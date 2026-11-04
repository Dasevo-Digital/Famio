import 'dart:async';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/home_shell.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets(
    'Android back: first the page of a section, then to the start page, '
    'only there out of the app',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      var closed = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') closed++;
          return null;
        },
      );

      final state = AppState();
      await state.init();
      final engine = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: FamioApiClient(
          'localhost:1',
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        ),
        memberId: 'm1',
      );
      state
        ..me = engine.members.single
        ..engine = engine;
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pumpAndSettle();

      // A page within the start section, as opened from one of its cards.
      final inSection = tester.element(
        find
            .descendant(
              of: find.byType(HomeShell),
              matching: find.byType(Scaffold),
            )
            .last,
      );
      unawaited(
        Navigator.of(inSection).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Unterseite')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unterseite'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(closed, 0, reason: 'back closed the app');
      expect(find.text('Unterseite'), findsNothing);

      // From another section back to the start page, not out of the app.
      await tester.tap(find.byTooltip('Einkauf'));
      await tester.pumpAndSettle();
      expect(find.text('Was brauchen wir?'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(closed, 0, reason: 'back from the shopping list closed the app');
      expect(find.text('Was brauchen wir?'), findsNothing);

      // On the start page itself, back leaves the app as usual.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(closed, 1);

      await engine.dispose();
    },
  );
}
