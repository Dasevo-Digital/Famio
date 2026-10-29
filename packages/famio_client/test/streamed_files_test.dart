import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:famio_client/famio_client.dart';
import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class LargeFileClient extends http.BaseClient {
  var calls = 0;
  final block = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 7);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    return http.StreamedResponse(
      Stream.fromIterable(Iterable.generate(129, (_) => block)),
      200,
      contentLength: 129 * block.length,
    );
  }
}

class StreamingOnlyApi extends FamioApiClient {
  StreamingOnlyApi(http.Client client)
    : super('http://localhost', httpClient: client);
  @override
  Future<List<int>> downloadFile(String id, {int? thumb}) =>
      throw StateError('Full buffer path used');
}

void main() {
  test(
    'a temp-folder failure before listening still cancels and completes',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'famio-unwritable-target-',
      );
      final target = File('${directory.path}/not-a-directory')
        ..writeAsStringSync('fixture');
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient(
          (_) async => http.Response.bytes(List.filled(1024, 1), 200),
        ),
      );
      final cache = FileCache.open(
        '${directory.path}/db',
        api,
        tempDir: target.path,
        maxBytes: 10,
      );
      addTearDown(() {
        cache.close();
        api.close();
        directory.deleteSync(recursive: true);
      });
      await expectLater(
        cache
            .openable(
              FileRef(
                id: newId(),
                name: 'fixture',
                mime: 'application/octet-stream',
                size: 1024,
              ),
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'file_storage')),
      );
    },
  );
  test(
    'a truncated download leaves no partial cache and can be retried',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'famio-truncated-file-',
      );
      var calls = 0;
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.value(++calls == 1 ? [1, 2] : [1, 2, 3, 4, 5]),
            200,
            contentLength: 5,
          ),
        ),
      );
      final cache = FileCache.open(
        '${directory.path}/db',
        api,
        tempDir: '${directory.path}/temp',
      );
      addTearDown(() {
        cache.close();
        api.close();
        directory.deleteSync(recursive: true);
      });
      final ref = FileRef(
        id: newId(),
        name: 'fixture.txt',
        mime: 'text/plain',
        size: 5,
      );
      await expectLater(
        cache.openable(ref).timeout(const Duration(seconds: 2)),
        throwsA(isA<ApiError>()),
      );
      expect(cache.size, 0);
      final path = await cache
          .openable(ref)
          .timeout(const Duration(seconds: 2));
      expect(File(path).readAsBytesSync(), [1, 2, 3, 4, 5]);
      expect(calls, 2);
    },
  );
  test('a file exceeding the offline budget still opens completely', () async {
    final directory = Directory.systemTemp.createTempSync(
      'famio-cache-budget-',
    );
    final api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient(
        (_) async => http.Response.bytes(List.filled(1024, 3), 200),
      ),
    );
    final cache = FileCache.open(
      '${directory.path}/db',
      api,
      tempDir: '${directory.path}/temp',
      maxBytes: 10,
    );
    addTearDown(() {
      cache.close();
      api.close();
      directory.deleteSync(recursive: true);
    });
    final path = await cache.openable(
      FileRef(
        id: newId(),
        name: 'fixture',
        mime: 'application/octet-stream',
        size: 1024,
      ),
    );
    expect(await File(path).length(), 1024);
    expect(cache.size, 0);
  });
  test(
    '129 MiB opens and remains available offline through encrypted blocks',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'famio-stream-file-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final client = LargeFileClient();
      final api = StreamingOnlyApi(client);
      final ref = FileRef(
        id: newId(),
        name: 'large.bin',
        mime: 'application/octet-stream',
        size: 129 * 1024 * 1024,
      );
      FileCache open() => FileCache.open(
        '${directory.path}/files.db',
        api,
        tempDir: '${directory.path}/temp',
        hexKey: '16' * 32,
        maxBytes: 200 * 1024 * 1024,
      );
      var cache = open();
      var file = File(await cache.openable(ref));
      expect(await file.length(), ref.size);
      final handle = await file.open();
      await handle.setPosition(ref.size - 1);
      expect(await handle.readByte(), 7);
      await handle.close();
      expect(cache.size, ref.size);
      await expectLater(
        cache.bytes(ref),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 413)),
        reason:
            'the explicitly buffered path remains bounded, including cached files',
      );
      cache.clearTemp();
      cache.close();
      cache = open();
      file = File(await cache.openable(ref));
      expect(await file.length(), ref.size);
      expect(
        client.calls,
        1,
        reason: 'reopening uses the encrypted offline copy',
      );
      cache.close();
      api.close();
    },
  );
  test(
    'streamed uploads enforce the limit without collecting the request',
    () async {
      final member = newId();
      final fileId = newId();
      var received = 0;
      final client = MockClient.streaming((request, body) async {
        await for (final chunk in body) {
          received += chunk.length;
        }
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'id': fileId,
                'name': 'fixture',
                'mime': 'text/plain',
                'size': received,
              }),
            ),
          ),
          200,
        );
      });
      final api = FamioApiClient('http://localhost', httpClient: client);
      final ref = await api.uploadFileStream(
        stream: Stream.fromIterable([
          [1, 2],
          [3],
        ]),
        name: member,
        mime: 'text/plain',
        maxBytes: 3,
        length: 3,
      );
      expect(ref.size, 3);
      expect(received, 3);
      await expectLater(
        api.uploadFileStream(
          stream: Stream.value([1, 2, 3, 4]),
          name: 'too-large',
          mime: 'text/plain',
          maxBytes: 3,
        ),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 413)),
      );
      api.close();
    },
  );
  test(
    'sync negotiates changed server limits and keeps them across restart',
    () async {
      final app = FamioServerApp.inMemory();
      final member = app.accounts.create(
        username: 'member',
        displayName: 'Member',
      );
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode(
              app.records
                  .sync(
                    SyncRequest.fromJson(
                      (jsonDecode(request.body) as Map).cast(),
                    ),
                    member.id,
                  )
                  .toJson(),
            ),
            200,
          ),
        ),
      );
      final store = LocalStore.open(':memory:');
      var engine = SyncEngine(store: store, api: api, memberId: member.id);
      app.settings.update({'maxUploadMb': 200});
      await engine.sync();
      expect(engine.maxUploadBytes, 200 * 1024 * 1024);
      app.settings.update({'maxUploadMb': 300});
      await engine.sync();
      await engine.dispose();
      engine = SyncEngine(store: store, api: api, memberId: member.id);
      expect(engine.maxUploadBytes, 300 * 1024 * 1024);
      await engine.dispose();
      store.close();
      api.close();
      await app.close();
      Directory(app.dataDir).deleteSync(recursive: true);
    },
  );
}
