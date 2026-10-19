import 'package:famio/src/data/meal_suggestions.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _monday = DateTime(2026, 10, 19);

DateTime _day(int i) => DateTime(_monday.year, _monday.month, _monday.day + i);

Recipe _recipe(
  String title, {
  bool favorite = false,
  List<String> uses = const [],
}) => Recipe(
  id: title,
  title: title,
  favorite: favorite,
  ingredients: [for (final i in uses) Ingredient(name: i)],
);

PlannedMeal _meal(int day, String recipe, [MealSlot slot = MealSlot.dinner]) =>
    PlannedMeal(
      id: '$recipe$day',
      date: _day(day),
      slot: slot,
      recipeId: recipe,
    );

void main() {
  test('free days from today, favourites first, no repeats', () {
    final s = suggestMeals(
      monday: _monday,
      slot: MealSlot.dinner,
      from: _day(2),
      recipes: [
        _recipe('Suppe'),
        _recipe('Lasagne', favorite: true),
        _recipe('Pizza', favorite: true),
        _recipe('Curry', favorite: true),
        _recipe('Chili', favorite: true),
      ],
      planned: [
        // Twelve days before: too recent.
        _meal(-12, 'Pizza'),
        // Three weeks ago: fine again.
        _meal(-21, 'Chili'),
        // Already in the week (at lunch): not twice.
        _meal(5, 'Curry', MealSlot.lunch),
        // Thursday's dinner is planned.
        _meal(3, 'Lasagne'),
      ],
      pantry: const [],
    );
    // Wednesday to Sunday, without Thursday.
    expect(s.days.map((d) => d.day), [21, 23, 24, 25]);
    final titles = s.candidates.map((c) => c.recipe.title).toList();
    // Lasagne is in the week, Pizza too recent, Curry already planned.
    expect(titles, ['Chili', 'Suppe']);
  });

  test('what the pantry has comes first, and what expires soon', () {
    final pantry = [
      const PantryItem(id: 'r', name: 'Reis', amount: 1),
      const PantryItem(id: 'k', name: 'Kokosmilch', amount: 1),
      PantryItem(id: 's', name: 'Sahne', amount: 1, bestBefore: _day(2)),
    ];
    MealSuggestion suggest(int seed) => suggestMeals(
      monday: _monday,
      slot: MealSlot.dinner,
      recipes: [
        _recipe('Nudeln', favorite: true, uses: ['Nudeln', 'Tomaten']),
        _recipe('Curry', favorite: true, uses: ['Reis', 'Kokosmilch']),
        _recipe(
          'Gratin',
          favorite: true,
          uses: ['Kartoffeln', 'Sahne', 'Salz'],
        ),
        _recipe('Toast', uses: ['Toast', 'Salz']),
      ],
      planned: const [],
      pantry: pantry,
      seed: seed,
    );
    for (var seed = 0; seed < 20; seed++) {
      final s = suggest(seed);
      // All at home, or most of it with the cream to use up.
      expect(
        {for (final c in s.candidates.take(2)) c.recipe.title},
        {'Curry', 'Gratin'},
      );
      expect(s.candidates[2].recipe.title, 'Nudeln');
      // Favourites before the rest, however full the pantry.
      expect(s.candidates.last.recipe.title, 'Toast');
    }
    final s = suggest(0);
    final gratin = s.candidates.firstWhere((c) => c.recipe.title == 'Gratin');
    expect(gratin.usesExpiring, isTrue);
    expect((gratin.stock.have.length, gratin.stock.total), (2, 3));
    expect(gratin.stock.missing.map((i) => i.name), ['Kartoffeln']);
    // Salt is at home, but does not expire.
    final toast = s.candidates.firstWhere((c) => c.recipe.title == 'Toast');
    expect(toast.usesExpiring, isFalse);
  });

  test('other suggestions mix recipes that are about as good', () {
    final recipes = [
      for (final t in ['A', 'B', 'C', 'D', 'E', 'F'])
        _recipe(t, favorite: true),
    ];
    final orders = {
      for (var seed = 0; seed < 10; seed++)
        suggestMeals(
          monday: _monday,
          slot: MealSlot.dinner,
          recipes: recipes,
          planned: const [],
          pantry: const [],
          seed: seed,
        ).candidates.map((c) => c.recipe.title).join(),
    };
    expect(orders.length, greaterThan(1));
  });

  test('the usual slot: lunch only if planned more often', () {
    expect(usualSlot(const []), MealSlot.dinner);
    expect(
      usualSlot([
        _meal(0, 'a', MealSlot.lunch),
        _meal(1, 'b', MealSlot.lunch),
        _meal(1, 'c'),
        _meal(1, 'd', MealSlot.breakfast),
      ]),
      MealSlot.lunch,
    );
    expect(
      usualSlot([_meal(0, 'a', MealSlot.lunch), _meal(1, 'c')]),
      MealSlot.dinner,
    );
  });
}
