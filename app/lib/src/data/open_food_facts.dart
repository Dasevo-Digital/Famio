import 'dart:convert';

import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n.dart';

/// Products and their nutrients from Open Food Facts, the free food
/// database (ODbL). Asked only after the member agreed on this device;
/// only the search words or the barcode leave the device.
class OpenFoodFacts {
  OpenFoodFacts({this.client, Uri? base})
    : _base = base ?? Uri.https('world.openfoodfacts.org');

  /// Tests pass their own; otherwise one per request.
  final http.Client? client;
  final Uri _base;

  static const _consentKey = 'nutrition.enabled';
  static const _fields =
      'code,product_name,product_name_de,product_name_en,product_name_es,'
      'brands,nutriments,serving_quantity,product_quantity';
  static const _headers = {'user-agent': 'Famio (Familien-Organizer)'};

  /// Whether the member agreed to ask Open Food Facts (per device).
  static Future<bool> allowed() async =>
      (await SharedPreferences.getInstance()).getBool(_consentKey) ?? false;

  static Future<void> allow(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_consentKey, value);

  /// Products matching [query] that have nutrients.
  Future<List<Nutrition>> search(String query) async {
    final json = await _get(
      _base.replace(
        path: '/cgi/search.pl',
        queryParameters: {
          'search_terms': query.trim(),
          'search_simple': '1',
          'action': 'process',
          'json': '1',
          'page_size': '15',
          'fields': _fields,
        },
      ),
    );
    return [
      for (final p in (json['products'] as List?) ?? const [])
        if (p is Map) ?nutritionOf(p.cast()),
    ];
  }

  /// The product with [code]; null if unknown or without nutrients.
  Future<Nutrition?> product(String code) async {
    if (!RegExp(r'^\d{6,14}$').hasMatch(code)) return null;
    final json = await _get(
      _base.replace(
        path: '/api/v2/product/$code.json',
        queryParameters: {'fields': _fields},
      ),
    );
    final p = json['product'];
    return json['status'] == 1 && p is Map ? nutritionOf(p.cast()) : null;
  }

  Future<Map<String, Object?>> _get(Uri url) async {
    final c = client ?? http.Client();
    try {
      final response = await c
          .get(url, headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw OpenFoodFactsException(response.statusCode);
      }
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      return json is Map ? json.cast() : const {};
    } on FormatException {
      throw const OpenFoodFactsException(0);
    } finally {
      if (client == null) c.close();
    }
  }

  /// The values per 100 g of an Open Food Facts product; null without a
  /// name or energy.
  static Nutrition? nutritionOf(Map<String, Object?> p) {
    String text(Object? v) => v is String ? v.trim() : '';
    double? number(Object? v) => switch (v) {
      num() => v.toDouble(),
      String() => double.tryParse(v.replaceAll(',', '.')),
      _ => null,
    };
    var name = text(p['product_name_$appLanguage']);
    if (name.isEmpty) name = text(p['product_name']);
    if (name.isEmpty) name = text(p['product_name_de']);
    final n = (p['nutriments'] as Map?)?.cast<String, Object?>() ?? const {};
    final kcal =
        number(n['energy-kcal_100g']) ??
        switch (number(n['energy_100g'])) {
          final kj? => kj / 4.184,
          null => null,
        };
    if (name.isEmpty || kcal == null) return null;
    final brand = text(p['brands']).split(',').first.trim();
    final serving = number(p['serving_quantity']);
    final package = number(p['product_quantity']);
    return Nutrition(
      code: text(p['code']),
      product: brand.isEmpty || name.contains(brand) ? name : '$name ($brand)',
      kcal: kcal,
      protein: number(n['proteins_100g']),
      fat: number(n['fat_100g']),
      carbs: number(n['carbohydrates_100g']),
      sugar: number(n['sugars_100g']),
      salt: number(n['salt_100g']),
      pieceGrams: serving != null && serving > 0 ? serving : null,
      packageGrams: package != null && package > 0 ? package : null,
    );
  }
}

/// Open Food Facts could not be asked (offline, busy, rate limit).
class OpenFoodFactsException implements Exception {
  const OpenFoodFactsException(this.status);

  final int status;
}
