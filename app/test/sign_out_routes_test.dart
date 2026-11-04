import 'dart:async';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/notes_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('signed out from elsewhere while a sheet is open: it closes '
      'instead of failing without the session', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    final api = FamioApiClient(
      'localhost:1',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: api,
      memberId: 'm1',
    );
    state
      ..me = engine.members.single
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const NotesScreen())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Notiz anlegen'));
    await tester.pumpAndSettle();
    expect(find.text('Neue Notiz'), findsOneWidget);

    // As when "Das war ich nicht" on another device ends this session.
    // (Signing out goes on to delete the local files, which needs real
    // I/O; the session itself ends first.)
    unawaited(state.signOut(notice: 'Von einem anderen Gerät abgemeldet'));
    for (var i = 0; i < 50 && state.engine != null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(state.engine, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(find.text('Neue Notiz'), findsNothing);
    expect(find.text('Von einem anderen Gerät abgemeldet'), findsOneWidget);
  });
}
