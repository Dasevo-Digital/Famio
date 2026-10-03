part of '../api.dart';

/// Start page, web app, Home Assistant panel and the WebSocket.
extension _WebRoutes on FamioApi {
  Response _health(Request request) => _json({
    'name': 'famio',
    'version': serverVersion,
    'setupRequired': !accounts.hasUsers,
    // The first client in a shared LAN must not be able to claim the server.
    'setupCodeRequired': !accounts.hasUsers && setupCode != null,
    // Offered on the login screen: "Mit … anmelden".
    if (sso case final sso? when sso.enabled) 'sso': sso.config!.buttonLabel,
  });

  Response _wsTicket(Request request) {
    _auth(request);
    // Home Assistant's sidebar signs the WebSocket in itself.
    final token = _bearer(request);
    if (token == null) {
      throw ApiException.badRequest('no_token', 'Keine Sitzung zum Anmelden');
    }
    final now = DateTime.now();
    _wsTickets.removeWhere((_, t) => t.expires.isBefore(now));
    final ticket = _randomToken();
    _wsTickets[ticket] = (
      token: token,
      expires: now.add(const Duration(seconds: 30)),
    );
    return _json({'ticket': ticket});
  }

  FutureOr<Response> _ws(Request request) {
    final ticket = request.url.queryParameters['ticket'];
    if (ticket != null) {
      final entry = _wsTickets.remove(ticket);
      if (entry == null || entry.expires.isBefore(DateTime.now())) {
        throw ApiException(401, 'unauthorized', 'Nicht angemeldet');
      }
      _auth(request, token: entry.token);
    } else {
      _auth(request);
    }
    return webSocketHandler((channel, _) {
      hub.add(channel, rev: records.currentRev);
    }, pingInterval: const Duration(seconds: 30))(request);
  }

  /// Through Home Assistant's sidebar (ingress).
  bool _viaIngress(Request request) {
    final peer =
        (request.context['shelf.io.connection_info'] as HttpConnectionInfo?)
            ?.remoteAddress;
    return ingressAuth && peer?.address == _ingressProxy;
  }

  Future<Response> _webApp(Request request, String path) async {
    final app = webApp;
    if (app == null) return Response.notFound('Not found');
    return app.serve(request, path);
  }

  /// How the web app runs here: in Home Assistant's sidebar the Home
  /// Assistant user is signed in, elsewhere the family signs in as usual.
  Response _panel(Request request) =>
      _json({'mode': _viaIngress(request) ? 'server' : 'browser'});

  Response _landing(Request request) {
    final member = _ingressMember(request);
    final ingress = _viaIngress(request);
    // The sidebar opens the web app; `?info` shows how to connect apps.
    if (ingress &&
        webApp != null &&
        !request.url.queryParameters.containsKey('info')) {
      return Response.found('app/');
    }
    return Response.ok(
      landingPage(
        member: member,
        hasPassword: member != null && accounts.hasPassword(member.id),
        address: _appAddress(request, ingress: ingress),
        version: serverVersion,
        addon: ingress,
        webApp: webApp != null,
      ),
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }

  Response _securityTxt(Request request) {
    final now = DateTime.now().toUtc();
    final expires = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 180));
    return Response.ok(
      'Contact: ${FamioApi.securityContact}\n'
      'Expires: ${expires.toIso8601String().replaceFirst('.000', '')}\n'
      'Preferred-Languages: de, en\n',
      headers: {'content-type': 'text/plain; charset=utf-8'},
    );
  }

  Response _deleteAccountPage(Request request) => Response.ok(
    accountDeletionPage(webApp: webApp != null),
    headers: {'content-type': 'text/html; charset=utf-8'},
  );

  /// The address to enter in the apps, as seen from [request]: the public
  /// address if set, the proxy's https address, otherwise Famio's own HTTPS
  /// port (plain HTTP only without one). Only shown, so the forwarded
  /// headers need no trust here.
  String _appAddress(Request request, {required bool ingress}) {
    final public = publicUrl;
    if (public != null) return public.replaceFirst(RegExp(r'/+$'), '');
    final uri = request.requestedUri;
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    String withPort(String scheme, int port) =>
        '$scheme://$host${port == (scheme == 'https' ? 443 : 80) ? '' : ':$port'}';
    if (uri.scheme == 'https') return withPort('https', uri.port);
    final proto = request.headers['x-forwarded-proto']
        ?.split(',')
        .first
        .trim()
        .toLowerCase();
    // In the Home Assistant sidebar the proxy is HA's, not Famio's.
    if (!ingress && proto == 'https') {
      final port = int.tryParse(request.headers['x-forwarded-port'] ?? '');
      return withPort('https', port ?? 443);
    }
    if (tlsPort case final port?) return withPort('https', port);
    return withPort('http', uri.port);
  }
}
