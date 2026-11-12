import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import '../api_exception.dart';
import '../i18n.dart';

/// The single sign-on provider, set by an admin.
class SsoConfig {
  const SsoConfig({
    required this.issuer,
    required this.clientId,
    required this.clientSecret,
    this.label = '',
    this.matchUsername = false,
  });

  factory SsoConfig.fromJson(Map<String, Object?> json) => SsoConfig(
    issuer: json['issuer'] as String? ?? '',
    clientId: json['clientId'] as String? ?? '',
    clientSecret: json['clientSecret'] as String? ?? '',
    label: json['label'] as String? ?? '',
    matchUsername: json['matchUsername'] as bool? ?? false,
  );

  /// OpenID provider, e.g. `https://auth.example.org/application/o/famio/`.
  final String issuer;
  final String clientId;
  final String clientSecret;

  /// Button text: "Mit … anmelden".
  final String label;

  /// Log in members whose Famio username equals the provider's
  /// `preferred_username` without linking first.
  final bool matchUsername;

  String get buttonLabel => label.trim().isEmpty ? 'Single Sign-On' : label;

  Map<String, Object?> toJson() => {
    'issuer': issuer,
    'clientId': clientId,
    'clientSecret': clientSecret,
    'label': label,
    'matchUsername': matchUsername,
  };
}

/// Where a finished sign-in in the browser goes.
enum SsoMode { login, link }

class _Flow {
  _Flow({
    required this.mode,
    required this.state,
    required this.nonce,
    required this.verifier,
    required this.secretHash,
    required this.code,
    required this.expires,
    this.userId,
    this.device,
    this.address,
  });

  final SsoMode mode;
  final String state;
  final String nonce;
  final String verifier;
  final String secretHash;

  /// Shown in the app that started the flow; the browser asks for it before
  /// anything happens. A link someone else started and handed over is of
  /// no use without it.
  final String code;
  final DateTime expires;
  final String? userId;
  final String? device;

  /// Where the start came from: open flows are limited per address.
  final String? address;

  /// Set by the callback: what the provider vouched for, waiting for the
  /// code in the browser.
  _Outcome? pending;
  int attempts = 0;

  /// Set once confirmed: the signed-in member (login) or linked (link).
  String? resultUser;
  String? error;
}

/// What the browser page shows after the provider: the form asking for the
/// app's code ([confirm] set), or a result.
class SsoPage {
  const SsoPage.result({required this.ok, required this.message})
    : confirm = null,
      device = null,
      link = false,
      error = null;

  const SsoPage.confirm({
    required String state,
    this.device,
    required this.link,
    this.error,
  }) : ok = true,
       message = '',
       confirm = state;

  final bool ok;
  final String message;

  /// The flow's state for the form, if the code is still to come.
  final String? confirm;

  /// The device that asks, as the app named it.
  final String? device;

  /// Linking an account rather than signing in.
  final bool link;

  /// The previous code was wrong.
  final String? error;
}

/// The provider's account and the member it leads to, applied only once the
/// browser confirmed with the code.
class _Outcome {
  _Outcome({
    required this.userId,
    required this.issuer,
    required this.subject,
    required this.name,
    required this.link,
  });

  final String userId;
  final String issuer;
  final String subject;
  final String? name;

  /// Store the provider's account for [userId] (linking, or a first login
  /// with a matching username).
  final bool link;
}

/// Sign-in with an OpenID Connect provider (Authentik, Keycloak, Authelia,
/// Google, Microsoft …) for the apps.
///
/// The app opens the provider in the browser and polls Famio until the
/// browser came back to Famio's callback – no app links or custom URL
/// schemes needed on any platform. Famio is a confidential client: it
/// exchanges the code with its secret and PKCE directly at the provider,
/// so the ID token arrives over TLS from the provider itself and its claims
/// are trusted without checking the signature (OpenID Connect Core
/// 3.1.3.7, 6.). Issuer, audience, expiry and nonce are still checked.
class SsoService {
  SsoService(this._db, {required this.publicUrl, http.Client? client})
    : _http = client ?? http.Client();

  final Database _db;
  final http.Client _http;

  /// The server's public address; the callback must be reachable there.
  final String? Function() publicUrl;

  static const _key = 'sso';
  static const flowLifetime = Duration(minutes: 10);
  static const _maxFlows = 100;

  /// Open flows one address may hold: nobody blocks the sign-in of others
  /// by starting flows that never end.
  static const _maxFlowsPerAddress = 5;

  /// Wrong codes in the browser before the flow ends.
  static const _maxAttempts = 5;

  final _flows = <String, _Flow>{};
  final _random = Random.secure();
  Map<String, Object?>? _discovery;
  String? _discoveredFor;

  SsoConfig? get config {
    final row = _db.select('SELECT value FROM settings WHERE key = ?', [
      _key,
    ]).firstOrNull;
    if (row == null) return null;
    return SsoConfig.fromJson(
      (jsonDecode(row.columnAt(0) as String) as Map).cast(),
    );
  }

  /// Offered to the apps: configured and reachable from outside.
  bool get enabled => config != null && publicUrl() != null;

  String? get redirectUri {
    final base = publicUrl();
    if (base == null) return null;
    return Uri.parse(
      base.endsWith('/') ? base : '$base/',
    ).resolve('api/auth/sso/callback').toString();
  }

  /// Saves the provider after checking its discovery document.
  /// An empty [SsoConfig.clientSecret] keeps the stored one.
  Future<void> save(SsoConfig next) async {
    final issuer = next.issuer.trim();
    final uri = Uri.tryParse(issuer);
    if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) {
      throw ApiException.badRequest(
        'invalid_issuer',
        t('Anbieter-Adresse muss mit https:// beginnen'),
      );
    }
    if (next.clientId.trim().isEmpty) {
      throw ApiException.badRequest('invalid_client', t('Client-ID fehlt'));
    }
    final secret = next.clientSecret.isNotEmpty
        ? next.clientSecret
        : config?.clientSecret ?? '';
    if (secret.isEmpty) {
      throw ApiException.badRequest('invalid_client', t('Client-Secret fehlt'));
    }
    await _discover(issuer, force: true);
    final stored = SsoConfig(
      issuer: issuer,
      clientId: next.clientId.trim(),
      clientSecret: secret,
      label: next.label.trim(),
      matchUsername: next.matchUsername,
    );
    _db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?)'
      ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [_key, jsonEncode(stored.toJson())],
    );
  }

  void remove() {
    _db.execute('DELETE FROM settings WHERE key = ?', [_key]);
    _discovery = null;
    _flows.clear();
  }

  // --- links ---------------------------------------------------------------

  bool isLinked(String userId) => _db.select(
    'SELECT 1 FROM sso_links WHERE user_id = ?',
    [userId],
  ).isNotEmpty;

  Set<String> linkedUsers() => {
    for (final row in _db.select('SELECT DISTINCT user_id FROM sso_links'))
      row.columnAt(0) as String,
  };

  /// Name shown for the member's link (the provider's username or email).
  String? linkName(String userId) =>
      _db.select('SELECT name FROM sso_links WHERE user_id = ?', [
            userId,
          ]).firstOrNull?['name']
          as String?;

  void unlink(String userId) =>
      _db.execute('DELETE FROM sso_links WHERE user_id = ?', [userId]);

  // --- flow ----------------------------------------------------------------

  /// Starts a sign-in in the browser. Returns the provider's URL, the flow
  /// id, the secret the app polls with and the code it shows for the
  /// browser.
  Future<({Uri url, String flow, String secret, String code})> start({
    required SsoMode mode,
    String? userId,
    String? device,
    String? address,
  }) async {
    final cfg = config;
    final redirect = redirectUri;
    if (cfg == null || redirect == null) {
      throw ApiException(
        404,
        'sso_disabled',
        t('Single Sign-On ist auf diesem Server nicht eingerichtet'),
      );
    }
    _expire();
    if (_flows.length >= _maxFlows ||
        (address != null &&
            _flows.values.where((f) => f.address == address).length >=
                _maxFlowsPerAddress)) {
      throw ApiException(
        429,
        'too_many_attempts',
        t('Bitte gleich noch einmal'),
      );
    }
    final discovery = await _discover(cfg.issuer);
    final verifier = _token(48);
    final flow = _token(24);
    final secret = _token(32);
    final state = _token(24);
    final nonce = _token(24);
    final code = _random.nextInt(1000000).toString().padLeft(6, '0');
    _flows[flow] = _Flow(
      mode: mode,
      state: state,
      nonce: nonce,
      verifier: verifier,
      secretHash: _sha(secret),
      code: code,
      expires: DateTime.now().add(flowLifetime),
      userId: userId,
      device: device,
      address: address,
    );
    final url = Uri.parse(discovery['authorization_endpoint'] as String)
        .replace(
          queryParameters: {
            ...Uri.parse(
              discovery['authorization_endpoint'] as String,
            ).queryParameters,
            'response_type': 'code',
            'client_id': cfg.clientId,
            'redirect_uri': redirect,
            'scope': 'openid profile email',
            'state': state,
            'nonce': nonce,
            'code_challenge': base64Url
                .encode(sha256.convert(utf8.encode(verifier)).bytes)
                .replaceAll('=', ''),
            'code_challenge_method': 'S256',
          },
        );
    return (url: url, flow: flow, secret: secret, code: code);
  }

  /// The browser came back from the provider. Finds the member for the
  /// provider's account ([memberForUsername]) and returns what the page
  /// shows: the form asking for the app's code, or why it failed. Nothing
  /// is signed in or linked before [confirm].
  Future<SsoPage> callback(
    Map<String, String> query, {
    required String? Function(String username) memberForUsername,
  }) async {
    final flow = _flows.values
        .where((f) => f.state == query['state'])
        .firstOrNull;
    if (flow == null || flow.expires.isBefore(DateTime.now())) {
      return SsoPage.result(
        ok: false,
        message: t(
          'Diese Anmeldung ist abgelaufen. Bitte in der App neu starten.',
        ),
      );
    }
    if (flow.error case final error?) {
      return SsoPage.result(ok: false, message: error);
    }
    // Reloaded: the provider's code is used up, the form is still valid.
    if (flow.pending != null) return _confirmPage(flow);
    try {
      if (query['error'] case final error?) {
        throw ApiException.badRequest(
          'sso_denied',
          t('Der Anbieter hat die Anmeldung abgelehnt ({error}).', {
            'error': error,
          }),
        );
      }
      final code = query['code'];
      if (code == null || code.isEmpty) {
        throw ApiException.badRequest('sso_failed', t('Kein Code erhalten'));
      }
      final claims = await _exchange(code, flow);
      final issuer = claims['iss'] as String;
      final subject = claims['sub'] as String;
      final name =
          (claims['preferred_username'] ?? claims['email'] ?? claims['name'])
              as String?;
      final linked = _linkedTo(issuer, subject);
      switch (flow.mode) {
        case SsoMode.link:
          if (linked != null && linked != flow.userId) throw _taken();
          flow.pending = _Outcome(
            userId: flow.userId!,
            issuer: issuer,
            subject: subject,
            name: name,
            link: true,
          );
        case SsoMode.login:
          var userId = linked;
          var link = false;
          if (userId == null &&
              config!.matchUsername &&
              claims['preferred_username'] is String) {
            userId = memberForUsername(claims['preferred_username'] as String);
            if (userId != null && !isLinked(userId)) {
              link = true;
            } else {
              userId = null;
            }
          }
          if (userId == null) {
            throw ApiException(
              403,
              'sso_unknown',
              t(
                'Zu diesem Anmeldekonto gibt es kein Famio-Konto. Zuerst in der App anmelden und unter Einstellungen → Anmeldung & Sicherheit „Single Sign-On verknüpfen“.',
              ),
            );
          }
          flow.pending = _Outcome(
            userId: userId,
            issuer: issuer,
            subject: subject,
            name: name,
            link: link,
          );
      }
      return _confirmPage(flow);
    } on ApiException catch (e) {
      flow.error = e.message;
      return SsoPage.result(ok: false, message: e.message);
    }
  }

  /// The browser sent the code the app shows: only now is the member signed
  /// in or the account linked. A wrong code asks again, a few times.
  SsoPage confirm(
    Map<String, String> form, {
    required void Function(String userId, String what) audit,
  }) {
    _expire();
    final flow = _flows.values
        .where((f) => f.state == form['state'])
        .firstOrNull;
    final outcome = flow?.pending;
    if (flow == null || outcome == null || flow.error != null) {
      return SsoPage.result(
        ok: false,
        message:
            flow?.error ??
            t('Diese Anmeldung ist abgelaufen. Bitte in der App neu starten.'),
      );
    }
    final entered = (form['code'] ?? '').replaceAll(RegExp(r'\s'), '');
    if (!_same(entered, flow.code)) {
      if (++flow.attempts >= _maxAttempts) {
        flow.pending = null;
        flow.error = t(
          'Zu oft ein falscher Code. Bitte in der App neu starten.',
        );
        return SsoPage.result(ok: false, message: flow.error!);
      }
      return _confirmPage(
        flow,
        error: t(
          'Der Code stimmt nicht. Bitte den Code aus der Famio-App eingeben.',
        ),
      );
    }
    flow.pending = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (flow.mode == SsoMode.link) {
      final linked = _linkedTo(outcome.issuer, outcome.subject);
      if (linked != null && linked != outcome.userId) {
        flow.error = _taken().message;
        return SsoPage.result(ok: false, message: flow.error!);
      }
      _db.execute('DELETE FROM sso_links WHERE user_id = ?', [outcome.userId]);
      _db.execute(
        'INSERT OR REPLACE INTO sso_links'
        ' (issuer, subject, user_id, name, created_at) VALUES (?, ?, ?, ?, ?)',
        [outcome.issuer, outcome.subject, outcome.userId, outcome.name, now],
      );
      flow.resultUser = outcome.userId;
      audit(outcome.userId, 'hat Single Sign-On verknüpft (${outcome.name})');
      return SsoPage.result(
        ok: true,
        message: t('Verknüpft. Du kannst dieses Fenster schließen.'),
      );
    }
    if (outcome.link && !isLinked(outcome.userId)) {
      _db.execute(
        'INSERT OR IGNORE INTO sso_links'
        ' (issuer, subject, user_id, name, created_at) VALUES (?, ?, ?, ?, ?)',
        [outcome.issuer, outcome.subject, outcome.userId, outcome.name, now],
      );
    }
    flow.resultUser = outcome.userId;
    return SsoPage.result(
      ok: true,
      message: t(
        'Angemeldet. Du kannst dieses Fenster schließen und zu Famio zurückkehren.',
      ),
    );
  }

  SsoPage _confirmPage(_Flow flow, {String? error}) => SsoPage.confirm(
    state: flow.state,
    device: flow.device,
    link: flow.mode == SsoMode.link,
    error: error,
  );

  String? _linkedTo(String issuer, String subject) =>
      _db.select(
            'SELECT user_id FROM sso_links WHERE issuer = ? AND subject = ?',
            [issuer, subject],
          ).firstOrNull?['user_id']
          as String?;

  static ApiException _taken() => ApiException(
    409,
    'sso_taken',
    t('Dieses Anmeldekonto gehört schon zu einem anderen Mitglied.'),
  );

  /// Compares in constant time.
  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// The app asks whether the browser part is done: null while pending,
  /// otherwise the member (once – the flow ends).
  ({String userId, SsoMode mode, String? device})? poll(
    String flowId,
    String secret,
  ) {
    _expire();
    final flow = _flows[flowId];
    if (flow == null || flow.secretHash != _sha(secret)) {
      throw ApiException(
        404,
        'sso_expired',
        t('Anmeldung abgelaufen. Bitte neu starten.'),
      );
    }
    if (flow.error case final error?) {
      _flows.remove(flowId);
      throw ApiException(403, 'sso_failed', error);
    }
    final user = flow.resultUser;
    if (user == null) return null;
    _flows.remove(flowId);
    return (userId: user, mode: flow.mode, device: flow.device);
  }

  // --- provider ------------------------------------------------------------

  Future<Map<String, Object?>> _discover(
    String issuer, {
    bool force = false,
  }) async {
    if (!force && _discovery != null && _discoveredFor == issuer) {
      return _discovery!;
    }
    final base = issuer.endsWith('/') ? issuer : '$issuer/';
    final url = Uri.parse(base).resolve('.well-known/openid-configuration');
    final Map<String, Object?> doc;
    try {
      final response = await _http
          .get(url)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw ApiException.badRequest(
          'sso_discovery',
          t('Anbieter antwortet nicht wie erwartet (HTTP {status} für {url})', {
            'status': response.statusCode,
            'url': url,
          }),
        );
      }
      doc = (jsonDecode(response.body) as Map).cast();
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException.badRequest(
        'sso_discovery',
        t('Anbieter nicht erreichbar ({url}): {error}', {
          'url': url,
          'error': e,
        }),
      );
    }
    for (final key in ['issuer', 'authorization_endpoint', 'token_endpoint']) {
      final value = doc[key];
      if (value is! String || !Uri.parse(value).isScheme('https')) {
        throw ApiException.badRequest(
          'sso_discovery',
          t('Unvollständige OpenID-Konfiguration ({key})', {'key': key}),
        );
      }
    }
    _discovery = doc;
    _discoveredFor = issuer;
    return doc;
  }

  Future<Map<String, Object?>> _exchange(String code, _Flow flow) async {
    final cfg = config!;
    final discovery = await _discover(cfg.issuer);
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(discovery['token_endpoint'] as String),
            headers: {'accept': 'application/json'},
            body: {
              'grant_type': 'authorization_code',
              'code': code,
              'redirect_uri': redirectUri!,
              'client_id': cfg.clientId,
              'client_secret': cfg.clientSecret,
              'code_verifier': flow.verifier,
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw ApiException.badRequest(
        'sso_failed',
        t('Anbieter nicht erreichbar: {error}', {'error': e}),
      );
    }
    if (response.statusCode != 200) {
      throw ApiException.badRequest(
        'sso_failed',
        t(
          'Der Anbieter hat den Code nicht angenommen (HTTP {status}). Client-ID, Secret und Weiterleitungs-Adresse prüfen.',
          {'status': response.statusCode},
        ),
      );
    }
    final token = (jsonDecode(response.body) as Map)['id_token'];
    if (token is! String) {
      throw ApiException.badRequest('sso_failed', t('Kein ID-Token erhalten'));
    }
    final parts = token.split('.');
    if (parts.length < 2) {
      throw ApiException.badRequest('sso_failed', t('Ungültiges ID-Token'));
    }
    final claims =
        (jsonDecode(
                  utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
                )
                as Map)
            .cast<String, Object?>();
    final audience = claims['aud'];
    final audiences = audience is List ? audience : [audience];
    final expires = claims['exp'];
    if (claims['iss'] != discovery['issuer'] ||
        !audiences.contains(cfg.clientId) ||
        claims['nonce'] != flow.nonce ||
        claims['sub'] is! String ||
        expires is! num ||
        expires * 1000 < DateTime.now().millisecondsSinceEpoch) {
      throw ApiException.badRequest(
        'sso_failed',
        t('ID-Token ungültig (Aussteller, Empfänger, Ablauf oder nonce)'),
      );
    }
    return claims;
  }

  void _expire() {
    final now = DateTime.now();
    _flows.removeWhere((_, f) => f.expires.isBefore(now));
  }

  String _token(int bytes) => base64Url
      .encode(List<int>.generate(bytes, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static String _sha(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}
