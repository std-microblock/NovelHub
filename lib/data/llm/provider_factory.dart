/// Builds an [LlmClient] from a [ProviderConfig].
library;

import 'llm_client.dart';
import 'providers/openai_compatible_provider.dart';
import 'providers/openai_streaming_provider.dart';
import 'providers/deepseek_prefix_provider.dart';

LlmClient buildLlmClient(ProviderConfig config) {
  switch (config.type) {
    case ProviderType.openaiCompatible:
      return OpenAiCompatibleProvider(config);
    case ProviderType.openaiStreaming:
      return OpenAiStreamingProvider(config);
    case ProviderType.deepSeekPrefix:
      return DeepSeekPrefixProvider(config);
  }
}
