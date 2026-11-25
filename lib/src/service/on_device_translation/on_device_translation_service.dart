import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

import '../../setting/translation_setting.dart';
import '../jh_service.dart';
import '../log.dart';
import '../path_service.dart';
import 'llm_page_translator.dart';
import 'ocr_engine.dart';
import 'ocr_models.dart';
import 'page_analysis.dart';
import 'page_eraser.dart';
import 'page_renderer.dart';

/// Output of translating one page on the device.
class OnDevicePageResult {
  final Uint8List png;

  /// Seconds per stage, keyed like [ImageTranslationTiming] categories.
  final Map<String, double> stageSeconds;
  final int detectedBlocks;
  final int translatedBlocks;

  const OnDevicePageResult(this.png, this.stageSeconds, this.detectedBlocks, this.translatedBlocks);
}

enum OcrModelStatus { missing, downloading, installed, error }

OnDeviceTranslationService onDeviceTranslationService = OnDeviceTranslationService();

/// Manga translation without a translation server: PP-OCR text detection and
/// recognition run on the device (ONNX Runtime in a background isolate), the
/// recognized text goes to the configured LLM API, and the translation is
/// typeset back onto the page locally.
class OnDeviceTranslationService extends GetxController with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const String modelsUpdateId = 'onDeviceTranslationModels';

  late final OcrModels models;
  final OcrEngine _engine = OcrEngine();
  Future<void>? _engineStarting;

  OcrModelStatus modelStatus = OcrModelStatus.missing;
  double downloadProgress = 0;
  String? modelError;
  CancelToken? _downloadCancelToken;

  @override
  List<JHLifeCircleBean> get initDependencies => [pathService, log, translationSetting];

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
    models = OcrModels(Directory(path.join(pathService.getVisibleDir().path, 'translation_models')));
    modelStatus = models.allInstalled ? OcrModelStatus.installed : OcrModelStatus.missing;
  }

  @override
  Future<void> doAfterBeanReady() async {}

  List<String> get _hosts => translationSetting.modelSource.value == TranslationModelSource.hfMirror
      ? [OcrModels.hfMirror, OcrModels.huggingFace]
      : [OcrModels.huggingFace, OcrModels.hfMirror];

  Future<void> downloadModels() async {
    if (modelStatus == OcrModelStatus.downloading) {
      return;
    }
    modelStatus = OcrModelStatus.downloading;
    downloadProgress = 0;
    modelError = null;
    _downloadCancelToken = CancelToken();
    update([modelsUpdateId]);
    try {
      await models.downloadAll(
        hosts: _hosts,
        cancelToken: _downloadCancelToken,
        onProgress: (received, total) {
          final double progress = total == 0 ? 0 : received / total;
          if ((progress - downloadProgress).abs() >= 0.01 || progress == 1) {
            downloadProgress = progress;
            update([modelsUpdateId]);
          }
        },
      );
      modelStatus = OcrModelStatus.installed;
      log.info('On-device translation models installed');
    } catch (e, stack) {
      if (e is DioException && CancelToken.isCancel(e)) {
        modelStatus = OcrModelStatus.missing;
      } else {
        modelStatus = OcrModelStatus.error;
        modelError = e.toString();
        log.error('Download on-device translation models failed', e, stack);
      }
    } finally {
      _downloadCancelToken = null;
      update([modelsUpdateId]);
    }
  }

  void cancelDownload() => _downloadCancelToken?.cancel();

  Future<void> deleteModels() async {
    await _engine.dispose();
    _engineStarting = null;
    await models.deleteAll();
    modelStatus = OcrModelStatus.missing;
    update([modelsUpdateId]);
  }

  Future<void> _ensureEngine() {
    if (_engine.isRunning) {
      return Future.value();
    }
    return _engineStarting ??= () async {
      try {
        final String dictionary = await rootBundle.loadString('assets/translation/ppocrv6_dict.txt');
        await _engine.start(
          detectorPath: models.file(OcrModels.detector).path,
          recognizerPath: models.file(OcrModels.recognizer).path,
          dictionary: dictionary.split('\n').map((l) => l.trimRight()).toList(),
          threads: max(1, min(4, Platform.numberOfProcessors - 1)),
        );
      } catch (_) {
        _engineStarting = null;
        rethrow;
      }
    }();
  }

  /// Translates one page; [onStage] hears each step as it starts
  /// (`translationStage*` l18n keys), for a progress display.
  Future<OnDevicePageResult> translatePage(Uint8List imageBytes, {void Function(String stage)? onStage}) async {
    if (!models.allInstalled) {
      throw StateError('translationModelsMissing'.tr);
    }
    if (translationSetting.translationProvider.value != 'openai_compatible') {
      throw StateError('onDeviceTranslationNeedsLlm'.tr);
    }
    final Map<String, double> stages = {};
    final Stopwatch watch = Stopwatch()..start();
    double lap() {
      final double s = watch.elapsedMicroseconds / 1e6;
      watch.reset();
      return s;
    }

    await _ensureEngine();
    final (Uint8List rgba, int width, int height) = await _decode(imageBytes);
    stages['translationStageOther'] = lap();

    onStage?.call('translationStageDetection');
    final OcrResult ocr = await _engine.analyze(rgba, width, height);
    lap();
    stages['translationStageDetection'] = ocr.detection.inMicroseconds / 1e6;
    stages['translationStageOcr'] = ocr.recognition.inMicroseconds / 1e6;

    final List<TextBlock> blocks = ocr.blocks.where((b) => !b.skip).toList();
    final Map<int, String> texts = {for (int i = 0; i < blocks.length; i++) i: blocks[i].text};
    final LlmPageTranslator translator = LlmPageTranslator(
      baseUrl: translationSetting.apiBaseUrl.value,
      apiKey: translationSetting.apiKey.value,
      model: translationSetting.apiModel.value,
      disableThinking: translationSetting.disableThinking.value,
      timeout: Duration(seconds: translationSetting.requestTimeoutSeconds.value),
    );
    onStage?.call('translationStageTranslating');
    final Map<int, String> translations = await translator.translate(texts, translationSetting.targetLanguage.value);
    stages['translationStageTranslating'] = lap();

    onStage?.call('translationStageInpainting');
    final List<RenderItem> items = [];
    for (final MapEntry<int, String> entry in translations.entries) {
      if (entry.key < 0 || entry.key >= blocks.length) {
        continue;
      }
      final TextBlock block = blocks[entry.key];
      items.add(RenderItem(block, entry.value, eraseBlock(rgba, width, height, block)));
    }
    stages['translationStageInpainting'] = lap();

    onStage?.call('translationStageRendering');
    final String target = translationSetting.targetLanguage.value.toLowerCase();
    final Uint8List png = await PageRenderer.render(
      rgba,
      width,
      height,
      items,
      // only Japanese reads in right-to-left columns; Chinese translations
      // read left to right, top to bottom, even in a tall bubble
      verticalAllowed: target.startsWith('ja'),
    );
    stages['translationStageRendering'] = lap();

    log.info('On-device translation: ${ocr.blocks.length} blocks, ${blocks.length} with text, ${items.length} translated');
    return OnDevicePageResult(png, stages, blocks.length, items.length);
  }

  static Future<(Uint8List, int, int)> _decode(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image image = frame.image;
    try {
      final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (data == null) {
        throw StateError('Unable to decode page image');
      }
      return (data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), image.width, image.height);
    } finally {
      image.dispose();
      codec.dispose();
    }
  }
}
