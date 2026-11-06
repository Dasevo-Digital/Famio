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
    final imported = recipeFromHtml(
      _page,
      id: 'r1',
      source: 'https://example.org',
    )!;
    final r = imported.recipe;
    expect(imported.image, isNull);
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

  test('the photo of a recipe comes in every form schema.org allows', () {
    Uri? image(String json) => recipeFromHtml(
      '<script type="application/ld+json">'
      '{"@type":"Recipe","name":"x","image":$json}</script>',
      id: 'r1',
      source: 'https://rezepte.test/kuchen/apfel',
    )?.image;
    final photo = Uri.parse('https://bilder.test/a.jpg');
    expect(image('"https://bilder.test/a.jpg"'), photo);
    expect(
      image('["https://bilder.test/a.jpg","https://bilder.test/b.jpg"]'),
      photo,
    );
    expect(
      image('{"@type":"ImageObject","url":"https://bilder.test/a.jpg"}'),
      photo,
    );
    expect(image('[{"contentUrl":"https://bilder.test/a.jpg"}]'), photo);
    expect(
      image('"/fotos/a.jpg"'),
      Uri.parse('https://rezepte.test/fotos/a.jpg'),
    );
    expect(image('[]'), isNull);
    expect(image('""'), isNull);
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

  test('the photo may be a reference inside the @graph', () {
    // As Chefkoch and sites with Yoast describe it.
    const page = '''
<script type="application/ld+json">{"@context":"https://schema.org","@graph":[
 {"@type":"Recipe","name":"Lasagne","image":{"@id":"https://rezepte.test/l#bild"}},
 {"@type":"WebPage","primaryImageOfPage":{"@id":"https://rezepte.test/l#bild"}},
 {"@type":"ImageObject","@id":"https://rezepte.test/l#bild",
  "url":"https://bilder.test/lasagne.jpg","width":960,"height":540}
]}</script>''';
    expect(
      recipeFromHtml(page, id: 'r1')?.image,
      Uri.parse('https://bilder.test/lasagne.jpg'),
    );
  });

  test('a reference that leads nowhere or in circles gives no photo', () {
    Uri? image(String nodes) => recipeFromHtml(
      '<script type="application/ld+json">{"@graph":['
      '{"@type":"Recipe","name":"x","image":{"@id":"#a"}}$nodes]}</script>',
      id: 'r1',
    )?.image;
    expect(image(''), isNull);
    expect(image(',{"@id":"#a","url":{"@id":"#a"}}'), isNull);
    expect(
      image(',{"@id":"#a","url":{"@id":"#b"}},{"@id":"#b","url":{"@id":"#a"}}'),
      isNull,
    );
  });

  test('without a photo in the recipe the page has its own', () {
    Uri? image(String head) => recipeFromHtml(
      '<html><head>$head</head><script type="application/ld+json">'
      '{"@type":"Recipe","name":"x"}</script></html>',
      id: 'r1',
      source: 'https://rezepte.test/kuchen/apfel',
    )?.image;
    final photo = Uri.parse('https://bilder.test/a.jpg?w=960&h=540');
    expect(
      image(
        '<meta property="og:image" '
        'content="https://bilder.test/a.jpg?w=960&amp;h=540">',
      ),
      photo,
    );
    expect(
      image(
        "<meta content='https://bilder.test/a.jpg?w=960&amp;h=540' "
        "property='og:image:secure_url'/>",
      ),
      photo,
    );
    expect(
      image('<meta property="og:image" content="/fotos/a.jpg">'),
      Uri.parse('https://rezepte.test/fotos/a.jpg'),
    );
    expect(image('<meta property="og:title" content="Apfelkuchen">'), isNull);
    // The address of the recipe's own photo goes first.
    expect(
      recipeFromHtml(
        '<meta property="og:image" content="https://bilder.test/logo.png">'
        '<script type="application/ld+json">{"@type":"Recipe","name":"x",'
        '"image":"https://bilder.test/a.jpg"}</script>',
        id: 'r1',
      )?.image,
      Uri.parse('https://bilder.test/a.jpg'),
    );
  });
}
