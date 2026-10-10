import 'dart:convert';

import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/open_food_facts.dart';
import 'package:famio/src/design/theme.dart';
import 'package:famio/src/screens/nutrition_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _flour = {
  'code': '4000000000001',
  'product_name': 'Weizenmehl Type 405',
  'brands': 'Mühle, Handel',
  'nutriments': {
    'energy-kcal_100g': 348,
    'proteins_100g': 10,
    'fat_100g': 1,
    'carbohydrates_100g': 72,
  },
};

/// Answers like Open Food Facts; remembers what was asked.
MockClient _off(List<Uri> asked) => MockClient((request) async {
  asked.add(request.url);
  if (request.url.path == '/cgi/search.pl') {
    return http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'products': [
            _flour,
            // No energy: left out.
            {'code': '9', 'product_name': 'Mehl ohne Angaben'},
          ],
        }),
      ),
      200,
    );
  }
  return http.Response('{"status":0}', 200);
});

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('products: values per 100 g, energy from kJ if needed', () {
    final n = OpenFoodFacts.nutritionOf(_flour)!;
    expect(
      (n.product, n.kcal, n.protein, n.carbs),
      ('Weizenmehl Type 405 (Mühle)', 348, 10, 72),
    );
    final kj = OpenFoodFacts.nutritionOf({
      'product_name': 'Saft',
      'serving_quantity': '200',
      'nutriments': {'energy_100g': 184.1},
    })!;
    expect(kj.kcal, closeTo(44, 0.01));
    expect(kj.pieceGrams, 200);
    expect(OpenFoodFacts.nutritionOf({'product_name': 'Leer'}), isNull);
  });

  test(
    'search asks for the words only and skips products without values',
    () async {
      final asked = <Uri>[];
      final found = await OpenFoodFacts(client: _off(asked)).search(' Mehl ');
      expect(found.map((n) => n.product), ['Weizenmehl Type 405 (Mühle)']);
      expect(asked.single.host, 'world.openfoodfacts.org');
      expect(asked.single.queryParameters['search_terms'], 'Mehl');
    },
  );

  testWidgets('asked once, then ingredients are linked and summed up', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    engine.saveRecipe(
      Recipe(
        id: 'r',
        title: 'Pfannkuchen',
        servings: 2,
        ingredients: [
          Ingredient.parse('200 g Mehl'),
          Ingredient.parse('2 Eier'),
        ],
      ),
    );
    final off = OpenFoodFacts(client: _off([]));
    final state = AppState()..engine = engine;
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: famioTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: [
                  RecipeNutrition(recipe: engine.recipe('r')!, off: off),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Nährwerte aus Open Food Facts'));
    await tester.pumpAndSettle();
    expect(find.text('Open Food Facts fragen?'), findsOneWidget);
    await tester.tap(find.text('Erlauben'));
    await tester.pumpAndSettle();
    expect(await OpenFoodFacts.allowed(), isTrue);

    await tester.tap(find.byTooltip('Suchen').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weizenmehl Type 405 (Mühle)'));
    await tester.pumpAndSettle();
    final linked = engine.recipe('r')!;
    expect(linked.ingredients.first.nutrition!.kcal, 348);
    expect(
      find.text('Weizenmehl Type 405 (Mühle) · 348 kcal je 100 g'),
      findsOneWidget,
    );
    final n = linked.nutritionPerServing!;
    expect(n.kcal, 348);
    expect((n.counted, n.total), (1, 2));

    // Linked once more after an edit of the recipe: the link stays.
    expect(
      Ingredient.parse('200 g Mehl').withNutrition(null).nutrition,
      isNull,
    );
  });
}
