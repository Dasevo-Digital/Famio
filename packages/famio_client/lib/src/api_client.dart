import 'dart:convert';
import 'dart:io';

import 'package:famio_shared/famio_shared.dart';

import 'google_login.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Error returned by the server, or a connection problem ([status] 0).
class ApiError implements Exception {
  const ApiError(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  bool get isUnauthorized => status == 401;
  bool get isNetwork => status == 0;

  @override
  String toString() => message;
}

class ServerInfo {
  const ServerInfo({
    required this.version,
    required this.setupRequired,
    this.setupCodeRequired = false,
    this.singleSignOn,
  });

  final String version;
  final bool setupRequired;

  /// Button text for signing in with the single sign-on provider, if the
  /// server offers it.
  final String? singleSignOn;

  /// The first account can only be created with the code from the server
  /// log (setup through a reverse proxy or the internet).
  final bool setupCodeRequired;
}

/// Protection of the connection to the server.
enum TransportSecurity {
  /// HTTPS.
  encrypted,

  /// Plain HTTP inside the home network (private address or local name).
  localNetwork,

  /// Plain HTTP to an internet address: refused by the app.
  insecure,
}

/// The password was right; the server now asks for the code of the
/// authenticator app (or a recovery code): see [FamioApiClient.loginTwoFactor].
class TwoFactorRequired implements Exception {
  const TwoFactorRequired(this.challenge);

  final String challenge;
}

/// Two-factor and single sign-on state of the signed-in member.
class TwoFactorStatus {
  const TwoFactorStatus({
    required this.enabled,
    required this.recoveryCodesLeft,
    required this.required,
    required this.sessionVerified,
    required this.singleSignOn,
    this.singleSignOnName,
    this.singleSignOnLabel,
  });

  factory TwoFactorStatus.fromJson(Map<String, Object?> json) =>
      TwoFactorStatus(
        enabled: json['twoFactor'] as bool? ?? false,
        recoveryCodesLeft: (json['recoveryCodesLeft'] as num?)?.toInt() ?? 0,
        required: json['required'] as bool? ?? false,
        sessionVerified: json['sessionVerified'] as bool? ?? false,
        singleSignOn: json['singleSignOn'] as bool? ?? false,
        singleSignOnName: json['singleSignOnName'] as String?,
        singleSignOnLabel: json['singleSignOnLabel'] as String?,
      );

  /// Authenticator app set up.
  final bool enabled;
  final int recoveryCodesLeft;

  /// An admin made two-factor login mandatory for this member.
  final bool required;

  /// This device signed in with a second factor (or single sign-on).
  final bool sessionVerified;

  /// Linked to the provider; [singleSignOnName] is the account there.
  final bool singleSignOn;
  final String? singleSignOnName;

  /// The server offers single sign-on under this name.
  final String? singleSignOnLabel;

  /// Must set up two-factor login before using the app.
  bool get setupNeeded => required && !enabled && !sessionVerified;

  /// Must confirm a code on this device before using the app.
  bool get verifyNeeded => required && enabled && !sessionVerified;
}

/// A sign-in in the browser at the single sign-on provider: open [url],
/// then poll with [flow] and [secret].
class SsoFlow {
  const SsoFlow({required this.url, required this.flow, required this.secret});

  final Uri url;
  final String flow;
  final String secret;
}

/// Result of a successful login or first setup.
class LoginResult {
  const LoginResult({required this.token, required this.member});

  final String token;
  final FamilyMember member;
}

/// Thin typed wrapper around the Famio HTTP API.
class FamioApiClient {
  FamioApiClient(
    String baseUrl, {
    this.token,
    this.pinnedCertificate,
    http.Client? httpClient,
  }) : baseUrl = normalizeUrl(baseUrl),
       _http = httpClient ?? IOClient(ioClient(pinnedCertificate));

  final Uri baseUrl;
  String? token;

  /// SHA-256 fingerprint of the key of the server's own certificate,
  /// confirmed by the user on first connect. Only this key is accepted
  /// besides certificates trusted by the system (e.g. Let's Encrypt).
  final String? pinnedCertificate;
  final http.Client _http;

  /// A `dart:io` client that trusts [pin] in addition to the system's CAs;
  /// also used for the WebSocket.
  static HttpClient ioClient(String? pin) => HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..badCertificateCallback = (cert, host, port) =>
        pin != null && pin.isNotEmpty && certificateFingerprint(cert) == pin;

  /// `AB:CD:…` SHA-256 fingerprint of the certificate's key, as the server
  /// prints it. The key stays when the server renews its certificate.
  static String certificateFingerprint(X509Certificate cert) {
    try {
      return formatFingerprint(
        sha256.convert(subjectPublicKeyInfo(cert.der)).bytes,
      );
    } on FormatException {
      return '';
    }
  }

  /// Connects to [url] and returns the fingerprint of its certificate if
  /// the system does not trust it (self-signed): the app then asks the user.
  /// Returns null if the certificate is trusted or not HTTPS; throws
  /// [ApiError] if the server is not reachable.
  static Future<String?> untrustedCertificate(Uri url) async {
    if (url.scheme != 'https') return null;
    String? seen;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (cert, host, port) {
        seen = certificateFingerprint(cert);
        return false;
      };
    try {
      final request = await client.getUrl(url.resolve('api/health'));
      await (await request.close()).drain<void>();
      return null;
    } on HandshakeException {
      if (seen != null) return seen;
      throw const ApiError(
        0,
        'tls',
        'Verschlüsselte Verbindung fehlgeschlagen',
      );
    } on SocketException catch (e) {
      throw ApiError(0, 'network', 'Server nicht erreichbar ($e)');
    } on HttpException catch (e) {
      throw ApiError(0, 'network', 'Server nicht erreichbar ($e)');
    } finally {
      client.close(force: true);
    }
  }

  static const _timeout = Duration(seconds: 20);

  /// The server shows a certificate other than the confirmed one.
  static const tlsRejected =
      'Das Zertifikat des Servers passt nicht zum bestätigten. Wurde der '
      'Server neu eingerichtet? Dann die Adresse neu eingeben und den '
      'Fingerabdruck mit dem Server-Log vergleichen.';

  /// Accepts user input like `homeassistant.local:8765` and returns a URL.
  static Uri normalizeUrl(String input) {
    var text = input.trim();
    if (!text.contains('://')) text = 'http://$text';
    var uri = Uri.parse(text);
    if (!uri.hasPort && uri.scheme == 'http') uri = uri.replace(port: 8765);
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path, query: null, fragment: null);
  }

  Future<ServerInfo> health() async {
    final json = await _send('GET', 'api/health');
    if (json['name'] != 'famio') {
      throw const ApiError(0, 'not_famio', 'Das ist kein Famio-Server');
    }
    return ServerInfo(
      version: json['version'] as String,
      setupRequired: json['setupRequired'] as bool,
      setupCodeRequired: json['setupCodeRequired'] as bool? ?? false,
      singleSignOn: json['sso'] as String?,
    );
  }

  Future<LoginResult> setup({
    required String username,
    required String displayName,
    required String password,
    String? setupCode,
    String? device,
  }) => _login('api/auth/setup', {
    'username': username,
    'displayName': displayName,
    'password': password,
    'setupCode': ?setupCode,
    'device': device,
  });

  Future<LoginResult> login({
    required String username,
    required String password,
    String? device,
  }) => _login('api/auth/login', {
    'username': username,
    'password': password,
    'device': device,
  });

  /// Second step after [TwoFactorRequired]: the code from the
  /// authenticator app or a recovery code.
  Future<LoginResult> loginTwoFactor({
    required String challenge,
    required String code,
  }) => _login('api/auth/login/two-factor', {
    'challenge': challenge,
    'code': code,
  });

  Future<void> logout() => _send('POST', 'api/auth/logout');

  // --- two-factor ------------------------------------------------------------

  Future<TwoFactorStatus> twoFactorStatus() async =>
      TwoFactorStatus.fromJson(await _send('GET', 'api/me/two-factor'));

  /// Starts the setup: the secret and the `otpauth://` link for the QR code.
  Future<({String secret, String uri})> beginTotp() async {
    final json = await _send('POST', 'api/me/two-factor/totp');
    return (secret: json['secret'] as String, uri: json['uri'] as String);
  }

  /// Activates two-factor login; returns the recovery codes (shown once).
  Future<List<String>> confirmTotp(String code) async {
    final json = await _send('POST', 'api/me/two-factor/totp/confirm', {
      'code': code,
    });
    return (json['recoveryCodes'] as List).cast();
  }

  Future<void> disableTotp({required String password, required String code}) =>
      _send('POST', 'api/me/two-factor/totp/disable', {
        'password': password,
        'code': code,
      });

  Future<List<String>> newRecoveryCodes(String code) async {
    final json = await _send('POST', 'api/me/two-factor/recovery-codes', {
      'code': code,
    });
    return (json['recoveryCodes'] as List).cast();
  }

  /// Confirms the second factor for this session.
  Future<void> verifyTwoFactor(String code) =>
      _send('POST', 'api/me/two-factor/verify', {'code': code});

  // --- single sign-on ----------------------------------------------------------

  /// Starts signing in ([link] false) or linking the own account in the
  /// browser.
  Future<SsoFlow> startSso({bool link = false, String? device}) async {
    final json = await _send('POST', 'api/auth/sso/start', {
      'mode': link ? 'link' : 'login',
      'device': device,
    });
    return SsoFlow(
      url: Uri.parse(json['url'] as String),
      flow: json['flow'] as String,
      secret: json['secret'] as String,
    );
  }

  /// Null while the browser part is still open; the session once done (for
  /// linking: the own member, [LoginResult.token] empty).
  Future<LoginResult?> pollSso(SsoFlow flow) async {
    final json = await _send('POST', 'api/auth/sso/poll', {
      'flow': flow.flow,
      'secret': flow.secret,
    });
    if (json['status'] != 'done') return null;
    final result = LoginResult(
      token: json['token'] as String? ?? '',
      member: FamilyMember.fromJson((json['member'] as Map).cast()),
    );
    if (result.token.isNotEmpty) token = result.token;
    return result;
  }

  Future<void> unlinkSso() => _send('DELETE', 'api/me/sso');

  Future<FamilyMember> me() async =>
      FamilyMember.fromJson(await _send('GET', 'api/me'));

  /// Settings for all apps: `mapTileUrl` (null = OpenStreetMap).
  Future<Map<String, Object?>> config() => _send('GET', 'api/config');

  Future<List<FamilyMember>> members() async {
    final json = await _send('GET', 'api/members');
    return [
      for (final m in json['members'] as List)
        FamilyMember.fromJson((m as Map).cast()),
    ];
  }

  Future<FamilyMember> createMember({
    required String username,
    required String displayName,
    required String password,
    bool isAdmin = false,
    MemberRole role = MemberRole.adult,
  }) async => FamilyMember.fromJson(
    await _send('POST', 'api/members', {
      'username': username,
      'displayName': displayName,
      'password': password,
      'isAdmin': isAdmin,
      'role': role.name,
    }),
  );

  Future<void> deleteMember(String id) => _send('DELETE', 'api/members/$id');

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) => _send('PUT', 'api/me/password', {
    'currentPassword': currentPassword,
    'newPassword': newPassword,
  });

  /// Changes the own display name, color and/or birthday ([clearBirthday]
  /// removes it).
  Future<FamilyMember> updateMe({
    String? displayName,
    int? color,
    Birthday? birthday,
    bool clearBirthday = false,
  }) async => FamilyMember.fromJson(
    await _send('PATCH', 'api/me', {
      'displayName': ?displayName,
      'color': ?color,
      if (birthday != null || clearBirthday) 'birthday': birthday?.toString(),
    }),
  );

  /// Devices the own account is signed in on.
  Future<List<DeviceSession>> mySessions() async {
    final json = await _send('GET', 'api/me/sessions');
    return [
      for (final s in json['sessions'] as List)
        DeviceSession.fromJson((s as Map).cast()),
    ];
  }

  Future<void> deleteMySession(String sessionId) =>
      _send('DELETE', 'api/me/sessions/$sessionId');

  // --- server administration (admins only) ---------------------------------

  Future<ServerOverview> adminOverview() async =>
      ServerOverview.fromJson(await _send('GET', 'api/admin/overview'));

  /// Keys with a null value reset that setting to the server default.
  Future<ServerOverview> updateServerSettings(
    Map<String, Object?> changes,
  ) async => ServerOverview.fromJson(
    await _send('PATCH', 'api/admin/settings', changes),
  );

  /// Sets all server settings back to their defaults.
  Future<ServerOverview> resetServerSettings() async =>
      ServerOverview.fromJson(await _send('POST', 'api/admin/settings/reset'));

  /// Deletes all of the family's data on the server (see the server's
  /// `/api/admin/wipe`). [confirm] must be "LÖSCHEN". Returns how many
  /// records, files and members were removed.
  Future<({int records, int files, int members})> wipeServerData({
    required String password,
    required String confirm,
    bool removeMembers = false,
  }) async {
    final json = await _send('POST', 'api/admin/wipe', {
      'password': password,
      'confirm': confirm,
      'removeMembers': removeMembers,
    });
    return (
      records: (json['records'] as num?)?.toInt() ?? 0,
      files: (json['files'] as num?)?.toInt() ?? 0,
      members: (json['members'] as num?)?.toInt() ?? 0,
    );
  }

  /// Calendars shared with member [id] and which an admin switched off.
  Future<List<MemberCalendar>> memberCalendars(String id) async =>
      _memberCalendars(await _send('GET', 'api/admin/users/$id/calendars'));

  /// Switches the calendars [hidden] off for member [id].
  Future<List<MemberCalendar>> setMemberCalendars(
    String id,
    Iterable<String> hidden,
  ) async => _memberCalendars(
    await _send('PUT', 'api/admin/users/$id/calendars', {
      'hidden': [...hidden],
    }),
  );

  static List<MemberCalendar> _memberCalendars(Map<String, Object?> json) => [
    for (final c in json['calendars'] as List? ?? const [])
      MemberCalendar.fromJson((c as Map).cast()),
  ];

  Future<List<AdminUser>> adminUsers() async {
    final json = await _send('GET', 'api/admin/users');
    return [
      for (final u in json['users'] as List)
        AdminUser.fromJson((u as Map).cast()),
    ];
  }

  Future<FamilyMember> updateUser(
    String id, {
    String? username,
    String? displayName,
    bool? isAdmin,
    int? color,
    Birthday? birthday,
    bool clearBirthday = false,
    MemberRole? role,
  }) async => FamilyMember.fromJson(
    await _send('PATCH', 'api/admin/users/$id', {
      'username': ?username,
      'displayName': ?displayName,
      'isAdmin': ?isAdmin,
      'color': ?color,
      'role': ?role?.name,
      if (birthday != null || clearBirthday) 'birthday': birthday?.toString(),
    }),
  );

  /// Returns how many devices were signed out.
  Future<int> resetPassword(
    String id,
    String password, {
    bool signOut = true,
  }) async {
    final json = await _send('PUT', 'api/admin/users/$id/password', {
      'password': password,
      'signOut': signOut,
    });
    return json['signedOut'] as int? ?? 0;
  }

  /// Signs a member out on one device, or on all (except this one).
  /// Switches off two-factor login of member [id] (lost phone).
  Future<void> resetTwoFactor(String id) =>
      _send('DELETE', 'api/admin/users/$id/two-factor');

  Future<void> unlinkUserSso(String id) =>
      _send('DELETE', 'api/admin/users/$id/sso');

  /// The single sign-on provider (without its secret) and the address to
  /// register there as redirect URI.
  Future<Map<String, Object?>> ssoConfig() => _send('GET', 'api/admin/sso');

  /// An empty [clientSecret] keeps the stored one.
  Future<Map<String, Object?>> saveSsoConfig({
    required String issuer,
    required String clientId,
    required String clientSecret,
    required String label,
    required bool matchUsername,
  }) => _send('PUT', 'api/admin/sso', {
    'issuer': issuer,
    'clientId': clientId,
    'clientSecret': clientSecret,
    'label': label,
    'matchUsername': matchUsername,
  });

  Future<void> deleteSsoConfig() => _send('DELETE', 'api/admin/sso');

  Future<void> signOutUser(String id, {String? sessionId}) => _send(
    'DELETE',
    sessionId == null
        ? 'api/admin/users/$id/sessions'
        : 'api/admin/users/$id/sessions/$sessionId',
  );

  /// The member's calendar feeds and the server's public base URL, if one
  /// is configured (needed for Google Calendar).
  Future<(List<CalendarFeed>, Uri? publicUrl)> calendarFeeds() async {
    final json = await _send('GET', 'api/calendar/feeds');
    final public = json['publicUrl'] as String?;
    return (
      [
        for (final f in json['feeds'] as List)
          CalendarFeed.fromJson((f as Map).cast()),
      ],
      // Taken as configured: behind a proxy there is no default port.
      public == null
          ? null
          : Uri.parse(public.endsWith('/') ? public : '$public/'),
    );
  }

  Future<CalendarFeed> createCalendarFeed({
    required String name,
    required FeedScope scope,
    bool hideDetails = false,
  }) async => CalendarFeed.fromJson(
    await _send('POST', 'api/calendar/feeds', {
      'name': name,
      'scope': scope.name,
      'hideDetails': hideDetails,
    }),
  );

  Future<void> deleteCalendarFeed(String id) =>
      _send('DELETE', 'api/calendar/feeds/$id');

  /// Asks the server to import a subscription now; returns the new status.
  Future<SubscriptionStatus> refreshSubscription(String id) async {
    final json = await _send('POST', 'api/calendar/subscriptions/$id/refresh');
    return SubscriptionStatus.fromRecord(
      SyncRecord(
        collection: Collections.calendarSyncStatus,
        id: id,
        data: json,
        updatedAt: 0,
      ),
    );
  }

  // --- CalDAV ---------------------------------------------------------------

  /// Passwords of calendar apps connected to Famio's CalDAV server.
  // --- push notifications (ntfy) ------------------------------------------

  Future<List<PushTarget>> pushTargets() async {
    final json = await _send('GET', 'api/me/push');
    return [
      for (final t in json['targets'] as List)
        PushTarget.fromJson((t as Map).cast()),
    ];
  }

  /// Adds a device; the server sends a test message right away (see
  /// [PushTarget.lastError]).
  Future<PushTarget> addPushTarget({
    required String name,
    required String url,
    String? token,
    bool details = false,
  }) async => PushTarget.fromJson(
    await _send('POST', 'api/me/push', {
      'name': name,
      'url': url,
      'token': ?token,
      'details': details,
    }),
  );

  Future<void> deletePushTarget(String id) =>
      _send('DELETE', 'api/me/push/$id');

  /// Returns the error, or null if the test message went out.
  Future<String?> testPushTarget(String id) async =>
      (await _send('POST', 'api/me/push/$id/test'))['error'] as String?;

  Future<List<AppPassword>> appPasswords() async {
    final json = await _send('GET', 'api/me/app-passwords');
    return [
      for (final p in json['passwords'] as List)
        AppPassword.fromJson((p as Map).cast()),
    ];
  }

  /// Creates an app password; the secret is only shown this once.
  Future<(AppPassword, String secret)> createAppPassword({
    required String name,
    bool includeConfidential = false,
  }) async {
    final json = await _send('POST', 'api/me/app-passwords', {
      'name': name,
      'includeConfidential': includeConfidential,
    });
    return (
      AppPassword.fromJson((json['password'] as Map).cast()),
      json['secret'] as String,
    );
  }

  /// A configuration profile that connects Apple Calendar to Famio (with a
  /// new app password) for devices reaching the server at [url].
  Future<({String fileName, String profile})> appleProfile({
    required Uri url,
    String? name,
  }) async {
    final json = await _send('POST', 'api/me/apple-profile', {
      'url': url.toString(),
      'name': ?name,
    });
    return (
      fileName: json['fileName'] as String,
      profile: json['profile'] as String,
    );
  }

  Future<void> deleteAppPassword(String id) =>
      _send('DELETE', 'api/me/app-passwords/$id');

  /// Calendars the server finds with these credentials (e.g. iCloud).
  Future<List<CalDavCalendarInfo>> discoverCalDav({
    required String url,
    required String username,
    required String password,
  }) async {
    final json = await _send('POST', 'api/calendar/caldav/discover', {
      'url': url,
      'username': username,
      'password': password,
    }, _slow);
    return [
      for (final c in json['calendars'] as List)
        CalDavCalendarInfo.fromJson((c as Map).cast()),
    ];
  }

  /// Hands the code from Google's login page to the server; returns a
  /// one-time grant id, the account's e-mail and its calendars.
  Future<(String grant, String? email, List<CalDavCalendarInfo>)>
  connectGoogle({
    required String clientId,
    required String clientSecret,
    required GoogleLoginResult login,
  }) async {
    final json = await _send('POST', 'api/calendar/google/connect', {
      'clientId': clientId,
      'clientSecret': clientSecret,
      'code': login.code,
      'codeVerifier': login.codeVerifier,
      'redirectUri': login.redirectUri,
    }, _slow);
    return (
      json['grant'] as String,
      json['email'] as String?,
      [
        for (final c in json['calendars'] as List)
          CalDavCalendarInfo.fromJson((c as Map).cast()),
      ],
    );
  }

  Future<List<CalDavAccount>> calDavAccounts() async {
    final json = await _send('GET', 'api/calendar/caldav');
    return [
      for (final a in json['accounts'] as List)
        CalDavAccount.fromJson((a as Map).cast()),
    ];
  }

  /// Connects a calendar and runs the first sync.
  Future<CalDavAccount> createCalDavAccount({
    String serverUrl = '',
    String username = '',
    String password = '',
    required CalDavCalendarInfo calendar,
    bool onlyMine = false,
    CalendarSharing sharing = const CalendarSharing.family(),
    String? googleGrant,
  }) async => CalDavAccount.fromJson(
    await _send('POST', 'api/calendar/caldav', {
      'name': calendar.name,
      'serverUrl': serverUrl,
      'username': username,
      'password': password,
      'calendarUrl': calendar.url,
      'calendarName': calendar.name,
      'onlyMine': onlyMine,
      'sharedWith': sharing.toJson(),
      // Older servers only know "just me".
      'privateImport': sharing.private,
      'googleGrant': ?googleGrant,
    }, _slow),
  );

  Future<CalDavAccount> updateCalDavAccount(
    String id, {
    String? password,
    bool? onlyMine,
    CalendarSharing? sharing,
  }) async => CalDavAccount.fromJson(
    await _send('PATCH', 'api/calendar/caldav/$id', {
      'password': ?password,
      'onlyMine': ?onlyMine,
      if (sharing != null) ...{
        'sharedWith': sharing.toJson(),
        'privateImport': sharing.private,
      },
    }, _slow),
  );

  Future<void> deleteCalDavAccount(String id) =>
      _send('DELETE', 'api/calendar/caldav/$id', null, _slow);

  Future<CalDavAccount> syncCalDavAccount(String id) async =>
      CalDavAccount.fromJson(
        await _send('POST', 'api/calendar/caldav/$id/sync', null, _slow),
      );

  // --- location -------------------------------------------------------------

  /// A token that can only report positions, for a phone's background
  /// service.
  Future<String> locationDeviceToken(String device) async =>
      (await _send('POST', 'api/location/device-token', {
            'device': device,
          }))['token']
          as String;

  Future<LocationReportResult> reportLocation(
    List<LocationFix> fixes, {
    SharingState state = SharingState.active,
    String? device,
  }) async => LocationReportResult.fromJson(
    await _send('POST', 'api/location/report', {
      'fixes': [for (final f in fixes) f.toJson()],
      'state': state.name,
      'device': ?device,
    }),
  );

  /// Pauses location sharing of [memberId] (default: yourself); needs the
  /// parents' code. [duration] null pauses until resumed.
  Future<void> pauseLocation({
    required String code,
    String? memberId,
    Duration? duration,
  }) => _send('POST', 'api/location/pause', {
    'code': code,
    'memberId': ?memberId,
    'minutes': ?duration?.inMinutes,
  });

  Future<void> resumeLocation({String? memberId}) =>
      _send('POST', 'api/location/resume', {'memberId': ?memberId});

  Future<List<LocationFix>> locationHistory({
    String? memberId,
    required DateTime from,
    required DateTime to,
  }) async {
    final json = await _send(
      'GET',
      Uri(
        path: 'api/location/history',
        queryParameters: {
          'member': ?memberId,
          'from': from.toUtc().toIso8601String(),
          'to': to.toUtc().toIso8601String(),
        },
      ).toString(),
    );
    return [
      for (final p in json['points'] as List)
        LocationFix.fromJson((p as Map).cast()),
    ];
  }

  /// Sets (or with null removes) the parents' code for pausing sharing.
  Future<void> setLocationCode(String? code) =>
      _send('PUT', 'api/admin/location-code', {'code': code});

  /// Talking to other calendar servers can take a while.
  static const _slow = Duration(seconds: 120);

  Future<SyncResponse> sync(SyncRequest request) async =>
      SyncResponse.fromJson(await _send('POST', 'api/sync', request.toJson()));

  /// Uploads a file; reference the returned [FileRef] from a record so other
  /// members may download it.
  Future<FileRef> uploadFile({
    required List<int> bytes,
    required String name,
    required String mime,
  }) async {
    final request =
        http.Request(
            'POST',
            baseUrl
                .resolve('api/files')
                .replace(queryParameters: {'name': name}),
          )
          ..headers['content-type'] = mime
          ..bodyBytes = bytes;
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(const Duration(minutes: 5)),
      );
    } catch (e) {
      throw ApiError(0, 'network', 'Upload fehlgeschlagen ($e)');
    }
    final json = _decode(response);
    return FileRef.fromJson(json)!;
  }

  /// Downloads a file or, with [thumb] (160, 480 or 1280), a JPEG preview.
  Future<List<int>> downloadFile(String id, {int? thumb}) async {
    final response = await _http
        .get(fileUrl(id, thumb: thumb), headers: authHeaders)
        .timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) _decode(response);
    return response.bodyBytes;
  }

  Uri fileUrl(String id, {int? thumb}) => baseUrl
      .resolve('api/files/$id')
      .replace(queryParameters: {if (thumb != null) 'thumb': '$thumb'});

  Map<String, String> get authHeaders => {
    if (token != null) 'authorization': 'Bearer $token',
  };

  /// WebSocket URL for change notifications; authenticate with
  /// [authHeaders] (never put the token into the URL, it gets logged).
  Uri get webSocketUrl => baseUrl
      .resolve('api/ws')
      .replace(scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws');

  /// How well the connection to [url] is protected.
  static TransportSecurity transportSecurity(Uri url) {
    if (url.scheme == 'https') return TransportSecurity.encrypted;
    final host = url.host.toLowerCase();
    final ip = InternetAddress.tryParse(host);
    final local = ip != null
        ? ip.isLoopback || ip.isLinkLocal || _isPrivate(ip)
        : host == 'localhost' ||
              host.endsWith('.local') ||
              host.endsWith('.lan') ||
              host.endsWith('.home.arpa') ||
              !host.contains('.');
    return local ? TransportSecurity.localNetwork : TransportSecurity.insecure;
  }

  static bool _isPrivate(InternetAddress ip) {
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 100 && b[1] >= 64 && b[1] < 128); // CGNAT, e.g. Tailscale
    }
    return (b[0] & 0xfe) == 0xfc; // fc00::/7
  }

  void close() => _http.close();

  Future<LoginResult> _login(String path, Map<String, Object?> body) async {
    final json = await _send('POST', path, body);
    if (json['twoFactorRequired'] == true) {
      throw TwoFactorRequired(json['challenge'] as String);
    }
    token = json['token'] as String;
    return LoginResult(
      token: token!,
      member: FamilyMember.fromJson((json['member'] as Map).cast()),
    );
  }

  Future<Map<String, Object?>> _send(
    String method,
    String path, [
    Object? body,
    Duration timeout = _timeout,
  ]) async {
    final request = http.Request(method, baseUrl.resolve(path))
      ..headers['accept'] = 'application/json';
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(timeout),
      );
    } on HandshakeException {
      throw const ApiError(0, 'network', tlsRejected);
    } on http.ClientException catch (e) {
      throw ApiError(
        0,
        'network',
        e.message.contains('CERTIFICATE_VERIFY_FAILED')
            ? tlsRejected
            : 'Server nicht erreichbar (${e.message})',
      );
    } catch (e) {
      throw ApiError(0, 'network', 'Server nicht erreichbar ($e)');
    }

    return _decode(response);
  }

  static Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?> json;
    try {
      json = (jsonDecode(utf8.decode(response.bodyBytes)) as Map).cast();
    } catch (_) {
      throw ApiError(
        response.statusCode,
        'invalid_response',
        'Unerwartete Antwort vom Server (HTTP ${response.statusCode})',
      );
    }
    if (response.statusCode >= 400) {
      throw ApiError(
        response.statusCode,
        json['error'] as String? ?? 'error',
        json['message'] as String? ?? 'Fehler ${response.statusCode}',
      );
    }
    return json;
  }
}
