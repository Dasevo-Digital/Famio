// The wall display hangs where everybody passes: confidential appointments
// show as busy there, in every view.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/kiosk_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
  late SyncEngine engine;

  Future<BuildContext> start(
    WidgetTester tester, {
    bool byPerson = false,
  }) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'kiosk.byPerson': byPerson});
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
    await tester.pumpAndSettle();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final soon = now.add(const Duration(hours: 1));
    engine
      ..saveEvent(
        CalendarEvent(
          id: 'e1',
          title: 'Psychotherapie',
          start: today,
          end: today.add(const Duration(days: 1)),
          allDay: true,
          confidential: true,
          memberIds: const ['m1'],
        ),
      )
      ..saveEvent(
        CalendarEvent(
          id: 'e2',
          title: 'Psychotherapie',
          start: soon,
          end: soon.add(const Duration(hours: 1)),
          confidential: true,
          memberIds: const ['m1'],
        ),
      );
    return tester.element(find.byType(Scaffold).first);
  }

  testWidgets('the board by person', (tester) async {
    final context = await start(tester, byPerson: true);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const KioskScreen()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Psychotherapie'), findsNothing);
    expect(find.textContaining('Belegt'), findsWidgets);
    Navigator.of(context).pop();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the topic panels', (tester) async {
    final context = await start(tester);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const KioskScreen()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Psychotherapie'), findsNothing);
    Navigator.of(context).pop();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the photo slideshow', (tester) async {
    final context = await start(tester);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: PhotoSlideshow(
            photos: const [
              FileRef(id: 'f1', name: 'a.jpg', mime: 'image/jpeg', size: 10),
            ],
            now: DateTime.now(),
            engine: engine,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Psychotherapie'), findsNothing);
    expect(find.textContaining('Belegt'), findsOneWidget);
    Navigator.of(context).pop();
    await tester.pump(const Duration(seconds: 3));
  });

  void saveRestricted() => engine
    ..saveTask(const Task(id: 't1', title: 'Müll rausbringen'))
    ..saveTask(
      const Task(id: 't2', title: 'Geschenk für Mia', visibleTo: ['m1', 'm2']),
    )
    ..saveShoppingList(
      const ShoppingList(id: 'l1', name: 'Überraschung', visibleTo: ['m1']),
    )
    ..saveShoppingItem(
      const ShoppingItem(id: 'i1', listId: 'l1', name: 'Luftballons'),
    )
    ..saveShoppingList(
      const ShoppingList(id: 'l2', name: 'Wocheneinkauf', sort: 1),
    )
    ..saveShoppingItem(
      const ShoppingItem(id: 'i2', listId: 'l2', name: 'Milch'),
    )
    ..saveDocument(
      const FamilyDocument(
        id: 'd1',
        title: 'Urlaub',
        category: DocumentCategory.photos,
        file: FileRef(id: 'f1', name: 'a.jpg', mime: 'image/jpeg', size: 10),
      ),
    )
    ..saveDocument(
      const FamilyDocument(
        id: 'd2',
        title: 'Privat',
        category: DocumentCategory.photos,
        file: FileRef(id: 'f2', name: 'b.jpg', mime: 'image/jpeg', size: 10),
        visibleTo: ['m1'],
      ),
    );

  for (final byPerson in [false, true]) {
    testWidgets(
      'only what the whole family sees (${byPerson ? 'board' : 'topics'})',
      (tester) async {
        final context = await start(tester, byPerson: byPerson);
        saveRestricted();
        expect(familyPhotos(engine).map((f) => f.id), ['f1']);
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const KioskScreen()));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        if (byPerson) {
          expect(find.textContaining('Müll rausbringen'), findsWidgets);
        } else {
          expect(find.textContaining('Milch'), findsWidgets);
        }
        for (final hidden in ['Geschenk', 'Luftballons', 'Überraschung']) {
          expect(find.textContaining(hidden), findsNothing, reason: hidden);
        }
        Navigator.of(context).pop();
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }

  for (final byPerson in [false, true]) {
    testWidgets(
      'appointments only some see are busy (${byPerson ? 'board' : 'topics'})',
      (tester) async {
        final context = await start(tester, byPerson: byPerson);
        final soon = DateTime.now().add(const Duration(hours: 1));
        engine.put(Collections.events, 'private', {
          ...CalendarEvent(
            id: 'private',
            title: 'Bewerbungsgespräch',
            start: soon,
            end: soon.add(const Duration(hours: 1)),
            memberIds: const ['m1'],
          ).toData(),
          SyncRecord.visibilityKey: ['m1'],
        });
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const KioskScreen()));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.textContaining('Bewerbungsgespräch'), findsNothing);
        expect(find.textContaining('Belegt'), findsWidgets);
        Navigator.of(context).pop();
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }
}
