import 'package:shelf/shelf.dart';

/// The server's request log. Every request in it meant thousands of lines a
/// day (health checks, syncs, calendar apps), with the calendar user name
/// in many paths. By default it now names only what needs attention:
/// server errors, refused requests (except the usual 401 of calendar apps
/// and 404 of probes) and slow ones, plus a summary once a day that names
/// where most of those 401 and 404 went (a spike stays explainable).
/// `FAMIO_ACCESS_LOG=full` writes every request again, for debugging.
///
/// Paths appear as their route (`/dav/calendars/<user>/<calendar>`), never
/// as requested: they carry user names, record ids, feed tokens and file
/// names (of medical documents, say).
class RequestLog {
  RequestLog({
    required this.write,
    this.full = false,
    this.slow = const Duration(seconds: 2),
    Iterable<String> routes = const [],
    DateTime Function()? now,
  }) : _routes = [for (final r in routes) _Route(r)],
       _now = now ?? DateTime.now {
    _since = _now();
  }

  /// Gets each line; `isError` for failures (stderr).
  final void Function(String line, bool isError) write;

  /// Every request, like before.
  final bool full;

  /// Requests taking longer are logged.
  final Duration slow;

  final List<_Route> _routes;
  final DateTime Function() _now;
  late DateTime _since;
  final _counts = <String, int>{};
  var _slowCount = 0;

  /// 401 and 404 answers by path ("404 /wp-login.php"), not logged one by
  /// one; at most [_maxQuietPaths] paths, scanners try thousands.
  final _quiet = <String, int>{};
  static const _maxQuietPaths = 200;

  /// Kept open on purpose: waiting for notifications, the WebSocket.
  static const _longLived = {'api/notifications', 'api/ws'};

  Middleware get middleware =>
      (inner) => (request) async {
        _summaryIfDue();
        final watch = Stopwatch()..start();
        final Response response;
        try {
          response = await inner(request);
        } on HijackException {
          rethrow;
        } catch (error, stack) {
          write(_line(request, watch.elapsed, 'ERROR'), true);
          write('$error\n$stack', true);
          _count('5xx');
          rethrow;
        }
        final status = response.statusCode;
        final elapsed = watch.elapsed;
        final isSlow =
            elapsed >= slow && !_longLived.contains(request.url.path);
        _count('${status ~/ 100}xx');
        if (isSlow) _slowCount++;
        final problem =
            status >= 500 || (status >= 400 && status != 401 && status != 404);
        if (status == 401 || status == 404) _countQuiet(status, request);
        if (full || problem || isSlow) {
          write(
            '${_line(request, elapsed, '[$status]')}${isSlow && !full ? ' (langsam)' : ''}',
            status >= 500,
          );
        }
        return response;
      };

  void _count(String kind) => _counts[kind] = (_counts[kind] ?? 0) + 1;

  void _countQuiet(int status, Request request) {
    var key = '$status ${_shape(request)}';
    if (!_quiet.containsKey(key) && _quiet.length >= _maxQuietPaths) {
      key = '$status (weitere)';
    }
    _quiet[key] = (_quiet[key] ?? 0) + 1;
  }

  void _summaryIfDue() {
    final now = _now();
    if (now.difference(_since) < const Duration(hours: 24)) return;
    final total = _counts.values.fold(0, (a, b) => a + b);
    if (total > 0) {
      final kinds = [
        for (final k in ['2xx', '3xx', '4xx', '5xx'])
          if (_counts[k] case final n?) '$k $n',
      ].join(', ');
      final top =
          (_quiet.entries.toList()..sort(
                (a, b) => b.value != a.value
                    ? b.value.compareTo(a.value)
                    : a.key.compareTo(b.key),
              ))
              .take(3)
              .map((e) => '${e.key} ×${e.value}')
              .join(', ');
      write(
        'Anfragen seit ${_since.toIso8601String()}: $total ($kinds)'
        '${_slowCount > 0 ? ', langsam: $_slowCount' : ''}'
        '${top.isEmpty ? '' : '; häufigste 401/404: $top'}',
        false,
      );
    }
    _counts.clear();
    _quiet.clear();
    _slowCount = 0;
    _since = now;
  }

  /// Like shelf's log line, with the route instead of the path and
  /// without the query (it carries file names).
  String _line(Request request, Duration elapsed, String status) =>
      '${_now().toIso8601String()} $elapsed '
      '${request.method.padRight(7)} $status ${_shape(request)}';

  /// The route [request] went to, the most specific if several fit
  /// (`/api/me/passkeys/options` before `/api/me/passkeys/<id>`). Paths no
  /// route knows (probes, a typo) keep only their first part, `api/<area>`
  /// for the API: "/wp-admin/…".
  String _shape(Request request) {
    final segments = [
      for (final s in request.url.pathSegments)
        if (s.isNotEmpty) s,
    ];
    _Route? best;
    for (final route in _routes) {
      if (route.matches(segments) &&
          (best == null || route.literals > best.literals)) {
        best = route;
      }
    }
    if (best != null) return best.shape;
    final kept = segments.take(segments.firstOrNull == 'api' ? 2 : 1);
    return '/${kept.map((p) => p.length > 40 ? '…' : p).join('/')}'
        '${segments.length > kept.length ? '/…' : ''}';
  }
}

/// A route template like `/api/members/<id>/ring` or `/app/<path|.*>`
/// (the rest of the path).
class _Route {
  _Route(String template)
    : _parts = [
        for (final s in template.split('/'))
          if (s.isNotEmpty) s,
      ];

  final List<String> _parts;

  /// The template with `<path>` for `<path|.*>`.
  late final shape =
      '/${_parts.map((p) => p.startsWith('<') ? '${p.split('|').first.replaceFirst('>', '')}>' : p).join('/')}';

  late final literals = _parts.where((p) => !p.startsWith('<')).length;

  bool matches(List<String> segments) {
    for (var i = 0; i < _parts.length; i++) {
      final part = _parts[i];
      if (part.endsWith('|.*>')) return true;
      if (i >= segments.length) return false;
      if (!part.startsWith('<') && part != segments[i]) return false;
    }
    return segments.length == _parts.length;
  }
}
