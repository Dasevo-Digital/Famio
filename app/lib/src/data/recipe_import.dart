import 'dart:async';
import 'dart:convert';

import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;

/// The first web address in [text]: apps share "Lasagne https://…".
Uri? linkIn(String text) {
  final match = RegExp(
    r'''https?://[^\s<>"']+''',
    caseSensitive: false,
  ).firstMatch(text);
  if (match == null) return null;
  final link = match[0]!.replaceFirst(RegExp(r'[.,;:!?)\]]+$'), '');
  final url = Uri.tryParse(link);
  return url != null && url.host.isNotEmpty ? url : null;
}

/// Whether [url] looks like a recipe: a page of a known recipe site, or an
/// address that says so (`/rezept/`, `/recipes/`, `/receta/`, …). "Teilen
/// an Famio" then offers the recipe import first.
bool isRecipeLink(Uri url) {
  var host = url.host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  if (_recipeSites.any((site) => host == site || host.endsWith('.$site'))) {
    return true;
  }
  return RegExp(
    r'(^|[/\-_])(rezept|rezepte|recipe|recipes|receta|recetas|kochen)([/\-_.]|$)',
  ).hasMatch(url.path.toLowerCase());
}

const _recipeSites = {
  'chefkoch.de',
  'lecker.de',
  'kitchenstories.com',
  'gutekueche.at',
  'gutekueche.de',
  'essen-und-trinken.de',
  'eatsmarter.de',
  'springlane.de',
  'kuechengoetter.de',
  'einfachbacken.de',
  'kochbar.de',
  'cookidoo.de',
  'hellofresh.de',
  'bbcgoodfood.com',
  'allrecipes.com',
  'seriouseats.com',
  'simplyrecipes.com',
  'bonappetit.com',
  'epicurious.com',
  'recetasgratis.net',
  'directoalpaladar.com',
};

/// A recipe from a web page and the address of its photo.
typedef ImportedRecipe = ({Recipe recipe, Uri? image});

/// Reads a recipe from a web page: nearly all recipe sites (Chefkoch,
/// Lecker, blogs …) describe it as schema.org `Recipe` in JSON-LD.
ImportedRecipe? recipeFromHtml(
  String html, {
  required String id,
  String source = '',
}) {
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
    if (recipe != null) {
      return (
        recipe: _toRecipe(recipe, id: id, source: source),
        image:
            _imageUrl(recipe['image'], source, _nodes(json)) ??
            _imageUrl(recipe['thumbnailUrl'], source, const {}) ??
            _pageImage(html, source),
      );
    }
  }
  return null;
}

/// Why no recipe came from a page (#570). The order says which reason
/// tells the most: a page that turned the request down explains more than
/// one without a recipe, and that more than one that was out of reach.
enum RecipeImportProblem { refused, noRecipe, unreachable }

/// A recipe page that could not be read; see [RecipeImportProblem].
class RecipeImportError implements Exception {
  const RecipeImportError(
    this.problem, {
    this.status,
    this.message,
    this.timedOut = false,
    this.sameAgain = false,
  });

  final RecipeImportProblem problem;

  /// The page's HTTP status, when the device fetched it itself.
  final int? status;

  /// The server's own words, when it fetched the page.
  final String? message;

  /// No answer in time: a second try would only wait as long again.
  final bool timedOut;

  /// The device would get the same answer again (a page larger than
  /// [maxRecipePage], something else than a web page): no second try there,
  /// the server still gets its turn.
  final bool sameAgain;

  /// The page is not there (any more); nobody gets another answer.
  bool get gone => status == 404 || status == 410;

  @override
  String toString() => 'RecipeImportError($problem, $status, $message)';
}

const _userAgent = 'Mozilla/5.0 (Famio Rezept-Import)';

/// The most of a recipe page the device reads (as the server's
/// `/api/web/page`, #575): recipe pages are far smaller, and a phone must
/// not hold an endless "page" in its memory.
const maxRecipePage = 3 * 1024 * 1024;

/// Downloads [url] and reads its recipe, or throws a [RecipeImportError].
///
/// With [direct] the device fetches the page itself, and once more after
/// [retryAfter] when that failed: sites sometimes turn a single request
/// down. Then the server [api] tries (the web app may only ask the server:
/// browsers may not read other sites, and its content policy only lets it
/// talk to a few hosts), so another way to the site gets its chance.
Future<ImportedRecipe> importRecipe(
  Uri url, {
  required String id,
  http.Client? client,
  FamioApiClient? api,
  bool direct = true,
  Duration retryAfter = const Duration(seconds: 1),
}) async {
  RecipeImportError? reason;
  void keep(RecipeImportError e) {
    if (reason == null || e.problem.index < reason!.problem.index) reason = e;
  }

  if (direct) {
    final c = client ?? http.Client();
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) await Future<void>.delayed(retryAfter);
        try {
          return await _fetchDirect(c, url, id: id);
        } on RecipeImportError catch (e) {
          keep(e);
          if (e.gone) rethrow;
          if (e.timedOut || e.sameAgain) break;
        }
      }
    } finally {
      if (client == null) c.close();
    }
  }
  if (api != null) {
    // Without the device's own try the server gets the second one.
    for (var attempt = 0; attempt < (direct ? 1 : 2); attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryAfter);
      try {
        final page = await api.fetchWebPage(url);
        final recipe = recipeFromHtml(
          page.html,
          id: id,
          source: page.url.toString(),
        );
        if (recipe != null) return recipe;
        keep(const RecipeImportError(RecipeImportProblem.noRecipe));
        break;
      } on ApiError catch (e) {
        final problem = _serverProblem(e);
        keep(problem);
        // Only the page's answer may be different next time.
        if (e.code != 'page_unavailable' || problem.timedOut) break;
      }
    }
  }
  throw reason ?? const RecipeImportError(RecipeImportProblem.unreachable);
}

/// Reads the page at [url] on the device: 20 seconds for all of it, at
/// most [maxRecipePage], only a web page (or one that does not say what it
/// is). What is not read is not downloaded either.
Future<ImportedRecipe> _fetchDirect(
  http.Client client,
  Uri url, {
  required String id,
}) async {
  final String html;
  try {
    html = await httpTransfer(
      client: client,
      method: 'GET',
      url: url,
      headers: {'user-agent': _userAgent},
      timeout: const Duration(seconds: 20),
      consume: (response, body) async {
        // Gives the page up unread: its connection is closed, and the
        // answer comes at once (without waiting for the closing).
        Never giveUp(Object reason) {
          unawaited(body.listen(null).cancel());
          throw reason;
        }

        if (response.statusCode != 200) {
          giveUp(
            RecipeImportError(
              RecipeImportProblem.refused,
              status: response.statusCode,
            ),
          );
        }
        final type = response.headers['content-type'] ?? '';
        if (type.isNotEmpty && !type.toLowerCase().contains('html')) {
          giveUp(
            const RecipeImportError(
              RecipeImportProblem.noRecipe,
              sameAgain: true,
            ),
          );
        }
        if ((response.contentLength ?? 0) > maxRecipePage) {
          giveUp(TransferTooLarge());
        }
        return utf8.decode(
          await readTransferBytes(body, maxBytes: maxRecipePage),
          allowMalformed: true,
        );
      },
    );
  } on RecipeImportError {
    rethrow;
  } on TimeoutException {
    throw const RecipeImportError(
      RecipeImportProblem.unreachable,
      timedOut: true,
    );
  } on TransferTooLarge {
    throw const RecipeImportError(
      RecipeImportProblem.noRecipe,
      sameAgain: true,
    );
  } on Exception {
    // No connection, no name, a broken TLS handshake …
    throw const RecipeImportError(RecipeImportProblem.unreachable);
  }
  final recipe = recipeFromHtml(html, id: id, source: url.toString());
  if (recipe == null) {
    throw const RecipeImportError(RecipeImportProblem.noRecipe);
  }
  return recipe;
}

/// What the server's answer for a page means (see its `/api/web/page`).
RecipeImportError _serverProblem(ApiError e) => switch (e.code) {
  // The page answered with something else than the page.
  'page_unavailable' when e.status == 502 => RecipeImportError(
    RecipeImportProblem.refused,
    message: e.message,
  ),
  'page_unavailable' => RecipeImportError(
    RecipeImportProblem.unreachable,
    message: e.message,
    timedOut: true,
  ),
  'not_html' || 'too_large' => RecipeImportError(
    RecipeImportProblem.noRecipe,
    message: e.message,
  ),
  // Offline, a guest, an address the server may not fetch …
  _ => RecipeImportError(RecipeImportProblem.unreachable, message: e.message),
};

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

/// The nodes of a JSON-LD document by their `@id`: in a `@graph`, `image` is
/// often only a reference to one (Chefkoch, sites with Yoast).
Map<Object?, Map<dynamic, dynamic>> _nodes(Object? json) {
  final nodes = <Object?, Map<dynamic, dynamic>>{};
  void collect(Object? value) {
    if (value is List) {
      value.forEach(collect);
    } else if (value is Map) {
      if (value.containsKey('@id') && value.length > 1) {
        nodes[value['@id']] = value;
      }
      value.values.forEach(collect);
    }
  }

  collect(json);
  return nodes;
}

/// schema.org `image`: an address, an `ImageObject`, a reference to one in
/// [nodes], or a list of them. A followed reference leaves [nodes], so that
/// references in circles end.
Uri? _imageUrl(Object? image, String source, Map<Object?, Map> nodes) {
  if (image is List) {
    return image.map((i) => _imageUrl(i, source, nodes)).nonNulls.firstOrNull;
  }
  if (image is Map) {
    final address =
        image['url'] ?? image['contentUrl'] ?? nodes.remove(image['@id']);
    return _imageUrl(address, source, nodes);
  }
  if (image is! String || image.trim().isEmpty) return null;
  final url = Uri.tryParse(_unescape(image.trim()));
  if (url == null) return null;
  return url.hasScheme ? url : Uri.tryParse(source)?.resolveUri(url);
}

/// The picture a page names for sharing (`og:image`).
Uri? _pageImage(String html, String source) {
  final image = RegExp(
    r"""property=["']og:image(:secure_url)?["']""",
    caseSensitive: false,
  );
  final content = RegExp(r"""content=["']([^"']+)["']""", caseSensitive: false);
  final tags = RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(html);
  for (final tag in tags) {
    if (!image.hasMatch(tag[0]!)) continue;
    final url = _imageUrl(content.firstMatch(tag[0]!)?[1], source, const {});
    if (url != null) return url;
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
