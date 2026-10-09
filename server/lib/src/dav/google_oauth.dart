import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;

import 'dav_client.dart';
import '../i18n.dart';

/// Access to a Google account, kept by the server: the family's own OAuth
/// client (created in the Google Cloud Console) and the refresh token.
class GoogleGrant {
  GoogleGrant({
    required this.clientId,
    required this.clientSecret,
    required this.refreshToken,
    this.accessToken,
    this.expiresAt,
    this.email,
  });

  factory GoogleGrant.fromJson(Map<String, Object?> json) => GoogleGrant(
    clientId: json['clientId'] as String,
    clientSecret: json['clientSecret'] as String,
    refreshToken: json['refreshToken'] as String,
    accessToken: json['accessToken'] as String?,
    expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
    email: json['email'] as String?,
  );

  final String clientId;
  final String clientSecret;
  final String refreshToken;
  String? accessToken;
  DateTime? expiresAt;

  /// The account's primary calendar id, which is its e-mail address.
  String? email;

  bool get fresh =>
      accessToken != null &&
      expiresAt != null &&
      DateTime.now().isBefore(expiresAt!.subtract(const Duration(minutes: 2)));

  Map<String, Object?> toJson() => {
    'type': 'google',
    'clientId': clientId,
    'clientSecret': clientSecret,
    'refreshToken': refreshToken,
    'accessToken': accessToken,
    'expiresAt': expiresAt?.toIso8601String(),
    'email': email,
  };
}

/// Google's OAuth token endpoint and calendar list, and the CalDAV address
/// of each calendar. Endpoints can be replaced for tests.
class GoogleOAuth {
  GoogleOAuth(
    this._http, {
    Uri? tokenEndpoint,
    Uri? calendarList,
    Uri? caldavBase,
  }) : tokenEndpoint =
           tokenEndpoint ?? Uri.parse('https://oauth2.googleapis.com/token'),
       calendarList =
           calendarList ??
           Uri.parse(
             'https://www.googleapis.com/calendar/v3/users/me/calendarList',
           ),
       caldavBase =
           caldavBase ??
           Uri.parse('https://apidata.googleusercontent.com/caldav/v2/');

  final http.Client _http;
  final Uri tokenEndpoint;
  final Uri calendarList;
  final Uri caldavBase;

  /// Grants waiting for the member to pick a calendar, by one-time id.
  final _pending = <String, (String userId, GoogleGrant, DateTime)>{};
  final _random = Random.secure();

  /// Exchanges the code from Google's login page (PKCE) for tokens.
  Future<GoogleGrant> exchange({
    required String clientId,
    required String clientSecret,
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final json = await _token({
      'grant_type': 'authorization_code',
      'code': code,
      'code_verifier': codeVerifier,
      'redirect_uri': redirectUri,
      'client_id': clientId,
      'client_secret': clientSecret,
    });
    final refresh = json['refresh_token'] as String?;
    if (refresh == null) {
      throw DavException(
        t(
          'Google hat keinen dauerhaften Zugang erteilt. Bitte die Verbindung unter myaccount.google.com → Sicherheit → Drittanbieter-Apps entfernen und erneut anmelden.',
        ),
      );
    }
    return GoogleGrant(
      clientId: clientId,
      clientSecret: clientSecret,
      refreshToken: refresh,
      accessToken: json['access_token'] as String?,
      expiresAt: DateTime.now().add(
        Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600),
      ),
    );
  }

  /// A valid access token for [grant], refreshed when needed (or [force]d).
  Future<String> accessToken(GoogleGrant grant, {bool force = false}) async {
    if (!force && grant.fresh) return grant.accessToken!;
    final json = await _token({
      'grant_type': 'refresh_token',
      'refresh_token': grant.refreshToken,
      'client_id': grant.clientId,
      'client_secret': grant.clientSecret,
    });
    grant
      ..accessToken = json['access_token'] as String
      ..expiresAt = DateTime.now().add(
        Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600),
      );
    return grant.accessToken!;
  }

  /// The account's writable calendars with their CalDAV addresses.
  Future<List<CalDavCalendarInfo>> calendars(GoogleGrant grant) async {
    final response = await _http
        .get(
          calendarList.replace(queryParameters: {'minAccessRole': 'writer'}),
          headers: {'authorization': 'Bearer ${await accessToken(grant)}'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 403) {
      throw DavException(
        t(
          'Google verweigert den Zugriff: Im Cloud-Projekt „Google Calendar API“ und „CalDAV API“ aktivieren.',
        ),
        status: 403,
      );
    }
    if (response.statusCode != 200) {
      throw DavException(
        t('Kalenderliste von Google nicht abrufbar (HTTP {status})', {
          'status': response.statusCode,
        }),
        status: response.statusCode,
      );
    }
    final items =
        (jsonDecode(response.body) as Map)['items'] as List? ?? const [];
    final result = <CalDavCalendarInfo>[];
    for (final item in items.cast<Map>()) {
      final id = item['id'] as String;
      if (item['primary'] == true) grant.email = id;
      final hex = (item['backgroundColor'] as String?)?.replaceAll('#', '');
      result.add(
        CalDavCalendarInfo(
          url: caldavBase
              .resolve('${Uri.encodeComponent(id)}/events/')
              .toString(),
          name: (item['summaryOverride'] ?? item['summary']) as String? ?? id,
          color: hex == null || hex.length != 6
              ? null
              : 0xFF000000 | int.parse(hex, radix: 16),
        ),
      );
    }
    return result;
  }

  /// Keeps [grant] until the member picked a calendar; returns its id.
  String hold(String userId, GoogleGrant grant) {
    _pending.removeWhere(
      (_, v) => DateTime.now().difference(v.$3) > const Duration(minutes: 30),
    );
    final id = base64Url
        .encode(List<int>.generate(18, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    _pending[id] = (userId, grant, DateTime.now());
    return id;
  }

  /// The held grant [id] of [userId] (only once).
  GoogleGrant? take(String userId, String id) {
    final held = _pending[id];
    if (held == null || held.$1 != userId) return null;
    _pending.remove(id);
    return held.$2;
  }

  Future<Map<String, Object?>> _token(Map<String, String> form) async {
    final http.Response response;
    try {
      response = await _http
          .post(tokenEndpoint, body: form)
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw DavException(t('Google antwortet nicht'));
    } on http.ClientException catch (e) {
      throw DavException(
        t('Google nicht erreichbar: {message}', {'message': e.message}),
      );
    }
    final json = (jsonDecode(response.body) as Map).cast<String, Object?>();
    if (response.statusCode != 200) {
      final error = json['error'] as String? ?? 'HTTP ${response.statusCode}';
      throw DavException(switch (error) {
        'invalid_grant' => t(
          'Der Google-Zugang ist abgelaufen oder wurde widerrufen – bitte neu anmelden. (Im Cloud-Projekt den Veröffentlichungsstatus auf „In Produktion“ stellen, sonst endet er nach 7 Tagen.)',
        ),
        'invalid_client' => t('Client-ID oder Client-Secret stimmt nicht'),
        _ => t('Google-Anmeldung fehlgeschlagen ({error})', {'error': error}),
      }, status: 401);
    }
    return json;
  }
}
