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
    '{"id":"m2","username":"papa","displayName":"Papa","isAdmin":true}]';

/// Role changes and admin rights are asked first, and who gives up their
/// own rights confirms it with the password (#487).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late List<Map<String, Object?>> patches;

  Future<void> open(WidgetTester tester, String userId) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    patches = [];
    final users = {
      for (final (id, name) in [('m1', 'Mama'), ('m2', 'Papa')])
        id: <String, Object?>{
          'id': id,
          'username': name.toLowerCase(),
          'displayName': name,
          'isAdmin': true,
          'role': 'adult',
          'createdAt': DateTime(2026).millisecondsSinceEpoch,
          'sessions': const [],
        },
    };
    http.Response json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    final client = MockClient((r) async {
      final path = r.url.path;
      if (path.endsWith('api/admin/users') && r.method == 'GET') {
        return json({'users': users.values.toList()});
      }
      if (r.method == 'PATCH') {
        final body = (jsonDecode(r.body) as Map).cast<String, Object?>();
        patches.add({'path': path, ...body});
        final user = users[path.split('/').last]!;
        user['role'] = body['role'] ?? user['role'];
        user['isAdmin'] = body['isAdmin'] ?? user['isAdmin'];
        return json(user);
      }
      if (path.endsWith('api/me')) return json({'hasPassword': true});
      if (path.endsWith('api/members')) {
        return json({'members': users.values.toList()});
      }
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
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AdminUserScreen(userId: userId)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a role is asked first', (tester) async {
    await open(tester, 'm2');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Kind'));
    await tester.pumpAndSettle();
    expect(find.text('Rolle ändern?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(patches, isEmpty);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Kind'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ändern'));
    await tester.pumpAndSettle();
    // Someone else's role needs no password.
    expect(find.text('Passwort bestätigen'), findsNothing);
    expect(patches.single['role'], 'child');
    expect(patches.single.containsKey('password'), isFalse);
  });

  testWidgets('the own role with the password', (tester) async {
    await open(tester, 'm1');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Gast'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ändern'));
    await tester.pumpAndSettle();
    expect(find.text('Passwort bestätigen'), findsOneWidget);
    // Cancelled: nothing changes.
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(patches, isEmpty);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Gast'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ändern'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'tulpe-regal-7');
    await tester.tap(find.text('Bestätigen'));
    await tester.pumpAndSettle();
    expect(patches.single, {
      'path': '/api/admin/users/m1',
      'role': 'guest',
      'isAdmin': false,
      'password': 'tulpe-regal-7',
    });
  });

  testWidgets('giving up admin rights is asked, the own with the password', (
    tester,
  ) async {
    await open(tester, 'm1');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Eigene Administratorrechte abgeben?'), findsOneWidget);
    await tester.tap(find.text('Rechte entziehen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'tulpe-regal-7');
    await tester.tap(find.text('Bestätigen'));
    await tester.pumpAndSettle();
    expect(patches.single['isAdmin'], false);
    expect(patches.single['password'], 'tulpe-regal-7');
  });
}
