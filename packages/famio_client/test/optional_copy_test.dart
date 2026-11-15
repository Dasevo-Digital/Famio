@TestOn('vm || browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a source whose cancellation waits cannot hold up a successful upload',
    () async {
      final ref = FileRef(
        id: newId(),
        name: 'fixture',
        mime: 'text/plain',
        size: 4,
      );
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient.streaming((_, input) async {
          await input.drain<void>();
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(ref.toJson()))),
            200,
          );
        }),
      );
      final cache = FileCache.open(':memory:', api, tempDir: 'unused');
      final listening = Completer<void>(),
          cancelStarted = Completer<void>(),
          release = Completer<void>();
      final source = StreamController<List<int>>(
        onListen: listening.complete,
        onCancel: () {
          cancelStarted.complete();
          return release.future;
        },
      );
      addTearDown(() async {
        release.complete();
        cache.close();
        api.close();
        if (!source.isClosed) await source.close();
      });
      var reads = 0;
      final result = cache.uploadStream(
        openRead: () =>
            ++reads == 1 ? Stream.value([1, 2, 3, 4]) : source.stream,
        name: ref.name,
        mime: ref.mime,
        length: 4,
        maxBytes: 4,
      );
      await listening.future;
      cache.clear();
      expect((await result.timeout(const Duration(seconds: 2))).id, ref.id);
      await cancelStarted.future.timeout(const Duration(seconds: 2));
      expect(release.isCompleted, isFalse);
      expect(cache.size, 0);
    },
  );
  test(
    'a one-shot source may fail its second listen without failing the upload',
    () async {
      final ref = FileRef(
        id: newId(),
        name: 'fixture',
        mime: 'text/plain',
        size: 4,
      );
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient.streaming((_, input) async {
          await input.drain<void>();
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(ref.toJson()))),
            200,
          );
        }),
      );
      final cache = FileCache.open(':memory:', api, tempDir: 'unused');
      final source = StreamController<List<int>>()..add([1, 2, 3, 4]);
      unawaited(source.close());
      addTearDown(() {
        cache.close();
        api.close();
      });
      final result = await cache
          .uploadStream(
            openRead: () => source.stream,
            name: ref.name,
            mime: ref.mime,
            length: 4,
            maxBytes: 4,
          )
          .timeout(const Duration(seconds: 2));
      expect(result.id, ref.id);
      expect(cache.size, 0);
    },
  );
  for (final action in ['clear', 'close', 'timeout']) {
    test(
      '$action finishes a stalled optional copy after successful upload',
      () async {
        final ref = FileRef(
          id: newId(),
          name: 'fixture.bin',
          mime: 'application/octet-stream',
          size: 4,
        );
        var acknowledged = false, reads = 0;
        final api = FamioApiClient(
          'http://localhost',
          httpClient: MockClient.streaming((_, input) async {
            var size = 0;
            await for (final chunk in input) {
              size += chunk.length;
            }
            expect(size, 4);
            acknowledged = true;
            return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode(ref.toJson()))),
              200,
            );
          }),
        );
        final cache = FileCache.open(
          ':memory:',
          api,
          tempDir: 'unused',
          copyTimeout: action == 'timeout'
              ? const Duration(milliseconds: 40)
              : const Duration(minutes: 1),
        );
        final listening = Completer<void>(), cancelled = Completer<void>();
        final stalled = StreamController<List<int>>(
          onListen: listening.complete,
          onCancel: cancelled.complete,
        );
        addTearDown(() async {
          cache.close();
          api.close();
          if (!stalled.isClosed) await stalled.close();
        });
        final upload = cache.uploadStream(
          openRead: () =>
              ++reads == 1 ? Stream.value([1, 2, 3, 4]) : stalled.stream,
          name: ref.name,
          mime: ref.mime,
          length: 4,
          maxBytes: 4,
        );
        await listening.future.timeout(const Duration(seconds: 2));
        expect(acknowledged, isTrue);
        if (action == 'clear') cache.clear();
        if (action == 'close') cache.close();
        expect((await upload.timeout(const Duration(seconds: 2))).id, ref.id);
        await cancelled.future.timeout(const Duration(seconds: 2));
        stalled.add([9, 9, 9, 9]);
        await stalled.close();
        if (action != 'close') {
          expect(cache.size, 0);
          final next = await cache.uploadStream(
            openRead: () => Stream.value([1, 2, 3, 4]),
            name: ref.name,
            mime: ref.mime,
            length: 4,
            maxBytes: 4,
          );
          expect(await cache.bytes(next), [1, 2, 3, 4]);
        }
      },
    );
  }
  test(
    'a file picker stream of Uint8List over 8 MiB is uploaded and kept',
    () async {
      const chunk = 1024 * 1024, chunks = 9;
      final ref = FileRef(
        id: newId(),
        name: 'big.bin',
        mime: 'application/octet-stream',
        size: chunk * chunks,
      );
      var received = 0;
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient.streaming((_, input) async {
          await for (final part in input) {
            received += part.length;
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(ref.toJson()))),
            200,
          );
        }),
      );
      final cache = FileCache.open(':memory:', api, tempDir: 'unused');
      addTearDown(() {
        cache.close();
        api.close();
      });
      // Like PlatformFile.readAsByteStream: the element type is Uint8List.
      Stream<Uint8List> picked() async* {
        for (var i = 0; i < chunks; i++) {
          yield Uint8List(chunk)..fillRange(0, chunk, i);
        }
      }

      final result = await cache
          .uploadStream(
            openRead: picked,
            name: ref.name,
            mime: ref.mime,
            length: ref.size,
            maxBytes: ref.size,
          )
          .timeout(const Duration(seconds: 20));
      expect(result.id, ref.id);
      expect(received, ref.size);
      expect(cache.size, greaterThanOrEqualTo(ref.size));
    },
  );
  for (final close in [false, true]) {
    test(
      '${close ? 'close' : 'clear'} actively cancels a direct stalled cache writer',
      () async {
        final api = FamioApiClient('http://localhost');
        final cache = FileCache.open(':memory:', api, tempDir: 'unused');
        final listening = Completer<void>(), cancelled = Completer<void>();
        final input = StreamController<List<int>>(
          onListen: listening.complete,
          onCancel: cancelled.complete,
        );
        addTearDown(() async {
          cache.close();
          api.close();
          if (!input.isClosed) await input.close();
        });
        final copying = cache.putStream(
          FileRef(id: newId(), name: 'fixture', mime: 'text/plain', size: 4),
          input.stream,
        );
        final rejected = expectLater(
          copying.timeout(const Duration(seconds: 2)),
          throwsA(isA<StateError>()),
        );
        await listening.future;
        if (close) {
          cache.close();
        } else {
          cache.clear();
        }
        await rejected;
        await cancelled.future.timeout(const Duration(seconds: 2));
        input.add([1, 2, 3, 4]);
        await input.close();
        if (!close) expect(cache.size, 0);
      },
    );
  }
}
