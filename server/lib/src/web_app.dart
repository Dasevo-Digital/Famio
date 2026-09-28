import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

/// The Famio web app (Flutter's web build), served below `/app/` – in the
/// Home Assistant sidebar and in any browser.
class WebApp {
  WebApp(String dir) : dir = p.normalize(p.absolute(dir));

  /// Folder with `index.html`, `main.dart.js` …
  final String dir;

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
  /// (CanvasKit) and inline styles; map tiles and the weather come from
  /// other HTTPS servers, emoji from Google's font service.
  static const policy =
      "default-src 'self'; "
      "script-src 'self' 'wasm-unsafe-eval'; "
      "style-src 'self' 'unsafe-inline'; "
      "img-src 'self' data: blob: https:; "
      "font-src 'self' data: https://fonts.gstatic.com; "
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
  Future<Response> serve(String path) async {
    final relative = path.isEmpty ? 'index.html' : path;
    final file = p.normalize(p.join(dir, relative));
    // Nothing outside the web app's folder.
    if (!p.isWithin(dir, file)) return Response.notFound('Not found');
    final type = _types[p.extension(file).toLowerCase()];
    final handle = File(file);
    if (type == null || !await handle.exists()) {
      return Response.notFound('Not found');
    }
    // The start files change with every version; the rest is loaded by
    // them and can stay in the cache for a while.
    final fresh =
        relative == 'index.html' ||
        relative.startsWith('flutter') ||
        relative == 'main.dart.js' ||
        relative == 'version.json' ||
        relative == 'manifest.json';
    return Response.ok(
      handle.openRead(),
      headers: {
        'content-type': type,
        'content-length': '${await handle.length()}',
        'cache-control': fresh ? 'no-cache' : 'public, max-age=86400',
      },
    );
  }
}
