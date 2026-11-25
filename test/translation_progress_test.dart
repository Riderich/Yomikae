import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/pages/read/translation_progress.dart';

void main() {
  final DateTime t0 = DateTime(2026, 1, 1);
  DateTime at(double seconds) => t0.add(Duration(milliseconds: (seconds * 1000).round()));

  test('a range reports done pages, speed and time left', () {
    final TranslationProgress p = TranslationProgress()..add(4);
    p.startPage(0, at(0));
    expect(p.fraction(at(1)), 0);
    expect(p.remaining(at(1)), isNull);

    p.finishPage(seconds: 10, now: at(10));
    p.startPage(1, at(10));
    expect(p.secondsPerPage, 10);
    expect(p.fraction(at(15)), closeTo((1 + 0.5) / 4, 1e-9));
    expect(p.remaining(at(15)), const Duration(seconds: 25));

    // a page translated before counts as done without a time
    p.finishPage(seconds: 20, now: at(30));
    p.finishPage(now: at(30));
    expect(p.secondsPerPage, 15);
    expect(p.done, 3);
    expect(p.running, isTrue);
  });

  test('a lone page is indeterminate, and the bar stays up a moment after', () {
    final TranslationProgress p = TranslationProgress()..add(1);
    p.startPage(5, at(0));
    expect(p.fraction(at(3)), isNull);
    expect(p.visibleAt(at(3)), isTrue);
    p.finishPage(seconds: 8, now: at(8));
    expect(p.running, isFalse);
    expect(p.visibleAt(at(10)), isTrue);
    expect(p.visibleAt(at(12)), isFalse);
  });

  test('stopping a range takes back the pages left; a new start begins at zero', () {
    final TranslationProgress p = TranslationProgress()..add(10);
    p.startPage(0, at(0));
    p.finishPage(seconds: 5, ok: false, now: at(5));
    p.cancel(9, at(5));
    expect(p.total, 1);
    expect(p.running, isFalse);
    expect(p.failed, 1);

    p.add(2);
    expect(p.total, 2);
    expect(p.done, 0);
    expect(p.failed, 0);
    expect(p.secondsPerPage, isNull);
  });

  test('pages added while running join the same count', () {
    final TranslationProgress p = TranslationProgress()..add(1);
    p.add(1);
    expect(p.total, 2);
  });
}
