import 'dart:convert';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/family_data.dart';
import 'home_widget/widget_sync.dart';
import 'location/location_sharing.dart';
import 'push/own_push.dart';
import 'secure_vault.dart';
import 'reminders/reminder_service.dart';
import 'environment.dart';

/// A server address checked by [AppState.resolveServer]: what to connect
/// to, the certificate to pin and what the server reported.
class ResolvedServer {
  const ResolvedServer(this.url, this.info, {this.pin});

  final String url;
  final ServerInfo info;
  final String? pin;
}

/// Asks the user whether to trust a self-signed server certificate.
typedef TrustCertificate = Future<bool> Function(String fingerprint);

/// Session and sync lifecycle. Screens reach it through [AppScope].
class AppState extends ChangeNotifier {
  /// This device opens the wall display at start (kitchen tablet).
  bool get kioskAutostart => _prefs.getBool('kiosk.autostart') ?? false;

  Future<void> setKioskAutostart(bool value) async {
    await _prefs.setBool('kiosk.autostart', value);
    notifyListeners();
  }

  /// "Hoher Kontrast" on this device; the theme listens to it alone.
  final highContrast = ValueNotifier(false);

  Future<void> setHighContrast(bool value) async {
    highContrast.value = value;
    await _prefs.setBool('highContrast', value);
    notifyListeners();
  }

  late SharedPreferences _prefs;
  late SecureVault vault;
  ReminderService? _reminders;

  /// Famio's own push notifications (without ntfy).
  OwnPush? ownPush;

  String? serverUrl;

  /// Fingerprint of the server's own certificate, if pinned.
  String? certificatePin;

  /// The server presents another key than the pinned one (e.g. after the
  /// switch to renewable certificates in 0.8.1): the user must confirm it.
  String? changedCertificate;
  DateTime? _certificateChecked;
  FamilyMember? me;
  SyncEngine? engine;

  /// Downloaded attachments and documents of the signed-in member.
  FileCache? files;

  /// Message for the login screen, e.g. why the session ended.
  String? notice;

  /// Tile server for maps set by the admins; null uses OpenStreetMap.
  String? mapTileUrl;

  bool get signedIn => engine != null;

  /// The server's HTTPS port for the home network (FAMIO_TLS_PORT).
  static const defaultTlsPort = AppEnv.tlsPort;

  /// Back in the foreground: catch up with changes made meanwhile.
  late final _lifecycle = AppLifecycleListener(
    onResume: () => engine?.resumed(),
  );

  Future<void> init() async {
    _lifecycle;
    _prefs = await SharedPreferences.getInstance();
    highContrast.value = _prefs.getBool('highContrast') ?? false;
    vault = await SecureVault.open(_prefs);
    serverUrl = _prefs.getString('serverUrl');
    mapTileUrl = _prefs.getString('mapTileUrl');
    final token = await vault.read('token');
    final meJson = _prefs.getString('me');
    if (serverUrl != null && token != null && meJson != null) {
      final member = FamilyMember.fromJson((jsonDecode(meJson) as Map).cast());
      await _startSession(
        serverUrl!,
        token,
        member,
        pin: await vault.read('certPin'),
      );
    }
  }

  /// Finds the best way to reach the server at [input]:
  ///
  /// * `https://…` as given; a self-signed certificate is pinned after the
  ///   user confirmed its fingerprint ([trust]).
  /// * A home network address without scheme is tried with HTTPS on
  ///   [defaultTlsPort] first, then falls back to plain HTTP (older servers).
  /// * Plain HTTP to internet addresses is refused.
  Future<ResolvedServer> resolveServer(
    String input, {
    required TrustCertificate trust,
  }) async {
    final uri = FamioApiClient.normalizeUrl(input);
    final explicitHttp = input.trim().toLowerCase().startsWith('http://');
    if (uri.scheme == 'http' &&
        !explicitHttp &&
        FamioApiClient.transportSecurity(uri) ==
            TransportSecurity.localNetwork &&
        (uri.port == 8765 || uri.port == AppEnv.httpPort)) {
      final https = uri.replace(scheme: 'https', port: defaultTlsPort);
      try {
        return await _resolveHttps(https, trust);
      } on ApiError catch (e) {
        if (e.code == 'untrusted') rethrow;
        // No HTTPS port (older server or FAMIO_TLS_PORT=0): plain HTTP.
      }
    }
    if (uri.scheme == 'https') return _resolveHttps(uri, trust);
    final client = _client(uri.toString(), null);
    return ResolvedServer(uri.toString(), await client.health());
  }

  Future<ResolvedServer> _resolveHttps(Uri url, TrustCertificate trust) async {
    final fingerprint = await FamioApiClient.untrustedCertificate(url);
    if (fingerprint != null && !await trust(fingerprint)) {
      throw const ApiError(
        0,
        'untrusted',
        'Zertifikat nicht bestätigt – Verbindung abgebrochen.',
      );
    }
    final client = _client(url.toString(), fingerprint);
    return ResolvedServer(
      url.toString(),
      await client.health(),
      pin: fingerprint,
    );
  }

  /// Passwords and family data never travel unencrypted over the internet:
  /// plain HTTP is only allowed to addresses in the home network.
  static FamioApiClient _client(String url, String? pin, {String? token}) {
    final uri = FamioApiClient.normalizeUrl(url);
    if (FamioApiClient.transportSecurity(uri) == TransportSecurity.insecure) {
      throw const ApiError(
        0,
        'insecure',
        'Über das Internet nur verschlüsselt: bitte die Adresse mit '
            'https:// angeben (z. B. über den Reverse-Proxy).',
      );
    }
    return FamioApiClient(url, token: token, pinnedCertificate: pin);
  }

  Future<void> signIn(
    ResolvedServer server,
    String username,
    String password,
  ) async {
    final result = await _client(
      server.url,
      server.pin,
    ).login(username: username, password: password, device: deviceName);
    await _startSession(
      server.url,
      result.token,
      result.member,
      pin: server.pin,
    );
  }

  /// Second login step after [TwoFactorRequired]: the code from the
  /// authenticator app or a recovery code.
  Future<void> signInTwoFactor(
    ResolvedServer server,
    String challenge,
    String code,
  ) async {
    final result = await _client(
      server.url,
      server.pin,
    ).loginTwoFactor(challenge: challenge, code: code);
    await _startSession(
      server.url,
      result.token,
      result.member,
      pin: server.pin,
    );
  }

  /// Signs in with the single sign-on provider in the browser: [open]
  /// shows its page; Famio is polled until the browser part is done,
  /// [cancelled] returns true or ten minutes pass.
  Future<void> signInSso(
    ResolvedServer server, {
    required Future<void> Function(Uri url) open,
    required bool Function() cancelled,
  }) async {
    final api = _client(server.url, server.pin);
    final flow = await api.startSso(device: deviceName);
    await open(flow.url);
    final end = DateTime.now().add(const Duration(minutes: 10));
    while (!cancelled() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (cancelled()) return;
      final result = await api.pollSso(flow);
      if (result != null) {
        await _startSession(
          server.url,
          result.token,
          result.member,
          pin: server.pin,
        );
        return;
      }
    }
    if (!cancelled()) {
      throw const ApiError(
        0,
        'sso_timeout',
        'Die Anmeldung im Browser wurde nicht abgeschlossen.',
      );
    }
  }

  /// Set when an admin made two-factor login mandatory and this device
  /// still has to set it up or confirm a code; the app shows nothing else.
  TwoFactorStatus? twoFactorGate;

  /// Asks the server whether this session may be used without a second
  /// factor (offline: keeps the current state).
  Future<void> refreshTwoFactor() async {
    final engine = this.engine;
    if (engine == null) return;
    try {
      final status = await engine.api.twoFactorStatus();
      final gate = status.setupNeeded || status.verifyNeeded ? status : null;
      if (this.engine != engine) return;
      final changed = (gate == null) != (twoFactorGate == null);
      twoFactorGate = gate;
      if (changed) {
        notifyListeners();
        if (gate == null) engine.sync();
      }
    } on ApiError {
      // Offline or an older server without two-factor login.
    }
  }

  /// First start of a fresh server: creates the admin account.
  Future<void> setupServer(
    ResolvedServer server, {
    required String displayName,
    required String username,
    required String password,
    String? setupCode,
  }) async {
    final result = await _client(server.url, server.pin).setup(
      username: username,
      displayName: displayName,
      password: password,
      setupCode: setupCode,
      device: deviceName,
    );
    await _startSession(
      server.url,
      result.token,
      result.member,
      pin: server.pin,
    );
  }

  /// Switches a plain-HTTP home network session to the server's HTTPS port
  /// without signing in again.
  Future<void> encryptConnection({required TrustCertificate trust}) async {
    final current = serverUrl;
    final member = me;
    final token = await vault.read('token');
    if (current == null || member == null || token == null) return;
    final uri = Uri.parse(current);
    final server = await _resolveHttps(
      uri.replace(scheme: 'https', port: defaultTlsPort),
      trust,
    );
    // The session token must work over the new connection before switching.
    await _client(server.url, server.pin, token: token).me();
    await _stopSession();
    await _startSession(server.url, token, member, pin: server.pin);
  }

  /// The family's server moved to [input] (new address, same data, e.g.
  /// from Docker to a Proxmox container): switches over without signing in
  /// again. Fails if the server there does not know this session.
  Future<void> moveServer(
    String input, {
    required TrustCertificate trust,
  }) async {
    final member = me;
    final token = await vault.read('token');
    if (member == null || token == null) return;
    final server = await resolveServer(input, trust: trust);
    final FamilyMember there;
    try {
      there = await _client(server.url, server.pin, token: token).me();
    } on ApiError catch (e) {
      if (e.status != 401) rethrow;
      throw const ApiError(
        401,
        'unauthorized',
        'Dieser Server kennt deine Anmeldung nicht – ist es wirklich euer '
            'umgezogener Famio-Server? Sonst abmelden und neu verbinden.',
      );
    }
    if (there.id != member.id) {
      throw const ApiError(
        409,
        'other_member',
        'Dort bist du als jemand anderes angemeldet.',
      );
    }
    await _stopSession();
    await _startSession(server.url, token, there, pin: server.pin);
  }

  /// Offline with a pinned certificate: finds out whether the server now
  /// shows another key (at most once a minute).
  Future<void> _checkCertificate(String url, String pin) async {
    final last = _certificateChecked;
    if (last != null && DateTime.now().difference(last).inSeconds < 60) return;
    _certificateChecked = DateTime.now();
    try {
      final seen = await FamioApiClient.untrustedCertificate(Uri.parse(url));
      if (seen != null && seen != pin && serverUrl == url) {
        changedCertificate = seen;
        notifyListeners();
      }
    } on ApiError {
      // Server not reachable: nothing to decide.
    }
  }

  /// Pins the [changedCertificate] the user confirmed and reconnects.
  Future<void> acceptChangedCertificate() async {
    final pin = changedCertificate;
    final url = serverUrl;
    final member = me;
    final token = await vault.read('token');
    if (pin == null || url == null || member == null || token == null) return;
    // The session must work with the new key before switching.
    await _client(url, pin, token: token).me();
    changedCertificate = null;
    await _stopSession();
    await _startSession(url, token, member, pin: pin);
  }

  Future<void> signOut({String? notice}) async {
    final engine = this.engine;
    final member = me;
    if (engine == null) return;
    this.notice = notice;

    if (notice == null) {
      await engine.sync(); // Last chance to push pending edits.
      try {
        await engine.api.logout();
      } on ApiError {
        // Session is removed locally anyway.
      }
    }
    await _reminders?.clear();
    await HomeWidgetSync.clear();
    // Also the phone's notification service and its token.
    try {
      await ownPush?.detach();
    } catch (_) {
      // Not available on this platform.
    }
    // Signing out ends location sharing on this phone as well.
    try {
      await LocationSharing.disable(api: engine.api);
    } catch (_) {
      // Not available on this platform.
    }
    await _stopSession();
    if (member != null) {
      final support = await _supportDir();
      for (final name in ['famio_${member.id}.db', 'files_${member.id}.db']) {
        for (final suffix in ['', '-journal', '-wal', '-shm']) {
          final file = File(p.join(support, '$name$suffix'));
          if (file.existsSync()) file.deleteSync();
        }
      }
    }
    await vault.write('token', null);
    await vault.write('certPin', null);
    await _prefs.remove('me');
    me = null;
    certificatePin = null;
    changedCertificate = null;
    twoFactorGate = null;
    notifyListeners();
  }

  Future<void> _stopSession() async {
    final engine = this.engine;
    if (engine == null) return;
    this.engine = null;
    notifyListeners();
    await engine.dispose();
    engine.store.close();
    files
      ?..clearTemp()
      ..close();
    files = null;
  }

  Future<void> _startSession(
    String url,
    String token,
    FamilyMember member, {
    String? pin,
  }) async {
    final normalized = FamioApiClient.normalizeUrl(url).toString();
    await _prefs.setString('serverUrl', normalized);
    await _prefs.setString('me', jsonEncode(member.toJson()));
    await vault.write('token', token);
    await vault.write('certPin', pin);

    // Local copy and file cache are encrypted with a key from the keystore.
    final key = await vault.deviceKey();
    final support = await _supportDir();
    final api = FamioApiClient(
      normalized,
      token: token,
      pinnedCertificate: pin,
    );
    final engine = SyncEngine(
      store: LocalStore.open(
        p.join(support, 'famio_${member.id}.db'),
        hexKey: key,
      ),
      api: api,
      memberId: member.id,
    );
    engine.statusChanges.listen((status) {
      if (status.state == SyncState.unauthorized && this.engine == engine) {
        signOut(notice: 'Deine Sitzung ist abgelaufen. Bitte neu anmelden.');
      }
      if (status.state == SyncState.offline && pin != null) {
        _checkCertificate(normalized, pin);
      }
      if (status.state == SyncState.offline &&
          (engine.lastError?.code.startsWith('two_factor') ?? false)) {
        refreshTwoFactor();
      }
    });
    engine.changes.listen((changed) {
      if (changed.contains('members')) _refreshMe();
    });

    // Plain cache folder of version 0.5: now an encrypted database.
    final legacyCache = Directory(p.join(support, 'files_${member.id}'));
    if (legacyCache.existsSync()) legacyCache.deleteSync(recursive: true);
    files = FileCache.open(
      p.join(support, 'files_${member.id}.db'),
      api,
      hexKey: key,
      tempDir: Directory(
        p.join((await getTemporaryDirectory()).path, 'famio_open'),
      ),
    )..clearTemp();
    serverUrl = normalized;
    certificatePin = pin;
    me = member;
    notice = null;
    this.engine = engine..start();
    notifyListeners();
    // After the first sync, move older child records to guardian-only.
    engine.statusChanges
        .firstWhere((s) => s.state == SyncState.idle && s.lastSync != null)
        .then((_) {
          if (this.engine == engine) engine.applyChildVisibility();
        })
        .catchError((Object _) {});

    // Before the reminders: creating those may wait for Android's
    // notification permission dialog.
    final push = ownPush ??= OwnPush(
      _prefs,
      show: (notice, {required details}) async =>
          _reminders?.showNotice(notice, details: details),
    );
    push
        .attach(api, serverUrl: normalized, pin: pin, device: deviceName)
        .catchError((Object _) {});
    _reminders ??= await ReminderService.create(_prefs);
    _reminders?.ownPushActive = () => push.active;
    if (this.engine == engine) _reminders?.attach(engine);
    _loadConfig(api);
    refreshTwoFactor();
    HomeWidgetSync.attach(engine);
    // A sharing phone follows the server address (e.g. after "encrypt").
    LocationSharing.refresh(
      serverUrl: normalized,
      certificatePin: pin,
      device: deviceName,
    ).catchError((Object _) {});
  }

  /// Server settings for the apps; kept for offline use.
  Future<void> _loadConfig(FamioApiClient api) async {
    try {
      final config = await api.config();
      mapTileUrl = config['mapTileUrl'] as String?;
      if (mapTileUrl == null) {
        await _prefs.remove('mapTileUrl');
      } else {
        await _prefs.setString('mapTileUrl', mapTileUrl!);
      }
      notifyListeners();
    } on ApiError {
      // Offline or older server: keep the stored value.
    }
  }

  /// Picks up changes to the own profile (name, admin flag) from the server.
  void _refreshMe() {
    final engine = this.engine;
    if (engine == null) return;
    final fresh = engine.members.where((m) => m.id == me?.id).firstOrNull;
    if (fresh == null) return;
    me = fresh;
    _prefs.setString('me', jsonEncode(fresh.toJson()));
    notifyListeners();
  }

  /// One database per member, so accounts on a shared device never mix.
  static Future<String> _supportDir() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir.path;
  }

  /// Name of this device as shown in the device lists.
  static String get deviceName {
    if (kIsWeb) return 'Web';
    try {
      return '${Platform.operatingSystem} (${Platform.localHostname})';
    } catch (_) {
      return Platform.operatingSystem;
    }
  }
}

/// Provides [AppState] to the widget tree and rebuilds dependents on change.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Like [of], but without rebuilding on change; for callbacks and initState.
  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// The sync engine of the signed-in session. Only valid below the home
  /// shell, which is only shown while signed in.
  static SyncEngine engineOf(BuildContext context) => of(context).engine!;
}
