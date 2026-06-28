/// LLM message / request / response / chunk models — provider-agnostic.
///
/// These mirror the OpenAI Chat Completions shape (role/content/tool_calls)
/// with a few extensions for DeepSeek's prefix-continuation beta:
///   - [prefix] (assistant message): seed the model's own message for
///     continuation.
///   - [reasoningContent]: DeepSeek CoT text; setting it (and leaving content
///     empty) = "continue the chain-of-thought".
library;

import '../../domain/conversation.dart' as conv
    show Message, MessageRole, ToolCall, roleToString;

/// A single message as sent to an LLM provider. Built from domain
/// [conv.Message]s plus provider options.
class LlmMessage {
  final conv.MessageRole role;
  final String content;
  final List<conv.ToolCall> toolCalls;

  /// DeepSeek: continue from this assistant message.
  final bool prefix;

  /// DeepSeek: reasoning/CoT text (continuing CoT when content is empty).
  final String reasoningContent;

  /// For role==tool responses: which tool call this answers.
  final String? toolCallId;

  LlmMessage({
    required this.role,
    this.content = '',
    List<conv.ToolCall>? toolCalls,
    this.prefix = false,
    this.reasoningContent = '',
    this.toolCallId,
  }) : toolCalls = toolCalls ?? [];

  /// Build the provider request body for this message. Providers call this
  /// and then add provider-specific fields on top.
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'role': conv.roleToString(role)};
    // DeepSeek rejects assistant prefix seeds that omit `content` entirely
    // ("content or tool_calls must be set"). Always emit `content` (even
    // empty) when this is a prefix continuation seed.
    if (content.isNotEmpty || prefix) {
      m['content'] = content;
    }
    if (toolCalls.isNotEmpty) {
      m['tool_calls'] = toolCalls
          .map((t) => {
                'id': t.id,
                'type': 'function',
                'function': {'name': t.name, 'arguments': t.arguments},
              })
          .toList();
    }
    if (reasoningContent.isNotEmpty) m['reasoning_content'] = reasoningContent;
    if (prefix) m['prefix'] = true;
    if (toolCallId != null) m['tool_call_id'] = toolCallId;
    return m;
  }
}

/// One tool/function definition, OpenAI function-calling shape.
class LlmTool {
  final String name;
  final String description;
  final Map<String, dynamic> parametersJsonSchema;

  const LlmTool({
    required this.name,
    required this.description,
    required this.parametersJsonSchema,
  });

  Map<String, dynamic> toJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parametersJsonSchema,
        },
      };
}

class LlmRequest {
  final String model;
  final List<LlmMessage> messages;
  final List<LlmTool> tools;
  final String? toolChoice; // 'auto' | 'none' | 'required'
  final double? temperature;
  final List<String>? stop;
  final bool stream;

  /// Force the last assistant message to be a prefix-continuation seed
  /// (DeepSeek). The provider reads this to set prefix:true.
  final bool usePrefixContinuation;

  const LlmRequest({
    required this.model,
    required this.messages,
    this.tools = const [],
    this.toolChoice,
    this.temperature,
    this.stop,
    this.stream = true,
    this.usePrefixContinuation = false,
  });

  Map<String, dynamic> toBody() {
    final b = <String, dynamic>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
    };
    if (tools.isNotEmpty) {
      b['tools'] = tools.map((t) => t.toJson()).toList();
      b['tool_choice'] = toolChoice ?? 'auto';
    }
    if (temperature != null) b['temperature'] = temperature;
    if (stop != null) b['stop'] = stop;
    if (stream) b['stream'] = true;
    return b;
  }
}

/// Non-streaming response.
class LlmResponse {
  final String content;
  final String reasoningContent;
  final List<conv.ToolCall> toolCalls;

  const LlmResponse({
    this.content = '',
    this.reasoningContent = '',
    this.toolCalls = const [],
  });
}

/// A single streaming increment.
class LlmChunk {
  final String? contentDelta;
  final String? reasoningDelta;

  /// Indexed tool-call deltas. Key = index of the tool call in the response.
  final Map<int, ToolCallDelta> toolCallDeltas;

  final bool done;

  const LlmChunk({
    this.contentDelta,
    this.reasoningDelta,
    this.toolCallDeltas = const {},
    this.done = false,
  });
}

class ToolCallDelta {
  final String? id;
  final String? name;
  final String? argumentsDelta;
  const ToolCallDelta({this.id, this.name, this.argumentsDelta});
}
