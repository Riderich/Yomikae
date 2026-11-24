import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

/// Translates all text blocks of a page with one OpenAI-compatible chat
/// completion request (DeepSeek, Qwen, OpenAI, local servers, ...).
class LlmPageTranslator {
  final String baseUrl;
  final String apiKey;
  final String model;
  final bool disableThinking;
  final Duration timeout;

  LlmPageTranslator({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.disableThinking,
    required this.timeout,
  });

  static const Map<String, String> _languageNames = {
    'zh': 'Simplified Chinese',
    'zh-cn': 'Simplified Chinese',
    'zh-hans': 'Simplified Chinese',
    'zh-tw': 'Traditional Chinese',
    'zh-hant': 'Traditional Chinese',
    'en': 'English',
    'en-us': 'English',
    'ko': 'Korean',
    'ko-kr': 'Korean',
    'ja': 'Japanese',
  };

  static String languageName(String code) => _languageNames[code.toLowerCase()] ?? code;

  static String systemPrompt(String targetLanguage) => '''
You are a professional manga translator. Translate the Japanese speech bubbles of one manga page into ${languageName(targetLanguage)}.
- The text comes from OCR and may contain small recognition errors; infer what was meant.
- Bubbles are given in reading order; use the surrounding bubbles as context.
- A long passage (a column of prose, a caption) may be split over several consecutive ids. Translate each piece so that the pieces read in order form the whole passage; never move text between ids.
- Keep translations natural, colloquial and short enough to fit a speech bubble. Keep names consistent.
- Keep the original punctuation style for emphasis (！？…), do not add explanations or notes.
Reply with JSON only, in exactly this form: {"translations":[{"id":<id>,"text":"<translation>"}]}''';

  /// Returns translations keyed by the ids of [texts].
  Future<Map<int, String>> translate(Map<int, String> texts, String targetLanguage) async {
    if (texts.isEmpty) {
      return {};
    }
    final String user = jsonEncode(texts.entries.map((e) => {'id': e.key, 'text': e.value}).toList());
    final String content = await _complete(systemPrompt(targetLanguage), user, json: true, receiveTimeout: timeout);
    return parseTranslations(content);
  }

  /// Minimal request to check the URL, key and model. Throws an
  /// [LlmApiException] that says what went wrong.
  Future<void> ping() async {
    await _complete(null, 'Reply only with OK', json: false, receiveTimeout: const Duration(seconds: 30));
  }

  /// Sends one request, trying the candidate endpoints of [baseUrl] in order
  /// (moving on only after 404/405), and retries once without optional
  /// parameters when the API rejects the request (some APIs refuse
  /// `thinking`, `temperature` or `response_format`).
  Future<String> _complete(String? system, String user, {required bool json, required Duration receiveTimeout}) async {
    final Dio dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: receiveTimeout,
      receiveTimeout: receiveTimeout,
      headers: {
        if (cleanKey(apiKey).isNotEmpty) 'Authorization': 'Bearer ${cleanKey(apiKey)}',
        'Content-Type': 'application/json',
      },
    ));

    LlmApiException? lastError;
    for (final LlmEndpoint endpoint in endpointsOf(baseUrl)) {
      for (final bool minimal in [false, true]) {
        final Map<String, dynamic> body = requestBody(endpoint.api, model, system, user, json: json, disableThinking: disableThinking, minimal: minimal);
        Response<dynamic> response;
        try {
          try {
            response = await dio.post(endpoint.url, data: body);
          } on DioException catch (e) {
            if (e.type == DioExceptionType.connectionTimeout || !LlmApiException.fromDio(endpoint.url, e).connectionCut) {
              rethrow;
            }
            // a dropped connection is often a one-off; try once more
            await Future.delayed(const Duration(seconds: 1));
            response = await dio.post(endpoint.url, data: body);
          }
        } on DioException catch (e) {
          lastError = LlmApiException.fromDio(endpoint.url, e);
          final int? status = e.response?.statusCode;
          if (!minimal && (status == 400 || status == 422)) {
            continue;
          }
          break;
        }
        try {
          final dynamic data = response.data is String ? jsonDecode(response.data as String) : response.data;
          return replyText(endpoint.api, data);
        } catch (e) {
          throw LlmApiException(endpoint.url, response.statusCode, 'unexpected reply: $e');
        }
      }
      if (lastError?.status != 404 && lastError?.status != 405) {
        break;
      }
    }
    throw lastError!;
  }

  /// The key as pasted, without what copying tends to bring along: spaces,
  /// line breaks, invisible characters, quotes and a `Bearer ` prefix.
  static String cleanKey(String key) {
    String k = key.replaceAll(RegExp(r'[\s​-‏⁠﻿]'), '');
    k = k.replaceAll(RegExp('^["\'“”‘’]+|["\'“”‘’]+\$'), '');
    if (k.toLowerCase().startsWith('bearer')) {
      k = k.substring(6);
    }
    return k;
  }

  /// The endpoints to try for what the user typed as the API address:
  /// - a full `.../chat/completions` or `.../responses` URL is used as is;
  /// - a base URL with a path (`.../v1`, `.../compatible-mode/v1`) gets
  ///   `/chat/completions`;
  /// - a bare host gets `/v1/chat/completions`, then `/chat/completions`.
  static List<LlmEndpoint> endpointsOf(String baseUrl) {
    String url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isNotEmpty && !url.contains('://')) {
      url = 'https://$url';
    }
    final String lower = url.toLowerCase();
    if (lower.endsWith('/chat/completions')) {
      return [LlmEndpoint(url, LlmApi.chat)];
    }
    if (lower.endsWith('/responses')) {
      return [LlmEndpoint(url, LlmApi.responses)];
    }
    final Uri? uri = Uri.tryParse(url);
    if (uri != null && (uri.path.isEmpty || uri.path == '/')) {
      return [LlmEndpoint('$url/v1/chat/completions', LlmApi.chat), LlmEndpoint('$url/chat/completions', LlmApi.chat)];
    }
    return [LlmEndpoint('$url/chat/completions', LlmApi.chat)];
  }

  /// [minimal] leaves out everything but the model and the prompt.
  static Map<String, dynamic> requestBody(
    LlmApi api,
    String model,
    String? system,
    String user, {
    required bool json,
    required bool disableThinking,
    required bool minimal,
  }) {
    if (api == LlmApi.responses) {
      return {
        'model': model,
        if (system != null) 'instructions': system,
        'input': user,
        if (!minimal && json)
          'text': {
            'format': {'type': 'json_object'},
          },
        if (!minimal && json) 'temperature': 0.3,
      };
    }
    return {
      'model': model,
      'messages': [
        if (system != null) {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      if (!minimal && json) 'temperature': 0.3,
      if (!minimal && json) 'response_format': {'type': 'json_object'},
      if (!minimal && disableThinking) 'thinking': {'type': 'disabled'},
    };
  }

  /// The text of a chat completion or a Responses API reply.
  static String replyText(LlmApi api, dynamic data) {
    if (data is! Map) {
      throw const FormatException('reply is not a JSON object');
    }
    if (data['error'] != null) {
      throw FormatException('${data['error']}');
    }
    if (api == LlmApi.responses) {
      if (data['output_text'] is String) {
        return data['output_text'] as String;
      }
      final StringBuffer text = StringBuffer();
      for (final dynamic item in (data['output'] as List? ?? const [])) {
        if (item is Map && item['type'] == 'message') {
          for (final dynamic part in (item['content'] as List? ?? const [])) {
            if (part is Map && part['text'] is String) {
              text.write(part['text']);
            }
          }
        }
      }
      return text.toString();
    }
    final dynamic content = data['choices'][0]['message']['content'];
    if (content is List) {
      return content.map((p) => p is Map ? (p['text'] ?? '') : '$p').join();
    }
    return (content ?? '') as String;
  }

  /// Parses the model reply, tolerating code fences or text around the JSON.
  static Map<int, String> parseTranslations(String content) {
    final int start = content.indexOf('{');
    final int end = content.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw FormatException('LLM reply contains no JSON: $content');
    }
    final dynamic json = jsonDecode(content.substring(start, end + 1));
    final List<dynamic> items = json is Map ? (json['translations'] ?? const []) as List : json as List;
    final Map<int, String> result = {};
    for (final dynamic item in items) {
      if (item is! Map) {
        continue;
      }
      final int? id = item['id'] is int ? item['id'] as int : int.tryParse('${item['id']}');
      final String? text = item['text']?.toString();
      if (id != null && text != null && text.trim().isNotEmpty) {
        result[id] = text.trim();
      }
    }
    return result;
  }
}

enum LlmApi { chat, responses }

class LlmEndpoint {
  final String url;
  final LlmApi api;

  const LlmEndpoint(this.url, this.api);

  @override
  bool operator ==(Object other) => other is LlmEndpoint && other.url == url && other.api == api;

  @override
  int get hashCode => Object.hash(url, api);

  @override
  String toString() => '${api.name} $url';
}

/// A failed API call, with the URL, the HTTP status and the API's own message.
class LlmApiException implements Exception {
  final String url;
  final int? status;
  final String message;

  /// The network cut the connection before the API answered (TLS handshake
  /// dropped, connection reset or refused): usually the address is blocked
  /// on this network, not a wrong URL or key.
  final bool connectionCut;

  LlmApiException(this.url, this.status, this.message, {this.connectionCut = false});

  factory LlmApiException.fromDio(String url, DioException e) {
    final int? status = e.response?.statusCode;
    if (status == null) {
      final Object? cause = e.error;
      final bool cut = cause is HandshakeException ||
          cause is SocketException ||
          RegExp('handshake|connection (reset|refused|closed|terminated)', caseSensitive: false).hasMatch('${e.message} $cause');
      String detail = '${cause ?? e.message ?? e.type.name}';
      if (e.type == DioExceptionType.connectionTimeout) {
        detail = 'connection timed out';
      }
      return LlmApiException(url, null, detail, connectionCut: cut || e.type == DioExceptionType.connectionTimeout);
    }
    final dynamic data = e.response?.data;
    String detail = '';
    if (data is Map && data['error'] != null) {
      final dynamic error = data['error'];
      detail = error is Map ? '${error['message'] ?? error}' : '$error';
    } else if (data != null) {
      detail = data is String ? data : jsonEncode(data);
    }
    if (detail.length > 300) {
      detail = '${detail.substring(0, 300)}…';
    }
    return LlmApiException(url, status, detail);
  }

  @override
  String toString() => status == null ? '$message\n$url' : 'HTTP $status $message\n$url';
}
