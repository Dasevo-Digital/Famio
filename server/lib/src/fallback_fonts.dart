import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Fallback fonts of the web app (emoji, symbols, other scripts). Flutter
/// would load them from Google's font service, which would tell Google the
/// address of every browser that opens Famio. The web build ships most of
/// them under `fonts/` (see app/tool/build_web.sh); the large Chinese,
/// Japanese and Korean sets come through here instead: the server fetches
/// such a file once from Google and keeps it, browsers only ever ask the
/// Famio server.
class FallbackFonts {
  FallbackFonts({
    required this.cacheDir,
    required this.allowed,
    http.Client? client,
    Uri? source,
  }) : _http = client ?? http.Client(),
       source = source ?? Uri.parse('https://fonts.gstatic.com/s/');

  /// For the web build in [webDir]: the paths in `fonts/remote.txt`, the
  /// only ones fetched. Null without that list (an older build).
  static FallbackFonts? forWebApp(
    String webDir, {
    required String cacheDir,
    http.Client? client,
  }) {
    final list = File(p.join(webDir, 'fonts', 'remote.txt'));
    if (!list.existsSync()) return null;
    return FallbackFonts(
      cacheDir: cacheDir,
      allowed: {
        for (final line in list.readAsLinesSync())
          if (line.trim().isNotEmpty) line.trim(),
      },
      client: client,
    );
  }

  final String cacheDir;

  /// Paths below `fonts/` exactly as the web app asks for them, e.g.
  /// `notosanssc/v36/<name>.0.woff2`; nothing else is fetched.
  final Set<String> allowed;
  final Uri source;
  final http.Client _http;
  final _pending = <String, Future<File?>>{};

  /// A slice of a CJK font is at most a few hundred KB.
  static const _maxBytes = 8 * 1024 * 1024;

  /// The cached file for [path], fetched first if needed; null if it is
  /// not on the list or Google cannot be reached.
  Future<File?> file(String path) async {
    if (!allowed.contains(path)) return null;
    final target = File(p.join(cacheDir, path));
    if (!p.isWithin(cacheDir, target.path)) return null;
    if (target.existsSync()) return target;
    // A block, not `=> remove(...)`: whenComplete would wait for the
    // removed future, which is this one.
    return _pending[path] ??= _fetch(path, target).whenComplete(() {
      _pending.remove(path);
    });
  }

  Future<File?> _fetch(String path, File target) async {
    try {
      final response = await _http
          .get(source.resolve(path))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 ||
          response.bodyBytes.isEmpty ||
          response.bodyBytes.length > _maxBytes) {
        return null;
      }
      target.parent.createSync(recursive: true);
      // Under its own name only when complete.
      final part = File('${target.path}.part')
        ..writeAsBytesSync(response.bodyBytes, flush: true);
      part.renameSync(target.path);
      return target;
    } catch (_) {
      return null;
    }
  }
}
