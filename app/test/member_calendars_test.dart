// Switching off a calendar shared with a member on their admin page
// (KAL-132): the switch redraws, and nothing fails on the way.
import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/admin_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('a shared calendar switched off on the member\'s page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    var hidden = <String>[];
    final puts = <List<String>>[];
    http.Response json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    Map<String, Object?> calendars() => {
      'calendars': [
        {
          'source': 'abo1',
          'name': 'Schulkalender',
          'kind': 'subscription',
          'ownerId': 'm1',
          'hidden': hidden.contains('abo1'),
        },
      ],
    };
    final users = [
      for (final (id, name, role, admin) in [
        ('m1', 'Mama', 'adult', true),
        ('k1', 'Mia', 'child', false),
      ])
        <String, Object?>{
          'id': id,
          'username': name.toLowerCase(),
          'displayName': name,
          'isAdmin': admin,
          'role': role,
          'createdAt': DateTime(2026).millisecondsSinceEpoch,
          'sessions': const [],
        },
    ];
    final client = MockClient((r) async {
      final path = r.url.path;
      if (path.endsWith('api/admin/users/k1/calendars')) {
        if (r.method == 'PUT') {
          hidden = [
            for (final s in (jsonDecode(r.body) as Map)['hidden'] as List)
              s as String,
          ];
          puts.add(hidden);
        }
        return json(calendars());
      }
      // Offline for the sync after the change: that is all right.
      if (path.endsWith('api/sync')) return http.Response('', 503);
      if (path.endsWith('api/admin/users')) return json({'users': users});
      if (path.endsWith('api/members')) return json({'members': users});
      if (path.endsWith('api/me')) return json({'hasPassword': true});
      return http.Response('{}', 200);
    });
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1', httpClient: client),
      memberId: 'm1',
    );
    state
      ..me = engine.members.first
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    Navigator.of(tester.element(find.byType(Scaffold).first)).push(
      MaterialPageRoute<void>(
        builder: (_) => const AdminUserScreen(userId: 'k1'),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(SwitchListTile, 'Schulkalender');
    await tester.scrollUntilVisible(tile, 200);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(puts, [
      ['abo1'],
    ]);
    // Redrawn with the server's answer.
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.pump(const Duration(seconds: 1));
  });
}
