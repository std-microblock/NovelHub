/// Shared parsing of OpenAI-compatible streaming deltas into [LlmChunk]s.
library;

import 'dart:convert';
import 'llm_models.dart';
import '../../domain/conversation.dart' show ToolCall;

/// Parse one SSE `data:` payload (already stripped of the `data:` prefix).
/// Returns null for `[DONE]` / non-JSON / empty.
LlmChunk? parseOpenAiDelta(String payload) {
  final trimmed = payload.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed == '[DONE]') return const LlmChunk(done: true);
  try {
    final json = jsonDecode(trimmed) as Map<String, dynamic>;
    if (json['object'] == 'chat.completion' &&
        json['choices'] != null) {
      // Non-streamed body erroneously routed here — ignore.
      return null;
    }
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) return null;
    final choice = choices[0] as Map<String, dynamic>;
    final finishReason = choice['finish_reason'] as String?;
    if (finishReason != null && finishReason != 'null') {
      return const LlmChunk(done: true);
    }
    final delta = choice['delta'];
    if (delta == null) return null;
    final d = delta as Map<String, dynamic>;
    String? contentDelta;
    String? reasoningDelta;
    final Map<int, ToolCallDelta> toolDeltas = {};
    if (d['content'] is String) contentDelta = d['content'] as String;
    if (d['reasoning_content'] is String) {
      reasoningDelta = d['reasoning_content'] as String;
    }
    final tcs = d['tool_calls'];
    if (tcs is List) {
      for (final tc in tcs) {
        final m = tc as Map<String, dynamic>;
        final index = (m['index'] as num?)?.toInt() ?? 0;
        final fn = m['function'] as Map<String, dynamic>?;
        toolDeltas[index] = ToolCallDelta(
          id: m['id'] as String?,
          name: fn?['name'] as String?,
          argumentsDelta: fn?['arguments'] as String?,
        );
      }
    }
    if (contentDelta == null &&
        reasoningDelta == null &&
        toolDeltas.isEmpty) {
      return const LlmChunk();
    }
    return LlmChunk(
      contentDelta: contentDelta,
      reasoningDelta: reasoningDelta,
      toolCallDeltas: toolDeltas,
    );
  } catch (_) {
    return null;
  }
}

/// Parse a non-streaming OpenAI completion body into [LlmResponse].
LlmResponse parseOpenAiResponse(Map<String, dynamic> json) {
  final choices = (json['choices'] as List?) ?? [];
  if (choices.isEmpty) return const LlmResponse();
  final choice = choices[0] as Map<String, dynamic>;
  final msg = (choice['message'] as Map<String, dynamic>?) ?? {};
  final content = (msg['content'] as String?) ?? '';
  final reasoning = (msg['reasoning_content'] as String?) ?? '';
  final calls = <ToolCall>[];
  final tcs = msg['tool_calls'];
  if (tcs is List) {
    for (final tc in tcs) {
      final m = tc as Map<String, dynamic>;
      final fn = m['function'] as Map<String, dynamic>?;
      calls.add(ToolCall(
        id: (m['id'] as String?) ?? '',
        name: (fn?['name'] as String?) ?? '',
        arguments: (fn?['arguments'] as String?) ?? '',
      ));
    }
  }
  return LlmResponse(
    content: content,
    reasoningContent: reasoning,
    toolCalls: calls,
  );
}
