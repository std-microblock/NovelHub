/// OpenAI-compatible provider (non-streaming default, streaming on demand).
library;

import '../llm_client.dart';
import '../openai_transport.dart';

class OpenAiCompatibleProvider extends LlmClient with OpenAiTransport {
  @override
  final ProviderConfig config;
  OpenAiCompatibleProvider(this.config);
}
