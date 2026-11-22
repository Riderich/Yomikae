import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' as dio;
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

import '../model/gallery_image.dart';
import '../model/read_page_info.dart';
import '../setting/translation_setting.dart';
import 'gallery_download/gallery_download_service.dart';
import 'jh_service.dart';
import 'on_device_translation/on_device_translation_service.dart';
import 'log.dart';
import 'path_service.dart';
import 'translation_runtime_service.dart';

enum ImageTranslationStatus { idle, translating, success, error }

class ImageTranslationEntry {
  ImageTranslationStatus status;
  String? relativePath;
  String? error;

  ImageTranslationEntry({
    this.status = ImageTranslationStatus.idle,
    this.relativePath,
    this.error,
  });
}

/// Where the time of one page translation went, in seconds per category.
class ImageTranslationTiming {
  static const String fetch = 'translationStageFetch';
  static const String network = 'translationStageNetwork';
  static const String queue = 'translationStageQueue';
  static const String detection = 'translationStageDetection';
  static const String ocr = 'translationStageOcr';
  static const String translating = 'translationStageTranslating';
  static const String inpainting = 'translationStageInpainting';
  static const String rendering = 'translationStageRendering';
  static const String server = 'translationStageServer';
  static const String other = 'translationStageOther';

  /// manga-image-translator stage name -> category
  static const Map<String, String> _engineStageCategories = {
    'engine_wait': queue,
    'detection': detection,
    'ocr': ocr,
    'translating': translating,
    'inpainting': inpainting,
    'rendering': rendering,
  };

  final double total;
  final Map<String, double> parts;

  const ImageTranslationTiming({required this.total, required this.parts});

  /// [serverTimingJson] is the X-JHenTai-Timing header from the adapter, if any.
  factory ImageTranslationTiming.fromMeasurements({
    required Duration fetchSource,
    required Duration request,
    String? serverTimingJson,
  }) {
    final double fetchSeconds = fetchSource.inMicroseconds / 1e6;
    final double requestSeconds = request.inMicroseconds / 1e6;
    final Map<String, double> parts = {fetch: fetchSeconds};

    Map<String, dynamic>? server;
    if (serverTimingJson != null && serverTimingJson.isNotEmpty) {
      try {
        server = Map<String, dynamic>.from(jsonDecode(serverTimingJson));
      } catch (_) {
        server = null;
      }
    }

    final double? adapterTotal = (server?['adapter_total'] as num?)?.toDouble();
    if (server == null || adapterTotal == null) {
      parts[server == null ? ImageTranslationTiming.server : other] = requestSeconds;
    } else {
      parts[network] = max(0, requestSeconds - adapterTotal);
      double accounted = 0;
      server.forEach((String name, dynamic value) {
        final String? category = _engineStageCategories[name];
        if (category == null || value is! num) {
          return;
        }
        parts[category] = (parts[category] ?? 0) + value.toDouble();
        accounted += value.toDouble();
      });
      final bool hasStages = server.keys.any(_engineStageCategories.containsKey);
      if (!hasStages) {
        // Engine without streaming support: only the total engine time is known.
        parts[ImageTranslationTiming.server] = adapterTotal;
      } else {
        parts[other] = max(0, adapterTotal - accounted);
      }
    }

    return ImageTranslationTiming(total: fetchSeconds + requestSeconds, parts: parts);
  }

  static ImageTranslationTiming? average(List<ImageTranslationTiming> timings) {
    if (timings.isEmpty) {
      return null;
    }
    final Map<String, double> sums = {};
    double total = 0;
    for (final ImageTranslationTiming timing in timings) {
      total += timing.total;
      timing.parts.forEach((key, value) => sums[key] = (sums[key] ?? 0) + value);
    }
    return ImageTranslationTiming(
      total: total / timings.length,
      parts: sums.map((key, value) => MapEntry(key, value / timings.length)),
    );
  }

  /// e.g. "耗时 42.1 秒：修图 25.3 · LLM 翻译 8.0 · 文字检测 3.2 · ..." (largest first)
  String summary() {
    final List<MapEntry<String, double>> sorted = parts.entries.where((e) => e.value >= 0.05).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final String details = sorted.map((e) => '${e.key.tr} ${e.value.toStringAsFixed(1)}').join(' · ');
    return '${'translationTimingTotal'.trParams({'seconds': total.toStringAsFixed(1)})}: $details';
  }

  @override
  String toString() => 'total=${total.toStringAsFixed(2)}s ${parts.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(2)}s').join(' ')}';
}

ImageTranslationService imageTranslationService = ImageTranslationService();

class ImageTranslationService extends GetxController
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const String updateIdPrefix = 'imageTranslation';

  final Map<String, ImageTranslationEntry> _entries = {};
  late Directory _cacheDirectory;

  @override
  List<JHLifeCircleBean> get initDependencies => [
        pathService,
        log,
        translationSetting,
      ];

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
    _cacheDirectory = Directory(
      path.join(pathService.getVisibleDir().path, 'translation_cache'),
    );
    await _cacheDirectory.create(recursive: true);
    super.onInit();
  }

  @override
  Future<void> doAfterBeanReady() async {
    unawaited(translationRuntimeService.startIfInitialized());
  }

  String updateId(ReadPageInfo info, int index) =>
      '$updateIdPrefix::${_pageKey(info, index)}';

  ImageTranslationEntry entry(ReadPageInfo info, int index) {
    final String key = _pageKey(info, index);
    return _entries.putIfAbsent(key, () {
      final String? cachedPath = _findCachedRelativePath(info, index);
      return ImageTranslationEntry(
        status: cachedPath == null
            ? ImageTranslationStatus.idle
            : ImageTranslationStatus.success,
        relativePath: cachedPath,
      );
    });
  }

  GalleryImage translatedImageOrOriginal(
    ReadPageInfo info,
    int index,
    GalleryImage original, {
    required bool showTranslated,
  }) {
    if (!showTranslated) {
      return original;
    }
    final ImageTranslationEntry current = entry(info, index);
    if (current.status != ImageTranslationStatus.success ||
        current.relativePath == null) {
      return original;
    }
    return original.copyWith(
      path: current.relativePath,
      downloadStatus: DownloadStatus.downloaded,
    );
  }

  /// Returns where the time went, or null if this page is already being translated.
  Future<ImageTranslationTiming?> translate({
    required ReadPageInfo info,
    required int index,
    required Uint8List imageBytes,
    required String fileName,
    Duration fetchSourceDuration = Duration.zero,
  }) async {
    final String key = _pageKey(info, index);
    final ImageTranslationEntry current = entry(info, index);
    if (current.status == ImageTranslationStatus.translating) {
      return null;
    }

    current
      ..status = ImageTranslationStatus.translating
      ..error = null;
    update([updateId(info, index)]);

    try {
      final (List<int> translatedBytes, String extension, ImageTranslationTiming timing) = translationSetting.isOnDevice
          ? await _translateOnDevice(imageBytes, fetchSourceDuration)
          : await _translateOnServer(info, index, imageBytes, fileName, fetchSourceDuration);

      final String relativePath = _cacheRelativePath(info, index, extension);
      final File output = File(
        path.join(pathService.getVisibleDir().path, relativePath),
      );
      await output.create(recursive: true);
      await output.writeAsBytes(translatedBytes, flush: true);

      current
        ..status = ImageTranslationStatus.success
        ..relativePath = relativePath
        ..error = null;
      log.info('Translated page cached: $key -> $relativePath');
      log.info('Translation timing $key: $timing');
      return timing;
    } catch (e, stack) {
      current
        ..status = ImageTranslationStatus.error
        ..error = e.toString();
      log.error('Translate page failed: $key', e, stack);
      rethrow;
    } finally {
      update([updateId(info, index)]);
    }
  }

  Future<(List<int>, String, ImageTranslationTiming)> _translateOnDevice(Uint8List imageBytes, Duration fetchSourceDuration) async {
    final OnDevicePageResult result = await onDeviceTranslationService.translatePage(imageBytes);
    final double fetchSeconds = fetchSourceDuration.inMicroseconds / 1e6;
    final ImageTranslationTiming timing = ImageTranslationTiming(
      total: fetchSeconds + result.stageSeconds.values.fold(0.0, (a, b) => a + b),
      parts: {ImageTranslationTiming.fetch: fetchSeconds, ...result.stageSeconds},
    );
    return (result.png, 'png', timing);
  }

  Future<(List<int>, String, ImageTranslationTiming)> _translateOnServer(
    ReadPageInfo info,
    int index,
    Uint8List imageBytes,
    String fileName,
    Duration fetchSourceDuration,
  ) async {
    final Duration timeout = Duration(
      seconds: translationSetting.requestTimeoutSeconds.value,
    );
    final dio.Dio client = dio.Dio(
      dio.BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        sendTimeout: timeout,
        receiveTimeout: timeout,
        responseType: dio.ResponseType.bytes,
        headers: {
          if (translationSetting.apiToken.value.isNotEmpty)
            'Authorization': 'Bearer ${translationSetting.apiToken.value}',
        },
      ),
    );
    final dio.FormData body = dio.FormData.fromMap({
      'image': dio.MultipartFile.fromBytes(imageBytes, filename: fileName),
      'gallery_id': _galleryKey(info),
      'page_index': index,
      'source_language': translationSetting.sourceLanguage.value,
      'target_language': translationSetting.targetLanguage.value,
      'translation_provider': translationSetting.translationProvider.value,
      'api_base_url': translationSetting.apiBaseUrl.value,
      'api_key': translationSetting.apiKey.value,
      'api_model': translationSetting.apiModel.value,
      'disable_thinking': translationSetting.disableThinking.value,
    });
    final Stopwatch requestStopwatch = Stopwatch()..start();
    final dio.Response<List<int>> response = await client.post<List<int>>(
      '${translationSetting.serviceUrl.value}/v1/translate',
      data: body,
      options: dio.Options(responseType: dio.ResponseType.bytes),
    );
    requestStopwatch.stop();
    final List<int>? translatedBytes = response.data;
    if (translatedBytes == null || translatedBytes.isEmpty) {
      throw StateError('Translation service returned an empty image');
    }

    final String extension = _extensionFromContentType(
      response.headers.value(dio.Headers.contentTypeHeader),
    );
    final ImageTranslationTiming timing = ImageTranslationTiming.fromMeasurements(
      fetchSource: fetchSourceDuration,
      request: requestStopwatch.elapsed,
      serverTimingJson: response.headers.value('x-jhentai-timing'),
    );
    log.info(
      'Translation server response: upload=${imageBytes.length ~/ 1024}KB download=${translatedBytes.length ~/ 1024}KB '
      'server=${response.headers.value('x-jhentai-timing')}',
    );
    return (translatedBytes, extension, timing);
  }

  Future<bool> testConnection() async {
    try {
      final dio.Dio client = dio.Dio(
        dio.BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final dio.Response response = await client.post(
        '${translationSetting.serviceUrl.value}/v1/test',
        data: dio.FormData.fromMap({
          'translation_provider': translationSetting.translationProvider.value,
          'api_base_url': translationSetting.apiBaseUrl.value,
          'api_key': translationSetting.apiKey.value,
          'api_model': translationSetting.apiModel.value,
          'disable_thinking': translationSetting.disableThinking.value,
        }),
      );
      return response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300;
    } catch (e) {
      log.warning('Image translation service health check failed', e);
      return false;
    }
  }

  Future<void> clearCache() async {
    final List<String> updateIds =
        _entries.keys.map((key) => '$updateIdPrefix::$key').toList();
    if (await _cacheDirectory.exists()) {
      await _cacheDirectory.delete(recursive: true);
    }
    await _cacheDirectory.create(recursive: true);
    _entries.clear();
    if (updateIds.isNotEmpty) {
      update(updateIds);
    }
  }

  /// Server-mode keys stay unchanged so existing caches keep working.
  String get _engineSuffix => translationSetting.isOnDevice ? '::onDevice' : '';

  String _galleryKey(ReadPageInfo info) {
    return info.gid != null
        ? '${info.gid}_${info.token ?? ''}'
        : info.readProgressRecordStorageKey;
  }

  String _pageKey(ReadPageInfo info, int index) =>
      '${_galleryKey(info)}::$index::${translationSetting.targetLanguage.value}::${translationSetting.translationProvider.value}::${translationSetting.apiModel.value}$_engineSuffix';

  String _cacheBaseName(ReadPageInfo info, int index) {
    final String identity =
        '${_galleryKey(info)}::$index::${translationSetting.sourceLanguage.value}::${translationSetting.targetLanguage.value}::${translationSetting.translationProvider.value}::${translationSetting.apiModel.value}$_engineSuffix';
    return sha256.convert(utf8.encode(identity)).toString();
  }

  String _cacheRelativePath(ReadPageInfo info, int index, String extension) {
    return path.join(
      'translation_cache',
      '${_cacheBaseName(info, index)}.$extension',
    );
  }

  String? _findCachedRelativePath(ReadPageInfo info, int index) {
    for (final String extension in const ['png', 'jpg', 'webp']) {
      final String relativePath = _cacheRelativePath(info, index, extension);
      if (File(
        path.join(pathService.getVisibleDir().path, relativePath),
      ).existsSync()) {
        return relativePath;
      }
    }
    return null;
  }

  String _extensionFromContentType(String? contentType) {
    if (contentType?.contains('webp') == true) {
      return 'webp';
    }
    if (contentType?.contains('jpeg') == true ||
        contentType?.contains('jpg') == true) {
      return 'jpg';
    }
    return 'png';
  }
}
