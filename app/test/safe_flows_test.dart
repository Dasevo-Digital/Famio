import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/school_bag.dart';
import 'package:famio/src/data/week_plan.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/budget_screens.dart';
import 'package:famio/src/screens/sos_screens.dart';
import 'package:famio/src/screens/subscriptions_screen.dart';
import 'package:famio/src/screens/tasks_screen.dart';
import 'package:famio/src/sos/sos_controller.dart';
import 'package:famio/src/widgets/account_password.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"},'
    '{"id":"g1","username":"oma","displayName":"Oma","role":"guest"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  tearDown(() => SosController.current = null);

  late SyncEngine engine;
  var hasPassword = false;
  var raised = 0;

  Future<BuildContext> start(
    WidgetTester tester, {
    String memberId = 'm1',
    Size size = const Size(900, 1800),
    void Function(LocalStore store)? before,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    raised = 0;
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/api/me')) {
        return http.Response(
          jsonEncode({
            'id': memberId,
            'username': 'x',
            'displayName': 'X',
            'hasPassword': hasPassword,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (r.url.path.endsWith('/api/sos')) raised++;
      return http.Response('{}', 503);
    });
    final state = AppState();
    await state.init();
    final store = LocalStore.open(':memory:')..setMeta('members', _members);
    before?.call(store);
    engine = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1', httpClient: client),
      memberId: memberId,
    );
    state
      ..me = engine.members.firstWhere((m) => m.id == memberId)
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    return tester.element(find.byType(Scaffold).first);
  }

  group('confidential titles', () {
    final from = DateTime(2026, 11, 9, 8);

    CalendarEvent secret(String title) => CalendarEvent(
      id: 'e1',
      title: title,
      start: DateTime(2026, 11, 11, 10),
      end: DateTime(2026, 11, 11, 11),
      confidential: true,
      memberIds: const ['m1'],
    );

    testWidgets('stay out of the packing reminder', (tester) async {
      await start(tester);
      engine
        ..saveEvent(secret('Psychotherapie'))
        ..saveShoppingList(
          const ShoppingList(
            id: 'l1',
            name: 'Pack',
            packing: true,
            eventId: 'e1',
          ),
        )
        ..saveShoppingItem(
          const ShoppingItem(
            id: 'i1',
            listId: 'l1',
            name: 'Karte',
            memberId: 'm1',
          ),
        );
      final r = [
        for (final x in familyReminders(
          engine,
          from: from,
          to: from.add(const Duration(days: 14)),
        ))
          if (x.key.startsWith('pack:')) x,
      ];
      expect(r, hasLength(1));
      expect(r.single.title, isNot(contains('Psychotherapie')));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('stay out of the week plan', (tester) async {
      await start(tester);
      engine.saveEvent(secret('Psychotherapie'));
      final titles = [
        for (final d in buildWeekPlan(engine, DateTime(2026, 11, 9)).days)
          for (final e in d.events) e.title,
      ];
      expect(titles, isNotEmpty);
      expect(titles, isNot(contains('Psychotherapie')));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('stay out of the school bag', (tester) async {
      await start(tester);
      final child = Child(
        id: 'c1',
        name: 'Emil',
        birthDate: DateTime(2018, 3, 4),
      );
      engine
        ..saveChild(child)
        ..saveEvent(secret('Emil Therapie'))
        ..saveEvent(
          CalendarEvent(
            id: 'e2',
            title: 'Emil Zahnarzt',
            start: DateTime(2026, 11, 11, 14),
            end: DateTime(2026, 11, 11, 15),
          ),
        )
        ..saveTimetable(
          Timetable(childId: 'c1').withLesson(DateTime.wednesday, 0, 'Mathe'),
        );
      final bag = schoolBag(engine, child, DateTime(2026, 11, 11));
      expect(bag?.events, ['Emil Zahnarzt']);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('the subscription editor', () {
    testWidgets('says what is missing where it can be seen', (tester) async {
      final context = await start(tester);
      showSubscriptionEditor(context);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Speichern'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Bitte einen Namen angeben'), findsOneWidget);
      expect(find.text('Bitte einen Betrag angeben'), findsOneWidget);
      expect(engine.subscriptions, isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('survives a period that is none', (tester) async {
      final context = await start(tester);
      showSubscriptionEditor(context);
      await tester.pumpAndSettle();
      final every = find.widgetWithText(TextField, 'Alle');
      await tester.enterText(every, '-1');
      await tester.pump();
      expect(tester.widget<TextField>(every).controller!.text, '1');
      await tester.enterText(every, '0');
      await tester.pump();
      await tester.ensureVisible(find.text('Als gekündigt markieren'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Als gekündigt markieren'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('suggests the day before the next payment', (tester) async {
      final context = await start(tester);
      final now = DateTime.now();
      final next = DateTime(now.year, now.month, now.day + 10);
      final existing = Subscription(
        id: 'a',
        name: 'Film',
        cents: 999,
        start: next,
      );
      engine.saveSubscription(existing);
      showSubscriptionEditor(context, existing: existing);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Als gekündigt markieren'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Als gekündigt markieren'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DatePickerDialog>(find.byType(DatePickerDialog))
            .initialDate,
        DateTime(now.year, now.month, now.day + 9),
      );
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('budget too says it next to the field', (tester) async {
      final context = await start(tester);
      showBudgetEntryEditor(context);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Speichern'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Bitte einen Betrag angeben'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('subscription reminders', () {
    final from = DateTime(2026, 11, 9, 8);

    List<DateTime> due(Subscription s) {
      engine.saveSubscription(s);
      return [
        for (final r in familyReminders(
          engine,
          from: from,
          to: from.add(const Duration(days: 14)),
        ))
          if (r.key.contains(s.id)) r.at,
      ];
    }

    Subscription abo(
      String id,
      SubscriptionUnit unit, {
      int? lead,
      String? memberId,
    }) => Subscription(
      id: id,
      name: 'Film',
      cents: 100,
      start: DateTime(2026, 1, 20),
      unit: unit,
      remindDays: lead,
      memberId: memberId,
    );

    testWidgets('come for short periods with a long lead too', (tester) async {
      await start(tester);
      expect(due(abo('daily', SubscriptionUnit.days, lead: 3)), isNotEmpty);
      expect(due(abo('weekly', SubscriptionUnit.weeks, lead: 14)), isNotEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('go to adults when the payer has no account', (tester) async {
      await start(tester);
      expect(
        due(abo('gone', SubscriptionUnit.months, lead: 3, memberId: 'weg')),
        isNotEmpty,
      );
      expect(
        due(abo('other', SubscriptionUnit.months, lead: 3, memberId: 'm2')),
        isEmpty,
      );
      await tester.pump(const Duration(seconds: 5));
    });
  });

  testWidgets('a guest reads a task instead of editing it', (tester) async {
    final context = await start(tester, memberId: 'g1');
    engine.saveTask(
      const Task(
        id: 't1',
        title: 'Kuchen',
        notes: 'Bitte ohne Nuesse',
        assigneeIds: ['g1'],
      ),
    );
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const TasksScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kuchen'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Speichern'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the banner shows the running alarm, it raises none', (
    tester,
  ) async {
    await start(
      tester,
      memberId: 'k1',
      before: (store) => store.put(
        SyncRecord(
          collection: Collections.sosAlerts,
          id: 's1',
          data: SosAlert(
            id: 's1',
            memberId: 'k1',
            startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
            state: SosState.active,
          ).toData(),
          updatedAt: 1,
        ),
        dirty: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(SosBanner),
            matching: find.byType(ListTile),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(SosController.current?.alertId, 's1');
    expect(raised, 0);
    await tester.pump(const Duration(seconds: 5));
  });

  group('asking for the password', () {
    testWidgets('does not bother accounts without one', (tester) async {
      final context = await start(tester);
      hasPassword = false;
      expect(await askAccountPassword(context), '');
    });

    testWidgets('hands on what was typed, null when cancelled', (tester) async {
      final context = await start(tester);
      hasPassword = true;
      String? answer = 'unset';
      askAccountPassword(context).then((v) => answer = v);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'tulpe-regal-7');
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(answer, 'tulpe-regal-7');

      askAccountPassword(context).then((v) => answer = v);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(answer, isNull);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
