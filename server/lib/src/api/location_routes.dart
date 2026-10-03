part of '../api.dart';

const _locationScope = 'location';

/// Location sharing of the members' phones.
extension _LocationRoutes on FamioApi {
  LocationService get _locations =>
      locations ??
      (throw ApiException(404, 'not_found', 'Standort nicht verfügbar'));

  /// A phone reports its positions. Works with the app's session and with
  /// the phone's location-only token (see [_locationDeviceToken]).
  Future<Response> _locationReport(Request request) async {
    final token = _bearer(request);
    final member =
        _ingressMember(request) ??
        (token == null
            ? null
            : accounts.userForToken(token) ??
                  accounts.userForToken(token, scope: _locationScope));
    if (member == null) {
      throw ApiException(401, 'unauthorized', 'Nicht angemeldet');
    }
    if (member.isGuest) {
      throw ApiException(403, 'forbidden', 'Für Gäste nicht verfügbar');
    }
    _checkWriter(member);
    final body = await _body(request);
    final fixes = [
      for (final f in (body['fixes'] as List? ?? const []).take(1000))
        LocationFix.fromJson((f as Map).cast()),
    ];
    final state =
        SharingState.values.where((s) => s.name == body['state']).firstOrNull ??
        SharingState.active;
    final device = (body['device'] as String?)?.trim();
    final result = _locations.report(
      member,
      fixes: fixes,
      state: state,
      device: device == null || device.isEmpty
          ? null
          : device.substring(0, device.length.clamp(0, 60)),
      platform: switch (body['platform']) {
        'ios' => 'ios',
        'android' => 'android',
        _ => null,
      },
    );
    // Place notices for this member, so the phone can show them even while
    // the app is closed.
    final since = (body['alertsSince'] as num?)?.toInt();
    final names = {for (final m in accounts.members()) m.id: m.displayName};
    return _json({
      ...result.toJson(),
      if (since != null)
        'alerts': [
          for (final r in records.all(
            Collections.locationAlerts,
            visibleToMember: member.id,
          ))
            if (LocationAlert.fromRecord(r) case final a
                when a.at.millisecondsSinceEpoch > since)
              {
                'id': a.id,
                'text': a.text(names[a.memberId] ?? 'Jemand'),
                'at': a.at.millisecondsSinceEpoch,
              },
        ],
    });
  }

  /// A token that can only report positions, for the phone's background
  /// service: it never unlocks family data if the phone is compromised.
  Future<Response> _locationDeviceToken(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final device = (body['device'] as String? ?? 'Telefon').trim();
    final token = accounts.createSession(
      member.id,
      device: '${device.isEmpty ? 'Telefon' : device} · Standort',
      scope: _locationScope,
    );
    return _json({'token': token}, status: 201);
  }

  /// Pausing needs the parents' code, whoever asks.
  Future<Response> _locationPause(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final target = body['memberId'] as String? ?? member.id;
    if (accounts.byId(target) == null) {
      throw ApiException(404, 'not_found', 'Mitglied nicht gefunden');
    }
    final address = clientAddress.of(request);
    final key = '#loccode:${member.id}';
    _checkThrottle(address, key);
    if (!await _locations.checkCode(body['code'] as String? ?? '')) {
      throttle.failed(address, key);
      throw ApiException(403, 'wrong_code', 'Der Eltern-Code stimmt nicht');
    }
    throttle.succeeded(address, key);
    final minutes = body['minutes'] as int?;
    _locations.pause(
      target,
      duration: minutes == null ? null : Duration(minutes: minutes),
      byMember: member.id,
    );
    _audit(
      member,
      'hat die Standortfreigabe von ${_who(accounts.byId(target))} pausiert',
    );
    return _json({'ok': true});
  }

  /// Sharing again needs no code; others than the member need to be admins.
  Future<Response> _locationResume(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final target = body['memberId'] as String? ?? member.id;
    if (target != member.id && !member.isAdmin) {
      throw ApiException(403, 'forbidden', 'Nur für Eltern (Administratoren)');
    }
    _locations.resume(target);
    return _json({'ok': true});
  }

  /// The way of the last days: only for parents and the member themselves.
  Response _locationHistory(Request request) {
    final member = _member(request);
    final query = request.url.queryParameters;
    final target = query['member'] ?? member.id;
    if (target != member.id && !member.isAdmin) {
      throw ApiException(403, 'forbidden', 'Nur für Eltern (Administratoren)');
    }
    final now = DateTime.now();
    final oldest = now.subtract(_locations.retention);
    final requestedFrom =
        DateTime.tryParse(query['from'] ?? '') ??
        now.subtract(const Duration(days: 1));
    // A point that is about to be collected must not briefly reappear because
    // a client guessed an older query range.
    final from = requestedFrom.isBefore(oldest) ? oldest : requestedFrom;
    final requestedTo = DateTime.tryParse(query['to'] ?? '') ?? now;
    final to = requestedTo.isAfter(now) ? now : requestedTo;
    return _json({
      'points': [
        for (final f in _locations.history(target, from: from, to: to))
          f.toJson(),
      ],
    });
  }

  /// A recurring time window is intentionally private to its owner and the
  /// family's administrators: it can reveal routines even without a point.
  Response _locationSchedule(Request request) {
    final member = _member(request);
    final target = request.url.queryParameters['member'] ?? member.id;
    if (target != member.id && !member.isAdmin) {
      throw ApiException(403, 'forbidden', 'Nur für Eltern (Administratoren)');
    }
    if (accounts.byId(target) == null) {
      throw ApiException(404, 'not_found', 'Mitglied nicht gefunden');
    }
    return _json({'schedule': _locations.scheduleFor(target)?.toJson()});
  }

  /// Changes need the parents' code just like a manual pause, otherwise a
  /// member could silently bypass the family-wide pause protection.
  Future<Response> _locationSetSchedule(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final target = body['memberId'] as String? ?? member.id;
    if (target != member.id && !member.isAdmin) {
      throw ApiException(403, 'forbidden', 'Nur für Eltern (Administratoren)');
    }
    if (accounts.byId(target) == null) {
      throw ApiException(404, 'not_found', 'Mitglied nicht gefunden');
    }
    final address = clientAddress.of(request);
    final key = '#loccode:${member.id}';
    _checkThrottle(address, key);
    if (!await _locations.checkCode(body['code'] as String? ?? '')) {
      throttle.failed(address, key);
      throw ApiException(403, 'wrong_code', 'Der Eltern-Code stimmt nicht');
    }
    throttle.succeeded(address, key);
    final raw = body['schedule'];
    LocationSchedule? schedule;
    if (raw != null) {
      if (raw is! Map) {
        throw ApiException.badRequest(
          'invalid_schedule',
          'Ungültiger Zeitplan',
        );
      }
      try {
        schedule = LocationSchedule.fromJson(raw.cast());
      } on FormatException {
        throw ApiException.badRequest(
          'invalid_schedule',
          'Ungültiger Zeitplan',
        );
      }
    }
    _locations.setSchedule(target, schedule);
    _audit(
      member,
      schedule == null
          ? 'hat den Standort-Zeitplan von ${_who(accounts.byId(target))} entfernt'
          : 'hat den Standort-Zeitplan von ${_who(accounts.byId(target))} geändert',
    );
    return _json({'schedule': schedule?.toJson()});
  }

  Future<Response> _adminLocationCode(Request request) async {
    final admin = _admin(request);
    final body = await _body(request);
    await _locations.setCode(body['code'] as String?);
    _audit(admin, 'hat den Eltern-Code für den Standort geändert');
    return _json({'ok': true, 'codeSet': _locations.codeSet});
  }
}
