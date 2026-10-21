import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/shopping_history.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

SyncEngine _engine() => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', '[]'),
  api: FamioApiClient('localhost:1'),
  memberId: 'm1',
);

ShoppingItem _item(
  String id,
  String name, {
  String list = 'l',
  String q = '',
}) => ShoppingItem(id: id, listId: list, name: name, quantity: q);

void main() {
  final now = DateTime(2026, 10, 20, 10);

  test('ticking off counts as bought, not on packing lists', () {
    final e = _engine()
      ..saveShoppingList(const ShoppingList(id: 'l', name: 'Einkauf'))
      ..saveShoppingList(
        const ShoppingList(id: 'p', name: 'Urlaub', packing: true),
      );
    e
      ..noteBought(_item('a', 'Milch', q: '2 l'), now: now)
      ..noteBought(_item('b', ' milch ', q: '1 l'), now: now)
      ..noteBought(_item('c', 'Sonnencreme', list: 'p'), now: now);
    final milk = e.boughtItem('milch')!;
    expect(
      (milk.name, milk.quantity, milk.count, milk.listId),
      ('milch', '1 l', 2, 'l'),
    );
    expect(e.boughtItem('sonnencreme'), isNull);
  });

  test('a list only some see stays out of the family history', () {
    final e = _engine()
      ..saveShoppingList(
        const ShoppingList(id: 'g', name: 'Geschenke', visibleTo: ['m1']),
      )
      ..noteBought(_item('a', 'Lego', list: 'g'), now: now);
    expect(e.boughtItem('lego'), isNull);
  });

  test(
    'suggestions: what matches, often and lately bought, not on the list',
    () {
      final e = _engine()
        ..saveShoppingList(const ShoppingList(id: 'l', name: 'Einkauf'));
      for (final (name, times, daysAgo) in [
        ('Milch', 10, 2),
        ('Mehl', 3, 1),
        ('Hafermilch', 4, 3),
        ('Brot', 30, 400),
        ('Eier', 5, 5),
      ]) {
        e.saveBoughtItem(
          BoughtItem(
            key: name.toLowerCase(),
            name: name,
            count: times,
            lastBought: now.subtract(Duration(days: daysAgo)),
          ),
        );
      }
      e.saveShoppingItem(_item('x', 'Eier'));
      List<String> names(String typed) => [
        for (final b in e.shoppingSuggestions('l', typed: typed, now: now))
          b.name,
      ];
      // Eier are on the list; Brot was bought long ago.
      expect(names(''), ['Milch', 'Hafermilch', 'Mehl', 'Brot']);
      // Names starting with it first.
      expect(names('mil'), ['Milch', 'Hafermilch']);
      expect(names('me'), ['Mehl']);
    },
  );

  test('staples go back on their list once when due', () {
    final e = _engine()
      ..saveShoppingList(const ShoppingList(id: 'l', name: 'Einkauf'))
      ..saveShoppingList(const ShoppingList(id: 'l2', name: 'Drogerie'));
    e.saveBoughtItem(
      BoughtItem(
        key: 'windeln',
        name: 'Windeln',
        quantity: '1 Packung',
        count: 3,
        listId: 'l2',
        everyDays: 14,
        lastBought: DateTime(2026, 10, 6, 18),
      ),
    );
    expect(e.boughtItem('windeln')!.nextDue, DateTime(2026, 10, 20));
    // Not yet the day before.
    expect(e.addDueStaples(now: DateTime(2026, 10, 19, 23)), 0);
    expect(e.addDueStaples(now: now), 1);
    final added = e.shoppingItems('l2').single;
    expect((added.name, added.quantity), ('Windeln', '1 Packung'));
    // Marked: not again today, and only once on the list.
    expect(e.addDueStaples(now: now), 0);
    expect(e.boughtItem('windeln')!.nextDue, DateTime(2026, 11, 3));
    expect(e.addDueStaples(now: DateTime(2026, 11, 3, 8)), 0);
    expect(e.shoppingItems('l2'), hasLength(1));
  });
}
