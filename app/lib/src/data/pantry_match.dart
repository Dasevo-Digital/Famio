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

/// Whether [ingredient] is at home: a pantry item with some left that
/// names the same thing. Words match as a whole, in the singular or the
/// plural ("Ei", "Eier"), or as the end of a compound ("Milch" covers
/// "Vollmilch", "Reis" covers "Basmatireis"), either way round. A part of a
/// word does not: "Eis" is not "Reis", "Butter" not "Erdnussbutter".
bool inPantry(Ingredient ingredient, Iterable<PantryItem> pantry) {
  final name = foldForSearch(ingredient.name).trim();
  if (name.isEmpty) return false;
  if (_staples.contains(name)) return true;
  final wanted = _words(ingredient.name);
  if (wanted.isEmpty) return false;
  for (final p in pantry) {
    if (p.amount <= 0) continue;
    final have = _words(p.name);
    for (final a in have) {
      for (final b in wanted) {
        if (_sameThing(a, b)) return true;
      }
    }
  }
  return false;
}

/// The words of a name without notes in brackets, folded ("Äpfel" and
/// "Aepfel" alike).
List<String> _words(String name) => [
  for (final w
      in foldForSearch(name.replaceAll(RegExp(r'\(.*?\)'), ' '))
          .replaceAll('ae', 'a')
          .replaceAll('oe', 'o')
          .replaceAll('ue', 'u')
          .split(RegExp(r'[^a-z]+')))
    if (w.length >= 2) w,
];

/// Words that make a compound a different product ("Kokosmilch" is not
/// milk, "Erdnussbutter" not butter).
const _otherProduct = {
  'kokos',
  'mandel',
  'hafer',
  'soja',
  'reis',
  'erdnuss',
  'cashew',
  'haselnuss',
  'kakao',
  'butter',
  'kondens',
};

bool _sameThing(String a, String b) =>
    _samePlural(a, b) || _compoundOf(a, b) || _compoundOf(b, a);

bool _samePlural(String a, String b) {
  if (a == b) return true;
  final (short, long) = a.length < b.length ? (a, b) : (b, a);
  if (!long.startsWith(short)) return false;
  return switch (long.substring(short.length)) {
    'n' || 'en' || 'er' || 'e' => true,
    // "Ei" + s is "Eis": only for longer words.
    's' => short.length >= 4,
    _ => false,
  };
}

/// Whether [word] is a compound ending in [head] ("vollmilch", "milch").
bool _compoundOf(String word, String head) {
  if (head.length < 4) return false;
  for (final end in [head, '${head}n', '${head}en', '${head}er', '${head}e']) {
    if (word.length > end.length && word.endsWith(end)) {
      final prefix = word.substring(0, word.length - end.length);
      return !_otherProduct.contains(prefix);
    }
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
