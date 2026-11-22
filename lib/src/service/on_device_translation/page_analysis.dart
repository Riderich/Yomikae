import 'dart:math';
import 'dart:typed_data';

/// Pure logic of the on-device manga OCR pipeline: DB post-processing of the
/// PP-OCR detector output, grouping text lines into speech bubbles, reading
/// order, recognizer input preparation and CTC decoding.
///
/// Nothing here touches ONNX Runtime or dart:ui so it can be unit tested and
/// run inside a background isolate.

/// An axis-aligned text line (a column for vertical Japanese) in image pixels.
class TextLine {
  final int x0;
  final int y0;
  final int x1;
  final int y1;

  const TextLine(this.x0, this.y0, this.x1, this.y1);

  int get width => x1 - x0;

  int get height => y1 - y0;

  bool get vertical => height > width * 1.2;

  /// Column width for vertical text, line height for horizontal text: roughly the font size.
  int get thickness => vertical ? width : height;

  List<int> toList() => [x0, y0, x1, y1];

  factory TextLine.fromList(List<dynamic> v) => TextLine(v[0] as int, v[1] as int, v[2] as int, v[3] as int);

  @override
  String toString() => 'TextLine($x0,$y0,$x1,$y1)';
}

/// A group of lines that belong to one speech bubble / caption.
class TextBlock {
  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final bool vertical;

  /// Every detected line, furigana included (used for erasing).
  final List<TextLine> lines;

  /// Lines to recognize, furigana removed, in reading order.
  final List<TextLine> ocrLines;

  String text;
  double confidence;

  /// Sound effects, decorations and noise that should be left untouched.
  bool skip;

  TextBlock({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.vertical,
    required this.lines,
    required this.ocrLines,
    this.text = '',
    this.confidence = 0,
    this.skip = false,
  });

  int get width => x1 - x0;

  int get height => y1 - y0;

  /// Median thickness of the recognized lines: the original font size.
  int get fontSize {
    if (ocrLines.isEmpty) {
      return 0;
    }
    final List<int> sizes = ocrLines.map((l) => l.thickness).toList()..sort();
    return sizes[sizes.length ~/ 2];
  }

  Map<String, dynamic> toJson() => {
        'box': [x0, y0, x1, y1],
        'vertical': vertical,
        'lines': lines.map((l) => l.toList()).toList(),
        'ocrLines': ocrLines.map((l) => l.toList()).toList(),
        'text': text,
        'confidence': confidence,
        'skip': skip,
      };

  factory TextBlock.fromJson(Map<String, dynamic> json) {
    final List<dynamic> box = json['box'];
    return TextBlock(
      x0: box[0],
      y0: box[1],
      x1: box[2],
      y1: box[3],
      vertical: json['vertical'],
      lines: (json['lines'] as List).map((l) => TextLine.fromList(l)).toList(),
      ocrLines: (json['ocrLines'] as List).map((l) => TextLine.fromList(l)).toList(),
      text: json['text'],
      confidence: (json['confidence'] as num).toDouble(),
      skip: json['skip'],
    );
  }
}

// ----------------------------------------------------------------- detection

/// PP-OCR DB post-process constants (from the model's inference.yml).
const double dbThreshold = 0.2;
const double dbBoxThreshold = 0.45;
const double dbUnclipRatio = 1.4;

/// Size of the detector input for an image of [width] x [height]: the long side
/// limited to [maxSide], both sides multiples of 32.
(int, int) detectorInputSize(int width, int height, int maxSide) {
  final double scale = min(1.0, maxSide / max(width, height));
  int round32(double v) => max(32, (v / 32).round() * 32);
  return (round32(width * scale), round32(height * scale));
}

/// Turns the detector probability map ([mapWidth] x [mapHeight]) into text line
/// boxes in original image coordinates ([imageWidth] x [imageHeight]).
///
/// Equivalent to PaddleOCR's DBPostProcess with axis-aligned boxes: threshold,
/// connected components, mean-score filter, then "unclip" by
/// `area * ratio / perimeter`.
List<TextLine> linesFromProbabilityMap(
  Float32List prob,
  int mapWidth,
  int mapHeight,
  int imageWidth,
  int imageHeight,
) {
  final int n = mapWidth * mapHeight;
  final Int32List labels = Int32List(n); // 0 = unvisited/background, >0 = component id
  final Int32List stack = Int32List(n);
  final double sx = imageWidth / mapWidth;
  final double sy = imageHeight / mapHeight;
  final List<TextLine> lines = [];
  int nextLabel = 0;

  for (int start = 0; start < n; start++) {
    if (labels[start] != 0 || prob[start] <= dbThreshold) {
      continue;
    }
    nextLabel++;
    int top = 0;
    stack[top++] = start;
    labels[start] = nextLabel;
    int minX = mapWidth, minY = mapHeight, maxX = 0, maxY = 0;
    int area = 0, perimeter = 0;
    double scoreSum = 0;

    while (top > 0) {
      final int p = stack[--top];
      final int x = p % mapWidth;
      final int y = p ~/ mapWidth;
      area++;
      scoreSum += prob[p];
      minX = min(minX, x);
      maxX = max(maxX, x);
      minY = min(minY, y);
      maxY = max(maxY, y);

      bool boundary = false;
      // 4-neighbourhood
      for (int k = 0; k < 4; k++) {
        final int nx = k == 0 ? x - 1 : (k == 1 ? x + 1 : x);
        final int ny = k == 2 ? y - 1 : (k == 3 ? y + 1 : y);
        if (nx < 0 || ny < 0 || nx >= mapWidth || ny >= mapHeight) {
          boundary = true;
          continue;
        }
        final int q = ny * mapWidth + nx;
        if (prob[q] <= dbThreshold) {
          boundary = true;
          continue;
        }
        if (labels[q] == 0) {
          labels[q] = nextLabel;
          stack[top++] = q;
        }
      }
      if (boundary) {
        perimeter++;
      }
    }

    if (area < 6 || scoreSum / area < dbBoxThreshold) {
      continue;
    }
    final double d = area * dbUnclipRatio / max(perimeter, 1);
    final int x0 = max(0, ((minX - d) * sx).floor());
    final int y0 = max(0, ((minY - d) * sy).floor());
    final int x1 = min(imageWidth, ((maxX + 1 + d) * sx).ceil());
    final int y1 = min(imageHeight, ((maxY + 1 + d) * sy).ceil());
    if (x1 - x0 >= 3 && y1 - y0 >= 3) {
      lines.add(TextLine(x0, y0, x1, y1));
    }
  }
  return lines;
}

// ------------------------------------------------------------------ grouping

/// Luminance (0-255) of the pixel at byte offset [p] of an RGBA buffer.
int _lum(Uint8List rgba, int p) => (rgba[p] * 77 + rgba[p + 1] * 150 + rgba[p + 2] * 29) >> 8;

/// Whether a drawn line (a bubble border, a panel edge) runs through the gap
/// between two text lines, i.e. they belong to different bubbles.
///
/// Looks at the empty strip between the two boxes over the span both cover and
/// counts the scanlines across it that contain strong contrast. A border
/// crosses nearly every scanline; stray furigana or noise only a few.
bool gapHasBorder(Uint8List rgba, int width, TextLine a, TextLine b) {
  final int hGap = max(a.x0, b.x0) - min(a.x1, b.x1);
  final int vGap = max(a.y0, b.y0) - min(a.y1, b.y1);
  final bool sideBySide = hGap >= vGap;
  final int gx0 = sideBySide ? min(a.x1, b.x1) : max(a.x0, b.x0);
  final int gx1 = sideBySide ? max(a.x0, b.x0) : min(a.x1, b.x1);
  final int gy0 = sideBySide ? max(a.y0, b.y0) : min(a.y1, b.y1);
  final int gy1 = sideBySide ? min(a.y1, b.y1) : max(a.y0, b.y0);
  if (gx1 - gx0 < 2 || gy1 - gy0 < 2) {
    return false; // the boxes touch, or share no span to look at
  }

  int scanlines = 0, contrasted = 0;
  final int outer0 = sideBySide ? gy0 : gx0, outer1 = sideBySide ? gy1 : gx1;
  final int inner0 = sideBySide ? gx0 : gy0, inner1 = sideBySide ? gx1 : gy1;
  for (int o = outer0; o < outer1; o++) {
    int lo = 255, hi = 0;
    for (int i = inner0; i < inner1; i++) {
      final int v = _lum(rgba, sideBySide ? (o * width + i) * 4 : (i * width + o) * 4);
      lo = min(lo, v);
      hi = max(hi, v);
    }
    scanlines++;
    if (hi - lo > 90) {
      contrasted++;
    }
  }
  return contrasted >= scanlines * 0.7;
}

bool _linked(TextLine a, TextLine b, bool requireSimilarSize) {
  if (a.vertical != b.vertical && min(min(a.width, a.height), min(b.width, b.height)) > 12) {
    return false;
  }
  final int ta = a.thickness, tb = b.thickness;
  if (requireSimilarSize && min(ta, tb) < max(ta, tb) * 0.65) {
    return false; // different font size: another bubble, or furigana
  }
  final int size = max(min(ta, tb), 8);
  final int gap, overlap;
  if (a.vertical || b.vertical) {
    gap = max(a.x0, b.x0) - min(a.x1, b.x1);
    overlap = min(a.y1, b.y1) - max(a.y0, b.y0);
  } else {
    gap = max(a.y0, b.y0) - min(a.y1, b.y1);
    overlap = min(a.x1, b.x1) - max(a.x0, b.x0);
  }
  return gap < size * 0.9 && overlap > -size * 0.5;
}

/// Groups lines into blocks (one per speech bubble) and orders everything for
/// reading: blocks in manga order (top to bottom, right to left), vertical
/// columns right to left, horizontal lines top to bottom. Furigana (much
/// thinner columns attached to a block) is kept for erasing but not recognized.
///
/// [separated] tells whether something drawn between two lines (see
/// [gapHasBorder]) keeps them apart, so neighbouring bubbles do not merge.
/// Blocks with more lines than a speech bubble ever has (a page of prose, a
/// long caption) are cut into chunks of a few lines, see [splitLargeBlock].
List<TextBlock> groupLines(List<TextLine> lines, int imageHeight, {bool Function(TextLine a, TextLine b)? separated}) {
  bool linked(TextLine a, TextLine b, bool requireSimilarSize) =>
      _linked(a, b, requireSimilarSize) && (separated == null || !separated(a, b));

  final int n = lines.length;
  final List<int> parent = List<int>.generate(n, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  // pass 1: lines of a similar size form blocks
  for (int i = 0; i < n; i++) {
    for (int j = i + 1; j < n; j++) {
      if (linked(lines[i], lines[j], true)) {
        parent[find(i)] = find(j);
      }
    }
  }
  // pass 2: single thin lines (furigana) join an adjacent block of bigger text
  final Map<int, int> groupSizes = {};
  for (int i = 0; i < n; i++) {
    groupSizes.update(find(i), (v) => v + 1, ifAbsent: () => 1);
  }
  for (int i = 0; i < n; i++) {
    if (groupSizes[find(i)]! > 1) {
      continue;
    }
    for (int j = 0; j < n; j++) {
      if (find(j) != find(i) && lines[j].thickness > lines[i].thickness * 1.3 && linked(lines[i], lines[j], false)) {
        parent[find(i)] = find(j);
        break;
      }
    }
  }

  final Map<int, List<TextLine>> groups = {};
  for (int i = 0; i < n; i++) {
    groups.putIfAbsent(find(i), () => []).add(lines[i]);
  }

  final List<TextBlock> blocks = [];
  for (final List<TextLine> ls in groups.values) {
    blocks.addAll(splitLargeBlock(_makeBlock(ls)));
  }

  final int band = max(1, (imageHeight * 0.12).round());
  blocks.sort((a, b) {
    final int row = (a.y0 ~/ band).compareTo(b.y0 ~/ band);
    return row != 0 ? row : b.x1.compareTo(a.x1);
  });
  return blocks;
}

TextBlock _makeBlock(List<TextLine> ls, {bool? vertical}) {
  final bool v = vertical ?? ls.where((l) => l.vertical).length * 2 >= ls.length;
  final List<int> thickness = ls.map((l) => v ? l.width : l.height).toList()..sort();
  final int main = thickness[thickness.length ~/ 2];
  final List<TextLine> ocrLines = ls.where((l) => (v ? l.width : l.height) >= main * 0.6).toList();
  if (v) {
    ocrLines.sort((a, b) => b.x1.compareTo(a.x1));
  } else {
    ocrLines.sort((a, b) => a.y0.compareTo(b.y0));
  }
  return TextBlock(
    x0: ls.map((l) => l.x0).reduce(min),
    y0: ls.map((l) => l.y0).reduce(min),
    x1: ls.map((l) => l.x1).reduce(max),
    y1: ls.map((l) => l.y1).reduce(max),
    vertical: v,
    lines: ls,
    ocrLines: ocrLines,
  );
}

/// More lines than any speech bubble holds: prose, a column, a caption page.
const int maxBubbleLines = 8;

/// Lines per chunk when a large block is cut up.
const int chunkLines = 4;

/// Cuts a block with more than [maxBubbleLines] lines into small chunks so each
/// translation is typeset close to its source and nothing between the text
/// (drawings, other bubbles) is painted over.
///
/// Lines are first regrouped strictly: side by side and overlapping for at
/// least half their length, so stacked tiers of a page of prose separate.
/// Every tier is then cut into runs of at most [chunkLines] lines.
List<TextBlock> splitLargeBlock(TextBlock block) {
  if (block.ocrLines.length <= maxBubbleLines) {
    return [block];
  }
  final bool v = block.vertical;
  int a0(TextLine l) => v ? l.y0 : l.x0;
  int a1(TextLine l) => v ? l.y1 : l.x1;
  int c0(TextLine l) => v ? l.x0 : l.y0;
  int c1(TextLine l) => v ? l.x1 : l.y1;

  final List<TextLine> main = block.ocrLines;
  final int n = main.length;
  final List<int> parent = List<int>.generate(n, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  for (int i = 0; i < n; i++) {
    for (int j = i + 1; j < n; j++) {
      final TextLine a = main[i], b = main[j];
      final int ta = a.thickness, tb = b.thickness;
      if (min(ta, tb) < max(ta, tb) * 0.65) {
        continue;
      }
      final int overlap = min(a1(a), a1(b)) - max(a0(a), a0(b));
      final int gap = max(c0(a), c0(b)) - min(c1(a), c1(b));
      if (overlap >= min(a1(a) - a0(a), a1(b) - a0(b)) * 0.5 && gap < max(min(ta, tb), 8) * 0.9) {
        parent[find(i)] = find(j);
      }
    }
  }
  final Map<int, List<TextLine>> tiers = {};
  for (int i = 0; i < n; i++) {
    tiers.putIfAbsent(find(i), () => []).add(main[i]);
  }

  final List<List<TextLine>> chunks = [];
  for (final List<TextLine> tier in tiers.values) {
    // reading order across the tier: columns right to left, rows top to bottom
    tier.sort((a, b) => v ? c1(b).compareTo(c1(a)) : c0(a).compareTo(c0(b)));
    final int count = (tier.length / chunkLines).ceil();
    final int size = (tier.length / count).ceil();
    for (int i = 0; i < tier.length; i += size) {
      chunks.add(tier.sublist(i, min(tier.length, i + size)));
    }
  }

  // furigana and other thin lines go with the chunk whose lines are nearest
  for (final TextLine extra in block.lines.where((l) => !main.contains(l))) {
    final double cx = (extra.x0 + extra.x1) / 2, cy = (extra.y0 + extra.y1) / 2;
    double best = double.infinity;
    List<TextLine>? target;
    for (final List<TextLine> chunk in chunks) {
      for (final TextLine l in chunk) {
        final double dx = max(0, max(l.x0 - cx, cx - l.x1)), dy = max(0, max(l.y0 - cy, cy - l.y1));
        final double d = dx * dx + dy * dy;
        if (d < best) {
          best = d;
          target = chunk;
        }
      }
    }
    target?.add(extra);
  }

  return chunks.map((ls) => _makeBlock(ls, vertical: v)).toList();
}

// --------------------------------------------------------------- recognition

const int recognizerHeight = 48;

/// Builds the recognizer input `[1, 3, 48, W]` (RGB, normalized to [-1, 1]) for
/// one line of an RGBA image. Vertical columns are rotated 90° counter-clockwise
/// so the text reads left to right, as PP-OCR expects.
(Float32List, int) recognizerInput(Uint8List rgba, int imageWidth, TextLine line) {
  final int lw = line.width, lh = line.height;
  final bool rotate = line.vertical;
  // size of the (possibly rotated) crop
  final int cw = rotate ? lh : lw;
  final int ch = rotate ? lw : lh;
  final int outW = max(16, (recognizerHeight * cw / max(ch, 1)).round());
  final Float32List data = Float32List(3 * recognizerHeight * outW);
  final int plane = recognizerHeight * outW;

  for (int oy = 0; oy < recognizerHeight; oy++) {
    final double cy = (oy + 0.5) * ch / recognizerHeight - 0.5;
    for (int ox = 0; ox < outW; ox++) {
      final double cx = (ox + 0.5) * cw / outW - 0.5;
      // map crop coords back to line coords (rotation: crop(x', y') = line(w-1-y', x'))
      final double lx = rotate ? (lw - 1 - cy) : cx;
      final double ly = rotate ? cx : cy;
      // bilinear sample
      final double fx = (line.x0 + lx).clamp(line.x0.toDouble(), (line.x1 - 1).toDouble());
      final double fy = (line.y0 + ly).clamp(line.y0.toDouble(), (line.y1 - 1).toDouble());
      final int x0 = fx.floor(), y0 = fy.floor();
      final int x1 = min(x0 + 1, line.x1 - 1), y1 = min(y0 + 1, line.y1 - 1);
      final double ax = fx - x0, ay = fy - y0;
      final int p00 = (y0 * imageWidth + x0) * 4;
      final int p01 = (y0 * imageWidth + x1) * 4;
      final int p10 = (y1 * imageWidth + x0) * 4;
      final int p11 = (y1 * imageWidth + x1) * 4;
      for (int c = 0; c < 3; c++) {
        final double top = rgba[p00 + c] * (1 - ax) + rgba[p01 + c] * ax;
        final double bottom = rgba[p10 + c] * (1 - ax) + rgba[p11 + c] * ax;
        final double v = top * (1 - ay) + bottom * ay;
        data[c * plane + oy * outW + ox] = (v / 255.0 - 0.5) / 0.5;
      }
    }
  }
  return (data, outW);
}

/// Greedy CTC decode of `[T, C]` softmax output. Index 0 is the blank, then the
/// dictionary characters, then a space. Returns the text and the probability of
/// each emitted character.
(String, List<double>) ctcDecode(Float32List probs, int steps, int classes, List<String> dictionary) {
  final StringBuffer text = StringBuffer();
  final List<double> scores = [];
  int previous = 0;
  for (int t = 0; t < steps; t++) {
    final int base = t * classes;
    int best = 0;
    double bestScore = probs[base];
    for (int c = 1; c < classes; c++) {
      final double v = probs[base + c];
      if (v > bestScore) {
        bestScore = v;
        best = c;
      }
    }
    if (best != 0 && best != previous) {
      final int index = best - 1;
      text.write(index < dictionary.length ? dictionary[index] : ' ');
      scores.add(bestScore);
    }
    previous = best;
  }
  return (text.toString(), scores);
}

final RegExp _japanese = RegExp(r'[぀-ヿ一-鿿]');

/// Marks blocks that should not be translated: sound effects and drawings read
/// with low confidence, and blocks without real Japanese text.
void markSkippedBlocks(List<TextBlock> blocks) {
  for (final TextBlock block in blocks) {
    final int japanese = _japanese.allMatches(block.text).length;
    block.skip = block.confidence < 0.75 || japanese < 2;
  }
}
