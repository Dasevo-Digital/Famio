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

/// An emergency needs no unlocking: the countdown shows over the app lock
/// and can be cancelled there; afterwards the lock is back (#516).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('the countdown shows over the lock and can be cancelled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'appLock.enabled': true});
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
    expect(state.lock.locked, isTrue);
    expect(find.text('Famio ist gesperrt'), findsOneWidget);

    startSosCountdown(tester.element(find.byType(Scaffold).first));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Famio ist gesperrt'), findsNothing);
    final cancel = find.text('Abbrechen').hitTestable();
    expect(cancel, findsOneWidget);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(SosActiveScreen, skipOffstage: false), findsNothing);
    expect(state.lock.locked, isTrue);
    expect(find.text('Famio ist gesperrt'), findsOneWidget);
  });
}
