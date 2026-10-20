import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/shopping_text.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

SyncEngine _engine() => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: 'm1',
);

void main() {
  test('open items by aisle, amounts first, nothing ticked', () {
    final e = _engine()
      ..saveShoppingList(const ShoppingList(id: 'l', name: 'Wocheneinkauf'))
      ..saveShoppingItem(
        const ShoppingItem(id: 'a', listId: 'l', name: 'Äpfel', quantity: '3'),
      )
      ..saveShoppingItem(
        const ShoppingItem(
          id: 'b',
          listId: 'l',
          name: 'Milch',
          quantity: '2 l',
        ),
      )
      ..saveShoppingItem(
        const ShoppingItem(id: 'c', listId: 'l', name: 'Brot', checked: true),
      );
    expect(
      shoppingListText(e, e.shoppingList('l')!),
      'Wocheneinkauf\n\nObst & Gemüse\n• 3 Äpfel\nKühlregal\n• 2 l Milch',
    );
  });

  test('one aisle needs no heading; packing lists name the owner', () {
    final e = _engine()
      ..saveShoppingList(const ShoppingList(id: 'l', name: 'Obst'))
      ..saveShoppingItem(
        const ShoppingItem(id: 'a', listId: 'l', name: 'Bananen'),
      )
      ..saveShoppingList(
        const ShoppingList(id: 'p', name: 'Urlaub', packing: true),
      )
      ..saveShoppingItem(
        const ShoppingItem(
          id: 'x',
          listId: 'p',
          name: 'Badehose',
          memberId: 'k1',
        ),
      )
      ..saveShoppingItem(
        const ShoppingItem(id: 'y', listId: 'p', name: 'Sonnencreme'),
      );
    expect(shoppingListText(e, e.shoppingList('l')!), 'Obst\n\n• Bananen');
    expect(
      shoppingListText(e, e.shoppingList('p')!),
      allOf(contains('• Badehose (Mia)'), contains('• Sonnencreme')),
    );
  });
}
