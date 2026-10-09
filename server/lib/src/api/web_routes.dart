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

  /// Prometheus metrics without family data. Only with FAMIO_METRICS_TOKEN
  /// (as bearer token); otherwise the endpoint does not exist.
  Response _metrics(Request request) {
    final expected = metricsToken;
    final m = metrics;
    if (expected == null || m == null) return Response.notFound('');
    final given = _bearer(request) ?? '';
    if (!_constantTimeEquals(given, expected)) {
      return Response(401, headers: {'www-authenticate': 'Bearer'});
    }
    final w = MetricsWriter();
    final now = DateTime.now();
    w
      ..add('famio_info', 'Version of the server', 'gauge', [
        (labels: {'version': serverVersion}, value: 1),
      ])
      ..gauge(
        'famio_uptime_seconds',
        'Seconds since the server started',
        now.difference(m.startedAt).inSeconds,
      )
      ..gauge(
        'famio_process_resident_memory_bytes',
        'Resident memory of the server process',
        residentMemory(),
      );
    final roles = <String, int>{for (final r in MemberRole.values) r.name: 0};
    for (final member in accounts.members()) {
      roles[member.role.name] = roles[member.role.name]! + 1;
    }
    w.add('famio_members', 'Family members by role', 'gauge', [
      for (final e in roles.entries) (labels: {'role': e.key}, value: e.value),
    ]);
    final counts = records.counts();
    w
      ..gauge(
        'famio_records',
        'Live records (all collections)',
        counts.values.fold<int>(0, (a, b) => a + b),
      )
      ..gauge(
        'famio_records_deleted',
        'Deletion marks kept for devices that were offline',
        records.deletedCount(),
      )
      ..gauge('famio_revision', 'Current sync revision', records.currentRev)
      ..gauge(
        'famio_conflicts_open',
        'Changes that crossed and wait for a decision',
        counts[Collections.conflicts] ?? 0,
      )
      ..gauge(
        'famio_websocket_clients',
        'Connected devices (WebSocket)',
        hub.connectedClients,
      );
    final (fileCount, fileBytes) = files.usage();
    w
      ..gauge('famio_files', 'Stored uploads', fileCount)
      ..gauge('famio_files_bytes', 'Size of stored uploads', fileBytes);
    if (dbSize case final size?) {
      w.gauge('famio_database_bytes', 'Size of the main database', size());
    }
    final calendarErrors = [
      for (final r in records.all(Collections.calendarSyncStatus))
        if (r.data['error'] != null) r,
    ].length;
    w.gauge(
      'famio_calendar_subscription_errors',
      'Calendar subscriptions whose last import failed',
      calendarErrors,
    );
    if (backups case final job?) {
      final list = job.list();
      final status = job.status();
      final check = status['lastCheck'] as Map?;
      w
        ..gauge('famio_backups', 'Stored backups', list.length)
        ..gauge(
          'famio_backup_last_timestamp_seconds',
          'Time of the newest backup (0: none)',
          (list.firstOrNull?.at.millisecondsSinceEpoch ?? 0) ~/ 1000,
        )
        ..gauge(
          'famio_backup_failed',
          '1 if the last backup attempt failed',
          status['lastError'] == null ? 0 : 1,
        )
        ..gauge(
          'famio_backup_check_ok',
          '1 if the last tested backup can be restored (-1: never tested)',
          check == null ? -1 : (check['ok'] == true ? 1 : 0),
        );
    }
    w
      ..add(
        'famio_http_responses_total',
        'Responses by status class',
        'counter',
        [
          for (final e in m.responses.entries)
            (labels: {'class': e.key}, value: e.value),
        ],
      )
      ..counter(
        'famio_sync_requests_total',
        'Sync requests answered',
        m.syncRequests,
      )
      ..add('famio_push_total', 'Push messages via ntfy', 'counter', [
        (labels: {'result': 'sent'}, value: m.pushSent),
        (labels: {'result': 'failed'}, value: m.pushFailed),
      ]);
    return Response.ok(
      w.toString(),
      headers: {
        'content-type': 'text/plain; version=0.0.4; charset=utf-8',
        'cache-control': 'no-store',
      },
    );
  }

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
