import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

/// One downloadable model file, pinned to a Hugging Face commit and verified by SHA-256.
class OcrModelFile {
  final String fileName;
  final String repo;
  final String revision;
  final String remotePath;
  final int size;
  final String sha256;

  const OcrModelFile({
    required this.fileName,
    required this.repo,
    required this.revision,
    required this.remotePath,
    required this.size,
    required this.sha256,
  });

  String url(String host) => '$host/$repo/resolve/$revision/$remotePath';
}

class OcrModels {
  /// PP-OCRv6 small text detector (Apache-2.0, PaddlePaddle).
  static const OcrModelFile detector = OcrModelFile(
    fileName: 'ppocr_v6_small_det.onnx',
    repo: 'PaddlePaddle/PP-OCRv6_small_det_onnx',
    revision: '28fe5895c24fd108c19eb3e8479f4ab385fbfc62',
    remotePath: 'inference.onnx',
    size: 9880512,
    sha256: 'd73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e',
  );

  /// PP-OCRv6 small recognizer fine-tuned on manga lettering (Apache-2.0).
  static const OcrModelFile recognizer = OcrModelFile(
    fileName: 'ppocr_v6_small_rec_manga.onnx',
    repo: 'fumetodev/PP-OCRv6_small_rec_manga_ONNX',
    revision: '1ef01f78c59f6f66389c9722fd2d0ab761680ea9',
    remotePath: 'ppocr-rec-v6-small-manga.onnx',
    size: 21143614,
    sha256: 'c5cc5038a98c3df3e2d37de5716f603e2b0bcd3536c74078fdd91876a48a25ef',
  );

  static const List<OcrModelFile> all = [detector, recognizer];

  static int get totalSize => all.fold(0, (sum, f) => sum + f.size);

  static const String huggingFace = 'https://huggingface.co';
  static const String hfMirror = 'https://hf-mirror.com';

  final Directory directory;

  OcrModels(this.directory);

  File file(OcrModelFile model) => File(path.join(directory.path, model.fileName));

  /// Present with the expected size. The hash is checked once, right after download.
  bool isInstalled(OcrModelFile model) {
    final File f = file(model);
    return f.existsSync() && f.lengthSync() == model.size;
  }

  bool get allInstalled => all.every(isInstalled);

  /// Downloads every missing file. [hosts] are tried in order for each file.
  /// [onProgress] receives the downloaded and total byte counts over all files.
  Future<void> downloadAll({
    required List<String> hosts,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    await directory.create(recursive: true);
    final int total = totalSize;
    int done = 0;
    for (final OcrModelFile model in all) {
      if (isInstalled(model)) {
        done += model.size;
        onProgress(done, total);
        continue;
      }
      Object? lastError;
      for (final String host in hosts) {
        try {
          await _download(model, host, (received) => onProgress(done + received, total), cancelToken);
          lastError = null;
          break;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) {
            rethrow;
          }
          lastError = e;
        } on Exception catch (e) {
          lastError = e;
        }
      }
      if (lastError != null) {
        throw lastError;
      }
      done += model.size;
      onProgress(done, total);
    }
  }

  Future<void> _download(OcrModelFile model, String host, void Function(int received) onProgress, CancelToken? cancelToken) async {
    final File target = file(model);
    final File partial = File('${target.path}.part');
    if (partial.existsSync()) {
      partial.deleteSync();
    }
    await Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(minutes: 2))).download(
      model.url(host),
      partial.path,
      cancelToken: cancelToken,
      onReceiveProgress: (received, _) => onProgress(received),
    );
    final Digest digest = await sha256.bind(partial.openRead()).first;
    if (digest.toString() != model.sha256) {
      partial.deleteSync();
      throw StateError('Checksum mismatch for ${model.fileName} from $host');
    }
    if (target.existsSync()) {
      target.deleteSync();
    }
    await partial.rename(target.path);
  }

  Future<void> deleteAll() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
