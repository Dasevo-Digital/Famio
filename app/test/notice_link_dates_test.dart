// A famio://open link from another app or web page with a date far from
// any calendar's opens nothing broken (#579): the date is left out.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"bea","displayName":"Bea","isAdmin":true},'
    '{"id":"m2","username":"tom","displayName":"Tom"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Future<AppState> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tips.off': true});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final begin = DateTime(2026, 1, 5, 10);
    engine.saveEvent(
      CalendarEvent(
        id: 'weekly',
        title: 'Turnen',
        start: begin,
        end: begin.add(const Duration(hours: 1)),
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
      ),
    );
    state
      ..me = engine.members.firstWhere((m) => m.id == 'm1')
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    return state;
  }

  for (final link in [
    'famio://open?target=day:@%2B275760-09-13T00:00:00.000Z',
    'famio://open?target=event:weekly@%2B275760-09-13T00:00:00.000Z',
  ]) {
    testWidgets(link, (tester) async {
      final state = await start(tester);
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exceptionAsString());
      addTearDown(() => FlutterError.onError = previous);
      state.openRequest.value = NoticeTarget.fromLink(Uri.parse(link));
      await tester.pumpAndSettle();
      FlutterError.onError = previous;
      expect(errors, isEmpty);
      expect(tester.takeException(), isNull);
      // The engine's pending write.
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
