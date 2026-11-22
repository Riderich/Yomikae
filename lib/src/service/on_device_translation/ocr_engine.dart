import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'ort_tensor.dart';
import 'page_analysis.dart';

/// Result of detecting and recognizing the text on one page.
class OcrResult {
  final List<TextBlock> blocks;
  final Duration detection;
  final Duration recognition;

  const OcrResult(this.blocks, this.detection, this.recognition);
}

/// PP-OCR detector + manga recognizer running in a long-lived background
/// isolate, so neither the UI thread nor Android's main thread is blocked and
/// the models are loaded only once.
class OcrEngine {
  /// Longest side of the detector input. 1280 keeps small manga text readable
  /// while staying well under a second on phones.
  static const int detectorMaxSide = 1280;

  Isolate? _isolate;
  SendPort? _sendPort;
  final ReceivePort _receivePort = ReceivePort();
  final Map<int, Completer<Map<dynamic, dynamic>>> _pending = {};
  int _nextId = 0;
  Completer<void>? _ready;

  bool get isRunning => _sendPort != null;

  Future<void> start({
    required String detectorPath,
    required String recognizerPath,
    required List<String> dictionary,
    int threads = 4,
  }) async {
    if (_ready != null) {
      return _ready!.future;
    }
    final Completer<void> ready = _ready = Completer<void>();
    _receivePort.listen((dynamic message) {
      if (message is SendPort) {
        _sendPort = message;
        return;
      }
      final Map<dynamic, dynamic> map = message as Map;
      if (map['type'] == 'ready') {
        ready.complete();
      } else if (map['type'] == 'initError') {
        ready.completeError(StateError(map['error'] as String));
      } else {
        _pending.remove(map['id'])?.complete(map);
      }
    });
    _isolate = await Isolate.spawn(
      _workerMain,
      {
        'port': _receivePort.sendPort,
        'detector': detectorPath,
        'recognizer': recognizerPath,
        'dictionary': dictionary,
        'threads': threads,
      },
      debugName: 'manga-ocr-engine',
    );
    try {
      await ready.future;
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<OcrResult> analyze(Uint8List rgba, int width, int height) async {
    if (_sendPort == null) {
      throw StateError('OCR engine is not started');
    }
    final int id = _nextId++;
    final Completer<Map<dynamic, dynamic>> completer = Completer();
    _pending[id] = completer;
    _sendPort!.send({
      'id': id,
      'rgba': TransferableTypedData.fromList([rgba]),
      'width': width,
      'height': height,
    });
    final Map<dynamic, dynamic> reply = await completer.future;
    if (reply['error'] != null) {
      throw StateError(reply['error'] as String);
    }
    return OcrResult(
      (reply['blocks'] as List).map((b) => TextBlock.fromJson(Map<String, dynamic>.from(b as Map))).toList(),
      Duration(microseconds: reply['detectionUs'] as int),
      Duration(microseconds: reply['recognitionUs'] as int),
    );
  }

  Future<void> dispose() async {
    _sendPort?.send({'type': 'close'});
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _sendPort = null;
    _ready = null;
    for (final Completer<Map<dynamic, dynamic>> c in _pending.values) {
      c.complete({'error': 'OCR engine stopped'});
    }
    _pending.clear();
  }
}

// ------------------------------------------------------------------- worker

void _workerMain(Map<String, dynamic> init) {
  final SendPort reply = init['port'] as SendPort;
  final ReceivePort requests = ReceivePort();
  reply.send(requests.sendPort);

  final _Worker worker;
  try {
    worker = _Worker(
      init['detector'] as String,
      init['recognizer'] as String,
      (init['dictionary'] as List).cast<String>(),
      init['threads'] as int,
    );
  } catch (e) {
    reply.send({'type': 'initError', 'error': e.toString()});
    return;
  }
  reply.send({'type': 'ready'});

  requests.listen((dynamic message) {
    final Map<dynamic, dynamic> map = message as Map;
    if (map['type'] == 'close') {
      worker.release();
      requests.close();
      return;
    }
    final int id = map['id'] as int;
    try {
      final Uint8List rgba = (map['rgba'] as TransferableTypedData).materialize().asUint8List();
      reply.send({'id': id, ...worker.analyze(rgba, map['width'] as int, map['height'] as int)});
    } catch (e, stack) {
      reply.send({'id': id, 'error': '$e\n$stack'});
    }
  });
}

class _Worker {
  final OrtSession detector;
  final OrtSession recognizer;
  final List<String> dictionary;
  final OrtRunOptions runOptions = OrtRunOptions();

  // ImageNet normalisation applied to B, G, R (PaddleOCR decodes images as BGR).
  static const List<double> _mean = [0.485, 0.456, 0.406];
  static const List<double> _std = [0.229, 0.224, 0.225];

  _Worker._(this.detector, this.recognizer, this.dictionary);

  factory _Worker(String detectorPath, String recognizerPath, List<String> dictionary, int threads) {
    OrtEnv.instance.init();
    OrtSession open(String path) {
      final OrtSessionOptions options = OrtSessionOptions()
        ..setIntraOpNumThreads(threads)
        ..setInterOpNumThreads(1)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
      // fromFile passes the path as UTF-8, which Windows' wide-char API misreads;
      // loading from memory works everywhere and the models are small.
      return OrtSession.fromBuffer(File(path).readAsBytesSync(), options);
    }

    return _Worker._(open(detectorPath), open(recognizerPath), dictionary);
  }

  Map<String, dynamic> analyze(Uint8List rgba, int width, int height) {
    final Stopwatch watch = Stopwatch()..start();
    final List<TextLine> lines = _detect(rgba, width, height);
    final Duration detection = watch.elapsed;

    final List<TextBlock> blocks = groupLines(lines, height, separated: (a, b) => gapHasBorder(rgba, width, a, b));
    for (final TextBlock block in blocks) {
      final StringBuffer text = StringBuffer();
      final List<double> scores = [];
      for (final TextLine line in block.ocrLines) {
        final (String lineText, List<double> lineScores) = _recognize(rgba, width, line);
        text.write(lineText);
        scores.addAll(lineScores);
      }
      block.text = text.toString();
      block.confidence = scores.isEmpty ? 0 : scores.reduce((a, b) => a + b) / scores.length;
    }
    markSkippedBlocks(blocks);

    return {
      'blocks': blocks.map((b) => b.toJson()).toList(),
      'detectionUs': detection.inMicroseconds,
      'recognitionUs': (watch.elapsed - detection).inMicroseconds,
    };
  }

  List<TextLine> _detect(Uint8List rgba, int width, int height) {
    final (int dw, int dh) = detectorInputSize(width, height, OcrEngine.detectorMaxSide);
    final Float32List input = Float32List(3 * dw * dh);
    final int plane = dw * dh;
    final double sx = width / dw, sy = height / dh;
    for (int y = 0; y < dh; y++) {
      final double fy = min(max((y + 0.5) * sy - 0.5, 0.0), height - 1.0);
      final int y0 = fy.floor(), y1 = min(y0 + 1, height - 1);
      final double ay = fy - y0;
      for (int x = 0; x < dw; x++) {
        final double fx = min(max((x + 0.5) * sx - 0.5, 0.0), width - 1.0);
        final int x0 = fx.floor(), x1 = min(x0 + 1, width - 1);
        final double ax = fx - x0;
        final int p00 = (y0 * width + x0) * 4, p01 = (y0 * width + x1) * 4;
        final int p10 = (y1 * width + x0) * 4, p11 = (y1 * width + x1) * 4;
        for (int c = 0; c < 3; c++) {
          // channel c of the BGR input is RGBA channel 2 - c
          final int rc = 2 - c;
          final double v = (rgba[p00 + rc] * (1 - ax) + rgba[p01 + rc] * ax) * (1 - ay) +
              (rgba[p10 + rc] * (1 - ax) + rgba[p11 + rc] * ax) * ay;
          input[c * plane + y * dw + x] = (v / 255.0 - _mean[c]) / _std[c];
        }
      }
    }

    final OrtValueTensor tensor = floatTensor(input, [1, 3, dh, dw]);
    final List<OrtValue?> outputs = detector.run(runOptions, {detector.inputNames.first: tensor});
    tensor.release();
    try {
      final OrtValue output = outputs.first!;
      final List<int> shape = tensorShape(output);
      final int mh = shape[shape.length - 2], mw = shape[shape.length - 1];
      final Float32List prob = readFloatTensor(output, mw * mh);
      return linesFromProbabilityMap(prob, mw, mh, width, height);
    } finally {
      for (final OrtValue? o in outputs) {
        o?.release();
      }
    }
  }

  (String, List<double>) _recognize(Uint8List rgba, int width, TextLine line) {
    final (Float32List input, int inputWidth) = recognizerInput(rgba, width, line);
    final OrtValueTensor tensor = floatTensor(input, [1, 3, recognizerHeight, inputWidth]);
    final List<OrtValue?> outputs = recognizer.run(runOptions, {recognizer.inputNames.first: tensor});
    tensor.release();
    try {
      final OrtValue output = outputs.first!;
      final List<int> shape = tensorShape(output);
      final int steps = shape[1], classes = shape[2];
      return ctcDecode(readFloatTensor(output, steps * classes), steps, classes, dictionary);
    } finally {
      for (final OrtValue? o in outputs) {
        o?.release();
      }
    }
  }

  void release() {
    detector.release();
    recognizer.release();
    runOptions.release();
    OrtEnv.instance.release();
  }
}
