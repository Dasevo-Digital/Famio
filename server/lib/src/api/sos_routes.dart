part of '../api.dart';

/// Scope of the token a phone's background service uses to send positions
/// during an emergency; it can do nothing else.
const _sosScope = 'sos';

/// The emergency button (see [SosService]).
extension _SosRoutes on FamioApi {
  SosService get _sos =>
      sos ?? (throw ApiException(404, 'not_found', t('Notfallknopf fehlt')));

  static double? _number(Object? v) => (v as num?)?.toDouble();

  /// A number that is none (JSON allows 1e400, #479) counts as missing: an
  /// emergency is raised in any case.
  static double? _finite(Object? v) => switch (_number(v)) {
    final double n when n.isFinite => n,
    _ => null,
  };

  /// A battery level, if the value is one.
  static int? _percent(Object? v) => switch (_number(v)) {
    final double n when n >= 0 && n <= 100 => n.toInt(),
    _ => null,
  };

  Future<Response> _sosRaise(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final latitude = _finite(body['latitude']);
    final longitude = _finite(body['longitude']);
    final valid =
        latitude != null &&
        longitude != null &&
        latitude.abs() <= 90 &&
        longitude.abs() <= 180;
    final alert = _sos.raise(
      member,
      latitude: valid ? latitude : null,
      longitude: valid ? longitude : null,
      accuracy: valid ? _finite(body['accuracy']) : null,
      battery: _percent(body['battery']),
    );
    _audit(member, 'hat den Notfallknopf gedrückt');
    hub.notifyRev(records.currentRev);
    return _json(alert.toData()..['id'] = alert.id, status: 201);
  }

  /// A token for the phone's background service: sends positions of the
  /// member's emergencies, nothing else.
  Future<Response> _sosDeviceToken(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final device = (body['device'] as String? ?? 'Telefon').trim();
    final token = accounts.createSession(
      member.id,
      device: t('{device} · Notruf', {
        'device': device.isEmpty ? t('Telefon') : device,
      }),
      scope: _sosScope,
    );
    return _json({'token': token}, status: 201);
  }

  Future<Response> _sosPosition(Request request, String id) async {
    final token = _bearer(request);
    final member = token == null
        ? _member(request)
        : accounts.userForToken(token, scope: _sosScope) ?? _member(request);
    final body = await _body(request);
    final latitude = _finite(body['latitude']);
    final longitude = _finite(body['longitude']);
    if (latitude == null || longitude == null) {
      throw ApiException.badRequest('invalid_position', t('Position fehlt'));
    }
    if (latitude.abs() > 90 || longitude.abs() > 180) {
      throw ApiException.badRequest(
        'invalid_position',
        t('Ungültige Position'),
      );
    }
    final alert = _sos.position(
      member,
      id,
      latitude: latitude,
      longitude: longitude,
      accuracy: _finite(body['accuracy']),
      battery: _percent(body['battery']),
    );
    hub.notifyRev(records.currentRev);
    return _json(alert.toData()..['id'] = alert.id);
  }

  Future<Response> _checkIn(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final alert = _sos.checkIn(
      member,
      note: body['note'] as String? ?? '',
      latitude: _number(body['latitude']),
      longitude: _number(body['longitude']),
    );
    hub.notifyRev(records.currentRev);
    return _json(alert.toData()..['id'] = alert.id, status: 201);
  }

  Response _requestCheckIn(Request request, String id) {
    final member = _member(request);
    _sos.requestCheckIn(member, id);
    return _json({'ok': true});
  }

  Response _ring(Request request, String id) {
    final member = _member(request);
    _sos.ring(member, id);
    _audit(member, 'hat ein Handy klingeln lassen');
    return _json({'ok': true});
  }

  Response _sosComing(Request request, String id) {
    final member = _member(request);
    final alert = _sos.coming(member, id);
    _audit(member, 'kommt zum Notfall');
    hub.notifyRev(records.currentRev);
    return _json(alert.toData()..['id'] = alert.id);
  }

  Response _sosResolve(Request request, String id) {
    final member = _member(request);
    final alert = _sos.resolve(member, id);
    _audit(member, 'hat einen Notfall beendet');
    hub.notifyRev(records.currentRev);
    return _json(alert.toData()..['id'] = alert.id);
  }
}
