import 'package:flutter_test/flutter_test.dart';
import 'package:novelhub/agent/agent_loop.dart';
import 'package:novelhub/data/llm/llm_client.dart';
import 'package:novelhub/data/llm/llm_models.dart';
import 'package:novelhub/domain/conversation.dart';
import 'package:novelhub/domain/entities.dart';
import 'package:novelhub/domain/novel_doc.dart';

/// A mock client that replays a scripted sequence of responses.
class _ScriptedClient extends LlmClient {
  final List<LlmResponse> _responses;
  int _i = 0;
  _ScriptedClient(this._responses, ProviderConfig cfg) : _cfg = cfg;
  final ProviderConfig _cfg;

  /// Captured requests (most recent last), for assertions.
  final List<LlmRequest> requests = [];

  @override
  ProviderConfig get config => _cfg;

  @override
  Future<LlmResponse> complete(LlmRequest req) async => _next();

  @override
  Stream<LlmChunk> stream(LlmRequest req) async* {
    requests.add(req);
    final r = _next();
    if (r.reasoningContent.isNotEmpty) {
      yield LlmChunk(reasoningDelta: r.reasoningContent);
    }
    if (r.content.isNotEmpty) {
      yield LlmChunk(contentDelta: r.content);
    }
    for (var i = 0; i < r.toolCalls.length; i++) {
      // Each tool call gets its own delta index so they don't collide.
      final tc = r.toolCalls[i];
      yield LlmChunk(toolCallDeltas: {
        i: ToolCallDelta(id: tc.id, name: tc.name, argumentsDelta: tc.arguments),
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
    novel.chapters = [
      Chapter(id: 'c1', title: novel.chapters.first.title, paragraphs: [
        Paragraph(id: 'p1', text: 'one'),
        Paragraph(id: 'p2', text: 'two'),
        Paragraph(id: 'p3', text: 'three'),
      ]),
    ];
    final doc = NovelDoc(novel);

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
      novelDoc: doc,
      chapterId: 'c1',
      chapterTitle: novel.chapters.first.title,
      history: const [],
      userMessage: userMsg,
      now: 1,
      onTurnUpdate: (s) => snapshots.add(s),
    );

    expect(doc.chapterById('c1')!.paragraphs[1].text, 'TWO');
    expect(result.toolResults, hasLength(1));
    expect(snapshots, isNotEmpty);
  });

  test('agent loop preserves round-1 content when round-2 follows tool call',
      () async {
    // Regression: previously the loop kept a single `assistant` Message and
    // overwrote it each round, so round-1's content (and tool calls) were
    // lost when round-2 produced the final reply.
    final novel = Novel.create(title: 't');
    novel.chapters = [
      Chapter(id: 'c1', title: novel.chapters.first.title, paragraphs: [
        Paragraph(id: 'p1', text: 'one'),
      ]),
    ];
    final doc = NovelDoc(novel);

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
      novelDoc: doc,
      chapterId: 'c1',
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
    expect(doc.chapterById('c1')!.paragraphs[0].text, 'CHANGED');
  });

  test('agent loop final snapshot has no leftover empty streaming message',
      () async {
    // Regression: after streaming the final reply, the snapshot must not
    // contain a duplicate/empty trailing assistant message.
    final novel = Novel.create(title: 't');
    novel.chapters = [
      Chapter(id: 'c1', title: novel.chapters.first.title,
          paragraphs: [Paragraph(id: 'p1', text: 'x')]),
    ];
    final doc = NovelDoc(novel);

    final client = _ScriptedClient([
      const LlmResponse(content: '只回复，无工具。'),
    ], _cfg());

    final loop = AgentLoop(client: client);
    final result = await loop.run(
      novel: novel,
      novelDoc: doc,
      chapterId: 'c1',
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

  test('chapter tools: add + rename + move + delete dispatched and reversible',
      () async {
    final novel = Novel.create(title: 't');
    novel.chapters = [
      Chapter(id: 'c1', title: novel.chapters.first.title,
          paragraphs: [Paragraph.create('')]),
    ];
    final doc = NovelDoc(novel);

    final client = _ScriptedClient([
      LlmResponse(content: '', toolCalls: [
        ToolCall(
            id: 'call_1',
            name: 'add_chapter',
            arguments: '{"title":"第二章"}'),
        ToolCall(
            id: 'call_2',
            name: 'rename_chapter',
            arguments: '{"chapter":"c1","title":"序章"}'),
        ToolCall(
            id: 'call_3',
            name: 'move_chapter',
            arguments: '{"chapter":"c1","to_position":2}'),
      ]),
      const LlmResponse(content: '已重组章节。'),
    ], _cfg());

    final loop = AgentLoop(client: client);
    final result = await loop.run(
      novel: novel,
      novelDoc: doc,
      chapterId: 'c1',
      chapterTitle: novel.chapters.first.title,
      history: const [],
      userMessage: Message.user('调整章节'),
      now: 1,
      onTurnUpdate: (_) {},
    );

    // 3 mutations all recorded.
    expect(result.toolResults.where((r) => r.mutation != null), hasLength(3));
    expect(doc.novel.chapters.length, 2);
    expect(doc.novel.chapters.first.title, '第二章');
    expect(doc.novel.chapters.last.id, 'c1');
    expect(doc.novel.chapters.last.title, '序章');

    // Revert the whole turn: undo every mutation (move, rename, add).
    final tl = doc; // NovelDoc carries the events
    for (final r in result.toolResults.reversed) {
      if (r.mutation != null) tl.undo(r.mutation!);
    }
    expect(doc.novel.chapters.length, 1);
    expect(doc.novel.chapters.first.id, 'c1');
  });

  test('chapter param routes edit_range to a different chapter', () async {
    final novel = Novel.create(title: 't');
    novel.chapters = [
      Chapter(id: 'c1', title: '第一章',
          paragraphs: [Paragraph(id: 'p1', text: 'one')]),
      Chapter(id: 'c2', title: '第二章',
          paragraphs: [Paragraph(id: 'q1', text: 'two')]),
    ];
    final doc = NovelDoc(novel);

    final client = _ScriptedClient([
      LlmResponse(content: '', toolCalls: [
        ToolCall(
          id: 'call_1',
          name: 'edit_range',
          arguments: '{"start":1,"end":1,"new_text":"TWO","chapter":2}',
        ),
      ]),
      const LlmResponse(content: '改好了。'),
    ], _cfg());

    final loop = AgentLoop(client: client);
    await loop.run(
      novel: novel,
      novelDoc: doc,
      chapterId: 'c1',
      chapterTitle: novel.chapters.first.title,
      history: const [],
      userMessage: Message.user('改第2章'),
      now: 1,
      onTurnUpdate: (_) {},
    );

    // Current chapter untouched, target chapter edited.
    expect(doc.chapterById('c1')!.paragraphs.first.text, 'one');
    expect(doc.chapterById('c2')!.paragraphs.first.text, 'TWO');
  });

  test('user messageContext is appended to the LLM user content', () async {
    final novel = Novel.create(title: 't');
    novel.chapters = [
      Chapter(id: 'c1', title: novel.chapters.first.title,
          paragraphs: [Paragraph(id: 'p1', text: 'x')]),
    ];
    final doc = NovelDoc(novel);

    final client = _ScriptedClient([
      const LlmResponse(content: 'ok'),
    ], _cfg());

    final loop = AgentLoop(client: client);
    final userMsg = Message.user('帮我看看', messageContext: '【选中段落】\n1 foo');
    await loop.run(
      novel: novel,
      novelDoc: doc,
      chapterId: 'c1',
      chapterTitle: novel.chapters.first.title,
      history: const [],
      userMessage: userMsg,
      now: 1,
      onTurnUpdate: (_) {},
    );

    // The first (and only) request's last user message must contain both the
    // plain content and the appended messageContext.
    final req = client.requests.single;
    final lastUser = req.messages.lastWhere(
        (m) => m.role == MessageRole.user,
        orElse: () => req.messages.last);
    expect(lastUser.content, contains('帮我看看'));
    expect(lastUser.content, contains('【选中段落】'));
    expect(lastUser.content, contains('1 foo'));
  });

  test('edit_range resolves paragraphs by hash', () async {
    final novel = Novel.create(title: 't');
    novel.chapters = [
      Chapter(id: 'c1', title: novel.chapters.first.title, paragraphs: [
        Paragraph(id: 'p1', text: 'one'),
        Paragraph(id: 'p2', text: 'two'),
        Paragraph(id: 'p3', text: 'three'),
      ]),
    ];
    final doc = NovelDoc(novel);
    // Use the display hash of paragraph 2 ("two") to target it.
    final hash = doc.displayHashes('c1')[1];

    final client = _ScriptedClient([
      LlmResponse(content: '', toolCalls: [
        ToolCall(
          id: 'call_1',
          name: 'edit_range',
          arguments: '{"start_hash":"$hash","new_text":"TWO"}',
        ),
      ]),
      const LlmResponse(content: '已修改。'),
    ], _cfg());

    final loop = AgentLoop(client: client);
    await loop.run(
      novel: novel,
      novelDoc: doc,
      chapterId: 'c1',
      chapterTitle: novel.chapters.first.title,
      history: const [],
      userMessage: Message.user('把two那段改成TWO'),
      now: 1,
      onTurnUpdate: (_) {},
    );

    // Only paragraph 2 changed; neighbors untouched.
    final paras = doc.chapterById('c1')!.paragraphs;
    expect(paras.map((p) => p.text).toList(), ['one', 'TWO', 'three']);
  });

  test('insert_at with no locator appends to the end', () async {
    final novel = Novel.create(title: 't');
    novel.chapters = [
      Chapter(id: 'c1', title: novel.chapters.first.title, paragraphs: [
        Paragraph(id: 'p1', text: 'one'),
      ]),
    ];
    final doc = NovelDoc(novel);

    final client = _ScriptedClient([
      LlmResponse(content: '', toolCalls: [
        ToolCall(
          id: 'call_1',
          name: 'insert_at',
          arguments: '{"new_text":"two\\n\\nthree"}',
        ),
      ]),
      const LlmResponse(content: '已追加。'),
    ], _cfg());

    final loop = AgentLoop(client: client);
    await loop.run(
      novel: novel,
      novelDoc: doc,
      chapterId: 'c1',
      chapterTitle: novel.chapters.first.title,
      history: const [],
      userMessage: Message.user('在末尾追加两段'),
      now: 1,
      onTurnUpdate: (_) {},
    );

    expect(doc.chapterById('c1')!.paragraphs.map((p) => p.text).toList(),
        ['one', 'two', 'three']);
  });
}
