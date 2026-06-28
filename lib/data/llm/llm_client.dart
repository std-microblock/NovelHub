/// Provider configuration (persisted) + the LlmClient interface.
library;

import 'llm_models.dart';
import '../../domain/conversation.dart' show ToolCall;

enum ProviderType {
  openaiCompatible,
  openaiStreaming,
  deepSeekPrefix;

  String get label => switch (this) {
        openaiCompatible => 'OpenAI 兼容 (非流式)',
        openaiStreaming => 'OpenAI 流式',
        deepSeekPrefix => 'DeepSeek 前缀续写',
      };

  static ProviderType fromName(String s) =>
      ProviderType.values.firstWhere((e) => e.name == s,
          orElse: () => ProviderType.openaiCompatible);
}

/// A configured LLM provider. Plain model (persisted as JSON by repo).
class ProviderConfig {
  final String id;
  String name;
  ProviderType type;
  String baseUrl;
  String apiKey;
  String modelName;
  double temperature;

  /// DeepSeek-only: enable /beta prefix continuation endpoint.
  bool beta;

  /// DeepSeek-only: force CoT to start with this prefix (continue CoT).
  String? cotPrefix;

  /// DeepSeek-only: how many leading chars of CoT the prefix should cover.
  int cotFirstChars;

  /// How many automatic prefix-continuation retries on stream interruption.
  int autoRetryCount;

  ProviderConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.baseUrl,
    required this.apiKey,
    required this.modelName,
    this.temperature = 0.7,
    this.beta = false,
    this.cotPrefix,
    this.cotFirstChars = 2,
    this.autoRetryCount = 3,
  });

  ProviderConfig copy() => ProviderConfig(
        id: id,
        name: name,
        type: type,
        baseUrl: baseUrl,
        apiKey: apiKey,
        modelName: modelName,
        temperature: temperature,
        beta: beta,
        cotPrefix: cotPrefix,
        cotFirstChars: cotFirstChars,
        autoRetryCount: autoRetryCount,
      );

  ProviderConfig copyWith({
    String? name,
    ProviderType? type,
    String? baseUrl,
    String? apiKey,
    String? modelName,
    double? temperature,
    bool? beta,
    String? cotPrefix,
    int? cotFirstChars,
    int? autoRetryCount,
  }) =>
      ProviderConfig(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        modelName: modelName ?? this.modelName,
        temperature: temperature ?? this.temperature,
        beta: beta ?? this.beta,
        cotPrefix: cotPrefix ?? this.cotPrefix,
        cotFirstChars: cotFirstChars ?? this.cotFirstChars,
        autoRetryCount: autoRetryCount ?? this.autoRetryCount,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'modelName': modelName,
        'temperature': temperature,
        'beta': beta,
        'cotPrefix': cotPrefix,
        'cotFirstChars': cotFirstChars,
        'autoRetryCount': autoRetryCount,
      };

  factory ProviderConfig.fromJson(Map<String, dynamic> json) => ProviderConfig(
        id: json['id'] as String,
        name: json['name'] as String,
        type: ProviderType.fromName(json['type'] as String),
        baseUrl: json['baseUrl'] as String,
        apiKey: (json['apiKey'] as String?) ?? '',
        modelName: json['modelName'] as String,
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
        beta: (json['beta'] as bool?) ?? false,
        cotPrefix: json['cotPrefix'] as String?,
        cotFirstChars: (json['cotFirstChars'] as num?)?.toInt() ?? 2,
        autoRetryCount: (json['autoRetryCount'] as num?)?.toInt() ?? 3,
      );

  /// DeepSeek default convenience constructor.
  factory ProviderConfig.deepSeek({required String apiKey, String name = 'DeepSeek'}) =>
      ProviderConfig(
        id: 'cfg_deepseek_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        type: ProviderType.deepSeekPrefix,
        baseUrl: 'https://api.deepseek.com',
        apiKey: apiKey,
        modelName: 'deepseek-v4-pro',
        beta: true,
      );

  /// True when this provider supports true prefix continuation (DeepSeek beta).
  bool get supportsPrefixContinuation => type == ProviderType.deepSeekPrefix;
}

/// A function that builds [LlmRequest]s and runs them. Providers implement.
abstract class LlmClient {
  ProviderConfig get config;

  /// Non-streaming completion.
  Future<LlmResponse> complete(LlmRequest req);

  /// Streaming completion. Emits [LlmChunk]s; the final chunk has done=true.
  Stream<LlmChunk> stream(LlmRequest req);
}

/// Accumulates streamed chunks into a final [LlmResponse].
class StreamAccumulator {
  final StringBuffer content = StringBuffer();
  final StringBuffer reasoning = StringBuffer();
  final Map<int, _ToolCallBuilder> _tools = {};

  void add(LlmChunk chunk) {
    if (chunk.contentDelta != null) content.write(chunk.contentDelta);
    if (chunk.reasoningDelta != null) reasoning.write(chunk.reasoningDelta);
    chunk.toolCallDeltas.forEach((index, delta) {
      final b = _tools.putIfAbsent(index, _ToolCallBuilder.new);
      if (delta.id != null) b.id = delta.id!;
      if (delta.name != null) b.name = delta.name!;
      if (delta.argumentsDelta != null) {
        b.arguments.write(delta.argumentsDelta);
      }
    });
  }

  LlmResponse build() {
    final indices = _tools.keys.toList()..sort();
    final calls = indices.map((i) {
      final b = _tools[i]!;
      return ToolCall(
        id: b.id,
        name: b.name,
        arguments: b.arguments.toString(),
      );
    }).toList();
    return LlmResponse(
      content: content.toString(),
      reasoningContent: reasoning.toString(),
      toolCalls: calls,
    );
  }
}

class _ToolCallBuilder {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
