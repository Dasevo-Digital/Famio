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
/// names the same thing. Only the main noun counts ("rote Paprika" is
/// Paprika, "Tomaten, gehackt" Tomaten, "Öl zum Braten" Öl), so a shared
/// adjective does not ("Rote Linsen" are no red pepper). Nouns match in the
/// singular or the plural ("Ei", "Eier"), as the end of a compound ("Milch"
/// covers "Vollmilch", "Reis" covers "Basmatireis"), and as the start of a
/// compound naming a part of it ("Knoblauch" covers "Knoblauchzehen").
bool inPantry(Ingredient ingredient, Iterable<PantryItem> pantry) {
  final wanted = mainNoun(ingredient.name);
  if (wanted.isEmpty) return false;
  if (_staples.contains(wanted)) return true;
  for (final p in pantry) {
    if (p.amount <= 0) continue;
    final have = mainNoun(p.name);
    if (have.isNotEmpty && _sameThing(have, wanted)) return true;
  }
  return false;
}

final _nouns = <String, String>{};

/// The main noun of an ingredient or pantry name, folded ("Äpfel" and
/// "Aepfel" alike): what comes before a comma, a bracket or a phrase like
/// "zum Braten", and of that the last capitalised word (adjectives before
/// it are lower case or come first); "Type 405", "Bio" and the like do not
/// count. Remembered, as recipe lists ask for it again and again.
String mainNoun(String name) => _nouns.length > 4000
    ? (_nouns..clear()).putIfAbsent(name, () => _noun(name))
    : _nouns.putIfAbsent(name, () => _noun(name));

String _noun(String name) {
  var core = name.split(RegExp(r'[,(;/]')).first;
  core = core
      .split(
        RegExp(
          r'\s(?:zum|zur|für|fur|aus|mit|von|vom|nach|ohne|in|im|oder|und|à|a la|'
          r'for|from|with|of|or|and|para|con|de|del|o|y)\s',
          caseSensitive: false,
        ),
      )
      .first;
  final words = [
    for (final w in core.split(RegExp(r'[\s\-]+')))
      if (w.isNotEmpty &&
          !RegExp(r'\d').hasMatch(w) &&
          !_notTheThing.contains(w.toLowerCase()))
        w,
  ];
  if (words.isEmpty) return '';
  final capitalised = [
    for (final w in words)
      if (w[0] != w[0].toLowerCase()) w,
  ];
  return _fold((capitalised.isNotEmpty ? capitalised : words).last);
}

/// Words that describe a product rather than name it.
const _notTheThing = {
  'type',
  'typ',
  'tk',
  'bio',
  'größe',
  'grosse',
  'gr',
  'gr.',
  'ca',
  'ca.',
  'etwa',
  'evtl',
  'evtl.',
  'optional',
  'frisch',
  'frische',
  'fresh',
};

String _fold(String word) => foldForSearch(word)
    .replaceAll('ae', 'a')
    .replaceAll('oe', 'o')
    .replaceAll('ue', 'u')
    .replaceAll(RegExp(r'[^a-z]'), '');

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

/// Endings that name a part or form of the thing before them
/// ("Knoblauchzehe", "Zimtstange", "Zitronensaft", "Parmesankäse").
const _parts = {
  'zehe',
  'zehen',
  'stange',
  'stangen',
  'blatt',
  'blatter',
  'wurfel',
  'filet',
  'filets',
  'saft',
  'schale',
  'abrieb',
  'scheibe',
  'scheiben',
  'stuck',
  'stucke',
  'zweig',
  'zweige',
  'spalten',
  'ringe',
  'streifen',
  'pulver',
  'kase',
};

bool _sameThing(String a, String b) =>
    _samePlural(a, b) ||
    _compoundOf(a, b) ||
    _compoundOf(b, a) ||
    _partOf(a, b) ||
    _partOf(b, a);

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

/// Whether [word] names a part of [thing] ("knoblauchzehen", "knoblauch").
bool _partOf(String word, String thing) {
  if (thing.length < 4) return false;
  for (final start in [thing, '${thing}n', '${thing}s', '${thing}en']) {
    if (word.length > start.length &&
        word.startsWith(start) &&
        _parts.contains(word.substring(start.length))) {
      return true;
    }
  }
  // "Zitronen" covers "Zitronensaft": the plural before the part.
  if (thing.endsWith('n') || thing.endsWith('e')) {
    final stem = thing.substring(0, thing.length - 1);
    return stem.length >= 4 &&
        word.startsWith(stem) &&
        _parts.contains(
          word.substring(stem.length).replaceFirst(RegExp(r'^n'), ''),
        );
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
