import 'package:famio_client/famio_client.dart';
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

  /// What a link or notification asked to open (`famio://open?…`, #385),
  /// once. A link from ntfy names only a stored notification
  /// (`famio://open?notice=…`, #578): [resolve] asks the server what it
  /// opens; null (offline, removed, someone else's) opens nothing more.
  static Future<NoticeTarget?> takeTarget({
    Future<NoticeTarget?> Function(String key)? resolve,
  }) async {
    if (!_supported) return null;
    final String? handedOver;
    try {
      handedOver = await _channel.invokeMethod<String>('takeTarget');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
    if (NoticeLink.keyIn(handedOver) case final key?) {
      if (resolve == null) return null;
      try {
        return await resolve(key).timeout(const Duration(seconds: 15));
      } catch (_) {
        return null;
      }
    }
    return NoticeTarget.decode(handedOver);
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
