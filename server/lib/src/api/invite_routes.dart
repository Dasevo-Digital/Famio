part of '../api.dart';

/// Invitations instead of handed-over passwords (see [Invites]).
extension _InviteRoutes on FamioApi {
  Invites get _invites =>
      invites ?? (throw ApiException(404, 'not_found', 'Einladungen fehlen'));

  /// Throttled like a login: the code is the only secret.
  static const _throttleKey = '#invite';

  Response _openInvites(Request request) {
    _admin(request);
    return _json({
      'invites': [for (final i in _invites.open()) i.toJson()],
    });
  }

  Future<Response> _createInvite(Request request) async {
    final admin = _admin(request);
    final body = await _body(request);
    final hours = (body['hours'] as num?)?.toInt() ?? 48;
    final (invite, code) = _invites.create(
      role: MemberRole.parse(body['role']),
      displayName: body['displayName'] as String? ?? '',
      createdBy: admin.id,
      valid: Duration(hours: hours.clamp(1, 24 * 14)),
    );
    _audit(admin, 'hat eine Einladung (${invite.role.label}) erstellt');
    return _json({...invite.toJson(), 'code': code}, status: 201);
  }

  Response _revokeInvite(Request request, String id) {
    final admin = _admin(request);
    _invites.revoke(id);
    _audit(admin, 'hat eine Einladung zurückgezogen');
    return _json({'ok': true});
  }

  Invite _findInvite(Request request, String code) {
    final address = clientAddress.of(request);
    _checkThrottle(address, _throttleKey);
    final invite = _invites.find(code);
    if (invite == null) {
      throttle.failed(address, _throttleKey);
      throw ApiException(
        404,
        'invalid_invite',
        'Diese Einladung gibt es nicht oder sie ist abgelaufen.',
      );
    }
    return invite;
  }

  /// What the newcomer is invited as, before they choose a password.
  Future<Response> _checkInvite(Request request) async {
    final body = await _body(request);
    final invite = _findInvite(request, body['code'] as String? ?? '');
    return _json({
      'role': invite.role.name,
      'displayName': invite.displayName,
      'expiresAt': invite.expiresAt.toUtc().toIso8601String(),
    });
  }

  Future<Response> _redeemInvite(Request request) async {
    final body = await _body(request);
    final code = body['code'] as String? ?? '';
    _findInvite(request, code);
    final member = await _invites.redeem(
      code,
      username: body['username'] as String? ?? '',
      displayName: body['displayName'] as String? ?? '',
      password: body['password'] as String? ?? '',
    );
    _audit(member, 'ist der Familie per Einladung beigetreten');
    hub.notifyMembersChanged();
    if (calendarAccess?.reapply() ?? false) hub.notifyRev(records.currentRev);
    return _session(member, body['device'] as String?, method: 'invite');
  }
}
