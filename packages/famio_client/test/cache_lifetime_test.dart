import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

FileRef fixture() => FileRef(
  id: newId(),
  name: 'fixture.bin',
  mime: 'application/octet-stream',
  size: 4,
);

void main() {
  for (final beforeEnd in [false, true]) {
    test(
      'clear invalidates an offline write ${beforeEnd ? 'before commit' : 'between chunks'}',
      () async {
        var downloads = 0;
        final api = FamioApiClient(
          'http://localhost',
          httpClient: MockClient((_) async {
            downloads++;
            return http.Response.bytes([1, 2, 3, 4], 200);
          }),
        );
        final directory = Directory.systemTemp.createTempSync(
          'famio-cache-life-',
        );
        final cache = FileCache.open(
          ':memory:',
          api,
          tempDir: '${directory.path}/temp',
        );
        addTearDown(() {
          cache.close();
          api.close();
          directory.deleteSync(recursive: true);
        });
        final ref = fixture();
        cache.put(fixture(), [0, 0, 0, 0]);
        final written = Completer<void>(), resume = Completer<void>();
        Stream<List<int>> chunks() async* {
          yield beforeEnd ? [1, 2, 3, 4] : [1, 2];
          written.complete();
          await resume.future;
          if (!beforeEnd) yield [3, 4];
        }

        final copying = cache.putStream(ref, chunks());
        final rejected = expectLater(copying, throwsA(isA<StateError>()));
        await written.future;
        cache.clear();
        resume.complete();
        await rejected;
        expect(cache.size, 0);
        final path = await cache.openable(ref);
        expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
        expect(downloads, 1);
      },
    );
  }

  test('clear rejects a late buffered download without retaining it', () async {
    final started = Completer<void>(), release = Completer<void>();
    final api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient((_) async {
        started.complete();
        await release.future;
        return http.Response.bytes([1, 2, 3, 4], 200);
      }),
    );
    final cache = FileCache.open(':memory:', api, tempDir: 'unused');
    addTearDown(() {
      cache.close();
      api.close();
    });
    final pending = cache.bytes(fixture(), thumb: 480);
    final rejected = expectLater(
      pending,
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'cancelled')),
    );
    await started.future;
    cache.clear();
    release.complete();
    await rejected;
    expect(cache.size, 0);
  });

  test(
    'old download cleanup cannot remove the next generation pending entry',
    () async {
      final responses = [
        Completer<http.Response>(),
        Completer<http.Response>(),
      ];
      var calls = 0;
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient((_) => responses[calls++].future),
      );
      final cache = FileCache.open(':memory:', api, tempDir: 'unused');
      addTearDown(() {
        cache.close();
        api.close();
      });
      final ref = fixture();
      final old = cache.bytes(ref);
      final rejected = expectLater(old, throwsA(isA<ApiError>()));
      await Future<void>.delayed(Duration.zero);
      cache.clear();
      final fresh = cache.bytes(ref);
      await Future<void>.delayed(Duration.zero);
      responses[0].complete(http.Response.bytes([9, 9, 9, 9], 200));
      await rejected;
      expect(identical(cache.bytes(ref), fresh), isTrue);
      responses[1].complete(http.Response.bytes([1, 2, 3, 4], 200));
      expect(await fresh, [1, 2, 3, 4]);
      expect(calls, 2);
    },
  );

  for (final corrupt in ['truncated', 'gap', 'missing']) {
    for (final buffered in [false, true]) {
      test(
        '$corrupt cached file is replaced when ${buffered ? 'read' : 'opened'}',
        () async {
          final directory = Directory.systemTemp.createTempSync(
            'famio-cache-repair-',
          );
          final dbPath = '${directory.path}/files.db';
          var downloads = 0;
          final api = FamioApiClient(
            'http://localhost',
            httpClient: MockClient((_) async {
              downloads++;
              return http.Response.bytes([1, 2, 3, 4], 200);
            }),
          );
          final cache = FileCache.open(
            dbPath,
            api,
            tempDir: '${directory.path}/temp',
            hexKey: '16' * 32,
          );
          addTearDown(() {
            cache.close();
            api.close();
            directory.deleteSync(recursive: true);
          });
          final ref = fixture();
          cache.put(ref, [1, 2, 3, 4]);
          final db = openDeviceDatabase(dbPath, hexKey: '16' * 32);
          switch (corrupt) {
            case 'truncated':
              db.execute('UPDATE blobs SET data = ? WHERE key = ?', [
                [3, 4],
                ref.id,
              ]);
            case 'gap':
              db.execute('UPDATE blobs SET seq = 1 WHERE key = ?', [ref.id]);
            case 'missing':
              db.execute('DELETE FROM blobs WHERE key = ?', [ref.id]);
          }
          db.close();
          final bytes = buffered
              ? await cache.bytes(ref)
              : await File(await cache.openable(ref)).readAsBytes();
          expect(bytes, [1, 2, 3, 4]);
          expect(downloads, 1);
          expect(cache.size, 4);
          expect(await cache.bytes(ref), [1, 2, 3, 4]);
          expect(downloads, 1);
        },
      );
    }
  }
}
