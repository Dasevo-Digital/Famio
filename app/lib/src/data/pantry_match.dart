import 'package:famio_client/famio_client.dart';

import 'family_extras.dart';
import 'search.dart';
import '../l10n.dart';

/// How much of a recipe the pantry covers.
class RecipeStock {
  const RecipeStock(this.have, this.missing);

  final List<Ingredient> have;
  final List<Ingredient> missing;

  int get total => have.length + missing.length;
  double get share => total == 0 ? 0 : have.length / total;
}

/// Whether [ingredient] is at home: a pantry item with some left that
/// names the same thing, or a basic every kitchen has (#457). What counts
/// is the word that names the thing, not what is said about it:
///
/// * German names their nouns by capitals: "Kartoffeln festkochend",
///   "Tomaten stückig", "etwas Öl", "heißes Wasser" are potatoes, tomatoes,
///   oil and water. Spaced nouns are one compound ("Kidney Bohnen"), and
///   the first or last noun counts as well ("Reis Basmati", "Kerrygold
///   Butter", "Nudeln Penne"), unless a product comes after the first
///   ("Tomaten Ketchup", "Knoblauch Pulver", "Erdbeer Joghurt"). A compound
///   is its last part ("Vollmilch" is milk, "Basmatireis" rice) unless the
///   front makes another thing ("Kokosmilch", "Süßkartoffeln",
///   "Kichererbsen", "Knoblauch").
/// * In English the last noun names the thing ("chicken stock"), in
///   Spanish the first ("pimiento rojo"); "of", "von", "de" join a part to
///   its thing ("juice of a lemon", "dientes de ajo") or describe it
///   ("salsa de tomate", "leche de coco").
/// * Some words make another product of the same thing: "coconut milk",
///   "sour cream", "spring onions", "saure Sahne", "arroz" in "vinagre de
///   arroz". They must be on both sides alike.
/// * A part is covered by its whole ("Knoblauchzehen", "Zitronensaft",
///   "lemon juice" by garlic and lemons), a piece also covers the whole
///   ("Speckwürfel", "chicken breasts" are bacon and chicken), what is
///   made of it does not ("Orangensaft", "Paprikapulver", "Zwiebelringe").
///
/// Nouns match in the singular or the plural ("Ei", "Eier"). Alternatives
/// ("Schmand oder Crème fraîche") count each. [language] is the recipe's
/// language; pantry names are read the same way.
bool inPantry(
  Ingredient ingredient,
  Iterable<PantryItem> pantry, {
  String? language,
}) {
  final lang = language ?? appLanguage;
  for (final wanted in _things(ingredient.name, lang)) {
    if (wanted.staple) return true;
    for (final p in pantry) {
      if (p.amount <= 0) continue;
      for (final have in _things(p.name, lang)) {
        if (have.covers(wanted, lang)) return true;
      }
    }
  }
  return false;
}

/// The word that names the thing in [name], folded ("Äpfel" as "apfel"),
/// or ''.
String mainNoun(String name, {String? language}) =>
    _things(name, language ?? appLanguage).firstOrNull?.names.first ?? '';

/// One thing a name stands for.
class _Thing {
  _Thing(this.names, this.kinds, {this.part, this.staple = false});

  /// What it may be called, folded: in German the compound and its nouns,
  /// elsewhere the noun that names it, or the whole a part is of.
  final Set<String> names;

  /// Words that make it another product (see [_kindOf]).
  final Set<String> kinds;

  /// In English and Spanish: the part of [names] it is ("breasts",
  /// "juice", "dientes"), if any.
  final String? part;

  final bool staple;

  /// Whether this, at home, is what [wanted] asks for.
  bool covers(_Thing wanted, String language) {
    if (kinds.length != wanted.kinds.length ||
        !kinds.every(wanted.kinds.contains)) {
      return false;
    }
    // Juice at home is no lemon; a piece of meat is the meat.
    if (part != null &&
        !_cuts.contains(part) &&
        (wanted.part == null || !_samePlural(part!, wanted.part!))) {
      return false;
    }
    for (final have in names) {
      for (final want in wanted.names) {
        if (_same(have, want, language)) return true;
      }
    }
    return false;
  }
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

/// What comes after the thing: "zum Braten", "aus der Dose", "und
/// Pfeffer", "& Pfeffer".
final _phrase = RegExp(
  r'\s(?:zum|zur|für|fur|aus|mit|nach|ohne|in|im|und|sowie|à|a la|'
  r'for|from|with|in|and|to|para|con|en|y)\s|\s?&\s?',
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
  final first = _phraseThing(parts.first, language);
  final last = _phraseThing(parts.last, language);
  if (last == null) return first;
  // "Saft einer Zitrone", "a pinch of salt", "dientes de ajo": a part or a
  // measure before "of" wants what comes after it.
  if (first == null) return last;
  final firstName = first.names.first;
  if (_partWords.contains(firstName)) {
    return _Thing(last.names, last.kinds, part: firstName, staple: last.staple);
  }
  // German and English "of": the thing is at the end ("cream of mushroom
  // soup"); Spanish "de" describes what comes before it ("salsa de
  // tomate", "aceite de oliva", "leche de coco").
  final (thing, rest) = language == 'es' ? (first, last) : (last, first);
  final described = rest.names.first;
  return _Thing(
    thing.names,
    {...thing.kinds, ...rest.kinds, if (_isKind(described)) _kindOf(described)},
    part: thing.part,
    // "aceite de oliva", "olive oil": the words of the rest are for a basic.
    staple: thing.staple && rest.kinds.isEmpty && rest.names.every(_stapleWord),
  );
}

/// A word of a name: as written, and folded.
typedef _Word = ({String raw, String folded});

/// The thing of one phrase without "of" (see [inPantry]).
_Thing? _phraseThing(String phrase, String language) {
  final words = <_Word>[
    for (final w in phrase.trim().split(RegExp(r'[\s\-]+')))
      if (w.isNotEmpty && !RegExp(r'\d').hasMatch(w))
        (raw: w, folded: _fold(w)),
  ]..removeWhere((w) => w.folded.length < 2 || _isFiller(w.folded, language));
  if (words.isEmpty) return null;
  return language == 'de' ? _germanThing(words) : _otherThing(words, language);
}

/// German: nouns have capitals. Without any (typed in a hurry, or an
/// English name in a German app) like the other languages, but with the
/// compounds of German.
_Thing? _germanThing(List<_Word> words) {
  bool capital(_Word w) =>
      w.raw[0] != w.raw[0].toLowerCase() && !_adjective(w.folded);
  final byCapitals = words.any(capital);
  final nouns = [
    for (final w in words)
      if (byCapitals ? capital(w) : !_adjective(w.folded)) w.folded,
  ];
  final described = [
    for (final w in words)
      if (!nouns.contains(w.folded)) w.folded,
  ];
  if (nouns.isEmpty) return null;
  final kinds = {
    for (final w in described)
      if (_isKind(w)) _kindOf(w),
  };
  final compound = _formOf(nouns.join(), described);
  final names = {compound};
  if (nouns.length > 1) {
    final made = nouns.skip(1).any(_isProduct);
    if (!made) names.add(_formOf(nouns.first, described));
    final last = nouns.last;
    if (!_isProduct(last) &&
        !_parts.contains(last) &&
        !_otherFronts.contains(nouns.first)) {
      names.add(_formOf(last, described));
    }
  }
  // Lower-case words with capital nouns describe it ("heißes Wasser");
  // without capitals they must be words for a basic ("olive oil").
  final staple =
      kinds.isEmpty &&
      _stapleName(compound) &&
      (byCapitals || described.every(_stapleWord));
  return _Thing(names, kinds, staple: staple);
}

/// English and Spanish: the last noun names the thing, in Spanish the
/// first.
_Thing? _otherThing(List<_Word> words, String language) {
  final adjectives = <String>[];
  final nouns = <String>[];
  for (final w in words) {
    if (_adjective(w.folded)) {
      adjectives.add(w.folded);
    } else if (!nouns.contains(w.folded)) {
      nouns.add(w.folded);
    }
  }
  if (nouns.isEmpty) return null;
  var head = language == 'es' ? nouns.first : nouns.last;
  // Breadcrumbs are no bread; grated cheese is cheese.
  if (head == 'pan' && adjectives.any((a) => a.startsWith('rallad'))) {
    head = 'panrallado';
  }
  final others = [
    for (final n in nouns)
      if (n != head) n,
  ];
  // "garlic cloves", "chicken breasts", "egg yolks": the part of a whole.
  String? part;
  var names = {head};
  if (_partWords.contains(head) && others.isNotEmpty) {
    part = head;
    names = {language == 'es' ? others.first : others.last};
  }
  // "cheddar cheese" is cheddar, "queso manchego" manchego.
  if (const {'cheese', 'queso'}.contains(head)) {
    names.addAll(others.where(_cheeses.contains));
  }
  final described = [...adjectives, ...others.where((n) => !names.contains(n))];
  final kinds = {
    for (final w in described)
      if (_isKind(w) || (w == 'cream' && head == 'cheese')) _kindOf(w),
  };
  // Sweet paprika is paprika (the mild one), sweet potatoes no potatoes.
  if (const {'paprika', 'pimenton'}.contains(head)) kinds.remove('sweet');
  final staple =
      part == null &&
      kinds.isEmpty &&
      _stapleName(head) &&
      described.every(_stapleWord);
  return _Thing(names, kinds, part: part, staple: staple);
}

/// What a few names really are: paprika "edelsüß" is the powder, broth as
/// powder is still broth, the yolk is of the egg.
String _formOf(String name, List<String> described) {
  if (name == 'paprika' &&
      described.any(
        (w) => const {'edelsuss', 'rosenscharf', 'delikatess'}.contains(w),
      )) {
    return 'paprikapulver';
  }
  if (const {
    'paprikaedelsuss',
    'paprikarosenscharf',
    'paprikadelikatess',
  }.contains(name)) {
    return 'paprikapulver';
  }
  if (const {'eigelb', 'eiweiss', 'eidotter'}.contains(name)) return 'ei';
  for (final form in ['pulver', 'granulat']) {
    if (name.endsWith(form)) {
      final stem = name.substring(0, name.length - form.length);
      if (stem.endsWith('bruhe') ||
          stem.endsWith('bouillon') ||
          stem.endsWith('fond')) {
        return stem;
      }
    }
  }
  return name;
}

/// Whether [have], a name at home, is the same as [want] (see [inPantry]).
bool _same(String have, String want, String language) {
  if (_samePlural(have, want)) return true;
  if (have == '${want}kase' && _cheeses.contains(want)) return true;
  if (want == '${have}kase' && _cheeses.contains(have)) return true;
  if (language != 'de') return false;
  return _compoundOf(want, have) ||
      _compoundOf(have, want) ||
      _pieceOf(want, have, _parts) ||
      _pieceOf(have, want, _cuts);
}

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

/// Whether [word] is a compound ending in [head] ("vollmilch", "milch")
/// that is still [head] ("kokosmilch" is not).
bool _compoundOf(String word, String head) {
  if (head.length < 4 || _notTheirEnd.contains(word)) return false;
  for (final end in [head, '${head}n', '${head}en', '${head}er', '${head}e']) {
    if (word.length > end.length && word.endsWith(end)) {
      final front = word.substring(0, word.length - end.length);
      return !_otherFronts.any(
        (f) => front == f || front == '${f}n' || front == '${f}e',
      );
    }
  }
  return false;
}

/// Whether [word] is [thing] with an ending of [endings] ("knoblauchzehen",
/// "knoblauch").
bool _pieceOf(String word, String thing, Set<String> endings) {
  if (thing.length < 4) return false;
  for (final start in [thing, '${thing}n', '${thing}s', '${thing}en']) {
    if (word.length > start.length &&
        word.startsWith(start) &&
        endings.contains(word.substring(start.length))) {
      return true;
    }
  }
  // "Zitronen" covers "Zitronensaft": the plural before the part.
  if (thing.endsWith('n') || thing.endsWith('e')) {
    final stem = thing.substring(0, thing.length - 1);
    return stem.length >= 4 &&
        word.startsWith(stem) &&
        endings.contains(
          word.substring(stem.length).replaceFirst(RegExp(r'^n'), ''),
        );
  }
  return false;
}

String _fold(String word) => foldForSearch(word)
    .replaceAll('ae', 'a')
    .replaceAll('oe', 'o')
    .replaceAll('ue', 'u')
    .replaceAll(RegExp(r'[^a-z]'), '');

// --- Words -------------------------------------------------------------------

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

/// Fronts that leave a basic a basic ("Olivenöl", "Meersalz").
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

bool _stapleName(String name) {
  if (_staples.contains(name)) return true;
  for (final staple in _staples) {
    if (staple.length >= 2 &&
        name.endsWith(staple) &&
        _staplePrefixes.contains(
          name.substring(0, name.length - staple.length),
        )) {
      return true;
    }
  }
  return false;
}

/// What a basic may be called besides its name: "schwarzer Pfeffer",
/// "olive oil", "boiling water", "sal gorda" are still basics; "red
/// pepper", "sesame oil", "agua de coco" are not.
const _stapleWords = {
  'schwarz',
  'weiss',
  'bunt',
  'gemahlen',
  'grob',
  'fein',
  'frisch',
  'braun',
  'neutral',
  'brown',
  'black',
  'white',
  'ground',
  'freshly',
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
  'virgin',
  'extra',
  'cane',
  'granulated',
  'tap',
  'cold',
  'warm',
  'lukewarm',
  'hot',
  'boiling',
  'negr',
  'blanc',
  'molid',
  'grues',
  'gord',
  'fin',
  'oliva',
  'girasol',
  'virgen',
  'moren',
  'caliente',
  'templad',
  'tibi',
};

bool _stapleWord(String w) => _stapleWords.any(
  (s) => w == s || (w.startsWith(s) && w.length - s.length <= 2),
);

/// Words that make another product of the thing they come with: "coconut
/// milk", "leche de coco", "sweet potatoes", "sour cream", "spring
/// onions", "saure Sahne".
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
  'sour',
  'saur',
  'spring',
  'cayenne',
  'sesame',
  'sesamo',
  'powdered',
  'icing',
  'glas',
};

bool _isKind(String w) => _kindWords.any((k) => _kindWord(w, k));

/// Whether [w] is the kind word [k], also as plural or adjective ("dulces",
/// "saure").
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
        'saur' => 'sour',
        'sesamo' => 'sesame',
        'icing' || 'glas' => 'powdered',
        _ => k,
      };
    }
  }
  return w;
}

/// Fronts of a compound that make it another thing than its end:
/// "Kokosmilch", "Süßkartoffeln", "Kichererbsen", "Reisnudeln",
/// "Zuckererbsen", "Vanillezucker".
const _otherFronts = {
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
  'suss',
  'kicher',
  'knob',
  'krauter',
  'vanille',
  'cayenne',
  'sesam',
  'puder',
  'gelier',
  'zucker',
  'sauer',
};

/// Compounds that are not their end although the front is no
/// [_otherFronts] word elsewhere ("Frischmilch" is milk).
const _notTheirEnd = {'frischkase'};

/// Nouns after the first that make a product of it: "Tomaten Ketchup",
/// "Knoblauch Pulver", "Erdbeer Joghurt", "Mais Chips".
bool _isProduct(String noun) => const {
  'ketchup',
  'pulver',
  'granulat',
  'mark',
  'saft',
  'sosse',
  'sauce',
  'sose',
  'paste',
  'pesto',
  'chips',
  'flips',
  'kekse',
  'keks',
  'schokolade',
  'essig',
  'creme',
  'pudding',
  'tee',
  'mus',
  'brei',
  'puree',
  'joghurt',
  'bruhe',
  'fond',
  'aufstrich',
  'konfiture',
  'marmelade',
  'gelee',
  'sirup',
  'fix',
  'bolognese',
}.contains(noun);

/// Endings that name a part or piece of the thing before them, covered by
/// it ("Knoblauchzehe", "Zimtstange", "Zitronensaft", "Zwiebelringe").
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
  'breast',
  'breasts',
  'thigh',
  'thighs',
  'fillet',
  'fillets',
  'yolk',
  'yolks',
};

/// Pieces that, at home, are the thing as well ("Speckwürfel" are bacon,
/// "chicken breasts" chicken); "Zwiebelringe", "Zimtstangen" or juice are
/// not.
const _cuts = {
  'wurfel',
  'filet',
  'filets',
  'scheibe',
  'scheiben',
  'stuck',
  'stucke',
  'zehe',
  'zehen',
  'diente',
  'dientes',
  'clove',
  'cloves',
  'breast',
  'breasts',
  'thigh',
  'thighs',
  'fillet',
  'fillets',
  'yolk',
  'yolks',
};

/// Words that name a part of what follows or comes with them ("dientes de
/// ajo", "juice of a lemon", "garlic cloves"); a part alone is not the
/// thing.
const _partWords = {
  'saft',
  'abrieb',
  'schale',
  'zehe',
  'zehen',
  'juice',
  'zest',
  'clove',
  'cloves',
  'breast',
  'breasts',
  'thigh',
  'thighs',
  'fillet',
  'fillets',
  'yolk',
  'yolks',
  'whites',
  'diente',
  'dientes',
  'zumo',
  'jugo',
};

/// Cheeses also called "…käse", "… cheese", "queso …".
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

/// Units, amounts, articles and words that describe a product rather than
/// name it, folded. "Glas" is a jar in German only ("azúcar glas").
bool _isFiller(String w, String language) =>
    _fillers.contains(w) || (language == 'de' && _germanFillers.contains(w));

const _germanFillers = {'glas', 'glaser'};

const _fillers = {
  // German
  'type', 'typ', 'tk', 'bio', 'gr', 'ca', 'etwa', 'etwas', 'wenig',
  'reichlich', 'evtl', 'optional', 'nb', 'el', 'tl', 'msp', 'prise',
  'prisen', 'dose', 'dosen', 'packung', 'packungen', 'pck', 'pack',
  'packchen', 'becher', 'bund', 'tasse', 'tassen', 'schuss', 'spritzer',
  'handvoll', 'beutel', 'flasche', 'flaschen', 'kg', 'g', 'ml', 'l',
  'liter', 'gramm', 'art', 'natur', 'zart', 'klassisch', 'classic',
  'original', 'sorte', 'grosse', 'no', 'nr', 'ein', 'eine', 'einer', 'der',
  'die', 'das',
  // English
  'a', 'an', 'the', 'cup', 'cups', 'tbsp', 'tsp', 'tablespoon',
  'tablespoons', 'teaspoon', 'teaspoons', 'can', 'cans', 'pinch',
  'handful', 'package', 'bunch', 'jar', 'size', 'some',
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
  'geschnitten', 'griechisch', 'italienisch', 'extra', 'light', 'neutral',
  // English
  'red', 'green', 'yellow', 'white', 'black', 'brown', 'large', 'small',
  'medium', 'big', 'fresh', 'freshly', 'whole', 'dried', 'chopped',
  'ground', 'grated', 'minced', 'sliced', 'diced', 'frozen', 'raw', 'ripe',
  'hot', 'cold', 'lukewarm', 'boiling', 'sweet', 'sour', 'virgin',
  'unsalted', 'salted', 'plain', 'natural', 'greek', 'boneless',
  'skinless', 'melted', 'softened', 'heavy', 'granulated',
  'canned', 'baby',
  // Spanish
  'roj', 'verde', 'amarill', 'blanc', 'negr', 'grande', 'pequen', 'fresc',
  'sec', 'picad', 'molid', 'rallad', 'enter', 'grieg', 'virgen', 'madur',
  'gord', 'fin', 'templad', 'derretid',
};

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
