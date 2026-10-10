import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  const flour = Nutrition(
    code: '1',
    product: 'Weizenmehl',
    kcal: 350,
    protein: 10,
    fat: 1,
    carbs: 72,
  );
  const egg = Nutrition(
    code: '2',
    product: 'Eier',
    kcal: 140,
    protein: 12,
    fat: 10,
    carbs: 1,
    pieceGrams: 60,
  );

  test('amounts in grams by unit', () {
    double? g(String line, [Nutrition? n]) =>
        Ingredient.parse(line).withNutrition(n).grams;
    expect(g('200 g Mehl'), 200);
    expect(g('0,5 kg Mehl'), 500);
    expect(g('2 EL Öl'), 30);
    expect(g('1 TL Salz'), 5);
    expect(g('250 ml Milch'), 250);
    expect(g('2 Eier'), isNull);
    expect(g('2 Eier', egg), 120);
    expect(g('Salz'), isNull);
  });

  test('nutrients of one serving from the linked ingredients', () {
    final recipe = Recipe(
      id: 'r',
      title: 'Pfannkuchen',
      servings: 2,
      ingredients: [
        Ingredient.parse('200 g Mehl').withNutrition(flour),
        Ingredient.parse('2 Eier').withNutrition(egg),
        Ingredient.parse('300 ml Milch'),
        Ingredient.parse('Salz'),
      ],
    );
    final n = recipe.nutritionPerServing!;
    expect(n.kcal, closeTo((350 * 2 + 140 * 1.2) / 2, 0.01));
    expect(n.protein, closeTo((10 * 2 + 12 * 1.2) / 2, 0.01));
    expect((n.counted, n.total), (2, 3));
    expect(
      Recipe(
        id: 'x',
        title: 'x',
        ingredients: [Ingredient.parse('1 Ei')],
      ).nutritionPerServing,
      isNull,
    );
  });

  test('the link survives the record', () {
    final recipe = Recipe(
      id: 'r',
      title: 'Pfannkuchen',
      ingredients: [Ingredient.parse('2 Eier').withNutrition(egg)],
    );
    final back = Recipe.fromRecord(
      SyncRecord(
        collection: Collections.recipes,
        id: 'r',
        data: recipe.toData(),
        updatedAt: 1,
      ),
    );
    final n = back.ingredients.single.nutrition!;
    expect((n.product, n.kcal, n.pieceGrams), ('Eier', 140, 60));
    expect(back.ingredients.single.toString(), '2 Eier');
  });
}
