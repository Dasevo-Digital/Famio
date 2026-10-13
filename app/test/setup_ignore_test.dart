import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('a step left as it is no longer counts as open', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    // The server's list: PaperBuddy is not wanted in this family.
    final ignored = <String>{};
    List<SetupStep> steps() => [
      const SetupStep(
        id: 'members',
        title: 'Familie eingeladen',
        done: true,
        detail: '3 Mitglieder.',
      ),
      SetupStep(
        id: 'paperbuddy',
        title: 'PaperBuddy verbinden',
        done: false,
        detail: 'Dokumente aus PaperBuddy anzeigen.',
        ignored: ignored.contains('paperbuddy'),
      ),
    ];
    final api = FamioApiClient(
      'localhost:1',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/api/admin/setup/ignored')) {
          final body = jsonDecode(request.body) as Map;
          body['ignored'] == true
              ? ignored.add(body['id'] as String)
              : ignored.remove(body['id']);
          return http.Response('{"ok":true}', 200);
        }
        if (request.url.path.endsWith('/api/admin/setup')) {
          return http.Response(
            jsonEncode({
              'steps': [for (final s in steps()) s.toJson()],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    const me = FamilyMember(
      id: 'm1',
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    final state = AppState();
    await state.init();
    state
      ..me = me
      ..engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: api,
        memberId: me.id,
      );
    // The answers arrive asynchronously; give them time.
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einrichtung abschließen (1 von 2)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ignorieren'));
    await settle();
    expect(ignored, {'paperbuddy'});
    expect(find.text('Alles eingerichtet'), findsOneWidget);
    expect(find.text('PaperBuddy verbinden · Ignoriert'), findsOneWidget);

    // Back on the start page the card is gone; "Wieder anzeigen" undoes it.
    await tester.tap(find.text('Wieder anzeigen'));
    await settle();
    expect(ignored, isEmpty);
    expect(find.text('1 von 2 erledigt'), findsOneWidget);
    await tester.tap(find.text('Ignorieren'));
    await settle();
    await tester.tapAt(const Offset(20, 20));
    await settle();
    expect(find.textContaining('Einrichtung abschließen'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });
}
