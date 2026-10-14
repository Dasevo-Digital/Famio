import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:famio_server/src/updates/app_updates.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('a broken download is tried again soon and logged', () async {
    const version = '9.9.9';
    final pair = await Ed25519().newKeyPair();
    final key = base64Encode((await pair.extractPublicKey()).bytes);
    final files = {
      for (final p in AppPlatform.values)
        p.fileName(version): utf8.encode('Paket ${p.name}'),
    };
    final sums = [
      for (final e in files.entries)
        '${await sha256Hex(Stream.value(e.value))}  ${e.key}\n',
    ].join();
    final signature = base64Encode(
      (await Ed25519().sign(utf8.encode(sums), keyPair: pair)).bytes,
    );
    var broken = true;
    final client = MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response(
          jsonEncode({
            'assets': [
              for (final name in [
                ...files.keys,
                'SHA256SUMS.txt',
                'SHA256SUMS.txt.sig',
              ])
                {'name': name, 'browser_download_url': 'https://dl.test/$name'},
            ],
          }),
          200,
        );
      }
      final name = request.url.pathSegments.last;
      if (name == 'SHA256SUMS.txt') return http.Response(sums, 200);
      if (name == 'SHA256SUMS.txt.sig') return http.Response(signature, 200);
      // The first package download breaks off, as a stalled connection.
      if (broken) {
        broken = false;
        throw http.ClientException('Verbindung abgebrochen', request.url);
      }
      return http.Response.bytes(files[name]!, 200);
    });
    final db = sqlite3.openInMemory()
      ..execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)');
    final dir = Directory.systemTemp.createTempSync('famio_updates_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final log = <String>[];
    final updates = AppUpdates(
      db: db,
      dir: dir.path,
      version: version,
      client: client,
      publicKey: key,
      retrySoon: const Duration(milliseconds: 20),
      onError: log.add,
    );
    addTearDown(updates.stop);

    final info = await updates.configure(enabled: true);
    expect(info['error'], contains('Verbindung abgebrochen'));
    expect(log.single, contains('[app-updates] 9.9.9'));
    // Nothing half-written is left behind.
    expect(
      dir.listSync(recursive: true).where((e) => e.path.endsWith('.part')),
      isEmpty,
    );

    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final p in AppPlatform.values) {
      expect(updates.package(p), isNotNull, reason: p.name);
    }
    expect(updates.info()['error'], isNull);
  });
}
