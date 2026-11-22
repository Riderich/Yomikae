import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/on_device_translation/ocr_engine.dart';
import 'package:jhentai/src/service/on_device_translation/page_analysis.dart';
import 'package:jhentai/src/service/on_device_translation/page_eraser.dart';

/// Runs the real PP-OCR models on a sample page. Needs the ONNX Runtime library
/// on the library path and a directory with the models and a raw RGBA page:
///
///   JHENTAI_OCR_TEST_DIR=<dir> flutter test test/on_device_ocr_engine_test.dart
///
/// On Windows also set JHENTAI_ORT_DLL to an onnxruntime.dll of version 1.18 or newer.
/// <dir> contains det.onnx, rec.onnx, page.rgba and page.size ("width height").
void main() {
  final String? dir = Platform.environment['JHENTAI_OCR_TEST_DIR'];

  test('detects and reads the speech bubbles of a manga page', () async {
    final List<String> size = File('$dir/page.size').readAsStringSync().trim().split(' ');
    final int width = int.parse(size[0]), height = int.parse(size[1]);
    final Uint8List rgba = File('$dir/page.rgba').readAsBytesSync();
    final List<String> dictionary = File('assets/translation/ppocrv6_dict.txt').readAsLinesSync();

    // Windows ships an old onnxruntime.dll in System32 that wins the DLL search;
    // preloading a recent one by absolute path makes later loads by name reuse it.
    final String? dll = Platform.environment['JHENTAI_ORT_DLL'];
    if (dll != null) {
      DynamicLibrary.open(dll);
    }
    final OcrEngine engine = OcrEngine();
    await engine.start(detectorPath: '$dir/det.onnx', recognizerPath: '$dir/rec.onnx', dictionary: dictionary);
    final Stopwatch watch = Stopwatch()..start();
    final OcrResult result = await engine.analyze(rgba, width, height);
    // ignore: avoid_print
    print('analyze ${watch.elapsedMilliseconds}ms (detection ${result.detection.inMilliseconds}ms, '
        'recognition ${result.recognition.inMilliseconds}ms)');
    for (final TextBlock b in result.blocks) {
      // ignore: avoid_print
      print('${b.skip ? 'SKIP' : 'TEXT'} [${b.x0},${b.y0},${b.x1},${b.y1}] ${b.vertical ? 'V' : 'H'} '
          'conf=${b.confidence.toStringAsFixed(2)} ${b.text}');
    }
    await engine.dispose();
    final String? dump = Platform.environment['JHENTAI_OCR_DUMP'];
    if (dump != null) {
      File(dump).writeAsStringSync(jsonEncode(result.blocks.where((b) => !b.skip).map((b) => b.toJson()).toList()));
    }

    final List<String> texts = result.blocks.where((b) => !b.skip).map((b) => b.text).toList();
    expect(texts, contains('でもあんなまぐれはもう一生ない気もする…'));
    expect(texts, contains('またパチンコやろうかな'));
    expect(texts, contains('実家からの手紙…？'));
    expect(texts.any((t) => t.contains('気イ変になるんじゃなかろうか')), isTrue);
    // sound effects are not translated
    expect(result.blocks.where((b) => b.skip).length, greaterThanOrEqualTo(5));

    // erasing a bubble leaves only its white background inside the text boxes
    final TextBlock bubble = result.blocks.firstWhere((b) => b.text == 'またパチンコやろうかな');
    final int color = eraseBlock(rgba, width, height, bubble);
    expect(luminance(color), greaterThan(240));
  }, skip: dir == null ? 'set JHENTAI_OCR_TEST_DIR to run' : false, timeout: const Timeout(Duration(minutes: 2)));
}
