import 'dart:convert';

import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;

/// Reads a recipe from a web page: nearly all recipe sites (Chefkoch,
/// Lecker, blogs …) describe it as schema.org `Recipe` in JSON-LD.
Recipe? recipeFromHtml(String html, {required String id, String source = ''}) {
  final scripts = RegExp(
    r'''<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>''',
    dotAll: true,
    caseSensitive: false,
  ).allMatches(html);
  for (final m in scripts) {
    Object? json;
    try {
      json = jsonDecode(m.group(1)!.trim());
    } catch (_) {
      continue;
    }
    final recipe = _findRecipe(json);
    if (recipe != null) return _toRecipe(recipe, id: id, source: source);
  }
  return null;
}

/// Downloads [url] and reads its recipe.
Future<Recipe?> importRecipe(
  Uri url, {
  required String id,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final response = await c
        .get(url, headers: {'user-agent': 'Mozilla/5.0 (Famio Rezept-Import)'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    return recipeFromHtml(
      utf8.decode(response.bodyBytes, allowMalformed: true),
      id: id,
      source: url.toString(),
    );
  } finally {
    if (client == null) c.close();
  }
}

Map<String, Object?>? _findRecipe(Object? json) {
  if (json is List) {
    for (final e in json) {
      final r = _findRecipe(e);
      if (r != null) return r;
    }
  } else if (json is Map) {
    final type = json['@type'];
    if (type == 'Recipe' || (type is List && type.contains('Recipe'))) {
      return json.cast();
    }
    return _findRecipe(json['@graph']) ?? _findRecipe(json['mainEntity']);
  }
  return null;
}

Recipe _toRecipe(
  Map<String, Object?> r, {
  required String id,
  String source = '',
}) {
  String text(Object? v) => v is String
      ? _strip(v)
      : v is List && v.isNotEmpty
      ? text(v.first)
      : '';
  final servings =
      int.tryParse(
        RegExp(r'\d+').firstMatch(text(r['recipeYield']))?.group(0) ?? '',
      ) ??
      4;
  final steps = <String>[];
  void collect(Object? v) {
    if (v is String) {
      steps.addAll(
        _strip(v).split(RegExp(r'\n+')).where((l) => l.trim().isNotEmpty),
      );
    } else if (v is List) {
      v.forEach(collect);
    } else if (v is Map) {
      if (v['itemListElement'] != null) {
        collect(v['itemListElement']);
      } else {
        collect(v['text'] ?? v['name']);
      }
    }
  }

  collect(r['recipeInstructions']);
  return Recipe(
    id: id,
    title: text(r['name']),
    servings: servings.clamp(1, 50),
    ingredients: [
      for (final i in r['recipeIngredient'] as List? ?? const [])
        if (i is String && _strip(i).isNotEmpty) Ingredient.parse(_strip(i)),
    ],
    steps: steps.map((s) => s.trim()).join('\n'),
    minutes: _minutes(text(r['totalTime'])) ?? _minutes(text(r['cookTime'])),
    source: source,
  );
}

/// ISO 8601 durations like "PT1H30M".
int? _minutes(String iso) {
  final m = RegExp(r'P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?').firstMatch(iso);
  if (m == null || m.group(0) == 'P') return null;
  int g(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
  final total = g(1) * 1440 + g(2) * 60 + g(3);
  return total == 0 ? null : total;
}

String _strip(String s) => _unescape(
  s
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAllMapped(RegExp(r' ([.,;:!?])'), (m) => m[1]!),
).trim();

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ');
