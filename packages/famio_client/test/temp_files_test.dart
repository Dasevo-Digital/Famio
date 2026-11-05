@TestOn('vm')
library;

import 'dart:io';

import 'package:famio_client/src/platform/storage_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() => directory = Directory.systemTemp.createTempSync('famio-open'));
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('plain copies go after an hour, newer ones stay', () async {
    final old = await writeTempFile(directory.path, 'alt.pdf', [1]);
    final fresh = await writeTempFile(directory.path, 'neu.pdf', [2]);
    File(
      old,
    ).setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    sweepTempFiles(directory.path, const Duration(hours: 1));
    expect(File(old).existsSync(), isFalse);
    expect(File(fresh).existsSync(), isTrue);
  });

  test('nothing to sweep yet is fine', () {
    sweepTempFiles('${directory.path}/fehlt', const Duration(hours: 1));
  });

  test('on Linux only their user reads the folder', () async {
    final dir = '${directory.path}/famio_open';
    await writeTempFile(dir, 'befund.pdf', [1]);
    final mode = Directory(dir).statSync().mode & 0x1ff;
    expect(mode, Platform.isLinux ? 0x1c0 : isNonZero);
  });
}
