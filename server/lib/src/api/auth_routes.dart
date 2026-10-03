part of '../api.dart';

/// Setup, login, two-factor and single sign-on.
extension _AuthRoutes on FamioApi {
  Future<Response> _setup(Request request) async {
    if (accounts.hasUsers) {
      throw ApiException(
        409,
        'already_set_up',
        'Server ist bereits eingerichtet',
      );
    }
    final body = await _body(request);
    if (setupCode case final expected?) {
      final address = clientAddress.of(request);
      _checkThrottle(address, '#setup');
      final given = (body['setupCode'] as String? ?? '').trim().toUpperCase();
      if (!_constantTimeEquals(given, expected)) {
        throttle.failed(address, '#setup');
        throw ApiException(
          403,
          'setup_code_required',
          'Einrichtungscode fehlt oder ist falsch. Er steht im Server-Log '
              '(z. B. docker logs famio).',
        );
      }
    }
    final hash = await accounts.hashPassword(body['password'] as String? ?? '');
    // Checked again: another setup may have finished while hashing.
    if (accounts.hasUsers) {
      throw ApiException(
        409,
        'already_set_up',
        'Server ist bereits eingerichtet',
      );
    }
    final member = accounts.create(
      username: body['username'] as String? ?? '',
      displayName: body['displayName'] as String? ?? '',
      passwordHash: hash,
      isAdmin: true,
    );
    _audit(member, 'hat den Server eingerichtet');
    return _session(member, body['device'] as String?, method: 'password');
  }

  Future<Response> _login(Request request) async {
    final body = await _body(request);
    final username = body['username'] as String? ?? '';
    final address = clientAddress.of(request);
    _checkThrottle(address, username);
    final member = await accounts.verify(
      username,
      body['password'] as String? ?? '',
    );
    if (member == null) {
      throttle.failed(address, username);
      throw ApiException(
        401,
        'invalid_credentials',
        'Benutzername oder Passwort falsch',
      );
    }
    throttle.succeeded(address, username);
    final device = body['device'] as String?;
    if (mfa.hasTotp(member.id)) {
      // The password was right; the code from the authenticator app follows.
      final challenge = _randomToken();
      final now = DateTime.now();
      _challenges.removeWhere((_, c) => c.expires.isBefore(now));
      _challenges[challenge] = (
        userId: member.id,
        device: device,
        expires: now.add(const Duration(minutes: 5)),
        tries: 0,
      );
      return _json({'twoFactorRequired': true, 'challenge': challenge});
    }
    return _session(member, device, method: 'password');
  }

  /// Second step of a login with two-factor authentication.
  Future<Response> _loginTwoFactor(Request request) async {
    final body = await _body(request);
    final id = body['challenge'] as String? ?? '';
    final challenge = _challenges[id];
    if (challenge == null || challenge.expires.isBefore(DateTime.now())) {
      _challenges.remove(id);
      throw ApiException(
        401,
        'challenge_expired',
        'Die Anmeldung ist abgelaufen. Bitte noch einmal mit Passwort.',
      );
    }
    final address = clientAddress.of(request);
    final key = '#2fa:${challenge.userId}';
    _checkThrottle(address, key);
    if (!mfa.check(challenge.userId, body['code'] as String? ?? '')) {
      throttle.failed(address, key);
      final tries = challenge.tries + 1;
      if (tries >= 5) {
        _challenges.remove(id);
      } else {
        _challenges[id] = (
          userId: challenge.userId,
          device: challenge.device,
          expires: challenge.expires,
          tries: tries,
        );
      }
      throw ApiException(401, 'invalid_code', 'Der Code stimmt nicht');
    }
    throttle.succeeded(address, key);
    _challenges.remove(id);
    final member = accounts.byId(challenge.userId);
    if (member == null) {
      throw ApiException(401, 'unauthorized', 'Nicht angemeldet');
    }
    return _session(member, challenge.device, method: 'totp');
  }

  Response _twoFactorStatus(Request request) {
    final member = _auth(request);
    final token = _bearer(request);
    final method = token == null ? null : accounts.sessionMethod(token);
    final policy = settings.effective.twoFactorRequired;
    return _json({
      'twoFactor': mfa.hasTotp(member.id),
      'recoveryCodesLeft': mfa.recoveryCodesLeft(member.id),
      'required': policy?.appliesTo(member) ?? false,
      'sessionVerified': method == 'totp' || method == 'sso',
      'singleSignOn': sso?.isLinked(member.id) ?? false,
      'singleSignOnName': sso?.linkName(member.id),
      if (sso case final sso? when sso.enabled)
        'singleSignOnLabel': sso.config!.buttonLabel,
    });
  }

  /// Starts the setup: secret and otpauth link for the QR code.
  Response _totpBegin(Request request) {
    final member = _auth(request);
    if (mfa.hasTotp(member.id)) {
      throw ApiException(
        409,
        'already_enabled',
        'Zwei-Faktor ist schon eingerichtet – zum Wechseln des Handys zuerst '
            'ausschalten.',
      );
    }
    final secret = mfa.begin(member.id);
    return _json({
      'secret': secret,
      'uri': Totp.uri(
        secret,
        account: member.username,
        issuer: 'Famio',
      ).toString(),
    });
  }

  Future<Response> _totpConfirm(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    final address = clientAddress.of(request);
    _checkThrottle(address, '#2fa:${member.id}');
    final List<String> codes;
    try {
      codes = mfa.confirm(member.id, body['code'] as String? ?? '');
    } on ApiException {
      throttle.failed(address, '#2fa:${member.id}');
      rethrow;
    }
    // This device just proved the second factor.
    if (_bearer(request) case final token?) {
      accounts.setSessionMethod(token, 'totp');
    }
    _audit(member, 'hat die Zwei-Faktor-Anmeldung eingeschaltet');
    return _json({'recoveryCodes': codes});
  }

  Future<Response> _totpDisable(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    if (settings.effective.twoFactorRequired?.appliesTo(member) ?? false) {
      throw ApiException(
        403,
        'two_factor_mandatory',
        'Für dein Konto ist die Zwei-Faktor-Anmeldung Pflicht.',
      );
    }
    await _checkSecondFactor(request, member, body, needPassword: true);
    mfa.disable(member.id);
    _audit(member, 'hat die Zwei-Faktor-Anmeldung ausgeschaltet');
    return _json({'ok': true});
  }

  Future<Response> _recoveryCodes(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    await _checkSecondFactor(request, member, body);
    _audit(member, 'hat neue Wiederherstellungscodes erzeugt');
    return _json({'recoveryCodes': mfa.newRecoveryCodes(member.id)});
  }

  /// Confirms the second factor for an existing session, e.g. after an
  /// admin made it mandatory.
  Future<Response> _twoFactorVerify(Request request) async {
    final member = _auth(request);
    final body = await _body(request);
    await _checkSecondFactor(request, member, body);
    if (_bearer(request) case final token?) {
      accounts.setSessionMethod(token, 'totp');
    }
    return _json({'ok': true});
  }

  /// Checks the code (and the password, if asked and the member has one),
  /// throttled like a login.
  Future<void> _checkSecondFactor(
    Request request,
    FamilyMember member,
    Map<String, Object?> body, {
    bool needPassword = false,
  }) async {
    final address = clientAddress.of(request);
    final key = '#2fa:${member.id}';
    _checkThrottle(address, key);
    final passwordOk =
        !needPassword ||
        !accounts.hasPassword(member.id) ||
        await accounts.checkPassword(
          member.id,
          body['password'] as String? ?? '',
        );
    if (!passwordOk || !mfa.check(member.id, body['code'] as String? ?? '')) {
      throttle.failed(address, key);
      throw ApiException(
        403,
        'invalid_code',
        passwordOk ? 'Der Code stimmt nicht' : 'Passwort falsch',
      );
    }
    throttle.succeeded(address, key);
  }

  SsoService get _sso =>
      sso ??
      (throw ApiException(
        404,
        'sso_disabled',
        'Single Sign-On nicht verfügbar',
      ));

  /// Starts a sign-in (or linking the own account) in the browser.
  Future<Response> _ssoStart(Request request) async {
    final body = await _body(request);
    final link = body['mode'] == 'link';
    final member = link ? _auth(request) : null;
    final flow = await _sso.start(
      mode: link ? SsoMode.link : SsoMode.login,
      userId: member?.id,
      device: body['device'] as String?,
    );
    return _json({
      'url': flow.url.toString(),
      'flow': flow.flow,
      'secret': flow.secret,
    });
  }

  /// The provider sends the browser back here.
  Future<Response> _ssoCallback(Request request) async {
    final result = await _sso.callback(
      request.url.queryParameters,
      memberForUsername: (name) => accounts
          .members()
          .where((m) => m.username.toLowerCase() == name.toLowerCase())
          .firstOrNull
          ?.id,
      audit: (userId, what) => _audit(accounts.byId(userId)!, what),
    );
    return Response(
      result.ok ? 200 : 400,
      body: ssoResultPage(ok: result.ok, message: result.message),
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }

  /// The app waits for the browser part: pending, or the new session.
  Future<Response> _ssoPoll(Request request) async {
    final body = await _body(request);
    final done = _sso.poll(
      body['flow'] as String? ?? '',
      body['secret'] as String? ?? '',
    );
    if (done == null) return _json({'status': 'pending'});
    final member = accounts.byId(done.userId);
    if (member == null) {
      throw ApiException(404, 'not_found', 'Mitglied nicht gefunden');
    }
    if (done.mode == SsoMode.link) {
      return _json({'status': 'done', 'member': member.toJson()});
    }
    final token = accounts.createSession(
      member.id,
      device: done.device,
      method: 'sso',
    );
    return _json({'status': 'done', 'token': token, 'member': member.toJson()});
  }

  Response _ssoUnlinkMe(Request request) {
    final member = _auth(request);
    _sso.unlink(member.id);
    _audit(member, 'hat Single Sign-On gelöst');
    return _json({'ok': true});
  }

  Response _adminResetTwoFactor(Request request, String id) {
    final admin = _admin(request);
    final target = accounts.byId(id);
    if (target == null) {
      throw ApiException(404, 'not_found', 'Mitglied nicht gefunden');
    }
    mfa.disable(id);
    _audit(
      admin,
      'hat die Zwei-Faktor-Anmeldung von ${_who(target)} zurückgesetzt',
    );
    return _json({'ok': true});
  }

  Response _adminUnlinkSso(Request request, String id) {
    final admin = _admin(request);
    final target = accounts.byId(id);
    if (target == null) {
      throw ApiException(404, 'not_found', 'Mitglied nicht gefunden');
    }
    _sso.unlink(id);
    _audit(admin, 'hat Single Sign-On von ${_who(target)} gelöst');
    return _json({'ok': true});
  }

  Response _adminSso(Request request) {
    _admin(request);
    final config = _sso.config;
    return _json({
      'configured': config != null,
      'issuer': config?.issuer,
      'clientId': config?.clientId,
      'secretSet': (config?.clientSecret ?? '').isNotEmpty,
      'label': config?.label,
      'matchUsername': config?.matchUsername ?? false,
      'redirectUri': _sso.redirectUri,
    });
  }

  Future<Response> _adminSaveSso(Request request) async {
    final admin = _admin(request);
    final body = await _body(request);
    if (publicUrl == null) {
      throw ApiException.badRequest(
        'public_url_missing',
        'Zuerst die öffentliche Adresse eintragen: der Anbieter leitet dorthin '
            'zurück.',
      );
    }
    await _sso.save(
      SsoConfig(
        issuer: body['issuer'] as String? ?? '',
        clientId: body['clientId'] as String? ?? '',
        clientSecret: body['clientSecret'] as String? ?? '',
        label: body['label'] as String? ?? '',
        matchUsername: body['matchUsername'] as bool? ?? false,
      ),
    );
    _audit(admin, 'hat Single Sign-On eingerichtet (${body['issuer']})');
    return _adminSso(request);
  }

  Response _adminDeleteSso(Request request) {
    final admin = _admin(request);
    _sso.remove();
    _audit(admin, 'hat Single Sign-On entfernt');
    return _json({'ok': true});
  }

  Response _logout(Request request) {
    final token = _bearer(request);
    if (token != null) accounts.deleteSession(token);
    return _json({'ok': true});
  }
}
