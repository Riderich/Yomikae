import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/on_device_translation/page_analysis.dart';
import 'package:jhentai/src/service/on_device_translation/page_eraser.dart';
import 'package:jhentai/src/service/on_device_translation/page_renderer.dart';

/// Erases and typesets a page so the result can be inspected by eye.
///
///   JHENTAI_RENDER_TEST_DIR=<dir> JHENTAI_RENDER_FONT=<cjk .ttf> flutter test test/on_device_page_renderer_test.dart
///
/// <dir> holds page.rgba / page.size (see on_device_ocr_engine_test.dart) and
/// blocks.json (TextBlock.toJson list with a "translation" field); the result
/// is written to <dir>/rendered.png.
void main() {
  final String? dir = Platform.environment['JHENTAI_RENDER_TEST_DIR'];
  final String? font = Platform.environment['JHENTAI_RENDER_FONT'];

  testWidgets('typesets translations into erased bubbles', (tester) async {
    await tester.runAsync(() async {
      final FontLoader loader = FontLoader('TestCJK')..addFont(Future.value(ByteData.sublistView(File(font!).readAsBytesSync())));
      await loader.load();

      final List<String> size = File('$dir/page.size').readAsStringSync().trim().split(' ');
      final int width = int.parse(size[0]), height = int.parse(size[1]);
      final Uint8List rgba = File('$dir/page.rgba').readAsBytesSync();
      final List<dynamic> json = jsonDecode(File('$dir/blocks.json').readAsStringSync()) as List<dynamic>;

      final List<RenderItem> items = [];
      for (final dynamic j in json) {
        final TextBlock block = TextBlock.fromJson(Map<String, dynamic>.from(j as Map));
        items.add(RenderItem(block, j['translation'] as String, eraseBlock(rgba, width, height, block)));
      }
      final Uint8List png = await PageRenderer.render(rgba, width, height, items, verticalAllowed: true, fontFamily: 'TestCJK');
      File('$dir/rendered.png').writeAsBytesSync(png);
      expect(png.sublist(1, 4), 'PNG'.codeUnits);
    });
  }, skip: dir == null || font == null);
}

