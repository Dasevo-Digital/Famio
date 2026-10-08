import 'dart:typed_data';

import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('keeps at most its limit, dropping the longest unused first', () async {
    final downloads = <String>[];
    final api = FamioApiClient(
      'localhost:1',
      httpClient: MockClient((request) async {
        downloads.add(request.url.pathSegments.last);
        return http.Response.bytes(Uint8List(400), 200);
      }),
    );
    final cache = FileCache.open(
      ':memory:',
      api,
      tempDir: '/nonexistent',
      maxBytes: 1000,
    );
    FileRef ref(String id) =>
        FileRef(id: id, name: '$id.jpg', mime: 'image/jpeg', size: 400);
    await cache.bytes(ref('a'));
    await cache.bytes(ref('b'));
    expect(cache.size, 800);
    // "a" is used again, so "b" is the oldest when "c" arrives.
    await cache.bytes(ref('a'));
    await cache.bytes(ref('c'));
    expect(cache.size, 800);
    expect(downloads, ['a', 'b', 'c']);
    await cache.bytes(ref('a'));
    expect(downloads, ['a', 'b', 'c']);
    await cache.bytes(ref('b'));
    expect(downloads, ['a', 'b', 'c', 'b']);

    cache.clear();
    expect(cache.size, 0);
    await cache.bytes(ref('a'));
    expect(downloads.last, 'a');
    cache.close();
  });
}
