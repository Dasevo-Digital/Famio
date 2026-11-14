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

/// What a basic may be called besides its name: "schwarzer Pfeffer",
/// "olive oil", "Meersalz", "aceite de oliva" are still basics; "red
/// pepper", "sesame oil", "Puderzucker", "agua de coco" are not (#457).
const _stapleWords = {
  'schwarz',
  'weiss',
  'bunt',
  'gemahlen',
  'grob',
  'fein',
  'frisch',
  'braun',
  'brown',
  'black',
  'white',
  'ground',
  'coarse',
  'fine',
  'sea',
  'table',
  'kosher',
  'olive',
  'vegetable',
  'sunflower',
  'rapeseed',
  'canola',
  'neutral',
  'virgin',
  'extra',
  'cane',
  'tap',
  'cold',
  'warm',
  'negr',
  'blanc',
  'molid',
  'grues',
  'oliva',
  'girasol',
  'virgen',
  'moren',
  'caliente',
  'tibi',
};

/// Prefixes that leave a basic a basic ("Olivenöl", "Meersalz").
const _staplePrefixes = {
  'oliven',
  'olive',
  'raps',
  'sonnenblumen',
  'speise',
  'pflanzen',
  'meer',
  'jod',
  'kristall',
  'rohr',
  'tafel',
  'mineral',
  'stein',
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
/// names the same thing (#457). What counts is the word that names the
/// thing, not adjectives ("rote Paprika" is Paprika, so "Rote Linsen" are
/// no red pepper), units ("Dose") or phrases ("zum Braten"):
///
/// * in German the nouns as one compound, the last naming the thing:
///   "Tomaten Ketchup" is ketchup like "Tomatenketchup", "Knoblauch
///   Pulver" no fresh garlic, "Kerrygold Butter" butter;
/// * in English the last word ("chicken breasts"), in Spanish the first
///   ("pimiento rojo"); words before or after it must be there too, and a
///   word that makes it another product ("coconut", "coco", "sweet") on
///   both sides alike;
/// * "of", "von", "de" join a part to its thing: "Saft einer Zitrone",
///   "dientes de ajo" want the fruit and the garlic; otherwise the thing
///   is "salsa" in "salsa de tomate".
///
/// Nouns match in the singular or the plural ("Ei", "Eier"), as the end of
/// a compound ("Milch" covers "Vollmilch", "Reis" covers "Basmatireis"),
/// and the whole covers its part ("Knoblauch" covers "Knoblauchzehen",
/// "Zitronen" cover "Zitronensaft"), not the other way round
/// ("Paprikapulver" is no bell pepper). Alternatives ("Schmand oder Crème
/// fraîche") count each. [language] is the recipe's language, which says
/// where the noun of a phrase in lower case is.
bool inPantry(
  Ingredient ingredient,
  Iterable<PantryItem> pantry, {
  String? language,
}) {
  final lang = language ?? appLanguage;
  for (final wanted in _things(ingredient.name, lang)) {
    if (wanted.isStaple) return true;
    for (final p in pantry) {
      if (p.amount <= 0) continue;
      for (final have in _things(p.name, lang)) {
        if (have.covers(wanted)) return true;
      }
    }
  }
  return false;
}

/// The word that names the thing in [name], folded ("Äpfel" as "apfel"),
/// or ''.
String mainNoun(String name, {String? language}) =>
    _things(name, language ?? appLanguage).firstOrNull?.head ?? '';

/// One thing a name stands for: its head word, the other nouns and the
/// adjectives that come with it.
class _Thing {
  _Thing(this.head, this.nouns, this.adjectives);

  /// The word naming the thing; in German the whole compound.
  final String head;

  /// Other nouns of an English or Spanish name ("chicken" breasts).
  final Set<String> nouns;
  final Set<String> adjectives;

  late final Set<String> kinds = {
    for (final w in {...nouns, ...adjectives})
      if (_kindWords.any((k) => _kindWord(w, k))) _kindOf(w),
  };

  bool get isStaple {
    if (kinds.isNotEmpty) return false;
    if (!nouns.every(_stapleWord) || !adjectives.every(_stapleWord)) {
      return false;
    }
    if (_staples.contains(head)) return true;
    for (final staple in _staples) {
      if (staple.length >= 3 &&
          head.endsWith(staple) &&
          _staplePrefixes.contains(
            head.substring(0, head.length - staple.length),
          )) {
        return true;
      }
    }
    return head.endsWith('ol') &&
        _staplePrefixes.contains(head.substring(0, head.length - 2));
  }

  /// Whether this, at home, is what [wanted] asks for.
  bool covers(_Thing wanted) =>
      _sameThing(head, wanted.head) &&
      wanted.nouns.every(
        (n) => nouns.any((m) => m == n || _samePlural(m, n)),
      ) &&
      _sameKinds(kinds, wanted.kinds);
}

bool _stapleWord(String w) => _stapleWords.any(
  (s) => w == s || (w.startsWith(s) && w.length - s.length <= 2),
);

bool _sameKinds(Set<String> a, Set<String> b) =>
    a.length == b.length && a.every(b.contains);

/// Words that make another product of the thing they describe: "coconut
/// milk", "leche de coco", "sweet potatoes", "harina de almendras".
const _kindWords = {
  'kokos',
  'coconut',
  'coco',
  'mandel',
  'almond',
  'almendra',
  'hafer',
  'oat',
  'avena',
  'soja',
  'soy',
  'reis',
  'rice',
  'arroz',
  'erdnuss',
  'peanut',
  'cacahuete',
  'mani',
  'cashew',
  'anacardo',
  'haselnuss',
  'hazelnut',
  'avellana',
  'kakao',
  'cocoa',
  'cacao',
  'sweet',
  'dulce',
};

/// Whether [w] is the kind word [k], also as plural or adjective ("dulces").
bool _kindWord(String w, String k) =>
    w.startsWith(k) && w.length - k.length <= 2;

/// One word for a kind in every language.
String _kindOf(String w) {
  // The longest first: "cocoa" is no "coco".
  for (final k in _kindWords.toList()..sort((a, b) => b.length - a.length)) {
    if (_kindWord(w, k)) {
      return switch (k) {
        'coconut' || 'coco' => 'kokos',
        'almond' || 'almendra' => 'mandel',
        'oat' || 'avena' => 'hafer',
        'soy' => 'soja',
        'rice' || 'arroz' => 'reis',
        'peanut' || 'cacahuete' || 'mani' => 'erdnuss',
        'anacardo' => 'cashew',
        'hazelnut' || 'avellana' => 'haselnuss',
        'cocoa' || 'cacao' => 'kakao',
        'dulce' => 'sweet',
        _ => k,
      };
    }
  }
  return w;
}

final _names = <String, List<_Thing>>{};

/// The things an ingredient or pantry name stands for: one per alternative
/// ("A oder B"), remembered, as recipe lists ask again and again.
List<_Thing> _things(String name, String language) {
  if (_names.length > 4000) _names.clear();
  return _names.putIfAbsent('$language|$name', () {
    final core = name.split(RegExp(r'[,(;/]')).first;
    return [
      for (final alternative in core.split(
        RegExp(r'\s(?:oder|or|o|bzw\.?)\s', caseSensitive: false),
      ))
        ?_thingOf(alternative, language),
    ];
  });
}

/// What comes before a phrase like "zum Braten" or "aus der Dose".
final _phrase = RegExp(
  r'\s(?:zum|zur|für|fur|aus|mit|nach|ohne|in|im|und|sowie|à|a la|'
  r'for|from|with|in|and|para|con|en|y)\s',
  caseSensitive: false,
);

/// Joins two nouns: "Saft einer Zitrone", "juice of a lemon", "dientes de
/// ajo", "salsa de tomate".
final _ofPhrase = RegExp(
  r'\s(?:einer|eines|einem|eine|ein|der|des|vom|von|of|de|del)\s',
  caseSensitive: false,
);

_Thing? _thingOf(String phrase, String language) {
  final parts = phrase.split(_phrase).first.split(_ofPhrase);
  if (parts.length == 1) return _phraseThing(parts.single, language);
  // "Saft einer Zitrone", "a pinch of salt", "dientes de ajo": a part or a
  // measure before "of" wants what comes after it.
  final first = _phraseThing(parts.first, language);
  final last = _phraseThing(parts.last, language);
  if (first == null || _partWords.contains(first.head)) return last;
  if (last == null) return first;
  // German and English "of": the thing is at the end ("cream of mushroom
  // soup"); Spanish "de" describes what comes before it ("salsa de
  // tomate", "aceite de oliva").
  final (thing, rest) = language == 'es' ? (first, last) : (last, first);
  return _Thing(
    thing.head,
    {...thing.nouns, if (language != 'de') rest.head, ...rest.nouns},
    {...thing.adjectives, ...rest.adjectives},
  );
}

/// The thing of one phrase without "of" (see [inPantry]).
_Thing? _phraseThing(String phrase, String language) {
  final raw = [
    for (final w in phrase.trim().split(RegExp(r'[\s\-]+')))
      if (w.isNotEmpty) w,
  ];
  final adjectives = <String>{};
  final nouns = <String>[];
  for (final w in raw) {
    if (RegExp(r'\d').hasMatch(w)) continue;
    final f = _fold(w);
    if (f.length < 2 || _fillers.contains(f)) continue;
    if (_adjective(f)) {
      adjectives.add(f);
    } else if (!nouns.contains(f)) {
      nouns.add(f);
    }
  }
  if (nouns.isEmpty) return null;
  if (language == 'de') {
    // Nouns spaced like "Tomaten Ketchup" are one compound, as in German.
    return _Thing(_formOf(nouns.join()), const {}, adjectives);
  }
  var head = language == 'es' ? nouns.first : nouns.last;
  // Breadcrumbs are no bread; grated cheese is cheese.
  if (head == 'pan' && adjectives.any((a) => a.startsWith('rallad'))) {
    head = 'panrallado';
  }
  return _Thing(_formOf(head), {
    for (final n in nouns)
      if (n != head) n,
  }, adjectives);
}

/// The thing a few names really are: paprika "edelsüß" is the powder,
/// broth as powder is still broth.
String _formOf(String head) {
  if (head.startsWith('paprika') &&
      {
        'paprikaedelsuss',
        'paprikarosenscharf',
        'paprikadelikatess',
      }.contains(head)) {
    return 'paprikapulver';
  }
  for (final form in ['pulver', 'granulat']) {
    if (head.endsWith(form)) {
      final stem = head.substring(0, head.length - form.length);
      if (stem.endsWith('bruhe') ||
          stem.endsWith('bouillon') ||
          stem.endsWith('fond')) {
        return stem;
      }
    }
  }
  return head;
}

/// Units, amounts, articles and words that describe a product rather
/// than name it, folded.
const _fillers = {
  // German
  'type', 'typ', 'tk', 'bio', 'gr', 'ca', 'etwa', 'evtl', 'optional',
  'el', 'tl', 'msp', 'prise', 'prisen', 'dose', 'dosen', 'packung',
  'packungen', 'pck', 'pack', 'packchen', 'becher', 'glas', 'glaser',
  'bund', 'tasse', 'tassen', 'schuss', 'spritzer', 'handvoll', 'beutel',
  'flasche', 'flaschen', 'kg', 'g', 'ml', 'l', 'liter', 'gramm', 'art',
  'natur',
  'zart',
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
  'ringe',
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
    // "Ei" + s is "Eis": not for the shortest words.
    's' => short.length >= 3,
    // Spanish: "limón", "limones".
    'es' => short.length >= 3,
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
