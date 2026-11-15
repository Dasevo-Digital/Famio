import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/deadlines.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/contacts_screens.dart';
import 'package:famio/src/screens/deadlines_screen.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio/src/screens/meals_screens.dart';
import 'package:famio/src/screens/pantry_screens.dart';
import 'package:famio/src/screens/shopping_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"},'
    '{"id":"g1","username":"oma","displayName":"Oma","role":"guest"}]';

/// What the app offers depends on the role: what the server undoes after
/// the next sync without a word is not offered at all (#537, #539).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Future<SyncEngine> open(
    WidgetTester tester,
    String memberId,
    Widget page, {
    void Function(SyncEngine engine)? seed,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: memberId,
    );
    seed?.call(engine);
    state
      ..me = engine.members.firstWhere((m) => m.id == memberId)
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    Navigator.of(
      tester.element(find.byType(Scaffold).first),
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pumpAndSettle();
    return engine;
  }

  void lists(SyncEngine engine) {
    engine
      ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Wocheneinkauf'))
      ..saveShoppingItem(
        const ShoppingItem(id: 'i1', listId: 'l1', name: 'Milch'),
      )
      ..saveShoppingItem(
        const ShoppingItem(id: 'i2', listId: 'l1', name: 'Brot'),
      );
  }

  Future<List<String>> menuOf(WidgetTester tester) async {
    await tester.tap(find.byTooltip(tr.navMore).last);
    await tester.pumpAndSettle();
    final entries = [
      for (final item in tester.widgetList<PopupMenuItem<String>>(
        find.byType(PopupMenuItem<String>),
      ))
        if (item.child case final Text text) text.data!,
    ];
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    return entries;
  }

  group('a guest on the shopping lists (ALL-130)', () {
    testWidgets('makes no lists and changes none', (tester) async {
      await open(tester, 'g1', const ShoppingListsScreen(), seed: lists);
      expect(find.text('Wocheneinkauf'), findsOneWidget);
      expect(find.byTooltip(tr.shoppingNewList), findsNothing);
      expect(find.byTooltip(tr.shoppingListTemplate), findsNothing);
      await tester.tap(find.text('Wocheneinkauf'));
      await tester.pumpAndSettle();
      // Adding items stays.
      expect(find.byTooltip(tr.commonAdd), findsOneWidget);
      final menu = await menuOf(tester);
      expect(menu, isNot(contains(tr.commonRename)));
      expect(menu, isNot(contains(tr.shoppingDeleteList)));
      expect(menu, isNot(contains(tr.shoppingWhoSees)));
      expect(menu, isNot(contains(tr.shoppingSaveTemplate)));
    });

    testWidgets('adults still manage them', (tester) async {
      await open(tester, 'm1', const ShoppingListsScreen(), seed: lists);
      expect(find.byTooltip(tr.shoppingNewList), findsOneWidget);
      await tester.tap(find.text('Wocheneinkauf'));
      await tester.pumpAndSettle();
      final menu = await menuOf(tester);
      expect(menu, containsAll([tr.commonRename, tr.shoppingDeleteList]));
    });

    test('deleting a list as a guest loses no item', () {
      final guest = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: FamioApiClient('localhost:1'),
        memberId: 'g1',
      );
      lists(guest);
      expect(guest.deleteShoppingList('l1'), isFalse);
      expect(guest.shoppingList('l1'), isNotNull);
      expect(guest.shoppingItems('l1'), hasLength(2));
      final adult = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: FamioApiClient('localhost:1'),
        memberId: 'm1',
      );
      lists(adult);
      expect(adult.deleteShoppingList('l1'), isTrue);
      expect(adult.shoppingList('l1'), isNull);
      expect(adult.shoppingItems('l1'), isEmpty);
    });
  });

  testWidgets('a guest calls contacts but does not edit them (ALL-179)', (
    tester,
  ) async {
    await open(
      tester,
      'g1',
      const ContactsScreen(),
      seed: (e) => e.saveContact(
        const FamilyContact(id: 'c1', name: 'Kinderarzt', phone: '030 1234'),
      ),
    );
    expect(find.text('Kinderarzt'), findsOneWidget);
    expect(find.byTooltip(tr.contactsAdd), findsNothing);
    await tester.tap(find.text('Kinderarzt'));
    await tester.pumpAndSettle();
    expect(find.text(tr.commonSave), findsNothing, reason: 'no editor');
    expect(find.byTooltip(tr.contactsCallPhone('030 1234')), findsOneWidget);
  });

  group('a guest and the meals (HAU-151)', () {
    void meals(SyncEngine e) {
      final today = DateUtils.dateOnly(DateTime.now());
      e
        ..saveRecipe(
          const Recipe(id: 'r1', title: 'Lasagne', steps: 'Schichten'),
        )
        ..saveMeal(
          PlannedMeal(
            id: 'p1',
            date: today,
            slot: MealSlot.dinner,
            title: 'Pizza',
          ),
        )
        ..savePantryItem(const PantryItem(id: 'v1', name: 'Nudeln', amount: 2));
    }

    testWidgets('reads the plan without planning', (tester) async {
      await open(tester, 'g1', const MealsScreen(), seed: meals);
      expect(find.text('Pizza'), findsOneWidget);
      expect(find.byTooltip(tr.mealsPlanMeal), findsNothing);
      expect(find.byTooltip(tr.commonChange), findsNothing);
      expect(find.text(tr.mealsSuggestWeek), findsNothing);
      await tester.tap(find.text('Pizza'));
      await tester.pumpAndSettle();
      expect(find.text(tr.commonSave), findsNothing, reason: 'no editor');
    });

    testWidgets('reads a recipe without changing it', (tester) async {
      await open(tester, 'g1', const RecipeScreen(recipeId: 'r1'), seed: meals);
      expect(find.text('Lasagne'), findsWidgets);
      expect(find.byTooltip(tr.commonEdit), findsNothing);
      expect(find.byTooltip(tr.mealsFavorite), findsNothing);
      expect(find.text(tr.mealsSchedule), findsNothing);
      expect(find.text(tr.mealsCookingMode), findsOneWidget);
    });

    testWidgets('sees the pantry without counting', (tester) async {
      await open(tester, 'g1', const PantryScreen(), seed: meals);
      expect(find.text('Nudeln'), findsOneWidget);
      expect(find.byTooltip(tr.pantryOneMore), findsNothing);
      expect(find.byTooltip(tr.pantryOneLess), findsNothing);
      expect(find.byTooltip(tr.pantryAddItem), findsNothing);
    });

    testWidgets('adults plan and count', (tester) async {
      await open(tester, 'm1', const PantryScreen(), seed: meals);
      expect(find.byTooltip(tr.pantryOneMore), findsOneWidget);
      expect(find.byTooltip(tr.pantryAddItem), findsOneWidget);
    });
  });

  group('deadlines are for adults (ALL-201)', () {
    void deadline(SyncEngine e) => e.saveDeadline(
      Deadline(
        id: 'd1',
        title: 'Zahnarzt-Termin machen',
        due: DateUtils.addDaysToDate(DateTime.now(), 3),
        assigneeId: 'k1',
      ),
    );

    testWidgets('a child in charge gets no "Erledigt"', (tester) async {
      await open(tester, 'k1', const DeadlinesScreen(), seed: deadline);
      expect(find.text('Zahnarzt-Termin machen'), findsOneWidget);
      expect(find.text(tr.commonDoneCap), findsNothing);
    });

    testWidgets('children are not offered as the one in charge', (
      tester,
    ) async {
      await open(tester, 'm1', const DeadlinesScreen());
      expect(find.text(tr.commonDoneCap), findsNothing);
      await tester.tap(find.byTooltip(tr.deadlinesAddDeadline));
      await tester.pumpAndSettle();
      final who = find.widgetWithText(
        DropdownButtonFormField<String?>,
        tr.tasksWhoTakesCare,
      );
      await tester.ensureVisible(who);
      await tester.pumpAndSettle();
      await tester.tap(who);
      await tester.pumpAndSettle();
      expect(find.text('Papa'), findsWidgets);
      expect(find.text('Mia'), findsNothing);
      expect(find.text('Oma'), findsNothing);
    });
  });

  group('documents (HAU-157, HAU-115)', () {
    const file = FileRef(
      id: 'f1',
      name: 'befund.pdf',
      mime: 'application/pdf',
      size: 4,
    );

    RadioListTile<Object?> tile(WidgetTester tester, String title) =>
        tester.widget<RadioListTile<Object?>>(
          find.ancestor(
            of: find.text(title),
            matching: find.byWidgetPredicate((w) => w is RadioListTile),
          ),
        );

    Object? chosen(WidgetTester tester) => tester
        .widget<RadioGroup<Object?>>(
          find.byWidgetPredicate((w) => w is RadioGroup),
        )
        .groupValue;

    testWidgets('a child files health only for chosen people', (tester) async {
      final engine = await open(
        tester,
        'k1',
        const DocumentEditor(existing: null, category: DocumentCategory.health),
      );
      expect(engine.myRole, MemberRole.child);
      await tester.ensureVisible(find.text(tr.commonWholeFamily));
      expect(tile(tester, tr.commonWholeFamily).enabled, isFalse);
      expect(find.text(tr.docsChildHealthAudience), findsOneWidget);
      // Choosing the family first and then health does not keep it.
      await tester.ensureVisible(find.text(DocumentCategory.school.label));
      await tester.tap(find.text(DocumentCategory.school.label));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(tr.commonWholeFamily));
      await tester.tap(find.text(tr.commonWholeFamily));
      await tester.pumpAndSettle();
      expect(tile(tester, tr.commonWholeFamily).enabled, isTrue);
      await tester.ensureVisible(find.text(DocumentCategory.health.label));
      await tester.tap(find.text(DocumentCategory.health.label));
      await tester.pumpAndSettle();
      expect(chosen(tester), isNot(tile(tester, tr.commonWholeFamily).value));
      expect(chosen(tester), tile(tester, tr.docsOnlyMe).value);
    });

    testWidgets('an only-me document opens as only me', (tester) async {
      await open(
        tester,
        'm1',
        const DocumentEditor(
          existing: FamilyDocument(
            id: 'doc1',
            title: 'Befund',
            category: DocumentCategory.health,
            file: file,
            visibleTo: ['m1'],
          ),
        ),
      );
      await tester.ensureVisible(find.text(tr.docsOnlyMe));
      expect(chosen(tester), tile(tester, tr.docsOnlyMe).value);
    });

    testWidgets('a shared one still opens as chosen people', (tester) async {
      await open(
        tester,
        'm1',
        const DocumentEditor(
          existing: FamilyDocument(
            id: 'doc2',
            title: 'Befund',
            category: DocumentCategory.health,
            file: file,
            visibleTo: ['m1', 'm2'],
          ),
        ),
      );
      await tester.ensureVisible(find.text(tr.docsMe));
      expect(chosen(tester), tile(tester, tr.docsMe).value);
    });
  });

  test('who may change what', () {
    SyncEngine as(String id) => SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: id,
    );
    expect(as('g1').mayWrite(Collections.shoppingItems), isTrue);
    expect(as('g1').mayWrite(Collections.tasks), isTrue);
    expect(as('g1').mayWrite(Collections.shoppingLists), isFalse);
    expect(as('g1').mayWrite(Collections.contacts), isFalse);
    expect(as('k1').mayWrite(Collections.deadlines), isFalse);
    expect(as('k1').mayWrite(Collections.documents), isTrue);
    expect(as('m1').mayWrite(Collections.deadlines), isTrue);
  });
}
