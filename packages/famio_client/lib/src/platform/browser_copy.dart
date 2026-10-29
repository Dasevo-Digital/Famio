import 'dart:typed_data';
import 'copy_queue.dart';
import 'browser_copy_io.dart'
    if (dart.library.js_interop) 'browser_copy_web.dart'
    as raw;

Future<Uint8List?> readBrowserCopy(String name) =>
    CopyQueue.named(name).run(() => raw.readBrowserCopy(name));

Future<void> deleteBrowserCopy(String name) =>
    CopyQueue.named(name).clear(() => raw.deleteBrowserCopy(name));

Future<void> writeBrowserCopy(String name, Uint8List plain) {
  final queue = CopyQueue.named(name);
  final lease = queue.enable();
  return queue.run(() async {
    if (!queue.owns(lease)) return;
    await raw.enableBrowserCopy(name, lease);
    if (queue.owns(lease)) await raw.writeBrowserCopy(name, plain, lease);
  });
}
