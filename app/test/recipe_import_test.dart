import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/recipe_import.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _page = '''
<html><head>
<script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"x"}</script>
<script type="application/ld+json">
{"@context":"https://schema.org","@graph":[{"@type":"BreadcrumbList"},
 {"@type":["Recipe"],"name":"Omas Pfannkuchen &amp; Apfelmus",
  "recipeYield":"4 Portionen",
  "totalTime":"PT1H15M",
  "recipeIngredient":["250 g Mehl","500 ml Milch","3 Eier","1 Prise Salz"],
  "recipeInstructions":[
    {"@type":"HowToStep","text":"Alles <b>verrühren</b>."},
    {"@type":"HowToSection","itemListElement":[{"@type":"HowToStep","text":"In der Pfanne ausbacken."}]}
  ]}]}
</script></head></html>
''';

void main() {
  test('schema.org recipe is read from JSON-LD', () {
    final r = recipeFromHtml(_page, id: 'r1', source: 'https://example.org')!;
    expect(r.title, 'Omas Pfannkuchen & Apfelmus');
    expect(r.servings, 4);
    expect(r.minutes, 75);
    expect(r.ingredients.map((i) => i.toString()), [
      '250 g Mehl',
      '500 ml Milch',
      '3 Eier',
      '1 Prise Salz',
    ]);
    expect(r.steps, 'Alles verrühren.\nIn der Pfanne ausbacken.');
    expect(recipeFromHtml('<html></html>', id: 'x'), isNull);
  });

  test('ingredients join open items on the shopping list', () {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm',
    );
    engine
      ..saveShoppingList(const ShoppingList(id: 'l', name: 'Einkauf'))
      ..saveShoppingItem(
        const ShoppingItem(
          id: 'a',
          listId: 'l',
          name: 'Mehl',
          quantity: '500 g',
        ),
      )
      ..saveShoppingItem(
        const ShoppingItem(
          id: 'b',
          listId: 'l',
          name: 'Milch',
          quantity: '1 Packung',
        ),
      );
    final added = engine.addToShoppingList('l', [
      Ingredient.parse('250 g Mehl'),
      Ingredient.parse('500 ml Milch'),
      Ingredient.parse('3 Eier'),
    ]);
    expect(added, 1);
    final items = {
      for (final i in engine.shoppingItems('l')) i.name: i.quantity,
    };
    expect(items, {
      'Mehl': '750 g',
      'Milch': '1 Packung + 500 ml',
      'Eier': '3',
    });
  });
}
