import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import 'web_app.dart';

/// The Home Assistant add-on in client mode: shows the web app in the
/// sidebar and forwards it to the family's Famio server elsewhere (e.g. a
/// Proxmox container or a public address).
///
/// Every Home Assistant user signs in once with their own Famio account
/// (password, second factor). The session token stays in the add-on, per
/// Home Assistant user – the browser never sees it. Only requests through
/// Home Assistant's ingress proxy are served.
class PanelProxy {
  PanelProxy({
    required Uri upstream,
    String? pin,
    required String dataDir,
    this.webApp,
    this.ingressProxy = '172.30.32.2',
  }) : upstream = upstream.path.endsWith('/')
           ? upstream
           : upstream.replace(path: '${upstream.path}/'),
       _sessionsFile = File(p.join(dataDir, 'panel_sessions.json')),
       _client = _httpClient(pin) {
    if (_sessionsFile.existsSync()) {
      try {
        _sessions.addAll(
          (jsonDecode(_sessionsFile.readAsStringSync()) as Map).cast(),
        );
      } on FormatException {
        // Unreadable: everybody signs in again.
      }
    }
  }

  /// The family's Famio server.
  final Uri upstream;
  final WebApp? webApp;

  /// Address Home Assistant's ingress proxy connects from.
  final String ingressProxy;

  final File _sessionsFile;
  final HttpClient _client;

  /// Home Assistant user id → Famio session token.
  final _sessions = <String, String>{};

  static HttpClient _httpClient(String? pin) => HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    // The family's server in the home network with its own certificate:
    // only the key confirmed in the add-on's settings.
    ..badCertificateCallback = (cert, host, port) =>
        pin != null && pin.isNotEmpty && _fingerprint(cert) == pin;

  static String _fingerprint(X509Certificate cert) {
    try {
      return formatFingerprint(
        sha256.convert(subjectPublicKeyInfo(cert.der)).bytes,
      );
    } on FormatException {
      return '';
    }
  }

  Handler get handler => _handle;

  Future<Response> _handle(Request request) async {
    final path = request.url.path;
    if (path.isEmpty || path == 'app') return Response.found('app/');
    if (path.startsWith('app/')) {
      final app = webApp;
      return app == null
          ? Response.notFound('Not found')
          : _secured(await app.serve(path.substring(4)));
    }
    // Health checks (Docker, Home Assistant's watchdog): is the family's
    // server reachable?
    if (path == 'api/health') return _forward(request, null);
    final user = _homeAssistantUser(request);
    if (user == null) {
      return _error(
        403,
        'ingress_only',
        'Nur über die Seitenleiste von Home Assistant.',
      );
    }
    if (path == 'api/panel') return _json({'mode': 'client'});
    if (path == 'api/ws') return _webSocket(request, user);
    if (path.startsWith('api/')) return _forward(request, user);
    return Response.notFound('Not found');
  }

  /// The Home Assistant user of an ingress request, else null.
  _User? _homeAssistantUser(Request request) {
    final info =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    if (info?.remoteAddress.address != ingressProxy) return null;
    final id = request.headers['x-remote-user-id'];
    if (id == null || id.isEmpty) return null;
    return _User(
      id,
      request.headers['x-remote-user-display-name'] ??
          request.headers['x-remote-user-name'] ??
          '',
    );
  }

  Future<Response> _forward(Request request, _User? user) async {
    final path = request.url.path;
    final token = user == null ? null : _sessions[user.id];
    final HttpClientResponse response;
    try {
      final outgoing = await _client.openUrl(
        request.method,
        upstream.resolve(request.url.toString()),
      );
      outgoing.followRedirects = false;
      for (final name in const [
        'content-type',
        'accept',
        'accept-language',
        'if-none-match',
      ]) {
        final value = request.headers[name];
        if (value != null) outgoing.headers.set(name, value);
      }
      if (token != null) {
        outgoing.headers.set('authorization', 'Bearer $token');
      }
      if (user != null && _signsIn(path)) {
        // Named after the Home Assistant user in the member's devices.
        final body = await request.readAsString();
        final json = body.isEmpty
            ? <String, Object?>{}
            : (jsonDecode(body) as Map).cast<String, Object?>();
        if (json.containsKey('device') || path == 'api/auth/login') {
          json['device'] = user.name.isEmpty
              ? 'Home Assistant'
              : 'Home Assistant (${user.name})';
        }
        outgoing.add(utf8.encode(jsonEncode(json)));
      } else {
        await outgoing.addStream(request.read());
      }
      response = await outgoing.close();
    } on SocketException catch (e) {
      return _unreachable(e);
    } on HandshakeException catch (e) {
      return _unreachable(e);
    } on HttpException catch (e) {
      return _unreachable(e);
    }

    if (user != null && path == 'api/auth/logout') {
      _setSession(user.id, null);
    }
    final headers = <String, String>{};
    for (final name in const [
      'content-type',
      'content-disposition',
      'cache-control',
      'etag',
      'content-security-policy',
      'x-content-type-options',
    ]) {
      final value = response.headers.value(name);
      if (value != null) headers[name] = value;
    }

    if (user != null &&
        path.startsWith('api/auth/') &&
        response.statusCode == 200 &&
        (headers['content-type'] ?? '').contains('json')) {
      // A new session: keep its token here, the browser gets a
      // placeholder.
      final body = await utf8.decodeStream(response);
      final json = jsonDecode(body);
      if (json is Map && json['token'] is String && json['member'] is Map) {
        _setSession(user.id, json['token'] as String);
        json['token'] = 'panel';
      }
      return Response(200, body: jsonEncode(json), headers: headers);
    }
    if (user != null &&
        token != null &&
        response.statusCode == 401 &&
        !path.startsWith('api/auth/')) {
      // Signed out elsewhere (e.g. in the device list): sign in again.
      _setSession(user.id, null);
    }
    return _secured(
      Response(response.statusCode, body: response, headers: headers),
    );
  }

  static bool _signsIn(String path) =>
      path == 'api/auth/login' ||
      path == 'api/auth/setup' ||
      path.startsWith('api/auth/sso');

  /// Change notifications: the browser's WebSocket is joined to one with
  /// the session token to the family's server.
  Future<Response> _webSocket(Request request, _User user) async {
    final token = _sessions[user.id];
    if (token == null) {
      return _error(401, 'unauthorized', 'Nicht angemeldet');
    }
    final url = upstream
        .resolve('api/ws')
        .replace(scheme: upstream.scheme == 'https' ? 'wss' : 'ws');
    return webSocketHandler((browser, _) async {
      final WebSocket server;
      try {
        server = await WebSocket.connect(
          url.toString(),
          headers: {'authorization': 'Bearer $token'},
          customClient: _client,
        );
      } catch (_) {
        await browser.sink.close();
        return;
      }
      server.pingInterval = const Duration(seconds: 30);
      server.listen(
        browser.sink.add,
        onDone: () => browser.sink.close(),
        onError: (Object _) => browser.sink.close(),
      );
      browser.stream.listen(
        server.add,
        onDone: () => server.close(),
        onError: (Object _) => server.close(),
      );
    }, pingInterval: const Duration(seconds: 30))(request);
  }

  void _setSession(String user, String? token) {
    if (_sessions[user] == token) return;
    token == null ? _sessions.remove(user) : _sessions[user] = token;
    _sessionsFile.parent.createSync(recursive: true);
    _sessionsFile.writeAsStringSync(jsonEncode(_sessions));
  }

  Response _unreachable(Object error) => _error(
    502,
    'upstream_unreachable',
    'Der Famio-Server ($upstream) ist nicht erreichbar.',
  );

  static Response _secured(Response response) => response.change(
    headers: {
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      if (response.mimeType == 'text/html')
        'content-security-policy': WebApp.policy,
    },
  );

  static Response _json(Object body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  );

  static Response _error(int status, String code, String message) =>
      _json({'error': code, 'message': message}, status: status);

  void close() => _client.close(force: true);
}

class _User {
  const _User(this.id, this.name);

  final String id;
  final String name;
}
