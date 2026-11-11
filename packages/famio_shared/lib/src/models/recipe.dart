import '../sync_record.dart';
import 'chat.dart';
import '../texts.dart';

/// What 100 g (or 100 ml) of the product an ingredient is linked to
/// contain, from Open Food Facts. Kept in the recipe, so everyone sees the
/// values, also offline, and only the one linking asks Open Food Facts.
class Nutrition {
  const Nutrition({
    required this.code,
    required this.product,
    required this.kcal,
    this.protein,
    this.fat,
    this.carbs,
    this.sugar,
    this.salt,
    this.pieceGrams,
    this.packageGrams,
  });

  factory Nutrition.fromJson(Map<String, Object?> json) => Nutrition(
    code: json['code'] as String? ?? '',
    product: json['product'] as String? ?? '',
    kcal: (json['kcal'] as num?)?.toDouble() ?? 0,
    protein: (json['protein'] as num?)?.toDouble(),
    fat: (json['fat'] as num?)?.toDouble(),
    carbs: (json['carbs'] as num?)?.toDouble(),
    sugar: (json['sugar'] as num?)?.toDouble(),
    salt: (json['salt'] as num?)?.toDouble(),
    pieceGrams: (json['pieceGrams'] as num?)?.toDouble(),
    packageGrams: (json['packageGrams'] as num?)?.toDouble(),
  );

  /// The product's barcode at Open Food Facts.
  final String code;

  /// Its name, e.g. "Weizenmehl Type 405 (Aurora)".
  final String product;
  final double kcal;
  final double? protein;
  final double? fat;
  final double? carbs;
  final double? sugar;
  final double? salt;

  /// Weight of one piece ("2 Eier"): the product's serving, or what the
  /// family entered.
  final double? pieceGrams;

  /// Weight of one package ("1 Dose Tomaten").
  final double? packageGrams;

  Nutrition copyWith({double? pieceGrams, double? packageGrams}) => Nutrition(
    code: code,
    product: product,
    kcal: kcal,
    protein: protein,
    fat: fat,
    carbs: carbs,
    sugar: sugar,
    salt: salt,
    pieceGrams: pieceGrams ?? this.pieceGrams,
    packageGrams: packageGrams ?? this.packageGrams,
  );

  Map<String, Object?> toJson() => {
    'code': code,
    'product': product,
    'kcal': kcal,
    'protein': ?protein,
    'fat': ?fat,
    'carbs': ?carbs,
    'sugar': ?sugar,
    'salt': ?salt,
    'pieceGrams': ?pieceGrams,
    'packageGrams': ?packageGrams,
  };
}

/// Nutrients of one serving, summed over the linked ingredients.
class ServingNutrition {
  const ServingNutrition({
    required this.kcal,
    required this.protein,
    required this.fat,
    required this.carbs,
    required this.counted,
    required this.total,
  });

  final double kcal;
  final double protein;
  final double fat;
  final double carbs;

  /// Ingredients that went into the sum, of [total] with an amount.
  final int counted;
  final int total;
}

/// [v] in German notation with at most [decimals] places and no trailing
/// zeros ("12,5", "0,125", "3"); thirds as "⅓"/"⅔" ("1 ⅓"), which have no
/// exact decimal.
String formatAmount(double v, {int decimals = 3}) {
  final whole = v.floor();
  final part = v - whole;
  for (final (value, glyph) in const [(1 / 3, '⅓'), (2 / 3, '⅔')]) {
    if ((part - value).abs() < 1e-6) {
      return whole == 0 ? glyph : '$whole $glyph';
    }
  }
  var text = v.toStringAsFixed(decimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  }
  return text.replaceAll('.', ',');
}

/// [existing] (the quantity of an item on the shopping list) plus [item],
/// as text, or null when they cannot be added up without losing something:
/// [existing] is more than one amount ("500 g + 1 Pck.", "2 große"), one of
/// them is a range, or the units differ and are not grams and kilograms or
/// millilitres and litres.
String? addQuantities(String existing, Ingredient item) {
  final add = item.amount;
  final text = existing.trim();
  if (add == null || item.upTo != null || text.isEmpty) return null;
  final before = Ingredient.parse('$text x');
  final had = before.amount;
  if (before.name != 'x' || had == null || before.upTo != null) return null;
  String result(double amount, String unit) =>
      Ingredient(name: '', amount: amount, unit: unit).exactQuantity();
  if (before.unit.toLowerCase() == item.unit.toLowerCase()) {
    return result(had + add, item.unit);
  }
  final a = _metric[before.unit.toLowerCase()];
  final b = _metric[item.unit.toLowerCase()];
  if (a == null || b == null || a.$1 != b.$1) return null;
  final total = had * a.$2 + add * b.$2;
  final (small, large) = a.$1 == 'g' ? ('g', 'kg') : ('ml', 'l');
  // In kilograms or litres only when nothing gets rounded away (whole
  // grams or millilitres); otherwise in the small unit.
  final whole = (total - total.roundToDouble()).abs() < 1e-6;
  return total >= 1000 && whole
      ? result(total.roundToDouble() / 1000, large)
      : result(total, small);
}

/// Units that convert: base unit and factor.
const _metric = {
  'mg': ('g', 0.001),
  'g': ('g', 1.0),
  'kg': ('g', 1000.0),
  'ml': ('ml', 1.0),
  'cl': ('ml', 10.0),
  'dl': ('ml', 100.0),
  'l': ('ml', 1000.0),
};

/// One line of a recipe: "200 g Mehl", "2 Eier", "Salz".
class Ingredient {
  const Ingredient({
    required this.name,
    this.amount,
    this.upTo,
    this.unit = '',
    this.nutrition,
  });

  /// Parses a free text line like "1 1/2 EL Zucker", "200g Mehl" or
  /// "½ TL Salz".
  factory Ingredient.parse(String line) {
    var text = line.trim();
    const fractions = {'½': 0.5, '¼': 0.25, '¾': 0.75, '⅓': 1 / 3, '⅔': 2 / 3};
    double? amount;
    double? upTo;
    // "1 1/2", "1/2", "1,5", "2½", "½", also ranges like "2-3".
    final m = RegExp(
      r'^(?:(\d+)\s+(\d+)/(\d+)|(\d+)/(\d+)|(\d+(?:[.,]\d+)?)\s*([½¼¾⅓⅔])?|([½¼¾⅓⅔]))'
      r'(?:\s*[-–]\s*(\d+(?:[.,]\d+)?(?:\s*[½¼¾⅓⅔])?|[½¼¾⅓⅔]))?',
    ).firstMatch(text);
    if (m != null) {
      int g(int i) => int.parse(m.group(i)!);
      if (m.group(1) != null) {
        amount = g(1) + (g(3) == 0 ? 0 : g(2) / g(3));
      } else if (m.group(4) != null) {
        amount = g(5) == 0 ? null : g(4) / g(5);
      } else if (m.group(6) != null) {
        amount =
            double.parse(m.group(6)!.replaceAll(',', '.')) +
            (fractions[m.group(7)] ?? 0);
      } else {
        amount = fractions[m.group(8)];
      }
      if (m.group(9) case final top?) {
        final glyph = fractions[top[top.length - 1]];
        final digits = glyph == null ? top : top.substring(0, top.length - 1);
        final whole = digits.trim().isEmpty
            ? 0.0
            : double.parse(digits.trim().replaceAll(',', '.'));
        final v = whole + (glyph ?? 0);
        if (amount != null && v > amount) upTo = v;
      }
      text = text.substring(m.group(0)!.length).trim();
    }
    var unit = '';
    if (amount != null) {
      final u = RegExp(
        r'^(kg|g|mg|l|ml|cl|dl|EL|TL|Msp\.?|Prisen?|Pck\.?|Päckchen|Dosen?|Becher|Bund|Stück|Stk\.?|Scheiben?|Zehen?|Tassen?|Glas|Handvoll|cm)(?=\s|$)',
        caseSensitive: false,
      ).firstMatch(text);
      if (u != null) {
        unit = u.group(1)!;
        text = text.substring(u.group(0)!.length).trim();
      }
    }
    return Ingredient(name: text, amount: amount, upTo: upTo, unit: unit);
  }

  factory Ingredient.fromJson(Map<String, Object?> json) => Ingredient(
    name: json['name'] as String? ?? '',
    amount: (json['amount'] as num?)?.toDouble(),
    upTo: (json['upTo'] as num?)?.toDouble(),
    unit: json['unit'] as String? ?? '',
    nutrition: json['nutrition'] is Map
        ? Nutrition.fromJson((json['nutrition'] as Map).cast())
        : null,
  );

  final String name;
  final double? amount;

  /// Upper end of a range like "2–3 Eier" ([amount] is the lower end).
  final double? upTo;
  final String unit;

  /// The product it is linked to, for nutrients; null if not linked.
  final Nutrition? nutrition;

  /// The same with [nutrition] linked (null: unlinked).
  Ingredient withNutrition(Nutrition? nutrition) => Ingredient(
    name: name,
    amount: amount,
    upTo: upTo,
    unit: unit,
    nutrition: nutrition,
  );

  /// The same for [factor] times the servings.
  Ingredient scaled(double factor) => Ingredient(
    name: name,
    amount: amount == null ? null : amount! * factor,
    upTo: upTo == null ? null : upTo! * factor,
    unit: unit,
    nutrition: nutrition,
  );

  /// The amount in grams (millilitres count as grams), as far as the unit
  /// tells: spoons by their usual size, pieces and packages by the linked
  /// product; null if unknown.
  double? get grams {
    final a = amount;
    if (a == null) return null;
    if (byPackage) {
      final g = nutrition?.packageGrams;
      return g == null ? null : a * g;
    }
    final factor = switch (unit.toLowerCase().replaceAll('.', '')) {
      'g' || 'ml' => 1.0,
      'kg' || 'l' => 1000.0,
      'mg' => 0.001,
      'cl' => 10.0,
      'dl' => 100.0,
      'el' => 15.0,
      'tl' => 5.0,
      'msp' || 'prise' || 'prisen' => 0.5,
      'tasse' || 'tassen' => 150.0,
      _ => nutrition?.pieceGrams,
    };
    return factor == null ? null : a * factor;
  }

  /// Counted in packages ("1 Dose Tomaten"): weighed by the package.
  bool get byPackage => const {
    'pck',
    'päckchen',
    'dose',
    'dosen',
    'becher',
    'glas',
  }.contains(unit.toLowerCase().replaceAll('.', ''));

  /// The amount for [factor] times the servings, as text ("1,5 kg"),
  /// rounded for reading. Ranges read "2–3".
  String quantity([double factor = 1]) {
    if (amount == null) return unit;
    String round(double v) => v >= 10
        ? v.round().toString()
        : (v * 10).round() % 10 == 0
        ? v.round().toString()
        : v.toStringAsFixed(1).replaceAll('.', ',');
    var text = round(amount! * factor);
    if (upTo case final top?) text = '$text–${round(top * factor)}';
    return unit.isEmpty ? text : '$text $unit';
  }

  /// The amount as text without rounding it away ("0,25 l", "12,5 g",
  /// "⅓ TL", "2–3"), so that [Ingredient.parse] reads back the same:
  /// for editing and for the shopping list.
  String exactQuantity({int decimals = 3}) {
    if (amount == null) return unit;
    var text = formatAmount(amount!, decimals: decimals);
    if (upTo case final top?) {
      text = '$text–${formatAmount(top, decimals: decimals)}';
    }
    return unit.isEmpty ? text : '$text $unit';
  }

  /// The line as it is edited: [exactQuantity] and the name.
  String get editText =>
      [exactQuantity(), name].where((s) => s.isNotEmpty).join(' ');

  @override
  String toString() => [quantity(), name].where((s) => s.isNotEmpty).join(' ');

  Map<String, Object?> toJson() => {
    'name': name,
    'amount': ?amount,
    'upTo': ?upTo,
    if (unit.isNotEmpty) 'unit': unit,
    'nutrition': ?nutrition?.toJson(),
  };
}

/// A family recipe, stored in `Collections.recipes`.
class Recipe {
  const Recipe({
    required this.id,
    required this.title,
    this.servings = 4,
    this.ingredients = const [],
    this.steps = '',
    this.minutes,
    this.source = '',
    this.photo,
    this.tags = const [],
    this.favorite = false,
  });

  factory Recipe.fromRecord(SyncRecord r) => Recipe(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    servings: (r.data['servings'] as num?)?.toInt() ?? 4,
    ingredients: [
      for (final i in r.data['ingredients'] as List? ?? const [])
        Ingredient.fromJson((i as Map).cast()),
    ],
    steps: r.data['steps'] as String? ?? '',
    minutes: (r.data['minutes'] as num?)?.toInt(),
    source: r.data['source'] as String? ?? '',
    photo: FileRef.fromJson(r.data['photo']),
    tags: [for (final t in r.data['tags'] as List? ?? const []) t as String],
    favorite: r.data['favorite'] as bool? ?? false,
  );

  final String id;
  final String title;
  final int servings;
  final List<Ingredient> ingredients;

  /// Preparation, one step per line.
  final String steps;
  final int? minutes;

  /// Where it comes from (web address, "Oma").
  final String source;
  final FileRef? photo;
  final List<String> tags;
  final bool favorite;

  /// Nutrients of one serving from the linked ingredients; null if none
  /// is linked.
  ServingNutrition? get nutritionPerServing {
    if (!ingredients.any((i) => i.nutrition != null)) return null;
    var kcal = 0.0, protein = 0.0, fat = 0.0, carbs = 0.0;
    var counted = 0;
    for (final i in ingredients) {
      final n = i.nutrition;
      final grams = i.grams;
      if (n == null || grams == null) continue;
      final share = grams / 100 / servings;
      kcal += n.kcal * share;
      protein += (n.protein ?? 0) * share;
      fat += (n.fat ?? 0) * share;
      carbs += (n.carbs ?? 0) * share;
      counted++;
    }
    return ServingNutrition(
      kcal: kcal,
      protein: protein,
      fat: fat,
      carbs: carbs,
      counted: counted,
      // "Salz", "Pfeffer" without an amount do not count.
      total: ingredients.where((i) => i.amount != null).length,
    );
  }

  Recipe copyWith({bool? favorite, List<Ingredient>? ingredients}) => Recipe(
    id: id,
    title: title,
    servings: servings,
    ingredients: ingredients ?? this.ingredients,
    steps: steps,
    minutes: minutes,
    source: source,
    photo: photo,
    tags: tags,
    favorite: favorite ?? this.favorite,
  );

  Map<String, Object?> toData() => {
    'title': title,
    'servings': servings,
    'ingredients': [for (final i in ingredients) i.toJson()],
    'steps': steps,
    'minutes': minutes,
    'source': source,
    'photo': photo?.toJson(),
    'tags': tags,
    'favorite': favorite,
  };
}

enum MealSlot {
  breakfast('Frühstück'),
  lunch('Mittag'),
  dinner('Abendessen'),
  snack('Snack');

  const MealSlot(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('MealSlot.$name', _label);
}

/// A planned meal, stored in `Collections.mealPlan`.
class PlannedMeal {
  const PlannedMeal({
    required this.id,
    required this.date,
    required this.slot,
    this.recipeId,
    this.title = '',
    this.servings,
    this.note = '',
  });

  factory PlannedMeal.fromRecord(SyncRecord r) => PlannedMeal(
    id: r.id,
    date: _date(r.data['date']) ?? DateTime(2000),
    slot:
        MealSlot.values.where((s) => s.name == r.data['slot']).firstOrNull ??
        MealSlot.dinner,
    recipeId: r.data['recipeId'] as String?,
    title: r.data['title'] as String? ?? '',
    servings: (r.data['servings'] as num?)?.toInt(),
    note: r.data['note'] as String? ?? '',
  );

  final String id;
  final DateTime date;
  final MealSlot slot;

  /// A recipe, or just a [title] ("Pizza bestellen").
  final String? recipeId;
  final String title;
  final int? servings;
  final String note;

  Map<String, Object?> toData() => {
    'date': _day(date),
    'slot': slot.name,
    'recipeId': recipeId,
    'title': title,
    'servings': servings,
    'note': note,
  };
}

DateTime? _date(Object? v) {
  final d = v is String ? DateTime.tryParse(v) : null;
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
