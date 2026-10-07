import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Text in a photo, recognised on the device (Vision on Apple devices,
/// ML Kit on Android). Null where unavailable or nothing was found.
class Ocr {
  static const _channel = MethodChannel('famio/ocr');

  static bool get available =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// The text of a PDF (text layer, or the first pages read like a photo).
  static Future<String?> pdfText(String path) async {
    if (!available) return null;
    try {
      final text = await _channel.invokeMethod<String>('pdfText', {
        'path': path,
      });
      return text == null || text.trim().isEmpty ? null : text;
    } catch (e) {
      debugPrint('PDF nicht lesbar: $e');
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
    } catch (e) {
      debugPrint('Texterkennung nicht möglich: $e');
      return null;
    }
  }
}
