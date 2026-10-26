import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../l10n.dart';

/// Android: the recognition model is still being loaded by Google Play
/// services (the small 64-bit package), or cannot be without them.
class OcrModelMissing implements Exception {
  const OcrModelMissing({required this.loading});

  /// True while the download runs: try again in a minute.
  final bool loading;
}

/// Text in a photo, recognised on the device (Vision on Apple devices,
/// ML Kit on Android). Null where unavailable or nothing was found; throws
/// [OcrModelMissing] while the model is not on the phone yet.
class Ocr {
  static const _channel = MethodChannel('famio/ocr');

  static bool get available =>
      debugAvailable ??
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS));

  /// Tests on any machine pretend to have (or not have) the recognition.
  @visibleForTesting
  static bool? debugAvailable;

  /// Android: where the recognition models come from, `play` (Google Play
  /// services) or `bundled` (inside the app); null elsewhere.
  static Future<String?> models() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('models');
    } catch (_) {
      return null;
    }
  }

  /// Throws [OcrModelMissing] when Google Play has not loaded the model.
  static void _checkModel(PlatformException e) {
    if (e.code == 'downloading' || e.code == 'unavailable') {
      throw OcrModelMissing(loading: e.code == 'downloading');
    }
  }

  /// The text of a PDF (text layer, or the first pages read like a photo).
  static Future<String?> pdfText(String path) async {
    if (!available) return null;
    try {
      final text = await _channel.invokeMethod<String>('pdfText', {
        'path': path,
      });
      return text == null || text.trim().isEmpty ? null : text;
    } on PlatformException catch (e) {
      _checkModel(e);
      debugPrint(tr.ocrPdfNotReadableError(e));
      return null;
    } catch (e) {
      debugPrint(tr.ocrPdfNotReadableError(e));
      return null;
    }
  }

  static Future<String?> recognize(String path) async {
    if (!available) return null;
    try {
      final text = await _channel.invokeMethod<String>('recognize', {
        'path': path,
      });
      return text == null || text.trim().isEmpty ? null : text;
    } on PlatformException catch (e) {
      _checkModel(e);
      debugPrint(tr.ocrTextRecognitionNotPossible(e));
      return null;
    } catch (e) {
      debugPrint(tr.ocrTextRecognitionNotPossible(e));
      return null;
    }
  }

  /// Whether [mime] is something [textOfFile] can read.
  static bool readable(String mime) =>
      available && (mime == 'application/pdf' || mime.startsWith('image/'));

  /// The text of a PDF or picture at [path], for finding it later; null
  /// where there is none or it cannot be read (also while the model is
  /// missing: it is only a help).
  static Future<String?> textOfFile(String path, String mime) async {
    if (!readable(mime)) return null;
    try {
      return mime == 'application/pdf'
          ? await pdfText(path)
          : await recognize(path);
    } on OcrModelMissing {
      return null;
    }
  }

  /// [textOfFile] for [bytes] not yet on disk (a file just picked).
  static Future<String?> textOf(List<int> bytes, String mime) async {
    if (!readable(mime)) return null;
    final file = File(
      '${Directory.systemTemp.path}/famio-text-${DateTime.now().microsecondsSinceEpoch}'
      '${mime == 'application/pdf' ? '.pdf' : ''}',
    );
    try {
      await file.writeAsBytes(bytes);
      return await textOfFile(file.path, mime);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
}
