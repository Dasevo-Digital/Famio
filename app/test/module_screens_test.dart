import 'dart:async';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/shopping_history.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/screens/chores_screens.dart';
import 'package:famio/src/screens/event_editor.dart';
import 'package:famio/src/screens/event_import_screen.dart';
import 'package:famio/src/screens/notes_screen.dart';
import 'package:famio/src/screens/pantry_screens.dart';
import 'package:famio/src/screens/pregnancy_screens.dart';
import 'package:famio/src/screens/push_settings_screen.dart';
import 'package:famio/src/screens/member_emergency_screen.dart';
import 'package:famio/src/screens/settings_screen.dart';
import 'package:famio/src/screens/shopping_screens.dart';
import 'package:famio/src/screens/timetable_view.dart';
import 'package:famio/src/screens/wishes_screen.dart';
import 'package:famio/src/widgets/data_builder.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio/src/data/ocr.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio/src/widgets/undo_delete.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Whether [text] shows up anywhere while scrolling through the last list
/// (lists build only what is on screen).
Future<bool> _seenWhileScrolling(WidgetTester tester, String text) async {
  final list = find.byType(Scrollable).last;
  for (var i = 0; i < 30; i++) {
    if (find.text(text).evaluate().isNotEmpty) return true;
    await tester.drag(list, const Offset(0, -300));
    await tester.pump();
  }
  return false;
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

  group('wish lists', () {
    testWidgets('a claim is hidden from the one who wishes', (tester) async {
      await open(tester);
      engine.saveWish(
        Wish(
          id: 'w1',
          ownerId: 'k1',
          title: 'Fahrrad',
          createdAt: DateTime(2026),
        ),
      );
      await push(tester, const WishesScreen(memberId: 'k1'));
      expect(find.text('Fahrrad'), findsOneWidget);
      await tester.tap(find.text('Ich besorge das'));
      await _pumpData(tester);
      final claim = engine.record(Collections.wishClaims, 'w1')!;
      expect(claim.visibleTo, unorderedEquals(['m1', 'm2']));
      expect(find.text('Du besorgst das'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('lifts', () {
    testWidgets('who brings and who picks up', (tester) async {
      await open(tester);
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day + 1, 17);
      engine.saveEvent(
        CalendarEvent(
          id: 'e1',
          title: 'Training',
          start: start,
          end: start.add(const Duration(hours: 1)),
        ),
      );
      await _pumpData(tester);
      final context = tester.element(find.byType(Scaffold).first);
      showEventEditor(
        context,
        occurrence: engine
            .occurrences(start, start.add(const Duration(hours: 1)))
            .single,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Wer fährt?'));
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String?>, 'Bringt'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Papa').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      final e = engine.events.single;
      expect((e.bringerId, e.pickerId), ('m2', null));
      expect(engine.liftsLabel(e), '🚗 Papa bringt');
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
      // The editor is longer than the screen.
      await tester.ensureVisible(find.text('Speichern'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      final task = engine.tasks.single;
      expect(
        [for (final s in task.checklist) (s.text, s.done)],
        [('Badesachen', true), ('Sonnencreme', true), ('Handtuch', false)],
      );
    });
  });

  group('task people', () {
    testWidgets('several take care of a task, only they and I see it', (
      tester,
    ) async {
      await open(tester, section: 'Aufgaben');
      engine.saveTask(const Task(id: 't1', title: 'Garage aufräumen'));
      await _pumpData(tester);
      await tester.tap(find.text('Garage aufräumen'));
      await tester.pumpAndSettle();
      Finder chip(String name) => find.widgetWithText(FilterChip, name).first;
      for (final name in ['Papa', 'Mia']) {
        await tester.ensureVisible(chip(name));
        await tester.tap(chip(name));
        await tester.pump();
      }
      // Checklist, files and visibility are folded away for a plain task.
      expect(find.text('Nur ich'), findsNothing);
      await tester.ensureVisible(
        find.text('Checkliste, Dateien, Sichtbarkeit'),
      );
      await tester.tap(find.text('Checkliste, Dateien, Sichtbarkeit'));
      await tester.pump();
      await tester.ensureVisible(find.text('Nur ich'));
      await tester.tap(find.text('Nur ich'));
      await tester.pump();
      expect(find.textContaining('sieht die Aufgabe immer'), findsOneWidget);
      await tester.ensureVisible(find.text('Speichern'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      final task = engine.tasks.single;
      expect(task.assigneeIds, ['m2', 'k1']);
      expect(task.visibleTo, unorderedEquals(['m1', 'm2', 'k1']));
      // Both on the card, with the lock.
      expect(find.byTooltip('Papa'), findsOneWidget);
      expect(find.byTooltip('Mia'), findsOneWidget);
      expect(find.byTooltip('Sichtbar für: Mama, Papa, Mia'), findsOneWidget);

      // Opened again: "Only me" is still chosen; back to the family.
      await tester.tap(find.text('Garage aufräumen'));
      await tester.pumpAndSettle();
      final onlyMe = tester.widget<RadioGroup<Object?>>(
        find.byWidgetPredicate((w) => w is RadioGroup),
      );
      expect('${onlyMe.groupValue}', endsWith('.me'));
      await tester.ensureVisible(find.text('Ganze Familie (ohne Gäste)'));
      await tester.tap(find.text('Ganze Familie (ohne Gäste)'));
      await tester.pump();
      await tester.ensureVisible(find.text('Speichern'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(engine.tasks.single.visibleTo, isNull);
      expect(engine.tasks.single.assigneeIds, ['m2', 'k1']);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('task photos', () {
    testWidgets('photos and files show in the list and can be taken off', (
      tester,
    ) async {
      await open(tester, section: 'Aufgaben');
      engine.saveTask(
        const Task(
          id: 't1',
          title: 'Regal aufbauen',
          photos: [
            FileRef(id: 'f1', name: 'regal.jpg', mime: 'image/jpeg', size: 9),
            FileRef(
              id: 'f2',
              name: 'Anleitung.pdf',
              mime: 'application/pdf',
              size: 9,
            ),
          ],
        ),
      );
      await _pumpData(tester);
      // The photo as thumbnail, the PDF counted.
      expect(find.byType(CachedImage), findsOneWidget);
      expect(find.textContaining('📎 1'), findsOneWidget);
      await tester.tap(find.text('Regal aufbauen'));
      await tester.pumpAndSettle();
      expect(find.text('Fotos und Dateien'), findsOneWidget);
      expect(find.text('Anleitung.pdf'), findsOneWidget);
      expect(find.byTooltip('Foto oder Datei anhängen'), findsOneWidget);
      await tester.tap(find.byTooltip('Anhang entfernen').first);
      await tester.pump();
      // The editor is longer than the screen.
      await tester.ensureVisible(find.text('Speichern'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(
        [for (final f in engine.tasks.single.photos) f.name],
        ['Anleitung.pdf'],
      );
      expect(find.byType(CachedImage), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('memories', () {
    testWidgets('a year ago today on the start page, hidden until tomorrow', (
      tester,
    ) async {
      await open(tester);
      final today = DateTime.now();
      engine
        ..saveChild(Child(id: 'k', name: 'Mia', birthDate: DateTime(2023)))
        ..saveChildEntry(
          ChildEntry(
            id: 'm',
            childId: 'k',
            kind: ChildEntryKind.milestone,
            date: DateTime(today.year - 1, today.month, today.day),
            title: 'Erste Schritte',
          ),
        );
      await _pumpData(tester);
      await tester.pumpAndSettle();
      expect(find.text('Heute vor einem Jahr'), findsOneWidget);
      expect(find.text('Mia: Erste Schritte'), findsOneWidget);

      await tester.tap(find.text('Für heute ausblenden'));
      await tester.pumpAndSettle();
      expect(find.text('Heute vor einem Jahr'), findsNothing);
      expect(appState.memoriesHiddenOn, isNotNull);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('shopping history', () {
    testWidgets('ticked items come back as suggestions and staples', (
      tester,
    ) async {
      await open(tester);
      engine
        ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'))
        ..saveShoppingItem(
          const ShoppingItem(
            id: 'a',
            listId: 'l1',
            name: 'Milch',
            quantity: '2 l',
          ),
        );
      await push(tester, const ShoppingListScreen(listId: 'l1'));
      expect(find.text('Oft gekauft:'), findsNothing);

      await tester.tap(find.text('Milch'));
      await _pumpData(tester);
      engine.deleteShoppingItem('a');
      await _pumpData(tester);
      expect(engine.boughtItem('milch')!.count, 1);
      expect(find.text('Oft gekauft:'), findsOneWidget);

      // One tap puts it back, with the amount of last time.
      await tester.tap(find.widgetWithText(ActionChip, 'Milch'));
      await _pumpData(tester);
      final again = engine.shoppingItems('l1').single;
      expect((again.name, again.quantity), ('Milch', '2 l'));
      expect(find.widgetWithText(ActionChip, 'Milch'), findsNothing);

      // A rhythm makes it a staple.
      await tester.tap(find.byTooltip('Mehr'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stammartikel'));
      await tester.pumpAndSettle();
      expect(find.text('1-mal gekauft'), findsOneWidget);
      await tester.tap(find.text('Kein Rhythmus'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('alle 2 Wochen').last);
      await tester.pumpAndSettle();
      expect(engine.boughtItem('milch')!.everyDays, 14);
      expect(find.textContaining('wieder am'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('purchase into the budget', () {
    Future<void> openCart(WidgetTester tester) async {
      engine
        ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Wocheneinkauf'))
        ..saveShoppingItem(
          const ShoppingItem(
            id: 'a',
            listId: 'l1',
            name: 'Milch',
            checked: true,
          ),
        )
        ..saveShoppingItem(
          const ShoppingItem(
            id: 'b',
            listId: 'l1',
            name: 'Brot',
            checked: true,
          ),
        )
        ..saveShoppingItem(
          const ShoppingItem(id: 'c', listId: 'l1', name: 'Käse'),
        );
      await push(tester, const ShoppingListScreen(listId: 'l1'));
    }

    testWidgets('the receipt as groceries, the cart emptied, undone', (
      tester,
    ) async {
      await open(tester);
      await openCart(tester);
      await tester.tap(find.text('Bezahlt? Betrag ins Haushaltsbuch'));
      await tester.pumpAndSettle();
      expect(find.text('Einkauf ins Haushaltsbuch'), findsOneWidget);
      expect(
        find.text('Die 2 abgehakten Sachen von der Liste nehmen'),
        findsOneWidget,
      );
      await tester.tap(find.text('Eintragen'));
      await tester.pumpAndSettle();
      expect(find.text('Bitte einen Betrag angeben'), findsOneWidget);

      await tester.enterText(field('Betrag laut Kassenbon'), '23,45');
      await tester.tap(find.text('Eintragen'));
      await tester.pumpAndSettle();
      final entry = engine.budgetEntries.single;
      expect(
        (entry.cents, entry.category, entry.note, entry.income, entry.memberId),
        (2345, 'Lebensmittel', 'Wocheneinkauf', false, 'm1'),
      );
      expect(entry.date, DateUtils.dateOnly(DateTime.now()));
      expect(engine.shoppingItems('l1').map((i) => i.name), ['Käse']);
      expect(
        find.text('23,45 € als Ausgabe für Lebensmittel eingetragen.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Rückgängig'));
      await _pumpData(tester);
      expect(engine.budgetEntries, isEmpty);
      expect(
        engine.shoppingItems('l1').map((i) => i.name),
        unorderedEquals(['Milch', 'Brot', 'Käse']),
      );
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('only for those who see the budget', (tester) async {
      await open(tester);
      engine.saveBudgetSettings(const BudgetSettings(memberIds: ['m2']));
      await openCart(tester);
      expect(find.text('Bezahlt? Betrag ins Haushaltsbuch'), findsNothing);
      engine.saveBudgetSettings(const BudgetSettings(memberIds: ['m1', 'm2']));
      await _pumpData(tester);
      expect(find.text('Bezahlt? Betrag ins Haushaltsbuch'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
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

    testWidgets('the week suggested from the favourites', (tester) async {
      await open(tester, section: 'Essen');
      final today = DateUtils.dateOnly(DateTime.now());
      engine
        ..savePantryItem(const PantryItem(id: 'reis', name: 'Reis', amount: 1))
        ..saveRecipe(
          const Recipe(
            id: 'curry',
            title: 'Curry',
            favorite: true,
            ingredients: [
              Ingredient(name: 'Reis'),
              Ingredient(name: 'Kokosmilch'),
            ],
          ),
        )
        ..saveRecipe(const Recipe(id: 'pizza', title: 'Pizza', favorite: true))
        ..saveMeal(
          PlannedMeal(
            id: 'p1',
            date: today.subtract(const Duration(days: 7)),
            slot: MealSlot.dinner,
            recipeId: 'pizza',
          ),
        );
      await _pumpData(tester);

      await tester.tap(find.text('Woche vorschlagen'));
      await tester.pumpAndSettle();
      expect(find.text('Vorschlag für die Woche'), findsOneWidget);
      // Today first; the pizza of last week is not suggested again.
      expect(find.text('Curry ★'), findsOneWidget);
      expect(find.text('1 von 2 Zutaten im Vorrat'), findsOneWidget);
      expect(find.textContaining('Pizza'), findsNothing);

      await tester.tap(find.text('1 einplanen'));
      await _pumpData(tester);
      // The snack bar slides in.
      await tester.pumpAndSettle();
      final planned = engine.plannedMeals(
        today,
        today.add(const Duration(days: 1)),
      );
      expect(planned.single.recipeId, 'curry');
      expect(planned.single.slot, MealSlot.dinner);
      expect(find.text('1 Essen eingeplant.'), findsOneWidget);

      // What the pantry lacks onto the shopping list.
      await tester.tap(find.text('Fehlendes einkaufen'));
      await _pumpData(tester);
      final list = engine.shoppingLists.single;
      expect(engine.shoppingItems(list.id).map((i) => i.name), ['Kokosmilch']);
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
      // Calendar days: 14 × 24 h miss a day across a DST change.
      expect(next.due, DateTime(today.year, today.month, today.day + 14));
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
      await tester.pump(const Duration(milliseconds: 300));
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

  group('documents', () {
    testWidgets('a new PDF is read for the search', (tester) async {
      await open(tester);
      Ocr.debugAvailable = true;
      addTearDown(() => Ocr.debugAvailable = null);
      const channel = MethodChannel('famio/ocr');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final asked = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        asked.add(call.method);
        return 'Ihre Versichertennummer lautet A123456789.';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final context = tester.element(find.byType(Scaffold).first);
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const DocumentEditor(
              picked: PickedFile(
                [37, 80, 68, 70],
                'brief.pdf',
                'application/pdf',
              ),
            ),
          ),
        ),
      );
      // The first frame of a new page is offstage.
      await tester.pump();
      await tester.pump();
      expect(find.text('Text wird erkannt …'), findsOneWidget);
      // The file is written for the recognition: that takes real time.
      final reading = find.text('Text wird erkannt …');
      for (var i = 0; i < 100 && reading.evaluate().isNotEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(asked, ['pdfText']);
      expect(find.textContaining('Text erkannt (42 Zeichen)'), findsOneWidget);
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
      // A Sunday's preview would otherwise also read just "Mathe".
      await tester.enterText(
        field('Mitbringen (zu jeder Stunde des Fachs)'),
        'Zirkel',
      );
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();

      final lesson = engine.timetable('c1')!.lesson(1, 0)!;
      expect(lesson.subject, 'Mathe');
      expect(lesson.room, '204');
      expect(engine.timetable('c1')!.bring, {'Mathe': 'Zirkel'});
      expect(find.text('Mathe'), findsOneWidget);

      final check = find.text('Schulranzen-Check am Vorabend');
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(engine.timetable('c1')!.bagCheck, '18:30');
      expect(find.textContaining('Um 18:30 erinnert Famio'), findsOneWidget);
      await tester.ensureVisible(find.text('Mathe'));

      await tester.tap(find.text('Mathe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leeren'));
      await tester.pumpAndSettle();
      expect(engine.timetable('c1')!.lesson(1, 0), isNull);
      expect(find.text('Mathe'), findsNothing);
    });
  });

  group('kids', () {
    testWidgets('a new child is for both parents; a private one says so', (
      tester,
    ) async {
      await open(tester, section: 'Kinder');
      // Nothing to see yet: the other parent may have added a child already.
      expect(find.textContaining('Fehlt ein Kind?'), findsOneWidget);

      await tester.tap(find.byTooltip('Kind oder Schwangerschaft hinzufügen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kind hinzufügen'));
      await tester.pumpAndSettle();
      final mia = find.widgetWithText(FilterChip, 'Mia');
      await tester.scrollUntilVisible(
        mia,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      bool selected(String name) => tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, name))
          .selected;
      expect(selected('Mama'), isTrue);
      expect(selected('Papa'), isTrue);
      expect(selected('Mia'), isFalse);
      Navigator.of(tester.element(mia)).pop();
      await tester.pumpAndSettle();

      // Only Mama sees Emil: the card tells her Papa does not.
      Child emil(List<String> guardians) => Child(
        id: 'c1',
        name: 'Emil',
        birthDate: DateTime(2024, 3, 1),
        guardianIds: guardians,
      );
      engine.saveChild(emil(['m1']));
      await _pumpData(tester);
      expect(find.text('Nur Mama'), findsOneWidget);
      expect(find.textContaining('Fehlt ein Kind?'), findsOneWidget);

      engine.saveChild(emil(['m1', 'm2']));
      await _pumpData(tester);
      expect(find.text('Emil'), findsOneWidget);
      expect(find.text('Nur Mama'), findsNothing);
      // Let the sync engine's retry timer run out.
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('settings', () {
    testWidgets('adults find the Ko-fi link, children do not', (tester) async {
      await open(tester);
      await push(tester, const SettingsScreen());
      expect(await _seenWhileScrolling(tester, 'Famio unterstützen'), isTrue);

      Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
      await tester.pumpAndSettle();
      appState.me = engine.members.firstWhere((m) => m.id == 'k1');
      await push(tester, const SettingsScreen());
      expect(await _seenWhileScrolling(tester, 'Famio unterstützen'), isFalse);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('emergency facts of adults', () {
    testWidgets('entered once, shown with the emergency numbers', (
      tester,
    ) async {
      await open(tester);
      await push(tester, const MemberEmergencyScreen(memberId: 'm1'));
      expect(find.text('Meine Notfall-Infos'), findsOneWidget);
      await tester.tap(find.text('Notfall-Infos eintragen'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Allergien'), 'Penicillin');
      await tester.enterText(
        field('Vollmacht und Patientenverfügung'),
        'Ordner im Arbeitszimmer',
      );
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      await _pumpData(tester);

      final saved = engine.memberEmergency('m1')!;
      expect(saved.info.allergies, 'Penicillin');
      expect(saved.documents, 'Ordner im Arbeitszimmer');
      expect(find.text('Penicillin'), findsOneWidget);
      expect(find.textContaining('112'), findsWidgets);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('in the settings for adults, not for children', (tester) async {
      await open(tester);
      await push(tester, const SettingsScreen());
      expect(await _seenWhileScrolling(tester, 'Meine Notfall-Infos'), isTrue);

      Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
      await tester.pumpAndSettle();
      appState.me = engine.members.firstWhere((m) => m.id == 'k1');
      await push(tester, const SettingsScreen());
      expect(await _seenWhileScrolling(tester, 'Meine Notfall-Infos'), isFalse);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('savings goals', () {
    testWidgets('saved towards, reached, bought', (tester) async {
      await open(tester);
      engine
        ..saveAllowance(
          Allowance(memberId: 'k1', weeklyCents: 500, since: DateTime(2026)),
        )
        ..saveMoneyEntry(
          MoneyEntry(
            id: 'm',
            memberId: 'k1',
            cents: 3000,
            at: DateTime.now(),
            kind: MoneyKind.gift,
          ),
        );
      await push(tester, const MemberAccountScreen(memberId: 'k1'));
      await tester.tap(find.text('Sparziel'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Wofür?'), 'Fahrrad');
      await tester.enterText(field('Wie viel?'), '120');
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      await _pumpData(tester);

      expect(find.text('Fahrrad'), findsOneWidget);
      expect(find.text('30,00 € von 120,00 €'), findsOneWidget);
      expect(find.textContaining('noch etwa 18 Wochen'), findsOneWidget);

      engine.saveMoneyEntry(
        MoneyEntry(
          id: 'oma',
          memberId: 'k1',
          cents: 9000,
          at: DateTime.now(),
          kind: MoneyKind.gift,
        ),
      );
      await _pumpData(tester);
      expect(find.text('Geschafft! 🎉'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Gekauft'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Gekauft').last);
      await tester.pumpAndSettle();
      await _pumpData(tester);
      expect(engine.savingsGoals('k1'), isEmpty);
      expect(engine.moneyBalance('k1'), 0);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
