import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/subscriptions_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;
  late AppState state;
  const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');

  Future<void> start(
    WidgetTester tester, {
    Size size = const Size(1000, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    state = AppState();
    await state.init();
    final store = LocalStore.open(':memory:')
      ..setMeta(
        'members',
        '[{"id":"m1","username":"mama","displayName":"Mama"},'
            '{"id":"m2","username":"papa","displayName":"Papa"}]',
      );
    engine = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
  }

  Future<void> push(WidgetTester tester, Widget page) async {
    Navigator.of(
      tester.element(find.byType(Scaffold).first),
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pumpAndSettle();
  }

  /// A payment on a day of the coming weeks, whatever today is.
  DateTime inDays(int days) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + days);
  }

  Subscription abo(
    String id,
    String name,
    int cents, {
    int inDaysFromNow = 5,
    SubscriptionUnit unit = SubscriptionUnit.months,
    int every = 1,
    String category = 'Streaming',
    String? memberId,
    DateTime? endsOn,
    int? remindDays = 3,
  }) => Subscription(
    id: id,
    name: name,
    cents: cents,
    start: inDays(inDaysFromNow),
    unit: unit,
    every: every,
    category: category,
    memberId: memberId,
    endsOn: endsOn,
    remindDays: remindDays,
  );

  testWidgets('shows what the subscriptions come to', (tester) async {
    await start(tester);
    engine
      ..saveSubscription(abo('a', 'Filme', 1200))
      ..saveSubscription(
        abo(
          'b',
          'Speicher',
          12000,
          inDaysFromNow: 2,
          unit: SubscriptionUnit.years,
          category: 'Cloud',
          memberId: 'm2',
        ),
      );
    await push(tester, const SubscriptionsScreen());

    expect(find.text('22,00 €'), findsOneWidget);
    expect(find.text('264,00 €'), findsOneWidget);
    expect(find.text('Filme'), findsOneWidget);
    expect(find.textContaining('monatlich'), findsOneWidget);
    expect(find.textContaining('jährlich'), findsWidgets);
    expect(find.text('in 2 Tagen'), findsOneWidget);
    expect(find.text('Wer bezahlt'), findsOneWidget);

    // The next payment first, by price the dearest.
    double top(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(top('Speicher'), lessThan(top('Filme')));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Name'));
    await tester.pumpAndSettle();
    expect(top('Filme'), lessThan(top('Speicher')));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('adds one with its period and category', (tester) async {
    await start(tester);
    await push(tester, const SubscriptionsScreen());
    expect(find.text('Erstes Abo eintragen'), findsOneWidget);

    await tester.tap(find.text('Erstes Abo eintragen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Zeitung');
    await tester.enterText(find.widgetWithText(TextField, 'Betrag'), '29,90');
    await tester.tap(find.widgetWithText(ChoiceChip, 'vierteljährlich'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Zeitung'));
    await tester.pump();
    await tester.ensureVisible(find.text('Speichern'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final s = engine.subscriptions.single;
    expect(s.name, 'Zeitung');
    expect(s.cents, 2990);
    expect(s.every, 3);
    expect(s.unit, SubscriptionUnit.months);
    expect(s.category, 'Zeitung');
    expect(s.remindDays, 3);
    expect(find.textContaining('vierteljährlich'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('asks for a name and an amount', (tester) async {
    await start(tester);
    await push(tester, const SubscriptionsScreen());
    await tester.tap(find.text('Erstes Abo eintragen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Speichern'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pump();
    expect(engine.subscriptions, isEmpty);
    expect(find.text('Bitte einen Namen angeben'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a cancelled one moves to the ended ones', (tester) async {
    await start(tester);
    engine
      ..saveSubscription(abo('a', 'Filme', 1200))
      ..saveSubscription(
        abo(
          'b',
          'Alt',
          500,
          inDaysFromNow: -40,
          endsOn: inDays(-5),
          category: 'Musik',
        ),
      );
    await push(tester, const SubscriptionsScreen());
    expect(find.text('Beendet'), findsOneWidget);
    expect(find.text('Monatlich gespart'), findsOneWidget);
    expect(find.text('5,00 €'), findsWidgets);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the budget shows it unless the family switched it off', (
    tester,
  ) async {
    await start(tester);
    engine.saveSubscription(abo('a', 'Filme', 1200));
    await tester.pump();
    await push(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: subscriptionsShown(context)
              ? const SubscriptionsCard()
              : const Text('ohne Abos'),
        ),
      ),
    );
    expect(find.text('Abos'), findsOneWidget);
    expect(find.text('1 Abo · 12,00 € im Monat'), findsOneWidget);

    state.hiddenModules = {ServerSettings.subscriptionsModule};
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('ohne Abos'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('follows who may see the budget', (tester) async {
    await start(tester);
    engine.saveSubscription(abo('a', 'Filme', 1200));
    expect(engine.record(Collections.subscriptions, 'a')?.visibleTo, isNull);
    engine.saveBudgetSettings(BudgetSettings(memberIds: [me.id]));
    expect(engine.record(Collections.subscriptions, 'a')?.visibleTo, [me.id]);
    engine.saveSubscription(abo('b', 'Musik', 900));
    expect(engine.record(Collections.subscriptions, 'b')?.visibleTo, [me.id]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('fits a phone with large text', (tester) async {
    await start(tester, size: const Size(390, 844));
    engine
      ..saveSubscription(abo('a', 'Filme und Serien', 1200, memberId: 'm2'))
      ..saveSubscription(
        abo('b', 'Speicher', 12000, unit: SubscriptionUnit.years),
      );
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await push(tester, const SubscriptionsScreen());
    await tester.dragUntilVisible(
      find.text('Speicher'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speicher'));
    await tester.pumpAndSettle();
    expect(find.text('Speichern'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  group('reminders', () {
    final from = DateTime(2026, 11, 9, 8);
    final to = DateTime(2026, 12, 20);

    List<DueReminder> due({bool subscriptions = true}) => [
      for (final r in familyReminders(
        engine,
        from: from,
        to: to,
        subscriptions: subscriptions,
      ))
        if (r.key.startsWith('subscription:')) r,
    ];

    Subscription fixed(String id, {int? remindDays = 3, String? memberId}) =>
        Subscription(
          id: id,
          name: 'Filme',
          cents: 1299,
          start: DateTime(2026, 1, 15),
          remindDays: remindDays,
          memberId: memberId,
        );

    testWidgets('come the set days ahead at nine', (tester) async {
      await start(tester);
      engine.saveSubscription(fixed('a'));
      final r = due();
      expect(r.map((e) => e.at), [
        DateTime(2026, 11, 12, 9),
        DateTime(2026, 12, 12, 9),
      ]);
      expect(r.first.title, 'Filme: Abbuchung in 3 Tagen');
      expect(r.first.body, contains('12,99 €'));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('stay away when off, for someone else or hidden', (
      tester,
    ) async {
      await start(tester);
      engine
        ..saveSubscription(fixed('off', remindDays: null))
        ..saveSubscription(fixed('other', memberId: 'm2'));
      expect(due(), isEmpty);
      engine.saveSubscription(fixed('mine', memberId: me.id));
      expect(due(), isNotEmpty);
      expect(due(subscriptions: false), isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
