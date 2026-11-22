import 'dart:math';
import 'dart:typed_data';

import 'page_analysis.dart';

/// Removes the original text of a block from an RGBA image by painting its line
/// boxes with the bubble's background colour.
///
/// The background colour is the per-channel median of a ring of pixels around
/// the text (inside the padded block box but outside every line box). Speech
/// bubbles are almost always flat, so this matches what an inpainting model
/// would produce there at a tiny fraction of the cost.
///
/// Returns the colour used, as `0xAARRGGBB`.
int eraseBlock(Uint8List rgba, int width, int height, TextBlock block, {int ring = 6}) {
  final int bx0 = max(0, block.x0 - ring), by0 = max(0, block.y0 - ring);
  final int bx1 = min(width, block.x1 + ring), by1 = min(height, block.y1 + ring);
  final int bw = bx1 - bx0, bh = by1 - by0;

  // mask of text pixels within the padded box
  final Uint8List mask = Uint8List(bw * bh);
  for (final TextLine l in block.lines) {
    final int lx0 = max(l.x0, bx0) - bx0, lx1 = min(l.x1, bx1) - bx0;
    if (lx1 <= lx0) {
      continue;
    }
    for (int y = max(l.y0, by0); y < min(l.y1, by1); y++) {
      mask.fillRange((y - by0) * bw + lx0, (y - by0) * bw + lx1, 1);
    }
  }

  final List<Int32List> histograms = List.generate(3, (_) => Int32List(256));
  int samples = 0;
  for (int y = 0; y < bh; y++) {
    for (int x = 0; x < bw; x++) {
      if (mask[y * bw + x] != 0) {
        continue;
      }
      final int p = ((by0 + y) * width + bx0 + x) * 4;
      histograms[0][rgba[p]]++;
      histograms[1][rgba[p + 1]]++;
      histograms[2][rgba[p + 2]]++;
      samples++;
    }
  }

  int median(Int32List histogram) {
    if (samples == 0) {
      return 255;
    }
    int seen = 0;
    for (int v = 0; v < 256; v++) {
      seen += histogram[v];
      if (seen * 2 >= samples) {
        return v;
      }
    }
    return 255;
  }

  final int r = median(histograms[0]), g = median(histograms[1]), b = median(histograms[2]);
  for (int y = 0; y < bh; y++) {
    for (int x = 0; x < bw; x++) {
      if (mask[y * bw + x] == 0) {
        continue;
      }
      final int p = ((by0 + y) * width + bx0 + x) * 4;
      rgba[p] = r;
      rgba[p + 1] = g;
      rgba[p + 2] = b;
      rgba[p + 3] = 255;
    }
  }
  return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// Perceived brightness (0-255) of a `0xAARRGGBB` colour.
double luminance(int argb) => 0.299 * ((argb >> 16) & 0xFF) + 0.587 * ((argb >> 8) & 0xFF) + 0.114 * (argb & 0xFF);

/// An axis-aligned rectangle in image pixels: x0, y0, x1, y1 (end exclusive).
typedef PixelRect = (int, int, int, int);

bool _overlaps(PixelRect a, PixelRect b) => a.$1 < b.$3 && b.$1 < a.$3 && a.$2 < b.$4 && b.$2 < a.$4;

/// The room the translation of [block] may use on the erased page: the text box
/// trimmed where a bubble border cuts into it, then grown side by side while the
/// new strip is plain [background] and stays clear of [obstacles] (the other
/// translated blocks), by at most [maxGrow] pixels per side.
///
/// This keeps the translation inside its bubble instead of running over the
/// border, while still using the empty bubble space around the original text.
PixelRect clearArea(
  Uint8List rgba,
  int width,
  int height,
  TextBlock block,
  int background,
  List<PixelRect> obstacles, {
  required int maxGrow,
  int step = 2,
}) {
  final double bgLum = luminance(background);

  /// Whether the strip has (almost) nothing but background.
  bool plain(PixelRect r) {
    final int x0 = max(0, r.$1), y0 = max(0, r.$2), x1 = min(width, r.$3), y1 = min(height, r.$4);
    if (x1 <= x0 || y1 <= y0) {
      return false;
    }
    int total = 0, off = 0;
    for (int y = y0; y < y1; y++) {
      for (int x = x0; x < x1; x++) {
        final int p = (y * width + x) * 4;
        final double lum = 0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2];
        total++;
        if ((lum - bgLum).abs() > 50) {
          off++;
        }
      }
    }
    return off <= total * 0.01;
  }

  int x0 = block.x0, y0 = block.y0, x1 = block.x1, y1 = block.y1;

  // trim edges a border runs along (unclipped line boxes can reach past it)
  final int maxTrim = max(2, block.fontSize ~/ 3);
  for (int t = 0; t < maxTrim && x1 - x0 > step * 4 && !plain((x0, y0, x0 + step, y1)); t += step) {
    x0 += step;
  }
  for (int t = 0; t < maxTrim && x1 - x0 > step * 4 && !plain((x1 - step, y0, x1, y1)); t += step) {
    x1 -= step;
  }
  for (int t = 0; t < maxTrim && y1 - y0 > step * 4 && !plain((x0, y0, x1, y0 + step)); t += step) {
    y0 += step;
  }
  for (int t = 0; t < maxTrim && y1 - y0 > step * 4 && !plain((x0, y1 - step, x1, y1)); t += step) {
    y1 -= step;
  }

  // grow all four sides in turn so the area stays centred on the text
  bool free(PixelRect strip) => strip.$1 >= 0 && strip.$2 >= 0 && strip.$3 <= width && strip.$4 <= height && !obstacles.any((o) => _overlaps(o, strip)) && plain(strip);
  bool left = true, right = true, top = true, bottom = true;
  for (int grown = 0; grown < maxGrow && (left || right || top || bottom); grown += step) {
    if (left && free((x0 - step, y0, x0, y1))) {
      x0 -= step;
    } else {
      left = false;
    }
    if (right && free((x1, y0, x1 + step, y1))) {
      x1 += step;
    } else {
      right = false;
    }
    if (top && free((x0, y0 - step, x1, y0))) {
      y0 -= step;
    } else {
      top = false;
    }
    if (bottom && free((x0, y1, x1, y1 + step))) {
      y1 += step;
    } else {
      bottom = false;
    }
  }
  return (x0, y0, x1, y1);
}
