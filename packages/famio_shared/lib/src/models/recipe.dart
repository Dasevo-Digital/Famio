import '../sync_record.dart';
import 'chat.dart';

/// One line of a recipe: "200 g Mehl", "2 Eier", "Salz".
class Ingredient {
  const Ingredient({required this.name, this.amount, this.unit = ''});

  /// Parses a free text line like "1 1/2 EL Zucker", "200g Mehl" or
  /// "½ TL Salz".
  factory Ingredient.parse(String line) {
    var text = line.trim();
    const fractions = {'½': 0.5, '¼': 0.25, '¾': 0.75, '⅓': 1 / 3, '⅔': 2 / 3};
    double? amount;
    // "1 1/2", "1/2", "1,5", "2½", "½", also ranges like "2-3" (lower bound).
    final m = RegExp(
      r'^(?:(\d+)\s+(\d+)/(\d+)|(\d+)/(\d+)|(\d+(?:[.,]\d+)?)\s*([½¼¾⅓⅔])?|([½¼¾⅓⅔]))'
      r'(?:\s*[-–]\s*\d+(?:[.,]\d+)?)?',
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
    return Ingredient(name: text, amount: amount, unit: unit);
  }

  factory Ingredient.fromJson(Map<String, Object?> json) => Ingredient(
    name: json['name'] as String? ?? '',
    amount: (json['amount'] as num?)?.toDouble(),
    unit: json['unit'] as String? ?? '',
  );

  final String name;
  final double? amount;
  final String unit;

  /// The amount for [factor] times the servings, as text ("1,5 kg").
  String quantity([double factor = 1]) {
    if (amount == null) return unit;
    final v = amount! * factor;
    final rounded = v >= 10
        ? v.round().toString()
        : (v * 10).round() % 10 == 0
        ? v.round().toString()
        : v.toStringAsFixed(1).replaceAll('.', ',');
    return unit.isEmpty ? rounded : '$rounded $unit';
  }

  @override
  String toString() => [quantity(), name].where((s) => s.isNotEmpty).join(' ');

  Map<String, Object?> toJson() => {
    'name': name,
    'amount': ?amount,
    if (unit.isNotEmpty) 'unit': unit,
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

  Recipe copyWith({bool? favorite}) => Recipe(
    id: id,
    title: title,
    servings: servings,
    ingredients: ingredients,
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

  const MealSlot(this.label);

  final String label;
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
