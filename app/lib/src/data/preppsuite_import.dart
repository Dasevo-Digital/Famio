import 'dart:convert';

/// A shopping list exported by PreppSuite (Vorräte → Einkaufsliste →
/// Datei): the articles below their minimum. Format: PreppSuite's
/// `docs/einkaufsliste-format.md`, version 1.
class PreppSuiteList {
  const PreppSuiteList({required this.items, this.created, this.target});

  final List<PreppSuiteItem> items;

  /// When it was exported.
  final DateTime? created;
  final PreppSuiteTarget? target;
}

class PreppSuiteItem {
  const PreppSuiteItem({
    required this.name,
    this.quantity = '',
    this.supplyCategory = '',
  });

  final String name;

  /// The missing amount with its unit, written in the language of the
  /// exporting app ("1,5 kg"): fits Famio's free quantity field.
  final String quantity;

  /// PreppSuite's supply category (water, food …), not an aisle.
  final String supplyCategory;
}

/// The household's goal, beside the articles on purpose: a water article
/// below its minimum already counts towards it, so it is no line of its
/// own (the water would be bought twice).
class PreppSuiteTarget {
  const PreppSuiteTarget({
    required this.days,
    required this.met,
    this.waterLiters = 0,
    this.kcal = 0,
  });

  final int days;
  final bool met;
  final num waterLiters;
  final num kcal;
}

enum PreppSuiteProblem {
  /// Some other file.
  notAList,

  /// A later version of the format, which Famio might misread.
  newerVersion,
}

class PreppSuiteFormatException implements Exception {
  const PreppSuiteFormatException(this.problem);

  final PreppSuiteProblem problem;

  @override
  String toString() => 'PreppSuiteFormatException(${problem.name})';
}

/// Reads an exported list; throws [PreppSuiteFormatException] for anything
/// else. Fields Famio does not know are skipped, as the format asks.
PreppSuiteList parsePreppSuiteList(String text) {
  const notAList = PreppSuiteFormatException(PreppSuiteProblem.notAList);
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw notAList;
  }
  if (json is! Map || json['format'] != 'preppsuite-einkaufsliste') {
    throw notAList;
  }
  final version = json['version'];
  if (version is! int || version < 1) throw notAList;
  if (version > 1) {
    throw const PreppSuiteFormatException(PreppSuiteProblem.newerVersion);
  }
  String text0(Object? v) => v is String ? v.trim() : '';
  final items = [
    for (final i in json['items'] is List ? json['items'] as List : const [])
      if (i is Map && text0(i['name']).isNotEmpty)
        PreppSuiteItem(
          name: text0(i['name']),
          quantity: text0(i['quantity']),
          supplyCategory: text0(i['supplyCategory']),
        ),
  ];
  final target = json['target'];
  final created = json['created'];
  return PreppSuiteList(
    items: items,
    created: created is String ? DateTime.tryParse(created) : null,
    target: target is Map && target['days'] is num
        ? PreppSuiteTarget(
            days: (target['days'] as num).toInt(),
            met: target['met'] == true,
            waterLiters: target['waterLiters'] is num
                ? target['waterLiters'] as num
                : 0,
            kcal: target['kcal'] is num ? target['kcal'] as num : 0,
          )
        : null,
  );
}
