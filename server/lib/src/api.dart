import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

import 'package:timezone/timezone.dart' as tz;

import 'accounts.dart';
import 'api_exception.dart';
import 'auth/mfa.dart';
import 'auth/sso.dart';
import 'auth/totp.dart';
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
import 'family/repeating_tasks.dart';
import 'backup/backup_job.dart';
import 'family/invites.dart';
import 'family/sos.dart';
import 'hub.dart';
import 'export/data_export.dart';
import 'lists/list_sync.dart';
import 'landing_page.dart';
import 'web_app.dart';
import 'location/location_service.dart';
import 'push/notice_box.dart';
import 'push/push_service.dart';
import 'record_store.dart';

part 'api/account_routes.dart';
part 'api/admin_routes.dart';
part 'api/auth_routes.dart';
part 'api/calendar_routes.dart';
part 'api/export_routes.dart';
part 'api/file_routes.dart';
part 'api/list_routes.dart';
part 'api/location_routes.dart';
part 'api/notification_routes.dart';
part 'api/invite_routes.dart';
part 'api/sos_routes.dart';
part 'api/web_routes.dart';

const serverVersion = '1.0.10';

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
    this.lists,
    this.exports,
    this.calendarAccess,
    this.locations,
    this.push,
    this.notices,
    this.sos,
    this.invites,
    this.backups,
    required this.mfa,
    this.sso,
    this.webApp,
  }) : throttle = throttle ?? LoginThrottle();

  /// The web app below `/app/` (also the Home Assistant sidebar); null
  /// if the server was built without it.
  final WebApp? webApp;

  /// Two-factor login with an authenticator app.
  final Mfa mfa;

  /// Sign-in with an OpenID Connect provider; null in some tests.
  final SsoService? sso;

  /// Logins waiting for the second factor: challenge → user, device.
  final _challenges =
      <
        String,
        ({String userId, String? device, DateTime expires, int tries})
      >{};

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

  /// Famio's own push notifications; null in some tests.
  final NoticeBox? notices;

  /// The emergency button; null in some tests.
  final SosService? sos;

  /// Invitations for new members; null in some tests.
  final Invites? invites;

  /// Nightly backups; null when switched off.
  final BackupJob? backups;

  /// Location sharing of the members' phones.
  final LocationService? locations;

  /// Two-way sync with other CalDAV servers; null in some tests.
  final CalDavSync? caldav;

  /// Connections to Bring! and Microsoft To Do; null in some tests.
  final ListSync? lists;

  /// Data exports; null in some tests.
  final DataExport? exports;

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
      ..get('/delete-account', _deleteAccountPage)
      ..get('/.well-known/security.txt', _securityTxt)
      ..get('/app', (Request _) => Response.found('app/'))
      ..get('/app/<path|.*>', _webApp)
      ..get('/api/panel', _panel)
      ..get('/api/health', _health)
      ..post('/api/auth/setup', _setup)
      ..post('/api/auth/login', _login)
      ..post('/api/auth/login/two-factor', _loginTwoFactor)
      ..post('/api/auth/sso/start', _ssoStart)
      ..get('/api/auth/sso/callback', _ssoCallback)
      ..post('/api/auth/sso/poll', _ssoPoll)
      ..post('/api/auth/logout', _logout)
      ..get('/api/me/two-factor', _twoFactorStatus)
      ..post('/api/me/two-factor/totp', _totpBegin)
      ..post('/api/me/two-factor/totp/confirm', _totpConfirm)
      ..post('/api/me/two-factor/totp/disable', _totpDisable)
      ..post('/api/me/two-factor/recovery-codes', _recoveryCodes)
      ..post('/api/me/two-factor/verify', _twoFactorVerify)
      ..delete('/api/me/sso', _ssoUnlinkMe)
      ..get('/api/me', _me)
      ..patch('/api/me', _updateMe)
      ..delete('/api/me', _deleteMe)
      ..put('/api/me/password', _changePassword)
      ..post('/api/me/export', _exportMine)
      ..post('/api/admin/export', _exportFamily)
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
      ..get('/api/members/reachability', _reachability)
      ..get('/api/me/quiet-hours', _quietHours)
      ..put('/api/me/quiet-hours', _setQuietHours)
      ..get('/api/notifications', _notices)
      ..post('/api/notifications/device-token', _noticeDeviceToken)
      ..post('/api/notifications/test', _testNotice)
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
      ..get('/api/admin/backups', _backupStatus)
      ..post('/api/admin/backups', _backupNow)
      ..get('/api/admin/invites', _openInvites)
      ..post('/api/admin/invites', _createInvite)
      ..delete('/api/admin/invites/<id>', _revokeInvite)
      ..post('/api/auth/invite/check', _checkInvite)
      ..post('/api/auth/invite', _redeemInvite)
      ..patch('/api/admin/users/<id>', _adminUpdateUser)
      ..put('/api/admin/users/<id>/password', _adminResetPassword)
      ..delete('/api/admin/users/<id>', _deleteMember)
      ..delete('/api/admin/users/<id>/sessions', _adminSignOut)
      ..get('/api/admin/users/<id>/calendars', _adminMemberCalendars)
      ..put('/api/admin/users/<id>/calendars', _adminSetMemberCalendars)
      ..delete('/api/admin/users/<id>/sessions/<sid>', _adminSignOut)
      ..delete('/api/admin/users/<id>/two-factor', _adminResetTwoFactor)
      ..delete('/api/admin/users/<id>/sso', _adminUnlinkSso)
      ..get('/api/admin/sso', _adminSso)
      ..put('/api/admin/sso', _adminSaveSso)
      ..delete('/api/admin/sso', _adminDeleteSso)
      ..post('/api/sync', _sync)
      ..post('/api/location/report', _locationReport)
      ..post('/api/location/device-token', _locationDeviceToken)
      ..post('/api/location/pause', _locationPause)
      ..post('/api/location/resume', _locationResume)
      ..get('/api/location/history', _locationHistory)
      ..get('/api/location/schedule', _locationSchedule)
      ..put('/api/location/schedule', _locationSetSchedule)
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
      ..get('/api/lists/accounts', _listAccounts)
      ..post('/api/members/<id>/ring', _ring)
      ..post('/api/members/<id>/checkin-request', _requestCheckIn)
      ..post('/api/checkin', _checkIn)
      ..post('/api/sos', _sosRaise)
      ..post('/api/sos/device-token', _sosDeviceToken)
      ..post('/api/sos/<id>/position', _sosPosition)
      ..post('/api/sos/<id>/coming', _sosComing)
      ..post('/api/sos/<id>/resolve', _sosResolve)
      ..post('/api/lists/bring', _listConnectBring)
      ..post('/api/lists/microsoft', _listStartMicrosoft)
      ..post('/api/lists/microsoft/poll', _listPollMicrosoft)
      ..get('/api/lists/accounts/<id>/remote', _listRemoteLists)
      ..put('/api/lists/accounts/<id>/links', _listSetLinks)
      ..post('/api/lists/accounts/<id>/sync', _listSync)
      ..delete('/api/lists/accounts/<id>', _listDisconnect)
      ..get('/ical/<file>', _icalFeed)
      ..get('/api/ws', _ws)
      ..post('/api/ws/ticket', _wsTicket)
      ..post('/api/files', _upload)
      ..get('/api/files/<id>', _download);

    final dav = CalDavServer(
      accounts: accounts,
      records: records,
      location: () => location,
      throttle: throttle,
      clientAddress: clientAddress,
      onChanged: _eventsChanged,
      onRecordsChanged: () {
        hub.notifyRev(records.currentRev);
        lists?.poke();
      },
    );
    return const Pipeline()
        .addMiddleware(_compressJson)
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

  /// Word an admin types to confirm [_adminWipe].
  static const wipeConfirmation = 'LÖSCHEN';

  Future<Response> _sync(Request request) async {
    final member = _auth(request);
    final syncRequest = SyncRequest.fromJson(await _body(request));
    final before = records.currentRev;
    final response = records.sync(syncRequest, member.id);
    advanceRepeatingTasks(records, [
      for (final c in syncRequest.changes)
        if (c.collection == Collections.tasks) c.id,
    ], location: location);
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
    if (syncRequest.changes.any(
      (c) =>
          c.collection == Collections.tasks ||
          c.collection == Collections.shoppingItems,
    )) {
      lists?.poke();
    }
    return _json(response.toJson());
  }

  /// Browsers cannot send the token with a WebSocket: they fetch a ticket
  /// first (valid once, for 30 seconds) and put it into the URL.
  final _wsTickets = <String, ({String token, DateTime expires})>{};

  /// Where to report security problems (RFC 9116). Every server runs the
  /// same software, so reports go privately to the project.
  static const securityContact =
      'https://github.com/Dasevo-Digital/Famio/security/advisories/new';

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

  Response _session(FamilyMember member, String? device, {String? method}) {
    final token = accounts.createSession(
      member.id,
      device: device,
      method: method,
    );
    return _json({'token': token, 'member': member.toJson()});
  }

  /// The signed-in member: Home Assistant ingress or a session token (only
  /// in the Authorization header – URLs end up in proxy logs).
  FamilyMember _auth(Request request, {String? token}) {
    if (_ingressMember(request) case final member?) return member;
    token ??= _bearer(request);
    final member = token == null ? null : accounts.userForToken(token);
    if (member == null) {
      throw ApiException(401, 'unauthorized', 'Nicht angemeldet');
    }
    _checkTwoFactorPolicy(request, member, token!);
    return member;
  }

  void _checkTwoFactorPolicy(
    Request request,
    FamilyMember member,
    String token,
  ) {
    final policy = settings.effective.twoFactorRequired;
    if (policy == null || !policy.appliesTo(member)) return;
    final method = accounts.sessionMethod(token);
    if (method == 'totp' || method == 'sso') return;
    final path = request.url.path;
    if (_twoFactorFree.contains(path) || path.startsWith('api/me/two-factor')) {
      return;
    }
    final enabled = mfa.hasTotp(member.id);
    throw ApiException(
      403,
      enabled ? 'two_factor_required' : 'two_factor_setup_required',
      enabled
          ? 'Bitte mit dem Code aus der Authenticator-App bestätigen.'
          : 'Für dein Konto ist die Zwei-Faktor-Anmeldung Pflicht – bitte in '
                'der App einrichten.',
    );
  }

  String _randomToken() => base64Url
      .encode(List<int>.generate(24, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  /// Guests have no locations, calendar accounts or pocket money; limited
  /// service accounts only look at them.
  FamilyMember _member(Request request) {
    final member = _auth(request);
    if (member.isGuest) {
      throw ApiException(403, 'forbidden', 'Für Gäste nicht verfügbar');
    }
    if (request.method != 'GET') _checkWriter(member);
    return member;
  }

  FamilyMember _admin(Request request) {
    final member = _auth(request);
    if (!member.isAdmin) {
      throw ApiException(403, 'forbidden', 'Nur für Administratoren');
    }
    return member;
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

  /// JSON bodies above this size are refused (sync batches stay far below).
  static const maxJsonBytes = 16 * 1024 * 1024;

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
        // Only Home Assistant (same origin through ingress) may embed it.
        if (response.mimeType == 'text/html')
          'content-security-policy': path == 'app' || path.startsWith('app/')
              ? WebApp.policy
              : landingPagePolicy,
        'permissions-policy': 'camera=(), microphone=(), geolocation=()',
        if (https) 'strict-transport-security': 'max-age=31536000',
      },
    );
  };
}

String _who(FamilyMember? m) => m == null ? 'unbekannt' : '@${m.username}';

/// What a session without second factor may still do when two-factor
/// login is mandatory for its member: set it up, sign out.
const _twoFactorFree = {
  'api/me',
  'api/me/password',
  'api/me/sso',
  'api/auth/logout',
  'api/auth/sso/start',
};

final _random = Random.secure();

/// Service accounts set to "Nur lesen" or "Abhaken und Einkauf" change
/// nothing beyond what sync lets them (see RecordStore.mayWrite).
void _checkWriter(FamilyMember member) {
  if (member.isLimited) {
    throw ApiException(
      403,
      'read_only',
      'Dieses Dienstkonto darf das nicht ändern '
          '(${member.serviceAccess.label})',
    );
  }
}

bool _constantTimeEquals(String a, String b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

String? _bearer(Request request) {
  final header = request.headers['authorization'];
  if (header == null || !header.startsWith('Bearer ')) return null;
  return header.substring(7).trim();
}

/// Upload types a browser may display inline. Anything else (HTML, SVG,
/// scripts …) is served as an opaque download, so an uploaded file can
/// never run code in the server's origin – which, behind Home Assistant
/// ingress, is Home Assistant's origin.
const _inlineTypes = {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/heic',
};

Map<String, String> _fileHeaders(String name, String mime) {
  final inline = _inlineTypes.contains(mime.toLowerCase());
  return {
    'content-type': inline ? mime : 'application/octet-stream',
    'content-disposition':
        "${inline ? 'inline' : 'attachment'}; "
        "filename*=UTF-8''${Uri.encodeComponent(name)}",
    'content-security-policy': "default-src 'none'; sandbox",
  };
}

Future<Map<String, Object?>> _body(Request request) async {
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
  if (length != null && length > FamioApi.maxJsonBytes) {
    throw ApiException(413, 'too_large', 'Anfrage ist zu groß');
  }
  // Bytes, not a List<int> of 8-byte slots: a large sync batch would
  // otherwise take eight times its size in memory.
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in request.read()) {
    bytes.add(chunk);
    if (bytes.length > FamioApi.maxJsonBytes) {
      throw ApiException(413, 'too_large', 'Anfrage ist zu groß');
    }
  }
  try {
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is Map) return decoded.cast();
  } on FormatException {
    // Fall through.
  }
  throw ApiException.badRequest('invalid_json', 'Ungültiger JSON-Body');
}

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

/// Sync answers of a real family are hundreds of KB of JSON; gzip makes
/// them about five times smaller for apps and browsers on the go. Keep the
/// body streaming: buffering it here could temporarily double the memory
/// use for a full sync. Home Assistant's ingress compresses for browsers.
Handler _compressJson(Handler inner) => (request) async {
  final response = await inner(request);
  if (response.mimeType != 'application/json' ||
      response.headers.containsKey('content-encoding') ||
      request.headers.containsKey('x-ingress-path') ||
      !(request.headers['accept-encoding'] ?? '').contains('gzip')) {
    return response;
  }
  // Shelf knows the size of ordinary JSON String bodies without reading the
  // stream. Leave small answers uncompressed without recreating a buffer.
  if (response.contentLength case final length? when length < 1024) {
    return response;
  }
  return response.change(
    body: gzip.encoder.bind(response.read()),
    headers: {
      'content-encoding': 'gzip',
      // Shelf has already calculated the uncompressed String body length.
      // A transformed stream must use chunked transfer instead.
      'content-length': null,
      'vary': 'accept-encoding',
    },
  );
};

Handler _errors(Handler inner) => (request) async {
  try {
    return await inner(request);
  } on ApiException catch (e) {
    return _json({'error': e.code, 'message': e.message}, status: e.status);
  } on FormatException catch (e) {
    return _json({'error': 'bad_request', 'message': e.message}, status: 400);
  } on TypeError {
    // A field of the wrong type; the details describe server internals.
    return _json({
      'error': 'bad_request',
      'message': 'Ungültige Anfrage',
    }, status: 400);
  }
};
