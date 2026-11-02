import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Documents of Paperless-ngx and photos of PhotoVault reach the apps with
/// size 0: the Famio server passes on their length only when the source
/// sends one.
void main() {
  late Directory directory;
  late List<String> requests;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('famio-external-');
    requests = [];
  });
  tearDown(() => directory.deleteSync(recursive: true));

  FileCache cacheFor(List<int> body, {required bool withLength}) {
    final api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient.streaming((request, _) async {
        requests.add(request.url.path);
        return http.StreamedResponse(
          Stream.fromIterable([body.sublist(0, 2), body.sublist(2)]),
          200,
          contentLength: withLength ? body.length : null,
        );
      }),
    );
    final cache = FileCache.open(
      ':memory:',
      api,
      tempDir: '${directory.path}/temp',
    );
    addTearDown(() {
      cache.close();
      api.close();
    });
    return cache;
  }

  const document = FileRef(
    id: 'pl-11.20260201100000',
    name: 'police.pdf',
    mime: 'application/pdf',
    size: 0,
  );

  test('a document sent without a length opens all the same', () async {
    final cache = cacheFor([1, 2, 3, 4, 5], withLength: false);
    final path = await cache.openable(document);
    expect(await File(path).readAsBytes(), [1, 2, 3, 4, 5]);
    // Not kept offline: how large it is shows only at the end.
    expect(cache.size, 0);
    await cache.openable(document);
    expect(requests, hasLength(2));
  });

  test('with the length it is opened and kept offline', () async {
    final cache = cacheFor([1, 2, 3, 4, 5], withLength: true);
    final path = await cache.openable(document);
    expect(await File(path).readAsBytes(), [1, 2, 3, 4, 5]);
    expect(cache.size, 5);
    await cache.openable(document);
    expect(requests, hasLength(1));
  });

  test('a known size still has to match without a length', () async {
    final cache = cacheFor([1, 2, 3], withLength: false);
    const upload = FileRef(
      id: 'own-file',
      name: 'scan.pdf',
      mime: 'application/pdf',
      size: 5,
    );
    await expectLater(cache.openable(upload), throwsA(isA<ApiError>()));
    expect(cache.size, 0);
    final temp = Directory('${directory.path}/temp');
    expect(temp.existsSync() ? temp.listSync() : const [], isEmpty);
  });
}
