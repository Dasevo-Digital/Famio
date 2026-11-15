import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:famio/src/app_state.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final close in [false, true]) {
    test(
      'buffered upload succeeds without repopulating a ${close ? 'closed' : 'cleared'} cache',
      () async {
        final ref = FileRef(
          id: newId(),
          name: 'fixture.bin',
          mime: 'application/octet-stream',
          size: 4,
        );
        late FileCache cache;
        final api = FamioApiClient(
          'http://localhost',
          httpClient: MockClient((_) async {
            if (close) {
              cache.close();
            } else {
              cache.clear();
            }
            return http.Response(jsonEncode(ref.toJson()), 200);
          }),
        );
        final store = LocalStore.open(':memory:');
        final engine = SyncEngine(store: store, api: api, memberId: 'fixture');
        cache = FileCache.open(':memory:', api, tempDir: 'unused');
        final state = AppState()
          ..engine = engine
          ..files = cache;
        addTearDown(() async {
          await engine.dispose();
          store.close();
          cache.close();
          api.close();
        });
        expect(
          (await uploadPickedState(
            state,
            PickedFile([1, 2, 3, 4], ref.name, ref.mime),
          )).id,
          ref.id,
        );
        if (!close) expect(cache.size, 0);
      },
    );
  }
  for (final action in [
    'unchanged',
    'changed',
    'removed',
    'cleared',
    'closed',
  ]) {
    test(
      'streamed upload preserves its contents when source/cache is $action',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'famio-upload-copy-',
        );
        const size = 9 * 1024 * 1024;
        final original = Uint8List(size)..fillRange(0, size, 65);
        final source = File('${directory.path}/source.bin');
        await source.writeAsBytes(original);
        final ref = FileRef(
          id: newId(),
          name: 'source.bin',
          mime: 'application/octet-stream',
          size: size,
        );
        late FileCache cache;
        var uploads = 0, downloads = 0;
        final api = FamioApiClient(
          'http://localhost',
          httpClient: MockClient((request) async {
            if (request.method == 'GET') {
              downloads++;
              return http.Response.bytes(original, 200);
            }
            uploads++;
            expect(request.bodyBytes, original);
            switch (action) {
              case 'changed':
                await source.writeAsBytes(
                  Uint8List(size)..fillRange(0, size, 66),
                );
              case 'removed':
                await source.delete();
              case 'cleared':
                cache.clear();
              case 'closed':
                cache.close();
            }
            return http.Response(jsonEncode(ref.toJson()), 200);
          }),
        );
        final store = LocalStore.open(':memory:');
        final engine = SyncEngine(store: store, api: api, memberId: 'fixture');
        cache = FileCache.open(
          ':memory:',
          api,
          tempDir: '${directory.path}/temp',
        );
        final state = AppState()
          ..engine = engine
          ..files = cache;
        addTearDown(() async {
          await engine.dispose();
          store.close();
          cache.close();
          api.close();
          directory.deleteSync(recursive: true);
        });
        final picked = await pickedFromSource(
          name: ref.name,
          openRead: source.openRead,
          length: source.length,
          maxBytes: size,
          path: source.path,
        );
        expect(picked.bytes, isNull);
        final uploaded = await uploadPickedState(state, picked);
        expect(uploaded.id, ref.id);
        expect(uploads, 1);
        if (action == 'closed') return;
        expect(cache.size, action == 'unchanged' ? size : 0);
        if (action == 'unchanged' ||
            action == 'changed' ||
            action == 'removed') {
          final opened = File(await cache.openable(uploaded));
          expect(await opened.readAsBytes(), original);
          expect(downloads, action == 'unchanged' ? 0 : 1);
        }
      },
    );
  }
  test('a picker stream of Uint8List over 8 MiB is uploaded (#533)', () async {
    const chunk = 1024 * 1024, chunks = 9;
    final ref = FileRef(
      id: newId(),
      name: 'picked.bin',
      mime: 'application/octet-stream',
      size: chunk * chunks,
    );
    final api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient((request) async {
        expect(request.bodyBytes.length, ref.size);
        return http.Response(jsonEncode(ref.toJson()), 200);
      }),
    );
    final store = LocalStore.open(':memory:');
    final engine = SyncEngine(store: store, api: api, memberId: 'fixture');
    final cache = FileCache.open(':memory:', api, tempDir: 'unused');
    final state = AppState()
      ..engine = engine
      ..files = cache;
    addTearDown(() async {
      await engine.dispose();
      store.close();
      cache.close();
      api.close();
    });
    // What file_picker hands over (PlatformFile.readAsByteStream).
    Stream<Uint8List> read() async* {
      for (var i = 0; i < chunks; i++) {
        yield Uint8List(chunk)..fillRange(0, chunk, i);
      }
    }

    final picked = await pickedFromSource(
      name: ref.name,
      openRead: read,
      length: () async => ref.size,
      maxBytes: ref.size,
    );
    expect(picked.bytes, isNull);
    expect((await uploadPickedState(state, picked)).id, ref.id);
  });
  test('any other upload failure becomes a message (#533)', () async {
    final api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient((request) async {
        return http.Response('{}', 200);
      }),
    );
    final store = LocalStore.open(':memory:');
    final engine = SyncEngine(store: store, api: api, memberId: 'fixture');
    final cache = FileCache.open(':memory:', api, tempDir: 'unused');
    final state = AppState()
      ..engine = engine
      ..files = cache;
    addTearDown(() async {
      await engine.dispose();
      store.close();
      cache.close();
      api.close();
    });
    final broken = PickedFile.stream(
      () => throw StateError('source gone'),
      'broken.bin',
      'application/octet-stream',
      sourceLength: 9 * 1024 * 1024,
    );
    await expectLater(
      uploadPickedState(state, broken),
      throwsA(isA<ApiError>().having((e) => e.message, 'message', isNotEmpty)),
    );
  });
}
