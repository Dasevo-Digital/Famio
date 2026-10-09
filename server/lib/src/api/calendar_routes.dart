part of '../api.dart';

/// Calendar feeds, subscriptions, CalDAV accounts and occurrences.
extension _CalendarRoutes on FamioApi {
  Response _listFeeds(Request request) {
    final member = _auth(request);
    return _json({
      'feeds': [for (final f in feeds.forUser(member.id)) f.toJson()],
      'publicUrl': publicUrl,
    });
  }

  Future<Response> _createFeed(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final scope = FeedScope.values
        .where((s) => s.name == body['scope'])
        .firstOrNull;
    if (scope == null) {
      throw ApiException.badRequest('invalid_scope', t('Unbekannter Umfang'));
    }
    final feed = feeds.create(
      member.id,
      name: body['name'] as String? ?? '',
      scope: scope,
      hideDetails: body['hideDetails'] as bool? ?? false,
    );
    return _json(feed.toJson(), status: 201);
  }

  Response _deleteFeed(Request request, String id) {
    final member = _auth(request);
    feeds.delete(member.id, id);
    return _json({'ok': true});
  }

  Future<Response> _refreshSubscription(Request request, String id) async {
    _member(request);
    final status = await importer?.refresh(id);
    if (status == null) {
      throw ApiException(404, 'not_found', t('Abo nicht gefunden'));
    }
    return _json({...status.toData(), 'id': status.id});
  }

  CalDavSync get _caldav =>
      caldav ??
      (throw ApiException(404, 'not_found', t('CalDAV nicht verfügbar')));

  Future<Response> _caldavDiscover(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final address = clientAddress.of(request);
    // Password guessing against other servers through Famio is throttled.
    _checkThrottle(address, '#caldav:${member.id}');
    try {
      final calendars = await _caldav.discover(
        url: body['url'] as String? ?? '',
        username: body['username'] as String? ?? '',
        password: body['password'] as String? ?? '',
      );
      return _json({
        'calendars': [for (final c in calendars) c.toJson()],
      });
    } on ApiException {
      throttle.failed(address, '#caldav:${member.id}');
      rethrow;
    }
  }

  /// Completes a Google login: the app sends the code from Google's page,
  /// the server keeps the tokens and lists the calendars to choose from.
  Future<Response> _googleConnect(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    try {
      final grant = await _caldav.google.exchange(
        clientId: (body['clientId'] as String? ?? '').trim(),
        clientSecret: (body['clientSecret'] as String? ?? '').trim(),
        code: body['code'] as String? ?? '',
        codeVerifier: body['codeVerifier'] as String? ?? '',
        redirectUri: body['redirectUri'] as String? ?? '',
      );
      final calendars = await _caldav.google.calendars(grant);
      return _json({
        'grant': _caldav.google.hold(member.id, grant),
        'email': grant.email,
        'calendars': [for (final c in calendars) c.toJson()],
      });
    } on DavException catch (e) {
      throw ApiException.badRequest('google', e.message);
    }
  }

  GoogleGrant? _heldGrant(FamilyMember member, Object? id) {
    if (id == null) return null;
    final grant = _caldav.google.take(member.id, id as String);
    if (grant == null) {
      throw ApiException.badRequest(
        'google_expired',
        t('Google-Anmeldung abgelaufen – bitte erneut anmelden'),
      );
    }
    return grant;
  }

  Response _caldavAccounts(Request request) {
    final member = _member(request);
    return _json({
      'accounts': [for (final a in _caldav.forUser(member.id)) a.toJson()],
    });
  }

  Future<Response> _caldavCreate(Request request) async {
    final member = _member(request);
    final body = await _body(request);
    final account = _caldav.create(
      member.id,
      name: body['name'] as String? ?? '',
      serverUrl: body['serverUrl'] as String? ?? '',
      username: body['username'] as String? ?? '',
      password: body['password'] as String? ?? '',
      calendarUrl: body['calendarUrl'] as String? ?? '',
      calendarName: body['calendarName'] as String? ?? t('Kalender'),
      onlyMine: body['onlyMine'] as bool? ?? false,
      sharing: _sharingFrom(body) ?? const CalendarSharing.family(),
      googleGrant: _heldGrant(member, body['googleGrant']),
    );
    _audit(member, 'hat den Kalender „${account.name}“ verbunden (CalDAV)');
    return _json(
      (await _caldav.syncNow(member.id, account.id)).toJson(),
      status: 201,
    );
  }

  Future<Response> _caldavUpdate(Request request, String id) async {
    final member = _member(request);
    final body = await _body(request);
    _caldav.update(
      member.id,
      id,
      password: body['password'] as String?,
      onlyMine: body['onlyMine'] as bool?,
      sharing: _sharingFrom(body),
      googleGrant: _heldGrant(member, body['googleGrant']),
    );
    return _json((await _caldav.syncNow(member.id, id)).toJson());
  }

  /// `sharedWith` (null: whole family, list: these members), or the older
  /// `privateImport`; null if the request says neither.
  CalendarSharing? _sharingFrom(Map<String, Object?> body) {
    if (body.containsKey('sharedWith')) {
      final sharing = CalendarSharing.fromJson(body['sharedWith']);
      if (sharing.family) return sharing;
      final known = {for (final m in accounts.members()) m.id};
      return CalendarSharing.only([
        for (final id in sharing.members!)
          if (known.contains(id)) id,
      ]);
    }
    return switch (body['privateImport']) {
      true => const CalendarSharing.private(),
      false => const CalendarSharing.family(),
      _ => null,
    };
  }

  /// Calendars shared with member [id] and which of them an admin switched
  /// off (the member's calendar profile).
  Response _adminMemberCalendars(Request request, String id) {
    _admin(request);
    final access = calendarAccess;
    return _json({
      'calendars': [
        if (access != null)
          for (final c in access.calendarsOf(id)) c.toJson(),
      ],
    });
  }

  Future<Response> _adminSetMemberCalendars(Request request, String id) async {
    final admin = _admin(request);
    final target = accounts.byId(id);
    final access = calendarAccess;
    if (target == null || access == null) {
      throw ApiException(404, 'not_found', t('Mitglied nicht gefunden'));
    }
    final body = await _body(request);
    final offered = {for (final c in access.calendarsOf(id)) c.source};
    final hidden = [
      for (final s in body['hidden'] as List? ?? const [])
        if (offered.contains(s)) s as String,
    ];
    access.setHidden(id, hidden);
    if (access.reapply()) hub.notifyRev(records.currentRev);
    _audit(
      admin,
      'hat die Kalender von ${_who(target)} angepasst'
      '${hidden.isEmpty ? '' : ' (${hidden.length} ausgeblendet)'}',
    );
    return _adminMemberCalendars(request, id);
  }

  /// Occurrences of all events [member] may see (own, imported, series
  /// expanded) in `[from, to)`, for clients without the sync engine such as
  /// the Home Assistant integration.
  Response _occurrences(Request request) {
    final member = _auth(request);
    final query = request.url.queryParameters;
    final from = DateTime.tryParse(query['from'] ?? '')?.toLocal();
    final to = DateTime.tryParse(query['to'] ?? '')?.toLocal();
    if (from == null ||
        to == null ||
        !to.isAfter(from) ||
        to.difference(from) > const Duration(days: 400)) {
      throw ApiException.badRequest(
        'invalid_range',
        t('Zeitraum angeben (from, to; höchstens 400 Tage)'),
      );
    }
    String date(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final calendars = {
      for (final r in records.all(
        Collections.calendarSubscriptions,
        visibleToMember: member.id,
      ))
        r.id: CalendarSubscription.fromRecord(r).name,
    };
    final result = <(DateTime, Map<String, Object?>)>[];
    for (final collection in [Collections.events, Collections.externalEvents]) {
      for (final r in records.all(collection, visibleToMember: member.id)) {
        final event = CalendarEvent.fromRecord(r);
        for (final o in event.occurrencesBetween(from, to)) {
          final source = event.sourceId;
          result.add((
            o.start,
            {
              'id': event.id,
              'title': event.title,
              'allDay': event.allDay,
              'start': event.allDay
                  ? date(o.start)
                  : o.start.toUtc().toIso8601String(),
              'end': event.allDay
                  ? date(o.end)
                  : o.end.toUtc().toIso8601String(),
              'location': event.location,
              'notes': event.notes,
              'memberIds': event.memberIds,
              'recurring': event.recurrence != null,
              'readOnly': source != null,
              if (event.confidential) 'confidential': true,
              if (source != null)
                'calendar':
                    calendars[CalendarAccess.sourceOf(source)] ??
                    (source.startsWith('caldav:')
                        ? t('Verbundener Kalender')
                        : null),
            },
          ));
        }
      }
    }
    result.sort((a, b) => a.$1.compareTo(b.$1));
    return _json({
      'occurrences': [for (final (_, o) in result) o],
    });
  }

  Future<Response> _caldavDelete(Request request, String id) async {
    final member = _member(request);
    await _caldav.delete(member.id, id);
    return _json({'ok': true});
  }

  Future<Response> _caldavSync(Request request, String id) async {
    final member = _member(request);
    return _json((await _caldav.syncNow(member.id, id)).toJson());
  }

  /// Public ICS feed; the token in the file name is the credential.
  Response _icalFeed(Request request, String file) {
    final token = file.endsWith('.ics')
        ? file.substring(0, file.length - 4)
        : file;
    final found = feeds.byToken(token);
    if (found == null) return Response.notFound(t('Unbekannter Kalender'));
    final (feed, userId) = found;
    final events = [
      for (final r in records.all(Collections.events, visibleToMember: userId))
        (CalendarEvent.fromRecord(r), r),
    ].where((e) => feed.scope == FeedScope.all || e.$1.involves(userId));
    return Response.ok(
      exportIcs(
        events: events,
        calendarName: feed.name,
        location: location,
        memberNames: {for (final m in accounts.members()) m.id: m.displayName},
        hideDetails: feed.hideDetails,
      ),
      headers: {
        'content-type': 'text/calendar; charset=utf-8',
        'content-disposition': 'inline; filename="famio.ics"',
        'cache-control': 'no-cache',
      },
    );
  }
}
