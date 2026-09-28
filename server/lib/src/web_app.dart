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
    final packed = File('$file.gz');
    // Home Assistant's ingress compresses for the browser itself (and would
    // have to unpack ours first).
    final gzip =
        (request.headers['accept-encoding'] ?? '').contains('gzip') &&
        !request.headers.containsKey('x-ingress-path');
    final send = gzip && await packed.exists() ? packed : plain;
    return Response.ok(
      send.openRead(),
      headers: {
        ...headers,
        if (send == packed) 'content-encoding': 'gzip',
        'content-length': '${await send.length()}',
      },
    );
  }
}
