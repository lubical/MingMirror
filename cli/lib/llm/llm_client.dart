import 'dart:convert';

import 'package:dio/dio.dart';

/// OpenAI 兼容流式客户端：dio + 手写 SSE 解析。
class LlmClient {
  final Dio _dio;
  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;

  LlmClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = 0.4, // E2：从 0.7 降到 0.4，与"不得自造原文"约束对齐，降低虚构引文概率
  }) : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 120),
        ));

  /// 流式对话。messages: [{role, content}, ...]，逐段产出增量文本。
  Stream<String> chat(List<Map<String, String>> messages) async* {
    final resp = await _dio.post<ResponseBody>(
      '/chat/completions',
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        },
        responseType: ResponseType.stream,
      ),
      data: {
        'model': model,
        'messages': messages,
        'stream': true,
        'temperature': temperature,
      },
    );

    final body = resp.data;
    if (body == null) {
      throw LlmException('空响应');
    }

    var buffer = '';
    await for (final chunk
        in body.stream.cast<List<int>>().transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final idx = buffer.indexOf('\n\n');
        if (idx < 0) break;
        final event = buffer.substring(0, idx);
        buffer = buffer.substring(idx + 2);
        for (final line in event.split('\n')) {
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data.isEmpty) continue;
          if (data == '[DONE]') return;
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            // B2：choices 可能非 List、元素可能非 Map（错误响应体），逐层安全取值
            final choices = json['choices'];
            if (choices is! List || choices.isEmpty) continue;
            final first = choices.first;
            if (first is! Map) continue;
            final delta = first['delta'];
            if (delta is! Map) continue;
            final content = delta['content'];
            if (content is String && content.isNotEmpty) yield content;
          } on FormatException {
            // 忽略无法解析的单条 SSE 数据
          }
        }
      }
    }
  }
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);
  @override
  String toString() => 'LLM 调用失败: $message';
}
