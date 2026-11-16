import 'dart:async';
import 'dart:convert';

import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('a member list that arrives after dispose is dropped quietly', () async {
    final answer = Completer<http.Response>();
    final asked = Completer<void>();
    final api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient((request) {
        if (!asked.isCompleted) asked.complete();
        return answer.future;
      }),
    );
    final store = LocalStore.open(':memory:');
    final engine = SyncEngine(store: store, api: api, memberId: 'mama');
    final refresh = engine.refreshMembers();
    await asked.future;
    await engine.dispose();
    answer.complete(
      http.Response(
        jsonEncode({
          'members': [
            {'id': 'mama', 'username': 'mama', 'displayName': 'Mama'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await expectLater(refresh, completes);
    expect(store.getMeta('members'), isNull);
    store.close();
    api.close();
  });
}
