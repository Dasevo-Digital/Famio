// What the areas children, health and pregnancy offer, and how they say it:
// deleting with "Rückgängig" or after asking, nothing a child account may
// not do, the chart, the log's fields and the plan editor (#539, #544).
import 'dart:async';
import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/health_logic.dart';
import 'package:famio/src/data/kids_logic.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/kids_log_screens.dart';
import 'package:famio/src/screens/kids_screens.dart';
import 'package:famio/src/screens/medication_screens.dart';
import 'package:famio/src/screens/pregnancy_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const mama = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
const papa = FamilyMember(id: 'm2', username: 'papa', displayName: 'Papa');
const kid = FamilyMember(
  id: 'k1',
  username: 'lina',
  displayName: 'Lina',
  role: MemberRole.child,
);

DateTime get today => DateUtils.dateOnly(DateTime.now());
DateTime inDays(int days) => DateUtils.addDaysToDate(today, days);

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
    await initializeDateFormatting('en');
  });

  late SyncEngine engine;
  late BuildContext page;

  /// The app for [me]; [seed] writes what an adult (Mama) entered before,
  /// on the same device store. Then a blank page to open sheets from.
  Future<void> boot(
    WidgetTester tester, {
    FamilyMember me = mama,
    String language = 'de',
    Size size = const Size(1200, 2400),
    void Function(SyncEngine mama)? seed,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => useLanguage('de'));
    SharedPreferences.setMockInitialValues({
      if (language != 'de') 'language': language,
    });
    FlutterSecureStorage.setMockInitialValues({});
    final store = LocalStore.open(':memory:')
      ..setMeta(
        'members',
        jsonEncode([
          for (final m in [mama, papa, kid]) m.toJson(),
        ]),
      );
    seed?.call(
      SyncEngine(
        store: store,
        api: FamioApiClient('localhost:1'),
        memberId: mama.id,
      ),
    );
    engine = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    final state = AppState();
    await state.init();
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
  }

  /// Opens [screen] over the app (a blank page when null) and keeps its
  /// context in [page].
  Future<void> open(WidgetTester tester, [Widget? screen]) async {
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                screen ??
                Scaffold(
                  body: Builder(
                    builder: (context) {
                      page = context;
                      return const SizedBox.expand();
                    },
                  ),
                ),
          ),
        );
    await tester.pumpAndSettle();
  }

  /// Lets the sync debounce and timers of the page run out.
  Future<void> done(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  final baby = Child(
    id: 'c1',
    name: 'Emil',
    birthDate: DateUtils.addDaysToDate(
      DateUtils.dateOnly(DateTime.now()),
      -150,
    ),
  );

  group('a memory', () {
    final memory = ChildEntry(
      id: 'e1',
      childId: 'c1',
      kind: ChildEntryKind.memory,
      date: DateUtils.dateOnly(DateTime.now()),
      title: 'Erster Zahn',
    );

    testWidgets('KIN-016 deleted with "Rückgängig"', (tester) async {
      await boot(tester);
      engine
        ..saveChild(baby)
        ..saveChildEntry(memory);
      await open(tester);
      unawaited(
        showEntryEditor(
          page,
          child: baby,
          kind: ChildEntryKind.memory,
          existing: memory,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.commonDelete));
      await tester.pumpAndSettle();
      expect(engine.childEntries('c1'), isEmpty);
      final undo = find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(tr.commonUndo),
      );
      expect(undo, findsOneWidget);
      expect(find.text(tr.undoWhatDeleted('Erster Zahn')), findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(engine.childEntries('c1').single.title, 'Erster Zahn');
      await done(tester);
    });

    testWidgets('#539 a child may not change what an adult entered', (
      tester,
    ) async {
      await boot(
        tester,
        me: kid,
        seed: (mama) => mama
          ..saveChild(baby)
          ..saveChildEntry(memory),
      );
      engine.saveChildEntry(
        ChildEntry(
          id: 'e2',
          childId: 'c1',
          kind: ChildEntryKind.memory,
          date: today,
          title: 'Mein Eintrag',
        ),
      );
      await open(tester);
      unawaited(
        showEntryEditor(
          page,
          child: baby,
          kind: ChildEntryKind.memory,
          existing: memory,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(tr.kidsOnlyAuthorOrAdult), findsOneWidget);
      expect(find.text(tr.commonDelete), findsNothing);
      expect(find.text(tr.commonSave), findsNothing);
      Navigator.of(page).pop();
      await tester.pumpAndSettle();

      // What the child wrote itself it may change.
      unawaited(
        showEntryEditor(
          page,
          child: baby,
          kind: ChildEntryKind.memory,
          existing: engine.childEntries('c1').firstWhere((e) => e.id == 'e2'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(tr.kidsOnlyAuthorOrAdult), findsNothing);
      expect(find.text(tr.commonDelete), findsOneWidget);
      await done(tester);
    });
  });

  testWidgets('#539 an appointment someone else booked: the child sees it', (
    tester,
  ) async {
    final born = inDays(-60);
    final child = Child(id: 'c1', name: 'Emil', birthDate: born);
    final booked = ChildEntry(
      id: 'a1',
      childId: 'c1',
      kind: ChildEntryKind.checkup,
      date: inDays(7),
      refId: 'U4',
      planned: true,
    );
    await boot(
      tester,
      me: kid,
      seed: (mama) => mama
        ..saveChild(child)
        ..saveChildEntry(booked),
    );
    await open(tester);
    final item = checkupPlan(
      child,
      engine.childEntries('c1'),
    ).singleWhere((d) => d.id == 'U4');
    expect(item.appointment, isNotNull);
    unawaited(showDueActions(page, child, item));
    await tester.pumpAndSettle();
    expect(find.text(tr.dueCancelAppointment), findsNothing);
    expect(find.text(tr.kidsOnlyAuthorOrAdult), findsOneWidget);
    await done(tester);
  });

  testWidgets('KIN-029 the due sheet scrolls in a small window', (
    tester,
  ) async {
    await boot(tester, size: const Size(800, 460));
    final child = Child(id: 'c1', name: 'Emil', birthDate: inDays(-28));
    engine.saveChild(child);
    await open(tester);
    final rota = vaccinationPlan(
      child,
      const [],
    ).firstWhere((d) => d.id == 'rota_1');
    unawaited(showDueActions(page, child, rota));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final last = find.text(tr.dueDoneDateUnknown2);
    await tester.scrollUntilVisible(
      last,
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(engine.childEntries('c1').single.dateUnknown, isTrue);
    await done(tester);
  });

  group('the card of a child', () {
    testWidgets('KIN-035 a booked vaccination: what and when', (tester) async {
      await boot(tester);
      final child = Child(id: 'c1', name: 'Emil', birthDate: inDays(-28));
      final date = inDays(14);
      engine
        ..saveChild(child)
        ..saveChildEntry(
          ChildEntry(
            id: 'a1',
            childId: 'c1',
            kind: ChildEntryKind.vaccination,
            date: date,
            refId: 'rota_1',
            planned: true,
          ),
        );
      await open(tester, const KidsScreen());
      expect(find.textContaining('rota_1'), findsNothing);
      expect(
        find.text(
          tr.homeWhatDate(
            tr.commonVaccination,
            DateFormat.Md('de').format(date),
          ),
        ),
        findsOneWidget,
      );
      await done(tester);
    });

    test('KIN-035 a later check-up in English', () {
      useLanguage('en');
      addTearDown(() => useLanguage('de'));
      final from = inDays(30);
      final next = DueItem(
        id: 'U4',
        title: 'U4 – …',
        subtitle: '',
        from: from,
        to: inDays(60),
        state: DueState.upcoming,
      );
      expect(dueLater(next), 'U4 from ${DateFormat.Md('en').format(from)}');
    });

    testWidgets('KIN-134 a child account adds no children', (tester) async {
      await boot(tester, me: kid);
      // The start page does not ask it to add one.
      expect(find.text(tr.homeAddChildKeepTrack), findsNothing);
      expect(find.text(tr.kidsNoneYet), findsOneWidget);
      await open(tester, const KidsScreen());
      expect(find.text(tr.commonAdd), findsNothing);
      expect(find.byTooltip(tr.kidsAddChildPregnancy), findsNothing);
      expect(find.textContaining(tr.kidsNoneYet), findsOneWidget);
      await done(tester);
    });

    testWidgets('KIN-011 the question before removing, in English', (
      tester,
    ) async {
      await boot(tester, language: 'en');
      final child = Child(id: 'c1', name: 'Emil', birthDate: inDays(-28));
      engine.saveChild(child);
      await open(tester);
      unawaited(showChildEditor(page, existing: child));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(tr.kidsRemoveChild),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text(tr.kidsRemoveChild));
      await tester.pumpAndSettle();
      expect(find.text('Remove Emil?'), findsOneWidget);
      await tester.tap(find.text(tr.commonCancel));
      await tester.pumpAndSettle();
      await done(tester);
    });
  });

  testWidgets('KIN-018 the time of an appointment in the timeline', (
    tester,
  ) async {
    await boot(tester);
    engine
      ..saveChild(Child(id: 'c1', name: 'Emil', birthDate: inDays(-65)))
      ..saveChildEntry(
        ChildEntry(
          id: 'a1',
          childId: 'c1',
          kind: ChildEntryKind.checkup,
          date: inDays(21),
          refId: 'U5',
          planned: true,
          time: '09:30',
        ),
      );
    await open(tester, const ChildScreen(childId: 'c1'));
    await tester.tap(find.text(tr.kidsTabTimeline));
    await tester.pumpAndSettle();
    final row = find.textContaining('um 09:30 Uhr · Termin');
    expect(row, findsOneWidget);
    final text = tester.widget<Text>(row).data!;
    expect(text, isNot(contains('  ')), reason: text);
    expect(text, startsWith(DateFormat.yMMMd('de').format(inDays(21))));
    await done(tester);
  });

  group('the log', () {
    final emil = Child(
      id: 'c1',
      name: 'Emil',
      birthDate: DateUtils.addDaysToDate(
        DateUtils.dateOnly(DateTime.now()),
        -90,
      ),
    );

    Finder chart() => find.byWidgetPredicate(
      (w) =>
          w is CustomPaint && w.painter.runtimeType.toString() == '_BarPainter',
    );

    Future<void> series(WidgetTester tester, String from, String to) async {
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w.runtimeType.toString().startsWith('DropdownButton<') &&
              find
                  .descendant(of: find.byWidget(w), matching: find.text(from))
                  .evaluate()
                  .isNotEmpty,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(to).last);
      await tester.pumpAndSettle();
    }

    testWidgets('KIN-074 KIN-084 diapers once, low temperatures drawn', (
      tester,
    ) async {
      await boot(tester, size: const Size(1200, 4000));
      final now = DateTime.now();
      final at = now.hour == 0
          ? now
          : now.subtract(const Duration(minutes: 30));
      engine
        ..saveChild(emil)
        ..saveChildLog(
          ChildLog(
            id: 'l1',
            childId: 'c1',
            kind: LogKind.diaper,
            start: at,
            diaper: DiaperKind.both,
            by: mama.id,
          ),
        )
        ..saveChildLog(
          ChildLog(
            id: 'l2',
            childId: 'c1',
            kind: LogKind.temperature,
            start: at,
            temperatureC: 35.2,
            by: mama.id,
          ),
        );
      // The day totals keep counting pee and poo apart.
      final day = summarize(engine.childLogs('c1'), now);
      expect((day.wet, day.dirty, day.diapers), (1, 1, 1));
      await open(
        tester,
        Scaffold(
          body: ChildLogView(child: emil, logs: engine.childLogs('c1')),
        ),
      );
      await series(tester, tr.kidsLogMeals, tr.kidsLogDiapers);
      final diapers = tester.widget<CustomPaint>(chart()).painter as dynamic;
      expect((diapers.values as List<double>).last, 1.0);

      await series(tester, tr.kidsLogDiapers, tr.kidsLogTemperature);
      final temps = tester.widget<CustomPaint>(chart()).painter as dynamic;
      final v = (temps.values as List<double>).last;
      expect(v, 35.2);
      expect(temps.baseline as double, lessThan(35.2));
      expect((temps.format as String Function(double))(v), '35,2');
      // No measurement still reads "–".
      expect((temps.values as List<double>).first, 0);
      await done(tester);
    });

    testWidgets('KIN-057 "120,5" ml is rounded, not dropped', (tester) async {
      await boot(tester);
      engine.saveChild(emil);
      await open(tester);
      unawaited(showLogEditor(page, child: emil, kind: LogKind.bottle));
      await tester.pumpAndSettle();
      final amount = find.widgetWithText(TextField, tr.kidsLogAmountMl);
      await tester.enterText(amount, 'viel');
      await tester.tap(find.text(tr.commonSave));
      await tester.pumpAndSettle();
      expect(find.text(tr.kidsLogAmountInvalid), findsOneWidget);
      expect(engine.childLogs('c1'), isEmpty);
      await tester.enterText(amount, '120,5');
      await tester.tap(find.text(tr.commonSave));
      await tester.pumpAndSettle();
      expect(engine.childLogs('c1').single.amountMl, 121);
      await done(tester);
    });

    testWidgets('KIN-057 KIN-075 KIN-085 the fields in English', (
      tester,
    ) async {
      await boot(tester, language: 'en');
      engine.saveChild(emil);
      await open(tester);
      Future<void> editor(LogKind kind) async {
        unawaited(showLogEditor(page, child: emil, kind: kind));
        await tester.pumpAndSettle();
      }

      Future<void> close() async {
        Navigator.of(page).pop();
        await tester.pumpAndSettle();
      }

      await editor(LogKind.bottle);
      expect(find.widgetWithText(TextField, 'Amount (ml)'), findsOneWidget);
      await close();
      await editor(LogKind.temperature);
      expect(
        find.widgetWithText(TextField, 'Temperature (°C)'),
        findsOneWidget,
      );
      await close();
      await editor(LogKind.medication);
      expect(
        find.widgetWithText(TextField, 'Minimum interval (h)'),
        findsOneWidget,
      );
      expect(find.text('e.g. fever syrup'), findsOneWidget);
      await close();
      await done(tester);
    });

    testWidgets('#539 a child does not stop what an adult started', (
      tester,
    ) async {
      final sleep = ChildLog(
        id: 'l2',
        childId: 'c1',
        kind: LogKind.sleep,
        start: DateTime.now().subtract(const Duration(minutes: 40)),
        by: mama.id,
      );
      await boot(
        tester,
        me: kid,
        seed: (mama) => mama
          ..saveChild(emil)
          ..saveChildLog(sleep),
      );
      await open(
        tester,
        Scaffold(
          body: ChildLogView(child: emil, logs: engine.childLogs('c1')),
        ),
      );
      // No stop on the running card …
      expect(find.text(tr.kidsLogStop), findsNothing);
      // … and "Aufgewacht" explains instead of ending Mama's entry.
      await tester.tap(find.text(tr.kidsLogWokeUp));
      await tester.pump();
      expect(find.text(tr.kidsOnlyAuthorOrAdult), findsOneWidget);
      expect(engine.childLogs('c1').single.end, isNull);
      await done(tester);
    });

    testWidgets('#539 a child may not change a log an adult wrote', (
      tester,
    ) async {
      final log = ChildLog(
        id: 'l1',
        childId: 'c1',
        kind: LogKind.bath,
        start: DateTime.now().subtract(const Duration(hours: 1)),
        by: mama.id,
      );
      await boot(
        tester,
        me: kid,
        seed: (mama) => mama
          ..saveChild(emil)
          ..saveChildLog(log),
      );
      await open(tester);
      unawaited(
        showLogEditor(page, child: emil, kind: LogKind.bath, existing: log),
      );
      await tester.pumpAndSettle();
      expect(find.text(tr.kidsOnlyAuthorOrAdult), findsOneWidget);
      expect(find.text(tr.commonDelete), findsNothing);
      await done(tester);
    });
  });

  group('the pregnancy', () {
    final pregnancy = Pregnancy(
      id: 'p1',
      name: 'Bauchzwerg',
      dueDate: DateUtils.addDaysToDate(DateUtils.dateOnly(DateTime.now()), 14),
      guardianIds: const ['m1', 'k1'],
      contractions: [
        Contraction(
          DateTime.now().subtract(const Duration(minutes: 30)),
          DateTime.now().subtract(const Duration(minutes: 29)),
        ),
        Contraction(
          DateTime.now().subtract(const Duration(minutes: 20)),
          DateTime.now().subtract(const Duration(minutes: 19)),
        ),
      ],
    );

    testWidgets('KIN-125 clearing the contractions asks first', (tester) async {
      await boot(tester);
      engine.savePregnancy(pregnancy);
      await open(tester, const PregnancyScreen(pregnancyId: 'p1'));
      final clear = find.text(tr.pregnancyClearHistory);
      await tester.scrollUntilVisible(
        clear,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.text(tr.pregnancyClearHistoryQuestion), findsOneWidget);
      await tester.tap(find.text(tr.commonCancel));
      await tester.pumpAndSettle();
      expect(engine.pregnancy('p1')!.contractions, hasLength(2));
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(tr.pregnancyClearHistory),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.pregnancy('p1')!.contractions, isEmpty);
      await done(tester);
    });

    testWidgets('KIN-140 a child account only reads it', (tester) async {
      await boot(
        tester,
        me: kid,
        seed: (mama) => mama.savePregnancy(pregnancy),
      );
      await open(tester, const PregnancyScreen(pregnancyId: 'p1'));
      // Contractions: no timer, no clearing.
      expect(find.text(tr.pregnancyContractionStarts), findsNothing);
      expect(find.text(tr.pregnancyClearHistory), findsNothing);
      expect(find.text(tr.pregnancyAdultsEnter), findsOneWidget);
      await tester.tap(find.text(tr.pregnancyChecklists));
      await tester.pumpAndSettle();
      final boxes = find.byType(CheckboxListTile);
      expect(boxes, findsWidgets);
      for (final e in boxes.evaluate()) {
        expect((e.widget as CheckboxListTile).onChanged, isNull);
      }
      await tester.tap(find.text(tr.commonEvents));
      await tester.pumpAndSettle();
      final checks = find.byType(RoundCheck);
      expect(checks, findsWidgets);
      for (final e in checks.evaluate()) {
        expect((e.widget as RoundCheck).onChanged, isNull);
      }
      await tester.tap(find.text(tr.commonWeek));
      await tester.pumpAndSettle();
      expect(find.text(tr.pregnancyBabyHere), findsNothing);
      await done(tester);
    });

    testWidgets('adults still tick, time and welcome the baby', (tester) async {
      await boot(tester);
      engine.savePregnancy(pregnancy);
      await open(tester, const PregnancyScreen(pregnancyId: 'p1'));
      expect(find.text(tr.pregnancyContractionStarts), findsOneWidget);
      await tester.tap(find.text(tr.commonWeek));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(tr.pregnancyBabyHere),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await done(tester);
    });
  });

  group('medication plans', () {
    testWidgets('KIN-096 in a small window the editor shows the message', (
      tester,
    ) async {
      await boot(tester, size: const Size(800, 420));
      await open(tester);
      unawaited(showMedicationEditor(page));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, tr.kidsLogMedication),
        'Fiebersaft',
      );
      await tester.tap(find.byTooltip(tr.commonSave));
      await tester.pumpAndSettle();
      // Below the fold at first: the editor scrolls to it.
      expect(find.text(tr.medsTimesMissing).hitTestable(), findsOneWidget);
      expect(engine.medications, isEmpty);
      await done(tester);
    });

    testWidgets('KIN-096 no name, no times, an end before the start', (
      tester,
    ) async {
      await boot(tester);
      await open(tester);
      unawaited(showMedicationEditor(page));
      await tester.pumpAndSettle();
      final save = find.byTooltip(tr.commonSave);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text(tr.kidsLogPleaseEnterMedication), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, tr.kidsLogMedication),
        'Fiebersaft',
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text(tr.medsTimesMissing), findsOneWidget);
      expect(engine.medications, isEmpty);
      Navigator.of(page).pop();
      await tester.pumpAndSettle();

      final backwards = Medication(
        id: 'x',
        name: 'Rückwärtssaft',
        times: const ['09:00'],
        start: today,
        end: inDays(-1),
        careIds: const ['m1'],
      );
      engine.saveMedication(backwards);
      unawaited(showMedicationEditor(page, medication: backwards));
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text(tr.commonEndBeforeStart), findsOneWidget);
      expect(save, findsOneWidget, reason: 'the editor stays open');
      await done(tester);
    });

    Medication low(List<String> care) => Medication(
      id: 'med',
      name: 'Saft',
      times: const ['09:00'],
      start: DateUtils.dateOnly(DateTime.now()),
      careIds: care,
      stock: 1,
      stockAt: DateTime.now(),
    );

    testWidgets('KIN-103 buying more: a list all who care see', (tester) async {
      await boot(tester);
      engine
        ..saveShoppingList(
          const ShoppingList(
            id: 'pack',
            name: 'Koffer',
            sort: -2,
            packing: true,
          ),
        )
        ..saveShoppingList(
          const ShoppingList(
            id: 'mine',
            name: 'Aaa Privat',
            sort: -1,
            visibleTo: ['m1'],
          ),
        )
        ..saveShoppingList(const ShoppingList(id: 'all', name: 'Zett'))
        ..saveMedication(low(const ['m1', 'm2']));
      await open(tester, const MedicationScreen());
      final buy = find.text(tr.medsBuyMore);
      await tester.scrollUntilVisible(
        buy,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(buy);
      await tester.pumpAndSettle();
      expect(engine.shoppingItems('all').single.name, 'Saft (Apotheke)');
      expect(engine.shoppingItems('mine'), isEmpty);
      expect(engine.shoppingItems('pack'), isEmpty);
      await done(tester);
    });

    testWidgets('KIN-103 a list kept to those who care comes first', (
      tester,
    ) async {
      await boot(tester);
      engine
        ..saveShoppingList(const ShoppingList(id: 'all', name: 'Aaa Familie'))
        ..saveShoppingList(
          const ShoppingList(
            id: 'care',
            name: 'Zett Eltern',
            visibleTo: ['m1', 'm2'],
          ),
        )
        ..saveMedication(low(const ['m1', 'm2']));
      await open(tester, const MedicationScreen());
      final buy = find.text(tr.medsBuyMore);
      await tester.scrollUntilVisible(
        buy,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(buy);
      await tester.pumpAndSettle();
      // A medicine stays off the family's list (guests, Home Assistant).
      expect(engine.shoppingItems('care').single.name, 'Saft (Apotheke)');
      expect(engine.shoppingItems('all'), isEmpty);
      await done(tester);
    });

    testWidgets('KIN-103 without such a list the member picks one', (
      tester,
    ) async {
      await boot(tester);
      engine
        ..saveShoppingList(
          const ShoppingList(id: 'a', name: 'Mama A', visibleTo: ['m1']),
        )
        ..saveShoppingList(
          const ShoppingList(id: 'b', name: 'Mama B', visibleTo: ['m1']),
        )
        ..saveMedication(low(const ['m1', 'm2']));
      await open(tester, const MedicationScreen());
      final buy = find.text(tr.medsBuyMore);
      await tester.scrollUntilVisible(
        buy,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(buy);
      await tester.pumpAndSettle();
      expect(find.text(tr.commonWhichList), findsOneWidget);
      await tester.tap(find.text('Mama B'));
      await tester.pumpAndSettle();
      expect(engine.shoppingItems('b'), hasLength(1));
      expect(engine.shoppingItems('a'), isEmpty);
      await done(tester);
    });

    testWidgets('KIN-097 KIN-103 the card in English', (tester) async {
      await boot(tester, language: 'en');
      engine
        ..saveShoppingList(const ShoppingList(id: 'all', name: 'List'))
        ..saveMedication(
          Medication(
            id: 'med',
            name: 'Syrup',
            times: const ['09:00'],
            start: today,
            end: inDays(8),
            careIds: const ['m1'],
            stock: 1,
            stockAt: DateTime.now(),
          ),
        );
      await open(tester, const MedicationScreen());
      expect(
        find.textContaining('until ${DateFormat.yMd('en').format(inDays(8))}'),
        findsOneWidget,
      );
      expect(find.textContaining('bis '), findsNothing);
      final buy = find.text(tr.medsBuyMore);
      await tester.scrollUntilVisible(
        buy,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(buy);
      await tester.pumpAndSettle();
      expect(engine.shoppingItems('all').single.name, 'Syrup (pharmacy)');
      await done(tester);
    });

    testWidgets('#539 a child takes back only its own intake', (tester) async {
      final plan = Medication(
        id: 'med',
        name: 'Saft',
        times: const ['00:00', '00:01'],
        start: inDays(-1),
        careIds: const ['m1', 'k1'],
      );
      await boot(
        tester,
        me: kid,
        seed: (mama) => mama
          ..saveMedication(plan)
          ..recordIntake(plan, scheduled: plan.dosesOn(today).first),
      );
      engine.recordIntake(plan, scheduled: plan.dosesOn(today).last);
      expect(engine.intakes('med'), hasLength(2));
      await open(tester, const MedicationScreen());
      // Two doses taken: only the child's own has "Rückgängig".
      expect(find.byTooltip(tr.commonUndo), findsOneWidget);
      await done(tester);
    });
  });
}
