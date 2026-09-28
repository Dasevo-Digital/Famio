import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('large JSON answers are gzipped where the client can take it', () async {
    final app = FamioServerApp.inMemory();
    addTearDown(app.close);
    final mama = app.accounts.create(username: 'mama', displayName: 'Mama');
    final token = app.accounts.createSession(mama.id);
    final now = DateTime.now().millisecondsSinceEpoch;
    final request = jsonEncode(
      SyncRequest(
        since: 0,
        changes: [
          for (var i = 0; i < 50; i++)
            SyncRecord(
              collection: Collections.tasks,
              id: 'task-$i',
              data: {'title': 'Aufgabe Nummer $i für die ganze Familie'},
              updatedAt: now,
            ),
        ],
      ).toJson(),
    );
    Future<Response> sync(Map<String, String> extra) async => app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.local/api/sync'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
          ...extra,
        },
        body: request,
      ),
    );

    final packed = await sync({'accept-encoding': 'gzip, deflate'});
    expect(packed.headers['content-encoding'], 'gzip');
    final bytes = await packed.read().expand((b) => b).toList();
    final json = jsonDecode(utf8.decode(gzip.decode(bytes))) as Map;
    expect((json['changes'] as List), hasLength(50));
    expect(int.parse(packed.headers['content-length']!), bytes.length);

    // Not for clients without gzip, nor through Home Assistant's ingress.
    for (final headers in [
      <String, String>{},
      {'accept-encoding': 'gzip', 'x-ingress-path': '/api/hassio_ingress/x'},
    ]) {
      final plain = await sync(headers);
      expect(plain.headers['content-encoding'], isNull);
      expect(jsonDecode(await plain.readAsString()), isA<Map>());
    }
    // Small answers stay as they are.
    final health = await app.handler(
      Request(
        'GET',
        Uri.parse('http://famio.local/api/health'),
        headers: {'accept-encoding': 'gzip'},
      ),
    );
    expect(health.headers['content-encoding'], isNull);
  });
}
