// Catalog SIC, entries of 23.11.2026: the family's country (SIC-169),
// Austria's holidays and school holidays (SIC-170), Switzerland's cantons
// (SIC-171), emergency numbers by country (SIC-172) and a guardian removed
// in the administration (SIC-195) – in the real app against a throwaway
// server:
//
//   tool/integration_tests.sh macos integration_test/catalog_sic_b_test.dart
//
// What other members get comes from their own API sessions; what another
// device or admin changes is written through the API. The phone app and
// the browser are replaced at the url_launcher interface: no call goes out.
// Tests that change the country set it back to Germany.

import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/country.dart';
import 'package:famio/src/data/holidays.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/kids_screens.dart';
import 'package:famio/src/widgets/setup_checklist.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'catalog_kit.dart';

/// Stands in for the system's apps (phone, browser).
class _FakeLauncher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

final _launcher = _FakeLauncher();

// --- members and data --------------------------------------------------------

/// A member made anew for one test.
Future<FamilyMember> freshMember(
  String username,
  String name, {
  MemberRole role = MemberRole.adult,
}) async {
  final f = await theFamily();
  for (final u in await f.admin.adminUsers()) {
    if (u.member.username == username) await f.admin.deleteMember(u.member.id);
  }
  final m = await f.admin.createMember(
    username: username,
    displayName: name,
    password: kitMemberPassword,
    role: role,
  );
  addTearDown(() async {
    try {
      await f.admin.deleteMember(m.id);
    } on ApiError {
      // Gone already.
    }
  });
  return m;
}

Future<FamioApiClient> loginAs(FamilyMember m) async {
  final api = FamioApiClient(kitUrl);
  await api.login(
    username: m.username,
    password: kitMemberPassword,
    device: 'e2e',
  );
  return api;
}

Future<void> seed(
  FamioApiClient api,
  String collection,
  Map<String, Map<String, Object?>> records,
) async {
  final r = await put(api, collection, records);
  expect(
    r.rejected.map((x) => x.id),
    isEmpty,
    reason: 'the server takes $collection',
  );
}

/// The family's country (and region) through the API, like another admin.
Future<void> setCountry(FamilyCountry country, {String? region}) async {
  final f = await theFamily();
  await f.admin.updateServerSettings({
    'country': country.code,
    'holidayRegion': region,
  });
}

/// Back to Germany without a region after the test.
void germanyAfterwards() => addTearDown(() => setCountry(FamilyCountry.de));

// --- the app -----------------------------------------------------------------

/// A window as high as a big screen: lists build what is on it.
void tall(WidgetTester tester, {double width = 800, double height = 1600}) {
  tester.view.physicalSize = Size(width, height) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}

Future<AppState> start(WidgetTester tester, {String? user}) async {
  UrlLauncherPlatform.instance = _launcher;
  final state = await startApp(tester, user: user);
  await dismissTip(tester);
  return state;
}

Finder inDialog(Finder f) =>
    find.descendant(of: find.byType(Dialog), matching: f);

const _listPoint = Offset(600, 420);

Future<void> openSettingsItem(WidgetTester tester, String title) async {
  await openSection(tester, 'Einstellungen');
  await scrollTo(tester, find.text(title), at: _listPoint);
  await tap(tester, find.text(title));
}

Future<void> saveSettings(WidgetTester tester) async {
  await scrollTo(tester, find.text(de.commonSave));
  await tap(tester, find.text(de.commonSave).last);
}

/// Brings the field labelled [label] on screen (the form is long and builds
/// only what is near the screen).
Future<void> show(WidgetTester tester, String label) =>
    scrollTo(tester, find.text(label), up: true);

/// The drop-down labelled [label] (its button holds the items).
DropdownButton<Object?> dropdown(WidgetTester tester, String label) =>
    tester.widget(
          find
              .descendant(
                of: find
                    .ancestor(
                      of: find.text(label),
                      matching: find.byWidgetPredicate(
                        (w) => w is DropdownButtonFormField,
                      ),
                    )
                    .first,
                matching: find.byWidgetPredicate((w) => w is DropdownButton),
              )
              .first,
        )
        as DropdownButton<Object?>;

List<String> itemsOf(WidgetTester tester, String label) => [
  for (final i in dropdown(tester, label).items ?? const [])
    (i.child as Text).data!,
];

/// The text the drop-down shows for its value.
String? shownIn(WidgetTester tester, String label) {
  final d = dropdown(tester, label);
  for (final i in d.items ?? const <DropdownMenuItem<Object?>>[]) {
    if (i.value == d.value) return (i.child as Text).data;
  }
  return null;
}

/// Opens the drop-down [label] (as a person looks at it) and closes it again.
Future<List<String>> lookInto(WidgetTester tester, String label) async {
  await tap(
    tester,
    find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  // The open menu (its route), not the button's own copy of the items.
  final menu = find.byWidgetPredicate(
    (w) => w.runtimeType.toString().startsWith('_DropdownMenu<'),
  );
  await waitFor(tester, menu);
  final shown = [
    for (final e
        in find
            .descendant(
              of: menu,
              matching: find.byWidgetPredicate((w) => w is DropdownMenuItem),
            )
            .evaluate())
      if ((e.widget as DropdownMenuItem).child case final Text t) t.data!,
  ];
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 600));
  return shown;
}

/// Server-Verwaltung → Einstellungen, at the country field.
Future<void> openCountrySettings(WidgetTester tester) async {
  await openAdmin(tester, de.sectionSettings);
  await scrollTo(tester, find.text(de.adminCountry));
}

bool _is(Widget w, String type) => w.runtimeType.toString() == type;

/// The month grid's cell of [day].
Finder dayCell(DateTime day) => find.byWidgetPredicate(
  (w) =>
      _is(w, '_DayCell') &&
      DateUtils.isSameDay((w as dynamic).day as DateTime, day),
);

/// The calendar on [date]: back to today, the arrows to its month, its cell.
Future<void> openCalendarOn(
  WidgetTester tester,
  AppState state,
  DateTime date,
) async {
  await openSection(tester, 'Kalender');
  await snackGone(tester);
  await tap(tester, find.byTooltip(de.commonToday));
  final now = state.engine!.calendar.today();
  var months = (date.year - now.year) * 12 + date.month - now.month;
  for (; months > 0; months--) {
    await tap(tester, find.byTooltip(de.budgetNextMonth));
  }
  for (; months < 0; months++) {
    await tap(tester, find.byTooltip(de.budgetPreviousMonth));
  }
  await tap(
    tester,
    find.descendant(of: dayCell(date), matching: find.byType(InkWell)),
  );
  await waitFor(tester, find.text(DateFormat.MMMMEEEEd('de').format(date)));
}

/// A read-only appointment of the day list: its sheet.
Future<Finder> openReadOnly(WidgetTester tester, String title) async {
  await tap(tester, find.text(title).last);
  final sheet = find.byType(BottomSheet);
  await waitFor(tester, sheet);
  expect(
    find.descendant(of: sheet, matching: find.text(de.commonSave)),
    findsNothing,
  );
  return sheet;
}

Finder selectable(String text) =>
    find.byWidgetPredicate((w) => w is SelectableText && w.data == text);

Future<void> closeSheet(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 700));
  if (find.byType(BottomSheet).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(30, 30));
    await tester.pump(const Duration(milliseconds: 700));
  }
  await waitGone(tester, find.byType(BottomSheet));
}

/// Closes the sheet or dialog that holds [inside].
Future<void> closeTop(WidgetTester tester, Finder inside) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 600));
  if (inside.evaluate().isNotEmpty) {
    await Navigator.of(tester.element(inside.first)).maybePop();
    await tester.pump(const Duration(milliseconds: 600));
  }
}

/// The emergency number card titled [title].
Finder numberCard(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SoftCard)).first;

void expectCard(WidgetTester tester, String title, String subtitle) {
  expect(find.text(title), findsOneWidget, reason: title);
  expect(
    find.descendant(of: numberCard(title), matching: find.text(subtitle)),
    findsOneWidget,
    reason: '$title: $subtitle',
  );
}

/// The setup list from the banner on the start page.
Future<Finder> openSetupList(WidgetTester tester) async {
  await openSection(tester, 'Start');
  final banner = find.byWidgetPredicate(
    (w) =>
        w is Text &&
        RegExp(
          r'^Einrichtung abschließen \(\d+ von \d+\)$',
        ).hasMatch(w.data ?? ''),
  );
  await scrollTo(tester, banner, up: true);
  await tap(tester, banner);
  final list = find.byType(SetupChecklist);
  await waitFor(tester, list);
  return list;
}

/// The row of the setup step [title] in [list].
Finder stepRow(Finder list, String title) => find
    .ancestor(
      of: find.descendant(of: list, matching: find.text(title)),
      matching: find.byType(Row),
    )
    .first;

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // === Land der Familie =====================================================

  testWidgets('SIC-169 the family\'s country, then on another device', (
    tester,
  ) async {
    tall(tester);
    germanyAfterwards();
    final f = await theFamily();
    await setCountry(FamilyCountry.de);
    var state = await start(tester);
    await openCountrySettings(tester);

    // "Land": the three countries and what depends on it.
    expect(find.text(de.adminCountryHelper), findsOneWidget);
    expect(
      de.adminCountryHelper,
      'Danach richten sich Notrufnummern, Feiertage sowie die Hinweise zu '
      'Vorsorge, Impfungen und Mutterschutz.',
    );
    await show(tester, de.adminCountry);
    expect(shownIn(tester, de.adminCountry), 'Deutschland');
    await show(tester, de.adminCountry);
    expect(await lookInto(tester, de.adminCountry), [
      'Deutschland',
      'Österreich',
      'Schweiz',
    ]);
    await show(tester, de.adminCountry);
    expect(itemsOf(tester, de.adminCountry), [
      'Deutschland',
      'Österreich',
      'Schweiz',
    ]);

    // Österreich: "Bundesland" with the nine states, nothing else.
    await show(tester, de.adminCountry);
    await choose(tester, de.adminCountry, 'Österreich');
    await scrollTo(tester, find.text(de.adminFederalState));
    final austria = [
      de.adminNoPublicHolidays,
      for (final s in AustrianState.values) s.label,
    ];
    await show(tester, de.adminFederalState);
    expect(await lookInto(tester, de.adminFederalState), austria);
    await show(tester, de.adminFederalState);
    expect(itemsOf(tester, de.adminFederalState), austria);
    await show(tester, de.adminFederalState);
    await choose(tester, de.adminFederalState, 'Wien');
    await show(tester, de.adminFederalState);
    expect(shownIn(tester, de.adminFederalState), 'Wien');

    // Schweiz: "Kanton" with the cantons, empty after the change.
    await show(tester, de.adminCountry);
    await choose(tester, de.adminCountry, 'Schweiz');
    await scrollTo(tester, find.text(de.adminCanton));
    expect(find.text(de.adminFederalState), findsNothing);
    await show(tester, de.adminCanton);
    expect(shownIn(tester, de.adminCanton), de.adminNoPublicHolidays);
    final swiss = [
      de.adminNoPublicHolidays,
      for (final c in SwissCanton.values) c.label,
    ];
    await show(tester, de.adminCanton);
    expect(itemsOf(tester, de.adminCanton), swiss);
    await show(tester, de.adminCanton);
    expect(itemsOf(tester, de.adminCanton), isNot(contains('Wien')));
    await show(tester, de.adminCanton);
    expect(itemsOf(tester, de.adminCanton), isNot(contains('Berlin')));

    // Back to Österreich: the state is empty again; Wien, saved.
    await show(tester, de.adminCountry);
    await choose(tester, de.adminCountry, 'Österreich');
    await scrollTo(tester, find.text(de.adminFederalState));
    await show(tester, de.adminFederalState);
    expect(shownIn(tester, de.adminFederalState), de.adminNoPublicHolidays);
    await show(tester, de.adminFederalState);
    await choose(tester, de.adminFederalState, 'Wien');
    await saveSettings(tester);
    await waitFor(tester, find.text(de.adminServerSettingsSaved));
    final settings = (await f.admin.adminOverview()).settings;
    expect(settings.country, 'AT');
    expect(settings.holidayRegion, AustrianState.w.code);
    await finish(tester, state);

    // Another adult's device shows the numbers without a restart.
    await setCountry(FamilyCountry.de);
    state = await start(tester, user: f.bea.username);
    await eventually(
      tester,
      'Germany on Bea\'s device',
      () async => familyCountry == FamilyCountry.de,
    );
    await openSettingsItem(tester, de.memberEmergencyMine);
    await waitFor(tester, find.text('112 – ${de.kidsEmergency}'));
    await setCountry(FamilyCountry.at, region: AustrianState.w.code);
    await waitFor(
      tester,
      find.text('144 – ${de.emergencyRescue}'),
      timeout: const Duration(seconds: 90),
    );
    expect(find.text('112 – ${de.kidsEmergency}'), findsNothing);
    for (final title in [
      de.emergencyHealthLineAt,
      de.emergencyDoctorsAt,
      de.emergencyPoisonAt,
    ]) {
      await scrollTo(tester, find.text(title), at: _listPoint);
    }
    expect(
      [
        de.emergencyRescue,
        de.emergencyHealthLineAt,
        de.emergencyDoctorsAt,
        de.emergencyPoisonAt,
      ],
      [
        'Rettung',
        'Gesundheitsberatung 1450',
        'Ärztenotdienst',
        'Vergiftungsinformationszentrale',
      ],
    );
    // "oben": the rescue first, above the others.
    await scrollTo(tester, find.text('144 – ${de.emergencyRescue}'), up: true);
    expect(
      tester.getTopLeft(find.text('144 – ${de.emergencyRescue}')).dy,
      lessThan(tester.getTopLeft(find.text(de.emergencyHealthLineAt)).dy),
    );
    await finish(tester, state);
  });

  testWidgets('SIC-170 SIC-111 Austria: holidays and school holidays', (
    tester,
  ) async {
    tall(tester);
    germanyAfterwards();
    final f = await theFamily();
    await setCountry(FamilyCountry.de);
    final state = await start(tester);
    await openCountrySettings(tester);
    await show(tester, de.adminCountry);
    await choose(tester, de.adminCountry, 'Österreich');
    await scrollTo(tester, find.text(de.adminFederalState));
    await show(tester, de.adminFederalState);
    await choose(tester, de.adminFederalState, 'Wien');
    // The hint instead of a subscription (SIC-111: only German states).
    await scrollTo(tester, find.text(de.adminSchoolHolidaysAustria));
    expect(
      de.adminSchoolHolidaysAustria,
      'Die Schulferien des Bundeslands zeigt Famio nach dem '
      'Schulzeitgesetz im Kalender, ohne Gewähr.',
    );
    expect(
      find.text(de.adminSubscribeSchoolHolidaysRegion('Wien')),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data ?? '').startsWith('Schulferien') &&
            (w.data ?? '').endsWith('abonnieren'),
      ),
      findsNothing,
    );
    await saveSettings(tester);
    await waitFor(tester, find.text(de.adminServerSettingsSaved));
    expect(
      (await f.admin.adminOverview()).settings.holidayRegion,
      AustrianState.w.code,
    );
    await eventually(
      tester,
      'the app knows Vienna',
      () async => familyHolidayRegion == AustrianState.w,
    );

    // November 2026 to July 2027 as the calendar has it.
    final events = holidayEvents(DateTime(2026, 11), DateTime(2027, 8));
    final holidays = {
      for (final e in events)
        if (!isSchoolHolidaySource(e.sourceId)) e.title,
    };
    debugPrint('E2E-INFO SIC-170 holidays: $holidays');
    expect(
      holidays,
      containsAll([
        'Allerheiligen',
        'Mariä Empfängnis',
        'Weihnachten',
        'Stefanitag',
        'Neujahr',
        'Heilige Drei Könige',
        'Ostermontag',
        'Staatsfeiertag',
        'Christi Himmelfahrt',
        'Pfingstmontag',
        'Fronleichnam',
      ]),
    );
    expect(holidays, isNot(contains('Karfreitag')));
    final school = {
      for (final e in events)
        if (isSchoolHolidaySource(e.sourceId)) e.title,
    };
    debugPrint('E2E-INFO SIC-170 school holidays: $school');
    expect(
      school,
      containsAll([
        'Weihnachtsferien',
        'Semesterferien',
        'Osterferien',
        'Sommerferien',
      ]),
    );
    for (final e in events) {
      expect(e.allDay, isTrue, reason: e.title);
      expect(
        e.notes,
        isSchoolHolidaySource(e.sourceId)
            ? 'Schulferien in Wien nach dem Schulzeitgesetz, ohne Gewähr'
            : 'Gesetzlicher Feiertag in Wien',
        reason: e.title,
      );
    }

    // In the calendar: a holiday and the Christmas holidays, to read only.
    await openCalendarOn(tester, state, DateTime(2026, 12, 8));
    var sheet = await openReadOnly(tester, 'Mariä Empfängnis');
    expect(
      find.descendant(
        of: sheet,
        matching: selectable('Gesetzlicher Feiertag in Wien'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text(de.calendarAdminsSetFederalState),
      ),
      findsOneWidget,
    );
    await closeSheet(tester);
    await openCalendarOn(tester, state, DateTime(2026, 12, 29));
    sheet = await openReadOnly(tester, 'Weihnachtsferien');
    expect(
      find.descendant(
        of: sheet,
        matching: selectable(
          'Schulferien in Wien nach dem Schulzeitgesetz, ohne Gewähr',
        ),
      ),
      findsOneWidget,
    );
    await closeSheet(tester);
    await finish(tester, state);
  });

  testWidgets('SIC-171 Switzerland: a canton, no school holidays', (
    tester,
  ) async {
    tall(tester);
    germanyAfterwards();
    final f = await theFamily();
    await setCountry(FamilyCountry.de);
    final state = await start(tester);
    await openCountrySettings(tester);
    await show(tester, de.adminCountry);
    await choose(tester, de.adminCountry, 'Schweiz');
    await scrollTo(tester, find.text(de.adminSchoolHolidaysSwitzerland));
    expect(
      de.adminSchoolHolidaysSwitzerland,
      'In der Schweiz legen Kantone und Gemeinden die Schulferien fest. '
      'Famio zeigt sie deshalb nicht; den Ferienkalender der Gemeinde kannst '
      'du im Kalender abonnieren.',
    );
    await show(tester, de.adminCanton);
    expect(shownIn(tester, de.adminCanton), de.adminNoPublicHolidays);
    await saveSettings(tester);
    await waitFor(tester, find.text(de.adminServerSettingsSaved));
    final saved = (await f.admin.adminOverview()).settings;
    expect((saved.country, saved.holidayRegion), ('CH', null));

    // The setup list: the canton is missing.
    var list = await openSetupList(tester);
    var row = stepRow(list, 'Kanton für Feiertage');
    expect(
      find.descendant(
        of: row,
        matching: find.text('Ohne Kanton zeigt der Kalender keine Feiertage.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(AppIcons.warningCircle)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: list,
        matching: find.text('Bundesland für Feiertage'),
      ),
      findsNothing,
    );
    await closeTop(tester, list);
    await waitGone(tester, list);

    // Zürich: done, the holidays in the calendar.
    await openCountrySettings(tester);
    await scrollTo(tester, find.text(de.adminCanton));
    await show(tester, de.adminCanton);
    await choose(tester, de.adminCanton, 'Zürich');
    await saveSettings(tester);
    await waitFor(tester, find.text(de.adminServerSettingsSaved));
    expect(
      (await f.admin.adminOverview()).settings.holidayRegion,
      SwissCanton.zh.code,
    );
    list = await openSetupList(tester);
    await tap(
      tester,
      find.descendant(of: list, matching: find.byTooltip(de.commonCheckAgain)),
    );
    row = stepRow(list, 'Kanton für Feiertage');
    await waitFor(
      tester,
      find.descendant(
        of: row,
        matching: find.text('Die Feiertage erscheinen im Kalender.'),
      ),
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(AppIcons.check)),
      findsOneWidget,
    );
    await closeTop(tester, list);
    await waitGone(tester, list);
    await eventually(
      tester,
      'the app knows Zürich',
      () async => familyHolidayRegion == SwissCanton.zh,
    );
    final events = holidayEvents(DateTime(2026, 11), DateTime(2027, 8));
    final expected = {
      for (final year in [2026, 2027])
        for (final h in SwissCanton.zh.holidays(year))
          if (!h.date.isBefore(DateTime(2026, 11)) &&
              h.date.isBefore(DateTime(2027, 8)))
            h.name,
    };
    debugPrint('E2E-INFO SIC-171 holidays of Zürich: $expected');
    expect({for (final e in events) e.title}, expected);
    expect(events.where((e) => isSchoolHolidaySource(e.sourceId)), isEmpty);
    // Christmas in the calendar.
    final christmas = SwissCanton.zh
        .holidays(2026)
        .firstWhere((h) => h.date.month == 12 && h.date.day == 25);
    await openCalendarOn(tester, state, DateTime(2026, 12, 25));
    final sheet = await openReadOnly(tester, christmas.name);
    expect(
      find.descendant(
        of: sheet,
        matching: selectable('Gesetzlicher Feiertag in Zürich'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text(de.calendarAdminsSetCanton),
      ),
      findsOneWidget,
    );
    await closeSheet(tester);
    // No school holidays anywhere in the winter.
    await openCalendarOn(tester, state, DateTime(2026, 12, 29));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Weihnachtsferien'), findsNothing);
    await finish(tester, state);
  });

  testWidgets('SIC-172 emergency numbers follow the country', (tester) async {
    tall(tester);
    germanyAfterwards();
    final f = await theFamily();
    final me = f.adminMember.id;
    final child = uid('child');
    await seed(f.admin, Collections.children, {
      child: {
        ...Child(
          id: child,
          name: 'E2E Notrufkind',
          birthDate: DateTime(2020, 4, 2),
          guardianIds: [me],
        ).toData(),
        SyncRecord.visibilityKey: [me],
      },
    });
    addTearDown(() => remove(f.admin, Collections.children, [child]));
    await setCountry(FamilyCountry.ch);
    final state = await start(tester);
    await eventually(
      tester,
      'Switzerland in the app',
      () async => familyCountry == FamilyCountry.ch,
    );

    Future<void> swiss() async {
      final rescue = '144 – ${de.emergencyRescue}';
      await waitFor(tester, find.text(rescue));
      // Large and red, first.
      final card = tester.widget<SoftCard>(numberCard(rescue));
      expect(
        card.color,
        Theme.of(tester.element(find.text(rescue))).colorScheme.error,
      );
      expect(
        tester.widget<Text>(find.text(rescue)).style?.fontSize,
        Theme.of(
          tester.element(find.text(rescue)),
        ).textTheme.headlineSmall?.fontSize,
      );
      expectCard(tester, 'Tox Info Suisse', de.emergencyPoisonChNote);
      expect(
        de.emergencyPoisonChNote,
        '145 – Vergiftungsnotruf, rund um die Uhr',
      );
      expectCard(tester, de.emergencyDoctorsCh, de.emergencyDoctorsChNote);
      expect(
        de.emergencyDoctorsChNote,
        startsWith('Die Nummer ist je nach Kanton verschieden'),
      );
      // The doctors' service starts no call; the others do.
      _launcher.opened.clear();
      await tap(tester, find.text(de.emergencyDoctorsCh));
      await tester.pump(const Duration(seconds: 1));
      expect(_launcher.opened, isEmpty);
      expect(
        tester.widget<SoftCard>(numberCard(de.emergencyDoctorsCh)).onTap,
        isNull,
      );
      await tap(tester, find.text('Tox Info Suisse'));
      await eventually(
        tester,
        'Tox Info Suisse dialled',
        () async => _launcher.opened.contains('tel:145'),
      );
      expect(find.text('112 – ${de.kidsEmergency}'), findsNothing);
      expect(find.text(de.kidsOutHoursMedicalService), findsNothing);
    }

    Future<void> german() async {
      await waitFor(tester, find.text('112 – ${de.kidsEmergency}'));
      expectCard(
        tester,
        de.kidsOutHoursMedicalService,
        de.kids116117WhenPractice,
      );
      expectCard(
        tester,
        de.kidsPoisonControl,
        de.kids03019240ReachableNationwide,
      );
      expect(
        [de.kidsOutHoursMedicalService, de.kidsPoisonControl],
        ['Ärztlicher Bereitschaftsdienst', 'Giftnotruf'],
      );
      expect(find.text('144 – ${de.emergencyRescue}'), findsNothing);
      expect(find.text('Tox Info Suisse'), findsNothing);
      _launcher.opened.clear();
      await tap(tester, find.text(de.kidsOutHoursMedicalService));
      await eventually(
        tester,
        '116117 dialled',
        () async => _launcher.opened.contains('tel:116117'),
      );
    }

    Future<void> childPage() async {
      await openSection(tester, 'Kinder');
      if (find.byType(KidsScreen).evaluate().isEmpty) {
        await openSection(tester, 'Kinder');
      }
      await scrollTo(tester, find.text('E2E Notrufkind'), at: _listPoint);
      await tap(tester, find.text('E2E Notrufkind'));
      await waitFor(tester, find.byType(ChildScreen));
      await tap(tester, find.byTooltip(de.kidsEmergencyTitle));
      await waitFor(tester, find.text(de.kidsEmergencyName('E2E Notrufkind')));
    }

    // Switzerland: the own page and the child's.
    await openSettingsItem(tester, de.memberEmergencyMine);
    await swiss();
    await back(tester);
    await childPage();
    await swiss();
    await back(tester);
    await back(tester);

    // Germany.
    await setCountry(FamilyCountry.de);
    await eventually(
      tester,
      'Germany in the app',
      () async => familyCountry == FamilyCountry.de,
      timeout: const Duration(seconds: 90),
    );
    await openSettingsItem(tester, de.memberEmergencyMine);
    await german();
    await back(tester);
    await childPage();
    await german();
    await finish(tester, state);
  });

  // === Elternteil entfernen ===================================================

  testWidgets(
    'SIC-195 a guardian removed: the children\'s data go to the others',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      final anna = await freshMember('e2e-sic-anna', 'E2E Anna');
      final bert = await freshMember('e2e-sic-bert', 'E2E Bert');
      final b = await loginAs(bert);
      final a = await loginAs(anna);
      final kid = await sessionOf(f.kid);
      final ids = {
        for (final k in [
          'ben',
          'benEntry',
          'benLog',
          'lina',
          'linaEntry',
          'kim',
          'kimLog',
        ])
          k: uid(k),
      };
      final now = DateTime.now();
      // Ben: guardians Anna and Bert; what is his only Bert sees.
      await seed(b, Collections.children, {
        ids['ben']!: {
          ...Child(
            id: ids['ben']!,
            name: 'E2E Ben',
            birthDate: DateTime(2019, 5, 1),
            guardianIds: [anna.id, bert.id],
          ).toData(),
          SyncRecord.visibilityKey: [bert.id],
        },
        // Lina: only Bert is her guardian.
        ids['lina']!: {
          ...Child(
            id: ids['lina']!,
            name: 'E2E Lina',
            birthDate: DateTime(2021, 2, 3),
            guardianIds: [bert.id],
          ).toData(),
          SyncRecord.visibilityKey: [bert.id],
        },
        // Kim: the child account itself is named next to Bert.
        ids['kim']!: {
          ...Child(
            id: ids['kim']!,
            name: 'E2E Kim',
            birthDate: DateTime(2015, 9, 9),
            guardianIds: [bert.id],
          ).toData(),
          SyncRecord.visibilityKey: [bert.id, f.kid.id],
        },
      });
      await seed(b, Collections.childEntries, {
        ids['benEntry']!: {
          ...ChildEntry(
            id: ids['benEntry']!,
            childId: ids['ben']!,
            kind: ChildEntryKind.memory,
            date: now,
            title: 'E2E Bens erster Zahn',
          ).toData(),
          SyncRecord.visibilityKey: [bert.id],
        },
        ids['linaEntry']!: {
          ...ChildEntry(
            id: ids['linaEntry']!,
            childId: ids['lina']!,
            kind: ChildEntryKind.memory,
            date: now,
            title: 'E2E Linas Laufrad',
          ).toData(),
          SyncRecord.visibilityKey: [bert.id],
        },
      });
      await seed(b, Collections.childLogs, {
        ids['benLog']!: {
          ...ChildLog(
            id: ids['benLog']!,
            childId: ids['ben']!,
            kind: LogKind.symptom,
            start: now,
            symptom: 'E2E Husten Ben',
          ).toData(),
          SyncRecord.visibilityKey: [bert.id],
        },
        ids['kimLog']!: {
          ...ChildLog(
            id: ids['kimLog']!,
            childId: ids['kim']!,
            kind: LogKind.symptom,
            start: now,
            symptom: 'E2E Bauchweh Kim',
          ).toData(),
          SyncRecord.visibilityKey: [bert.id, f.kid.id],
        },
      });
      await seed(b, Collections.timetables, {
        ids['ben']!: {
          ...Timetable(
            childId: ids['ben']!,
            school: 'E2E Grundschule',
          ).toData(),
          SyncRecord.visibilityKey: [bert.id],
        },
      });
      addTearDown(() async {
        final admin = (await theFamily()).admin;
        await remove(admin, Collections.childEntries, [
          ids['benEntry']!,
          ids['linaEntry']!,
        ]);
        await remove(admin, Collections.childLogs, [
          ids['benLog']!,
          ids['kimLog']!,
        ]);
        await remove(admin, Collections.timetables, [ids['ben']!]);
        await remove(admin, Collections.children, [
          ids['ben']!,
          ids['lina']!,
          ids['kim']!,
        ]);
      });

      Future<Map<String, Set<String>>> sees(FamioApiClient api) async => {
        for (final c in [
          Collections.children,
          Collections.childEntries,
          Collections.childLogs,
          Collections.timetables,
        ])
          c: (await pull(api, c)).keys.toSet(),
      };
      // Before: Anna sees nothing of it.
      final before = await sees(a);
      for (final id in ids.values) {
        for (final c in before.values) {
          expect(c, isNot(contains(id)));
        }
      }

      // Server-Verwaltung → Benutzer → Bert → "E2E Bert entfernen".
      final state = await startApp(tester);
      await dismissTip(tester);
      await openAdmin(tester, 'Benutzer');
      await scrollTo(tester, find.text('E2E Bert'));
      await tap(tester, find.text('E2E Bert').last);
      await waitFor(tester, find.text(de.adminRole));
      final entry = find.text(de.adminRemoveName('E2E Bert'));
      await scrollTo(tester, entry);
      await tap(tester, entry);
      await waitFor(tester, find.text(de.commonRemoveName('E2E Bert')));
      expect(de.commonRemoveName('E2E Bert'), '„E2E Bert“ entfernen?');
      await tap(
        tester,
        inDialog(find.widgetWithText(FilledButton, de.commonRemove)),
      );
      await waitGone(tester, find.text(de.adminRole));
      expect(
        (await f.admin.adminUsers()).map((u) => u.member.id),
        isNot(contains(bert.id)),
      );

      // Anna: the children and everything only Bert saw.
      late Map<String, Set<String>> after;
      await eventually(tester, 'Anna gets the children\'s data', () async {
        after = await sees(a);
        return after[Collections.children]!.containsAll([
          ids['ben']!,
          ids['lina']!,
          ids['kim']!,
        ]);
      });
      expect(
        after[Collections.childEntries],
        containsAll([ids['benEntry']!, ids['linaEntry']!]),
      );
      expect(
        after[Collections.childLogs],
        containsAll([ids['benLog']!, ids['kimLog']!]),
      );
      expect(after[Collections.timetables], contains(ids['ben']!));
      final children = await pull(a, Collections.children);
      final entries = await pull(a, Collections.childEntries);
      final logs = await pull(a, Collections.childLogs);
      // Ben's go to Anna, his other guardian; no one else.
      expect(children[ids['ben']!]!.visibleTo, [anna.id]);
      expect(children[ids['ben']!]!.data['guardianIds'], [anna.id]);
      expect(entries[ids['benEntry']!]!.visibleTo, [anna.id]);
      expect(logs[ids['benLog']!]!.visibleTo, [anna.id]);
      expect((await pull(a, Collections.timetables))[ids['ben']!]!.visibleTo, [
        anna.id,
      ]);
      final carl = await sessionOf(f.carl);
      final carlSees = await sees(carl);
      expect(
        carlSees[Collections.childEntries],
        isNot(contains(ids['benEntry']!)),
      );
      expect(carlSees[Collections.timetables], isNot(contains(ids['ben']!)));
      // Lina, without a guardian left: all adults.
      expect(children[ids['lina']!]!.data['guardianIds'], isEmpty);
      expect(carlSees[Collections.children], contains(ids['lina']!));
      expect(carlSees[Collections.childEntries], contains(ids['linaEntry']!));
      // Kim: still the child account's, now also the adults'.
      expect(logs[ids['kimLog']!]!.visibleTo, contains(f.kid.id));
      expect(logs[ids['kimLog']!]!.visibleTo, contains(anna.id));
      final kidSees = await sees(kid);
      expect(kidSees[Collections.children], contains(ids['kim']!));
      expect(kidSees[Collections.childLogs], contains(ids['kimLog']!));
      expect(
        kidSees[Collections.childEntries],
        isNot(contains(ids['benEntry']!)),
      );
      await finish(tester, state);
    },
  );
}
