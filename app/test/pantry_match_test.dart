import 'package:famio/src/data/pantry_match.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pantry = [
    PantryItem(id: 'a', name: 'Milch', amount: 2),
    PantryItem(id: 'b', name: 'Eier', amount: 6),
    PantryItem(id: 'c', name: 'Mehl', amount: 0),
    PantryItem(id: 'd', name: 'Äpfel', amount: 3),
  ];

  test('what the pantry covers', () {
    bool has(String name) => inPantry(Ingredient(name: name), pantry);
    expect(has('Vollmilch'), isTrue);
    expect(has('Eier (Größe M)'), isTrue);
    expect(has('Mehl'), isFalse, reason: 'none left');
    expect(has('Aepfel'), isTrue, reason: 'umlauts folded');
    expect(has('Salz'), isTrue, reason: 'a staple');
    expect(has('Butter'), isFalse);
  });

  test('a recipe’s share', () {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    const recipe = Recipe(
      id: 'r',
      title: 'Pfannkuchen',
      ingredients: [
        Ingredient(name: 'Mehl', amount: 250, unit: 'g'),
        Ingredient(name: 'Milch', amount: 500, unit: 'ml'),
        Ingredient(name: 'Eier', amount: 3),
        Ingredient(name: 'Salz'),
      ],
    );
    final stock = engine.stockOf(recipe, pantry);
    expect(stock.have.map((i) => i.name), ['Milch', 'Eier', 'Salz']);
    expect(stock.missing.single.name, 'Mehl');
    expect(stock.share, 0.75);
  });
}
