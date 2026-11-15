// What the chores area, the start page and the wall display show about
// chores: what a wish costs, the texts in English, no balances for guests,
// and children away (#545).
import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/chores_screens.dart';
import 'package:famio/src/screens/kiosk_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const mama = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
const papa = FamilyMember(id: 'm2', username: 'papa', displayName: 'Papa');
const lina = FamilyMember(
  id: 'k1',
  username: 'lina',
  displayName: 'Lina',
  role: MemberRole.child,
);
const fips = FamilyMember(
  id: 'k2',
  username: 'fips',
  displayName: 'Fips',
  role: MemberRole.child,
);
const oma = FamilyMember(
  id: 'g1',
  username: 'oma',
  displayName: 'Oma',
  role: MemberRole.guest,
);

DateTime get today => DateUtils.dateOnly(DateTime.now());

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
    await initializeDateFormatting('en');
  });

  late SyncEngine engine;

  /// The app for [me]; [seed] writes what Mama entered before.
  Future<void> boot(
    WidgetTester tester, {
    FamilyMember me = mama,
    String language = 'de',
    void Function(SyncEngine mama)? seed,
  }) async {
    tester.view.physicalSize = const Size(1400, 2000);
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
          for (final m in [mama, papa, lina, fips, oma]) m.toJson(),
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
    await tester.pump();
  }

  Future<void> open(WidgetTester tester, Widget screen) async {
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> done(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  Chore chore(String id, String title, List<String> members) => Chore(
    id: id,
    title: title,
    emoji: '🧹',
    memberIds: members,
    start: DateTime(2026),
  );

  void away(SyncEngine e, String who, {String? substitute}) => e.saveAbsence(
    MemberAbsence(
      id: 'away-$who',
      memberId: who,
      from: today,
      to: DateUtils.addDaysToDate(today, 1),
      substituteId: substitute,
    ),
  );

  testWidgets('ALL-088 a wish shows what it costs', (tester) async {
    await boot(tester);
    for (final e in [
      PointEntry(
        id: 'p1',
        memberId: lina.id,
        points: 20,
        title: 'Fleißig',
        kind: PointKind.bonus,
        at: DateTime.now(),
      ),
      PointEntry(
        id: 'p2',
        memberId: lina.id,
        points: -10,
        title: '🍦 Eis',
        kind: PointKind.reward,
        at: DateTime.now(),
        status: PointStatus.pending,
      ),
    ]) {
      engine.put(Collections.pointEntries, e.id, e.toData());
    }
    engine.saveChore(chore('c1', 'Abräumen', [lina.id]));
    await open(tester, const ChoresScreen());
    expect(
      find.text(tr.choresPointsPointsBalanceBalance(10, 20)),
      findsOneWidget,
    );
    expect(find.textContaining('-10'), findsNothing);
    await done(tester);
  });

  testWidgets('ALL-065 "paused" and "today:" in English', (tester) async {
    await boot(tester, language: 'en');
    engine
      ..saveChore(
        Chore(
          id: 'c1',
          title: 'Paused chore',
          memberIds: [lina.id],
          start: DateTime(2026),
          paused: true,
        ),
      )
      ..saveChore(
        Chore(
          id: 'c2',
          title: 'Turns chore',
          memberIds: [lina.id, fips.id],
          rotate: true,
          start: DateTime(2026),
        ),
      );
    await open(tester, const ChoresScreen());
    await tester.tap(find.text(tr.sectionChores).last);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining(' · paused'), findsOneWidget);
    expect(find.textContaining('today: '), findsOneWidget);
    expect(find.textContaining('pausiert'), findsNothing);
    expect(find.textContaining('heute:'), findsNothing);
    await done(tester);
  });

  testWidgets('ALL-075 a guest sees no balances of zero', (tester) async {
    await boot(
      tester,
      me: oma,
      seed: (mama) => mama.saveChore(chore('c1', 'Abräumen', [lina.id])),
    );
    await open(tester, const ChoresScreen());
    // "Heute": no stars of zero next to the children.
    expect(find.text('⭐ 0'), findsNothing);
    await tester.tap(find.text(tr.settingsAccount));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(lina.displayName), findsOneWidget);
    expect(find.text(tr.choresAccountsGuests), findsOneWidget);
    expect(find.text('⭐ 0'), findsNothing);
    expect(find.text(formatEuro(0)), findsNothing);
    expect(find.text(tr.choresNoPocketMoneySet), findsNothing);
    await done(tester);
  });

  testWidgets('ALL-108 the start page: a child away has nothing open', (
    tester,
  ) async {
    await boot(
      tester,
      seed: (mama) {
        mama
          ..saveChore(chore('c1', 'Abräumen', [lina.id]))
          ..saveChore(chore('c2', 'Füttern', [fips.id]));
        away(mama, lina.id);
        away(mama, fips.id, substitute: papa.id);
      },
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Lina: ${tr.absenceAway}'), findsOneWidget);
    expect(find.textContaining('Abräumen'), findsNothing);
    // Covered by Papa, Fips's chore is still to do.
    expect(find.text('Fips: 🧹 Füttern'), findsOneWidget);
    await done(tester);
  });

  testWidgets('ALL-108 the wall display: away, or done by who covers', (
    tester,
  ) async {
    await boot(
      tester,
      seed: (mama) {
        mama
          ..saveChore(chore('c1', 'Abräumen', [lina.id]))
          ..saveChore(chore('c2', 'Füttern', [fips.id]));
        away(mama, lina.id);
        away(mama, fips.id, substitute: papa.id);
      },
    );
    await open(tester, const KioskScreen());
    expect(find.text(tr.absenceAway), findsOneWidget);
    expect(find.textContaining('Abräumen'), findsNothing);
    expect(
      find.text(tr.absenceRepresentedBy(papa.displayName)),
      findsOneWidget,
    );
    await tester.tap(
      find.byWidgetPredicate((w) => w is RoundCheck && w.label == 'Füttern'),
    );
    await tester.pump(const Duration(seconds: 1));
    final feed = engine.chores.singleWhere((c) => c.id == 'c2');
    expect(engine.choreCompletion(feed, today)!.memberId, papa.id);
    await done(tester);
  });
}
