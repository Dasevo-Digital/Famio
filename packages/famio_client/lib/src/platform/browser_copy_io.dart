import 'dart:typed_data';

// The apps keep their encrypted database on the device; only the browser
// needs a copy of its own (browser_copy_web.dart).

Future<Uint8List?> readBrowserCopy(String name) async => null;

Future<void> writeBrowserCopy(String name, Uint8List plain) async {}

Future<void> deleteBrowserCopy(String name) async {}
