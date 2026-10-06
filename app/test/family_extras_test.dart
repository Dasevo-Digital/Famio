import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/screens/kiosk_screen.dart';
import 'package:famio/src/screens/pantry_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"},'
    '{"id":"g1","username":"oma","displayName":"Oma","role":"guest"}]';

SyncEngine _engine(String memberId) => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: memberId,
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('points', () {
    final today = DateTime(2026, 9, 28);
    final chore = Chore(
      id: 'c1',
      title: 'Tisch decken',
      points: 3,
      memberIds: const ['k1'],
      start: today,
    );

    test('children ask, adults decide', () {
      final kid = _engine('k1');
      kid.completeChore(chore, today, 'k1');
      final entry = kid.choreCompletion(chore, today)!;
      expect(entry.status, PointStatus.pending);
      expect(kid.pointBalance('k1'), 0);

      final mama = _engine('m1')..savePointEntry(entry);
      mama.decidePoints(entry, approve: true);
      expect(mama.pointBalance('k1'), 3);
    });

    test('adults book directly, the wall display asks', () {
      final mama = _engine('m1');
      mama.completeChore(chore, today, 'k1');
      expect(mama.choreCompletion(chore, today)!.status, PointStatus.approved);
      mama.undoChore(chore, today);
      mama.completeChore(chore, today, 'k1', asRequest: true);
      expect(mama.choreCompletion(chore, today)!.status, PointStatus.pending);
    });

    test('finishing a routine earns its points once', () {
      final kid = _engine('k1');
      final routine = Routine(
        id: 'r1',
        title: 'Morgens',
        points: 2,
        steps: const [
          RoutineStep(id: 'a', title: 'Anziehen'),
          RoutineStep(id: 'b', title: 'Zähne'),
        ],
      );
      kid.toggleRoutineStep(routine, today, 'k1', 'a');
      expect(kid.pointsOf('k1'), isEmpty);
      kid.toggleRoutineStep(routine, today, 'k1', 'b');
      expect(kid.pointsOf('k1').single.points, 2);
      expect(kid.pointsOf('k1').single.status, PointStatus.pending);
      // Unticking withdraws the open request.
      kid.toggleRoutineStep(routine, today, 'k1', 'b');
      expect(kid.pointsOf('k1'), isEmpty);
    });

    test('rewards and pocket money', () {
      final mama = _engine('m1')
        ..savePointEntry(
          PointEntry(
            id: 'p',
            memberId: 'k1',
            points: 20,
            title: 'Bonus',
            kind: PointKind.bonus,
            at: today,
          ),
        );
      mama.redeem(
        const Reward(id: 'r', title: 'Eis', emoji: '🍦', cost: 5),
        'k1',
      );
      expect(mama.pointBalance('k1'), 15);
      mama.saveAllowance(
        Allowance(memberId: 'k1', since: today, centsPerPoint: 10),
      );
      mama.convertPoints('k1', 10);
      expect(mama.pointBalance('k1'), 5);
      expect(mama.moneyBalance('k1'), 100);
    });
  });

  test('lists from templates and back', () {
    final engine = _engine('m1');
    final id = engine.listFromTemplate(builtInTemplates.first);
    final list = engine.shoppingList(id)!;
    expect(list.name, contains('Urlaub'));
    expect(
      engine.shoppingItems(id).length,
      builtInTemplates.first.items.length,
    );
    final template = engine.templateFromList(list);
    expect(engine.listTemplates.single.items.length, template.items.length);
  });

  test('poll votes carry the chat audience', () {
    final engine = _engine('m1');
    engine.sendPoll(
      ChatIds.direct('m1', 'k1'),
      const Poll(
        question: 'Kino?',
        options: [
          PollOption(id: 'o0', text: 'Ja'),
          PollOption(id: 'o1', text: 'Nein'),
        ],
      ),
    );
    final message = engine.chatMessages(ChatIds.direct('m1', 'k1')).single;
    engine.vote(message, ['o0']);
    final vote = engine.records(Collections.pollVotes).single;
    expect(vote.visibleTo, unorderedEquals(['m1', 'k1']));
    expect(engine.pollVotes(message.id).single.optionIds, ['o0']);
    engine.vote(message, []);
    expect(engine.pollVotes(message.id), isEmpty);
  });

  test('medication intakes reduce the stock', () {
    final engine = _engine('m1');
    final m = Medication(
      id: 'med',
      name: 'Saft',
      times: const ['08:00'],
      start: DateTime(2026),
      stock: 10,
      stockAt: DateTime.now().subtract(const Duration(hours: 1)),
      careIds: const ['m1'],
    );
    engine.saveMedication(m);
    engine.recordIntake(m, scheduled: DateTime(2026, 9, 28, 8));
    engine.recordIntake(m, scheduled: DateTime(2026, 9, 29, 8), skipped: true);
    expect(engine.takenSinceCount(m), 1);
    expect(engine.intakeAt(m, DateTime(2026, 9, 28, 8)), isNotNull);
    expect(engine.records(Collections.medicationIntakes).first.visibleTo, [
      'm1',
    ]);
  });

  test('Open Food Facts lookup', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v2/product/4000417025005.json');
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'status': 1,
            'product': {
              'product_name_de': 'Vollmilch',
              'brands': 'Hof, Andere',
              'quantity': '1 l',
            },
          }),
        ),
        200,
      );
    });
    final p = await lookupProduct('4000417025005', client: client);
    expect(p?.name, 'Vollmilch (1 l)');
    expect(p?.brand, 'Hof');
    expect(await lookupProduct('abc', client: client), isNull);
  });

  Future<SyncEngine> open(
    WidgetTester tester, {
    required String memberId,
    String? section,
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final engine = _engine(memberId);
    state
      ..me = engine.members.firstWhere((m) => m.id == memberId)
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    if (section != null) {
      await tester.tap(find.text(section).first);
      await tester.pumpAndSettle();
    }
    return engine;
  }

  testWidgets('guests see no health, finance or document sections', (
    tester,
  ) async {
    await open(tester, memberId: 'g1');
    await tester.pumpAndSettle();
    expect(find.text('Ämter'), findsWidgets);
    expect(find.text('Dokumente'), findsNothing);
    expect(find.text('Medizin'), findsNothing);
    expect(find.text('Finanzen'), findsNothing);
    expect(find.text('Standort'), findsNothing);
  });

  testWidgets('a child ticks off a chore and waits for the okay', (
    tester,
  ) async {
    final engine = await open(tester, memberId: 'k1', section: 'Ämter');
    engine.saveChore(
      Chore(
        id: 'c1',
        title: 'Blumen gießen',
        emoji: '🪴',
        points: 2,
        memberIds: const ['k1'],
        start: DateTime(2026),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Blumen gießen'), findsOneWidget);
    await tester.tap(find.byType(RoundCheck).first);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('wartet auf Bestätigung'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the wall display shows the day', (tester) async {
    final engine = await open(tester, memberId: 'm1');
    final now = DateTime.now();
    engine
      ..saveEvent(
        CalendarEvent(
          id: 'e1',
          title: 'Turnen',
          start: DateTime(now.year, now.month, now.day, 23, 0),
          end: DateTime(now.year, now.month, now.day, 23, 30),
        ),
      )
      ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'))
      ..saveShoppingItem(
        const ShoppingItem(id: 'i1', listId: 'l1', name: 'Brot'),
      );
    await tester.pump();
    final context = tester.element(find.byType(Scaffold).first);
    openKiosk(context);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Turnen'), findsOneWidget);
    expect(find.text('Brot'), findsOneWidget);
    expect(find.text('Ämter & Routinen'), findsOneWidget);
    await tester.tap(find.byTooltip('Wandanzeige beenden'));
    await tester.pumpAndSettle();
  });

  testWidgets('the wall display shows family photos when nobody uses it', (
    tester,
  ) async {
    final engine = await open(tester, memberId: 'm1');
    engine.saveDocument(
      FamilyDocument(
        id: 'd1',
        title: 'Urlaub',
        category: DocumentCategory.photos,
        file: const FileRef(
          id: 'f1',
          name: 'strand.jpg',
          mime: 'image/jpeg',
          size: 10,
        ),
        createdAt: DateTime.now(),
      ),
    );
    await tester.pump();
    final context = tester.element(find.byType(Scaffold).first);
    openKiosk(context);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(PhotoSlideshow), findsNothing);
    expect(find.byTooltip('Keine Fotos zeigen'), findsOneWidget);
    for (var i = 0; i < 9; i++) {
      await tester.pump(const Duration(seconds: 15));
    }
    expect(find.byType(PhotoSlideshow), findsOneWidget);
    // A touch brings the day back.
    await tester.tapAt(const Offset(200, 200));
    await tester.pump();
    expect(find.byType(PhotoSlideshow), findsNothing);
    await tester.tap(find.byTooltip('Wandanzeige beenden'));
    await tester.pump(const Duration(seconds: 1));
  });
}
