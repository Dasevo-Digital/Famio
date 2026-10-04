import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/screens/pantry_screens.dart';
import 'package:famio/src/screens/pregnancy_screens.dart';
import 'package:famio/src/screens/timetable_view.dart';
import 'package:famio/src/widgets/data_builder.dart';
import 'package:famio/src/widgets/undo_delete.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Screen tests for the modules without their own widget tests so far:
/// meals, budget, pantry, medication, pregnancy and the timetable.

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

/// Change notifications arrive asynchronously: one pump delivers the event,
/// the next renders the rebuilt widgets.
Future<void> _pumpData(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;
  late AppState appState;

  /// Starts the app as Mama, optionally in [section].
  Future<void> open(WidgetTester tester, {String? section}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = appState = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    state
      ..me = engine.members.firstWhere((m) => m.id == 'm1')
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    if (section != null) {
      await tester.tap(find.text(section).first);
      await tester.pumpAndSettle();
    }
  }

  /// Opens [page] on top of the app, as the cards on the dashboard do.
  Future<void> push(WidgetTester tester, Widget page) async {
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pumpAndSettle();
  }

  Finder field(String label) =>
      find.widgetWithText(TextField, label, skipOffstage: false);

  group('budget', () {
    testWidgets('the first booking appears in the month', (tester) async {
      await open(tester, section: 'Finanzen');
      expect(find.text('Erste Buchung'), findsOneWidget);

      await tester.tap(find.text('Erste Buchung'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Betrag'), '12,50');
      await tester.enterText(field('Wofür? (optional)'), 'Wocheneinkauf');
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();

      final entry = engine.budgetEntries.single;
      expect(entry.cents, 1250);
      expect(entry.income, isFalse);
      expect(entry.memberId, 'm1');
      expect(find.text('Wocheneinkauf'), findsOneWidget);
      expect(find.text('Erste Buchung'), findsNothing);
    });

    testWidgets('a booking without an amount is refused', (tester) async {
      await open(tester, section: 'Finanzen');
      await tester.tap(find.text('Erste Buchung'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pump();
      expect(find.text('Bitte einen Betrag angeben'), findsOneWidget);
      expect(engine.budgetEntries, isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a restricted budget keeps its entries private', (
      tester,
    ) async {
      await open(tester, section: 'Finanzen');
      engine
        ..saveBudgetSettings(const BudgetSettings(memberIds: ['m1', 'm2']))
        ..saveBudgetEntry(
          BudgetEntry(
            id: 'b1',
            date: DateTime.now(),
            cents: 4200,
            category: 'Freizeit',
            note: 'Zoo',
          ),
        );
      await _pumpData(tester);
      expect(
        engine.record(Collections.budgetEntries, 'b1')!.visibleTo,
        unorderedEquals(['m1', 'm2']),
      );
      expect(find.textContaining('Sichtbar für: Mama, Papa'), findsOneWidget);

      // Edit and delete.
      await tester.tap(find.text('Zoo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Löschen'));
      await tester.pumpAndSettle();
      expect(engine.budgetEntries, isEmpty);
      expect(find.text('Erste Buchung'), findsOneWidget);
    });
  });

  group('medication', () {
    testWidgets('a new medication is health data for its carers', (
      tester,
    ) async {
      await open(tester, section: 'Medizin');
      expect(find.textContaining('Noch keine Medikamente'), findsOneWidget);

      await tester.tap(find.byTooltip('Medikament hinzufügen'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Medikament'), 'Fiebersaft');
      await tester.tap(find.text('Nur bei Bedarf'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Speichern'));
      await tester.pumpAndSettle();

      final med = engine.medications.single;
      expect(med.name, 'Fiebersaft');
      expect(med.asNeeded, isTrue);
      expect(engine.record(Collections.medications, med.id)!.visibleTo, ['m1']);
      expect(find.text('Fiebersaft'), findsWidgets);
    });

    testWidgets('taking an as-needed medication logs the intake', (
      tester,
    ) async {
      await open(tester, section: 'Medizin');
      engine.saveMedication(
        Medication(
          id: 'med',
          name: 'Nasenspray',
          start: DateTime(2026),
          asNeeded: true,
          careIds: const ['m1'],
        ),
      );
      await _pumpData(tester);
      await tester.tap(find.text('Jetzt genommen'));
      await _pumpData(tester);
      expect(engine.intakes('med'), hasLength(1));
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('meals', () {
    testWidgets('a recipe is written and opened', (tester) async {
      await open(tester, section: 'Essen');
      await tester.tap(find.text('Rezepte'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rezept hinzufügen').last);
      await tester.pumpAndSettle();

      await tester.enterText(field('Titel'), 'Pfannkuchen');
      await tester.enterText(
        field('Zutaten – eine pro Zeile'),
        '250 g Mehl\n3 Eier',
      );
      await tester.enterText(
        field('Zubereitung – ein Schritt pro Zeile'),
        'Verrühren\nBacken',
      );
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();

      final recipe = engine.recipes.single;
      expect(recipe.title, 'Pfannkuchen');
      expect(recipe.ingredients.map((i) => i.name), contains('Mehl'));

      await tester.tap(find.text('Pfannkuchen'));
      await tester.pumpAndSettle();
      expect(find.text('Zubereitung'), findsOneWidget);
      expect(find.textContaining('Verrühren'), findsOneWidget);
    });

    testWidgets('the week\'s ingredients go to the shopping list', (
      tester,
    ) async {
      await open(tester, section: 'Essen');
      final today = DateUtils.dateOnly(DateTime.now());
      engine
        ..saveRecipe(
          const Recipe(
            id: 'r1',
            title: 'Nudeln',
            servings: 2,
            ingredients: [
              Ingredient(name: 'Nudeln', amount: 500, unit: 'g'),
              Ingredient(name: 'Tomaten', amount: 4),
            ],
          ),
        )
        ..saveMeal(
          PlannedMeal(
            id: 'p1',
            date: today,
            slot: MealSlot.dinner,
            recipeId: 'r1',
          ),
        );
      await _pumpData(tester);
      expect(find.text('Nudeln'), findsWidgets);

      await tester.tap(find.text('Zutaten der Woche auf die Einkaufsliste'));
      await _pumpData(tester);
      final list = engine.shoppingLists.single;
      expect(
        engine.shoppingItems(list.id).map((i) => i.name),
        containsAll(['Nudeln', 'Tomaten']),
      );
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('pantry', () {
    testWidgets('an item is added and used up', (tester) async {
      await open(tester);
      await push(tester, const PantryScreen());
      expect(find.textContaining('Noch nichts erfasst'), findsOneWidget);

      await tester.tap(find.byTooltip('Artikel hinzufügen'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Artikel'), 'Milch');
      await tester.enterText(field('Menge'), '2');
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();

      expect(engine.pantryItems.single.name, 'Milch');
      expect(engine.pantryItems.single.amount, 2);
      await tester.tap(find.byTooltip('Eins weniger'));
      await _pumpData(tester);
      expect(engine.pantryItems.single.amount, 1);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('running low offers the shopping list', (tester) async {
      await open(tester);
      engine.savePantryItem(
        const PantryItem(id: 'p1', name: 'Kaffee', amount: 1, minAmount: 2),
      );
      await push(tester, const PantryScreen());
      expect(find.text('Wird knapp'), findsOneWidget);

      await tester.tap(find.text('Auf die Einkaufsliste'));
      await _pumpData(tester);
      final list = engine.shoppingLists.single;
      expect(engine.shoppingItems(list.id).single.name, 'Kaffee');
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('pregnancy', () {
    testWidgets('the week view and the contraction timer', (tester) async {
      await open(tester);
      engine.savePregnancy(
        Pregnancy(
          id: 'p1',
          dueDate: DateTime.now().add(const Duration(days: 100)),
          name: 'Krümel',
          guardianIds: const ['m1', 'm2'],
        ),
      );
      expect(
        engine.record(Collections.pregnancies, 'p1')!.visibleTo,
        unorderedEquals(['m1', 'm2']),
      );
      await push(tester, const PregnancyScreen(pregnancyId: 'p1'));
      expect(find.text('Krümel'), findsWidgets);
      expect(find.textContaining('noch 100 Tage'), findsOneWidget);
      expect(find.textContaining('Mutterschutz ab'), findsOneWidget);

      await tester.tap(find.text('Wehen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wehe beginnt'));
      await _pumpData(tester);
      expect(find.text('Wehe vorbei'), findsOneWidget);
      await tester.tap(find.text('Wehe vorbei'));
      await _pumpData(tester);
      expect(engine.pregnancy('p1')!.contractions, hasLength(1));
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('undo after deleting', () {
    testWidgets('a list with its items comes back as it was', (tester) async {
      await open(tester, section: 'Einkauf');
      engine
        ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Grillfest'))
        ..saveShoppingItem(
          const ShoppingItem(id: 'i1', listId: 'l1', name: 'Kohle'),
        )
        ..put(Collections.budgetEntries, 'b1', {
          ...BudgetEntry(
            id: 'b1',
            date: DateTime(2026, 10, 1),
            cents: 999,
            category: 'Freizeit',
          ).toData(),
          SyncRecord.visibilityKey: ['m1'],
          'ext:quelle': 'Bank',
        });
      // As in the app: from the page on screen.
      final context = tester.element(find.byTooltip('Neue Liste'));

      deleteWithUndo(
        context,
        what: 'Grillfest',
        collections: const {
          Collections.shoppingLists,
          Collections.shoppingItems,
        },
        delete: () => engine.deleteShoppingList('l1'),
      );
      await tester.pumpAndSettle();
      expect(engine.shoppingLists, isEmpty);
      expect(find.text('„Grillfest“ gelöscht'), findsOneWidget);
      await tester.tap(find.text('Rückgängig'));
      await tester.pump();
      expect(engine.shoppingLists.single.name, 'Grillfest');
      expect(engine.shoppingItems('l1').single.name, 'Kohle');

      // Visibility and fields from other apps come back too.
      deleteWithUndo(
        context,
        collections: const {Collections.budgetEntries},
        delete: () => engine.deleteBudgetEntry('b1'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rückgängig'));
      await tester.pump();
      final restored = engine.record(Collections.budgetEntries, 'b1')!;
      expect(restored.visibleTo, ['m1']);
      expect(restored.data['ext:quelle'], 'Bank');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a swiped away task can be brought back', (tester) async {
      await open(tester, section: 'Aufgaben');
      engine.saveTask(const Task(id: 't1', title: 'Müll rausbringen'));
      await _pumpData(tester);
      await tester.drag(find.text('Müll rausbringen'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(engine.tasks, isEmpty);
      expect(find.text('Rückgängig').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Rückgängig'));
      await _pumpData(tester);
      expect(engine.tasks.single.title, 'Müll rausbringen');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a swiped away shopping item can be brought back', (
      tester,
    ) async {
      await open(tester);
      engine
        ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'))
        ..saveShoppingItem(
          const ShoppingItem(id: 'i1', listId: 'l1', name: 'Milch'),
        );
      await tester.tap(find.text('Einkauf').first);
      await tester.pumpAndSettle();
      if (find.text('Milch').evaluate().isEmpty) {
        await tester.tap(find.text('Einkauf').last);
        await tester.pumpAndSettle();
      }
      await tester.drag(find.text('Milch'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(engine.shoppingItems('l1'), isEmpty);
      await tester.tap(find.text('Rückgängig'));
      await _pumpData(tester);
      expect(engine.shoppingItems('l1').single.name, 'Milch');
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('list connections', () {
    testWidgets('opened from tasks, hidden when the family switched it off', (
      tester,
    ) async {
      await open(tester, section: 'Aufgaben');
      await tester.tap(find.byTooltip('Mit anderen Apps verbinden'));
      await tester.pumpAndSettle();
      expect(find.text('Listen verbinden'), findsWidgets);
      expect(
        find.text('Apple Erinnerungen, Thunderbird & Co.'),
        findsOneWidget,
      );
      Navigator.of(tester.element(find.text('Listen verbinden').first)).pop();
      await tester.pumpAndSettle();

      appState.hiddenModules = {ServerSettings.listSyncModule};
      await tester.tap(find.text('Einkauf').first);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Mit anderen Apps verbinden'), findsNothing);
    });
  });

  group('timetable', () {
    testWidgets('a lesson is entered and cleared', (tester) async {
      await open(tester);
      final child = Child(id: 'c1', name: 'Emil', birthDate: DateTime(2018));
      engine.saveChild(child);
      await push(
        tester,
        Scaffold(
          body: DataBuilder(
            collections: const {Collections.timetables},
            builder: (context, _) => TimetableView(child: child),
          ),
        ),
      );

      await tester.tap(find.byIcon(AppIcons.plus).first);
      await tester.pumpAndSettle();
      expect(find.text('Mo, 1. Stunde'), findsOneWidget);
      await tester.enterText(field('Fach'), 'Mathe');
      await tester.enterText(field('Raum (optional)'), '204');
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();

      final lesson = engine.timetable('c1')!.lesson(1, 0)!;
      expect(lesson.subject, 'Mathe');
      expect(lesson.room, '204');
      expect(find.text('Mathe'), findsOneWidget);

      await tester.tap(find.text('Mathe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leeren'));
      await tester.pumpAndSettle();
      expect(engine.timetable('c1')!.lesson(1, 0), isNull);
      expect(find.text('Mathe'), findsNothing);
    });
  });
}
