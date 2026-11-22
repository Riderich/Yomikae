import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/image_translation_service.dart';

void main() {
  test('server stages are split out and the rest is network', () {
    final ImageTranslationTiming timing = ImageTranslationTiming.fromMeasurements(
      fetchSource: const Duration(milliseconds: 800),
      request: const Duration(seconds: 12),
      serverTimingJson:
          '{"engine_wait":0.5,"detection":1.0,"ocr":0.5,"textline_merge":0.1,"translating":6.0,"inpainting":2.0,"rendering":0.4,"finished":0.1,"engine":10.6,"adapter_total":10.7}',
    );

    expect(timing.total, closeTo(12.8, 1e-9));
    expect(timing.parts[ImageTranslationTiming.fetch], closeTo(0.8, 1e-9));
    expect(timing.parts[ImageTranslationTiming.network], closeTo(1.3, 1e-9));
    expect(timing.parts[ImageTranslationTiming.queue], closeTo(0.5, 1e-9));
    expect(timing.parts[ImageTranslationTiming.translating], closeTo(6.0, 1e-9));
    expect(timing.parts[ImageTranslationTiming.inpainting], closeTo(2.0, 1e-9));
    // textline_merge + finished + adapter overhead
    expect(timing.parts[ImageTranslationTiming.other], closeTo(0.3, 1e-9));
    final double sum = timing.parts.values.fold(0, (a, b) => a + b);
    expect(sum, closeTo(timing.total, 1e-9));
  });

  test('old adapter without timing header reports server time as a whole', () {
    final ImageTranslationTiming timing = ImageTranslationTiming.fromMeasurements(
      fetchSource: const Duration(seconds: 1),
      request: const Duration(seconds: 20),
    );

    expect(timing.parts, {
      ImageTranslationTiming.fetch: 1.0,
      ImageTranslationTiming.server: 20.0,
    });
  });

  test('engine without streaming reports engine time as server time', () {
    final ImageTranslationTiming timing = ImageTranslationTiming.fromMeasurements(
      fetchSource: Duration.zero,
      request: const Duration(seconds: 10),
      serverTimingJson: '{"engine":9.0,"adapter_total":9.2}',
    );

    expect(timing.parts[ImageTranslationTiming.server], closeTo(9.2, 1e-9));
    expect(timing.parts[ImageTranslationTiming.network], closeTo(0.8, 1e-9));
    expect(timing.parts.containsKey(ImageTranslationTiming.other), isFalse);
  });

  test('average and summary list the slowest part first', () {
    final ImageTranslationTiming? average = ImageTranslationTiming.average([
      const ImageTranslationTiming(total: 10, parts: {'a': 2, 'b': 8}),
      const ImageTranslationTiming(total: 20, parts: {'a': 4, 'b': 16}),
    ]);

    expect(average!.total, 15);
    expect(average.parts, {'a': 3, 'b': 12});
    expect(average.summary(), endsWith('b 12.0 · a 3.0'));
    expect(ImageTranslationTiming.average([]), isNull);
  });
}
