// A series every three weeks (from an .ics file or a calendar app) keeps
// its interval when only its title changes in the editor (KAL-030).
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  for (final (frequency, interval, label, back) in [
    (RecurrenceFrequency.weekly, 3, 'Alle 3 Wochen', 21),
    (RecurrenceFrequency.daily, 4, 'Alle 4 Tage', 8),
  ]) {
    testWidgets('a series "$label" keeps its interval', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'tips.off': true});
      FlutterSecureStorage.setMockInitialValues({});
      const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
      final state = AppState();
      await state.init();
      final engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: FamioApiClient('localhost:1'),
        memberId: me.id,
      );
      state
        ..me = me
        ..engine = engine;
      await tester.pumpWidget(FamioApp(state: state));
      await tester.tap(find.text('Kalender').first);
      await tester.pumpAndSettle();

      final today = DateUtils.dateOnly(DateTime.now());
      engine.saveEvent(
        CalendarEvent(
          id: 'series',
          title: 'Chor',
          start: DateTime(today.year, today.month, today.day - back, 18),
          end: DateTime(today.year, today.month, today.day - back, 19),
          recurrence: Recurrence(frequency, interval: interval),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Chor').last); // Today's in the agenda.
      await tester.pumpAndSettle();
      // Offered as it is, not as "Wöchentlich".
      expect(find.text(label), findsWidgets);
      await tester.enterText(
        find.widgetWithText(TextField, 'Titel'),
        'Chor neu',
      );
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alle Termine der Serie'));
      await tester.pumpAndSettle();

      final saved = engine.event('series')!;
      expect(saved.title, 'Chor neu');
      expect(saved.recurrence?.frequency, frequency);
      expect(saved.recurrence?.interval, interval);
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
