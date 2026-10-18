import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A file shared to Famio, copied to the app's cache.
typedef SharedFile = ({String path, String name, String mime});

/// Text, links and files another app shared to Famio ("Teilen an Famio",
/// Android).
class SharedContent {
  const SharedContent({
    this.text = '',
    this.subject = '',
    this.files = const [],
  });

  final String text;

  /// The sender's title, e.g. a mail's subject or a page's title.
  final String subject;
  final List<SharedFile> files;
}

/// Calendar files opened with Famio from another app ("Öffnen mit" in Mail,
/// Files, the Finder, the Explorer or the file manager; "Teilen" on
/// Android), and other things shared to Famio on Android. The platform keeps
/// them until [take] or [takeShare] fetches them and calls [onOpened] when
/// one arrives while Famio runs.
abstract final class OpenedFiles {
  static const _channel = MethodChannel('famio/open_file');

  /// Set by the app shell, which shows the import.
  static VoidCallback? onOpened;
  static var _listening = false;

  static bool get _supported => !kIsWeb;

  static void listen() {
    if (_listening || !_supported) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') onOpened?.call();
    });
  }

  /// Text and files shared to Famio, once.
  static Future<SharedContent?> takeShare() async {
    if (!_supported) return null;
    try {
      final share = await _channel.invokeMapMethod<String, Object?>(
        'takeShare',
      );
      if (share == null) return null;
      return SharedContent(
        text: share['text'] as String? ?? '',
        subject: share['subject'] as String? ?? '',
        files: [
          for (final f in (share['files'] as List? ?? const []).cast<Map>())
            (
              path: f['path'] as String? ?? '',
              name: f['name'] as String? ?? '',
              mime: f['mime'] as String? ?? 'application/octet-stream',
            ),
        ],
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
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
