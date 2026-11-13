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

  test('whole words and compounds, not parts of words', () {
    bool has(String ingredient, String pantryItem) => inPantry(
      Ingredient(name: ingredient),
      [PantryItem(id: 'x', name: pantryItem, amount: 1)],
    );
    // Ice cream is no rice, no egg white and no iceberg lettuce.
    for (final other in ['Reis', 'Basmatireis', 'Eiweiß', 'Eisbergsalat']) {
      expect(has(other, 'Eis'), isFalse, reason: other);
    }
    expect(has('Erdnussbutter', 'Butter'), isFalse);
    expect(has('Kokosmilch', 'Milch'), isFalse);
    expect(has('Milch', 'Kokosmilch'), isFalse);
    expect(has('Reisnudeln', 'Nudeln'), isFalse);
    expect(has('Eis', 'Ei'), isFalse);
    // What is the same thing.
    expect(has('Basmatireis', 'Reis'), isTrue);
    expect(has('Reis', 'Basmatireis'), isTrue);
    expect(has('Milch', 'Vollmilch'), isTrue);
    expect(has('frische Milch', 'Milch 3,5 %'), isTrue);
    expect(has('Ei', 'Eier'), isTrue);
    expect(has('Hühnereier', 'Eier'), isTrue);
    expect(has('Tomaten', 'Tomate'), isTrue);
    expect(has('Zwiebeln (rot)', 'Zwiebel'), isTrue);
    expect(has('Bio-Eier', 'Eier'), isTrue);
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
