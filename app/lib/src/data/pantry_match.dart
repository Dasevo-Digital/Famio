import 'package:famio_client/famio_client.dart';

import 'family_extras.dart';
import 'search.dart';

/// Basics that are assumed to be at home in any kitchen.
const _staples = {'wasser', 'salz', 'pfeffer', 'zucker', 'ol', 'oel'};

/// How much of a recipe the pantry covers.
class RecipeStock {
  const RecipeStock(this.have, this.missing);

  final List<Ingredient> have;
  final List<Ingredient> missing;

  int get total => have.length + missing.length;
  double get share => total == 0 ? 0 : have.length / total;
}

/// Whether [ingredient] is at home: a pantry item with some left whose
/// name is part of the ingredient's (or the other way round), so
/// "Milch" covers "Vollmilch" and "Eier (Größe M)" is covered by "Eier".
bool inPantry(Ingredient ingredient, Iterable<PantryItem> pantry) {
  final name = foldForSearch(ingredient.name).trim();
  if (name.isEmpty) return false;
  if (_staples.contains(name)) return true;
  for (final p in pantry) {
    if (p.amount <= 0) continue;
    final item = foldForSearch(p.name).trim();
    if (item.length < 3) continue;
    if (name.contains(item) || item.contains(name)) return true;
  }
  return false;
}

extension PantryMatch on SyncEngine {
  RecipeStock stockOf(Recipe recipe, [List<PantryItem>? pantry]) {
    final items = pantry ?? pantryItems;
    final have = <Ingredient>[];
    final missing = <Ingredient>[];
    for (final i in recipe.ingredients) {
      (inPantry(i, items) ? have : missing).add(i);
    }
    return RecipeStock(have, missing);
  }
}
