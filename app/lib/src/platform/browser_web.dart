import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:web/web.dart' as web;

/// Hands a file to the browser as a download.
void downloadBytes(List<int> bytes, String name, String mime) {
  final blob = web.Blob(
    [Uint8List.fromList(bytes).toJS].toJS,
    web.BlobPropertyBag(type: mime),
  );
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body?.append(link);
  link.click();
  link.remove();
  // Give the browser a moment to start the download.
  Future<void>.delayed(
    const Duration(seconds: 30),
    () => web.URL.revokeObjectURL(url),
  );
}

/// The address the web app was loaded from.
Uri? get pageUrl => Uri.parse(web.window.location.href);

/// Per-tab storage (survives a reload, gone when the tab closes).
String? tabValue(String key) {
  try {
    return web.window.sessionStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void setTabValue(String key, String? value) {
  try {
    value == null
        ? web.window.sessionStorage.removeItem(key)
        : web.window.sessionStorage.setItem(key, value);
  } catch (_) {
    // Storage blocked: sign in again after a reload.
  }
}

/// For map tiles: OpenStreetMap refuses browser requests without a
/// Referer (its tile usage policy) and answers with an "Access blocked"
/// image, but the web app sends none ("no-referrer"). Tile requests send
/// only the origin of the Famio server, never a path.
http.Client? get mapTileClient => _mapTileClient;
final _mapTileClient = RetryClient(_OriginReferrerClient());

class _OriginReferrerClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abort = web.AbortController();
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.whenComplete(() => abort.abort()));
    }
    final headers = web.Headers();
    request.headers.forEach((name, value) => headers.append(name, value));
    final body = await request.finalize().toBytes();
    try {
      final response = await web.window
          .fetch(
            request.url.toString().toJS,
            web.RequestInit(
              method: request.method,
              headers: headers,
              body: body.isEmpty ? null : body.toJS,
              referrerPolicy: 'strict-origin',
              credentials: 'omit',
              signal: abort.signal,
            ),
          )
          .toDart;
      final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
      return http.StreamedResponse(
        Stream.value(bytes),
        response.status,
        contentLength: bytes.length,
        request: request,
        reasonPhrase: response.statusText,
        headers: {'content-type': ?response.headers.get('content-type')},
      );
    } catch (e) {
      if (abort.signal.aborted) throw http.RequestAbortedException(request.url);
      throw http.ClientException('$e', request.url);
    }
  }
}
