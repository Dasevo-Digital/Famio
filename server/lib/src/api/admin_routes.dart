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
      outdatedApps: _outdatedApps(),
    );
  }

  /// Devices used in the last three months whose app is older than this
  /// server, for "Apps älter als der Server" in the status.
  List<({String member, String device, String version})> _outdatedApps() {
    final since = DateTime.now().subtract(const Duration(days: 90));
    return [
      for (final u in accounts.adminUsers(serverVersion: serverVersion))
        for (final s in u.sessions)
          if (s.outdated && s.lastSeen.isAfter(since))
            (
              member: u.member.displayName,
              device: s.device ?? '',
              version: s.appVersionNumber ?? '',
            ),
    ];
  }

  /// What an admin should still set up, with where to do it.
  Future<Response> _setupChecklist(Request request) async {
    final admin = _admin(request);
    final s = settings.effective;
    final steps = <SetupStep>[];

    final url = s.publicUrl;
    if (url == null || url.isEmpty) {
      steps.add(
        SetupStep(
          id: 'address',
          title: t('Öffentliche Adresse'),
          done: false,
          detail: t(
            'Nicht eingetragen: Die Apps erreichen Famio nur im Heimnetz, und Google oder iCloud können Famio-Kalender nicht abonnieren.',
          ),
          where: t('Server-Verwaltung → Einstellungen → Öffentliche Adresse'),
        ),
      );
    } else {
      final reachable = await _reachesItself(url);
      steps.add(
        SetupStep(
          id: 'address',
          title: t('Öffentliche Adresse'),
          done: reachable,
          url: url,
          detail: reachable
              ? t('{url} ist über HTTPS erreichbar.', {'url': url})
              : await _pointsToItself(url)
              // E.g. a Proxmox container named like the address: its
              // /etc/hosts sends the request to itself, not to the proxy.
              ? t(
                  '{url} führt auf diesem Rechner zu ihm selbst statt zum Reverse-Proxy (meist, weil Container oder Rechner so heißen, siehe /etc/hosts). Von außen kann die Adresse trotzdem funktionieren – die App prüft sie dann von deinem Gerät aus.',
                  {'url': url},
                )
              : t(
                  '{url} antwortet dem Server nicht. Reverse-Proxy, DNS und Zertifikat prüfen (im Heimnetz kann es auch am Router liegen, der Anfragen an sich selbst nicht zurückleitet).',
                  {'url': url},
                ),
          where: t('Reverse-Proxy (z. B. Nginx Proxy Manager)'),
        ),
      );
    }

    final https = requireTls && (trustProxy || ingressAuth || tlsPort != null);
    steps.add(
      SetupStep(
        id: 'https',
        title: t('Nur verschlüsselt'),
        done: https,
        detail: https
            ? t('Anmeldung und Daten gehen nur über HTTPS.')
            : t(
                'Klartext aus dem Netz ist erlaubt (FAMIO_REQUIRE_TLS=false). Nur kurz für alte Apps nutzen.',
              ),
        where: t('FAMIO_REQUIRE_TLS in der Server-Konfiguration'),
      ),
    );

    final keyOk = encryptedAtRest && keySeparate;
    steps.add(
      SetupStep(
        id: 'key',
        title: t('Schlüssel getrennt von den Daten'),
        done: keyOk,
        detail: keyOk
            ? t(
                'Datenbank und Dateien sind verschlüsselt, der Schlüssel liegt woanders. Die Schlüsseldatei separat sichern!',
              )
            : encryptedAtRest
            ? t(
                'Der Schlüssel liegt im Datenordner: Wer eine Sicherung hat, hat auch den Schlüssel. FAMIO_KEY_FILE auf einen anderen Ort setzen.',
              )
            : t('Die Daten sind nicht verschlüsselt.'),
        where: t('FAMIO_KEY_FILE in der Server-Konfiguration'),
      ),
    );

    final family = [
      for (final m in accounts.members())
        if (!m.isService) m,
    ];
    steps.add(
      SetupStep(
        id: 'members',
        title: t('Familie eingeladen'),
        done: family.length > 1,
        detail: family.length > 1
            ? t('{count} Mitglieder.', {'count': family.length})
            : t('Bisher nur du. Lade die Familie per QR-Code oder Link ein.'),
        where: t('Server-Verwaltung → Benutzer → Mitglied hinzufügen'),
      ),
    );

    final twoFactor = mfa.hasTotp(admin.id);
    steps.add(
      SetupStep(
        id: 'twoFactor',
        title: t('Zwei-Faktor für dich'),
        done: twoFactor,
        detail: twoFactor
            ? t('Dein Admin-Konto ist mit einem zweiten Faktor geschützt.')
            : t(
                'Admins sollten einen zweiten Faktor (Authenticator-App) einrichten.',
              ),
        where: t('Einstellungen → Anmeldung & Sicherheit'),
      ),
    );

    if (push case final p?) {
      final now = DateTime.now();
      // Only who uses a Famio app can be reached; a child without a phone
      // is no gap to close.
      final devices = accounts.appDevices();
      bool usesApp(FamilyMember m) => devices[m.id]?.isNotEmpty ?? false;
      final noApp = [
        for (final m in family)
          if (!usesApp(m)) m.displayName,
      ];
      final reach = p.reachability([
        for (final m in family)
          if (usesApp(m)) m.id,
      ], noticeScope: _noticeScope);
      final missing = [
        for (final m in family)
          if (reach[m.id] case final r?
              when r.ntfy == 0 &&
                  (r.ownPush == null ||
                      now.difference(r.ownPush!) > const Duration(days: 2)))
            m,
      ];
      // Famio's own notifications reach an iPhone in the background only
      // through Apple's push service (paid developer account); until then
      // ntfy does.
      final iPhones = [
        for (final m in missing)
          if (devices[m.id]!.every((d) => d.startsWith('ios'))) m.displayName,
      ];
      steps.add(
        SetupStep(
          id: 'push',
          title: t('Benachrichtigungen erreichen alle'),
          done: missing.isEmpty,
          detail: [
            if (missing.isEmpty)
              t(
                'Jedes Mitglied mit Famio-App bekommt Alarme und Erinnerungen aufs Handy.',
              )
            else
              t(
                'Noch nicht erreichbar: {names}. In deren App die Benachrichtigungen einschalten (Famio-eigene oder ntfy).',
                {'names': missing.map((m) => m.displayName).join(', ')},
              ),
            if (iPhones.isNotEmpty)
              t(
                'Auf dem iPhone ({names}) geht das vorerst nur mit der ntfy-App.',
                {'names': iPhones.join(', ')},
              ),
            if (noApp.isNotEmpty)
              t('Ohne Famio-App: {names}.', {'names': noApp.join(', ')}),
          ].join(' '),
          where: t(
            'Einstellungen → Benachrichtigungen (in der jeweiligen App)',
          ),
        ),
      );
    }

    final job = backups;
    if (job == null) {
      steps.add(
        SetupStep(
          id: 'backup',
          title: 'Sicherung',
          done: false,
          detail: t(
            'Die eingebaute Sicherung ist aus (FAMIO_BACKUP_DIR=off). Dann muss Proxmox, Home Assistant oder ein anderes Werkzeug das Datenverzeichnis sichern.',
          ),
          where: t('FAMIO_BACKUP_DIR in der Server-Konfiguration'),
        ),
      );
    } else {
      final newest = job.list().firstOrNull;
      final check = newest?.check;
      final fresh =
          newest != null &&
          DateTime.now().difference(newest.at) < BackupJob.freshFor;
      final ok = fresh && (check?.ok ?? false);
      steps.add(
        SetupStep(
          id: 'backup',
          title: 'Sicherung',
          done: ok,
          detail: ok
              ? t(
                  'Die letzte nächtliche Sicherung ist geprüft und lässt sich wiederherstellen. Für den Ernstfall eine Kopie außer Haus aufbewahren.',
                )
              : newest == null
              ? t(
                  'Noch keine Sicherung – die erste entsteht heute Nacht um 3 Uhr oder mit „Jetzt sichern“.',
                )
              : !fresh
              ? t(
                  'Die letzte Sicherung ist älter als einen Tag. Fehler: {error}.',
                  {'error': job.lastError ?? t('keiner gemeldet')},
                )
              : t(
                  'Die letzte Sicherung ist noch nicht oder nicht erfolgreich geprüft.',
                ),
          where: t('Server-Verwaltung → Status → Sicherungen'),
        ),
      );
    }

    steps.add(
      SetupStep(
        id: 'region',
        title: t('Bundesland für Feiertage'),
        done: s.holidayRegion != null,
        detail: s.holidayRegion != null
            ? t('Feiertage und Schulferien erscheinen im Kalender.')
            : t(
                'Ohne Bundesland zeigt der Kalender keine Feiertage und Schulferien.',
              ),
        where: t('Server-Verwaltung → Einstellungen'),
      ),
    );
    final ignored = settings.ignoredSetupSteps;
    return _json({
      'steps': [
        for (final s in steps)
          (ignored.contains(s.id) ? s.copyWith(ignored: true) : s).toJson(),
      ],
    });
  }

  /// Leaves a setup step as it is, or shows it again.
  Future<Response> _ignoreSetupStep(Request request) async {
    final admin = _admin(request);
    final body = await _body(request);
    final id = body['id'];
    if (id is! String || !RegExp(r'^[A-Za-z][A-Za-z_-]{0,39}$').hasMatch(id)) {
      throw ApiException.badRequest('invalid_step', t('Unbekannter Punkt'));
    }
    final ignored = body['ignored'] == true;
    settings.ignoreSetupStep(id, ignored: ignored);
    _audit(
      admin,
      ignored
          ? 'hat den Einrichtungspunkt „$id“ ignoriert'
          : 'zeigt den Einrichtungspunkt „$id“ wieder an',
    );
    return _json({'ok': true});
  }

  /// Whether [url]'s host resolves to this machine itself.
  Future<bool> _pointsToItself(String url) async {
    try {
      final host = Uri.parse(url).host;
      final addresses = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 3));
      final own = {
        for (final i in await NetworkInterface.list(includeLoopback: true))
          for (final a in i.addresses) a.address,
      };
      return addresses.any((a) => a.isLoopback || own.contains(a.address));
    } catch (_) {
      return false;
    }
  }

  /// Whether `<url>/api/health` answers as Famio within a few seconds.
  Future<bool> _reachesItself(String url) async {
    final client = selfCheckClient;
    if (client == null) return false;
    try {
      final base = Uri.parse(url.endsWith('/') ? url : '$url/');
      final response = await client
          .get(base.resolve('api/health'))
          .timeout(const Duration(seconds: 6));
      return response.statusCode == 200 &&
          response.body.contains('"name":"famio"');
    } catch (_) {
      return false;
    }
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
        t('Zur Bestätigung „{word}“ eingeben', {
          'word': FamioApi.wipeConfirmation,
        }),
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
      throw ApiException(403, 'invalid_credentials', t('Passwort falsch'));
    }
    throttle.succeeded(address, '#pw:${admin.id}');
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
        for (final u in accounts.adminUsers(
          currentToken: _bearer(request),
          serverVersion: serverVersion,
        ))
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
      throw ApiException(404, 'not_found', t('Mitglied nicht gefunden'));
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

  Response _backupStatus(Request request) {
    _admin(request);
    final job = backups;
    return _json(
      job == null ? {'enabled': false} : {'enabled': true, ...job.status()},
    );
  }

  Future<Response> _backupNow(Request request) async {
    final admin = _admin(request);
    final job = backups;
    if (job == null) {
      throw ApiException.badRequest(
        'backups_off',
        t('Sicherungen sind ausgeschaltet (FAMIO_BACKUP_DIR=off)'),
      );
    }
    try {
      final backup = await job.run();
      _audit(admin, 'hat eine Sicherung erstellt');
      return _json(backup.toJson(), status: 201);
    } on StateError catch (e) {
      throw ApiException(409, 'backup_running', e.message);
    } catch (_) {
      throw ApiException(
        500,
        'backup_failed',
        t('Die Sicherung ist fehlgeschlagen: {error}', {
          'error': job.lastError,
        }),
      );
    }
  }

  /// Tries a backup (the newest without a name) and returns the result.
  Future<Response> _backupCheck(Request request) async {
    final admin = _admin(request);
    final job = backups;
    if (job == null) {
      throw ApiException.badRequest(
        'backups_off',
        t('Sicherungen sind ausgeschaltet (FAMIO_BACKUP_DIR=off)'),
      );
    }
    final name =
        request.url.queryParameters['name'] ?? job.list().firstOrNull?.name;
    if (name == null || job.folder(name) == null) {
      throw ApiException(
        404,
        'backup_not_found',
        t('Keine Sicherung gefunden'),
      );
    }
    final check = await job.verify(name);
    _audit(admin, 'hat die Sicherung $name geprüft');
    return _json(check.toJson());
  }

  Future<Response> _createMember(Request request) async {
    final admin = _admin(request);
    final body = await _body(request);
    final member = accounts.create(
      username: body['username'] as String? ?? '',
      displayName: body['displayName'] as String? ?? '',
      passwordHash: await accounts.hashPassword(
        body['password'] as String? ?? '',
        personal: [
          body['username'] as String? ?? '',
          body['displayName'] as String? ?? '',
        ],
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
        t('Du kannst dich nicht selbst löschen'),
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
