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
import '../domain/novel_doc.dart';
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
  /// and the list of tool results produced. [cancelToken] lets the caller
  /// abort mid-stream; on cancel, the partial assistant message is emitted
  /// and the turn ends (no further rounds).
  Future<TurnSnapshot> run({
    required Novel novel,
    required NovelDoc novelDoc,
    required String chapterId,
    required String chapterTitle,
    required List<Message> history,
    required Message userMessage,
    required int now,
    required TurnUpdate onTurnUpdate,
    CancelToken? cancelToken,
  }) async {
    final system = promptBuilder.build(novel: novel);

    final toolCtxBase = () => ToolContext(
          novel: novel,
          novelDoc: novelDoc,
          currentChapterId: chapterId,
          chapterTitle: chapterTitle,
          messageId: userMessage.id,
          now: now,
        );

    final llmHistory = <LlmMessage>[
      LlmMessage(role: MessageRole.system, content: system),
      ...history.map(_toLlm),
      // Convert rich-text content (inline @@$...$@@ tokens) to the
      // model-facing plain text, then append any agent-facing message
      // context (e.g. selected paragraphs) before sending to the LLM.
      LlmMessage(
          role: MessageRole.user, content: _userToLlmText(userMessage)),
    ];

    var round = 0;
    final toolResults = <ToolDispatchResult>[];
    // Messages produced this turn, in order: assistant(round1), tool results,
    // assistant(round2), tool results, ... Each round adds one assistant
    // message and (if it had tool calls) the tool-result messages.
    final turnMessages = <Message>[];

    while (round < maxRounds) {
      if (cancelToken?.cancelled ?? false) {
        return TurnSnapshot(
            messages: turnMessages, toolResults: toolResults);
      }
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

      // Incremental tool-call accumulator: streams tool-call arguments
      // char-by-char into the live assistant message so the UI can render
      // them as they arrive (not only after the stream finishes). The final
      // resp.toolCalls (set below after the stream completes) is authoritative
      // and overrides whatever was accumulated here.
      final tcBuilders = <int, _ToolCallBuilder>{};

      final retry = StreamingRetry(client);
      final result = await retry.runWithRetry(
        request: req,
        cancelToken: cancelToken,
        onChunk: (chunk) {
          final contentDelta = chunk.contentDelta;
          final reasoningDelta = chunk.reasoningDelta;
          final hasContent =
              contentDelta != null && contentDelta.isNotEmpty;
          final hasReasoning =
              reasoningDelta != null && reasoningDelta.isNotEmpty;
          final hasTools = chunk.toolCallDeltas.isNotEmpty;
          if (!hasContent && !hasReasoning && !hasTools) return;
          if (hasTools) {
            chunk.toolCallDeltas.forEach((index, delta) {
              final b = tcBuilders.putIfAbsent(index, _ToolCallBuilder.new);
              if (delta.id != null) b.id = delta.id!;
              if (delta.name != null) b.name = delta.name!;
              if (delta.argumentsDelta != null) {
                b.arguments.write(delta.argumentsDelta);
              }
            });
          }

          final i = turnMessages.indexOf(assistant);
          final newToolCalls = tcBuilders.isEmpty
              ? assistant.toolCalls
              : (tcBuilders.keys.toList()..sort()).map((k) {
                  final b = tcBuilders[k]!;
                  return ToolCall(
                      id: b.id,
                      name: b.name,
                      arguments: b.arguments.toString());
                }).toList();
          assistant = Message(
            id: assistant.id,
            role: MessageRole.assistant,
            content: hasContent
                ? assistant.content + contentDelta
                : assistant.content,
            reasoningContent: hasReasoning
                ? assistant.reasoningContent + reasoningDelta
                : assistant.reasoningContent,
            toolCalls: newToolCalls,
            turnId: userMessage.turnId,
            createdAt: assistant.createdAt,
          );
          turnMessages[i] = assistant;
          emit();
        },
      );

      // If the stream failed past all automatic retries, surface the error to
      // the caller (EditorStateNotifier catches it → lastError banner) instead
      // of silently treating the empty response as a final reply.
      if (result.failed) {
        throw _StreamFailedException(result.error, result.retries);
      }

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

      // If the user cancelled mid-stream, end the turn with what we have.
      if (result.cancelled) {
        return TurnSnapshot(
            messages: turnMessages, toolResults: toolResults);
      }

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
    // User messages may carry rich-text tokens; convert to plain text, then
    // append any agent-facing message context (persisted for consistency).
    final content = m.role == MessageRole.user ? _userToLlmText(m) : m.content;
    return LlmMessage(
      role: m.role,
      content: content,
      toolCalls: m.toolCalls,
      reasoningContent: m.reasoningContent,
    );
  }

  /// Plain-text view of a user message for the LLM: rich-text tokens expanded
  /// via [toAgentText], with any agent-facing [Message.messageContext]
  /// (e.g. selected paragraphs) appended as a trailing block.
  String _userToLlmText(Message m) {
    final base = toAgentText(m.content);
    if (m.messageContext.isEmpty) return base;
    return '$base\n\n${m.messageContext}';
  }

  String _newAssistantId() => _uuid.v4();
}

/// Local incremental builder for streaming tool calls (mirrors
/// StreamAccumulator's _ToolCallBuilder but kept here so the agent loop can
/// reflect partial tool-call args into the live snapshot before the stream
/// resolves to its final LlmResponse).
class _ToolCallBuilder {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}

/// Thrown when streaming failed past all automatic retries. Carries the
/// underlying error + retry count so the UI banner can report both.
class _StreamFailedException implements Exception {
  final Object? error;
  final int retries;
  const _StreamFailedException(this.error, this.retries);

  @override
  String toString() =>
      'API 请求失败（已重试 $retries 次）${error == null ? '' : ': $error'}';
}

// Local import-free id helper avoids pulling uuid here.
