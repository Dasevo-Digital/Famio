// Catalog KIN, entries of 23.11.2026 (the family in Austria or
// Switzerland: check-ups, vaccinations, pregnancy, emergency numbers, fever
// hints, the medication plan) and the parts of changed entries the older
// file does not check (undo after reset and delete, the chip of the child
// card, the shopping list of a medicine), against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_kin_b_test.dart
//
// Tests that switch the country of the family switch it back to Germany at
// their end: the tests of this file share one server. Reminders are what
// the running app plans (familyReminders of the reminder service); the
// system's notifications are not waited for.
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/country.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/health_logic.dart';
import 'package:famio/src/data/kids_logic.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/kids_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'catalog_kal_b_test.dart' show FakeLauncher;
import 'catalog_kit.dart';

/// No connection to anywhere: every new HTTP client goes to a proxy that
/// refuses (the server is out of reach, as without network).
class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'PROXY 127.0.0.1:9';
}

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // --- seeds: what another device of the admin writes ---------------------

  final audience = <String, List<String>>{};

  Future<FamioApiClient> adminApi() async => (await theFamily()).admin;
  Future<String> adminId() async => (await theFamily()).adminMember.id;

  DateTime born({int years = 0, int months = 0, int days = 0}) {
    final t = today();
    return DateTime(t.year - years, t.month - months, t.day - days);
  }

  Future<void> seed(
    FamioApiClient api,
    String collection,
    Map<String, Map<String, Object?>> records,
  ) async {
    final answer = await put(api, collection, records);
    expect(
      answer.rejected.map((r) => r.id),
      isEmpty,
      reason: 'seed of $collection',
    );
  }

  Future<String> seedChild(String name, DateTime birth) async {
    final g = [await adminId()];
    final id = uid('child');
    audience[id] = g;
    await seed(await adminApi(), Collections.children, {
      id: {
        ...Child(id: id, name: name, birthDate: birth, guardianIds: g).toData(),
        SyncRecord.visibilityKey: g,
      },
    });
    return id;
  }

  Future<void> seedEntries(List<ChildEntry> entries) async {
    await seed(await adminApi(), Collections.childEntries, {
      for (final e in entries)
        e.id: {...e.toData(), SyncRecord.visibilityKey: audience[e.childId]},
    });
  }

  ChildEntry entry(
    String childId,
    ChildEntryKind kind,
    DateTime date, {
    String? refId,
    bool planned = false,
    String? time,
    double? heightCm,
    double? weightKg,
    List<FileRef> photos = const [],
  }) => ChildEntry(
    id: uid('entry'),
    childId: childId,
    kind: kind,
    date: date,
    refId: refId,
    planned: planned,
    time: time,
    heightCm: heightCm,
    weightKg: weightKg,
    photos: photos,
  );

  Future<String> seedPregnancy(String name, DateTime due) async {
    final g = [await adminId()];
    final id = uid('pregnancy');
    await seed(await adminApi(), Collections.pregnancies, {
      id: {
        ...Pregnancy(id: id, dueDate: due, name: name, guardianIds: g).toData(),
        SyncRecord.visibilityKey: g,
      },
    });
    return id;
  }

  /// The country of the family through the API (another device of the
  /// admin); Germany without a state again at the end of the test.
  Future<void> country(String code, [String? region]) async {
    final api = await adminApi();
    addTearDown(
      () => api.updateServerSettings({'country': 'DE', 'holidayRegion': null}),
    );
    await api.updateServerSettings({'country': code, 'holidayRegion': region});
  }

  Future<void> countryIs(WidgetTester tester, FamilyCountry c) =>
      eventually(tester, 'the app follows: $c', () async => familyCountry == c);

  // --- the app ---------------------------------------------------------------

  Future<void> until(
    WidgetTester tester,
    bool Function() ok,
    String what, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    debugPrint('E2E until $what');
    final end = DateTime.now().add(timeout);
    while (!ok()) {
      if (DateTime.now().isAfter(end)) {
        throw TestFailure('Timed out: $what\nOn screen: ${onScreen()}');
      }
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Waits for what another device wrote.
  Future<void> arrives(
    WidgetTester tester,
    AppState state,
    bool Function(SyncEngine engine) ok,
    String what,
  ) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (!ok(state.engine!)) {
      if (DateTime.now().isAfter(end)) throw TestFailure('Timed out: $what');
      await state.engine!.sync();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  Finder byTypeName(String name) =>
      find.byWidgetPredicate((w) => w.runtimeType.toString() == name);
  final pillTabs = find.byWidgetPredicate(
    (w) => w.runtimeType.toString().startsWith('PillTabs<'),
  );
  Future<void> tab(WidgetTester tester, String label) => tap(
    tester,
    find.descendant(of: pillTabs.first, matching: find.text(label)),
  );

  Finder sheet() => find.byType(BottomSheet);
  Finder inSheet(Finder f) => find.descendant(of: sheet(), matching: f);

  Future<void> closeSheet(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump(const Duration(milliseconds: 300));
    await waitGone(tester, sheet(), timeout: const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Finder snackText(String text) =>
      find.descendant(of: find.byType(SnackBar), matching: find.text(text));
  Finder snackWith(String part) => find.descendant(
    of: find.byType(SnackBar),
    matching: find.textContaining(part),
  );
  Future<void> undo(WidgetTester tester) => tap(
    tester,
    find.descendant(
      of: find.byType(SnackBar),
      matching: find.text(de.commonUndo),
    ),
  );

  /// [finder] at the top of a list that may still be scrolled down (the
  /// tabs of a child keep their place).
  Future<void> top(WidgetTester tester, Finder finder) async {
    await tester.pump(const Duration(milliseconds: 500));
    await scrollTo(tester, finder, up: true);
  }

  Finder inCard(String title, Finder what) =>
      find.descendant(of: cardOf(title), matching: what);

  /// The texts of the card titled [title].
  List<String> cardTexts(WidgetTester tester, String title) => [
    for (final e
        in find
            .descendant(of: cardOf(title), matching: find.byType(Text))
            .evaluate())
      (e.widget as Text).data ?? '',
  ];

  Future<void> expectStatus(
    WidgetTester tester,
    String title,
    String status,
  ) async {
    await scrollTo(tester, find.text(title));
    expect(
      inCard(title, find.text(status)),
      findsOneWidget,
      reason: '$title: $status',
    );
  }

  Future<void> tickCard(WidgetTester tester, String title) async {
    await scrollTo(tester, find.text(title));
    await tap(tester, inCard(title, find.byType(RoundCheck)));
  }

  Future<void> kidsList(WidgetTester tester) async {
    await openSection(tester, 'Kinder');
    if (find.byType(KidsScreen).evaluate().isEmpty) {
      await openSection(tester, 'Kinder');
    }
    await waitFor(tester, find.byType(KidsScreen));
  }

  Future<void> inKidsList(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await tester.dragFrom(const Offset(600, 300), const Offset(0, 500));
      await tester.pump(const Duration(milliseconds: 150));
    }
    for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
      await tester.dragFrom(const Offset(600, 450), const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await waitFor(tester, finder, timeout: const Duration(seconds: 3));
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openChild(WidgetTester tester, String name) async {
    await kidsList(tester);
    await inKidsList(tester, find.text(name));
    await tap(tester, find.text(name));
    await waitFor(tester, find.byType(ChildScreen));
  }

  Future<void> openPregnancy(WidgetTester tester, String name) async {
    await kidsList(tester);
    await inKidsList(tester, find.text(name));
    await tap(tester, find.text(name));
    await waitFor(tester, find.byType(PregnancyScreen));
  }

  void tallView(WidgetTester tester, {double height = 760}) {
    final dpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = Size(800 * dpr, height * dpr);
    addTearDown(tester.view.resetPhysicalSize);
  }

  Future<AppState> start(WidgetTester tester, {String? user}) async {
    tallView(tester);
    await initializeDateFormatting('de');
    return startApp(tester, user: user);
  }

  /// Types [date] into an open date picker; whether the picker accepted it.
  Future<bool> typeDate(WidgetTester tester, DateTime date) async {
    final input = find.widgetWithText(TextField, 'Datum eingeben');
    if (input.evaluate().isEmpty) {
      await tap(tester, find.byTooltip('Zur Texteingabe wechseln'));
    }
    await enter(tester, input, DateFormat.yMd('de').format(date));
    await tester.tap(find.text('OK').last, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 900));
    return input.evaluate().isEmpty;
  }

  /// Every text of the page, scrolled from top to bottom.
  Future<Set<String>> pageTexts(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.dragFrom(const Offset(600, 300), const Offset(0, 300));
      await tester.pump(const Duration(milliseconds: 150));
    }
    final seen = <String>{};
    for (var i = 0; i < 20; i++) {
      seen.addAll(onScreen().split(' | '));
      await tester.dragFrom(const Offset(600, 450), const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 200));
    }
    seen.addAll(onScreen().split(' | '));
    return seen;
  }

  Future<bool> anywhere(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 12; i++) {
      await tester.dragFrom(const Offset(600, 300), const Offset(0, 300));
      await tester.pump(const Duration(milliseconds: 150));
    }
    for (var i = 0; i < 20; i++) {
      if (finder.evaluate().isNotEmpty) return true;
      await tester.dragFrom(const Offset(600, 450), const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 200));
    }
    return finder.evaluate().isNotEmpty;
  }

  /// Server-Verwaltung → Einstellungen → "Land" = [label], saved.
  Future<void> countryInApp(WidgetTester tester, String label) async {
    await openAdmin(tester, 'Einstellungen');
    final dropdown = find.ancestor(
      of: find.text(de.adminCountry),
      matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
    );
    await scrollTo(tester, dropdown);
    await choose(tester, de.adminCountry, label);
    await scrollTo(tester, find.text(de.commonSave));
    await tap(tester, find.text(de.commonSave).last);
    await waitFor(tester, find.text(de.adminServerSettingsSaved));
    await back(tester);
    await snackGone(tester);
  }

  /// The quick button of the daily log.
  Finder quickButton(String label) => find.ancestor(
    of: find.descendant(
      of: byTypeName('_QuickButtons'),
      matching: find.text(label),
    ),
    matching: find.byType(InkWell),
  );

  Future<void> typeTemperature(WidgetTester tester, String value) async {
    if (find.widgetWithText(TextField, 'Temperatur (°C)').evaluate().isEmpty) {
      await scrollTo(tester, quickButton(de.kidsLogTemperature), up: true);
      await tap(tester, quickButton(de.kidsLogTemperature));
    }
    await enter(tester, field('Temperatur (°C)'), value);
    await tester.pump(const Duration(milliseconds: 300));
  }

  String adviceText(WidgetTester tester, FeverLevel level) {
    final box = byTypeName('_AdviceBox');
    if (box.evaluate().isEmpty) return '';
    final w = tester.widget(box.first) as dynamic;
    expect(w.level, level);
    return w.text as String;
  }

  /// Saves the temperature: the dialog with [title] and [text].
  Future<void> dialog(WidgetTester tester, String title, String text) async {
    await tap(tester, inSheet(find.text(de.commonSave)));
    await waitFor(tester, find.byType(AlertDialog));
    expect(find.text(title), findsOneWidget);
    expect(find.text(de.kidsLogTextFamioDoesNot(text)), findsOneWidget);
    await tap(tester, find.text(de.commonUnderstood).last);
    await dialogClosed(tester);
  }

  /// The kid reminders the app plans for the next [days] days.
  List<DueReminder> kidReminders(AppState state, String childId, int days) {
    final now = DateTime.now();
    return [
      for (final r in familyReminders(
        state.engine!,
        from: now,
        to: now.add(Duration(days: days)),
      ))
        if (r.key.startsWith('kid:$childId:')) r,
    ];
  }

  final stateLabels = [
    de.commonDoneLower,
    de.dueDueNow,
    de.dueCanStillDone,
    de.dueNotRecorded,
    de.duePeriodOver,
    de.pregnancySoon,
    de.commonEvent,
  ];
  final aDate = RegExp(r'\d{1,2}\.\d{1,2}\.\d{4}');

  String md(DateTime d) => DateFormat.Md('de').format(d);

  // =========================================================================
  // Check-ups and vaccinations outside Germany
  // =========================================================================

  testWidgets(
    'KIN-146 KIN-157 check-ups in Austria without German windows; back in Germany, all kept',
    (tester) async {
      final id = await seedChild('E2E Vorsorge AT', born(days: 35));
      final booked = inDays(7);
      await seedEntries([
        entry(
          id,
          ChildEntryKind.checkup,
          inDays(-3),
          refId: 'U3',
          heightCm: 54,
          weightKg: 4.4,
        ),
        entry(
          id,
          ChildEntryKind.vaccination,
          booked,
          refId: 'rota_1',
          planned: true,
          time: '10:30',
        ),
        entry(
          id,
          ChildEntryKind.measurement,
          inDays(-1),
          heightCm: 55,
          weightKg: 4.5,
        ),
      ]);
      final f = await theFamily();
      addTearDown(
        () => f.admin.updateServerSettings({
          'country': 'DE',
          'holidayRegion': null,
        }),
      );
      final state = await start(tester);
      await countryIs(tester, FamilyCountry.de);
      await arrives(
        tester,
        state,
        (e) => e.childEntries(id).length == 3,
        'entries',
      );
      final child = state.engine!.child(id)!;

      // In Germany: the booklet's windows.
      await openChild(tester, 'E2E Vorsorge AT');
      await tab(tester, de.kidsTabCheckups);
      await top(tester, find.text(de.kidsPeriodsGermanChildHealth));
      await expectStatus(tester, 'U3', de.commonDoneLower);
      await expectStatus(tester, 'U4', de.pregnancySoon);
      expect(
        cardTexts(tester, 'U4').any((t) => aDate.hasMatch(t)),
        isTrue,
        reason: 'a period with dates',
      );
      expect(await anywhere(tester, find.text('J2')), isFalse);
      expect(
        kidReminders(state, id, 60).any((r) => r.key.endsWith(':start')),
        isTrue,
        reason: 'German reminders of the windows',
      );

      // KIN-157: Austria chosen in the app.
      await countryInApp(tester, 'Österreich');
      await countryIs(tester, FamilyCountry.at);
      await openChild(tester, 'E2E Vorsorge AT');
      await tab(tester, de.kidsTabCheckups);

      // KIN-146
      await top(
        tester,
        find.text(de.kidsCheckupsOtherCountry(de.countryInAustria)),
      );
      await expectStatus(tester, 'U3', de.commonDoneLower);
      final u4 = checkupPlan(
        child,
        state.engine!.childEntries(id),
      ).singleWhere((d) => d.id == 'U4');
      expect(u4.state, DueState.unscheduled);
      await scrollTo(tester, find.text('U4'));
      final texts = cardTexts(tester, 'U4');
      expect(texts, contains(u4.subtitle));
      expect(texts.where((t) => aDate.hasMatch(t)), isEmpty, reason: '$texts');
      expect(texts.where(stateLabels.contains), isEmpty, reason: '$texts');
      expect(find.textContaining('nachtragen'), findsNothing);
      final all = await pageTexts(tester);
      expect(all, contains('J2'), reason: 'the list goes on to J2');
      expect(all.where((t) => t == de.duePeriodOver), isEmpty);
      // An appointment for the U4.
      await tickCard(tester, 'U4');
      for (final b in [
        de.dueDoneToday,
        de.dueOtherDateMeasurementsNote,
        de.dueAddAppointment,
        de.dueDoneDateUnknown2,
      ]) {
        expect(find.text(b), findsOneWidget, reason: b);
      }
      await tap(tester, find.text(de.dueAddAppointment));
      await tap(tester, inSheet(find.textContaining('Am ')));
      expect(await typeDate(tester, inDays(10)), isTrue);
      await tap(tester, inSheet(find.text(de.kidsSaveAppointment)));
      await waitGone(tester, sheet());
      await expectStatus(tester, 'U4', de.commonEvent);
      await tab(tester, de.kidsTabVaccinations);
      await top(
        tester,
        find.text(de.kidsVaccinationsOtherCountry(de.countryInAustria)),
      );
      await expectStatus(tester, 'Rotaviren – 1. Dosis', de.commonEvent);
      await tab(tester, de.kidsTabGrowth);
      await scrollTo(tester, find.widgetWithText(ListTile, '55 cm · 4,5 kg'));
      // Reminders only for what is booked.
      final reminders = kidReminders(state, id, 60);
      debugPrint(
        'E2E-INFO reminders in Austria: ${reminders.map((r) => r.key)}',
      );
      expect(reminders, isNotEmpty);
      expect(reminders.every((r) => r.key.contains(':appt')), isTrue);

      // Back in Germany: windows, states and reminders again.
      await countryInApp(tester, 'Deutschland');
      await countryIs(tester, FamilyCountry.de);
      await openChild(tester, 'E2E Vorsorge AT');
      await tab(tester, de.kidsTabCheckups);
      await top(tester, find.text(de.kidsPeriodsGermanChildHealth));
      await expectStatus(tester, 'U3', de.commonDoneLower);
      await expectStatus(tester, 'U4', de.commonEvent);
      await expectStatus(tester, 'U5', de.pregnancySoon);
      expect(cardTexts(tester, 'U5').any((t) => aDate.hasMatch(t)), isTrue);
      await tab(tester, de.kidsTabVaccinations);
      await top(tester, find.text(de.kidsBasedStikoVaccinationCalendar));
      await expectStatus(tester, 'Rotaviren – 1. Dosis', de.commonEvent);
      await tab(tester, de.kidsTabGrowth);
      await scrollTo(tester, find.widgetWithText(ListTile, '55 cm · 4,5 kg'));
      expect(state.engine!.childEntries(id), hasLength(4));
      expect(
        kidReminders(state, id, 60).any((r) => !r.key.contains(':appt')),
        isTrue,
        reason: 'the German reminders are back',
      );
      await finish(tester, state);
    },
  );

  testWidgets('KIN-147 vaccinations in Switzerland without windows', (
    tester,
  ) async {
    final id = await seedChild('E2E Impfen CH', born(days: 91));
    await country('CH');
    final state = await start(tester);
    await countryIs(tester, FamilyCountry.ch);
    await arrives(tester, state, (e) => e.child(id) != null, 'child');
    await openChild(tester, 'E2E Impfen CH');
    await tab(tester, de.kidsTabVaccinations);
    await top(
      tester,
      find.text(de.kidsVaccinationsOtherCountry(de.countryInSwitzerland)),
    );
    await scrollTo(tester, find.text('Rotaviren – 1. Dosis'));
    final texts = cardTexts(tester, 'Rotaviren – 1. Dosis');
    expect(texts, ['Rotaviren – 1. Dosis'], reason: 'only the title: $texts');
    expect(find.textContaining('nachtragen'), findsNothing);
    final all = await pageTexts(tester);
    expect(all.where((t) => t.startsWith('Empfohlen ab')), isEmpty);
    expect(all.where(stateLabels.contains), isEmpty, reason: '$all');
    expect(
      vaccinationPlan(
        state.engine!.child(id)!,
        const [],
      ).every((d) => d.state == DueState.unscheduled && !d.tooLate),
      isTrue,
    );
    // Also the rotavirus dose: today, or an appointment.
    await tickCard(tester, 'Rotaviren – 1. Dosis');
    expect(inSheet(find.text(de.dueDoneToday)), findsOneWidget);
    expect(inSheet(find.text(de.dueAddAppointment)), findsOneWidget);
    await closeSheet(tester);
    await finish(tester, state);
  });

  testWidgets(
    'KIN-148 coming up, the card, the tile and the reminders in Austria',
    (tester) async {
      final id = await seedChild('E2E Demnächst AT', born(days: 61));
      final booked = inDays(7);
      await seedEntries([
        entry(
          id,
          ChildEntryKind.vaccination,
          booked,
          refId: 'six_1',
          planned: true,
          time: '10:30',
        ),
      ]);
      await country('AT', 'AT-9');
      final state = await start(tester);
      await countryIs(tester, FamilyCountry.at);
      await arrives(
        tester,
        state,
        (e) => e.childEntries(id).isNotEmpty,
        'the appointment',
      );
      final child = state.engine!.child(id)!;
      final six = vaccinationPlan(
        child,
        state.engine!.childEntries(id),
      ).singleWhere((d) => d.id == 'six_1');
      await openChild(tester, 'E2E Demnächst AT');
      await tab(tester, de.kidsTabTimeline);
      await waitFor(tester, find.text(de.tasksComingUp));
      await scrollTo(tester, find.text(de.dueVaccination(six.title)));
      await scrollTo(tester, find.textContaining('Typisch zwischen '));
      final all = await pageTexts(tester);
      expect(all.where((t) => t.startsWith('Jetzt fällig')), isEmpty);
      expect(
        all.where(
          (t) => t.startsWith('Impfung: ') || RegExp(r'^U\d').hasMatch(t),
        ),
        [de.dueVaccination(six.title)],
        reason: 'only the booked one: $all',
      );
      // The card of the list and the tile of the start page.
      final chip = de.homeWhatDate(de.commonVaccination, md(booked));
      await kidsList(tester);
      await inKidsList(tester, find.text('E2E Demnächst AT'));
      expect(
        find.descendant(
          of: cardOf('E2E Demnächst AT'),
          matching: find.text(chip),
        ),
        findsOneWidget,
      );
      await openSection(tester, 'Start');
      expect(await anywhere(tester, find.text(chip)), isTrue);
      // Reminders: the evening before at 18 o'clock and an hour before.
      final reminders = kidReminders(state, id, 14);
      debugPrint(
        'E2E-INFO reminders: ${reminders.map((r) => '${r.key} ${r.at}')}',
      );
      expect(reminders.map((r) => r.at).toSet(), {
        DateTime(booked.year, booked.month, booked.day - 1, 18),
        DateTime(booked.year, booked.month, booked.day, 9, 30),
      });
      expect(reminders.where((r) => r.key.contains(':book')), isEmpty);
      await finish(tester, state);
    },
  );

  testWidgets('KIN-149 a pregnancy in Austria', (tester) async {
    final id = await seedPregnancy('E2E Schwanger AT', inDays(140));
    await country('AT', 'AT-9');
    tallView(tester, height: 1400);
    await initializeDateFormatting('de');
    final state = await startApp(tester);
    await countryIs(tester, FamilyCountry.at);
    await arrives(tester, state, (e) => e.pregnancy(id) != null, 'pregnancy');
    await openPregnancy(tester, 'E2E Schwanger AT');
    await tab(tester, de.commonWeek);
    var all = await pageTexts(tester);
    expect(all.where((t) => t.startsWith('Mutterschutz')), isEmpty);
    expect(all.where((t) => t.startsWith('ET ')), hasLength(1));
    expect(
      all,
      contains(de.pregnancySizesAveragesOtherCountry(de.countryInAustria)),
    );

    await tab(tester, de.commonEvents);
    await waitFor(
      tester,
      find.text(de.pregnancyCheckupsOtherCountry(de.countryInAustria)),
    );
    all = await pageTexts(tester);
    for (final gone in [
      '1. Ultraschall-Screening',
      '2. Ultraschall-Screening',
      '3. Ultraschall-Screening',
      'Zuckertest (Glukose)',
      'Keuchhusten-Impfung',
      'Mutterschaftsgeld beantragen',
    ]) {
      expect(all, isNot(contains(gone)), reason: gone);
    }
    expect(all, contains('Kinderarzt suchen'));
    expect(
      all.any(
        (t) => t.contains(
          'Für die ersten Untersuchungen nach der Geburt und die weiteren Vorsorgen.',
        ),
      ),
      isTrue,
      reason: '$all',
    );

    await tab(tester, de.pregnancyChecklists);
    await waitFor(tester, find.byType(CheckboxListTile));
    for (final list in pregnancyChecklists) {
      if (list.id == 'bag') continue;
      await scrollTo(tester, find.text(list.title));
      await tap(tester, find.text(list.title));
    }
    all = await pageTexts(tester);
    for (final there in [
      'Vorsorgeunterlagen der Schwangerschaft, Versicherungskarte, Ausweis',
      'Familienleistungen prüfen und beantragen',
      'Ersten Termin beim Kinderarzt vereinbaren',
    ]) {
      expect(all, contains(there), reason: there);
    }
    for (final gone in [
      'Mutterpass, Versichertenkarte, Personalausweis',
      'Kindergeld bei der Familienkasse beantragen',
      'Elterngeld beantragen (rückwirkend nur 3 Monate)',
      'Termin für die U2 (3.–10. Lebenstag)',
    ]) {
      expect(all, isNot(contains(gone)), reason: gone);
    }
    // No reminder of maternity protection; in Germany there is one.
    List<String> keys() {
      final now = DateTime.now();
      return [
        for (final r in familyReminders(
          state.engine!,
          from: now,
          to: now.add(const Duration(days: 200)),
        ))
          if (r.key.startsWith('preg:$id:')) r.key,
      ];
    }

    expect(keys(), isNot(contains('preg:$id:leave')));
    familyCountry = FamilyCountry.de;
    final german = keys();
    familyCountry = FamilyCountry.at;
    expect(german, contains('preg:$id:leave'), reason: 'control: Germany');
    await finish(tester, state);
  });

  // =========================================================================
  // Emergency numbers and fever hints
  // =========================================================================

  testWidgets(
    'KIN-150 KIN-153 Austria: emergency numbers, also offline; fever hints',
    (tester) async {
      final f = await theFamily();
      final older = await seedChild('E2E Notfall AT', born(years: 3));
      final baby = await seedChild('E2E Fieberbaby AT', born(days: 42));
      await seed(f.admin, Collections.memberEmergency, {
        f.adminMember.id: MemberEmergency(
          memberId: f.adminMember.id,
          info: const EmergencyInfo(allergies: 'E2E Pollen'),
        ).toData(),
      });
      await country('AT', 'AT-9');
      var state = await start(tester);
      await countryIs(tester, FamilyCountry.at);
      await arrives(
        tester,
        state,
        (e) => e.child(older) != null && e.child(baby) != null,
        'children',
      );
      final austrian = [
        '144 – ${de.emergencyRescue}',
        de.emergencyRescueNote,
        de.emergencyHealthLineAt,
        de.emergencyHealthLineAtNote,
        de.emergencyDoctorsAt,
        de.emergencyDoctorsAtNote,
        de.emergencyPoisonAt,
        de.emergencyPoisonAtNote,
      ];
      final german = [
        '112 – ${de.kidsEmergency}',
        de.kidsOutHoursMedicalService,
        de.kids116117WhenPractice,
        de.kidsPoisonControl,
        de.kids03019240ReachableNationwide,
      ];

      Future<void> numbers(String where) async {
        final all = await pageTexts(tester);
        for (final t in austrian) {
          expect(all, contains(t), reason: '$where: $t');
        }
        for (final t in german) {
          expect(all, isNot(contains(t)), reason: '$where: $t');
        }
        await scrollTo(tester, find.text(austrian.first), up: true);
        final first = find
            .ancestor(
              of: find.text(austrian.first),
              matching: find.byType(SoftCard),
            )
            .first;
        expect(
          tester.widget<SoftCard>(first).color,
          Theme.of(tester.element(first)).colorScheme.error,
          reason: '$where: the large red card',
        );
      }

      Future<void> both() async {
        await openChild(tester, 'E2E Notfall AT');
        await tap(tester, find.byTooltip(de.kidsEmergencyTitle));
        await waitFor(
          tester,
          find.text(de.kidsEmergencyName('E2E Notfall AT')),
        );
        await numbers('child');
        await back(tester);
        await openSection(tester, 'Einstellungen');
        await scrollTo(tester, find.text(de.memberEmergencyMine));
        await tap(tester, find.text(de.memberEmergencyMine));
        await waitFor(tester, find.text('E2E Pollen'));
        await numbers('my emergency information');
        await back(tester);
      }

      await both();

      // KIN-153: fever hints with the numbers of Austria.
      final warnings = de.healthCall112RightAway;
      await openChild(tester, 'E2E Fieberbaby AT');
      await typeTemperature(tester, '38,2');
      final babyText = de.healthBabiesUnder3MonthsAt(warnings);
      expect(adviceText(tester, FeverLevel.urgent), babyText);
      await dialog(tester, de.kidsLogPleaseGetMedicalHelp, babyText);
      await openChild(tester, 'E2E Notfall AT');
      await tab(tester, de.kidsTabLog);
      final texts = <String>[babyText];
      for (final (value, level, title, text) in [
        (
          '40,1',
          FeverLevel.doctor,
          de.kidsLogContactPediatrician,
          de.healthHighFeverContactPediatricianAt(warnings),
        ),
        (
          '41,2',
          FeverLevel.urgent,
          de.kidsLogPleaseGetMedicalHelp,
          de.healthVeryHighFeverGetAt(warnings),
        ),
        (
          '34,5',
          FeverLevel.doctor,
          de.kidsLogContactPediatrician,
          de.healthVeryLowTemperatureAt(warnings),
        ),
      ]) {
        await typeTemperature(tester, value);
        expect(adviceText(tester, level), text, reason: value);
        await dialog(tester, title, text);
        texts.add(text);
      }
      expect(texts.where((t) => t.contains('116 117')), isEmpty);
      expect(texts[1], contains('1450'));
      expect(texts[2], contains('141'));
      expect(texts[3], contains('(1450, bei Warnzeichen 144)'));

      // KIN-150: without a connection, opened again.
      await tester.pumpWidget(const SizedBox());
      final first = state.engine!;
      state.engine = null;
      await first.dispose();
      first.store.close();
      state.files?.close();
      state.files = null;
      HttpOverrides.global = _NoNetwork();
      addTearDown(() => HttpOverrides.global = null);
      familyCountry = FamilyCountry.de;
      state = AppState();
      await state.init();
      addTearDown(() async {
        if (state.me != null) await state.signOut();
      });
      await tester.pumpWidget(FamioApp(state: state));
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      expect(familyCountry, FamilyCountry.at, reason: 'kept on the device');
      await expectLater(state.engine!.api.me(), throwsA(isA<Object>()));
      await both();
      HttpOverrides.global = null;
      await finish(tester, state);
    },
  );

  testWidgets('KIN-151 KIN-154 Switzerland: emergency numbers; fever hints', (
    tester,
  ) async {
    final launcher = FakeLauncher();
    final before = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = before);
    final older = await seedChild('E2E Notfall CH', born(years: 3));
    final baby = await seedChild('E2E Fieberbaby CH', born(days: 42));
    await country('CH');
    final state = await start(tester);
    await countryIs(tester, FamilyCountry.ch);
    await arrives(
      tester,
      state,
      (e) => e.child(older) != null && e.child(baby) != null,
      'children',
    );
    await openChild(tester, 'E2E Notfall CH');
    await tap(tester, find.byTooltip(de.kidsEmergencyTitle));
    await waitFor(tester, find.text(de.kidsEmergencyName('E2E Notfall CH')));
    final all = await pageTexts(tester);
    for (final t in [
      '144 – ${de.emergencyRescue}',
      'Tox Info Suisse',
      de.emergencyPoisonChNote,
      de.emergencyDoctorsCh,
      de.emergencyDoctorsChNote,
    ]) {
      expect(all, contains(t), reason: t);
    }
    for (final t in [
      '112 – ${de.kidsEmergency}',
      de.kids116117WhenPractice,
      de.emergencyHealthLineAt,
    ]) {
      expect(all, isNot(contains(t)), reason: t);
    }
    final doctors = find
        .ancestor(
          of: find.text(de.emergencyDoctorsCh),
          matching: find.byType(SoftCard),
        )
        .first;
    await scrollTo(tester, doctors);
    expect(tester.widget<SoftCard>(doctors).onTap, isNull);
    expect(
      find.descendant(of: doctors, matching: find.byIcon(AppIcons.info)),
      findsOneWidget,
    );
    await tester.tap(doctors, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    expect(launcher.opened, isEmpty, reason: 'nothing is called');
    final rescue = find
        .ancestor(
          of: find.text('144 – ${de.emergencyRescue}'),
          matching: find.byType(SoftCard),
        )
        .first;
    await scrollTo(tester, rescue, up: true);
    await tester.tap(rescue, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    expect(launcher.opened, ['tel:144'], reason: 'control: 144 is called');
    await back(tester);

    // KIN-154
    final warnings = de.healthCall112RightAway;
    await openChild(tester, 'E2E Fieberbaby CH');
    await typeTemperature(tester, '38,2');
    final texts = [adviceText(tester, FeverLevel.urgent)];
    expect(texts.first, de.healthBabiesUnder3MonthsCh(warnings));
    await dialog(tester, de.kidsLogPleaseGetMedicalHelp, texts.first);
    await openChild(tester, 'E2E Notfall CH');
    await tab(tester, de.kidsTabLog);
    for (final (value, level, title, text) in [
      (
        '40,1',
        FeverLevel.doctor,
        de.kidsLogContactPediatrician,
        de.healthHighFeverContactPediatricianCh(warnings),
      ),
      (
        '41,2',
        FeverLevel.urgent,
        de.kidsLogPleaseGetMedicalHelp,
        de.healthVeryHighFeverGetCh(warnings),
      ),
      (
        '34,5',
        FeverLevel.doctor,
        de.kidsLogContactPediatrician,
        de.healthVeryLowTemperatureCh(warnings),
      ),
    ]) {
      await typeTemperature(tester, value);
      expect(adviceText(tester, level), text, reason: value);
      await dialog(tester, title, text);
      texts.add(text);
    }
    for (final t in texts) {
      expect(t, isNot(contains('116 117')));
      expect(t, isNot(contains('1450')));
      expect(t, contains('Notfalldienst des Kantons'));
    }
    await finish(tester, state);
  });

  testWidgets('KIN-155 the hint of the medication plan by country', (
    tester,
  ) async {
    final f = await theFamily();
    addTearDown(
      () => f.admin.updateServerSettings({
        'country': 'DE',
        'holidayRegion': null,
      }),
    );
    for (final (code, c, text) in [
      ('DE', FamilyCountry.de, de.medsFamioOnlyRemindsYou),
      ('AT', FamilyCountry.at, de.medsFamioOnlyRemindsYouAt),
      ('CH', FamilyCountry.ch, de.medsFamioOnlyRemindsYouCh),
    ]) {
      await f.admin.updateServerSettings({
        'country': code,
        'holidayRegion': null,
      });
      final state = await start(tester);
      await countryIs(tester, c);
      await openSection(tester, 'Medizin');
      await waitFor(tester, find.text(text));
      expect(
        find.textContaining(code == 'DE' ? '116 117' : '144'),
        findsWidgets,
      );
      await finish(tester, state);
    }
  });

  // =========================================================================
  // Undo after resetting and deleting (changed entries)
  // =========================================================================

  testWidgets('KIN-164 KIN-021 KIN-048 reset and delete offer undo', (
    tester,
  ) async {
    final f = await theFamily();
    final id = await seedChild('E2E Rückgängig', born(days: 50));
    final photo = await f.admin.uploadFile(
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
        'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ),
      name: 'e2e-u3.png',
      mime: 'image/png',
    );
    final u3Date = inDays(-10);
    await seedEntries([
      entry(
        id,
        ChildEntryKind.checkup,
        u3Date,
        refId: 'U3',
        heightCm: 54,
        weightKg: 4.4,
        photos: [photo],
      ),
      entry(id, ChildEntryKind.vaccination, inDays(-1), refId: 'rota_1'),
      entry(id, ChildEntryKind.milestone, inDays(-2), refId: 'smile'),
      entry(
        id,
        ChildEntryKind.measurement,
        inDays(-3),
        heightCm: 56,
        weightKg: 4.6,
      ),
    ]);
    final state = await start(tester);
    await countryIs(tester, FamilyCountry.de);
    final engine = state.engine!;
    await arrives(tester, state, (e) => e.childEntries(id).length == 4, 'seed');
    ChildEntry? byRef(String ref) =>
        engine.childEntries(id).where((e) => e.refId == ref).firstOrNull;
    await openChild(tester, 'E2E Rückgängig');

    // KIN-164: the U3 reset and brought back.
    await tab(tester, de.kidsTabCheckups);
    await expectStatus(tester, 'U3', de.commonDoneLower);
    await scrollTo(tester, find.text('U3'));
    await tap(tester, cardOf('U3'));
    await waitFor(tester, inSheet(find.text(de.commonReset)));
    await tap(tester, inSheet(find.text(de.commonReset)));
    await waitFor(tester, snackText(de.kidsEntryWhatReset('U3')));
    expect(byRef('U3'), isNull);
    await undo(tester);
    await until(tester, () => byRef('U3') != null, 'U3 back');
    final u3 = byRef('U3')!;
    expect(u3.date, u3Date);
    expect(u3.heightCm, 54);
    expect(u3.weightKg, 4.4);
    expect(u3.photos.map((p) => p.id), [photo.id]);
    await snackGone(tester);
    await expectStatus(tester, 'U3', de.commonDoneLower);
    // The vaccination reset, the message left alone: open again.
    await tab(tester, de.kidsTabVaccinations);
    const rota = 'Rotaviren – 1. Dosis';
    await expectStatus(tester, rota, de.commonDoneLower);
    await tap(tester, cardOf(rota));
    await waitFor(tester, inSheet(find.text(de.commonReset)));
    await tap(tester, inSheet(find.text(de.commonReset)));
    await waitFor(tester, snackWith('zurückgesetzt'));
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(de.commonUndo),
      ),
      findsOneWidget,
    );
    await snackGone(tester);
    expect(byRef('rota_1'), isNull);
    await scrollTo(tester, find.text(rota));
    expect(
      tester.widget<RoundCheck>(inCard(rota, find.byType(RoundCheck))).value,
      isFalse,
    );
    await engine.sync();
    expect(
      (await pull(f.admin, Collections.childEntries)).values.where(
        (r) => r.data['childId'] == id && r.data['refId'] == 'rota_1',
      ),
      isEmpty,
    );

    // KIN-021: a milestone reset offers undo as well.
    final smile = milestoneById('smile')!.title;
    await tab(tester, de.kidsTabMilestones);
    await scrollTo(tester, find.text(smile));
    await tap(tester, find.text(smile));
    await waitFor(tester, inSheet(find.text(de.commonReset)));
    await tap(tester, inSheet(find.text(de.commonReset)));
    await waitFor(tester, snackText(de.kidsEntryWhatReset(smile)));
    expect(byRef('smile'), isNull);
    await undo(tester);
    await until(tester, () => byRef('smile') != null, 'milestone back');
    await snackGone(tester);

    // KIN-048: a measurement deleted offers undo.
    await tab(tester, de.kidsTabGrowth);
    final tile = find.widgetWithText(ListTile, '56 cm · 4,6 kg');
    await scrollTo(tester, tile);
    await tap(tester, tile);
    await waitFor(tester, inSheet(find.text(de.commonDelete)));
    await tap(tester, inSheet(find.text(de.commonDelete)));
    await waitGone(tester, sheet());
    await waitFor(
      tester,
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(de.commonUndo),
      ),
    );
    expect(
      engine
          .childEntries(id)
          .where((e) => e.kind == ChildEntryKind.measurement),
      isEmpty,
    );
    await undo(tester);
    await until(
      tester,
      () => engine
          .childEntries(id)
          .any((e) => e.kind == ChildEntryKind.measurement),
      'measurement back',
    );
    await scrollTo(tester, tile);
    await finish(tester, state);
  });

  // =========================================================================
  // The chip of the child card and the shopping list (changed entries)
  // =========================================================================

  testWidgets('KIN-035 the chip names the next check-up from its date', (
    tester,
  ) async {
    final id = await seedChild('E2E Später dran', born(days: 140));
    final state = await start(tester);
    await countryIs(tester, FamilyCountry.de);
    final engine = state.engine!;
    await arrives(tester, state, (e) => e.child(id) != null, 'child');
    final child = engine.child(id)!;
    // Everything open now is done (date unknown, as recorded afterwards).
    final done = <ChildEntry>[];
    for (var round = 0; round < 6; round++) {
      final open = [
        ...checkupPlan(child, done),
        ...vaccinationPlan(child, done),
      ].where((d) => d.open && !d.optional).toList();
      if (open.isEmpty) break;
      for (final d in open) {
        done.add(
          ChildEntry(
            id: uid('entry'),
            childId: id,
            kind: d.isCheckup
                ? ChildEntryKind.checkup
                : ChildEntryKind.vaccination,
            date: today(),
            refId: d.id,
            dateUnknown: !d.isCheckup ? false : true,
          ),
        );
      }
    }
    await seedEntries(done);
    await arrives(
      tester,
      state,
      (e) => e.childEntries(id).length == done.length,
      'entries',
    );
    final next = nextDue(child, engine.childEntries(id))!;
    debugPrint('E2E-INFO next: ${next.id} ${next.state} from ${next.from}');
    expect(next.open, isFalse);
    expect(next.appointment, isNull);
    final chip = next.isCheckup
        ? de.kidsWhatFrom(next.id, md(next.from))
        : de.kidsWhatFrom(de.commonVaccination, md(next.from));
    await kidsList(tester);
    await inKidsList(tester, find.text('E2E Später dran'));
    expect(
      find.descendant(of: cardOf('E2E Später dran'), matching: find.text(chip)),
      findsOneWidget,
      reason: 'chip "$chip"',
    );
    expect(
      find.descendant(
        of: cardOf('E2E Später dran'),
        matching: find.textContaining('_'),
      ),
      findsNothing,
      reason: 'no internal id',
    );
    await finish(tester, state);
  });

  testWidgets('KIN-103 which shopping list the medicine goes on', (
    tester,
  ) async {
    final f = await theFamily();
    final medId = uid('med');
    await seed(f.admin, Collections.medications, {
      medId: Medication(
        id: medId,
        name: 'E2E Hustensaft',
        times: const ['08:00', '20:00'],
        start: today(),
        careIds: [f.adminMember.id, f.bea.id],
        stock: 3,
        stockAt: DateTime.now(),
      ).toData(),
    });
    final admin = f.adminMember.id, bea = f.bea.id, carl = f.carl.id;
    final lists = {
      'E2E Packliste': (uid('list'), [admin, bea], true),
      'E2E Nur ich': (uid('list'), [admin], false),
      'E2E Mit Carl': (uid('list'), [admin, carl], false),
      'E2E Alle': (uid('list'), null, false),
      'E2E Eltern': (uid('list'), [admin, bea], false),
    };
    await seed(f.admin, Collections.shoppingLists, {
      for (final MapEntry(key: name, value: (id, who, packing))
          in lists.entries)
        id: {
          ...ShoppingList(id: id, name: name, packing: packing).toData(),
          SyncRecord.visibilityKey: ?who,
        },
    });
    final state = await start(tester);
    final engine = state.engine!;
    await arrives(
      tester,
      state,
      (e) => e.shoppingLists.length >= lists.length && e.medications.isNotEmpty,
      'lists and plan',
    );
    final card = find.ancestor(
      of: find.text('E2E Hustensaft'),
      matching: find.byWidgetPredicate((w) => w is SoftCard && w.onTap != null),
    );
    final buy = find.descendant(of: card, matching: find.text(de.medsBuyMore));
    Future<void> buyMore() async {
      await openSection(tester, 'Medizin');
      await scrollTo(tester, buy);
      await tap(tester, buy);
    }

    // A list of some that reaches all who care for the plan comes first.
    await buyMore();
    await waitFor(tester, find.text(de.medsList('E2E Eltern')));
    expect(
      engine.shoppingItems(lists['E2E Eltern']!.$1).map((i) => i.name),
      contains(de.medsPharmacyItem('E2E Hustensaft')),
    );
    await snackGone(tester);
    // Without it, the family's list.
    await remove(f.admin, Collections.shoppingLists, [lists['E2E Eltern']!.$1]);
    await arrives(
      tester,
      state,
      (e) => e.shoppingLists.every((l) => l.name != 'E2E Eltern'),
      'list gone',
    );
    await buyMore();
    await waitFor(tester, find.text(de.medsList('E2E Alle')));
    await snackGone(tester);
    // Without that, the member chooses; the packing list is no choice.
    await remove(f.admin, Collections.shoppingLists, [lists['E2E Alle']!.$1]);
    await arrives(
      tester,
      state,
      (e) => e.shoppingLists.every((l) => l.name != 'E2E Alle'),
      'list gone',
    );
    await buyMore();
    await waitFor(tester, find.text(de.commonWhichList));
    final options = find.descendant(
      of: find.byType(SimpleDialog),
      matching: find.byType(Text),
    );
    final names = {for (final e in options.evaluate()) (e.widget as Text).data};
    expect(names, containsAll(['E2E Nur ich', 'E2E Mit Carl']));
    expect(names, isNot(contains('E2E Packliste')));
    await tap(
      tester,
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('E2E Mit Carl'),
      ),
    );
    await waitFor(tester, find.text(de.medsList('E2E Mit Carl')));
    expect(
      engine.shoppingItems(lists['E2E Packliste']!.$1).map((i) => i.name),
      isEmpty,
    );
    await finish(tester, state);
  });
}
