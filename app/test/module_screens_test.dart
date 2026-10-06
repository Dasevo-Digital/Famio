import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/screens/event_import_screen.dart';
import 'package:famio/src/screens/notes_screen.dart';
import 'package:famio/src/screens/pantry_screens.dart';
import 'package:famio/src/screens/pregnancy_screens.dart';
import 'package:famio/src/screens/push_settings_screen.dart';
import 'package:famio/src/screens/shopping_screens.dart';
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

  group('quiet hours', () {
    testWidgets('shows the saved time; offline a change is undone', (
      tester,
    ) async {
      await open(tester);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'quietHours',
        '{"enabled":true,"start":"22:00","end":"06:30","placesLoud":true}',
      );
      await push(
        tester,
        const Scaffold(body: SingleChildScrollView(child: QuietHoursCard())),
      );
      expect(find.text('ab 22:00 Uhr'), findsOneWidget);
      expect(find.text('bis 06:30 Uhr'), findsOneWidget);

      // Saving fails here (no server): the switch springs back.
      await tester.tap(find.text('Ortsmeldungen trotzdem laut'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(
                SwitchListTile,
                'Ortsmeldungen trotzdem laut',
              ),
            )
            .value,
        isTrue,
      );
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('appointments from text', () {
    testWidgets('pasted text becomes checked appointments', (tester) async {
      await open(tester);
      await push(tester, const EventImportScreen());
      final now = DateTime.now();
      final next = DateTime(now.year, now.month, now.day + 10);
      final after = DateTime(now.year, now.month, now.day + 11);
      await tester.enterText(
        find.widgetWithText(TextField, 'Oder Text hier einfügen'),
        'Elternabend am ${next.day}.${next.month}. um 19:30 Uhr\n'
        'Wandertag ${after.day}.${after.month}.',
      );
      await tester.tap(find.text('Termine suchen'));
      await tester.pumpAndSettle();
      expect(find.text('2 Termine übernehmen'), findsOneWidget);
      // Only the first one.
      await tester.tap(find.byType(Checkbox).last);
      await tester.pump();
      await tester.tap(find.text('1 Termin übernehmen'));
      await tester.pumpAndSettle();
      final event = engine.events.single;
      expect(event.title, 'Elternabend');
      expect(
        (event.start.hour, event.start.minute, event.allDay),
        (19, 30, false),
      );
    });
  });

  group('pinboard', () {
    testWidgets('a pinned note shows on the start page', (tester) async {
      await open(tester);
      await push(tester, const NotesScreen());
      await tester.tap(find.byTooltip('Notiz anlegen'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Titel'),
        'WLAN für Gäste',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Text'),
        'Famio-Gast / sonnenblume42',
      );
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(engine.notes.single.pinned, isTrue);
      expect(engine.notes.single.visibleTo, isNull);
      expect(find.text('WLAN für Gäste'), findsOneWidget);
      Navigator.of(tester.element(find.text('Pinnwand').first)).pop();
      await tester.pumpAndSettle();
      expect(
        find.text('WLAN für Gäste: Famio-Gast / sonnenblume42'),
        findsOneWidget,
      );
    });
  });

  group('task checklists', () {
    testWidgets('progress in the list, steps ticked in the editor', (
      tester,
    ) async {
      await open(tester, section: 'Aufgaben');
      engine.saveTask(
        const Task(
          id: 't1',
          title: 'Freibad',
          checklist: [
            TaskStep(id: 'a', text: 'Badesachen', done: true),
            TaskStep(id: 'b', text: 'Sonnencreme'),
          ],
        ),
      );
      await _pumpData(tester);
      expect(find.textContaining('☑ 1/2'), findsOneWidget);
      await tester.tap(find.text('Freibad'));
      await tester.pumpAndSettle();
      expect(find.text('Checkliste (1/2)'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).last);
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Punkt hinzufügen, z. B. Sonnencreme'),
        'Handtuch',
      );
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      final task = engine.tasks.single;
      expect(
        [for (final s in task.checklist) (s.text, s.done)],
        [('Badesachen', true), ('Sonnencreme', true), ('Handtuch', false)],
      );
    });
  });

  group('shopping aisles', () {
    testWidgets('new items find their aisle; corrections are remembered', (
      tester,
    ) async {
      await open(tester);
      engine.saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'));
      await push(tester, const ShoppingListScreen(listId: 'l1'));
      for (final text in ['Vollmilch', '3 Äpfel', 'Hafermilch']) {
        await tester.enterText(find.byType(TextField).first, text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _pumpData(tester);
      }
      await tester.pumpAndSettle();
      final produce = tester.getTopLeft(find.text('Obst & Gemüse'));
      final dairy = tester.getTopLeft(find.text('Kühlregal'));
      expect(produce.dy, lessThan(dairy.dy), reason: 'store order');
      final apples = engine
          .shoppingItems('l1')
          .firstWhere((i) => i.name == 'Äpfel');
      expect((apples.quantity, apples.category), ('3', 'produce'));

      // Hafermilch belongs to the drinks in this family.
      final oat = engine
          .shoppingItems('l1')
          .firstWhere((i) => i.name == 'Hafermilch');
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Hafermilch'),
            matching: find.byType(SoftCard),
          ),
          matching: find.byTooltip('Bearbeiten'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kühlregal').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Getränke').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      // Still known after the list was cleared.
      engine.deleteShoppingItem(oat.id);
      await _pumpData(tester);
      await tester.enterText(find.byType(TextField).first, 'hafermilch');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _pumpData(tester);
      expect(
        engine
            .shoppingItems('l1')
            .firstWhere((i) => i.name == 'hafermilch')
            .category,
        'drinks',
      );
      await tester.pump(const Duration(seconds: 5));
    });
  });

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

    testWidgets('the undo message goes away by itself', (tester) async {
      await open(tester, section: 'Aufgaben');
      engine.saveTask(const Task(id: 't1', title: 'Müll rausbringen'));
      await _pumpData(tester);
      await tester.drag(find.text('Müll rausbringen'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('Rückgängig'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Rückgängig'), findsNothing);
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

  group('repeating tasks', () {
    testWidgets('ticking one off moves it to the next date', (tester) async {
      await open(tester, section: 'Aufgaben');
      final today = DateUtils.dateOnly(DateTime.now());
      engine.saveTask(
        Task(
          id: 't1',
          title: 'Gelbe Tonne',
          due: today,
          repeat: TaskRepeat.weekly,
          repeatEvery: 2,
        ),
      );
      await _pumpData(tester);
      expect(find.textContaining('alle 2 Wochen'), findsOneWidget);

      await tester.tap(find.byType(RoundCheck).first);
      await tester.pumpAndSettle();
      final next = engine.tasks.single;
      expect(next.done, isFalse);
      expect(next.due, today.add(const Duration(days: 14)));
      expect(find.textContaining('wieder fällig'), findsOneWidget);

      await tester.tap(find.text('Rückgängig'));
      await _pumpData(tester);
      expect(engine.tasks.single.due, today);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('search', () {
    testWidgets('finds a task from the start page and opens it', (
      tester,
    ) async {
      await open(tester);
      engine.saveTask(const Task(id: 't1', title: 'Müll rausbringen'));
      await _pumpData(tester);
      await tester.tap(find.byTooltip('Suchen'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'muell');
      await tester.pumpAndSettle();
      expect(find.text('Müll rausbringen'), findsOneWidget);
      await tester.tap(find.text('Müll rausbringen'));
      await tester.pumpAndSettle();
      expect(find.text('Aufgabe bearbeiten'), findsOneWidget);
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
