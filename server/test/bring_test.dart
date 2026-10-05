import 'dart:convert';

import 'package:famio_server/src/lists/bring.dart';
import 'package:famio_server/src/lists/list_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  BringProvider answering(Object body) => BringProvider(
    MockClient(
      (_) async => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      ),
    ),
    {
      'user': 'u',
      'token': 't',
      'expires': DateTime.now()
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch,
    },
  );

  test('reads the current answer', () async {
    final items = await answering({
      'uuid': 'L',
      'status': 'SHARED',
      'items': {
        'purchase': [
          {'uuid': 'a', 'itemId': 'Milch', 'specification': '2 l'},
        ],
        'recently': [
          {'uuid': 'b', 'itemId': 'Brot', 'specification': ''},
        ],
      },
    }).items('L');
    expect(
      [for (final i in items) (i.title, i.note, i.done)],
      [('Milch', '2 l', false), ('Brot', '', true)],
    );
  });

  test('reads the older answer with the lists at the top', () async {
    final items = await answering({
      'uuid': 'L',
      'purchase': [
        {'name': 'Eier', 'specification': '10'},
      ],
      'recently': <Object>[],
    }).items('L');
    expect(items.single.title, 'Eier');
    expect(items.single.note, '10');
  });

  test('an unknown answer is an error, not an empty list', () async {
    await expectLater(
      answering({'uuid': 'L', 'content': <Object>[]}).items('L'),
      throwsA(
        isA<ListProviderException>().having(
          (e) => e.message,
          'message',
          contains('Felder: uuid, content'),
        ),
      ),
    );
  });
}
