import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/shopping_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

SyncEngine _engine(String memberId) => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: memberId,
);

final _trip = CalendarEvent(
  id: 'urlaub',
  title: 'Ostsee',
  start: DateTime(2026, 10, 20),
  end: DateTime(2026, 10, 27),
  allDay: true,
);

const _template = ListTemplate(
  id: 't',
  name: 'Urlaub',
  items: [
    TemplateItem('Ausweise', category: 'Dokumente'),
    TemplateItem('Badesachen', category: 'Kleidung'),
    TemplateItem('Kuscheltier', category: 'Kinder'),
  ],
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('each person gets their things, shared ones come once', () {
    final e = _engine('m1')..saveEvent(_trip);
    final id = e.packingListFor(_trip, _template, memberIds: ['m1', 'k1']);
    final list = e.shoppingList(id)!;
    expect((list.packing, list.eventId), (true, 'urlaub'));
    expect(e.packingListOf('urlaub')!.id, id);
    final items = [
      for (final i in e.shoppingItems(id)) '${i.name}:${i.memberId}',
    ]..sort();
    expect(items, [
      'Ausweise:null',
      'Badesachen:k1',
      'Badesachen:m1',
      'Kuscheltier:k1',
    ]);
    // Saved as a template, each thing comes once again.
    expect(
      e.templateFromList(list).items.map((i) => i.name),
      unorderedEquals(['Ausweise', 'Badesachen', 'Kuscheltier']),
    );
  });

  test('reminds the evening before, only while I still have to pack', () {
    final now = DateTime(2026, 10, 15, 12);
    final mama = _engine('m1')..saveEvent(_trip);
    final id = mama.packingListFor(_trip, _template, memberIds: ['m1', 'k1']);
    List<DueReminder> packing() => [
      for (final r in familyReminders(
        mama,
        from: now,
        to: now.add(const Duration(days: 14)),
      ))
        if (r.key.startsWith('pack:')) r,
    ];
    final r = packing().single;
    expect(r.at, DateTime(2026, 10, 19, 18));
    expect(r.title, '🧳 Morgen: Ostsee');
    // Ausweise (everyone's) and my Badesachen.
    expect(r.body, 'Noch 2 Sachen packen');
    for (final i in mama.shoppingItems(id)) {
      if (i.memberId != 'k1') mama.saveShoppingItem(i.copyWith(checked: true));
    }
    expect(packing(), isEmpty);
  });

  testWidgets('a packing list is grouped by person and filtered', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = _engine('m1')..saveEvent(_trip);
    final id = engine.packingListFor(_trip, _template, memberIds: ['m1', 'k1']);
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ShoppingListScreen(listId: id),
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('0 von 4 eingepackt'), findsOneWidget);
    expect(find.text('Für alle'), findsOneWidget);
    expect(find.text('Meine Sachen'), findsOneWidget);
    expect(find.text('Mia'), findsWidgets);
    // Only Mia's things (and everyone's).
    await tester.tap(find.widgetWithText(ChoiceChip, 'Mia'));
    await tester.pumpAndSettle();
    expect(find.text('0 von 3 eingepackt'), findsOneWidget);
    expect(find.text('Kuscheltier'), findsOneWidget);
    await tester.tap(find.text('Kuscheltier'));
    await tester.pumpAndSettle();
    expect(find.text('Eingepackt (1)'), findsOneWidget);
    // Lets the sync debounce run out.
    await tester.pump(const Duration(seconds: 1));
  });
}
