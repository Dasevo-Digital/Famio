part of '../api.dart';

/// The emergency button (see [SosService]).
extension _SosRoutes on FamioApi {
  SosService get _sos =>
      sos ?? (throw ApiException(404, 'not_found', 'Notfallknopf fehlt'));

  static double? _number(Object? v) => (v as num?)?.toDouble();

  Future<Response> _sosRaise(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final alert = _sos.raise(
      member,
      latitude: _number(body['latitude']),
      longitude: _number(body['longitude']),
      accuracy: _number(body['accuracy']),
      battery: (body['battery'] as num?)?.toInt(),
    );
    _audit(member, 'hat den Notfallknopf gedrückt');
    hub.notifyRev(records.currentRev);
    return _json(alert.toData()..['id'] = alert.id, status: 201);
  }

  Future<Response> _sosPosition(Request request, String id) async {
    final member = _member(request);
    final body = await _body(request);
    final latitude = _number(body['latitude']);
    final longitude = _number(body['longitude']);
    if (latitude == null || longitude == null) {
      throw ApiException.badRequest('invalid_position', 'Position fehlt');
    }
    final alert = _sos.position(
      member,
      id,
      latitude: latitude,
      longitude: longitude,
      accuracy: _number(body['accuracy']),
      battery: (body['battery'] as num?)?.toInt(),
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
