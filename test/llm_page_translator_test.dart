import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/on_device_translation/llm_page_translator.dart';

void main() {
  group('endpoints', () {
    test('a full chat completions URL is used as is', () {
      expect(LlmPageTranslator.endpointsOf('https://api.example.com/v1/chat/completions/'), [
        const LlmEndpoint('https://api.example.com/v1/chat/completions', LlmApi.chat),
      ]);
    });

    test('a responses URL uses the Responses API', () {
      expect(LlmPageTranslator.endpointsOf('https://api.openai.com/v1/responses'), [
        const LlmEndpoint('https://api.openai.com/v1/responses', LlmApi.responses),
      ]);
    });

    test('a base URL with a path gets /chat/completions', () {
      expect(LlmPageTranslator.endpointsOf('https://dashscope.aliyuncs.com/compatible-mode/v1'), [
        const LlmEndpoint('https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions', LlmApi.chat),
      ]);
    });

    test('a bare host tries /v1 first, and gets https when the scheme is missing', () {
      expect(LlmPageTranslator.endpointsOf('api.deepseek.com'), [
        const LlmEndpoint('https://api.deepseek.com/v1/chat/completions', LlmApi.chat),
        const LlmEndpoint('https://api.deepseek.com/chat/completions', LlmApi.chat),
      ]);
    });
  });

  group('request and reply', () {
    test('minimal body drops optional parameters', () {
      final Map<String, dynamic> full = LlmPageTranslator.requestBody(LlmApi.chat, 'm', 's', 'u', json: true, disableThinking: true, minimal: false);
      expect(full.keys, containsAll(['thinking', 'response_format', 'temperature']));
      final Map<String, dynamic> minimal = LlmPageTranslator.requestBody(LlmApi.chat, 'm', 's', 'u', json: true, disableThinking: true, minimal: true);
      expect(minimal.keys.toSet(), {'model', 'messages'});
    });

    test('responses body uses instructions and input', () {
      final Map<String, dynamic> body = LlmPageTranslator.requestBody(LlmApi.responses, 'm', 's', 'u', json: true, disableThinking: true, minimal: false);
      expect(body['instructions'], 's');
      expect(body['input'], 'u');
      expect(body.containsKey('messages'), isFalse);
      expect(body.containsKey('thinking'), isFalse);
    });

    test('reads chat and responses replies', () {
      expect(
        LlmPageTranslator.replyText(LlmApi.chat, {
          'choices': [
            {
              'message': {'content': 'hi'}
            }
          ]
        }),
        'hi',
      );
      expect(LlmPageTranslator.replyText(LlmApi.responses, {'output_text': 'a'}), 'a');
      expect(
        LlmPageTranslator.replyText(LlmApi.responses, {
          'output': [
            {'type': 'reasoning', 'summary': []},
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'b'},
                {'type': 'output_text', 'text': 'c'},
              ]
            },
          ]
        }),
        'bc',
      );
    });
  });

  group('against a local server', () {
    late HttpServer server;
    final List<String> hits = [];
    final List<Map<String, dynamic>> bodies = [];

    setUp(() async {
      hits.clear();
      bodies.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final Map<String, dynamic> body = jsonDecode(await utf8.decoder.bind(request).join());
        hits.add(request.uri.path);
        bodies.add(body);
        final HttpResponse res = request.response..headers.contentType = ContentType.json;
        void reply(int status, Object json) {
          res.statusCode = status;
          res.write(jsonEncode(json));
        }

        if (request.headers.value('authorization') != 'Bearer good') {
          reply(401, {
            'error': {'message': 'Incorrect API key provided'}
          });
        } else if (request.uri.path == '/chat/completions') {
          // like an API that refuses unknown parameters
          if (body.containsKey('thinking')) {
            reply(400, {
              'error': {'message': 'Unrecognized request argument supplied: thinking'}
            });
          } else {
            reply(200, {
              'choices': [
                {
                  'message': {'content': '{"translations":[{"id":0,"text":"你好"}]}'}
                }
              ]
            });
          }
        } else if (request.uri.path == '/v1/responses') {
          reply(200, {
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': '{"translations":[{"id":0,"text":"早"}]}'}
                ]
              }
            ]
          });
        } else {
          reply(404, {
            'error': {'message': 'Not found'}
          });
        }
        await res.close();
      });
    });

    tearDown(() => server.close(force: true));

    LlmPageTranslator translator(String url, String key) => LlmPageTranslator(
          baseUrl: url,
          apiKey: key,
          model: 'm',
          disableThinking: true,
          timeout: const Duration(seconds: 5),
        );

    test('bare host falls back from /v1 and retries without rejected parameters', () async {
      final Map<int, String> result = await translator('http://127.0.0.1:${server.port}', 'good').translate({0: 'こんにちは'}, 'zh-CN');
      expect(result, {0: '你好'});
      expect(hits, ['/v1/chat/completions', '/chat/completions', '/chat/completions']);
      expect(bodies.last.containsKey('thinking'), isFalse);
    });

    test('full chat completions URL is not doubled', () async {
      await translator('http://127.0.0.1:${server.port}/chat/completions', 'good').ping();
      expect(hits.first, '/chat/completions');
    });

    test('responses URL', () async {
      final Map<int, String> result = await translator('http://127.0.0.1:${server.port}/v1/responses', 'good').translate({0: 'おはよう'}, 'zh-CN');
      expect(result, {0: '早'});
      expect(hits, ['/v1/responses']);
    });

    test('a bad key reports the status and the API message', () async {
      await expectLater(
        translator('http://127.0.0.1:${server.port}/chat/completions', 'bad').ping(),
        throwsA(isA<LlmApiException>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.toString(), 'text', contains('Incorrect API key provided'))),
      );
      expect(hits, ['/chat/completions']);
    });
  });
}
