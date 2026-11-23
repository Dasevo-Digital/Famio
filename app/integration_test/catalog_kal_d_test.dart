// Catalog KAL, entries of 23.11.2026 (country of the family, Austria and
// Switzerland, children and appointments of others, school letters, the
// last attachment, notices with their target) and the parts of changed
// entries the older files do not check, against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_kal_d_test.dart
//
// The helpers come from catalog_kal_a_test.dart and catalog_kal_b_test.dart
// (same server setup, same calendar on screen). Tests that switch the
// country of the family switch it back to Germany at their end: the tests
// of this file share one server.
import 'dart:convert';

import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/country.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/holidays.dart';
import 'package:famio/src/data/school_bag.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/format.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/event_import_screen.dart';
import 'package:famio/src/screens/free_time_screen.dart';
import 'package:famio/src/screens/ics_import_screen.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'catalog_kal_a_test.dart' as a;
import 'catalog_kal_b_test.dart' hide main;
import 'catalog_kit.dart';

const _holidayGrey = Color(0xFF7A8796);
const _schoolBlue = Color(0xFF5B8DEF);

/// The tests switch the country of the family; afterwards it is Germany
/// without a state again, as for every other test of the file.
void resetCountryAfter(KitFamily f) => addTearDown(
  () => f.admin.updateServerSettings({'country': 'DE', 'holidayRegion': null}),
);

/// Until the app took over the country and region of the server.
Future<void> countryIs(
  WidgetTester tester,
  FamilyCountry country,
  HolidayRegion? region,
) => eventually(
  tester,
  'the app follows: $country, $region',
  () async => familyCountry == country && familyHolidayRegion == region,
);

/// The entries of the drop-down [label] (also those not on screen).
List<DropdownMenuItem<Object?>> itemsOf(WidgetTester tester, String label) => [
  for (final e
      in find
          .descendant(
            of: a.dropdownOf(label),
            matching: find.byWidgetPredicate(
              (w) => w is DropdownMenuItem,
              skipOffstage: false,
            ),
            skipOffstage: false,
          )
          .evaluate())
    e.widget as DropdownMenuItem<Object?>,
];

String itemText(DropdownMenuItem<Object?> item) =>
    (item.child as Text).data ?? '';

/// Server-Verwaltung → Einstellungen: saved.
Future<void> saveSettings(WidgetTester tester) async {
  await scrollTo(tester, find.text(de.commonSave));
  await tap(tester, find.text(de.commonSave).last);
  await waitFor(tester, find.text(de.adminServerSettingsSaved));
  await snackGone(tester);
}

/// The setup list of the status tab: the step [title] with [detail].
Future<void> setupStep(WidgetTester tester, String title, String detail) async {
  await tap(tester, find.text('Status').last);
  await waitFor(tester, find.text(de.adminSetup));
  await scrollTo(tester, find.text(de.adminSetup));
  await waitFor(tester, find.text(title));
  await tester.ensureVisible(find.text(title));
  await tester.pump(const Duration(milliseconds: 300));
  final row = find
      .ancestor(of: find.text(title), matching: find.byType(Column))
      .first;
  expect(
    find.descendant(of: row, matching: find.text(detail)),
    findsOneWidget,
    reason: '$title: $detail',
  );
}

/// [title] on [day] in the day list: a public holiday (grey, "Feiertag")
/// or a school holiday (blue, "Schulferien").
Future<void> holidayOn(
  WidgetTester tester,
  AppState state,
  DateTime day,
  String title, {
  bool school = false,
}) async {
  await selectDay(tester, state, day);
  await waitFor(tester, find.text(title));
  if (!school) expect(timeOf(tester, title), de.commonAllDayLower);
  expect(barOf(tester, title), school ? _schoolBlue : _holidayGrey);
  expect(
    find.descendant(
      of: tileOf(title),
      matching: find.byTooltip(
        school ? de.calendarSchoolHolidays : de.calendarPublicHoliday,
      ),
    ),
    findsOneWidget,
    reason: '$title on $day',
  );
}

Future<void> noHoliday(
  WidgetTester tester,
  AppState state,
  DateTime day,
  String title,
) async {
  await selectDay(tester, state, day);
  await tester.pump(const Duration(milliseconds: 600));
  expect(find.text(title), findsNothing, reason: '$title on $day');
}

/// The texts of the open bottom sheet.
List<String> sheetTexts() => [
  for (final e
      in find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byWidgetPredicate(
              (w) => w is Text || w is EditableText,
            ),
          )
          .evaluate())
    switch (e.widget) {
      final Text t => t.data ?? t.textSpan?.toPlainText() ?? '',
      final EditableText t => t.controller.text,
      _ => '',
    },
];

/// Sends appointment [id] changed like another device of [api]'s member;
/// the server's answer.
Future<SyncResponse> send(
  FamioApiClient api,
  String id,
  Map<String, Object?> Function(Map<String, Object?> data) change,
) async {
  final record = (await eventOf(api, id))!;
  return put(api, Collections.events, {
    id: change({...record.data}),
  });
}

/// The code under "refused" for [id] (`partly_kept`, `not_allowed`).
String? refusedCode(SyncResponse r, String id) =>
    r.refused.where((i) => i.id == id).firstOrNull?.code;

/// Waits until the app has [id] as [ok] says.
Future<void> inApp(
  WidgetTester tester,
  AppState state,
  String id,
  bool Function(CalendarEvent? e) ok,
  String what,
) => eventually(tester, what, () async {
  await state.engine!.sync();
  return ok(state.engine!.event(id));
});

Future<void> closeTopSheet(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pump(const Duration(milliseconds: 300));
  await waitGone(
    tester,
    find.byType(BottomSheet),
    timeout: const Duration(seconds: 10),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

final taskSheetSave = find.widgetWithText(ColorButton, de.commonSave);

String shortDay(DateTime d) => DateFormat.yMMMEd('de').format(d);

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // --- Land der Familie --------------------------------------------------------

  testWidgets(
    'KAL-169 KAL-175 the country with its states or cantons, the setup list',
    (tester) async {
      final f = await setUpFamily(tester);
      resetCountryAfter(f);
      await f.admin.updateServerSettings({'holidayRegion': 'BY'});
      final state = await startApp(tester);
      await openAdmin(tester, 'Einstellungen');
      await scrollTo(tester, a.dropdownOf(de.adminCountry));
      expect(a.valueOf(tester, de.adminCountry), FamilyCountry.de);
      expect(find.text(de.adminCountryHelper), findsOneWidget);
      expect(a.valueOf(tester, de.adminFederalState), GermanState.by);
      expect(
        find.text(de.adminSubscribeSchoolHolidaysRegion('Bayern')),
        findsOneWidget,
      );

      // Austria: no state, the nine of Austria.
      await choose(tester, de.adminCountry, 'Österreich');
      expect(a.valueOf(tester, de.adminFederalState), isNull);
      expect(itemsOf(tester, de.adminFederalState).map(itemText), [
        de.adminNoPublicHolidays,
        for (final s in AustrianState.values) s.label,
      ]);
      expect(
        find.textContaining(RegExp(r'^Schulferien .+ abonnieren$')),
        findsNothing,
      );
      // Switzerland: "Kanton", the 26 cantons.
      await choose(tester, de.adminCountry, 'Schweiz');
      expect(find.text(de.adminCanton), findsOneWidget);
      expect(find.text(de.adminFederalState), findsNothing);
      expect(a.valueOf(tester, de.adminCanton), isNull);
      final cantons = itemsOf(tester, de.adminCanton).map(itemText).toList();
      expect(cantons, [
        de.adminNoPublicHolidays,
        for (final c in SwissCanton.values) c.label,
      ]);
      expect(cantons, hasLength(27));
      expect(find.text(de.adminSchoolHolidaysSwitzerland), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'^Schulferien .+ abonnieren$')),
        findsNothing,
      );
      await saveSettings(tester);

      // KAL-175: without a canton, then with one.
      await setupStep(
        tester,
        'Kanton für Feiertage',
        'Ohne Kanton zeigt der Kalender keine Feiertage.',
      );
      final open = (await f.admin.setupChecklist()).singleWhere(
        (s) => s.id == 'region',
      );
      expect(open.done, isFalse);
      await tap(tester, find.text('Einstellungen').last);
      await scrollTo(tester, a.dropdownOf(de.adminCanton));
      await choose(tester, de.adminCanton, 'Zürich');
      await saveSettings(tester);
      await setupStep(
        tester,
        'Kanton für Feiertage',
        'Die Feiertage erscheinen im Kalender.',
      );
      // Germany: the step is about the federal state again.
      await tap(tester, find.text('Einstellungen').last);
      await scrollTo(tester, a.dropdownOf(de.adminCountry));
      await choose(tester, de.adminCountry, 'Deutschland');
      expect(a.valueOf(tester, de.adminFederalState), isNull);
      await choose(tester, de.adminFederalState, 'Nordrhein-Westfalen');
      await saveSettings(tester);
      await setupStep(
        tester,
        'Bundesland für Feiertage',
        'Feiertage und Schulferien erscheinen im Kalender.',
      );

      // Austria and Vienna, saved and opened again.
      await tap(tester, find.text('Einstellungen').last);
      await scrollTo(tester, a.dropdownOf(de.adminCountry));
      await choose(tester, de.adminCountry, 'Österreich');
      await choose(tester, de.adminFederalState, 'Wien');
      expect(find.text(de.adminSchoolHolidaysAustria), findsOneWidget);
      await saveSettings(tester);
      await setupStep(
        tester,
        'Bundesland für Feiertage',
        'Feiertage und Schulferien erscheinen im Kalender.',
      );
      await back(tester);
      await openAdmin(tester, 'Einstellungen');
      await scrollTo(tester, a.dropdownOf(de.adminCountry));
      expect(a.valueOf(tester, de.adminCountry), FamilyCountry.at);
      expect(a.valueOf(tester, de.adminFederalState), AustrianState.w);
      final overview = await f.admin.adminOverview();
      expect(overview.settings.country, 'AT');
      expect(overview.settings.holidayRegion, 'AT-9');
      await countryIs(tester, FamilyCountry.at, AustrianState.w);
      // Hint: only the country changed, the server drops the old region.
      final swiss = await f.admin.updateServerSettings({'country': 'CH'});
      expect(swiss.settings.country, 'CH');
      expect(swiss.settings.holidayRegion, isNull);
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-171 KAL-172 KAL-176 Austria: holidays and school holidays on another device, also offline',
    (tester) async {
      final f = await setUpFamily(tester);
      resetCountryAfter(f);
      final gate = Gate(Uri.parse(kitUrl));
      await gate.start();
      addTearDown(gate.close);
      var state = await startVia(
        tester,
        gate.url,
        'e2e-bea',
        kitMemberPassword,
      );
      await countryIs(tester, FamilyCountry.de, null);
      // KAL-176: the admin chooses it on another device; Bea's app follows
      // without signing in again.
      await f.admin.updateServerSettings({
        'country': 'AT',
        'holidayRegion': 'AT-9',
      });
      await countryIs(tester, FamilyCountry.at, AustrianState.w);
      await openCalendar(tester);

      // KAL-171
      for (final (day, title) in [
        (DateTime(2026, 10, 26), 'Nationalfeiertag'),
        (DateTime(2026, 11, 1), 'Allerheiligen'),
        (DateTime(2026, 12, 8), 'Mariä Empfängnis'),
        (DateTime(2026, 12, 25), 'Weihnachten'),
        (DateTime(2026, 12, 26), 'Stefanitag'),
        (DateTime(2026, 4, 6), 'Ostermontag'),
      ]) {
        await holidayOn(tester, state, day, title);
      }
      await noHoliday(tester, state, DateTime(2026, 4, 3), 'Karfreitag');
      expect(
        agenda().where((t) => t.contains('Feiertag')),
        isEmpty,
        reason: 'nothing on Good Friday',
      );
      await holidayOn(
        tester,
        state,
        DateTime(2026, 10, 26),
        'Nationalfeiertag',
      );
      await tap(tester, find.text('Nationalfeiertag'));
      await waitFor(tester, find.text(de.holidayStatutoryIn('Wien')));
      expect(find.text(de.calendarAdminsSetFederalState), findsOneWidget);
      expect(editorOpen, findsNothing);
      await closeSheet(tester);

      // KAL-172
      for (final (day, title) in [
        (DateTime(2026, 10, 27), 'Herbstferien'),
        (DateTime(2026, 10, 30), 'Herbstferien'),
        (DateTime(2026, 11, 2), 'Allerseelen (schulfrei)'),
        (DateTime(2026, 11, 15), 'Hl. Leopold (schulfrei)'),
        (DateTime(2026, 12, 24), 'Weihnachtsferien'),
        (DateTime(2027, 1, 4), 'Weihnachtsferien'),
      ]) {
        await holidayOn(tester, state, day, title, school: true);
      }
      await noHoliday(tester, state, DateTime(2027, 1, 7), 'Weihnachtsferien');
      await holidayOn(
        tester,
        state,
        DateTime(2026, 10, 27),
        'Herbstferien',
        school: true,
      );
      await tap(tester, find.text('Herbstferien'));
      await waitFor(tester, find.text(de.holidaySchoolIn('Wien')));
      expect(editorOpen, findsNothing);
      await closeSheet(tester);
      // Hint: the sheet of a holiday of several days names its first day.
      await holidayOn(
        tester,
        state,
        DateTime(2027, 1, 4),
        'Weihnachtsferien',
        school: true,
      );
      await tap(tester, find.text('Weihnachtsferien'));
      await waitFor(tester, find.text(de.holidaySchoolIn('Wien')));
      final when = sheetTexts();
      debugPrint(
        'E2E-INFO sheet of the Christmas holidays opened on 4.1.2027: $when',
      );
      debugPrint(
        'E2E-INFO it names the first day only: '
        '${when.contains(dayLabel(DateTime(2026, 12, 24)))}, '
        'the day opened: ${when.contains(dayLabel(DateTime(2027, 1, 4)))}',
      );
      await closeSheet(tester);
      // No subscription for it.
      expect(state.engine!.calendarSubscriptions, isEmpty);
      expect(await pull(f.admin, Collections.calendarSubscriptions), isEmpty);
      // The admin reads the hint under the state.
      final admin = await f.admin.adminOverview();
      expect(admin.settings.holidayRegion, 'AT-9');

      // KAL-176: the emergency numbers of Austria on Bea's own page.
      Future<void> myEmergency() async {
        await openSection(tester, 'Einstellungen');
        await scrollTo(tester, find.text(de.memberEmergencyMine));
        await tap(tester, find.text(de.memberEmergencyMine));
        for (final text in [
          '144 – ${de.emergencyRescue}',
          de.emergencyHealthLineAt,
          de.emergencyDoctorsAt,
          de.emergencyPoisonAt,
        ]) {
          await scrollTo(tester, find.text(text), up: true);
        }
        expect(find.text(de.kidsOutHoursMedicalService), findsNothing);
        expect(find.text(de.kids03019240ReachableNationwide), findsNothing);
        await back(tester);
      }

      await myEmergency();

      // Without a connection, opened again: country and state stay.
      gate.cut();
      familyCountry = FamilyCountry.de;
      familyHolidayRegion = null;
      state = await restart(tester, state);
      expect(familyCountry, FamilyCountry.at, reason: 'kept on the device');
      expect(familyHolidayRegion, AustrianState.w);
      await openCalendar(tester);
      await holidayOn(
        tester,
        state,
        DateTime(2026, 10, 26),
        'Nationalfeiertag',
      );
      await holidayOn(
        tester,
        state,
        DateTime(2026, 10, 27),
        'Herbstferien',
        school: true,
      );
      await myEmergency();
      gate.restore();
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-174 KAL-138 Switzerland by canton, no school holidays; the sheet names the state',
    (tester) async {
      final f = await setUpFamily(tester);
      resetCountryAfter(f);
      await f.admin.updateServerSettings({
        'country': 'CH',
        'holidayRegion': null,
      });
      final state = await startApp(tester);
      await countryIs(tester, FamilyCountry.ch, null);
      await openAdmin(tester, 'Einstellungen');
      await scrollTo(tester, a.dropdownOf(de.adminCanton));
      expect(find.text(de.adminSchoolHolidaysSwitzerland), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'^Schulferien .+ abonnieren$')),
        findsNothing,
      );
      await choose(tester, de.adminCanton, 'Zürich');
      await saveSettings(tester);
      await back(tester);
      await countryIs(tester, FamilyCountry.ch, SwissCanton.zh);
      await openCalendar(tester);
      for (final (day, title) in [
        (DateTime(2026, 1, 2), 'Berchtoldstag'),
        (DateTime(2026, 4, 3), 'Karfreitag'),
        (DateTime(2026, 5, 1), 'Tag der Arbeit'),
        (DateTime(2026, 8, 1), 'Bundesfeier'),
        (DateTime(2026, 12, 26), 'Stephanstag'),
      ]) {
        await holidayOn(tester, state, day, title);
      }
      await tap(tester, find.text('Stephanstag'));
      await waitFor(tester, find.text(de.holidayStatutoryIn('Zürich')));
      expect(find.text(de.calendarAdminsSetCanton), findsOneWidget);
      expect(editorOpen, findsNothing);
      await closeSheet(tester);
      bool school(DateTime from, DateTime to) =>
          holidayEvents(from, to).any((e) => isSchoolHolidaySource(e.sourceId));
      expect(school(DateTime(2026), DateTime(2027, 2)), isFalse);
      await selectDay(tester, state, DateTime(2026, 10, 27));
      expect(find.byTooltip(de.calendarSchoolHolidays), findsNothing);

      // Ticino: no Good Friday, but Saint Joseph and Peter and Paul.
      await f.admin.updateServerSettings({'holidayRegion': 'CH-TI'});
      await countryIs(tester, FamilyCountry.ch, SwissCanton.ti);
      await noHoliday(tester, state, DateTime(2026, 4, 3), 'Karfreitag');
      await holidayOn(tester, state, DateTime(2026, 3, 19), 'Josefstag');
      await holidayOn(tester, state, DateTime(2026, 6, 29), 'Peter und Paul');
      // Geneva: its fast on 10.9., no Saint Stephen.
      await f.admin.updateServerSettings({'holidayRegion': 'CH-GE'});
      await countryIs(tester, FamilyCountry.ch, SwissCanton.ge);
      await holidayOn(tester, state, DateTime(2026, 9, 10), 'Genfer Bettag');
      await noHoliday(tester, state, DateTime(2026, 12, 26), 'Stephanstag');
      expect(school(DateTime(2026), DateTime(2027, 2)), isFalse);

      // KAL-138: Germany, North Rhine-Westphalia.
      await f.admin.updateServerSettings({
        'country': 'DE',
        'holidayRegion': 'NW',
      });
      await countryIs(tester, FamilyCountry.de, GermanState.nw);
      await holidayOn(tester, state, DateTime(2026, 11, 1), 'Allerheiligen');
      await tap(tester, find.text('Allerheiligen'));
      await waitFor(
        tester,
        find.text(de.holidayStatutoryIn('Nordrhein-Westfalen')),
      );
      expect(find.text(de.calendarAdminsSetFederalState), findsOneWidget);
      await closeSheet(tester);
      await finish(tester, state);
    },
  );

  // The device's date cannot be moved on the Mac: the school bag of the
  // Austrian school-free days is asked of the running app (the same
  // function the card "Für morgen", the start page and the reminder of
  // the evening use); on screen only tomorrow, a school day.
  testWidgets('KAL-177 no school bag on Austrian school-free days', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    resetCountryAfter(f);
    await f.admin.updateServerSettings({
      'country': 'AT',
      'holidayRegion': 'AT-9',
    });
    final now = today();
    final id = uid('child');
    await put(f.admin, Collections.children, {
      id: {
        ...Child(
          id: id,
          name: 'E2E Schulkind',
          birthDate: DateTime(now.year - 8, 2, 3),
          guardianIds: [f.adminMember.id],
        ).toData(),
        SyncRecord.visibilityKey: [f.adminMember.id],
      },
    });
    var timetable = Timetable(childId: id);
    for (var weekday = 1; weekday <= 5; weekday++) {
      timetable = timetable.withLesson(weekday, 0, 'Deutsch');
    }
    await put(f.admin, Collections.timetables, {
      id: {
        ...timetable.toData(),
        SyncRecord.visibilityKey: [f.adminMember.id],
      },
    });
    // A subscribed calendar of school holidays (as the server imports it).
    final feed = await addSubscription(f.admin, 'E2E Ferienabo');
    await addEvent(
      f.admin,
      'E2E Abo-Ferien',
      DateTime(2026, 11, 3),
      allDay: true,
      sourceId: feed,
    );
    final state = await startApp(tester);
    final engine = state.engine!;
    await countryIs(tester, FamilyCountry.at, AustrianState.w);
    await eventually(tester, 'child and timetable', () async {
      await engine.sync();
      return engine.child(id) != null && engine.timetable(id) != null;
    });
    final kid = engine.child(id)!;
    for (final day in [
      DateTime(2026, 10, 27),
      DateTime(2026, 10, 30),
      DateTime(2026, 11, 2),
      DateTime(2026, 12, 28),
      DateTime(2027, 1, 4),
    ]) {
      expect(schoolBag(engine, kid, day), isNull, reason: 'school-free $day');
    }
    // School days: the bag, also on a day of the subscribed holidays.
    expect(schoolBag(engine, kid, DateTime(2026, 11, 3)), isNotNull);
    expect(schoolBag(engine, kid, DateTime(2026, 11, 4)), isNotNull);
    final tomorrow = inDays(1);
    if (tomorrow.weekday <= DateTime.friday &&
        holidayEvents(tomorrow, inDays(2)).isEmpty) {
      await openSection(tester, 'Kinder');
      await scrollTo(tester, find.text('E2E Schulkind'));
      await tap(tester, find.text('E2E Schulkind'));
      await dismissTip(tester);
      await tap(tester, find.text(de.commonTimetable));
      await scrollTo(tester, find.text(de.timetableForTomorrow));
    }
    await finish(tester, state);
  });

  // --- Anhänge -------------------------------------------------------------------

  testWidgets('KAL-183 the last attachment taken off stays off', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final day = inDays(2);
    final file = await f.admin.uploadFile(
      bytes: await colourPng(const Color(0xFF2A9D6E)),
      name: 'e2e-letzter.png',
      mime: 'image/png',
    );
    final id = await addEvent(
      f.admin,
      'E2E Letzter Anhang',
      at(day, 11),
      files: [file],
    );
    final bea = await sessionOf(f.bea);
    expect(CalendarEvent.fromRecord((await eventOf(bea, id))!).files, [
      isA<FileRef>(),
    ]);
    final state = await startApp(tester);
    final engine = state.engine!;
    await openCalendar(tester);
    await selectDay(tester, state, day);
    await openEvent(tester, 'E2E Letzter Anhang');
    await scrollTo(tester, find.byType(FileThumb));
    expect(find.byType(FileThumb), findsOneWidget);
    await tap(tester, find.byTooltip(de.tasksRemovePhoto));
    expect(find.byType(FileThumb), findsNothing);
    await save(tester);
    await engine.sync();
    await eventually(
      tester,
      'no attachment on the server',
      () async =>
          CalendarEvent.fromRecord((await eventOf(f.admin, id))!).files.isEmpty,
    );
    // The second device: none; a while later still none.
    expect(CalendarEvent.fromRecord((await eventOf(bea, id))!).files, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    await engine.sync();
    expect(engine.event(id)!.files, isEmpty);
    expect(CalendarEvent.fromRecord((await eventOf(bea, id))!).files, isEmpty);
    await openEvent(tester, 'E2E Letzter Anhang');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(FileThumb), findsNothing);
    await closeEditor(tester);
    await finish(tester, state);
  });

  // --- Kinder und die Termine anderer ----------------------------------------------

  testWidgets(
    'KAL-045 KAL-185 KAL-186 the child adds nobody to appointments of others',
    (tester) async {
      final f = await setUpFamily(tester);
      final kidApi = await sessionOf(f.kid);
      final guestApi = await sessionOf(f.guest);
      final day = inDays(3);
      final secret = await addEvent(
        f.admin,
        'E2E Arzt mit Kind',
        at(day, 10),
        confidential: true,
        members: [f.adminMember.id, f.kid.id],
      );
      final family = await addEvent(
        f.admin,
        'E2E Familienausflug',
        at(day, 14),
      );
      final state = await startApp(tester, user: 'e2e-kind');
      final engine = state.engine!;
      await openCalendar(tester);
      await selectDay(tester, state, day);

      // KAL-185 / KAL-045: in A's confidential one, nobody new.
      await openEvent(tester, 'E2E Arzt mit Kind');
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.bea.displayName),
      );
      for (final name in [f.bea.displayName, f.guest.displayName]) {
        expect(person(tester, name).onSelected, isNull, reason: name);
        expect(person(tester, name).selected, isFalse, reason: name);
      }
      expect(a.wholeFamily(tester).onSelected, isNull);
      expect(find.text(de.eventNoNewParticipants), findsOneWidget);
      expect(find.text(de.commonAudienceSetByAdults), findsOneWidget);
      expect(switchOf(tester, de.commonPrivate).onChanged, isNull);
      // Who drives: only those already in it.
      await scrollTo(tester, a.dropdownOf(de.eventDropsOff));
      await tap(tester, a.dropdownOf(de.eventDropsOff));
      await tester.pump(const Duration(milliseconds: 600));
      for (final key in [de.eventDropsOff, de.eventPicksUp]) {
        final items = {
          for (final i in itemsOf(tester, key)) itemText(i): i.enabled,
        };
        expect(items[kitAdminName], isTrue, reason: '$key: $items');
        for (final name in [
          f.bea.displayName,
          f.carl.displayName,
          f.guest.displayName,
        ]) {
          expect(items[name], isFalse, reason: '$key $name: $items');
        }
      }
      await tap(tester, find.text(de.eventNobodyAssigned).last);
      await tester.pump(const Duration(milliseconds: 600));
      await closeEditor(tester);
      // Sent anyway: without Bea, still confidential, "partly_kept".
      var r = await send(
        kidApi,
        secret,
        (d) => d..['memberIds'] = [...d['memberIds'] as List, f.bea.id],
      );
      expect(refusedCode(r, secret), 'partly_kept');
      var stored = (await eventOf(f.admin, secret))!.data;
      expect(stored['memberIds'], isNot(contains(f.bea.id)));
      expect(stored['confidential'], isTrue);
      r = await send(kidApi, secret, (d) => d..['confidential'] = false);
      expect(refusedCode(r, secret), 'partly_kept');
      expect((await eventOf(f.admin, secret))!.data['confidential'], isTrue);
      expect(
        await titlesOf(guestApi, Collections.events),
        isNot(contains('E2E Arzt mit Kind')),
      );

      // KAL-186: in A's family one, nobody to name.
      await openEvent(tester, 'E2E Familienausflug');
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.kid.displayName),
      );
      for (final m in [f.adminMember, f.bea, f.carl, f.guest, f.kid]) {
        expect(
          person(tester, m.displayName).onSelected,
          isNull,
          reason: m.displayName,
        );
      }
      expect(find.text(de.eventWholeFamilyStays), findsOneWidget);
      await closeEditor(tester);
      // Its own family appointment: Bea can be named.
      await a.newEvent(tester, 'E2E Kind lädt ein');
      await save(tester);
      await engine.sync();
      final own = engine.events.singleWhere(
        (e) => e.title == 'E2E Kind lädt ein',
      );
      await openEvent(tester, 'E2E Kind lädt ein');
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.bea.displayName),
      );
      expect(person(tester, f.bea.displayName).onSelected, isNotNull);
      expect(find.text(de.eventWholeFamilyStays), findsNothing);
      await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
      await save(tester);
      await engine.sync();
      await eventually(
        tester,
        'Bea is in the child\'s own',
        () async =>
            jsonEncode((await eventOf(f.admin, own.id))?.data['memberIds']) ==
            jsonEncode([f.bea.id]),
      );
      // Sent anyway: the note is taken, the family keeps it.
      r = await send(
        kidApi,
        family,
        (d) => d
          ..['memberIds'] = [f.kid.id]
          ..['notes'] = 'E2E Notiz vom Kind',
      );
      expect(refusedCode(r, family), 'partly_kept');
      stored = (await eventOf(f.admin, family))!.data;
      expect(stored['notes'], 'E2E Notiz vom Kind');
      expect(stored['memberIds'], anyOf(isNull, isEmpty));
      expect(
        await titlesOf(guestApi, Collections.events),
        contains('E2E Familienausflug'),
      );
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-187 a child\'s appointment an adult made confidential stays theirs',
    (tester) async {
      final f = await setUpFamily(tester);
      final kidApi = await sessionOf(f.kid);
      final guestApi = await sessionOf(f.guest);
      final service = await sessionOf(await theService());
      final day = inDays(4);
      final state = await startApp(tester, user: 'e2e-kind');
      final engine = state.engine!;
      await openCalendar(tester);
      await selectDay(tester, state, day);
      await a.newEvent(tester, 'E2E Mein Termin');
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.kid.displayName),
      );
      await tap(tester, find.widgetWithText(FilterChip, f.kid.displayName));
      await save(tester);
      await engine.sync();
      final id = engine.events
          .singleWhere((e) => e.title == 'E2E Mein Termin')
          .id;
      await eventually(
        tester,
        'the child\'s on the server',
        () async => (await eventOf(f.admin, id)) != null,
      );
      // A joins and makes it confidential.
      final r0 = await send(
        f.admin,
        id,
        (d) => d
          ..['memberIds'] = [f.kid.id, f.adminMember.id]
          ..['confidential'] = true,
      );
      expect(r0.rejected.where((x) => x.id == id), isEmpty);
      var stored = (await eventOf(f.admin, id))!.data;
      expect(stored[CalendarEvent.confidentialByKey], f.adminMember.id);
      expect(stored[CalendarEvent.createdByKey], f.kid.id);
      await inApp(
        tester,
        state,
        id,
        (e) => e?.confidential == true,
        'confidential in the child\'s app',
      );
      await openEvent(tester, 'E2E Mein Termin');
      await scrollTo(
        tester,
        find.widgetWithText(SwitchListTile, de.commonPrivate),
      );
      expect(switchOf(tester, de.commonPrivate).onChanged, isNull);
      expect(switchOf(tester, de.commonPrivate).value, isTrue);
      expect(find.text(de.commonAudienceSetByAdults), findsOneWidget);
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.bea.displayName),
      );
      expect(person(tester, f.bea.displayName).onSelected, isNull);
      expect(person(tester, kitAdminName).onSelected, isNull);
      expect(find.text(de.eventNoNewParticipants), findsOneWidget);
      await closeEditor(tester);

      // Sent anyway, one by one.
      for (final (what, change)
          in <(String, void Function(Map<String, Object?>))>[
            (
              'Bea in it',
              (d) => d['memberIds'] = [...d['memberIds'] as List, f.bea.id],
            ),
            ('A out of it', (d) => d['memberIds'] = [f.kid.id]),
            ('not confidential', (d) => d['confidential'] = false),
            (
              'its own say',
              (d) => d[CalendarEvent.confidentialByKey] = f.kid.id,
            ),
          ]) {
        final r = await send(kidApi, id, (d) {
          change(d);
          return d;
        });
        debugPrint('E2E-INFO $what: ${r.refused.map((i) => i.code)}');
        stored = (await eventOf(f.admin, id))!.data;
        expect(stored['memberIds'], contains(f.adminMember.id), reason: what);
        expect(stored['memberIds'], isNot(contains(f.bea.id)), reason: what);
        expect(stored['confidential'], isTrue, reason: what);
        expect(
          stored[CalendarEvent.confidentialByKey],
          f.adminMember.id,
          reason: what,
        );
        expect(
          await titlesOf(guestApi, Collections.events),
          isNot(contains('E2E Mein Termin')),
          reason: what,
        );
        expect(
          await titlesOf(service, Collections.events),
          isNot(contains('E2E Mein Termin')),
          reason: what,
        );
      }
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-188 deleting and undoing does not make the parents\' appointment the child\'s',
    (tester) async {
      final f = await setUpFamily(tester);
      final kidApi = await sessionOf(f.kid);
      final guestApi = await sessionOf(f.guest);
      final service = await sessionOf(await theService());
      final day = inDays(5);
      final id = await addEvent(
        f.admin,
        'E2E Elterngeheimnis',
        at(day, 16),
        confidential: true,
        members: [f.adminMember.id, f.kid.id],
      );
      Future<void> nobodyElseSees(String when) async {
        expect(
          await titlesOf(guestApi, Collections.events),
          isNot(contains('E2E Elterngeheimnis')),
          reason: 'guest $when',
        );
        expect(
          await titlesOf(service, Collections.events),
          isNot(contains('E2E Elterngeheimnis')),
          reason: 'service account $when',
        );
      }

      Future<void> stillTheParents(String when) async {
        final stored = (await eventOf(f.admin, id))!.data;
        expect(
          stored[CalendarEvent.createdByKey],
          f.adminMember.id,
          reason: when,
        );
        expect(stored['confidential'], isTrue, reason: when);
        await nobodyElseSees(when);
      }

      final state = await startApp(tester, user: 'e2e-kind');
      final engine = state.engine!;
      await openCalendar(tester);
      await selectDay(tester, state, day);
      await openEvent(tester, 'E2E Elterngeheimnis');
      await scrollTo(tester, find.text(de.eventDelete));
      await tap(tester, find.text(de.eventDelete).last);
      await waitGone(tester, editorOpen);
      await tap(
        tester,
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(de.commonUndo),
        ),
      );
      await engine.sync();
      await eventually(
        tester,
        'back on the server',
        () async => (await eventOf(f.admin, id)) != null,
      );
      await stillTheParents('after undo');
      await waitFor(tester, find.text('E2E Elterngeheimnis'));
      await openEvent(tester, 'E2E Elterngeheimnis');
      await scrollTo(
        tester,
        find.widgetWithText(SwitchListTile, de.commonPrivate),
      );
      expect(switchOf(tester, de.commonPrivate).onChanged, isNull);
      expect(switchOf(tester, de.commonPrivate).value, isTrue);
      await closeEditor(tester);
      final r = await send(kidApi, id, (d) => d..['confidential'] = false);
      expect(refusedCode(r, id), 'partly_kept');
      await stillTheParents('after the child sent it public');

      // Out of the bin, restored by A.
      await remove(kidApi, Collections.events, [id]);
      await eventually(
        tester,
        'gone',
        () async => (await eventOf(f.admin, id)) == null,
      );
      final bin = (await f.admin.trash()).items.where((e) => e.record.id == id);
      expect(bin, hasLength(1));
      await f.admin.restoreTrash(bin.single.id);
      await eventually(
        tester,
        'restored',
        () async => (await eventOf(f.admin, id)) != null,
      );
      await stillTheParents('after the bin');
      await inApp(
        tester,
        state,
        id,
        (e) => e?.confidential == true,
        'back in the child\'s app',
      );
      await finish(tester, state);
    },
  );

  // --- Gäste ---------------------------------------------------------------------

  testWidgets(
    'KAL-050 KAL-190 the guest: no import, free times to read, nothing sent taken',
    (tester) async {
      final f = await setUpFamily(tester);
      final bea = await sessionOf(f.bea);
      final guestApi = await sessionOf(f.guest);
      final day = inDays(3);
      final family = await addEvent(f.admin, 'E2E Gast liest', at(day, 15));
      final ics = await tempFile(
        'e2e-gast.ics',
        utf8.encode(
          vcalendar([
            vevent(
              'e2e-ics-gast@example.com',
              'E2E Gast-Datei',
              at(day, 9),
              at(day, 10),
            ),
          ]),
        ),
      );
      final state = await startApp(tester, user: 'e2e-gast');
      final engine = state.engine!;
      await openCalendar(tester);
      expect(find.byTooltip(de.eventNewEvent), findsNothing);
      expect(find.byTooltip(de.calendarRecognizeEventsPhotoText), findsNothing);
      // "Wann haben alle Zeit?": suggestions to read only.
      await tap(tester, find.byTooltip(de.freeTimeTitle));
      await waitFor(tester, find.byType(FreeTimeScreen));
      await dismissTip(tester);
      final slots = find.descendant(
        of: find.byType(FreeTimeScreen),
        matching: find.byWidgetPredicate(
          (w) =>
              w is ListTile &&
              w.title is Text &&
              ((w.title as Text).data ?? '').contains(' – '),
        ),
      );
      await waitFor(tester, slots);
      for (final e in slots.evaluate()) {
        final tile = e.widget as ListTile;
        expect(tile.onTap, isNull);
        expect(tile.trailing, isNull);
      }
      await tester.tap(slots.first, warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
      expect(editorOpen, findsNothing);
      await back(tester);
      await waitGone(tester, find.byType(FreeTimeScreen));

      // KAL-190: a calendar file dropped on the window.
      await dropFiles(tester, [ics]);
      await waitFor(tester, find.text(de.eventGuestReadOnly));
      expect(find.byType(IcsImportScreen), findsNothing);
      await snackGone(tester);

      // Sent anyway through the guest's session.
      final newId = uid('event');
      await put(guestApi, Collections.events, {
        newId: CalendarEvent(
          id: newId,
          title: 'E2E Gast neu',
          start: at(day, 18),
          end: at(day, 19),
        ).toData(),
      });
      await send(guestApi, family, (d) => d..['title'] = 'E2E Gast geändert');
      await remove(guestApi, Collections.events, [family]);
      await engine.sync();
      final forBea = await pull(bea, Collections.events);
      expect(forBea[family]?.data['title'], 'E2E Gast liest');
      expect(
        forBea.values.map((r) => r.data['title']),
        isNot(contains('E2E Gast neu')),
      );
      expect(
        forBea.values.map((r) => r.data['title']),
        isNot(contains('E2E Gast-Datei')),
      );
      await eventually(tester, 'the guest\'s app as before', () async {
        await engine.sync();
        return engine.event(family)?.title == 'E2E Gast liest' &&
            engine.event(newId) == null;
      });
      await finish(tester, state);
    },
  );

  // --- Serien und Abos -------------------------------------------------------------

  testWidgets(
    'KAL-030 KAL-125 every two months kept; addresses refused readably',
    (tester) async {
      final f = await setUpFamily(tester);
      final s = inDays(2);
      final series = await addEvent(
        f.admin,
        'E2E Zwei Monate',
        at(s, 10),
        recurrence: const Recurrence(RecurrenceFrequency.monthly, interval: 2),
      );
      final private = await addSubscription(
        f.admin,
        'E2E Privat https',
        owner: f.adminMember.id,
        url: 'https://192.168.1.50/kal.ics',
      );
      final unknown = await addSubscription(
        f.admin,
        'E2E Unbekannt',
        owner: f.adminMember.id,
        url: 'https://e2e-gibt-es-nicht.invalid/kal.ics',
      );
      final state = await startApp(tester);
      final engine = state.engine!;
      await openCalendar(tester);
      await selectDay(tester, state, s);
      await openEvent(tester, 'E2E Zwei Monate');
      await scrollTo(tester, a.dropdownOf(de.eventRepeat));
      expect(
        find.descendant(
          of: a.dropdownOf(de.eventRepeat),
          matching: find.text(de.eventRepeatEveryMonths(2)),
        ),
        findsWidgets,
      );
      await scrollTo(tester, titleField, up: true);
      await enter(tester, titleField, 'E2E Zwei Monate neu');
      await leaveField(tester);
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, find.text(de.eventSaveChange));
      await tap(tester, find.text(de.eventAllEventsSeries).last);
      await waitGone(tester, editorOpen);
      await engine.sync();
      await eventually(
        tester,
        'the new title on the server',
        () async =>
            (await eventOf(f.admin, series))?.data['title'] ==
            'E2E Zwei Monate neu',
      );
      final stored = CalendarEvent.fromRecord(
        (await eventOf(f.admin, series))!,
      );
      expect(stored.recurrence?.frequency, RecurrenceFrequency.monthly);
      expect(stored.recurrence?.interval, 2);

      // KAL-125: https into a private network, a name nobody knows.
      await eventually(
        tester,
        'both fetches failed',
        () async =>
            engine.subscriptionStatus(private)?.error != null &&
            engine.subscriptionStatus(unknown)?.error != null,
        timeout: const Duration(seconds: 90),
      );
      final p = engine.subscriptionStatus(private)!.error!;
      final u = engine.subscriptionStatus(unknown)!.error!;
      debugPrint('E2E-INFO private: $p');
      debugPrint('E2E-INFO unknown: $u');
      expect(p, contains('192.168.1.50'));
      expect(p, contains('zeigt in ein privates Netzwerk'));
      expect(u, contains('e2e-gibt-es-nicht.invalid'));
      expect(u, contains('wurde nicht gefunden'));
      for (final e in [p, u]) {
        expect(e, isNot(contains('ApiException')));
        expect(e, isNot(contains('Import fehlgeschlagen')));
      }
      await openConnect(tester);
      await scrollTo(
        tester,
        find.textContaining('zeigt in ein privates Netzwerk'),
      );
      await finish(tester, state);
    },
  );

  // --- Schulbriefe -----------------------------------------------------------------

  testWidgets(
    'KAL-191 KAL-194 KAL-195 a school letter: appointment and deadline as drafts',
    (tester) async {
      await setUpFamily(tester);
      final state = await startApp(tester);
      final engine = state.engine!;
      final trip = DateTime(2026, 11, 27), due = DateTime(2026, 11, 20);
      await openImport(tester);
      await searchText(
        tester,
        'Klassenfahrt am 27.11.2026 um 8:30 Uhr. '
        'Bitte Einverständnis bis 20.11.2026 abgeben.',
      );
      await waitFor(tester, find.byTooltip(de.importEditTask));
      expect(find.byType(Checkbox), findsNothing);
      expect(find.textContaining('übernehmen'), findsNothing);
      expect(suggestionTitles(tester), [contains('Klassenfahrt')]);
      expect(find.textContaining(shortDay(trip)), findsWidgets);
      expect(find.textContaining('08:30'), findsWidgets);
      expect(find.text('Einverständnis abgeben'), findsOneWidget);
      expect(
        find.textContaining(de.importTaskDue(shortDay(due))),
        findsOneWidget,
      );
      // The appointment: opened and left, then saved.
      await tap(tester, find.byTooltip(de.importEditEvent));
      await waitFor(tester, editorOpen);
      await closeEditor(tester);
      expect(find.byTooltip(de.importEditEvent), findsOneWidget);
      await tap(tester, find.byTooltip(de.importEditEvent));
      await waitFor(tester, editorOpen);
      await save(tester);
      await waitFor(tester, find.text(de.import1EventAdded));
      expect(find.widgetWithText(TextButton, de.commonClose), findsOneWidget);
      expect(find.byTooltip(de.importEditEvent), findsNothing);
      final event = engine.events.singleWhere(
        (e) => e.title.contains('Klassenfahrt'),
      );
      expect(event.start, at(trip, 8, 30));
      expect(event.notes, startsWith(de.importTakenLine('').trim()));
      // The task: saved, the page closes.
      await snackGone(tester);
      await tap(tester, find.byTooltip(de.importEditTask));
      await waitFor(tester, taskSheetSave);
      await tap(tester, taskSheetSave);
      await waitFor(tester, find.text(de.importTaskAdded));
      await waitGone(tester, find.byType(EventImportScreen));
      final task = engine.tasks.singleWhere(
        (t) => t.title == 'Einverständnis abgeben',
      );
      expect(DateUtils.isSameDay(task.due, due), isTrue, reason: '${task.due}');
      expect(task.notes, startsWith(de.importTakenLine('').trim()));
      await snackGone(tester);

      // KAL-194: a deadline that is not one day.
      final friday = DateUtils.addDaysToDate(
        today(),
        (DateTime.friday - today().weekday) % 7,
      );
      await openImport(tester);
      for (final (text, day) in [
        ('Bitte Einverständnis bis Freitag oder Montag abgeben.', null),
        ('Bitte Einverständnis bis nächsten Freitag abgeben.', null),
        ('Bitte Einverständnis bis Freitag abgeben oder zurücksenden.', friday),
      ]) {
        await searchText(tester, text);
        await waitFor(tester, find.byTooltip(de.importEditTask));
        expect(find.byTooltip(de.importEditEvent), findsNothing, reason: text);
        final title =
            (tester
                        .widget<ListTile>(
                          find
                              .ancestor(
                                of: find.byTooltip(de.importEditTask),
                                matching: find.byType(ListTile),
                              )
                              .first,
                        )
                        .title!
                    as Text)
                .data!;
        debugPrint('E2E-INFO task of "$text": $title');
        // The catalog names the title for the first two only.
        if (day == null) {
          expect(title, 'Einverständnis abgeben', reason: text);
        } else {
          expect(title, startsWith('Einverständnis'), reason: text);
        }
        expect(
          find.textContaining(
            day == null ? de.importTaskSetDue : de.importTaskDue(shortDay(day)),
          ),
          findsOneWidget,
          reason: text,
        );
        if (day == null) {
          await tap(tester, find.byTooltip(de.importEditTask));
          await waitFor(tester, taskSheetSave);
          expect(
            find.widgetWithText(InputChip, de.tasksDue),
            findsOneWidget,
            reason: 'no due date in the editor: $text',
          );
          await closeTopSheet(tester);
        }
        await tap(tester, pageBack());
        await waitFor(tester, find.text(de.importFindEvents));
      }

      // KAL-195: "am" is a deadline only for handing something in.
      await searchText(
        tester,
        'Ausflug am 27.11.2026 um 9 Uhr\n'
        'Bitte die Einverständniserklärung am 20.11.2026 abgeben.',
      );
      await waitFor(tester, find.byTooltip(de.importEditTask));
      expect(suggestionTitles(tester), [contains('Ausflug')]);
      expect(find.textContaining('09:00'), findsWidgets);
      expect(
        find.textContaining(de.importTaskDue(shortDay(due))),
        findsOneWidget,
      );
      await tap(tester, pageBack());
      await waitFor(tester, find.text(de.importFindEvents));
      await searchText(
        tester,
        'Beim Elternabend am 27.11.2026 um 19 Uhr können Sie die '
        'Einverständniserklärung abgeben.',
      );
      await waitFor(tester, find.text(de.importTakeOver1Event));
      expect(find.byTooltip(de.importEditTask), findsNothing);
      expect(suggestionTitles(tester), [contains('Elternabend')]);
      expect(find.textContaining('19:00'), findsWidgets);
      await tap(tester, pageBack());
      await waitFor(tester, find.text(de.importFindEvents));
      await searchText(
        tester,
        'Elternabend am 27.11.2026 um 19 Uhr; Basar am 28.11.2026',
      );
      await waitFor(tester, find.text(de.importTakeOverCountEvents(2)));
      expect(find.byTooltip(de.importEditTask), findsNothing);
      expect(
        tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value),
        [true, true],
      );
      await back(tester);
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-192 KAL-193 a school letter photo: one original on both drafts, or none',
    (tester) async {
      final f = await setUpFamily(tester);
      addTearDown(() => f.admin.updateServerSettings({'maxUploadMb': null}));
      final picker = fakePicker();
      const lines = [
        'Klassenfahrt am 27.11.2026 um 8:30 Uhr.',
        'Bitte Einverständnis bis 20.11.2026 abgeben.',
      ];
      final letter = await letterFile('e2e-schulbrief.png', lines);
      final big = await letterFile(
        'e2e-schulbrief-gross.png',
        lines,
        noise: true,
      );
      expect(big.lengthSync(), greaterThan(mb));
      final state = await startApp(tester);
      final engine = state.engine!;
      final letterCard = find
          .ancestor(
            of: find.text(de.importKeepLetterOriginal),
            matching: find.byType(SoftCard),
          )
          .first;
      bool keep() => tester
          .widget<Checkbox>(
            find.descendant(of: letterCard, matching: find.byType(Checkbox)),
          )
          .value!;

      // KAL-192
      await openImport(tester);
      picker.picks.add([DiskFile(letter)]);
      await tap(tester, find.text(de.importChoosePicture));
      await waitFor(
        tester,
        find.byTooltip(de.importEditTask),
        timeout: const Duration(seconds: 60),
      );
      expect(keep(), isTrue);
      await tap(tester, find.byTooltip(de.importEditEvent));
      await waitFor(tester, editorOpen, timeout: const Duration(seconds: 60));
      await scrollTo(tester, find.byType(FileThumb));
      expect(find.byType(FileThumb), findsOneWidget);
      await save(tester);
      await waitFor(tester, find.text(de.import1EventAdded));
      await snackGone(tester);
      await tap(tester, find.byTooltip(de.importEditTask));
      await waitFor(tester, taskSheetSave);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(FileThumb),
        ),
        findsOneWidget,
      );
      await tap(tester, taskSheetSave);
      await waitGone(tester, find.byType(EventImportScreen));
      final event = engine.events.singleWhere(
        (e) => e.title.contains('Klassenfahrt'),
      );
      // The task of the pasted letter (KAL-191) has no photo.
      final task = engine.tasks.singleWhere(
        (t) => t.title == 'Einverständnis abgeben' && t.photos.isNotEmpty,
      );
      expect(event.files, hasLength(1));
      expect(task.photos, hasLength(1));
      expect(task.photos.single.id, event.files.single.id, reason: 'one file');
      await engine.sync();
      final bea = await sessionOf(f.bea);
      await eventually(tester, 'both on Bea\'s device', () async {
        final e = (await pull(bea, Collections.events))[event.id];
        final t = (await pull(bea, Collections.tasks))[task.id];
        return e != null &&
            t != null &&
            CalendarEvent.fromRecord(e).files.single.id ==
                event.files.single.id &&
            Task.fromRecord(t).photos.single.id == event.files.single.id;
      });
      expect(
        listEquals(
          await bea.downloadFile(event.files.single.id),
          letter.readAsBytesSync(),
        ),
        isTrue,
      );
      await snackGone(tester);

      // KAL-193: the server takes at most 1 MB.
      await f.admin.updateServerSettings({'maxUploadMb': 1});
      await eventually(tester, 'the app knows the limit', () async {
        await engine.sync();
        return engine.maxUploadBytes == mb;
      });
      final tasksBefore = engine.tasks.length,
          eventsBefore = engine.events.length;
      await openImport(tester);
      picker.picks.add([DiskFile(big)]);
      await tap(tester, find.text(de.importChoosePicture));
      await waitFor(
        tester,
        find.byTooltip(de.importEditTask),
        timeout: const Duration(seconds: 60),
      );
      expect(keep(), isTrue);
      await tap(tester, find.byTooltip(de.importEditTask));
      await waitFor(
        tester,
        find.text(de.importOriginalNotKept),
        timeout: const Duration(seconds: 60),
      );
      expect(taskSheetSave, findsNothing, reason: 'no editor');
      final message = find.text(de.importOriginalNotKept);
      expect(
        tester.widget<Text>(message.first).style?.color,
        Theme.of(tester.element(message.first)).colorScheme.error,
      );
      expect(find.byTooltip(de.importEditTask), findsOneWidget);
      expect(find.byTooltip(de.importEditEvent), findsOneWidget);
      await tap(tester, find.byTooltip(de.importEditEvent));
      await tester.pump(const Duration(seconds: 2));
      expect(editorOpen, findsNothing);
      expect(engine.tasks, hasLength(tasksBefore));
      expect(engine.events, hasLength(eventsBefore));
      // Without the original, the editor opens without an attachment.
      await tap(
        tester,
        find.descendant(of: letterCard, matching: find.byType(Checkbox)),
      );
      expect(keep(), isFalse);
      await tap(tester, find.byTooltip(de.importEditTask));
      await waitFor(tester, taskSheetSave);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(FileThumb),
        ),
        findsNothing,
      );
      await closeTopSheet(tester);
      expect(engine.tasks, hasLength(tasksBefore));
      await back(tester);
      await finish(tester, state);
    },
  );

  // --- Mitteilungen ------------------------------------------------------------------

  // Tapping a system notification cannot be done on the Mac: the target the
  // server sent is handed to the app the way a tap does (AppState
  // .openRequest, as ReminderService.taps and the Android/iOS links do).
  testWidgets('KAL-202 notices of appointments name their target', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final bea = await sessionOf(f.bea);
    final beaMark = await noticeMark(bea);
    final adminMark = await noticeMark(f.admin);
    final id = await addEvent(
      f.admin,
      'E2E Ziel-Termin',
      at(inDays(2), 10),
      members: [f.bea.id],
    );
    late Notice added, commented, secret;
    await eventually(tester, 'Bea hears of it', () async {
      final n = (await noticesAfter(
        bea,
        beaMark,
      )).where((n) => n.title == 'Neuer Termin: E2E Ziel-Termin');
      if (n.isEmpty) return false;
      added = n.first;
      return true;
    });
    expect(added.target?.kind, NoticeTarget.eventKind);
    expect(added.target?.id, id);
    expect(added.target!.encode(), startsWith('event:$id'));
    final comment = uid('comment');
    await put(f.admin, Collections.eventComments, {
      comment: EventComment(
        id: comment,
        eventId: id,
        authorId: f.adminMember.id,
        at: DateTime.now(),
        text: 'E2E Bis Donnerstag',
      ).toData(),
    });
    await eventually(tester, 'Bea hears of the comment', () async {
      final n = (await noticesAfter(
        bea,
        beaMark,
      )).where((n) => n.title == 'Kommentar zu „E2E Ziel-Termin“');
      if (n.isEmpty) return false;
      commented = n.first;
      return true;
    });
    expect(commented.target?.kind, NoticeTarget.eventKind);
    expect(commented.target?.id, id);
    // Confidential: its target, no title.
    final hidden = await addEvent(
      f.admin,
      'E2E Ziel geheim',
      at(inDays(2), 12),
      members: [f.bea.id],
      confidential: true,
    );
    await eventually(tester, 'Bea hears of the confidential one', () async {
      final n = (await noticesAfter(
        bea,
        beaMark,
      )).where((n) => n.target?.id == hidden);
      if (n.isEmpty) return false;
      secret = n.first;
      return true;
    });
    for (final text in [secret.title, secret.body, secret.brief]) {
      expect(text, isNot(contains('E2E Ziel geheim')));
    }
    expect(secret.target?.kind, NoticeTarget.eventKind);

    // "Zusage noch offen" and "Rückmeldung zur Zuständigkeit".
    final in50 = DateTime.now().add(const Duration(minutes: 50));
    final soon = DateTime(
      in50.year,
      in50.month,
      in50.day,
      in50.hour,
      in50.minute,
    );
    if (DateUtils.isSameDay(soon, DateTime.now())) {
      final lift = await a.addEvent(
        f.admin,
        'E2E Ziel-Fahrt',
        soon,
        members: [f.bea.id],
        bringer: f.bea.id,
        confirm: const AssignmentSettings(required: true, remindMinutes: 60),
      );
      late Notice open;
      await eventually(tester, 'Bea is asked to confirm', () async {
        final n = (await noticesAfter(
          bea,
          beaMark,
        )).where((n) => n.title == 'Zusage noch offen');
        if (n.isEmpty) return false;
        open = n.first;
        return true;
      }, timeout: const Duration(minutes: 3));
      expect(open.target?.kind, NoticeTarget.eventKind);
      expect(open.target?.id, lift);
      final answered = await a.answer(
        bea,
        f.bea,
        lift,
        AssignmentKind.bring,
        AssignmentDecision.accepted,
      );
      expect(answered.rejected, isEmpty);
      late Notice reply;
      await eventually(tester, 'A hears of the answer', () async {
        final n = (await noticesAfter(
          f.admin,
          adminMark,
        )).where((n) => n.title == 'Rückmeldung zur Zuständigkeit');
        if (n.isEmpty) return false;
        reply = n.first;
        return true;
      });
      expect(reply.target?.kind, NoticeTarget.eventKind);
      expect(reply.target?.id, lift);
    } else {
      debugPrint('E2E-INFO too close to midnight for a lift today');
    }

    // On Bea's device: the target opens the appointment.
    final state = await startApp(tester, user: 'e2e-bea');
    await eventually(tester, 'Bea\'s app has it', () async {
      await state.engine!.sync();
      return state.engine!.event(id) != null;
    });
    state.openRequest.value = commented.target;
    await waitFor(tester, editorOpen);
    expect(
      tester.widget<TextField>(titleField.last).controller!.text,
      'E2E Ziel-Termin',
    );
    await closeEditor(tester);
    await finish(tester, state);
  });
}
