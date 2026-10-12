import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Calendar files opened with Famio from another app ("Öffnen mit" in Mail,
/// Files or the Finder; "Teilen" on Android). The platform keeps the file
/// until [take] fetches it and calls [onOpened] when one arrives while Famio
/// runs.
abstract final class OpenedFiles {
  static const _channel = MethodChannel('famio/open_file');

  /// Set by the app shell, which shows the import.
  static VoidCallback? onOpened;
  static var _listening = false;

  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  static void listen() {
    if (_listening || !_supported) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') onOpened?.call();
    });
  }

  /// The waiting file, once.
  static Future<({String name, Uint8List bytes})?> take() async {
    if (!_supported) return null;
    try {
      final file = await _channel.invokeMapMethod<String, Object?>('take');
      final bytes = file?['bytes'];
      if (bytes is! Uint8List) return null;
      return (name: file?['name'] as String? ?? '', bytes: bytes);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
