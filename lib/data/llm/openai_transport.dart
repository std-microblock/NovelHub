/// Shared HTTP plumbing for OpenAI-compatible chat completions (both
/// non-streaming and SSE streaming). The three provider classes differ only
/// in how they shape the request (DeepSeek prefix / beta) — the transport is
/// identical, so it lives here.
library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'llm_client.dart';
import 'llm_models.dart';
import 'openai_parse.dart';
import 'sse_splitter.dart';

class LlmHttpException implements Exception {
  final int statusCode;
  final String body;
  LlmHttpException(this.statusCode, this.body);
  @override
  String toString() => 'LLM HTTP $statusCode: $body';
}

mixin OpenAiTransport on LlmClient {
  String get completionsPath => '/chat/completions';

  Uri _uri(String baseUrl) {
    var b = baseUrl;
    if (b.endsWith('/')) b = b.substring(0, b.length - 1);
    return Uri.parse('$b$completionsPath');
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey}',
      };

  @override
  Future<LlmResponse> complete(LlmRequest req) async {
    final body = jsonEncode(req.toBody()..['stream'] = false);
    final res = await http.post(_uri(config.baseUrl),
        headers: _headers, body: body);
    if (res.statusCode != 200) {
      throw LlmHttpException(res.statusCode, res.body);
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return parseOpenAiResponse(json);
  }

  @override
  Stream<LlmChunk> stream(LlmRequest req) async* {
    // Always stream (req.stream defaults true). Provider sets beta path etc.
    final body = jsonEncode(req.toBody());
    final request = http.Request('POST', _uri(config.baseUrl))
      ..headers.addAll(_headers)
      ..body = body;
    final client = http.Client();
    final response = await client.send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      client.close();
      throw LlmHttpException(response.statusCode, body);
    }
    final splitter = SseSplitter();
    try {
      await for (final raw in response.stream
          .transform(utf8.decoder)) {
        for (final payload in splitter.feed(raw)) {
          final chunk = parseOpenAiDelta(payload);
          if (chunk != null) yield chunk;
        }
      }
      // Flush any trailing buffered event (some servers omit the final
      // blank line).
      for (final payload in splitter.feed('\n\n')) {
        final chunk = parseOpenAiDelta(payload);
        if (chunk != null) yield chunk;
      }
    } finally {
      client.close();
    }
  }
}
