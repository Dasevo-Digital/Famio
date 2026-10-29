@TestOn('browser')
library;

import 'dart:async';
import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    'buffered browser reads use actual bytes rather than an old large reference size',
    () async {
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient(
          (_) async => http.Response.bytes([1, 2, 3, 4], 200),
        ),
      );
      final cache = FileCache.open('fixture', api, tempDir: 'unused');
      addTearDown(() {
        cache.close();
        api.close();
      });
      final ref = FileRef(
        id: newId(),
        name: 'fixture',
        mime: 'text/plain',
        size: 129 * 1024 * 1024,
      );
      expect(await cache.bytes(ref), [1, 2, 3, 4]);
      expect(await cache.bytes(ref), [1, 2, 3, 4]);
    },
  );
  for (final close in [false, true]) {
    test(
      '${close ? 'close' : 'clear'} invalidates an unfinished browser file copy',
      () async {
        var downloads = 0;
        final api = FamioApiClient(
          'http://localhost',
          httpClient: MockClient((_) async {
            downloads++;
            return http.Response.bytes([1, 2, 3, 4], 200);
          }),
        );
        final cache = FileCache.open('fixture', api, tempDir: 'unused');
        addTearDown(() {
          cache.close();
          api.close();
        });
        final ref = FileRef(
          id: newId(),
          name: 'fixture',
          mime: 'application/octet-stream',
          size: 4,
        );
        final written = Completer<void>(), resume = Completer<void>();
        Stream<List<int>> chunks() async* {
          yield [1, 2, 3, 4];
          written.complete();
          await resume.future;
        }

        final copying = cache.putStream(ref, chunks());
        final rejected = expectLater(copying, throwsA(isA<StateError>()));
        await written.future;
        if (close) {
          cache.close();
        } else {
          cache.clear();
        }
        resume.complete();
        await rejected;
        expect(cache.size, 0);
        if (!close) {
          expect(await cache.bytes(ref), [1, 2, 3, 4]);
          expect(downloads, 1);
        }
      },
    );
  }
}
