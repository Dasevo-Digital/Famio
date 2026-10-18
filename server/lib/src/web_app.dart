import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import 'fallback_fonts.dart';

/// The Famio web app (Flutter's web build), served below `/app/` – in the
/// Home Assistant sidebar and in any browser.
class WebApp {
  WebApp(String dir) : dir = p.normalize(p.absolute(dir));

  /// Folder with `index.html`, `main.dart.js` …
  final String dir;

  /// The CJK fallback fonts not shipped with the build (set by the server).
  FallbackFonts? fallbackFonts;

  /// `FAMIO_WEB_DIR`, else `web/` next to the server's `bin/` folder (the
  /// release bundle); null if there is no web app.
  static WebApp? locate(String? configured) {
    final candidates = [
      ?configured,
      p.join(p.dirname(p.dirname(Platform.resolvedExecutable)), 'web'),
    ];
    for (final dir in candidates) {
      if (File(p.join(dir, 'index.html')).existsSync()) return WebApp(dir);
    }
    return null;
  }

  /// Content-Security-Policy of the web app. Flutter needs WebAssembly
  /// (CanvasKit) and inline styles. Fonts only from this server (see
  /// [FallbackFonts]). Besides this server the web app talks only to the
  /// weather (Open-Meteo), Open Food Facts, GitHub's release list (version
  /// check) and the map tiles: [tileUrl], the admins' tile server, or
  /// OpenStreetMap. Should a flaw ever let foreign script run, it could not
  /// send data anywhere else.
  static String policyFor({String? tileUrl}) =>
      "default-src 'self'; "
      "script-src 'self' 'wasm-unsafe-eval'; "
      "style-src 'self' 'unsafe-inline'; "
      "img-src 'self' data: blob: https:; "
      "font-src 'self' data:; "
      "connect-src 'self' https://api.open-meteo.com "
      'https://world.openfoodfacts.org https://api.github.com '
      '${_origin(tileUrl ?? 'https://tile.openstreetmap.org/{z}/{x}/{y}.png')}; '
      "worker-src 'self' blob:; "
      "object-src 'none'; base-uri 'self'; "
      "frame-ancestors 'self'";

  /// The origin of a tile address template; a placeholder in the host
  /// (`https://{s}.tile.example.org/…`) becomes a wildcard.
  static String _origin(String template) {
    final at = template.indexOf('://');
    if (at < 0) return '';
    final rest = template.substring(at + 3);
    final end = rest.indexOf('/');
    var host = end < 0 ? rest : rest.substring(0, end);
    if (host.contains('{')) {
      final dot = host.indexOf('}.');
      host = dot < 0 ? '' : '*.${host.substring(dot + 2)}';
    }
    if (host.isEmpty || !RegExp(r'^[A-Za-z0-9.*:-]+$').hasMatch(host)) {
      return '';
    }
    return '${template.substring(0, at)}://$host';
  }

  /// For the Home Assistant panel connected to another Famio server: it
  /// does not know that server's map tiles, so any HTTPS host is allowed.
  static const policy =
      "default-src 'self'; "
      "script-src 'self' 'wasm-unsafe-eval'; "
      "style-src 'self' 'unsafe-inline'; "
      "img-src 'self' data: blob: https:; "
      "font-src 'self' data:; "
      "connect-src 'self' https:; "
      "worker-src 'self' blob:; "
      "object-src 'none'; base-uri 'self'; "
      "frame-ancestors 'self'";

  static const _types = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.json': 'application/json',
    '.wasm': 'application/wasm',
    '.css': 'text/css; charset=utf-8',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.ttf': 'font/ttf',
    '.otf': 'font/otf',
    '.woff2': 'font/woff2',
    '.bin': 'application/octet-stream',
    '.frag': 'application/octet-stream',
  };

  /// [path] below `app/` ('' for the start page).
  ///
  /// Nothing is cached blindly: an add-on or server update replaces the
  /// files under the same names. The browser asks again each time and gets
  /// "304 unchanged" for files it has, compressed files where it can.
  Future<Response> serve(Request request, String path) async {
    final relative = path.isEmpty ? 'index.html' : path;
    final file = p.normalize(p.join(dir, relative));
    // Nothing outside the web app's folder.
    if (!p.isWithin(dir, file)) return Response.notFound('Not found');
    final type = _types[p.extension(file).toLowerCase()];
    final plain = File(file);
    if (type == null || !await plain.exists()) {
      if (type != null && relative.startsWith('fonts/')) {
        // Versioned names: the content of a path never changes.
        if (await fallbackFonts?.file(relative.substring(6)) case final f?) {
          return Response.ok(
            f.openRead(),
            headers: {
              'content-type': type,
              'cache-control': 'public, max-age=31536000, immutable',
              'content-length': '${await f.length()}',
            },
          );
        }
      }
      return Response.notFound('Not found');
    }
    final stat = await plain.stat();
    final etag =
        '"${stat.size.toRadixString(36)}-'
        '${stat.modified.millisecondsSinceEpoch.toRadixString(36)}"';
    final headers = {
      'content-type': type,
      'cache-control': 'no-cache',
      'etag': etag,
      'vary': 'accept-encoding',
    };
    final match = request.headers['if-none-match'];
    if (match != null && match.split(',').any((t) => t.trim() == etag)) {
      return Response.notModified(headers: headers);
    }
    // Precompressed copies: Brotli (from the Docker build) is about a fifth
    // smaller than gzip. Home Assistant's ingress compresses for the
    // browser itself (and would have to unpack ours first).
    final accepted = request.headers.containsKey('x-ingress-path')
        ? const <String>{}
        : {
            for (final part
                in (request.headers['accept-encoding'] ?? '').split(','))
              part.split(';').first.trim(),
          };
    var send = plain;
    String? encoding;
    for (final (name, suffix) in const [('br', '.br'), ('gzip', '.gz')]) {
      final packed = File('$file$suffix');
      if (accepted.contains(name) && await packed.exists()) {
        send = packed;
        encoding = name;
        break;
      }
    }
    return Response.ok(
      send.openRead(),
      headers: {
        ...headers,
        'content-encoding': ?encoding,
        'content-length': '${await send.length()}',
      },
    );
  }
}
