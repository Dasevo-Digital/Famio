import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/calendar_connect_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Change notifications arrive asynchronously: one pump delivers the event,
/// the next renders the rebuilt widgets.
Future<void> pumpData(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  Future<void> openCalendar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    engine = SyncEngine(
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
  }

  testWidgets('shows today\'s events and creates new ones', (tester) async {
    await openCalendar(tester);
    final today = DateUtils.dateOnly(DateTime.now());
    engine.saveEvent(
      CalendarEvent(
        id: 'e1',
        title: 'Zahnarzt',
        start: today.add(const Duration(hours: 10)),
        end: today.add(const Duration(hours: 11)),
      ),
    );
    await pumpData(tester);
    // In the month cell and in the agenda.
    expect(find.textContaining('Zahnarzt'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Neuer Termin'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Titel'),
      'Elternabend',
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final created = engine.events.firstWhere((e) => e.title == 'Elternabend');
    expect(DateUtils.isSameDay(created.start, today), isTrue);
    expect(created.reminderMinutes, 15);
    expect(find.textContaining('Elternabend'), findsNWidgets(2));

    await tester.pump(const Duration(seconds: 1)); // Sync debounce.
  });

  testWidgets('deleting one occurrence of a series keeps the rest', (
    tester,
  ) async {
    await openCalendar(tester);
    final today = DateUtils.dateOnly(DateTime.now());
    engine.saveEvent(
      CalendarEvent(
        id: 'series',
        title: 'Training',
        start: today
            .subtract(const Duration(days: 7))
            .add(const Duration(hours: 17)),
        end: today
            .subtract(const Duration(days: 7))
            .add(const Duration(hours: 18)),
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
      ),
    );
    await pumpData(tester);

    await tester.tap(find.text('Training').last); // Agenda entry for today.
    await tester.pumpAndSettle();
    await tester.tap(find.text('Termin löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nur dieser Termin'));
    await tester.pumpAndSettle();

    final series = engine.event('series')!;
    expect(series.exceptions, {today});
    final nextWeek = today.add(const Duration(days: 7));
    expect(
      series
          .occurrencesBetween(today, nextWeek.add(const Duration(days: 1)))
          .map((o) => o.start),
      [nextWeek.add(const Duration(hours: 17))],
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('imported events are shown read-only', (tester) async {
    await openCalendar(tester);
    final today = DateUtils.dateOnly(DateTime.now());
    engine.saveCalendarSubscription(
      const CalendarSubscription(
        id: 'sub',
        name: 'Schule',
        url: 'https://example.org/s.ics',
        color: 0xFF43A047,
      ),
    );
    // Server-imported record, as it would arrive through sync.
    engine.store.put(
      SyncRecord(
        collection: Collections.externalEvents,
        id: 'x1',
        data: CalendarEvent(
          id: 'x1',
          title: 'Wandertag',
          start: today,
          end: today.add(const Duration(days: 1)),
          allDay: true,
          sourceId: 'sub',
        ).toData(),
        updatedAt: 1,
      ),
      dirty: false,
    );
    engine.saveCalendarSubscription(
      const CalendarSubscription(
        id: 'sub',
        name: 'Schule',
        url: 'https://example.org/s.ics',
        color: 0xFF43A047,
      ),
    );
    await pumpData(tester);

    expect(find.text('Wandertag'), findsNWidgets(2));
    await tester.tap(find.text('Wandertag').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Aus „Schule“ – nur lesbar'), findsOneWidget);
    expect(find.text('Termin bearbeiten'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('subscriptions can be added from the connect screen', (
    tester,
  ) async {
    await openCalendar(tester);
    await tester.tap(find.byTooltip('Mit Google/Apple Kalender verbinden'));
    await tester.pumpAndSettle();
    // App passwords, CalDAV accounts and feed links need the server;
    // offline this is explained, not an error.
    expect(
      find.text('Nur mit Verbindung zum Server verfügbar'),
      findsNWidgets(3),
    );

    await tester.scrollUntilVisible(
      find.text('Kalender abonnieren'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(CalendarConnectScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Kalender abonnieren'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Müllabfuhr',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'ICS-Adresse'),
      'ftp://x',
    );
    await tester.tap(find.text('Speichern'));
    await tester.pump();
    expect(find.textContaining('https:// oder webcal://'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'ICS-Adresse'),
      'webcal://example.org/muell.ics',
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    await pumpData(tester);

    final sub = engine.calendarSubscriptions.single;
    expect(sub.name, 'Müllabfuhr');
    expect(sub.url, 'webcal://example.org/muell.ics');
    // Owned by whoever added it, shared with the family by default.
    expect(sub.ownerId, engine.memberId);
    expect(sub.sharing.family, isTrue);
    await tester.scrollUntilVisible(
      find.textContaining(
        'Wird beim nächsten Abgleich geladen …\nVon dir · sichtbar für: '
        'Ganze Familie',
      ),
      200,
      scrollable: find
          .descendant(
            of: find.byType(CalendarConnectScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Müllabfuhr'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
