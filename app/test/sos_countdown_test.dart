// The SOS countdown ends itself and raises the alarm, also when something
// opened on top of it meanwhile (a plain pop closed that and swallowed the
// alarm).
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/sos_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets(
    'a sheet opened during the countdown does not swallow the alarm',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final state = AppState();
      await state.init();
      final engine = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: FamioApiClient('localhost:1'),
        memberId: 'm1',
      );
      state
        ..me = engine.members.firstWhere((m) => m.id == 'm1')
        ..engine = engine;
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold).first);

      // As at an app start after an update via the SOS widget: the countdown
      // first, then "Was ist neu" (a root sheet) on top of it.
      startSosCountdown(context);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      Object? sheetResult = 'still open';
      showModalBottomSheet<Object?>(
        context: context,
        useRootNavigator: true,
        builder: (_) => const SizedBox(height: 200, child: Text('Was ist neu')),
      ).then((r) => sheetResult = r);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Was ist neu'), findsOneWidget);

      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // The sheet stays as it was (under the alarm screen), the countdown is
      // gone, the alarm is on.
      expect(sheetResult, 'still open');
      expect(find.text('Was ist neu', skipOffstage: false), findsOneWidget);
      expect(find.byType(SosActiveScreen), findsOneWidget);
    },
  );
}
