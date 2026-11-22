import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'page_analysis.dart';
import 'page_eraser.dart';

/// A translated block to draw.
class RenderItem {
  final TextBlock block;
  final String text;
  final int backgroundColor;

  const RenderItem(this.block, this.text, this.backgroundColor);
}

/// Draws translations onto an (already erased) page with dart:ui and encodes
/// the result as PNG. Must run on the root isolate.
class PageRenderer {
  /// Only set by tests, which have no CJK system font.
  static String? _fontFamily;

  /// Punctuation drawn turned by 90° in vertical text (brackets, dashes, ellipses).
  ///
  /// Turning the normal glyph instead of using the Unicode vertical forms works
  /// with every font; many fonts lack the vertical forms and would show boxes.
  static const Set<String> _turned = {
    '…', '⋯', '‥', '—', '―', '－', '-', 'ー', '~', '～', '〜', '（', '）', '(', ')',
    '「', '」', '『', '』', '【', '】', '《', '》', '〈', '〉', '［', '］', '：', '；',
  };

  /// Punctuation that sits in the top right corner of its cell in vertical text.
  static const Set<String> _raised = {'，', '、', '。', '．', ',', '.'};

  static Future<Uint8List> render(Uint8List rgba, int width, int height, List<RenderItem> items, {required bool verticalAllowed, String? fontFamily}) async {
    _fontFamily = fontFamily;
    final ui.Image page = await _imageFromPixels(rgba, width, height);
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawImage(page, Offset.zero, Paint());

    // translations never take room from another block's text
    final List<PixelRect> taken = [for (final RenderItem item in items) (item.block.x0, item.block.y0, item.block.x1, item.block.y1)];
    for (int i = 0; i < items.length; i++) {
      final RenderItem item = items[i];
      final TextBlock block = item.block;
      final PixelRect box = taken[i];
      final PixelRect clear = clearArea(
        rgba,
        width,
        height,
        block,
        item.backgroundColor,
        [...taken.take(i), ...taken.skip(i + 1)],
        maxGrow: max(4, block.fontSize),
      );
      taken[i] = clear;
      // keep the outline stroke off the bubble border
      final double inset = max(1, block.fontSize * 0.08);
      final Rect area = Rect.fromLTRB(clear.$1 + inset, clear.$2 + inset, clear.$3 - inset, clear.$4 - inset);
      if (area.width < 4 || area.height < 4) {
        taken[i] = box;
        continue;
      }
      final bool darkBackground = luminance(item.backgroundColor) < 110;
      final Color textColor = darkBackground ? const Color(0xFFFFFFFF) : const Color(0xFF111111);
      final Color outline = Color(item.backgroundColor);
      // keep vertical source text vertical unless the area is clearly wide
      if (verticalAllowed && block.vertical && area.height >= area.width * 0.6) {
        _drawVertical(canvas, area, item.text, block.fontSize.toDouble(), textColor, outline);
      } else {
        _drawHorizontal(canvas, area, item.text, block.fontSize.toDouble(), textColor, outline);
      }
    }

    final ui.Image result = await recorder.endRecording().toImage(width, height);
    page.dispose();
    final ByteData? png = await result.toByteData(format: ui.ImageByteFormat.png);
    result.dispose();
    if (png == null) {
      throw StateError('Failed to encode translated page');
    }
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  }

  static Future<ui.Image> _imageFromPixels(Uint8List rgba, int width, int height) {
    final Completer<ui.Image> completer = Completer();
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  static TextStyle _style(double size, Color color, {Paint? foreground}) => TextStyle(
        fontSize: size,
        height: 1.15,
        color: foreground == null ? color : null,
        foreground: foreground,
        fontWeight: FontWeight.w600,
        fontFamily: _fontFamily,
      );

  static Paint _stroke(double size, Color color) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = max(1.5, size * 0.18)
    ..strokeJoin = StrokeJoin.round
    ..color = color;

  /// Largest font size, between 6 and the original text size, for which [fits] holds.
  static double _fitSize(double originalSize, Rect area, bool Function(double size) fits) {
    double lo = 6, hi = max(lo, min(originalSize, min(area.width, area.height)));
    if (fits(hi)) {
      return hi;
    }
    for (int i = 0; i < 12; i++) {
      final double mid = (lo + hi) / 2;
      if (fits(mid)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static void _drawHorizontal(Canvas canvas, Rect area, String text, double originalSize, Color color, Color outline) {
    TextPainter painter(double size, {Paint? foreground}) => TextPainter(
          text: TextSpan(text: text, style: _style(size, color, foreground: foreground)),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: area.width);

    final double size = _fitSize(originalSize, area, (s) {
      final TextPainter p = painter(s);
      return p.height <= area.height && p.width <= area.width + 0.5;
    });
    final TextPainter fill = painter(size);
    final Offset offset = Offset(area.left + (area.width - fill.width) / 2, area.top + (area.height - fill.height) / 2);
    painter(size, foreground: _stroke(size, outline)).paint(canvas, offset);
    fill.paint(canvas, offset);
  }

  static void _drawVertical(Canvas canvas, Rect area, String text, double originalSize, Color color, Color outline) {
    final List<String> chars = text.replaceAll('\n', '').characters.toList();
    if (chars.isEmpty) {
      return;
    }
    const double lineGap = 1.12; // column pitch relative to font size
    const double charGap = 1.02; // glyph pitch along a column

    bool fits(double s) {
      final int perColumn = max(1, (area.height / (s * charGap)).floor());
      final int columns = (chars.length / perColumn).ceil();
      return columns * s * lineGap <= area.width + 0.5;
    }

    final double size = _fitSize(originalSize, area, fits);
    final int perColumn = max(1, (area.height / (size * charGap)).floor());
    final int columns = (chars.length / perColumn).ceil();
    // balance the columns instead of leaving a short last one
    final int balanced = (chars.length / columns).ceil();
    final double totalWidth = columns * size * lineGap;
    final double columnHeight = min(balanced, chars.length) * size * charGap;
    final double right = area.left + (area.width + totalWidth) / 2;
    final double top = area.top + (area.height - columnHeight) / 2;

    for (int i = 0; i < chars.length; i++) {
      final int column = i ~/ balanced;
      final int row = i % balanced;
      final double cx = right - (column + 0.5) * size * lineGap;
      final double cy = top + (row + 0.5) * size * charGap;
      final String char = chars[i];
      for (final Paint? foreground in [_stroke(size, outline), null]) {
        final TextPainter p = TextPainter(
          text: TextSpan(text: char, style: _style(size, color, foreground: foreground)),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas.save();
        canvas.translate(cx, cy);
        if (_turned.contains(char)) {
          canvas.rotate(pi / 2);
        } else if (_raised.contains(char)) {
          // horizontal commas and full stops sit bottom left; vertical ones top right
          canvas.translate(size * 0.6, -size * 0.6);
        }
        p.paint(canvas, Offset(-p.width / 2, -p.height / 2));
        canvas.restore();
      }
    }
  }
}
