/// Streaming retry / prefix-continuation helper.
///
/// When a stream errors or is interrupted mid-generation, we recover by:
///   - DeepSeek (supportsPrefixContinuation): re-issue with the already-
///     accumulated assistant text as a `prefix:true` continuation seed = true
///     continuation of the same message.
///   - Other providers: best-effort continuation — append the partial
///     assistant message and ask the model to continue (not a true prefix
///     continuation, since the API has no such concept).
///
/// Automatic retries are attempted up to [ProviderConfig.autoRetryCount];
/// after that the caller surfaces a manual "retry" affordance.
library;

import 'llm_client.dart';
import 'llm_models.dart';
import '../../domain/conversation.dart' as conv show MessageRole;

class RetryResult {
  /// The final accumulated response (content/reasoning/tool calls), merged
  /// across the partial + continuation.
  final LlmResponse response;

  /// Number of automatic retries that were performed.
  final int retries;

  /// True if the stream failed and could not be recovered automatically.
  final bool failed;

  /// Accumulated partial text at the moment of failure (for manual retry UI).
  final String partialText;

  const RetryResult({
    required this.response,
    this.retries = 0,
    this.failed = false,
    this.partialText = '',
  });
}

class StreamingRetry {
  final LlmClient client;
  StreamingRetry(this.client);

  /// Run a stream with automatic retry-on-interruption. [onChunk] receives
  /// every emitted chunk (including from continuation attempts) so the UI can
  /// render live.
  Future<RetryResult> runWithRetry({
    required LlmRequest request,
    required void Function(LlmChunk) onChunk,
  }) async {
    final acc = StreamAccumulator();
    var attempt = 0;
    var retries = 0;
    LlmRequest req = request;

    while (true) {
      try {
        await for (final chunk in client.stream(req)) {
          acc.add(chunk);
          onChunk(chunk);
        }
        return RetryResult(response: acc.build(), retries: retries);
      } catch (e) {
        if (attempt >= client.config.autoRetryCount) {
          return RetryResult(
            response: acc.build(),
            retries: retries,
            failed: true,
            partialText: acc.build().content,
          );
        }
        attempt++;
        retries++;
        req = _continuationRequest(request, acc.build());
      }
    }
  }

  /// Build a continuation request from the partial response.
  LlmRequest _continuationRequest(LlmRequest original, LlmResponse partial) {
    final baseMessages = original.messages;
    final seed = LlmMessage(
      role: conv.MessageRole.assistant,
      content: partial.content,
      reasoningContent: partial.reasoningContent,
    );

    if (client.config.supportsPrefixContinuation) {
      // True prefix continuation: append assistant seed with prefix:true.
      return LlmRequest(
        model: original.model,
        messages: [...baseMessages, seed],
        tools: original.tools,
        toolChoice: original.toolChoice,
        temperature: original.temperature,
        stop: original.stop,
        stream: true,
        usePrefixContinuation: true,
      );
    }

    // Best-effort continuation for non-prefix providers.
    return LlmRequest(
      model: original.model,
      messages: [
        ...baseMessages,
        seed,
        LlmMessage(
            role: conv.MessageRole.user, content: '请继续未完成的内容。'),
      ],
      tools: original.tools,
      toolChoice: original.toolChoice,
      temperature: original.temperature,
      stop: original.stop,
      stream: true,
    );
  }

  /// Manual retry entry point — used by the UI "retry" button after an
  /// automatic-retry failure. Reuses the partial text as a prefix seed.
  Future<RetryResult> manualRetry({
    required LlmRequest request,
    required String partialText,
    required void Function(LlmChunk) onChunk,
  }) async {
    final acc = StreamAccumulator();
    final req = _continuationRequest(
        request,
        LlmResponse(content: partialText));
    try {
      await for (final chunk in client.stream(req)) {
        acc.add(chunk);
        onChunk(chunk);
      }
      return RetryResult(response: acc.build(), retries: 1, partialText: '');
    } catch (_) {
      return RetryResult(
        response: acc.build(),
        retries: 1,
        failed: true,
        partialText: partialText,
      );
    }
  }
}
