import 'dart:math';

import 'package:famio_client/famio_client.dart';

import 'pantry_match.dart';

/// A recipe Famio would cook, with what the pantry covers of it.
class MealCandidate {
  const MealCandidate({
    required this.recipe,
    required this.stock,
    this.usesExpiring = false,
  });

  final Recipe recipe;
  final RecipeStock stock;

  /// Uses something from the pantry that expires within a few days.
  final bool usesExpiring;
}

/// "Woche vorschlagen": the days of a week still without a meal in a slot,
/// and recipes to fill them, best first.
class MealSuggestion {
  const MealSuggestion({required this.days, required this.candidates});

  /// Days from the first one asked for, without a planned meal in the slot.
  final List<DateTime> days;

  /// Favourites first (the others only when they run out), each group led
  /// by what the pantry covers best and what uses up expiring food; none
  /// planned in the two weeks before or in the week itself.
  final List<MealCandidate> candidates;
}

/// Suggests meals for [slot] in the week starting on [monday], from [from]
/// on (today, in the current week). [planned] are the meals around it, at
/// least from two weeks before; [seed] mixes recipes that are about as
/// good, for "Andere Vorschläge".
MealSuggestion suggestMeals({
  required DateTime monday,
  required MealSlot slot,
  required List<Recipe> recipes,
  required List<PlannedMeal> planned,
  required List<PantryItem> pantry,
  DateTime? from,
  int seed = 0,
}) {
  final first = from == null || from.isBefore(monday)
      ? monday
      : DateTime(from.year, from.month, from.day);
  final end = DateTime(monday.year, monday.month, monday.day + 7);
  final taken = {
    for (final m in planned)
      if (m.slot == slot) m.date,
  };
  final days = [
    for (var i = 0; i < 7; i++)
      if (DateTime(monday.year, monday.month, monday.day + i) case final d
          when !d.isBefore(first) && !taken.contains(d))
        d,
  ];

  // Nothing that was on the table in the last two weeks or is already in
  // this one, in any slot.
  final recentFrom = DateTime(monday.year, monday.month, monday.day - 14);
  final recent = {
    for (final m in planned)
      if (m.recipeId != null &&
          !m.date.isBefore(recentFrom) &&
          m.date.isBefore(end))
        m.recipeId!,
  };
  final soon = DateTime(first.year, first.month, first.day + 4);
  final expiring = [
    for (final p in pantry)
      if (p.bestBefore case final d?
          when p.amount > 0 && !d.isBefore(first) && !d.isAfter(soon))
        p,
  ];
  // Salt and the like count as at home, not as expiring.
  bool usesUp(Ingredient i) => inPantry(i, expiring) && !inPantry(i, const []);
  final random = Random(seed);
  final scored = <(MealCandidate, double)>[];
  for (final r in recipes) {
    if (recent.contains(r.id)) continue;
    final have = <Ingredient>[];
    final missing = <Ingredient>[];
    for (final i in r.ingredients) {
      (inPantry(i, pantry) ? have : missing).add(i);
    }
    final stock = RecipeStock(have, missing);
    final usesExpiring = expiring.isNotEmpty && r.ingredients.any(usesUp);
    // Favourites before all others; then the pantry, with some chance, so
    // the week is not the same every time.
    final score =
        (r.favorite ? 10 : 0) +
        stock.share +
        (usesExpiring ? 0.5 : 0) +
        random.nextDouble() * 0.4;
    scored.add((
      MealCandidate(recipe: r, stock: stock, usesExpiring: usesExpiring),
      score,
    ));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return MealSuggestion(
    days: days,
    candidates: [for (final (c, _) in scored) c],
  );
}

/// The slot the family plans most in [planned] (the main meal); dinner if
/// nothing is planned.
MealSlot usualSlot(List<PlannedMeal> planned) {
  final counts = <MealSlot, int>{};
  for (final m in planned) {
    if (m.slot == MealSlot.lunch || m.slot == MealSlot.dinner) {
      counts[m.slot] = (counts[m.slot] ?? 0) + 1;
    }
  }
  return (counts[MealSlot.lunch] ?? 0) > (counts[MealSlot.dinner] ?? 0)
      ? MealSlot.lunch
      : MealSlot.dinner;
}
