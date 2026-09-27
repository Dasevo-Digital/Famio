import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Change notifications arrive asynchronously: one pump delivers the event,
/// the next renders the rebuilt widgets.
Future<void> pumpData(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  const me = FamilyMember(
    id: 'm1',
    username: 'mama',
    displayName: 'Mama',
    color: 0xFFDB4A7E,
  );
  const papa = FamilyMember(
    id: 'm2',
    username: 'papa',
    displayName: 'Papa',
    color: 0xFF3587D6,
  );
  late SyncEngine engine;

  Future<void> open(WidgetTester tester, String section) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
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
    await tester.tap(find.text(section).first);
    await tester.pumpAndSettle();
  }

  testWidgets('chat: sending a direct message restricts its audience', (
    tester,
  ) async {
    await open(tester, 'Chat');
    expect(find.text('Familie'), findsWidgets);
    await tester.tap(find.text('Papa'));
    await tester.pumpAndSettle();
    expect(find.text('Privat – nur ihr zwei'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Holst du die Kinder ab?');
    await tester.tap(find.byTooltip('Senden'));
    await pumpData(tester);

    final message = engine.records(Collections.chatMessages).single;
    expect(message.visibleTo, unorderedEquals([me.id, papa.id]));
    expect(find.text('Holst du die Kinder ab?'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('documents: filter by category and show lock for private ones', (
    tester,
  ) async {
    await open(tester, 'Dokumente');
    engine
      ..saveDocument(
        FamilyDocument(
          id: 'd1',
          title: 'Reisepass Mama',
          category: DocumentCategory.identity,
          file: const FileRef(
            id: 'f1',
            name: 'pass.pdf',
            mime: 'application/pdf',
            size: 120000,
          ),
          expiresAt: DateTime.now().add(const Duration(days: 20)),
          visibleTo: const ['m1'],
        ),
      )
      ..saveDocument(
        const FamilyDocument(
          id: 'd2',
          title: 'Hausratversicherung',
          category: DocumentCategory.insurance,
          file: FileRef(
            id: 'f2',
            name: 'police.pdf',
            mime: 'application/pdf',
            size: 90000,
          ),
        ),
      );
    await pumpData(tester);
    expect(find.text('Reisepass Mama'), findsOneWidget);
    expect(find.text('Hausratversicherung'), findsOneWidget);
    expect(find.byTooltip('Sichtbar für: Mama'), findsOneWidget);

    await tester.tap(find.text('Versicherungen'));
    await tester.pumpAndSettle();
    expect(find.text('Reisepass Mama'), findsNothing);
    expect(find.text('Hausratversicherung'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('kids: milestones appear in the timeline', (tester) async {
    await open(tester, 'Kinder');
    final birth = DateTime.now().subtract(const Duration(days: 300));
    engine
      ..saveChild(
        Child(id: 'k1', name: 'Lena', birthDate: DateUtils.dateOnly(birth)),
      )
      ..saveChildEntry(
        ChildEntry(
          id: 'e1',
          childId: 'k1',
          kind: ChildEntryKind.milestone,
          refId: 'sit',
          date: DateUtils.dateOnly(birth.add(const Duration(days: 200))),
        ),
      );
    await pumpData(tester);
    expect(find.text('Lena'), findsOneWidget);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();

    // Babies open on the daily log: one tap logs a diaper.
    expect(find.text('Protokoll'), findsOneWidget);
    await tester.tap(find.text('Windel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('nass + voll'));
    await tester.pumpAndSettle();
    expect(engine.childLogs('k1').single.diaper, DiaperKind.both);
    expect(find.text('Windel nass + voll'), findsOneWidget);

    await tester.tap(find.text('Zeitstrahl'));
    await tester.pumpAndSettle();
    expect(find.text('Sitzt frei ohne Stütze'), findsOneWidget);
    expect(find.textContaining('Geburt'), findsOneWidget);

    // Check-ups are ticked off right in the list.
    await tester.tap(find.text('Vorsorge'));
    await tester.pumpAndSettle();
    expect(find.textContaining('U6'), findsWidgets);
    await tester.tap(find.byType(RoundCheck).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heute erledigt'));
    await tester.pumpAndSettle();
    expect(
      engine.childEntries('k1').where((e) => e.kind == ChildEntryKind.checkup),
      hasLength(1),
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('pregnancy: weeks, contractions and the baby arrives', (
    tester,
  ) async {
    await open(tester, 'Kinder');
    final due = DateUtils.dateOnly(
      DateTime.now(),
    ).add(const Duration(days: 20));
    engine.savePregnancy(
      Pregnancy(id: 'p1', dueDate: due, name: 'Krümel', guardianIds: [me.id]),
    );
    await pumpData(tester);
    expect(find.text('Krümel'), findsOneWidget);
    expect(find.textContaining('SSW 37+1'), findsOneWidget);
    expect(engine.record(Collections.pregnancies, 'p1')?.visibleTo, [me.id]);
    await tester.tap(find.text('Krümel'));
    await tester.pumpAndSettle();
    // Late in pregnancy it opens on the contraction timer.
    await tester.tap(find.text('Wehe beginnt'));
    await tester.pump();
    await tester.tap(find.text('Wehe vorbei'));
    await tester.pump();
    expect(engine.pregnancy('p1')!.contractions.single.end, isNotNull);

    await tester.tap(find.text('Woche'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Baby ist da!'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Emil');
    await tester.tap(find.text('Junge'));
    await tester.tap(find.text('Kind anlegen'));
    await tester.pumpAndSettle();
    final child = engine.children.single;
    expect(child.name, 'Emil');
    expect(child.sex, ChildSex.male);
    expect(child.guardianIds, [me.id]);
    expect(engine.pregnancy('p1')!.childId, child.id);
    expect(engine.activePregnancies, isEmpty);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('meals: plan a recipe and shop its ingredients', (tester) async {
    await open(tester, 'Essen');
    final today = DateUtils.dateOnly(DateTime.now());
    engine
      ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'))
      ..saveRecipe(
        Recipe(
          id: 'r1',
          title: 'Pfannkuchen',
          servings: 4,
          ingredients: [
            Ingredient.parse('250 g Mehl'),
            Ingredient.parse('3 Eier'),
          ],
          steps: 'Verrühren\nAusbacken',
        ),
      )
      ..saveMeal(
        PlannedMeal(
          id: 'm1',
          date: today,
          slot: MealSlot.dinner,
          recipeId: 'r1',
          servings: 6,
        ),
      );
    await pumpData(tester);
    expect(find.text('Pfannkuchen'), findsOneWidget);
    await tester.tap(find.text('Zutaten der Woche auf die Einkaufsliste'));
    await tester.pumpAndSettle();
    final items = {
      for (final i in engine.shoppingItems('l1')) i.name: i.quantity,
    };
    expect(items, {'Mehl': '375 g', 'Eier': '4,5'});

    await tester.tap(find.text('Pfannkuchen'));
    await tester.pumpAndSettle();
    expect(find.text('375 g'), findsOneWidget);
    await tester.tap(find.byTooltip('Weniger'));
    await tester.pumpAndSettle();
    expect(
      find.text('312,5 g').evaluate().isNotEmpty ||
          find.text('313 g').evaluate().isNotEmpty,
      isTrue,
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('budget: month totals and restricted audience', (tester) async {
    await open(tester, 'Finanzen');
    final now = DateTime.now();
    engine
      ..saveBudgetSettings(
        BudgetSettings(
          memberIds: [me.id],
          limits: const {'Lebensmittel': 30000},
        ),
      )
      ..saveBudgetEntry(
        BudgetEntry(
          id: 'b1',
          date: DateTime(now.year, now.month, 1),
          cents: 350000,
          category: 'Gehalt',
          income: true,
          monthly: true,
        ),
      )
      ..saveBudgetEntry(
        BudgetEntry(
          id: 'b2',
          date: DateTime(now.year, now.month, 2),
          cents: 32050,
          category: 'Lebensmittel',
          note: 'Wocheneinkauf',
        ),
      );
    await pumpData(tester);
    expect(find.text('3.500,00 €'), findsOneWidget);
    expect(find.text('3.179,50 €'), findsOneWidget);
    expect(find.text('320,50 € von 300,00 €'), findsOneWidget);
    expect(engine.record(Collections.budgetEntries, 'b2')?.visibleTo, [me.id]);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('timetable: fill in a lesson', (tester) async {
    await open(tester, 'Kinder');
    engine.saveChild(
      Child(id: 'k1', name: 'Lena', birthDate: DateTime(2019, 3, 4)),
    );
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stundenplan'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.plus).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Mathe');
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(engine.timetable('k1')!.lesson(1, 0)?.subject, 'Mathe');
    expect(find.text('Mathe'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('emergency page shows numbers, allergies and the doctor', (
    tester,
  ) async {
    await open(tester, 'Kinder');
    engine
      ..saveContact(
        const FamilyContact(
          id: 'd1',
          name: 'Dr. Sommer',
          role: ContactRole.pediatrician,
          phone: '040 123456',
        ),
      )
      ..saveChild(
        Child(
          id: 'k1',
          name: 'Lena',
          birthDate: DateTime(2022, 5, 1),
          emergency: const EmergencyInfo(
            allergies: 'Erdnüsse',
            doctorContactId: 'd1',
          ),
        ),
      )
      ..saveChildLog(
        ChildLog(
          id: 'l1',
          childId: 'k1',
          kind: LogKind.medication,
          start: DateTime.now().subtract(const Duration(hours: 2)),
          medication: 'Fiebersaft',
          dose: '5 ml',
        ),
      );
    await pumpData(tester);
    await tester.tap(find.text('Lena'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Notfall'));
    await tester.pumpAndSettle();
    expect(find.text('112 – Notruf'), findsOneWidget);
    expect(find.text('Giftnotruf'), findsOneWidget);
    expect(find.text('Erdnüsse'), findsOneWidget);
    expect(find.text('Dr. Sommer'), findsOneWidget);
    expect(find.textContaining('Fiebersaft · 5 ml'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('contacts are grouped by role', (tester) async {
    await open(tester, 'Kontakte');
    engine
      ..saveContact(
        const FamilyContact(
          id: 'c1',
          name: 'Kita Sonnenschein',
          role: ContactRole.daycare,
        ),
      )
      ..saveContact(
        const FamilyContact(
          id: 'c2',
          name: 'Oma Inge',
          role: ContactRole.family,
          phone: '0171 1',
        ),
      );
    await pumpData(tester);
    expect(find.text('Kita'), findsOneWidget);
    expect(find.text('Familie & Freunde'), findsOneWidget);
    expect(find.text('Oma Inge'), findsOneWidget);
    expect(find.byTooltip('Anrufen: 0171 1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  test('log reminders: latest feeding and next possible dose', () {
    final child = Child(
      id: 'k1',
      name: 'Lena',
      birthDate: DateTime(2026, 5, 1),
    );
    final t = DateTime(2026, 9, 27, 10);
    final reminders = logReminders(child, [
      ChildLog(
        id: 'b2',
        childId: 'k1',
        kind: LogKind.bottle,
        start: t,
        remindAt: t.add(const Duration(hours: 3)),
      ),
      ChildLog(
        id: 'm1',
        childId: 'k1',
        kind: LogKind.medication,
        start: t.subtract(const Duration(hours: 1)),
        medication: 'Fiebersaft',
        remindAt: t.add(const Duration(hours: 5)),
      ),
      ChildLog(
        id: 'b1',
        childId: 'k1',
        kind: LogKind.bottle,
        start: t.subtract(const Duration(hours: 3)),
        remindAt: t,
      ),
    ]);
    expect(reminders.map((r) => r.key), ['log:b2', 'log:m1']);
    expect(reminders.first.title, 'Nächste Mahlzeit für Lena');
  });

  test('family reminders cover check-ups and expiring documents', () {
    final store = LocalStore.open(':memory:');
    final e = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final now = DateTime(2026, 1, 1, 8);
    e
      ..saveChild(
        Child(
          id: 'k',
          name: 'Ben',
          birthDate: DateTime(2025, 10, 1),
          guardianIds: const ['m1'],
        ),
      )
      ..saveChild(
        Child(
          id: 'x',
          name: 'Fremd',
          birthDate: DateTime(2025, 10, 1),
          guardianIds: const ['m9'],
        ),
      )
      ..saveDocument(
        FamilyDocument(
          id: 'd',
          title: 'Personalausweis',
          category: DocumentCategory.identity,
          file: null,
          expiresAt: DateTime(2026, 1, 20),
        ),
      );
    final titles = [
      for (final r in familyReminders(
        e,
        from: now,
        to: now.add(const Duration(days: 14)),
      ))
        r.title,
    ];
    expect(titles, contains('Personalausweis läuft ab'));
    expect(titles.where((t) => t.contains('Fremd')), isEmpty);
  });
}
