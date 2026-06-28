/// Streaming-focused OpenAI provider. Identical transport to the compatible
/// provider; the distinction exists in config so users can keep a streaming
/// preset separate from a non-streaming one (and so the UI can hint at it).
library;

import '../llm_client.dart';
import '../llm_models.dart';
import '../openai_transport.dart';

class OpenAiStreamingProvider extends LlmClient with OpenAiTransport {
  @override
  final ProviderConfig config;
  OpenAiStreamingProvider(this.config);

  @override
  Future<LlmResponse> complete(LlmRequest req) async {
    final acc = StreamAccumulator();
    await for (final chunk in super.stream(req)) {
      acc.add(chunk);
    }
    return acc.build();
  }
}
