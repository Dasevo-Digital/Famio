import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import 'package:timezone/timezone.dart' as tz;

import 'accounts.dart';
import 'api_exception.dart';
import 'calendar/calendar_feeds.dart';
import 'calendar/calendar_importer.dart';
import 'calendar/ics_export.dart';
import 'crypto/tls.dart';
import 'dav/apple_profile.dart';
import 'calendar/calendar_access.dart';
import 'dav/caldav_server.dart';
import 'dav/caldav_sync.dart';
import 'dav/dav_client.dart';
import 'dav/google_oauth.dart';
import 'files/file_store.dart';
import 'security.dart';
import 'settings.dart';
import 'hub.dart';
import 'landing_page.dart';
import 'location/location_service.dart';
import 'push/push_service.dart';
import 'record_store.dart';

const serverVersion = '0.14.1';

/// Marks a field that the request leaves as it is.
const Object _unchanged = Accounts.keep;

/// The Home Assistant supervisor's ingress proxy address.
const _ingressProxy = '172.30.32.2';

/// Builds the HTTP handler for the whole server.
class FamioApi {
  FamioApi({
    required this.accounts,
    required this.records,
    required this.hub,
    required this.feeds,
    required this.files,
    this.clientAddress = const ClientAddress(trustProxy: false),
    LoginThrottle? throttle,
    this.setupCode,
    this.importer,
    required this.settings,
    this.ingressAuth = false,
    this.trustProxy = false,
    this.dbSize,
    this.compactDatabase,
    this.auditLog,
    this.requireTls = false,
    this.tlsPort,
    this.tls,
    this.encryptedAtRest = false,
    this.keySeparate = false,
    this.onEventsChanged,
    this.caldav,
    this.calendarAccess,
    this.locations,
    this.push,
  }) : throttle = throttle ?? LoginThrottle();

  final Accounts accounts;
  final RecordStore records;
  final ChangeHub hub;
  final CalendarFeeds feeds;
  final FileStore files;
  final ClientAddress clientAddress;
  final LoginThrottle throttle;

  /// Required to create the first account unless the request comes directly
  /// from the local network (not through a proxy).
  final String? setupCode;
  final CalendarImporter? importer;

  /// Runtime settings (public URL, time zone, upload limit).
  final SettingsStore settings;
  final bool ingressAuth;
  final bool trustProxy;

  /// Refuse unencrypted API access unless it comes through a TLS proxy,
  /// Home Assistant ingress or from this machine.
  final bool requireTls;
  final int? tlsPort;

  /// The server's own HTTPS certificate (null without HTTPS port).
  final ServerTls? tls;
  String? get tlsFingerprint => tls?.fingerprint;
  final bool encryptedAtRest;
  final bool keySeparate;

  /// Push notifications through ntfy; null in some tests.
  final PushService? push;

  /// Location sharing of the members' phones.
  final LocationService? locations;

  /// Two-way sync with other CalDAV servers; null in some tests.
  final CalDavSync? caldav;

  /// Calendar sharing and the admins' calendar profiles.
  final CalendarAccess? calendarAccess;

  /// Called when events changed, e.g. to push them to other calendars.
  final void Function()? onEventsChanged;

  /// Receives security relevant admin actions (who did what), e.g. to
  /// print them to the server log.
  final void Function(String line)? auditLog;

  /// Size of the database file in bytes.
  final int Function()? dbSize;

  /// Rewrites the database file without deleted content.
  final void Function()? compactDatabase;
  final _startedAt = DateTime.now();

  /// The family's time zone (calendar feeds, floating imported times).
  tz.Location get location => settings.location;
  String? get publicUrl => settings.publicUrl;

  Handler get handler {
    final router = Router()
      ..get('/', _landing)
      ..get('/api/health', _health)
      ..post('/api/auth/setup', _setup)
      ..post('/api/auth/login', _login)
      ..post('/api/auth/logout', _logout)
      ..get('/api/me', _me)
      ..patch('/api/me', _updateMe)
      ..put('/api/me/password', _changePassword)
      ..get('/api/me/sessions', _mySessions)
      ..delete('/api/me/sessions/<sid>', _deleteMySession)
      ..get('/api/me/app-passwords', _appPasswords)
      ..post('/api/me/app-passwords', _createAppPassword)
      ..delete('/api/me/app-passwords/<id>', _deleteAppPassword)
      ..post('/api/me/apple-profile', _appleProfile)
      ..get('/api/me/push', _pushTargets)
      ..post('/api/me/push', _addPushTarget)
      ..delete('/api/me/push/<id>', _deletePushTarget)
      ..post('/api/me/push/<id>/test', _testPushTarget)
      ..get('/api/config', _config)
      ..get('/api/members', _members)
      ..post('/api/members', _createMember)
      ..delete('/api/members/<id>', _deleteMember)
      ..get('/api/admin/overview', _adminOverview)
      ..patch('/api/admin/settings', _adminSettings)
      ..post('/api/admin/settings/reset', _adminResetSettings)
      ..post('/api/admin/wipe', _adminWipe)
      ..get('/api/admin/users', _adminUsers)
      ..post('/api/admin/users', _createMember)
      ..patch('/api/admin/users/<id>', _adminUpdateUser)
      ..put('/api/admin/users/<id>/password', _adminResetPassword)
      ..delete('/api/admin/users/<id>', _deleteMember)
      ..delete('/api/admin/users/<id>/sessions', _adminSignOut)
      ..get('/api/admin/users/<id>/calendars', _adminMemberCalendars)
      ..put('/api/admin/users/<id>/calendars', _adminSetMemberCalendars)
      ..delete('/api/admin/users/<id>/sessions/<sid>', _adminSignOut)
      ..post('/api/sync', _sync)
      ..post('/api/location/report', _locationReport)
      ..post('/api/location/device-token', _locationDeviceToken)
      ..post('/api/location/pause', _locationPause)
      ..post('/api/location/resume', _locationResume)
      ..get('/api/location/history', _locationHistory)
      ..put('/api/admin/location-code', _adminLocationCode)
      ..get('/api/calendar/feeds', _listFeeds)
      ..post('/api/calendar/feeds', _createFeed)
      ..delete('/api/calendar/feeds/<id>', _deleteFeed)
      ..post('/api/calendar/subscriptions/<id>/refresh', _refreshSubscription)
      ..post('/api/calendar/caldav/discover', _caldavDiscover)
      ..post('/api/calendar/google/connect', _googleConnect)
      ..get('/api/calendar/caldav', _caldavAccounts)
      ..post('/api/calendar/caldav', _caldavCreate)
      ..patch('/api/calendar/caldav/<id>', _caldavUpdate)
      ..delete('/api/calendar/caldav/<id>', _caldavDelete)
      ..post('/api/calendar/caldav/<id>/sync', _caldavSync)
      ..get('/api/calendar/occurrences', _occurrences)
      ..get('/ical/<file>', _icalFeed)
      ..get('/api/ws', _ws)
      ..post('/api/files', _upload)
      ..get('/api/files/<id>', _download);

    final dav = CalDavServer(
      accounts: accounts,
      records: records,
      location: () => location,
      throttle: throttle,
      clientAddress: clientAddress,
      onChanged: _eventsChanged,
    );
    return const Pipeline()
        .addMiddleware(_securityHeaders)
        .addMiddleware(_errors)
        .addMiddleware(_tlsGuard)
        .addHandler(
          (request) => CalDavServer.handles(request)
              ? dav.handle(request)
              : router.call(request),
        );
  }

  /// Events changed outside of `/api/sync` (e.g. by a calendar app).
  void _eventsChanged() {
    hub.notifyRev(records.currentRev);
    onEventsChanged?.call();
  }

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
      throw ApiException(400, 'invalid_url', 'Ungültige Serveradresse');
    }
    final own = base.scheme == 'http' || base.port == tlsPort;
    final tls = this.tls;
    if (own && (tls == null || tlsPort == null)) {
      throw ApiException(
        400,
        'no_tls',
        'Apple Kalender braucht HTTPS: den HTTPS-Port des Servers '
            '(FAMIO_TLS_PORT) einschalten oder die Adresse über den '
            'Reverse-Proxy verwenden.',
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
          : 'Apple Kalender',
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
    final target = _push.add(
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

  Response _health(Request request) => _json({
    'name': 'famio',
    'version': serverVersion,
    'setupRequired': !accounts.hasUsers,
    'setupCodeRequired':
        !accounts.hasUsers && !clientAddress.isLocalDirect(request),
  });

  Future<Response> _setup(Request request) async {
    if (accounts.hasUsers) {
      throw ApiException(
        409,
        'already_set_up',
        'Server ist bereits eingerichtet',
      );
    }
    final body = await _body(request);
    if (!clientAddress.isLocalDirect(request)) {
      final address = clientAddress.of(request);
      _checkThrottle(address, '#setup');
      final given = (body['setupCode'] as String? ?? '').trim().toUpperCase();
      if (setupCode == null || !_constantTimeEquals(given, setupCode!)) {
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
    return _session(member, body['device'] as String?);
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
    return _session(member, body['device'] as String?);
  }

  Response _logout(Request request) {
    final token = _bearer(request);
    if (token != null) accounts.deleteSession(token);
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
    _audit(admin, 'hat die Servereinstellungen auf Standard zurückgesetzt');
    if (location.name != zone) importer?.subscriptionsChanged();
    return _json(_overview().toJson());
  }

  /// Word an admin types to confirm [_adminWipe].
  static const wipeConfirmation = 'LÖSCHEN';

  /// Deletes all of the family's data: every record (calendar, chat, lists,
  /// documents …), uploaded files, positions, calendar connections and
  /// feed links. Accounts stay, unless `removeMembers` also removes
  /// everybody but the admin. Needs the admin's password (if they have one)
  /// and [wipeConfirmation].
  Future<Response> _adminWipe(Request request) async {
    final admin = _admin(request);
    final body = await _body(request);
    if (body['confirm'] != wipeConfirmation) {
      throw ApiException.badRequest(
        'confirmation_required',
        'Zur Bestätigung „$wipeConfirmation“ eingeben',
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
    );
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
        'Aktuelles Passwort falsch',
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

  /// Settings every app needs, e.g. where map tiles come from.
  Response _config(Request request) {
    _auth(request);
    return _json({'mapTileUrl': settings.effective.mapTileUrl});
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

  Future<Response> _sync(Request request) async {
    final member = _auth(request);
    final syncRequest = SyncRequest.fromJson(await _body(request));
    final before = records.currentRev;
    final response = records.sync(syncRequest, member.id);
    final after = records.currentRev;
    if (after != before) hub.notifyRev(after);
    if (syncRequest.changes.any(
      (c) => c.collection == Collections.calendarSubscriptions,
    )) {
      importer?.subscriptionsChanged();
    }
    if (syncRequest.changes.any((c) => c.collection == Collections.events)) {
      onEventsChanged?.call();
    }
    return _json(response.toJson());
  }

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
      throw ApiException.badRequest('invalid_scope', 'Unbekannter Umfang');
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
      throw ApiException(404, 'not_found', 'Abo nicht gefunden');
    }
    return _json({...status.toData(), 'id': status.id});
  }

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

  static const _locationScope = 'location';

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
    final from =
        DateTime.tryParse(query['from'] ?? '') ??
        now.subtract(const Duration(days: 1));
    final to = DateTime.tryParse(query['to'] ?? '') ?? now;
    return _json({
      'points': [
        for (final f in _locations.history(target, from: from, to: to))
          f.toJson(),
      ],
    });
  }

  Future<Response> _adminLocationCode(Request request) async {
    final admin = _admin(request);
    final body = await _body(request);
    await _locations.setCode(body['code'] as String?);
    _audit(admin, 'hat den Eltern-Code für den Standort geändert');
    return _json({'ok': true, 'codeSet': _locations.codeSet});
  }

  CalDavSync get _caldav =>
      caldav ??
      (throw ApiException(404, 'not_found', 'CalDAV nicht verfügbar'));

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
        'Google-Anmeldung abgelaufen – bitte erneut anmelden',
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
      calendarName: body['calendarName'] as String? ?? 'Kalender',
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
      throw ApiException(404, 'not_found', 'Mitglied nicht gefunden');
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
        'Zeitraum angeben (from, to; höchstens 400 Tage)',
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
                        ? 'Verbundener Kalender'
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
    if (found == null) return Response.notFound('Unbekannter Kalender');
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

  Future<Response> _upload(Request request) async {
    final member = _auth(request);
    final length = request.contentLength;
    if (length != null && length > files.maxBytes) {
      throw ApiException(
        413,
        'too_large',
        'Datei ist größer als ${files.maxBytes ~/ (1024 * 1024)} MB',
      );
    }
    final name = request.url.queryParameters['name'] ?? 'datei';
    final mime =
        request.headers['content-type']?.split(';').first.trim() ??
        'application/octet-stream';
    final file = await files.save(
      owner: member.id,
      name: name,
      mime: mime.isEmpty ? 'application/octet-stream' : mime,
      body: request.read(),
    );
    return _json(file.toJson(), status: 201);
  }

  Future<Response> _download(Request request, String id) async {
    final member = _auth(request);
    final file = files.get(id);
    // Same answer for "missing" and "forbidden": ids reveal nothing.
    if (file == null || !files.mayRead(file, member.id)) {
      throw ApiException(404, 'not_found', 'Datei nicht gefunden');
    }
    final thumb = int.tryParse(request.url.queryParameters['thumb'] ?? '');
    final Stream<List<int>> body;
    final int length;
    if (thumb == null) {
      body = files.read(file);
      length = file.size;
    } else {
      final jpeg = await files.thumbnail(file, thumb);
      if (jpeg == null) {
        throw ApiException(404, 'not_found', 'Keine Vorschau verfügbar');
      }
      body = Stream.value(jpeg);
      length = jpeg.length;
    }
    return Response.ok(
      body,
      headers: {
        ..._fileHeaders(file.name, thumb == null ? file.mime : 'image/jpeg'),
        'content-length': '$length',
        // Files never change; a new upload gets a new id.
        'cache-control': 'private, max-age=31536000, immutable',
      },
    );
  }

  FutureOr<Response> _ws(Request request) {
    _auth(request);
    return webSocketHandler((channel, _) {
      hub.add(channel, rev: records.currentRev);
    }, pingInterval: const Duration(seconds: 30))(request);
  }

  Response _landing(Request request) {
    final member = _ingressMember(request);
    return Response.ok(
      landingPage(
        member: member,
        hasPassword: member != null && accounts.hasPassword(member.id),
        host: request.headers['host']?.split(':').first,
        version: serverVersion,
      ),
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }

  // --- helpers -------------------------------------------------------------

  void _checkThrottle(String address, String key) {
    final wait = throttle.blockedFor(address, key);
    if (wait != null) {
      throw ApiException(
        429,
        'too_many_attempts',
        'Zu viele Fehlversuche. Bitte in '
            '${(wait.inSeconds / 60).ceil()} Minute(n) erneut versuchen.',
      );
    }
  }

  void _audit(FamilyMember actor, String action) =>
      auditLog?.call('[audit] ${_who(actor)} $action');

  static String _who(FamilyMember? m) =>
      m == null ? 'unbekannt' : '@${m.username}';

  Response _session(FamilyMember member, String? device) {
    final token = accounts.createSession(member.id, device: device);
    return _json({'token': token, 'member': member.toJson()});
  }

  FamilyMember _auth(Request request) {
    final member = _ingressMember(request) ?? _tokenMember(request);
    if (member == null) {
      throw ApiException(401, 'unauthorized', 'Nicht angemeldet');
    }
    return member;
  }

  /// Guests have no locations, calendar accounts or pocket money.
  FamilyMember _member(Request request) {
    final member = _auth(request);
    if (member.isGuest) {
      throw ApiException(403, 'forbidden', 'Für Gäste nicht verfügbar');
    }
    return member;
  }

  FamilyMember _admin(Request request) {
    final member = _auth(request);
    if (!member.isAdmin) {
      throw ApiException(403, 'forbidden', 'Nur für Administratoren');
    }
    return member;
  }

  FamilyMember? _tokenMember(Request request) {
    // Tokens only in the Authorization header: URLs end up in proxy logs.
    final token = _bearer(request);
    return token == null ? null : accounts.userForToken(token);
  }

  /// Home Assistant ingress passes the logged-in HA user as headers. They are
  /// only trusted when the request really comes from the supervisor proxy.
  FamilyMember? _ingressMember(Request request) {
    if (!ingressAuth) return null;
    final info =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    if (info?.remoteAddress.address != _ingressProxy) return null;
    final haId = request.headers['x-remote-user-id'];
    if (haId == null || haId.isEmpty) return null;
    final member = accounts.fromHomeAssistant(
      haUserId: haId,
      haUsername: request.headers['x-remote-user-name'] ?? '',
      displayName: request.headers['x-remote-user-display-name'] ?? '',
    );
    return member;
  }

  static bool _constantTimeEquals(String a, String b) {
    var diff = a.length ^ b.length;
    for (var i = 0; i < a.length && i < b.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String? _bearer(Request request) {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) return null;
    return header.substring(7).trim();
  }

  /// Upload types a browser may display inline. Anything else (HTML, SVG,
  /// scripts …) is served as an opaque download, so an uploaded file can
  /// never run code in the server's origin – which, behind Home Assistant
  /// ingress, is Home Assistant's origin.
  static const _inlineTypes = {
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/heic',
  };

  static Map<String, String> _fileHeaders(String name, String mime) {
    final inline = _inlineTypes.contains(mime.toLowerCase());
    return {
      'content-type': inline ? mime : 'application/octet-stream',
      'content-disposition':
          "${inline ? 'inline' : 'attachment'}; "
          "filename*=UTF-8''${Uri.encodeComponent(name)}",
      'content-security-policy': "default-src 'none'; sandbox",
    };
  }

  /// JSON bodies above this size are refused (sync batches stay far below).
  static const maxJsonBytes = 16 * 1024 * 1024;

  static Future<Map<String, Object?>> _body(Request request) async {
    // Requiring the JSON type forces a CORS preflight for cross-site
    // requests, which fails: no other website can post to Famio in the name
    // of a member signed in through Home Assistant (CSRF).
    final type = request.headers['content-type']?.split(';').first.trim();
    if (type?.toLowerCase() != 'application/json') {
      throw ApiException(
        415,
        'json_required',
        'Content-Type application/json erwartet',
      );
    }
    final length = request.contentLength;
    if (length != null && length > maxJsonBytes) {
      throw ApiException(413, 'too_large', 'Anfrage ist zu groß');
    }
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > maxJsonBytes) {
        throw ApiException(413, 'too_large', 'Anfrage ist zu groß');
      }
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) return decoded.cast();
    } on FormatException {
      // Fall through.
    }
    throw ApiException.badRequest('invalid_json', 'Ungültiger JSON-Body');
  }

  static Response _json(Object body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );

  /// Whether the request reached Famio encrypted (directly or via proxy).
  bool _encrypted(Request request) =>
      request.requestedUri.scheme == 'https' ||
      (trustProxy &&
          request.headers['x-forwarded-proto']?.toLowerCase() == 'https');

  Handler _tlsGuard(Handler inner) => (request) {
    final path = request.url.path;
    if (requireTls &&
        (path.startsWith('api/') || CalDavServer.handles(request)) &&
        path != 'api/health' &&
        !_encrypted(request)) {
      final peer =
          (request.context['shelf.io.connection_info'] as HttpConnectionInfo?)
              ?.remoteAddress;
      final trusted =
          peer != null &&
          (peer.isLoopback || (ingressAuth && peer.address == _ingressProxy));
      if (!trusted) {
        throw ApiException(
          403,
          'tls_required',
          'Dieser Server erlaubt nur verschlüsselte Verbindungen. Bitte die '
              'https-Adresse verwenden'
              '${tlsPort == null ? '' : ' (im Heimnetz Port $tlsPort)'}.',
        );
      }
    }
    return inner(request);
  };

  Handler _securityHeaders(Handler inner) => (request) async {
    final response = await inner(request);
    final path = request.url.path;
    final https = _encrypted(request);
    return response.change(
      headers: {
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        // Health data must not linger in proxy or browser caches.
        if ((path.startsWith('api/') && !path.startsWith('api/files/')) ||
            path.startsWith('dav'))
          'cache-control': 'no-store',
        if (path.startsWith('ical/')) 'cache-control': 'no-store, private',
        if (path.isEmpty) ...{
          // Only Home Assistant (same origin through ingress) may embed it.
          'content-security-policy':
              "default-src 'self'; style-src 'self' 'unsafe-inline'; "
              "script-src 'self' 'unsafe-inline'; frame-ancestors 'self'",
        },
        if (https) 'strict-transport-security': 'max-age=31536000',
      },
    );
  };

  static Handler _errors(Handler inner) => (request) async {
    try {
      return await inner(request);
    } on ApiException catch (e) {
      return _json({'error': e.code, 'message': e.message}, status: e.status);
    } on FormatException catch (e) {
      return _json({'error': 'bad_request', 'message': e.message}, status: 400);
    } on TypeError catch (e) {
      return _json({'error': 'bad_request', 'message': '$e'}, status: 400);
    }
  };
}
