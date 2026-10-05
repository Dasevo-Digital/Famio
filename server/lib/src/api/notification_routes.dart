part of '../api.dart';

const _noticeScope = 'notify';

/// Push targets (ntfy) and Famio's own notifications.
extension _NotificationRoutes on FamioApi {
  PushService get _push =>
      push ?? (throw ApiException(404, 'not_found', 'Push nicht verfügbar'));

  Response _pushTargets(Request request) {
    final member = _auth(request);
    return _json({
      'targets': [for (final t in _push.targets(member.id)) t.toJson()],
    });
  }

  /// Adds a device and sends it a test message right away.
  Future<Response> _addPushTarget(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    final target = await _push.add(
      member.id,
      name: body['name'] as String? ?? '',
      url: body['url'] as String? ?? '',
      token: body['token'] as String?,
      details: body['details'] as bool? ?? false,
    );
    final error = await _push.test(member.id, target.id);
    return _json({...target.toJson(), 'lastError': error}, status: 201);
  }

  Response _deletePushTarget(Request request, String id) {
    final member = _auth(request);
    _push.remove(member.id, id);
    return _json({'ok': true});
  }

  Future<Response> _testPushTarget(Request request, String id) async {
    final member = _auth(request);
    final error = await _push.test(member.id, id);
    return _json({'ok': error == null, 'error': error});
  }

  Response _quietHours(Request request) {
    final member = _auth(request);
    return _json(_push.quietHours(member.id).toJson());
  }

  Future<Response> _setQuietHours(Request request) async {
    final member = _auth(request);
    final quiet = QuietHours.fromJson(await _body(request));
    _push.setQuietHours(member.id, quiet);
    return _json(quiet.toJson());
  }

  NoticeBox get _box =>
      notices ??
      (throw ApiException(404, 'not_found', 'Benachrichtigungen fehlen'));

  /// Signed in normally or with a phone's notification-only token.
  FamilyMember _noticeMember(Request request) {
    final token = _bearer(request);
    if (token != null) {
      if (accounts.userForToken(token, scope: _noticeScope) case final m?) {
        return m;
      }
    }
    return _auth(request);
  }

  /// New notifications after `after`; with `wait` (seconds, at most 300)
  /// the request stays open until one arrives. Without `after` only the
  /// current position is returned, so a new device starts fresh.
  Future<Response> _notices(Request request) async {
    final member = _noticeMember(request);
    final query = request.url.queryParameters;
    final latest = _box.latest(member.id);
    final after = int.tryParse(query['after'] ?? '');
    // Unknown position (new device, data wiped): start at the newest.
    if (after == null || after > latest) {
      return _json({'notices': const [], 'last': latest});
    }
    final wait = (int.tryParse(query['wait'] ?? '') ?? 0).clamp(0, 300);
    final found = await _box.wait(
      member.id,
      after,
      timeout: Duration(seconds: wait),
    );
    return _json({
      'notices': found,
      'last': found.isEmpty ? after : found.last['id'],
    });
  }

  /// A token that can only fetch notifications, for the phone's
  /// background service (it never sees the app's login).
  Future<Response> _noticeDeviceToken(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    final device = (body['device'] as String? ?? 'Telefon').trim();
    final token = accounts.createSession(
      member.id,
      device: '${device.isEmpty ? 'Telefon' : device} · Benachrichtigungen',
      scope: _noticeScope,
    );
    return _json({'token': token}, status: 201);
  }

  Response _testNotice(Request request) {
    final member = _noticeMember(request);
    _box.add(
      [member.id],
      const PushNotice(
        to: {},
        title: 'Famio',
        body: 'Benachrichtigungen funktionieren 🎉',
        brief: 'Benachrichtigungen funktionieren 🎉',
        tag: 'tada',
      ),
    );
    return _json({'ok': true});
  }
}
