import 'package:flutter_test/flutter_test.dart';
import 'package:novelhub/agent/agent_loop.dart';
import 'package:novelhub/data/llm/llm_client.dart';
import 'package:novelhub/data/llm/llm_models.dart';
import 'package:novelhub/domain/conversation.dart';
import 'package:novelhub/domain/entities.dart';
import 'package:novelhub/domain/paragraph_doc.dart';

/// A mock client that replays a scripted sequence of responses.
class _ScriptedClient extends LlmClient {
  final List<LlmResponse> _responses;
  int _i = 0;
  _ScriptedClient(this._responses, ProviderConfig cfg) : _cfg = cfg;
  final ProviderConfig _cfg;
  @override
  ProviderConfig get config => _cfg;

  @override
  Future<LlmResponse> complete(LlmRequest req) async => _next();

  @override
  Stream<LlmChunk> stream(LlmRequest req) async* {
    final r = _next();
    if (r.reasoningContent.isNotEmpty) {
      yield LlmChunk(reasoningDelta: r.reasoningContent);
    }
    if (r.content.isNotEmpty) {
      yield LlmChunk(contentDelta: r.content);
    }
    for (final tc in r.toolCalls) {
      // Single-shot deltas (index 0).
      yield LlmChunk(toolCallDeltas: {
        0: ToolCallDelta(id: tc.id, name: tc.name, argumentsDelta: tc.arguments),
      });
    }
    yield const LlmChunk(done: true);
  }

  LlmResponse _next() => _responses[_i++ % _responses.length];
}

ProviderConfig _cfg() => ProviderConfig(
      id: 'cfg',
      name: 'mock',
      type: ProviderType.openaiStreaming,
      baseUrl: 'http://localhost',
      apiKey: 'k',
      modelName: 'mock-model',
    );

void main() {
  test('agent loop dispatches tool calls then replies', () async {
    final novel = Novel.create(title: 't');
    novel.chapters.first.paragraphs = [
      Paragraph(id: 'p1', text: 'one'),
      Paragraph(id: 'p2', text: 'two'),
      Paragraph(id: 'p3', text: 'three'),
    ];
    final doc = ParagraphDoc(novel.chapters.first);

    final client = _ScriptedClient([
      LlmResponse(
        content: '',
        toolCalls: [
          ToolCall(
            id: 'call_1',
            name: 'edit_range',
            arguments: '{"start":2,"end":2,"new_text":"TWO"}',
          ),
        ],
      ),
      const LlmResponse(content: '已修改第 2 段。'),
    ], _cfg());

    final loop = AgentLoop(client: client);
    final userMsg = Message.user('把第2段改成TWO');
    final snapshots = <TurnSnapshot>[];

    final result = await loop.run(
      novel: novel,
      doc: doc,
      chapterTitle: novel.chapters.first.title,
      history: const [],
      userMessage: userMsg,
      now: 1,
      onTurnUpdate: (s) => snapshots.add(s),
    );

    expect(doc.paragraphs[1].text, 'TWO');
    expect(result.toolResults, hasLength(1));
    expect(snapshots, isNotEmpty);
  });

  test('agent loop preserves round-1 content when round-2 follows tool call',
      () async {
    // Regression: previously the loop kept a single `assistant` Message and
    // overwrote it each round, so round-1's content (and tool calls) were
    // lost when round-2 produced the final reply.
    final novel = Novel.create(title: 't');
    novel.chapters.first.paragraphs = [
      Paragraph(id: 'p1', text: 'one'),
    ];
    final doc = ParagraphDoc(novel.chapters.first);

    final client = _ScriptedClient([
      // Round 1: assistant emits BOTH content AND a tool call.
      LlmResponse(
        content: '我来帮你修改第 1 段。',
        toolCalls: [
          ToolCall(
            id: 'call_1',
            name: 'edit_range',
            arguments: '{"start":1,"end":1,"new_text":"CHANGED"}',
          ),
        ],
      ),
      // Round 2: final reply.
      const LlmResponse(content: '已完成。'),
    ], _cfg());

    final loop = AgentLoop(client: client);
    final userMsg = Message.user('改一下');

    final result = await loop.run(
      novel: novel,
      doc: doc,
      chapterTitle: novel.chapters.first.title,
      history: const [],
      userMessage: userMsg,
      now: 1,
      onTurnUpdate: (_) {},
    );

    // The committed turn messages must include BOTH assistant messages
    // (round-1 with content+toolCalls, round-2 final) plus the tool result.
    final assistantMsgs =
        result.messages.where((m) => m.role == MessageRole.assistant).toList();
    expect(assistantMsgs, hasLength(2));
    expect(assistantMsgs[0].content, '我来帮你修改第 1 段。');
    expect(assistantMsgs[0].toolCalls, hasLength(1));
    expect(assistantMsgs[1].content, '已完成。');
    // The tool result message is interleaved between the two assistants.
    final roles = result.messages.map((m) => m.role).toList();
    expect(roles, [
      MessageRole.assistant,
      MessageRole.tool,
      MessageRole.assistant,
    ]);
    expect(doc.paragraphs[0].text, 'CHANGED');
  });

  test('agent loop final snapshot has no leftover empty streaming message',
      () async {
    // Regression: after streaming the final reply, the snapshot must not
    // contain a duplicate/empty trailing assistant message.
    final novel = Novel.create(title: 't');
    novel.chapters.first.paragraphs = [Paragraph(id: 'p1', text: 'x')];
    final doc = ParagraphDoc(novel.chapters.first);

    final client = _ScriptedClient([
      const LlmResponse(content: '只回复，无工具。'),
    ], _cfg());

    final loop = AgentLoop(client: client);
    final result = await loop.run(
      novel: novel,
      doc: doc,
      chapterTitle: novel.chapters.first.title,
      history: const [],
      userMessage: Message.user('hi'),
      now: 1,
      onTurnUpdate: (_) {},
    );

    // Exactly one assistant message, no empties.
    final assistantMsgs =
        result.messages.where((m) => m.role == MessageRole.assistant).toList();
    expect(assistantMsgs, hasLength(1));
    expect(assistantMsgs[0].content, '只回复，无工具。');
    expect(assistantMsgs[0].toolCalls, isEmpty);
  });
}
