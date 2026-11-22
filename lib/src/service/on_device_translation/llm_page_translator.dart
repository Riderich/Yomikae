import 'dart:convert';

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
    final Dio dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: timeout,
      receiveTimeout: timeout,
      headers: {
        if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
        'Content-Type': 'application/json',
      },
    ));

    final Map<String, dynamic> body = {
      'model': model,
      'temperature': 0.3,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': systemPrompt(targetLanguage)},
        {
          'role': 'user',
          'content': jsonEncode(texts.entries.map((e) => {'id': e.key, 'text': e.value}).toList()),
        },
      ],
      if (disableThinking) 'thinking': {'type': 'disabled'},
    };

    final Response<dynamic> response = await dio.post('${_trimSlash(baseUrl)}/chat/completions', data: body);
    final dynamic data = response.data is String ? jsonDecode(response.data as String) : response.data;
    final String content = data['choices'][0]['message']['content'] as String;
    return parseTranslations(content);
  }

  /// Minimal request to check the URL, key and model.
  Future<void> ping() async {
    final Dio dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}'},
    ));
    await dio.post('${_trimSlash(baseUrl)}/chat/completions', data: {
      'model': model,
      'max_tokens': 4,
      'messages': [
        {'role': 'user', 'content': 'Reply only with OK'},
      ],
      if (disableThinking) 'thinking': {'type': 'disabled'},
    });
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

  static String _trimSlash(String url) {
    String result = url.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
