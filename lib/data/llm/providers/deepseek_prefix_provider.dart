/// DeepSeek prefix-continuation (Beta) provider.
///
/// - Uses `https://api.deepseek.com/beta` when [ProviderConfig.beta] is on.
/// - Prefix continuation: the *last* message is forced to
///   `role:assistant, prefix:true` so the model completes the rest of that
///   message. Caller sets `req.usePrefixContinuation = true` and puts the
///   partial assistant content in the last message's `content`.
/// - CoT-prefix restriction: when [ProviderConfig.cotPrefix] is non-empty,
///   the continuation seed is an assistant message with `reasoning_content`
///   set to the prefix and `content` empty — i.e. "continue the CoT from
///   these first characters".
library;

import '../llm_client.dart';
import '../llm_models.dart';
import '../openai_transport.dart';
import '../../../domain/conversation.dart' as conv show MessageRole;

class DeepSeekPrefixProvider extends LlmClient with OpenAiTransport {
  @override
  final ProviderConfig config;
  DeepSeekPrefixProvider(this.config);

  @override
  String get completionsPath =>
      config.beta ? '/beta/chat/completions' : '/chat/completions';

  /// Reshape the request for DeepSeek prefix continuation.
  LlmRequest _shape(LlmRequest req) {
    if (!req.usePrefixContinuation) {
      // Still apply the CoT prefix restriction if configured: append an
      // assistant reasoning seed at the *end* so the model continues CoT
      // from those characters. (Only meaningful when caller opts in.)
      if ((config.cotPrefix ?? '').isNotEmpty) {
        final cotPrefix = config.cotPrefix!.substring(
            0,
            config.cotFirstChars.clamp(0, config.cotPrefix!.length));
        if (cotPrefix.isNotEmpty) {
          final seed = LlmMessage(
            role: conv.MessageRole.assistant,
            reasoningContent: cotPrefix,
            prefix: true,
          );
          return LlmRequest(
            model: req.model,
            messages: [...req.messages, seed],
            tools: req.tools,
            toolChoice: req.toolChoice,
            temperature: req.temperature ?? config.temperature,
            stop: req.stop,
            stream: req.stream,
            usePrefixContinuation: false,
          );
        }
      }
      return req;
    }

    // Prefix continuation: take the last message and mark it prefix:true.
    final msgs = [...req.messages];
    if (msgs.isNotEmpty) {
      final last = msgs.removeLast();
      final seed = LlmMessage(
        role: conv.MessageRole.assistant,
        content: last.content,
        reasoningContent: last.reasoningContent,
        toolCalls: last.toolCalls,
        prefix: true,
      );
      msgs.add(seed);
    }
    return LlmRequest(
      model: req.model,
      messages: msgs,
      tools: req.tools,
      toolChoice: req.toolChoice,
      temperature: req.temperature ?? config.temperature,
      stop: req.stop,
      stream: req.stream,
      usePrefixContinuation: true,
    );
  }

  @override
  Future<LlmResponse> complete(LlmRequest req) =>
      super.complete(_shape(req));

  /// DeepSeek's prefix-continuation (beta) endpoint returns an EMPTY body
  /// when `stream:true` is sent — it only works non-streaming. So we route
  /// streaming requests through the non-streaming path and emit the full
  /// response as a single chunk, keeping the agent loop's streaming contract
  /// intact while actually getting content back.
  @override
  Stream<LlmChunk> stream(LlmRequest req) async* {
    final shaped = _shape(req);
    // Force non-streaming on the wire: the beta prefix endpoint returns an
    // empty body when stream:true is set.
    final nonStream = LlmRequest(
      model: shaped.model,
      messages: shaped.messages,
      tools: shaped.tools,
      toolChoice: shaped.toolChoice,
      temperature: shaped.temperature,
      stop: shaped.stop,
      stream: false,
      usePrefixContinuation: shaped.usePrefixContinuation,
    );
    final resp = await super.complete(nonStream);
    if (resp.reasoningContent.isNotEmpty) {
      yield LlmChunk(reasoningDelta: resp.reasoningContent);
    }
    if (resp.content.isNotEmpty) {
      yield LlmChunk(contentDelta: resp.content);
    }
    for (final tc in resp.toolCalls) {
      yield LlmChunk(toolCallDeltas: {
        0: ToolCallDelta(id: tc.id, name: tc.name, argumentsDelta: tc.arguments),
      });
    }
    yield const LlmChunk(done: true);
  }
}
