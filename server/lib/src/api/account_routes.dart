part of '../api.dart';

/// The signed-in member's own account: profile, sessions, password, app passwords.
extension _AccountRoutes on FamioApi {
  Response _appPasswords(Request request) {
    final member = _auth(request);
    return _json({
      'passwords': [
        for (final p in accounts.appPasswords(member.id)) p.toJson(),
      ],
    });
  }

  Future<Response> _createAppPassword(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    final (password, secret) = accounts.createAppPassword(
      member.id,
      name: body['name'] as String? ?? '',
      includeConfidential: body['includeConfidential'] as bool? ?? false,
    );
    _audit(member, 'hat ein Kalender-App-Passwort „${password.name}“ erstellt');
    return _json({
      'password': password.toJson(),
      'secret': secret,
    }, status: 201);
  }

  /// A configuration profile for Apple devices: connects Apple Calendar via
  /// CalDAV with a new app password and, for the server's own certificate,
  /// makes the device trust it. [url] is the address the app uses.
  Future<Response> _appleProfile(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    final base = Uri.tryParse(body['url'] as String? ?? '');
    if (base == null ||
        base.host.isEmpty ||
        !(base.scheme == 'http' || base.scheme == 'https')) {
      throw ApiException(400, 'invalid_url', t('Ungültige Serveradresse'));
    }
    final own = base.scheme == 'http' || base.port == tlsPort;
    final tls = this.tls;
    if (own && (tls == null || tlsPort == null)) {
      throw ApiException(
        400,
        'no_tls',
        t(
          'Apple Kalender braucht HTTPS: den HTTPS-Port des Servers (FAMIO_TLS_PORT) einschalten oder die Adresse über den Reverse-Proxy verwenden.',
        ),
      );
    }
    if (own && !tls!.covers(base.host)) {
      // The listener switches to the new certificate after this request.
      tls.addName(base.host);
      _audit(member, 'hat „${base.host}“ ins HTTPS-Zertifikat aufgenommen');
    }
    final (password, secret) = accounts.createAppPassword(
      member.id,
      name: (body['name'] as String?)?.trim().isNotEmpty == true
          ? (body['name'] as String).trim()
          : t('Apple Kalender'),
    );
    _audit(member, 'hat ein Apple-Profil „${password.name}“ erstellt');
    final port = own ? tlsPort! : base.port;
    final host = base.host.contains(':') ? '[${base.host}]' : base.host;
    final prefix = own ? '' : base.path.replaceAll(RegExp(r'/+$'), '');
    return _json({
      'fileName': 'Famio-Kalender.mobileconfig',
      'password': password.toJson(),
      'profile': appleCalendarProfile(
        host: base.host,
        port: port,
        principalUrl:
            'https://$host:$port$prefix/dav/principals/'
            '${Uri.encodeComponent(member.username)}/',
        username: member.username,
        password: secret,
        rootCertificate: own ? derOf(tls!.identity.caPem!) : null,
      ),
    }, status: 201);
  }

  Response _deleteAppPassword(Request request, String id) {
    final member = _auth(request);
    accounts.deleteAppPassword(member.id, id);
    return _json({'ok': true});
  }

  Response _me(Request request) {
    final member = _auth(request);
    return _json({
      ...member.toJson(),
      'hasPassword': accounts.hasPassword(member.id),
    });
  }

  /// Members may change their own display name and color.
  Future<Response> _updateMe(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    final updated = accounts.update(
      member.id,
      displayName: body['displayName'] as String?,
      color: body['color'] as int?,
      birthday: body.containsKey('birthday') ? body['birthday'] : _unchanged,
    );
    hub.notifyMembersChanged();
    return _json(updated.toJson());
  }

  /// Self-service account deletion. Shared family entries deliberately stay:
  /// removing them could erase data owned by other family members.
  Future<Response> _deleteMe(Request request) async {
    final member = _member(request);
    if (member.isAdmin && accounts.adminCount <= 1) {
      throw ApiException.badRequest(
        'last_admin',
        t(
          'Lege zuerst einen weiteren Administrator an oder übergib die Verwaltung.',
        ),
      );
    }
    final body = await _body(request);
    final address = clientAddress.of(request);
    _checkThrottle(address, '#delete:${member.id}');
    if (!accounts.hasPassword(member.id) ||
        !await accounts.checkPassword(
          member.id,
          body['password'] as String? ?? '',
        )) {
      throttle.failed(address, '#delete:${member.id}');
      throw ApiException(
        403,
        'reauth_required',
        t('Passwort zur Bestätigung falsch'),
      );
    }
    if (mfa.hasTotp(member.id) &&
        !mfa.check(member.id, body['code'] as String? ?? '')) {
      throttle.failed(address, '#delete:${member.id}');
      throw ApiException(403, 'reauth_required', t('Bestätigungscode falsch'));
    }
    await caldav?.disconnectUser(member.id);
    locations?.memberDeleted(member.id);
    accounts.delete(
      member.id,
    ); // cascades sessions, feeds, app passwords and SSO.
    _audit(member, 'hat das eigene Konto gelöscht');
    hub.notifyMembersChanged();
    if (calendarAccess?.reapply() ?? false) hub.notifyRev(records.currentRev);
    return _json({'ok': true});
  }

  Response _mySessions(Request request) {
    final member = _auth(request);
    final user = accounts
        .adminUsers(currentToken: _bearer(request))
        .firstWhere((u) => u.member.id == member.id);
    return _json({
      'sessions': [for (final s in user.sessions) s.toJson()],
    });
  }

  Response _deleteMySession(Request request, String sid) {
    final member = _auth(request);
    accounts.deleteSessions(member.id, sessionId: sid);
    return _json({'ok': true});
  }

  Future<Response> _changePassword(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    // Guessing the current password with a stolen session is throttled too.
    final address = clientAddress.of(request);
    _checkThrottle(address, '#pw:${member.id}');
    // Home Assistant users start without a password and may set one freely.
    if (accounts.hasPassword(member.id) &&
        !await accounts.checkPassword(
          member.id,
          body['currentPassword'] as String? ?? '',
        )) {
      throttle.failed(address, '#pw:${member.id}');
      throw ApiException(
        403,
        'invalid_credentials',
        t('Aktuelles Passwort falsch'),
      );
    }
    await accounts.setPassword(member.id, body['newPassword'] as String? ?? '');
    // A new password also locks out whoever may know the old one.
    final signedOut = accounts.deleteSessions(
      member.id,
      exceptToken: _bearer(request),
    );
    return _json({'ok': true, 'signedOut': signedOut});
  }
}
