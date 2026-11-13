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

  test('the main noun counts, not adjectives or phrases', () {
    bool has(String ingredient, String pantryItem) => inPantry(
      Ingredient(name: ingredient),
      [PantryItem(id: 'x', name: pantryItem, amount: 1)],
    );
    const notAtHome = {
      'rote Paprika': 'Rote Linsen',
      'Zwiebel, rot': 'Rote Linsen',
      'frische Petersilie': 'Frische Hefe',
      'weiße Schokolade': 'Weiße Bohnen',
      'saure Sahne': 'Saure Gurken',
      'grüne Paprika': 'Grüne Bohnen',
      'getrocknete Kräuter': 'Getrocknete Tomaten',
      'Tomaten, gehackt': 'Gehackte Haselnüsse',
      'Hackfleisch, gemischt': 'Gemischte Kräuter',
      'Butter, weich': 'Weiche Brötchen',
      'Tomaten aus der Dose': 'Mais aus der Dose',
      'Saft einer Zitrone': 'Orangensaft',
      'Mehl Type 405': 'Type 550',
    };
    for (final MapEntry(key: i, value: p) in notAtHome.entries) {
      expect(has(i, p), isFalse, reason: '$i / $p');
    }
    const atHome = {
      'Knoblauchzehen': 'Knoblauch',
      'Knoblauchzehe': 'Knoblauch',
      'Hähnchenbrustfilet': 'Hähnchenbrust',
      'Parmesan': 'Parmesankäse',
      'Speckwürfel': 'Speck',
      'Zimtstange': 'Zimt',
      'Lorbeerblätter': 'Lorbeer',
      'Zitronensaft': 'Zitronen',
      'Tomaten, passiert': 'Passierte Tomaten',
      'Kartoffeln, festkochend': 'Kartoffeln',
      'Sahne, süß': 'Süße Sahne',
      'Mehl Type 405': 'Mehl',
      'Eier (Größe M)': 'Bio-Eier',
    };
    for (final MapEntry(key: i, value: p) in atHome.entries) {
      expect(has(i, p), isTrue, reason: '$i / $p');
    }
    // Basics are there whatever the recipe calls them.
    expect(inPantry(const Ingredient(name: 'Öl zum Braten'), const []), isTrue);
    expect(
      inPantry(const Ingredient(name: 'schwarzer Pfeffer'), const []),
      isTrue,
    );
  });

  group('more than one German noun, other languages (#457)', () {
    bool has(String ingredient, String pantryItem, {String language = 'de'}) =>
        inPantry(Ingredient(name: ingredient), [
          PantryItem(id: 'x', name: pantryItem, amount: 1),
        ], language: language);

    test('product names from a barcode scan', () {
      const atHome = {
        'Haferflocken': 'Haferflocken Zart',
        'Nudeln': 'Nudeln Penne',
        'Penne': 'Nudeln Penne',
        'Thunfisch': 'Thunfisch Natur',
        'Tomaten': 'Tomaten Dose',
        'Joghurt': 'Joghurt Griechische Art',
        'Gemüsebrühe': 'Gemüsebrühe Pulver',
      };
      for (final MapEntry(key: i, value: p) in atHome.entries) {
        expect(has(i, p), isTrue, reason: '$i / $p');
      }
      // A word after the name is no thing of its own.
      expect(has('Backpulver', 'Gemüsebrühe Pulver'), isFalse);
    });

    test('a processed product is not the fresh one', () {
      const notAtHome = {
        'rote Paprika': 'Paprikapulver',
        'Orangen': 'Orangensaft',
        'Äpfel': 'Apfelsaft',
        'Tomaten': 'Tomatensaft',
        'frische Kräuter': 'Kräuterkäse',
        'Zimt, gemahlen': 'Zimtstangen',
        'Zwiebeln': 'Zwiebelringe',
        'Ingwer': 'Ingwerpulver',
      };
      for (final MapEntry(key: i, value: p) in notAtHome.entries) {
        expect(has(i, p), isFalse, reason: '$i / $p');
      }
      // The whole covers its part.
      expect(has('Zimtstange', 'Zimt'), isTrue);
      expect(has('Parmesan, gerieben', 'Parmesankäse'), isTrue);
    });

    test('alternatives count each', () {
      expect(has('Schmand oder Crème fraîche', 'Crème fraîche'), isTrue);
      expect(has('Schmand oder Crème fraîche', 'Schmand'), isTrue);
      expect(has('Schmand oder Crème fraîche', 'Sahne'), isFalse);
    });

    test('English recipes', () {
      bool en(String i, String p) => has(i, p, language: 'en');
      expect(en('olive oil', 'Olive oil'), isTrue);
      expect(en('chicken breasts', 'Chicken breasts'), isTrue);
      expect(en('brown sugar', 'Brown sugar'), isTrue);
      expect(en('milk', 'Whole milk'), isTrue);
      expect(en('red bell pepper', 'Bell peppers'), isTrue);
      expect(en('garlic, minced', 'Garlic'), isTrue);
      expect(en('red lentils', 'Red bell pepper'), isFalse);
      expect(en('chicken stock', 'Chicken breasts'), isFalse);
      expect(en('rice', 'Ice cream'), isFalse);
      expect(
        inPantry(const Ingredient(name: 'salt'), const [], language: 'en'),
        isTrue,
      );
    });

    test('Spanish recipes', () {
      bool es(String i, String p) => has(i, p, language: 'es');
      expect(es('pimiento rojo', 'Pimientos'), isTrue);
      expect(es('arroz blanco', 'Arroz'), isTrue);
      expect(es('dientes de ajo', 'ajo'), isTrue);
      expect(es('aceite de oliva', 'Aceite de oliva'), isTrue);
      expect(es('cebolla roja', 'col roja'), isFalse);
      expect(es('pimiento rojo', 'Tomate rojo'), isFalse);
    });

    test('an English name in a German app', () {
      expect(has('olive oil', 'Olive oil'), isTrue);
      expect(has('Chicken breasts', 'Chicken breasts'), isTrue);
    });
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
