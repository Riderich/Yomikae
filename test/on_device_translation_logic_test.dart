import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/on_device_translation/llm_page_translator.dart';
import 'package:jhentai/src/service/on_device_translation/page_analysis.dart';
import 'package:jhentai/src/service/on_device_translation/page_eraser.dart';

void main() {
  group('detection post-processing', () {
    test('detector input keeps aspect ratio in multiples of 32', () {
      expect(detectorInputSize(1654, 1170, 1280), (1280, 896));
      expect(detectorInputSize(800, 1200, 1280), (800, 1216));
    });

    test('connected regions of the probability map become unclipped line boxes', () {
      const int w = 40, h = 20;
      final Float32List prob = Float32List(w * h);
      // a 4 x 12 vertical stroke and a lone noisy pixel
      for (int y = 4; y < 16; y++) {
        for (int x = 10; x < 14; x++) {
          prob[y * w + x] = 0.9;
        }
      }
      prob[2 * w + 30] = 0.9;

      final List<TextLine> lines = linesFromProbabilityMap(prob, w, h, w * 2, h * 2);
      expect(lines, hasLength(1));
      final TextLine l = lines.single;
      // map coordinates x 2, grown by the DB unclip distance
      expect(l.x0, lessThan(20));
      expect(l.x1, greaterThan(28));
      expect(l.y0, lessThan(8));
      expect(l.y1, greaterThan(32));
      expect(l.vertical, isTrue);
    });

    test('low-confidence regions are dropped', () {
      const int w = 10, h = 10;
      final Float32List prob = Float32List(w * h);
      for (int i = 0; i < 30; i++) {
        prob[i] = 0.3; // above the pixel threshold, below the box threshold
      }
      expect(linesFromProbabilityMap(prob, w, h, w, h), isEmpty);
    });
  });

  group('grouping', () {
    test('columns of one bubble are read right to left, furigana is not read', () {
      final List<TextLine> lines = [
        const TextLine(100, 10, 120, 110), // first column (rightmost)
        const TextLine(122, 10, 130, 40), // furigana next to it
        const TextLine(76, 10, 96, 90),
        const TextLine(52, 10, 72, 60),
      ];
      final List<TextBlock> blocks = groupLines(lines, 1000);
      expect(blocks, hasLength(1));
      final TextBlock b = blocks.single;
      expect(b.vertical, isTrue);
      expect(b.lines, hasLength(4));
      expect(b.ocrLines.map((l) => l.x0), [100, 76, 52]);
      expect(b.fontSize, 20);
      expect([b.x0, b.y0, b.x1, b.y1], [52, 10, 130, 110]);
    });

    test('a nearby bubble with a smaller font stays separate', () {
      final List<TextBlock> blocks = groupLines([
        const TextLine(100, 10, 120, 110),
        const TextLine(76, 10, 96, 110),
        const TextLine(60, 30, 72, 80), // 12px text right next to 20px text
        const TextLine(46, 30, 58, 80),
      ], 1000);
      expect(blocks, hasLength(2));
    });

    test('blocks are ordered top to bottom, then right to left', () {
      final List<TextBlock> blocks = groupLines([
        const TextLine(10, 10, 30, 100), // top left
        const TextLine(500, 10, 520, 100), // top right
        const TextLine(300, 600, 320, 700), // bottom
      ], 1000);
      expect(blocks.map((b) => b.x0), [500, 10, 300]);
    });
  });

  group('recognition', () {
    test('CTC decode collapses repeats and drops blanks', () {
      const List<String> dictionary = ['あ', 'い'];
      // classes: blank, あ, い, space
      final Float32List probs = Float32List.fromList([
        0.1, 0.8, 0.05, 0.05, // あ
        0.1, 0.8, 0.05, 0.05, // あ (repeat)
        0.9, 0.05, 0.03, 0.02, // blank
        0.1, 0.7, 0.1, 0.1, // あ again after blank
        0.1, 0.1, 0.6, 0.2, // い
      ]);
      final (String text, List<double> scores) = ctcDecode(probs, 5, 4, dictionary);
      expect(text, 'ああい');
      expect(scores, hasLength(3));
    });

    test('vertical lines are rotated so the top of the column ends up on the left', () {
      const int w = 4, h = 12;
      final Uint8List rgba = Uint8List(w * h * 4);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final int v = y < h / 2 ? 0 : 255; // top half black, bottom half white
          rgba.setAll((y * w + x) * 4, [v, v, v, 255]);
        }
      }
      final (Float32List input, int inputWidth) = recognizerInput(rgba, w, const TextLine(0, 0, w, h));
      expect(inputWidth, 144); // 12 x 4 rotated, scaled to height 48
      // left of the line is the top of the column (black = -1), right is white (+1)
      expect(input[24 * inputWidth + 5], closeTo(-1, 1e-6));
      expect(input[24 * inputWidth + inputWidth - 5], closeTo(1, 1e-6));
    });

    test('sound effects and noise are skipped', () {
      TextBlock block(String text, double confidence) => TextBlock(
            x0: 0, y0: 0, x1: 1, y1: 1, vertical: true, lines: const [], ocrLines: const [], text: text, confidence: confidence);
      final List<TextBlock> blocks = [block('またパチンコやろうかな', 0.97), block('ビリ', 0.4), block('00', 0.98), block('…', 0.9)];
      markSkippedBlocks(blocks);
      expect(blocks.map((b) => b.skip), [false, true, true, true]);
    });
  });

  test('erasing paints the text boxes with the surrounding colour', () {
    const int w = 30, h = 30;
    final Uint8List rgba = Uint8List(w * h * 4);
    for (int i = 0; i < w * h; i++) {
      rgba.setAll(i * 4, [250, 248, 240, 255]); // off-white bubble
    }
    for (int y = 10; y < 20; y++) {
      for (int x = 12; x < 16; x++) {
        rgba.setAll((y * w + x) * 4, [0, 0, 0, 255]); // black glyphs
      }
    }
    final TextBlock block = TextBlock(
        x0: 11, y0: 9, x1: 17, y1: 21, vertical: true, lines: const [TextLine(11, 9, 17, 21)], ocrLines: const [TextLine(11, 9, 17, 21)]);
    final int color = eraseBlock(rgba, w, h, block);
    expect(color, 0xFFFAF8F0);
    expect(rgba.sublist((15 * w + 13) * 4, (15 * w + 13) * 4 + 3), [250, 248, 240]);
  });

  group('LLM reply parsing', () {
    test('reads the translations object, also inside a code fence', () {
      expect(LlmPageTranslator.parseTranslations('{"translations":[{"id":0,"text":"你好"},{"id":"2","text":" 再见 "}]}'),
          {0: '你好', 2: '再见'});
      expect(LlmPageTranslator.parseTranslations('```json\n{"translations":[{"id":1,"text":"嗯"}]}\n```'), {1: '嗯'});
    });

    test('a reply without JSON is an error', () {
      expect(() => LlmPageTranslator.parseTranslations('sorry'), throwsFormatException);
    });
  });

  group('large blocks and borders', () {
    Uint8List whitePage(int w, int h) => Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);

    test('a border between two columns keeps them in separate bubbles', () {
      const int w = 200, h = 200;
      final Uint8List rgba = whitePage(w, h);
      const TextLine a = TextLine(100, 20, 130, 150), b = TextLine(60, 20, 90, 150);
      expect(gapHasBorder(rgba, w, a, b), isFalse);
      for (int y = 0; y < h; y++) {
        final int p = (y * w + 95) * 4; // a vertical line in the gap
        rgba[p] = rgba[p + 1] = rgba[p + 2] = 0;
      }
      expect(gapHasBorder(rgba, w, a, b), isTrue);
      final List<TextBlock> blocks = groupLines([a, b], h, separated: (x, y) => gapHasBorder(rgba, w, x, y));
      expect(blocks, hasLength(2));
    });

    test('a page of prose is cut into tiers and chunks of a few columns', () {
      final List<TextLine> lines = [
        // two tiers of ten columns, right to left
        for (int i = 0; i < 10; i++) TextLine(1000 - i * 32, 100, 1030 - i * 32, 260),
        for (int i = 0; i < 10; i++) TextLine(1000 - i * 32, 262, 1030 - i * 32, 420),
      ];
      final List<TextBlock> blocks = groupLines(lines, 1200);
      expect(blocks.length, greaterThanOrEqualTo(6));
      expect(blocks.every((b) => b.ocrLines.length <= chunkLines), isTrue);
      // no chunk spans both tiers
      expect(blocks.every((b) => b.y1 <= 262 || b.y0 >= 260), isTrue);
      // first chunk is the top right one
      expect(blocks.first.x1, 1030);
      expect(blocks.first.y0, 100);
    });

    test('the typesetting area grows into the empty bubble but stops at its border', () {
      const int w = 300, h = 300;
      final Uint8List rgba = whitePage(w, h);
      // a bubble border 20 px left of the text
      for (int y = 0; y < h; y++) {
        final int p = (y * w + 80) * 4;
        rgba[p] = rgba[p + 1] = rgba[p + 2] = 0;
      }
      final TextBlock block = TextBlock(x0: 100, y0: 100, x1: 160, y1: 200, vertical: true, lines: const [TextLine(100, 100, 160, 200)], ocrLines: const [TextLine(130, 100, 160, 200), TextLine(100, 100, 130, 200)]);
      final (int x0, int y0, int x1, int y1) = clearArea(rgba, w, h, block, 0xFFFFFFFF, const [(170, 0, 300, 300)], maxGrow: 40);
      expect(x0, greaterThan(80)); // stopped at the border
      expect(x0, lessThan(100));
      expect(x1, lessThanOrEqualTo(170)); // stopped at the neighbouring block
      expect(y0, lessThan(100));
      expect(y1, greaterThan(200));
    });
  });
}
