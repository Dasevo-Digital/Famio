import 'dart:io';
import 'dart:typed_data';
import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    'old reference sizes cannot prevent cached or uncached native opening',
    () async {
      final dir = Directory.systemTemp.createTempSync('famio-metadata-');
      var downloads = 0;
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient((_) async {
          downloads++;
          return http.Response.bytes([1, 2, 3, 4], 200);
        }),
      );
      final cache = FileCache.open(
        ':memory:',
        api,
        tempDir: '${dir.path}/temp',
      );
      addTearDown(() {
        cache.close();
        api.close();
        dir.deleteSync(recursive: true);
      });
      final id = newId();
      for (final size in [-1, 0, 1, 1024, 5 * 1024 * 1024 * 1024]) {
        final ref = FileRef(
          id: id,
          name: 'fixture.bin',
          mime: 'application/octet-stream',
          size: size,
        );
        cache.clear();
        expect(await File(await cache.openable(ref)).readAsBytes(), [
          1,
          2,
          3,
          4,
        ]);
        final before = downloads;
        expect(await File(await cache.openable(ref)).readAsBytes(), [
          1,
          2,
          3,
          4,
        ]);
        expect(downloads, before);
        expect(await cache.bytes(ref), [1, 2, 3, 4]);
      }
      expect(downloads, 5);
    },
  );

  test(
    'actual cached size enforces the memory cap while streaming stays available',
    () async {
      final dir = Directory.systemTemp.createTempSync('famio-cache-cap-');
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient(
          (_) async => throw StateError('Cached fixture must stay offline'),
        ),
      );
      final cache = FileCache.open(
        '${dir.path}/files.db',
        api,
        tempDir: '${dir.path}/temp',
        hexKey: '16' * 32,
      );
      addTearDown(() {
        cache.close();
        api.close();
        dir.deleteSync(recursive: true);
      });
      const size = 129 * 1024 * 1024;
      final ref = FileRef(
        id: newId(),
        name: 'fixture.bin',
        mime: 'application/octet-stream',
        size: size,
      );
      final block = Uint8List(1024 * 1024);
      await cache.putStream(
        ref,
        Stream.fromIterable(Iterable.generate(129, (_) => block)),
      );
      final small = FileRef(
        id: ref.id,
        name: ref.name,
        mime: ref.mime,
        size: 1,
      );
      for (final value in [ref, small]) {
        await expectLater(
          cache.bytes(value),
          throwsA(isA<ApiError>().having((e) => e.status, 'status', 413)),
        );
      }
      expect(await File(await cache.openable(small)).length(), size);
      expect(cache.size, size);
    },
  );

  test(
    'response size decides the cache budget for an outdated small reference',
    () async {
      final dir = Directory.systemTemp.createTempSync('famio-response-budget-');
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient(
          (_) async => http.Response.bytes(List.filled(1024, 7), 200),
        ),
      );
      final cache = FileCache.open(
        ':memory:',
        api,
        tempDir: '${dir.path}/temp',
        maxBytes: 10,
      );
      addTearDown(() {
        cache.close();
        api.close();
        dir.deleteSync(recursive: true);
      });
      final ref = FileRef(
        id: newId(),
        name: 'fixture.bin',
        mime: 'application/octet-stream',
        size: 1,
      );
      expect(await File(await cache.openable(ref)).length(), 1024);
      expect(cache.size, 0);
    },
  );

  test(
    'canonical response length still rejects truncated bodies and permits retry',
    () async {
      final dir = Directory.systemTemp.createTempSync('famio-response-length-');
      var calls = 0;
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.value(++calls == 1 ? [1, 2] : [1, 2, 3, 4]),
            200,
            contentLength: 4,
          ),
        ),
      );
      final cache = FileCache.open(
        ':memory:',
        api,
        tempDir: '${dir.path}/temp',
      );
      addTearDown(() {
        cache.close();
        api.close();
        dir.deleteSync(recursive: true);
      });
      final ref = FileRef(
        id: newId(),
        name: 'fixture.bin',
        mime: 'application/octet-stream',
        size: 1,
      );
      await expectLater(
        cache.openable(ref).timeout(const Duration(seconds: 2)),
        throwsA(isA<ApiError>()),
      );
      expect(cache.size, 0);
      expect(await File(await cache.openable(ref)).readAsBytes(), [1, 2, 3, 4]);
      expect(calls, 2);
    },
  );

  test(
    'failed responses finish even before a storage target is created',
    () async {
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient(
          (_) async =>
              http.Response('{"error":"not_found","message":"Missing"}', 404),
        ),
      );
      final cache = FileCache.open(':memory:', api, tempDir: 'unused');
      addTearDown(() {
        cache.close();
        api.close();
      });
      await expectLater(
        cache
            .openable(
              FileRef(
                id: newId(),
                name: 'fixture',
                mime: 'text/plain',
                size: 4,
              ),
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 404)),
      );
    },
  );
}
