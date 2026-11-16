// Appointments read from a letter keep the family's time, also when the
// device is in another zone (#296, KAL-080): "19:30 Uhr" is 19:30 where the
// family lives, in the preview, the form and what is saved.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/event_extract.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/event_import_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as zones;
import 'package:timezone/timezone.dart' as tz;

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  // Before choosing the zone below.
  zones.initializeTimeZones();

  // Ten days ahead, a day without a change of daylight saving time nearby
  // does not matter: both are compared as instants.
  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day + 10);

  /// A family zone whose 19:30 on [day] is another instant than the
  /// device's 19:30: Tokyo and New York cannot both be the device's.
  final zone = ['Asia/Tokyo', 'America/New_York'].firstWhere(
    (z) =>
        tz.TZDateTime(
          tz.getLocation(z),
          day.year,
          day.month,
          day.day,
          19,
          30,
        ).timeZoneOffset !=
        DateTime(day.year, day.month, day.day, 19, 30).timeZoneOffset,
  );
  DateTime there(int hour, int minute) => tz.TZDateTime(
    tz.getLocation(zone),
    day.year,
    day.month,
    day.day,
    hour,
    minute,
  );

  final letter =
      'Elternabend am ${day.day}.${day.month}.${day.year} um 19:30 Uhr';

  test('a recognised time is an instant of the family\'s zone', () {
    final found = extractEvents(letter, timeZone: zone).single;
    expect(found.allDay, isFalse);
    expect(
      found.start.toUtc(),
      there(19, 30).toUtc(),
      reason: '19:30 in $zone, the device is in ${now.timeZoneName}',
    );
    expect(found.end.toUtc(), there(20, 30).toUtc());
    // Shown as the family's 19:30.
    expect((found.start.hour, found.start.minute), (19, 30));
  });

  test('an all-day date starts at the family\'s midnight', () {
    final found = extractEvents(
      'Wandertag am ${day.day}.${day.month}.${day.year}',
      timeZone: zone,
    ).single;
    expect(found.allDay, isTrue);
    expect(found.start.toUtc(), there(0, 0).toUtc());
    expect(
      (found.start.year, found.start.month, found.start.day),
      (day.year, day.month, day.day),
    );
    final next = tz.TZDateTime(
      tz.getLocation(zone),
      day.year,
      day.month,
      day.day + 1,
    );
    expect(found.end.toUtc(), next.toUtc());
  });

  test('without a family zone the device\'s time as before', () {
    final found = extractEvents(letter).single;
    expect(found.start, DateTime(day.year, day.month, day.day, 19, 30));
  });

  group('the import page', () {
    late SyncEngine engine;

    Future<void> search(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final state = AppState();
      await state.init();
      engine = SyncEngine(
        store: LocalStore.open(':memory:')
          ..setMeta('members', _members)
          ..setMeta('familyTimeZone', zone),
        api: FamioApiClient('localhost:1'),
        memberId: 'm1',
      );
      state
        ..me = engine.members.single
        ..engine = engine;
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold).first);
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const EventImportScreen()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Oder Text hier einfügen'),
        letter,
      );
      await tester.tap(find.text('Termine suchen'));
      await tester.pumpAndSettle();
    }

    testWidgets('takes the time over as the family\'s', (tester) async {
      await search(tester);
      // The preview says the family's 19:30.
      expect(find.textContaining('19:30–20:30'), findsOneWidget);
      await tester.tap(find.text('1 Termin übernehmen'));
      await tester.pumpAndSettle();
      final event = engine.events.single;
      expect(event.start.toUtc(), there(19, 30).toUtc());
      expect(event.end.toUtc(), there(20, 30).toUtc());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the form shows and saves the family\'s time', (tester) async {
      await search(tester);
      await tester.tap(find.byTooltip('Termin bearbeiten'));
      await tester.pumpAndSettle();
      expect(find.text('19:30'), findsOneWidget);
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      final event = engine.events.single;
      expect(event.start.toUtc(), there(19, 30).toUtc());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
