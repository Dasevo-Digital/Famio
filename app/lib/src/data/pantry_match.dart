import 'package:famio_client/famio_client.dart';

import 'family_extras.dart';
import 'search.dart';
import '../l10n.dart';

/// Basics that are assumed to be at home in any kitchen.
const _staples = {
  'wasser',
  'salz',
  'pfeffer',
  'zucker',
  'ol',
  'oel',
  'water',
  'salt',
  'pepper',
  'sugar',
  'oil',
  'agua',
  'sal',
  'pimienta',
  'azucar',
  'aceite',
};

/// How much of a recipe the pantry covers.
class RecipeStock {
  const RecipeStock(this.have, this.missing);

  final List<Ingredient> have;
  final List<Ingredient> missing;

  int get total => have.length + missing.length;
  double get share => total == 0 ? 0 : have.length / total;
}

/// Whether [ingredient] is at home: a pantry item with some left that
/// names the same thing. The nouns count, not adjectives ("rote Paprika"
/// is Paprika, so "Rote Linsen" are no red pepper), units ("Dose") or
/// phrases ("zum Braten"). Nouns match in the singular or the plural ("Ei",
/// "Eier"), as the end of a compound ("Milch" covers "Vollmilch", "Reis"
/// covers "Basmatireis"), and the whole covers its part ("Knoblauch" covers
/// "Knoblauchzehen", "Zitronen" cover "Zitronensaft"), not the other way
/// round ("Paprikapulver" is no bell pepper). Alternatives ("Schmand oder
/// Crème fraîche") count each. [language] says which word of a phrase in
/// lower case is the noun: the last in English and German ("olive oil",
/// "rote paprika"), the first in Spanish ("pimiento rojo").
bool inPantry(
  Ingredient ingredient,
  Iterable<PantryItem> pantry, {
  String? language,
}) {
  final lang = language ?? appLanguage;
  for (final wanted in ingredientNouns(ingredient.name, lang)) {
    if (wanted.any(_staples.contains)) return true;
    for (final p in pantry) {
      if (p.amount <= 0) continue;
      for (final have in ingredientNouns(p.name, lang)) {
        if (have.any((h) => wanted.any((w) => _sameThing(h, w)))) return true;
      }
    }
  }
  return false;
}

/// The main noun of [name] (see [ingredientNouns]), or ''.
String mainNoun(String name, {String? language}) =>
    ingredientNouns(name, language ?? appLanguage).firstOrNull?.firstOrNull ??
    '';

final _nouns = <String, List<List<String>>>{};

/// The nouns of an ingredient or pantry name, folded ("Äpfel" and
/// "Aepfel" alike): one list per alternative ("A oder B"), the main noun
/// first. Remembered, as recipe lists ask for it again and again.
List<List<String>> ingredientNouns(String name, String language) {
  if (_nouns.length > 4000) _nouns.clear();
  return _nouns.putIfAbsent('$language|$name', () {
    final core = name.split(RegExp(r'[,(;/]')).first;
    return [
      for (final alternative in core.split(
        RegExp(r'\s(?:oder|or|o|bzw\.?)\s', caseSensitive: false),
      ))
        if (_nounsOf(alternative, language) case final nouns
            when nouns.isNotEmpty)
          nouns,
    ];
  });
}

/// What comes before a phrase like "zum Braten" or "aus der Dose".
final _phrase = RegExp(
  r'\s(?:zum|zur|für|fur|aus|mit|nach|ohne|in|im|und|sowie|à|a la|'
  r'for|from|with|in|and|para|con|en|y)\s',
  caseSensitive: false,
);

/// Joins two nouns of which the last names the thing: "Saft einer
/// Zitrone", "juice of a lemon", "dientes de ajo".
final _ofPhrase = RegExp(
  r'\s(?:einer|eines|einem|eine|ein|der|des|vom|von|of|de|del)\s',
  caseSensitive: false,
);

List<String> _nounsOf(String phrase, String language) {
  final core = phrase.split(_phrase).first;
  final parts = core.split(_ofPhrase);
  final nouns = <String>[];
  void add(String word) {
    if (word.isNotEmpty && !nouns.contains(word)) nouns.add(word);
  }

  // The last part names the thing; a part before it counts too unless it
  // is a unit or a part ("Saft", "dientes", "cucharadas").
  final main = _phraseNouns(parts.last, language);
  main.forEach(add);
  for (final part in parts.sublist(0, parts.length - 1)) {
    for (final w in _phraseNouns(part, language)) {
      if (!_parts.contains(w) && !_partWords.contains(w)) add(w);
    }
  }
  return nouns;
}

/// The nouns of one phrase without "of": in German all capitalised words
/// but adjectives ("Rote Linsen", "Haferflocken Zart", "Nudeln Penne"),
/// otherwise the noun by [language].
List<String> _phraseNouns(String phrase, String language) {
  final raw = [
    for (final w in phrase.trim().split(RegExp(r'[\s\-]+')))
      if (w.isNotEmpty) w,
  ];
  bool kept(String w) =>
      !RegExp(r'\d').hasMatch(w) && !_notTheThing(_fold(w)) && _fold(w) != '';
  bool capital(String w) => w[0] != w[0].toLowerCase();
  if (raw.skip(1).any(capital)) {
    // German nouns are capitalised; the last one names the thing.
    final nouns = [
      for (final w in raw)
        if (capital(w) && kept(w)) _fold(w),
    ];
    return nouns.reversed.toList();
  }
  final words = [
    for (final w in raw)
      if (kept(w)) _fold(w),
  ];
  if (words.length <= 1) return words;
  return switch (language) {
    'es' => [words.first],
    // "Paprika rot" names Paprika; "Olive oil" from an English recipe oil.
    'de' when capital(raw.first) => [words.first, words.last],
    _ => [words.last],
  };
}

/// Units, amounts, articles and words that describe a product rather
/// than name it, folded.
bool _notTheThing(String w) => _fillers.contains(w) || _adjective(w);

const _fillers = {
  // German
  'type', 'typ', 'tk', 'bio', 'gr', 'ca', 'etwa', 'evtl', 'optional',
  'el', 'tl', 'msp', 'prise', 'prisen', 'dose', 'dosen', 'packung',
  'packungen', 'pck', 'pack', 'packchen', 'becher', 'glas', 'glaser',
  'bund', 'tasse', 'tassen', 'schuss', 'spritzer', 'handvoll', 'beutel',
  'flasche', 'flaschen', 'kg', 'g', 'ml', 'l', 'liter', 'gramm', 'art',
  'natur',
  'zart',
  'pulver',
  'klassisch',
  'classic',
  'original',
  'sorte',
  'grosse',
  'ein', 'eine', 'einer', 'der', 'die', 'das',
  // English
  'a', 'an', 'the', 'cup', 'cups', 'tbsp', 'tsp', 'tablespoon',
  'tablespoons', 'teaspoon', 'teaspoons', 'can', 'cans', 'pinch',
  'handful', 'package', 'bunch', 'jar', 'size',
  // Spanish
  'un', 'una', 'unos', 'unas', 'la', 'las', 'los', 'cucharada',
  'cucharadas', 'cucharadita', 'cucharaditas', 'taza', 'tazas', 'pizca',
  'lata', 'latas', 'paquete', 'punado', 'bote',
};

/// Adjectives, by their stem: "rote", "Grüne", "gehackt", "fresh",
/// "rojo", "blanca".
bool _adjective(String w) {
  for (final stem in _adjectiveStems) {
    if (w == stem) return true;
    if (w.startsWith(stem) &&
        const {
          'e',
          'er',
          'es',
          'en',
          'em',
          'o',
          'a',
          'os',
          'as',
          's',
        }.contains(w.substring(stem.length))) {
      return true;
    }
  }
  return false;
}

const _adjectiveStems = {
  // German
  'rot', 'grun', 'gelb', 'weiss', 'schwarz', 'braun', 'blau', 'lila',
  'gross', 'klein', 'mittel', 'frisch', 'ganz', 'halb', 'suss', 'sauer',
  'saur', 'scharf', 'mild', 'fein', 'grob', 'jung', 'alt', 'hart',
  'weich', 'dick', 'dunn', 'roh', 'reif', 'warm', 'kalt', 'flussig',
  'getrocknet', 'gehackt', 'gemahlen', 'gerostet', 'gerieben', 'geschalt',
  'gekocht', 'passiert', 'gerauchert', 'gesalzen', 'ungesalzen',
  'tiefgekuhlt', 'tiefgefroren', 'gefroren', 'gemischt', 'gewurfelt',
  'geschnitten', 'griechisch', 'italienisch', 'extra', 'light',
  // English
  'red', 'green', 'yellow', 'white', 'black', 'brown', 'large', 'small',
  'medium', 'big', 'fresh', 'whole', 'dried', 'chopped', 'ground',
  'grated', 'minced', 'sliced', 'diced', 'frozen', 'raw', 'ripe', 'hot',
  'cold', 'sweet', 'sour', 'virgin', 'unsalted', 'salted', 'plain',
  'natural', 'greek', 'boneless', 'skinless',
  // Spanish
  'roj', 'verde', 'amarill', 'blanc', 'negr', 'grande', 'pequen', 'fresc',
  'sec', 'picad', 'molid', 'rallad', 'enter', 'grieg', 'virgen', 'madur',
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
  'streifen',
  'kase',
};

/// Words that name a part of what follows ("dientes de ajo", "juice of a
/// lemon"); a part alone is not the thing.
const _partWords = {
  'saft',
  'zehe',
  'zehen',
  'juice',
  'zest',
  'clove',
  'cloves',
  'diente',
  'dientes',
  'zumo',
  'jugo',
};

/// Whether what is at home ([have]) is what the recipe wants ([wanted]):
/// the whole covers its part, a part not the whole ("Orangensaft" is no
/// oranges); a cheese is the same with or without "käse".
bool _sameThing(String have, String wanted) =>
    _samePlural(have, wanted) ||
    _compoundOf(have, wanted) ||
    _compoundOf(wanted, have) ||
    _partOf(wanted, have) ||
    (have == '${wanted}kase' && _cheeses.contains(wanted));

/// Cheeses also called "…käse" ("Parmesankäse"); "Kräuterkäse" is no herbs.
const _cheeses = {
  'parmesan',
  'pecorino',
  'gouda',
  'edamer',
  'emmentaler',
  'tilsiter',
  'cheddar',
  'mozzarella',
  'feta',
  'ricotta',
  'mascarpone',
  'gruyere',
  'manchego',
  'appenzeller',
};

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
