// Open wishes keep the points they ask for: a child sees what is set aside
// and cannot wish for more than is left (#377).
import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/chores_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const mama = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
const lina = FamilyMember(
  id: 'k1',
  username: 'lina',
  displayName: 'Lina',
  role: MemberRole.child,
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  PointEntry points(String id, int points, {bool open = false}) => PointEntry(
    id: id,
    memberId: lina.id,
    points: points,
    title: open ? '🎮 Spiel' : 'Fleißig',
    kind: open ? PointKind.reward : PointKind.bonus,
    at: DateTime.now(),
    status: open ? PointStatus.pending : PointStatus.approved,
  );

  /// Lina's app with [entries] and a reward of [cost] points.
  Future<void> boot(
    WidgetTester tester,
    List<PointEntry> entries, {
    required int cost,
  }) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          jsonEncode([
            for (final m in [mama, lina]) m.toJson(),
          ]),
        ),
      api: FamioApiClient('localhost:1'),
      memberId: lina.id,
    );
    for (final e in entries) {
      engine.put(Collections.pointEntries, e.id, e.toData());
    }
    engine.put(
      Collections.rewards,
      'r1',
      Reward(id: 'r1', title: 'Kino', emoji: '🎬', cost: cost).toData(),
    );
    final state = AppState();
    await state.init();
    state
      ..me = lina
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => const ChoresScreen()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text(tr.choresTabRewards).last);
    await tester.pump(const Duration(seconds: 1));
  }

  int openWishes() => engine.pendingPoints.length;

  test('what is left to wish for', () {
    final entries = [
      points('p1', 20),
      points('w1', -15, open: true),
      // A done chore waiting for the parents earns nothing yet.
      PointEntry(
        id: 'c1',
        memberId: lina.id,
        points: 3,
        title: 'Tisch',
        kind: PointKind.chore,
        at: DateTime.now(),
        status: PointStatus.pending,
      ),
      // Declined wishes keep nothing.
      PointEntry(
        id: 'w0',
        memberId: lina.id,
        points: -20,
        title: 'Eis',
        kind: PointKind.reward,
        at: DateTime.now(),
        status: PointStatus.rejected,
      ),
    ];
    expect(PointEntry.available(entries, lina.id), 5);
    expect(PointEntry.available(entries, lina.id, except: 'w1'), 20);
    expect(PointEntry.available(entries, mama.id), 0);
  });

  testWidgets('a wish beyond what open wishes leave is not sent', (
    tester,
  ) async {
    await boot(tester, [
      points('p1', 20),
      points('w1', -20, open: true),
    ], cost: 20);
    // The balance next to "Du hast" and what the reward costs.
    expect(find.text('⭐ 20'), findsNWidgets(2));
    expect(find.text(tr.rewardsPointsReserved(20)), findsOneWidget);
    expect(engine.availablePoints(lina.id), 0);
    await tester.tap(find.text(tr.rewardsRedeem));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(tr.rewardsNeedPointsWishesOpen(20, 20)), findsOneWidget);
    expect(find.text(tr.rewardsWish), findsNothing, reason: 'no dialog');
    expect(openWishes(), 1);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('within what is left a wish goes out', (tester) async {
    await boot(tester, [
      points('p1', 20),
      points('w1', -5, open: true),
    ], cost: 10);
    expect(find.text(tr.rewardsPointsReserved(5)), findsOneWidget);
    await tester.tap(find.text(tr.rewardsRedeem));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text(tr.rewardsWish));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(tr.rewardsWishSent), findsOneWidget);
    expect(openWishes(), 2);
    expect(engine.availablePoints(lina.id), 5);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('without open wishes nothing is set aside', (tester) async {
    await boot(tester, [points('p1', 4)], cost: 10);
    expect(find.textContaining('vorgemerkt'), findsNothing);
    await tester.tap(find.text(tr.rewardsRedeem));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(tr.rewardsYouStillNeedPoints(6)), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
