/// The agent loop: stream an assistant turn, dispatch any tool calls, feed
/// the results back, and re-call until the assistant returns a plain reply.
///
/// Live updates are emitted via [onTurnUpdate] so the UI can render streaming
/// deltas and tool-call events as they happen. The caller owns the message
/// list (persistence/UI state); this class only mutates via callbacks.
library;

import '../data/llm/llm_client.dart';
import '../data/llm/llm_models.dart';
import '../data/llm/streaming_retry.dart';
import '../domain/conversation.dart';
import '../domain/entities.dart';
import '../domain/paragraph_doc.dart';
import '../domain/rich_text.dart';
import 'system_prompt.dart';
import 'tool_registry.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Snapshot of an in-progress assistant turn, emitted on each change.
///
/// [messages] is the ordered list of messages produced so far this turn:
/// each LLM round contributes an assistant message, followed by the tool
/// messages that round's tool calls produced. The last assistant message is
/// the one currently streaming (or the final reply). The caller commits
/// these (minus the system prompt) into the conversation.
class TurnSnapshot {
  /// Ordered assistant + tool messages produced this turn. The final element
  /// is the currently-streaming (or final) assistant message.
  final List<Message> messages;
  final List<ToolDispatchResult> toolResults;
  const TurnSnapshot({required this.messages, required this.toolResults});

  /// The streaming/final assistant message (last assistant in [messages]).
  Message get streamingMessage =>
      messages.lastWhere((m) => m.role == MessageRole.assistant,
          orElse: () => messages.last);
}

typedef TurnUpdate = void Function(TurnSnapshot snapshot);

class AgentLoop {
  final LlmClient client;
  final ToolRegistry registry;
  final SystemPromptBuilder promptBuilder;

  /// Hard cap on consecutive LLM round-trips (prevents tool-call loops).
  final int maxRounds;

  AgentLoop({
    required this.client,
    ToolRegistry? registry,
    SystemPromptBuilder? promptBuilder,
    this.maxRounds = 8,
  })  : registry = registry ?? ToolRegistry(),
        promptBuilder = promptBuilder ?? const SystemPromptBuilder();

  /// Run one full turn for [userMessage]. [history] is the prior non-system
  /// conversation (already persisted). Returns the final assistant message
  /// and the list of tool results produced.
  Future<TurnSnapshot> run({
    required Novel novel,
    required ParagraphDoc doc,
    required String chapterTitle,
    required List<Message> history,
    required Message userMessage,
    required int now,
    required TurnUpdate onTurnUpdate,
  }) async {
    final system = promptBuilder.build(
        novel: novel, doc: doc, chapterTitle: chapterTitle);

    final toolCtxBase = () => ToolContext(
          novel: novel,
          doc: doc,
          chapterTitle: chapterTitle,
          messageId: userMessage.id,
          now: now,
        );

    final llmHistory = <LlmMessage>[
      LlmMessage(role: MessageRole.system, content: system),
      ...history.map(_toLlm),
      // Convert rich-text content (inline @@$...$@@ tokens) to the
      // model-facing plain text before sending to the LLM.
      LlmMessage(
          role: MessageRole.user, content: toAgentText(userMessage.content)),
    ];

    var round = 0;
    final toolResults = <ToolDispatchResult>[];
    // Messages produced this turn, in order: assistant(round1), tool results,
    // assistant(round2), tool results, ... Each round adds one assistant
    // message and (if it had tool calls) the tool-result messages.
    final turnMessages = <Message>[];

    while (round < maxRounds) {
      round++;
      final req = LlmRequest(
        model: client.config.modelName,
        messages: llmHistory,
        tools: ToolRegistry.tools,
        temperature: client.config.temperature,
        stream: true,
      );

      // The assistant message for THIS round.
      var assistant = Message(
        id: _newAssistantId(),
        role: MessageRole.assistant,
        turnId: userMessage.turnId,
        createdAt: now,
      );
      turnMessages.add(assistant);
      void emit() => onTurnUpdate(
          TurnSnapshot(messages: turnMessages, toolResults: toolResults));

      final retry = StreamingRetry(client);
      final result = await retry.runWithRetry(
        request: req,
        onChunk: (chunk) {
          if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
            final i = turnMessages.indexOf(assistant);
            assistant = Message(
              id: assistant.id,
              role: MessageRole.assistant,
              content: assistant.content + (chunk.contentDelta ?? ''),
              reasoningContent: assistant.reasoningContent,
              toolCalls: assistant.toolCalls,
              turnId: userMessage.turnId,
              createdAt: assistant.createdAt,
            );
            turnMessages[i] = assistant;
            emit();
          }
        },
      );

      final resp = result.response;
      final i = turnMessages.indexOf(assistant);
      assistant = Message(
        id: assistant.id,
        role: MessageRole.assistant,
        content: resp.content,
        reasoningContent: resp.reasoningContent,
        toolCalls: resp.toolCalls,
        turnId: userMessage.turnId,
        createdAt: now,
      );
      turnMessages[i] = assistant;
      emit();

      if (resp.toolCalls.isEmpty) {
        // Final reply.
        return TurnSnapshot(
            messages: turnMessages, toolResults: toolResults);
      }

      // Append the assistant tool-call message to history.
      llmHistory.add(LlmMessage(
        role: MessageRole.assistant,
        content: resp.content,
        toolCalls: resp.toolCalls,
      ));

      // Dispatch each tool call and feed results back. Tool result messages
      // are interleaved right after this assistant message.
      for (final tc in resp.toolCalls) {
        final r = registry.dispatch(
          ctx: toolCtxBase(),
          toolCallId: tc.id,
          name: tc.name,
          argumentsJson: tc.arguments,
        );
        toolResults.add(r);
        final toolMsg = Message(
          id: tc.id,
          role: MessageRole.tool,
          content: r.resultJson,
          toolCallId: tc.id,
          toolName: tc.name,
          turnId: userMessage.turnId,
          createdAt: now,
        );
        turnMessages.add(toolMsg);
        llmHistory.add(LlmMessage(
          role: MessageRole.tool,
          content: r.resultJson,
          toolCallId: tc.id,
        ));
        emit();
      }
      // Loop again: model sees tool results and continues.
    }

    return TurnSnapshot(
        messages: turnMessages, toolResults: toolResults);
  }

  LlmMessage _toLlm(Message m) {
    if (m.role == MessageRole.tool) {
      return LlmMessage(
        role: MessageRole.tool,
        content: m.content,
        toolCallId: m.toolCallId,
      );
    }
    // User messages may carry rich-text tokens; convert to plain text.
    final content = m.role == MessageRole.user ? toAgentText(m.content) : m.content;
    return LlmMessage(
      role: m.role,
      content: content,
      toolCalls: m.toolCalls,
      reasoningContent: m.reasoningContent,
    );
  }

  String _newAssistantId() => _uuid.v4();
}

// Local import-free id helper avoids pulling uuid here.
