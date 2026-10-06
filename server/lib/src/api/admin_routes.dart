part of '../api.dart';

/// Members and server administration.
extension _AdminRoutes on FamioApi {
  Response _adminOverview(Request request) {
    _admin(request);
    return _json(_overview().toJson());
  }

  ServerOverview _overview() {
    final (fileCount, fileBytes) = files.usage();
    return ServerOverview(
      version: serverVersion,
      startedAt: _startedAt,
      settings: settings.stored,
      defaults: settings.defaults,
      effective: settings.effective,
      trustProxy: trustProxy,
      ingressAuth: ingressAuth,
      databaseBytes: dbSize?.call() ?? 0,
      fileCount: fileCount,
      fileBytes: fileBytes,
      recordCounts: records.counts(),
      memberCount: accounts.members().length,
      sessionCount: accounts.sessionCount,
      connectedClients: hub.connectedClients,
      tlsPort: tlsPort,
      tlsFingerprint: tlsFingerprint,
      requireTls: requireTls,
      encryptedAtRest: encryptedAtRest,
      keySeparate: keySeparate,
      locationCodeSet: locations?.codeSet ?? false,
    );
  }

  Future<Response> _adminSettings(Request request) async {
    final admin = _admin(request);
    final zone = location.name;
    final changes = await _body(request);
    settings.update(changes);
    _audit(
      admin,
      'hat Servereinstellungen geändert: '
      '${changes.keys.join(', ')}',
    );
    // The apps reload their configuration with the member list.
    if (changes.containsKey('hiddenModules') ||
        changes.containsKey('holidayRegion')) {
      hub.notifyMembersChanged();
    }
    // Retention is a privacy boundary. Do not wait for the six-hour
    // housekeeping job when an administrator shortens it.
    if (changes.containsKey('locationHistoryDays')) {
      locations?.collectGarbage();
    }
    // Imported floating times depend on the zone.
    if (location.name != zone) importer?.subscriptionsChanged();
    return _json(_overview().toJson());
  }

  /// Sets every server setting back to its default (environment variables,
  /// add-on options). The parents' code for location sharing stays.
  Response _adminResetSettings(Request request) {
    final admin = _admin(request);
    final zone = location.name;
    settings.reset();
    // Resetting may also shorten the effective retention.
    locations?.collectGarbage();
    _audit(admin, 'hat die Servereinstellungen auf Standard zurückgesetzt');
    hub.notifyMembersChanged();
    if (location.name != zone) importer?.subscriptionsChanged();
    return _json(_overview().toJson());
  }

  /// Deletes all of the family's data: every record (calendar, chat, lists,
  /// documents …), uploaded files, positions, calendar connections and
  /// feed links. Accounts stay, unless `removeMembers` also removes
  /// everybody but the admin. Needs the admin's password (if they have one)
  /// and [wipeConfirmation].
  Future<Response> _adminWipe(Request request) async {
    final admin = _admin(request);
    final body = await _body(request);
    if (body['confirm'] != FamioApi.wipeConfirmation) {
      throw ApiException.badRequest(
        'confirmation_required',
        'Zur Bestätigung „${FamioApi.wipeConfirmation}“ eingeben',
      );
    }
    final address = clientAddress.of(request);
    _checkThrottle(address, '#pw:${admin.id}');
    if (accounts.hasPassword(admin.id) &&
        !await accounts.checkPassword(
          admin.id,
          body['password'] as String? ?? '',
        )) {
      throttle.failed(address, '#pw:${admin.id}');
      throw ApiException(403, 'invalid_credentials', 'Passwort falsch');
    }
    final removeMembers = body['removeMembers'] as bool? ?? false;
    // First, so nothing of the deletion reaches iCloud, Google & Co.
    await caldav?.disconnectAll();
    final count = records.wipe();
    final fileCount = files.deleteAll();
    locations?.deleteAll();
    feeds.deleteAll();
    notices?.deleteAll();
    calendarAccess?.clearHidden();
    var memberCount = 0;
    if (removeMembers) {
      for (final m in accounts.members()) {
        if (m.id == admin.id) continue;
        accounts.delete(m.id);
        memberCount++;
      }
    }
    compactDatabase?.call();
    _audit(
      admin,
      'hat alle Daten gelöscht ($count Einträge, $fileCount Dateien'
      '${removeMembers ? ', $memberCount Mitglieder' : ''})',
    );
    hub.notifyRev(records.currentRev);
    if (memberCount > 0) hub.notifyMembersChanged();
    importer?.subscriptionsChanged();
    return _json({
      'ok': true,
      'records': count,
      'files': fileCount,
      'members': memberCount,
    });
  }

  Response _adminUsers(Request request) {
    _admin(request);
    return _json({
      'users': [
        for (final u in accounts.adminUsers(currentToken: _bearer(request)))
          u.toJson(),
      ],
    });
  }

  Future<Response> _adminUpdateUser(Request request, String id) async {
    final admin = _admin(request);
    final body = await _body(request);
    final before = accounts.byId(id);
    final updated = accounts.update(
      id,
      username: body['username'] as String?,
      displayName: body['displayName'] as String?,
      isAdmin: body['isAdmin'] as bool?,
      color: body['color'] as int?,
      birthday: body.containsKey('birthday') ? body['birthday'] : _unchanged,
      role: body['role'] == null ? null : MemberRole.parse(body['role']),
      serviceAccess: body['serviceAccess'] == null
          ? null
          : ServiceAccess.parse(body['serviceAccess']),
    );
    if (before != null &&
        updated.isService &&
        before.serviceAccess != updated.serviceAccess) {
      _audit(
        admin,
        'hat für ${_who(updated)} „${updated.serviceAccess.label}“ eingestellt',
      );
    }
    if (before != null && before.role != updated.role) {
      _audit(
        admin,
        'hat ${_who(updated)} die Rolle ${updated.role.label} gegeben',
      );
    }
    if (before != null && before.isAdmin != updated.isAdmin) {
      _audit(
        admin,
        updated.isAdmin
            ? 'hat ${_who(updated)} zum Administrator gemacht'
            : 'hat ${_who(updated)} die Administratorrechte entzogen',
      );
    }
    hub.notifyMembersChanged();
    return _json(updated.toJson());
  }

  /// Sets a new password for a member, e.g. when they forgot theirs.
  /// Their other devices are signed out unless `signOut` is false.
  Future<Response> _adminResetPassword(Request request, String id) async {
    final admin = _admin(request);
    final body = await _body(request);
    final target = accounts.byId(id);
    if (target == null) {
      throw ApiException(404, 'not_found', 'Mitglied nicht gefunden');
    }
    await accounts.setPassword(id, body['password'] as String? ?? '');
    var signedOut = 0;
    if (body['signOut'] as bool? ?? true) {
      signedOut = accounts.deleteSessions(id, exceptToken: _bearer(request));
    }
    _audit(admin, 'hat das Passwort von ${_who(target)} zurückgesetzt');
    return _json({'ok': true, 'signedOut': signedOut});
  }

  Response _adminSignOut(Request request, String id, [String? sid]) {
    final admin = _admin(request);
    final count = accounts.deleteSessions(
      id,
      sessionId: sid,
      // "Sign out everywhere" on yourself keeps this device signed in.
      exceptToken: sid == null ? _bearer(request) : null,
    );
    _audit(
      admin,
      'hat ${_who(accounts.byId(id))} auf $count Gerät(en) '
      'abgemeldet',
    );
    return _json({'ok': true, 'signedOut': count});
  }

  /// Settings every app needs, e.g. where map tiles come from.
  Response _config(Request request) {
    _auth(request);
    return _json({
      'mapTileUrl': settings.effective.mapTileUrl,
      'mapProvider': settings.effective.mapProvider?.wire,
      'hiddenModules': settings.effective.hiddenModules ?? const [],
      'holidayRegion': settings.effective.holidayRegion,
    });
  }

  Response _members(Request request) {
    _auth(request);
    return _json({
      'members': [for (final m in accounts.members()) m.toJson()],
    });
  }

  Future<Response> _createMember(Request request) async {
    final admin = _admin(request);
    final body = await _body(request);
    final member = accounts.create(
      username: body['username'] as String? ?? '',
      displayName: body['displayName'] as String? ?? '',
      passwordHash: await accounts.hashPassword(
        body['password'] as String? ?? '',
      ),
      isAdmin: body['isAdmin'] as bool? ?? false,
      role: MemberRole.parse(body['role']),
    );
    _audit(
      admin,
      'hat ${_who(member)} angelegt'
      '${member.isAdmin ? ' (Administrator)' : ''}',
    );
    hub.notifyMembersChanged();
    // Calendars shared with the whole family but hidden for someone need
    // the newcomer in their audience.
    if (calendarAccess?.reapply() ?? false) hub.notifyRev(records.currentRev);
    return _json(member.toJson(), status: 201);
  }

  Response _deleteMember(Request request, String id) {
    final admin = _admin(request);
    if (id == admin.id) {
      throw ApiException.badRequest(
        'self_delete',
        'Du kannst dich nicht selbst löschen',
      );
    }
    final target = accounts.byId(id);
    accounts.delete(id);
    locations?.memberDeleted(id);
    if (target != null) _audit(admin, 'hat ${_who(target)} entfernt');
    hub.notifyMembersChanged();
    if (calendarAccess?.reapply() ?? false) hub.notifyRev(records.currentRev);
    return _json({'ok': true});
  }
}
