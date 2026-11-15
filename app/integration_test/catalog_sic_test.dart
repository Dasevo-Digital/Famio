// Catalog tests of the area SIC (emergency button, check-ins, location,
// notifications, server administration, invitations, calendar apps) in the
// real app against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_sic_test.dart
//
// One test per catalog entry or small group ("SIC-NNN …"). What other
// members get comes from their own API sessions; what another device does
// is written through the API. A small proxy in front of the server stands
// in for a lost connection. Tests that change server-wide settings set them
// back; "Alle Daten löschen" runs last.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/holidays.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/push/own_push.dart';
import 'package:famio/src/screens/sos_screens.dart';
import 'package:famio/src/sos/sos_controller.dart';
import 'package:famio/src/widgets/account_widgets.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';

const _allowWipe = String.fromEnvironment('FAMIO_ALLOW_WIPE');

/// Password of the members this file creates itself (random words; the
/// server turns easy ones down).
const _strong = 'Wolke-Regal-Tulpe-17';

/// The parents' code for pausing location sharing.
const _code = '2468';

/// Map tiles from nowhere: no test loads a public map service.
const _tiles = 'https://127.0.0.1:9/{z}/{x}/{y}.png';

/// The sections a guest no longer has (SIC-095).
const _roleAreas = ['Dokumente', 'Kinder', 'Standort', 'Finanzen', 'Medizin'];

/// Stands in for the system's apps (phone, maps, browser).
class _FakeLauncher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

/// A file on disk as the file picker hands it over.
final class _DiskFile extends PlatformFile {
  _DiskFile(this.file);

  final File file;

  @override
  String get name => file.uri.pathSegments.last;

  @override
  Uri get uri => file.uri;

  @override
  get xFile => throw UnimplementedError('not used by the app');

  @override
  int? lengthSync() => file.lengthSync();

  @override
  Future<int?> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

/// Stands in for the native open and folder panels.
class _FakePicker extends FilePickerPlatform {
  final picks = <File>[];
  String? directory;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => picks.isEmpty ? [] : [_DiskFile(picks.removeAt(0))];

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => directory;
}

/// Passes everything (also the WebSocket) through to the throwaway server
/// until [stop]: then the app's server is gone, like without internet.
class _Proxy {
  late final HttpServer _server;
  final _client = HttpClient()..autoUncompress = false;
  final _sockets = <WebSocket>[];
  var _down = false;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = Uri.parse(kitUrl);
    _server.listen((request) async {
      try {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final upstream = await WebSocket.connect(
            target
                .replace(
                  scheme: target.scheme == 'https' ? 'wss' : 'ws',
                  path: request.uri.path,
                  query: request.uri.hasQuery ? request.uri.query : null,
                )
                .toString(),
            headers: {'authorization': ?request.headers.value('authorization')},
          );
          final down = await WebSocketTransformer.upgrade(request);
          _sockets.addAll([upstream, down]);
          upstream.listen(down.add, onDone: down.close, onError: (_) {});
          down.listen(upstream.add, onDone: upstream.close, onError: (_) {});
          return;
        }
        final out = await _client.openUrl(
          request.method,
          target.replace(
            path: request.uri.path,
            query: request.uri.hasQuery ? request.uri.query : null,
          ),
        );
        out.followRedirects = false;
        request.headers.forEach((name, values) {
          if (const {
            'host',
            'content-length',
            'transfer-encoding',
            'connection',
          }.contains(name)) {
            return;
          }
          for (final v in values) {
            out.headers.add(name, v);
          }
        });
        await out.addStream(request);
        final answer = await out.close();
        request.response.statusCode = answer.statusCode;
        answer.headers.forEach((name, values) {
          if (const {
            'content-length',
            'transfer-encoding',
            'connection',
          }.contains(name)) {
            return;
          }
          for (final v in values) {
            request.response.headers.add(name, v);
          }
        });
        await request.response.addStream(answer);
        await request.response.close();
      } catch (_) {
        try {
          request.response.statusCode = 502;
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  Future<void> stop() async {
    if (_down) return;
    _down = true;
    for (final s in _sockets) {
      await s.close().catchError((Object _) {});
    }
    await _server.close(force: true);
    _client.close(force: true);
  }
}

/// RFC 6238 code like an authenticator app.
String _totp(String secret) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final bytes = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final char in secret.toUpperCase().split('')) {
    buffer = (buffer << 5) | alphabet.indexOf(char);
    bits += 5;
    if (bits >= 8) {
      bytes.add((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  final step = DateTime.now().millisecondsSinceEpoch ~/ 30000;
  final counter = ByteData(8)..setUint64(0, step);
  final hash = Hmac(sha1, bytes).convert(counter.buffer.asUint8List()).bytes;
  final o = hash.last & 0x0f;
  final value =
      ((hash[o] & 0x7f) << 24) |
      (hash[o + 1] << 16) |
      (hash[o + 2] << 8) |
      hash[o + 3];
  return (value % pow(10, 6)).toString().padLeft(6, '0');
}

/// The files of a ZIP archive (stored or deflated, as the server writes).
Map<String, List<int>> _unzip(Uint8List b) {
  final d = ByteData.sublistView(b);
  var e = b.length - 22;
  while (e >= 0 && d.getUint32(e, Endian.little) != 0x06054b50) {
    e--;
  }
  final count = d.getUint16(e + 10, Endian.little);
  var p = d.getUint32(e + 16, Endian.little);
  final out = <String, List<int>>{};
  for (var i = 0; i < count; i++) {
    final method = d.getUint16(p + 10, Endian.little);
    final size = d.getUint32(p + 20, Endian.little);
    final nameLength = d.getUint16(p + 28, Endian.little);
    final extra = d.getUint16(p + 30, Endian.little);
    final comment = d.getUint16(p + 32, Endian.little);
    final local = d.getUint32(p + 42, Endian.little);
    final name = utf8.decode(b.sublist(p + 46, p + 46 + nameLength));
    final start =
        local +
        30 +
        d.getUint16(local + 26, Endian.little) +
        d.getUint16(local + 28, Endian.little);
    final raw = b.sublist(start, start + size);
    out[name] = method == 8 ? ZLibDecoder(raw: true).convert(raw) : raw;
    p += 46 + nameLength + extra + comment;
  }
  return out;
}

class _Setup {
  _Setup(this.f, this.kid2, this.service);

  final KitFamily f;
  final FamilyMember kid2, service;
}

void main() {
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final launcher = _FakeLauncher();

  /// What this device showed as a notification (own push).
  final shown = <Notice>[];

  // --- the server ------------------------------------------------------------

  FamioApiClient? adminSession;

  /// An API session of the admin (another device); after "Andere abmelden"
  /// a new one.
  Future<FamioApiClient> admin() async => adminSession ??= await kitAdminApi();

  Future<String> adminId() async => (await (await admin()).me()).id;

  Future<FamilyMember> member(
    String username,
    String name, {
    MemberRole role = MemberRole.adult,
    bool isAdmin = false,
    String password = _strong,
    bool fresh = false,
  }) async {
    final api = await admin();
    for (final u in await api.adminUsers()) {
      if (u.member.username != username) continue;
      if (!fresh) return u.member;
      await api.deleteMember(u.member.id);
    }
    final m = await api.createMember(
      username: username,
      displayName: name,
      password: password,
      role: role,
      isAdmin: isAdmin,
    );
    if (fresh) {
      addTearDown(() async {
        try {
          await (await admin()).deleteMember(m.id);
        } on ApiError {
          // Gone already.
        }
      });
    }
    return m;
  }

  Future<FamioApiClient> login(
    String username, {
    String password = _strong,
    String device = 'e2e',
  }) async {
    final api = FamioApiClient(kitUrl);
    await api.login(username: username, password: password, device: device);
    return api;
  }

  /// Writes over the record's current revision (no conflict copy).
  Future<void> putLatest(
    FamioApiClient api,
    String collection,
    String id,
    Map<String, Object?> data,
  ) async {
    final current = (await pull(api, collection))[id];
    final answer = await api.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: collection,
            id: id,
            data: data,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            rev: current?.rev ?? 0,
          ),
        ],
      ),
    );
    expect(answer.rejected.map((r) => r.id), isNot(contains(id)));
  }

  Future<void> putOk(
    FamioApiClient api,
    String collection,
    Map<String, Map<String, Object?>> records,
  ) async {
    final answer = await put(api, collection, records);
    expect(answer.rejected.map((r) => r.id), isEmpty);
  }

  Future<_Setup>? setup;

  /// Once per file: two more members, map tiles that load nothing, and the
  /// child's button calls nobody (on a Mac it would open the phone app).
  Future<_Setup> prepare() => setup ??= () async {
    final f = await theFamily();
    final kid2 = await member(
      'e2e-kind2',
      'E2E Kind Zwei',
      role: MemberRole.child,
      password: kitMemberPassword,
    );
    final service = await member(
      'e2e-dienst',
      'E2E Dienst',
      role: MemberRole.service,
      password: kitMemberPassword,
    );
    final api = await admin();
    await api.updateServerSettings({
      'mapProvider': MapTileProvider.custom.wire,
      'mapTileUrl': _tiles,
    });
    await putLatest(
      api,
      Collections.sosSettings,
      SosSettings.recordId,
      SosSettings(call: {f.kid.id: SosSettings.none}).toData(),
    );
    return _Setup(f, kid2, service);
  }();

  Future<int> cursor(FamioApiClient api) async => (await api.notices()).last;

  Future<List<Notice>> noticesSince(FamioApiClient api, int after) async =>
      (await api.notices(after: after)).notices;

  Future<Notice> noticeFor(
    WidgetTester tester,
    FamioApiClient api,
    int after,
    bool Function(Notice n) which,
    String what,
  ) async {
    Notice? found;
    await eventually(tester, what, () async {
      found = (await noticesSince(api, after)).where(which).firstOrNull;
      return found != null;
    });
    return found!;
  }

  Future<List<SosAlert>> openAlarms(FamioApiClient api, String of) async => [
    for (final r in (await pull(api, Collections.sosAlerts)).values)
      if (SosAlert.fromRecord(r) case final a when a.memberId == of && a.open)
        a,
  ];

  Future<void> endAlarmsOf(String memberId) async {
    final api = await admin();
    for (final a in await openAlarms(api, memberId)) {
      try {
        await api.sosResolve(a.id);
      } on ApiError {
        // Over already.
      }
    }
  }

  Future<int> davStatus(String username, String password) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        'PROPFIND',
        Uri.parse(kitUrl).resolve('dav/'),
      );
      request.headers
        ..set(
          'authorization',
          'Basic ${base64.encode(utf8.encode('$username:$password'))}',
        )
        ..set('depth', '0');
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close();
    }
  }

  Future<int> rawStatus(
    FamioApiClient api,
    String method,
    String path,
    Object? body,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse(kitUrl).resolve(path),
      );
      api.authHeaders.forEach(request.headers.set);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close();
    }
  }

  Matcher apiError(String message, {int? status}) => isA<ApiError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.status, 'status', status ?? anything);

  Future<File> tempFile(String name, List<int> bytes) async {
    final dir = Directory('${Directory.systemTemp.path}/famio-e2e-sic')
      ..createSync(recursive: true);
    return File('${dir.path}/$name')..writeAsBytesSync(bytes);
  }

  _FakePicker fakePicker() {
    final before = FilePickerPlatform.instance;
    final fake = _FakePicker();
    FilePickerPlatform.instance = fake;
    addTearDown(() => FilePickerPlatform.instance = before);
    return fake;
  }

  // --- the app ----------------------------------------------------------------

  /// As the kit's startApp, also through [url] (a proxy); this device's
  /// notifications land in [shown] instead of the system.
  Future<AppState> start(
    WidgetTester tester, {
    String? user,
    String? password,
    String? url,
  }) async {
    expect(kitUrl, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    await initializeDateFormatting('de');
    UrlLauncherPlatform.instance = launcher;
    // Map tiles come from nowhere (see _tiles); a tile dropped while it
    // fails to load is reported, but is no failure of the app.
    final report = FlutterError.onError;
    FlutterError.onError = (details) {
      if ('${details.exception}'.contains('127.0.0.1:9/')) return;
      report?.call(details);
    };
    addTearDown(() => FlutterError.onError = report);
    SosController.current?.dispose();
    SosController.current = null;
    await freshStart();
    final state = AppState();
    await state.init();
    shown.clear();
    state.ownPush = OwnPush(
      await SharedPreferences.getInstance(),
      show: (notice, {required details}) async => shown.add(notice),
    );
    addTearDown(() async {
      if (state.me != null) await state.signOut();
    });
    await tester.pumpWidget(FamioApp(state: state));
    if (state.me == null) {
      await enter(tester, field('Server-Adresse'), url ?? kitUrl);
      await tap(tester, find.text('Verbinden'));
      await enter(tester, field('Benutzername'), user ?? kitUser);
      await enter(
        tester,
        field('Passwort'),
        password ?? (user == null ? kitPassword : kitMemberPassword),
      );
      await tap(tester, find.text('Anmelden'));
    }
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    if (find.text(de.commonLater).evaluate().isNotEmpty) {
      await tap(tester, find.text(de.commonLater).last);
    }
    await dismissTip(tester);
    return state;
  }

  Finder inDialog(Finder f) =>
      find.descendant(of: find.byType(Dialog), matching: f);

  Future<void> submit(WidgetTester tester, String label) async {
    await leaveField(tester);
    await tap(tester, find.widgetWithText(FilledButton, label).last);
  }

  /// "Passwort bestätigen" before something that keeps access.
  Future<void> confirmPassword(WidgetTester tester, String password) async {
    await waitFor(tester, find.text(de.accountPasswordTitle));
    final dialog = find.ancestor(
      of: find.text(de.accountPasswordTitle),
      matching: find.byType(AlertDialog),
    );
    await enter(
      tester,
      find.descendant(of: dialog, matching: find.byType(TextField)),
      password,
    );
    await leaveField(tester);
    await tap(
      tester,
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(FilledButton, de.commonConfirm),
      ),
    );
    await waitGone(tester, find.text(de.accountPasswordTitle));
  }

  /// A list tile by its title text.
  Finder tile(String title, {bool Function(ListTile t)? where}) =>
      find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            w.title is Text &&
            (w.title! as Text).data == title &&
            (where?.call(w) ?? true),
      );

  String? subtitleOf(ListTile t) =>
      t.subtitle is Text ? (t.subtitle! as Text).data : null;

  /// The ⋮ menu of [name] in "Wo ist wer?".
  Finder memberMenu(String name) => find.descendant(
    of: tile(name, where: (t) => t.trailing is PopupMenuButton<String>),
    matching: find.byType(PopupMenuButton<String>),
  );

  Future<void> fromMenu(WidgetTester tester, String name, String item) async {
    await tap(tester, memberMenu(name));
    await tap(tester, find.text(item).last);
  }

  Future<void> closeMenu(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Holds the emergency button for its three seconds.
  Future<void> hold(WidgetTester tester) async {
    final button = find.byType(SosHoldButton).first;
    await waitFor(tester, button);
    await tester.ensureVisible(button);
    await tester.pump(const Duration(milliseconds: 300));
    debugPrint(
      'E2E hold: hit ${button.hitTestable().evaluate().length},'
      ' tickers ${TickerMode.valuesOf(tester.element(button)).enabled}',
    );
    // After three seconds the alarm screen opens while the finger is still
    // down; the navigator then cancels the pointer. The test binding drops
    // such framework-made events unless they may pass (a phone delivers
    // them): without them the start page's list stays in its drag and
    // ignores every later touch.
    final binding = tester.binding as LiveTestWidgetsFlutterBinding;
    binding.shouldPropagateDevicePointerEvents = true;
    addTearDown(() => binding.shouldPropagateDevicePointerEvents = false);
    final gesture = await tester.startGesture(tester.getCenter(button));
    final end = DateTime.now().add(const Duration(milliseconds: 3700));
    var logged = false;
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      final ring = find.descendant(
        of: button,
        matching: find.byType(CircularProgressIndicator),
      );
      if (!logged &&
          DateTime.now().isAfter(end.subtract(const Duration(seconds: 2))) &&
          ring.evaluate().isNotEmpty) {
        logged = true;
        debugPrint(
          'E2E hold: ring ${tester.widget<CircularProgressIndicator>(ring.first).value}',
        );
      }
    }
    await gesture.up();
    binding.shouldPropagateDevicePointerEvents = false;
    await tester.pump(const Duration(milliseconds: 500));
    debugPrint(
      'E2E hold: screen ${find.byType(SosActiveScreen).evaluate().length},'
      ' current ${SosController.current?.alertId} ${SosController.current?.step}',
    );
  }

  /// Text widgets with exactly [label] (rail entries, tiles …).
  Finder exactly(String label) =>
      find.byWidgetPredicate((w) => w is Text && w.data == label);

  /// A section in the navigation (rail text or tooltip).
  Finder nav(String label) => find.byWidgetPredicate(
    (w) =>
        (w is Text && w.data == label) || (w is Tooltip && w.message == label),
  );

  String hm(DateTime t) => DateFormat.jm('de').format(t);

  /// Drags the page until [finder] is on screen, further than the kit.
  Future<void> scrollFar(
    WidgetTester tester,
    Finder finder, {
    bool up = false,
  }) async {
    for (final towardsTop in [up, !up]) {
      for (var i = 0; i < 45 && finder.evaluate().isEmpty; i++) {
        await tester.dragFrom(
          const Offset(600, 420),
          Offset(0, towardsTop ? 220 : -220),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
    }
    await waitFor(tester, finder, timeout: const Duration(seconds: 3));
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// An error the settings form shows above "Speichern" (built, but maybe
  /// above the visible part of the list).
  Future<void> formError(
    WidgetTester tester,
    String message, {
    bool part = false,
  }) async {
    Finder of({required bool skip}) => part
        ? find.textContaining(message, skipOffstage: skip)
        : find.text(message, skipOffstage: skip);
    await waitFor(tester, of(skip: false));
    await scrollTo(tester, of(skip: true), up: true);
  }

  Future<void> saveSettings(WidgetTester tester) async {
    await scrollTo(tester, find.text(de.commonSave));
    await tap(tester, find.text(de.commonSave).last);
  }

  Future<void> openPushSettings(WidgetTester tester) async {
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsPush));
    await tap(tester, find.text(de.settingsPush));
    await waitFor(tester, find.text(de.pushDirectlyThroughFamio));
  }

  Future<void> openUser(WidgetTester tester, String name) async {
    await openAdmin(tester, 'Benutzer');
    await scrollTo(tester, find.text(name));
    await tap(tester, find.text(name).last);
    await waitFor(tester, find.text(de.adminRole));
  }

  // === settings of the server =================================================

  testWidgets(
    'SIC-044 SIC-127 SIC-109 SIC-116 parents code, SSO without address, public address, values of the server',
    (tester) async {
      await prepare();
      final api = await admin();
      // The first test of the file: no parents' code yet.
      expect((await api.adminOverview()).locationCodeSet, isFalse);
      final state = await start(tester);
      await openAdmin(tester, de.sectionSettings);
      await waitFor(tester, find.text(de.adminPublicAddress));

      // SIC-127: Single Sign-On needs the public address first.
      final sso = tile('Single Sign-On (OpenID Connect)');
      await scrollTo(tester, sso);
      await tap(
        tester,
        find.descendant(of: sso, matching: find.text(de.commonSetUp)),
      );
      await waitFor(tester, find.text(de.ssoFirstEnterSavePublic));
      await tap(tester, inDialog(find.text(de.commonCancel)));
      await dialogClosed(tester);

      // SIC-044: parents' code: not set, mismatch, too short, set.
      final codeTile = tile(de.adminParentsCode);
      await scrollTo(tester, codeTile);
      expect(
        subtitleOf(tester.widget<ListTile>(codeTile)),
        de.adminNotSetYetWithout,
      );
      await tap(
        tester,
        find.descendant(of: codeTile, matching: find.text(de.adminSet)),
      );
      await enter(tester, field(de.adminNewCodeLeast4), _code);
      await enter(tester, field(de.adminRepeatCode), '2469');
      await tap(
        tester,
        inDialog(find.widgetWithText(FilledButton, 'Speichern')),
      );
      await waitFor(tester, find.text(de.adminCodesDoNotMatch));
      await enter(tester, field(de.adminNewCodeLeast4), '12');
      await enter(tester, field(de.adminRepeatCode), '12');
      await tap(
        tester,
        inDialog(find.widgetWithText(FilledButton, 'Speichern')),
      );
      await waitFor(
        tester,
        find.text('Der Code braucht 4 bis 32 Zeichen ohne Leerzeichen'),
      );
      expect((await api.adminOverview()).locationCodeSet, isFalse);
      await enter(tester, field(de.adminNewCodeLeast4), _code);
      await enter(tester, field(de.adminRepeatCode), _code);
      await submit(tester, de.commonSave);
      await dialogClosed(tester);
      await scrollTo(tester, codeTile);
      await waitFor(
        tester,
        find.descendant(
          of: codeTile,
          matching: find.text(de.adminSetNeededPauseEnd),
        ),
      );
      expect(
        find.descendant(of: codeTile, matching: find.text(de.commonChange)),
        findsOneWidget,
      );
      expect((await api.adminOverview()).locationCodeSet, isTrue);

      // SIC-109: only https; empty takes the default again.
      final address = field(de.adminPublicAddress);
      await scrollTo(tester, address, up: true);
      await enter(tester, address, 'http://famio.example.org');
      await saveSettings(tester);
      await formError(
        tester,
        'Öffentliche Adresse muss mit https:// beginnen, z. B. https://famio.example.org',
      );
      expect((await api.adminOverview()).settings.publicUrl, isNull);
      await scrollTo(tester, address, up: true);
      await enter(tester, address, 'https://famio.example.org');
      await saveSettings(tester);
      await waitFor(tester, find.text(de.adminServerSettingsSaved));
      expect(
        (await api.adminOverview()).settings.publicUrl,
        'https://famio.example.org/',
      );
      await snackGone(tester);
      await scrollTo(tester, address, up: true);
      await enter(tester, address, '');
      await saveSettings(tester);
      await waitFor(tester, find.text(de.adminServerSettingsSaved));
      expect((await api.adminOverview()).settings.publicUrl, isNull);

      // SIC-116: shown, not changeable.
      await scrollTo(tester, find.text(de.adminOnlyChangeableServer));
      for (final (label, note) in [
        (de.adminTrustReverseProxy, de.adminFamioTrustProxyNot),
        (de.adminHomeAssistantSign, de.adminAddOptionIngressAuth),
      ]) {
        await scrollTo(tester, find.text(label));
        final row = find
            .ancestor(of: find.text(label), matching: find.byType(Row))
            .first;
        expect(
          find.descendant(of: row, matching: find.text(note)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Text &&
                  (w.data == de.commonOn || w.data == de.commonOff),
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.byType(Switch)),
          findsNothing,
        );
      }
      expect(de.adminFamioTrustProxyNot, contains('FAMIO_TRUST_PROXY'));
      expect(de.adminAddOptionIngressAuth, contains('ingress_auth'));
      await finish(tester, state);
    },
  );

  testWidgets('SIC-119 status of the server', (tester) async {
    await prepare();
    final state = await start(tester);
    await openAdmin(tester, de.adminStatus);
    for (final label in [
      de.settingsVersion,
      de.adminRunningSince,
      de.commonMembers,
      de.adminSignedDevices,
      de.adminConnectedRightNow,
      de.adminDatabase,
      de.commonFiles,
      de.adminSecurity,
      de.adminHttpsHomeNetwork,
      de.adminUnencryptedAccess,
      de.adminCertificateFingerprintCompareWhen,
    ]) {
      await scrollFar(tester, find.text(label));
    }
    // Entries per area.
    await scrollFar(tester, find.text(de.commonEntries), up: true);
    await scrollFar(tester, find.text(de.adminDataServer));
    await finish(tester, state);
  });

  testWidgets(
    'SIC-111 federal state: holidays in the calendar, school holidays once',
    (tester) async {
      await prepare();
      // A state with a holiday in the shown month.
      final now = DateTime.now();
      GermanState? region;
      Holiday? holiday;
      for (final s in GermanState.values) {
        final h = germanHolidays(
          now.year,
          s,
        ).where((h) => h.date.month == now.month).firstOrNull;
        if (h != null) {
          region = s;
          holiday = h;
          break;
        }
      }
      expect(region, isNotNull, reason: 'a holiday this month somewhere');
      final api = await admin();
      addTearDown(() async {
        await (await admin()).updateServerSettings({'holidayRegion': null});
      });
      final proxy = _Proxy();
      await proxy.start();
      addTearDown(proxy.stop);
      final state = await start(tester, url: proxy.url);
      await openAdmin(tester, de.sectionSettings);
      await scrollTo(tester, find.text(de.adminFederalState));
      await choose(tester, de.adminFederalState, region!.label);
      await saveSettings(tester);
      await waitFor(tester, find.text(de.adminServerSettingsSaved));
      expect((await api.adminOverview()).settings.holidayRegion, region.code);
      await eventually(
        tester,
        'the app knows the state',
        () async => familyHolidayRegion == region,
      );
      await back(tester);
      await openSection(tester, 'Kalender');
      // The month shows dots; the day shows the holiday.
      Future<void> openDay() async {
        final day = find.text('${holiday!.date.day}');
        await waitFor(tester, day);
        await tap(tester, holiday!.date.day <= 7 ? day.first : day.last);
      }

      await openDay();
      await waitFor(tester, find.text(holiday!.name));

      // "Keine Feiertage" takes them away again.
      await openAdmin(tester, de.sectionSettings);
      await scrollTo(tester, find.text(de.adminFederalState));
      await choose(tester, de.adminFederalState, de.adminNoPublicHolidays);
      await saveSettings(tester);
      await waitFor(tester, find.text(de.adminServerSettingsSaved));
      await eventually(
        tester,
        'no state in the app',
        () async => familyHolidayRegion == null,
      );
      await back(tester);
      await openSection(tester, 'Kalender');
      await openDay();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(holiday.name), findsNothing);

      // School holidays: subscribed once, the second time "schon". Offline,
      // so the server never loads the public calendar (signing out drops
      // the unsent subscription).
      await openAdmin(tester, de.sectionSettings);
      await scrollTo(tester, find.text(de.adminFederalState));
      await choose(tester, de.adminFederalState, region.label);
      final subscribe = find.text(
        de.adminSubscribeSchoolHolidaysRegion(region.label),
      );
      await scrollTo(tester, subscribe);
      await proxy.stop();
      await tap(tester, subscribe);
      await waitFor(
        tester,
        find.text(de.adminSchoolHolidaysStateSubscribed(region.label)),
      );
      await snackGone(tester);
      await tap(tester, subscribe);
      await waitFor(
        tester,
        find.text(de.adminSchoolHolidaysStateAlready(region.label)),
      );
      await finish(tester, state);
      expect(
        (await pull(
          await admin(),
          Collections.calendarSubscriptions,
        )).values.where((r) => '${r.data['url']}' == region!.schoolHolidaysUrl),
        isEmpty,
      );
    },
  );

  testWidgets('SIC-112 largest file size', (tester) async {
    await prepare();
    final api = await admin();
    addTearDown(() async {
      await (await admin()).updateServerSettings({'maxUploadMb': null});
    });
    final picker = fakePicker();
    final big = await tempFile(
      'e2e-zwei-mb.bin',
      List<int>.filled(2 * 1024 * 1024, 7),
    );
    final state = await start(tester);
    await openAdmin(tester, de.sectionSettings);
    final size = field(de.adminMaximumFileSizeMb);
    for (final wrong in ['0', '5000']) {
      await scrollTo(tester, size);
      await enter(tester, size, wrong);
      await saveSettings(tester);
      await formError(tester, 'Upload-Grenze: 1 bis 4096 MB');
    }
    expect((await api.adminOverview()).settings.maxUploadMb, isNull);
    await scrollTo(tester, size);
    await enter(tester, size, '1');
    await saveSettings(tester);
    await waitFor(tester, find.text(de.adminServerSettingsSaved));
    expect((await api.adminOverview()).settings.maxUploadMb, 1);
    await eventually(
      tester,
      'the app knows the limit',
      () async => state.engine!.maxUploadBytes == 1024 * 1024,
    );

    // The server turns the file down …
    await expectLater(
      api.uploadFile(
        bytes: List<int>.filled(2 * 1024 * 1024, 7),
        name: 'e2e-zwei-mb.bin',
        mime: 'application/octet-stream',
      ),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 413)),
    );
    // … and the app says so before uploading.
    await back(tester);
    await openSection(tester, 'Aufgaben');
    await tap(tester, find.byTooltip('Aufgabe mit Details anlegen'));
    await waitFor(tester, find.text('Neue Aufgabe'));
    await tap(tester, find.text('Checkliste, Dateien, Sichtbarkeit'));
    picker.picks.add(big);
    await tap(tester, find.byTooltip('Foto oder Datei anhängen'));
    await waitFor(tester, find.textContaining('Maximal 1'));
    await tap(tester, inDialog(find.text(de.commonOk)));
    await dialogClosed(tester);
    Navigator.of(tester.element(find.text('Neue Aufgabe'))).pop();
    await tester.pump(const Duration(milliseconds: 600));
    await finish(tester, state);
  });

  testWidgets('SIC-113 map provider', (tester) async {
    await prepare();
    final api = await admin();
    addTearDown(() async {
      await (await admin()).updateServerSettings({
        'mapProvider': MapTileProvider.custom.wire,
        'mapTileUrl': _tiles,
      });
    });
    final state = await start(tester);
    await openAdmin(tester, de.sectionSettings);
    await scrollTo(tester, find.text(de.adminMapProvider));
    final tiles = field(de.adminXyzTileAddress);
    await scrollTo(tester, tiles);
    await enter(tester, tiles, 'https://karten.example.org/kacheln.png');
    await saveSettings(tester);
    await formError(
      tester,
      'Kartenkacheln: https-Adresse mit {z}, {x} und {y}',
      part: true,
    );
    expect((await api.adminOverview()).effective.mapTileUrl, _tiles);
    await scrollTo(tester, find.text('OpenStreetMap'));
    await tap(tester, find.text('OpenStreetMap'));
    await waitFor(tester, find.text(de.adminReadyUsePublicService));
    await saveSettings(tester);
    await waitFor(tester, find.text(de.adminServerSettingsSaved));
    final o = await api.adminOverview();
    expect(o.effective.mapProvider, MapTileProvider.openStreetMap);
    expect(o.effective.mapTileUrl, isNull);
    // Back to tiles from nowhere before anything shows a map.
    await api.updateServerSettings({
      'mapProvider': MapTileProvider.custom.wire,
      'mapTileUrl': _tiles,
    });
    await finish(tester, state);
  });

  // === the emergency button =================================================

  testWidgets(
    'SIC-002 SIC-003 SIC-004 SIC-008 SIC-011 SIC-009 SIC-014 a child holds the button',
    (tester) async {
      final s = await prepare();
      final f = s.f;
      addTearDown(() => endAlarmsOf(f.kid.id));
      final bea = await sessionOf(f.bea);
      final kid2 = await sessionOf(s.kid2);
      final guest = await sessionOf(f.guest);
      final beaFrom = await cursor(bea);
      final kid2From = await cursor(kid2);
      final guestFrom = await cursor(guest);
      bool sos(Notice n) => n.title == '🚨 SOS von E2E Kind';
      final state = await start(tester, user: 'e2e-kind');
      await waitFor(tester, find.text(de.sosEmergency));

      // SIC-003: moving the finger away lets go.
      final button = find.byType(SosHoldButton).first;
      await tester.ensureVisible(button);
      final gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump(const Duration(seconds: 1));
      await gesture.moveBy(const Offset(90, 0));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(de.sosSendingAlarm), findsNothing);
      expect(find.text(de.sosAlarmSent), findsNothing);
      expect(await openAlarms(bea, f.kid.id), isEmpty);

      // SIC-002: three seconds.
      await hold(tester);
      await waitFor(tester, find.text(de.sosAlarmSent));
      expect(find.text(de.sosFamilyWasAlertedSees), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text && (w.data == de.sosSiren || w.data == de.sosSirenOff),
        ),
        findsOneWidget,
      );
      expect(find.text(de.sosIAmSafeEnd), findsOneWidget);
      expect(find.text(de.sosBackFamioAlarmKeeps), findsOneWidget);

      // SIC-004: the adults are told.
      await noticeFor(tester, bea, beaFrom, sos, 'SOS notice for Bea');
      final first = (await openAlarms(bea, f.kid.id)).single.id;

      // SIC-014: not the other child, not the guest.
      expect(await pull(kid2, Collections.sosAlerts), isEmpty);
      expect(await pull(guest, Collections.sosAlerts), isEmpty);
      expect(
        (await noticesSince(
          kid2,
          kid2From,
        )).where((n) => n.title.startsWith('🚨')),
        isEmpty,
      );
      expect(
        (await noticesSince(
          guest,
          guestFrom,
        )).where((n) => n.title.startsWith('🚨')),
        isEmpty,
      );

      // SIC-008 (the child's side): someone is on the way.
      await bea.sosComing(first);
      await waitFor(tester, find.text(de.sosNameHasSeenAlarm('E2E Bea')));
      // The heading is German in every language (sos_screens.dart).
      expect(find.text('E2E Bea kommt!'), findsOneWidget);
      // The screen turns green.
      expect(
        tester
            .widget<Scaffold>(
              find
                  .ancestor(
                    of: find.text('E2E Bea kommt!'),
                    matching: find.byType(Scaffold),
                  )
                  .first,
            )
            .backgroundColor,
        const Color(0xFF2E7D32),
      );

      // SIC-011: back to Famio, the bar opens the same alarm.
      await tap(tester, find.text(de.sosBackFamioAlarmKeeps));
      await waitFor(tester, find.text(de.sosEmergencyCallRunning));
      await tap(tester, find.text(de.sosEmergencyCallRunning));
      await waitFor(tester, find.text(de.sosNameHasSeenAlarm('E2E Bea')));
      await tester.pump(const Duration(seconds: 3));
      expect((await openAlarms(bea, f.kid.id)).map((a) => a.id), [first]);
      expect((await noticesSince(bea, beaFrom)).where(sos), hasLength(1));

      // SIC-009: "Ich bin sicher" ends it for everybody.
      final beforeEnd = await cursor(bea);
      await tap(tester, find.text(de.sosIAmSafeEnd));
      await waitGone(tester, find.text(de.sosIAmSafeEnd));
      final ended = await noticeFor(
        tester,
        bea,
        beforeEnd,
        (n) => n.title == 'Notfall beendet',
        'Notfall beendet for Bea',
      );
      expect(ended.body, 'Der Notfall von E2E Kind ist beendet (E2E Kind).');
      final record = SosAlert.fromRecord(
        (await pull(bea, Collections.sosAlerts))[first]!,
      );
      expect(record.state, SosState.resolved);
      expect(record.resolvedBy, f.kid.id);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(de.sosEmergencyCallRunning), findsNothing);
      await finish(tester, state);
    },
  );

  // The catalog's note on SIC-002: adults have a small button on the start
  // page that works the same.
  testWidgets('SIC-002 adults hold the small button the same way', (
    tester,
  ) async {
    final s = await prepare();
    final me = await adminId();
    addTearDown(() => endAlarmsOf(me));
    final bea = await sessionOf(s.f.bea);
    final beaFrom = await cursor(bea);
    final state = await start(tester);
    await waitFor(
      tester,
      find.byWidgetPredicate((w) => w is SosHoldButton && !w.large),
    );
    expect(
      find.byWidgetPredicate((w) => w is SosHoldButton && w.large),
      findsNothing,
    );
    await hold(tester);
    await waitFor(tester, find.text(de.sosAlarmSent));
    await noticeFor(
      tester,
      bea,
      beaFrom,
      (n) => n.title == '🚨 SOS von $kitAdminName',
      'the admin\'s SOS for Bea',
    );
    expect((await openAlarms(bea, me)), hasLength(1));
    await tap(tester, find.text(de.sosIAmSafeEnd));
    await waitGone(tester, find.text(de.sosIAmSafeEnd));
    expect(await openAlarms(bea, me), isEmpty);
    await finish(tester, state);
  });

  // The catalog's note on SIC-008: the big heading "<B> kommt!" is German
  // in every language.
  testWidgets('SIC-008 the heading on the child side in English', (
    tester,
  ) async {
    final s = await prepare();
    final f = s.f;
    addTearDown(() => endAlarmsOf(f.kid.id));
    final kid = await sessionOf(f.kid);
    final bea = await sessionOf(f.bea);
    final state = await start(tester, user: 'e2e-kind');
    addTearDown(() => state.setLanguage('system'));
    final id = await kid.raiseSos();
    await bea.sosComing(id);
    final en = lookupL10n(const Locale('en'));
    await state.setLanguage('en');
    await tester.pump(const Duration(seconds: 1));
    await waitFor(tester, find.text(en.sosEmergencyCallRunning));
    await tap(tester, find.text(en.sosEmergencyCallRunning));
    await waitFor(tester, find.text(en.sosNameHasSeenAlarm('E2E Bea')));
    expect(find.text('E2E Bea kommt!'), findsOneWidget);
    await tap(tester, find.text(en.sosBackFamioAlarmKeeps));
    await state.setLanguage('system');
    await tester.pump(const Duration(seconds: 1));
    await kid.sosResolve(id);
    await finish(tester, state);
  });

  /// The child presses, goes back to Famio ([reopen]: and opens the alarm
  /// again from the bar), an adult ends it; then the child presses again.
  Future<void> pressAfterEnd(
    WidgetTester tester, {
    required bool reopen,
  }) async {
    final s = await prepare();
    final f = s.f;
    addTearDown(() => endAlarmsOf(f.kid.id));
    final bea = await sessionOf(f.bea);
    bool sos(Notice n) => n.title == '🚨 SOS von E2E Kind';
    final state = await start(tester, user: 'e2e-kind');
    await waitFor(tester, find.text(de.sosEmergency));
    await hold(tester);
    await waitFor(tester, find.text(de.sosAlarmSent));
    await tap(tester, find.text(de.sosBackFamioAlarmKeeps));
    await waitFor(tester, find.text(de.sosEmergencyCallRunning));
    // The start page takes touches again.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(de.sosCheckAllOkay).hitTestable(), findsOneWidget);
    if (reopen) {
      await tap(tester, find.text(de.sosEmergencyCallRunning));
      await waitFor(tester, find.text(de.sosAlarmSent));
      await tap(tester, find.text(de.sosBackFamioAlarmKeeps));
      await waitFor(tester, find.text(de.sosEmergencyCallRunning));
    }
    final first = (await openAlarms(bea, f.kid.id)).single.id;
    final beaFrom = await cursor(bea);
    // Ended on another device.
    await (await admin()).sosResolve(first);
    await waitGone(tester, find.text(de.sosEmergencyCallRunning));
    await tester.pump(const Duration(seconds: 1));
    await hold(tester);
    await waitFor(tester, find.text(de.sosAlarmSent));
    await noticeFor(tester, bea, beaFrom, sos, 'a new SOS notice');
    final second = (await openAlarms(bea, f.kid.id)).single.id;
    expect(second, isNot(first));
    await tap(tester, find.text(de.sosIAmSafeEnd));
    await waitGone(tester, find.text(de.sosIAmSafeEnd));
    await finish(tester, state);
  }

  testWidgets(
    'SIC-013 ended elsewhere: the next press is a new alarm',
    (tester) => pressAfterEnd(tester, reopen: false),
  );

  testWidgets(
    'SIC-013 also after the alarm was opened again from the bar',
    (tester) => pressAfterEnd(tester, reopen: true),
  );

  testWidgets(
    'SIC-004 SIC-006 SIC-008 SIC-010 SIC-009 adults see, come and end an alarm',
    (tester) async {
      final s = await prepare();
      final f = s.f;
      addTearDown(() => endAlarmsOf(f.kid.id));
      final api = await admin();
      addTearDown(() async {
        await putLatest(
          await admin(),
          Collections.sosSettings,
          SosSettings.recordId,
          SosSettings(call: {f.kid.id: SosSettings.none}).toData(),
        );
      });
      final kid = await sessionOf(f.kid);
      final bea = await sessionOf(f.bea);
      final state = await start(tester);
      final beaFrom = await cursor(bea);
      final kidFrom = await cursor(kid);

      // SIC-004: the red bar with the time.
      final id = await kid.raiseSos(
        latitude: 50.1109,
        longitude: 8.6821,
        accuracy: 25,
        battery: 64,
      );
      final alert = SosAlert.fromRecord(
        (await pull(api, Collections.sosAlerts))[id]!,
      );
      final bar = find.text(de.sosFrom('E2E Kind'));
      await waitFor(tester, bar);
      expect(find.text(de.sosSinceTime(hm(alert.startedAt))), findsOneWidget);
      await noticeFor(
        tester,
        bea,
        beaFrom,
        (n) => n.title == '🚨 SOS von E2E Kind',
        'SOS notice for Bea',
      );

      // SIC-006: where, since when, what to do.
      await tap(tester, bar.first);
      await waitFor(tester, find.text(de.sosNobodyHasReactedYet));
      final facts = find.textContaining(
        de.sosTriggeredTime(hm(alert.startedAt)),
      );
      expect(facts, findsOneWidget);
      final line = tester.widget<Text>(facts).data!;
      expect(line, contains('Standort von '));
      expect(line, contains('(± 25 m)'));
      expect(line, contains(de.sosBatteryBattery(64)));
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text(de.sosIMComing), findsOneWidget);
      expect(find.text(de.sosOpenInMaps), findsOneWidget);
      expect(find.text(de.sosEndEmergency), findsOneWidget);
      expect(find.text(de.commonCallName('E2E Kind')), findsNothing);
      // With a number of the child: "anrufen".
      await putLatest(
        api,
        Collections.sosSettings,
        SosSettings.recordId,
        SosSettings(
          phones: {f.kid.id: '0170 5550100'},
          call: {f.kid.id: SosSettings.none},
        ).toData(),
      );
      await waitFor(tester, find.text(de.commonCallName('E2E Kind')));
      launcher.opened.clear();
      await tap(tester, find.text(de.sosOpenInMaps));
      expect(launcher.opened.join(' '), contains('50.1109'));

      // SIC-008: "Ich komme".
      await tap(tester, find.text(de.sosIMComing));
      await waitFor(tester, find.text(de.sosNameWay('Admin')));
      expect(find.text(de.sosIMComing), findsNothing);
      await noticeFor(
        tester,
        kid,
        kidFrom,
        (n) => n.title == 'Admin kommt',
        '"Admin kommt" for the child',
      );
      await noticeFor(
        tester,
        bea,
        beaFrom,
        (n) => n.title == 'Admin kommt',
        '"Admin kommt" for Bea',
      );
      await back(tester);
      await waitFor(tester, find.textContaining(de.sosNameComing('Admin')));
      expect(
        find.byWidgetPredicate(
          (w) => w is Material && w.color == const Color(0xFFEF6C00),
        ),
        findsOneWidget,
      );

      // SIC-010: an adult ends it.
      final kidBeforeEnd = await cursor(kid);
      await tap(tester, bar.first);
      await tap(tester, find.text(de.sosEndEmergency));
      final resolved = find.textContaining('Beendet um ');
      await waitFor(tester, resolved);
      final done = SosAlert.fromRecord(
        (await pull(api, Collections.sosAlerts))[id]!,
      );
      expect(
        tester.widget<Text>(resolved).data,
        de.sosEndedTimeName(hm(done.resolvedAt!), 'Admin'),
      );
      expect(find.text(de.sosIMComing), findsNothing);
      expect(find.text(de.sosEndEmergency), findsNothing);
      await noticeFor(
        tester,
        kid,
        kidBeforeEnd,
        (n) => n.title == 'Notfall beendet',
        'Notfall beendet for the child',
      );
      await back(tester);
      await waitGone(tester, bar);

      // SIC-006 without a position; SIC-009: the child ends it, the page
      // says so.
      final id2 = await kid.raiseSos();
      await waitFor(tester, bar);
      await tap(tester, bar.first);
      await waitFor(tester, find.text(de.sosNobodyHasReactedYet));
      expect(find.text(de.sosLocationStillUnknown), findsOneWidget);
      expect(find.text(de.sosOpenInMaps), findsNothing);
      await kid.sosResolve(id2);
      final byChild = SosAlert.fromRecord(
        (await pull(api, Collections.sosAlerts))[id2]!,
      );
      await waitFor(
        tester,
        find.text(de.sosEndedTimeName(hm(byChild.resolvedAt!), 'E2E Kind')),
      );
      await back(tester);
      // The bar goes for the adults too.
      await waitGone(tester, bar);
      await finish(tester, state);
    },
  );

  testWidgets('SIC-014 SIC-015 guests and service accounts raise no alarm', (
    tester,
  ) async {
    final s = await prepare();
    final f = s.f;
    addTearDown(() => endAlarmsOf(f.kid.id));
    final kid = await sessionOf(f.kid);
    await kid.raiseSos();
    final guest = await sessionOf(f.guest);
    final service = await sessionOf(s.service);
    final state = await start(tester, user: 'e2e-gast');
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(SosHoldButton), findsNothing);
    expect(find.text(de.sosEmergency), findsNothing);
    expect(find.text(de.sosFrom('E2E Kind')), findsNothing);
    expect(state.engine!.records(Collections.sosAlerts), isEmpty);
    expect(await pull(guest, Collections.sosAlerts), isEmpty);
    // The guest is turned away before the button's own check, with the
    // guests' wording.
    await expectLater(
      guest.raiseSos(),
      throwsA(apiError('Für Gäste nicht verfügbar', status: 403)),
    );
    await expectLater(
      service.raiseSos(),
      throwsA(apiError('Für dieses Konto nicht verfügbar', status: 403)),
    );
    // The settings still list the button (see the catalog's note).
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsSos));
    await finish(tester, state);
  });

  testWidgets('SIC-018 no server and no text messages: "Kein Internet"', (
    tester,
  ) async {
    final s = await prepare();
    final f = s.f;
    addTearDown(() => endAlarmsOf(f.kid.id));
    final proxy = _Proxy();
    await proxy.start();
    addTearDown(proxy.stop);
    final state = await start(tester, user: 'e2e-kind', url: proxy.url);
    await waitFor(tester, find.byType(SosHoldButton));
    await eventually(
      tester,
      'the button settings are here',
      () async =>
          SosSettings.fromRecord(
            state.engine!.record(Collections.sosSettings, SosSettings.recordId),
          ).call[f.kid.id] ==
          SosSettings.none,
    );
    await proxy.stop();
    await hold(tester);
    await waitFor(tester, find.text(de.sosNoInternet));
    expect(find.text(de.sosAlarmCouldNotSent), findsOneWidget);
    await tap(tester, find.text(de.sosIAmSafeEnd));
    await waitGone(tester, find.text(de.sosNoInternet));
    expect(await openAlarms(await admin(), f.kid.id), isEmpty);
    await finish(tester, state);
  });

  testWidgets(
    'SIC-024 SIC-025 SIC-027 adults change siren, texts and numbers',
    (tester) async {
      final s = await prepare();
      final f = s.f;
      final kid = await sessionOf(f.kid);
      final bea = await sessionOf(f.bea);
      addTearDown(() async {
        await putLatest(
          await admin(),
          Collections.sosSettings,
          SosSettings.recordId,
          SosSettings(call: {f.kid.id: SosSettings.none}).toData(),
        );
      });
      // Bea's phone fetches Famio's own notifications; the child has none.
      final phone = FamioApiClient(
        kitUrl,
        token: await bea.noticeDeviceToken('E2E Handy'),
      );
      await phone.notices();
      Future<SosSettings> asChild() async => SosSettings.fromRecord(
        (await pull(kid, Collections.sosSettings))[SosSettings.recordId],
      );
      final state = await start(tester);
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, find.text(de.settingsSos));
      await tap(tester, find.text(de.settingsSos));
      await waitFor(tester, find.text(de.sosSirenPhone));

      // SIC-027: whose phone gets alarms.
      await scrollTo(tester, find.text(de.sosWhoGetsAlarms));
      final beaReach = tile(
        'E2E Bea',
        where: (t) => subtitleOf(t) == de.sosFamioNotificationsActive,
      );
      await scrollTo(tester, beaReach);
      final kidReach = tile(
        'E2E Kind',
        where: (t) => subtitleOf(t) == de.sosReceivesNoAlarmsPhone,
      );
      await scrollTo(tester, kidReach);
      expect(
        (tester.widget<ListTile>(kidReach).leading! as Icon).icon,
        AppIcons.warningCircle,
      );

      // SIC-024: the switches work and reach the child.
      for (final (title, read) in [
        (de.sosSirenPhone, (SosSettings x) => x.siren),
        (de.sosTextMessageWithoutInternet, (SosSettings x) => x.sms),
      ]) {
        final sw = find.widgetWithText(SwitchListTile, title);
        await scrollTo(tester, sw, up: true);
        expect(tester.widget<SwitchListTile>(sw).value, isTrue);
        await tap(tester, sw);
        await eventually(
          tester,
          '$title off',
          () async => !read(await asChild()),
        );
        await tap(tester, sw);
        await eventually(
          tester,
          '$title on',
          () async => read(await asChild()),
        );
      }

      // SIC-025: a number, then none again.
      Finder beaNumber(String subtitle) => tile(
        'E2E Bea',
        where: (t) => t.onTap != null && subtitleOf(t) == subtitle,
      );
      await scrollTo(tester, find.text(de.sosPhoneNumbers));
      await scrollTo(tester, beaNumber(de.sosNoNumber));
      await tap(tester, beaNumber(de.sosNoNumber));
      await waitFor(tester, find.text(de.sosNumberName('E2E Bea')));
      await enter(tester, inDialog(find.byType(TextField)), '0170 5550111');
      await submit(tester, de.commonSave);
      await dialogClosed(tester);
      await waitFor(tester, beaNumber('0170 5550111'));
      await eventually(
        tester,
        'the number on the server',
        () async => (await asChild()).phones[f.bea.id] == '0170 5550111',
      );
      await tap(tester, beaNumber('0170 5550111'));
      await waitFor(tester, find.text(de.sosNumberName('E2E Bea')));
      await enter(tester, inDialog(find.byType(TextField)), '');
      await submit(tester, de.commonSave);
      await dialogClosed(tester);
      await waitFor(tester, beaNumber(de.sosNoNumber));
      await eventually(
        tester,
        'no number on the server',
        () async => !(await asChild()).phones.containsKey(f.bea.id),
      );
      await finish(tester, state);
    },
  );

  /// The button settings with Bea's number and the child's [call].
  Future<({FamioApiClient kid, Finder dropdown, AppState state})> callPage(
    WidgetTester tester, {
    String? call,
  }) async {
    final s = await prepare();
    final f = s.f;
    addTearDown(() async {
      await putLatest(
        await admin(),
        Collections.sosSettings,
        SosSettings.recordId,
        SosSettings(call: {f.kid.id: SosSettings.none}).toData(),
      );
    });
    await putLatest(
      await admin(),
      Collections.sosSettings,
      SosSettings.recordId,
      SosSettings(
        phones: {f.bea.id: '0170 5550111'},
        call: {f.kid.id: ?call},
      ).toData(),
    );
    final kid = await sessionOf(f.kid);
    final state = await start(tester);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsSos));
    await tap(tester, find.text(de.settingsSos));
    await scrollTo(tester, find.text(de.sosWhomDoesButtonCall));
    final dropdown = find.descendant(
      of: tile('E2E Kind', where: (t) => t.trailing is DropdownButton<String>),
      matching: find.byType(DropdownButton<String>),
    );
    await scrollTo(tester, dropdown);
    return (kid: kid, dropdown: dropdown, state: state);
  }

  testWidgets('SIC-026 whom the button calls', (tester) async {
    final f = (await prepare()).f;
    final (:kid, :dropdown, :state) = await callPage(tester);
    Future<String?> choice() async => SosSettings.fromRecord(
      (await pull(kid, Collections.sosSettings))[SosSettings.recordId],
    ).call[f.kid.id];

    Future<void> pick(String item) async {
      await tap(tester, dropdown);
      await tap(tester, find.text(item).last);
      await tester.pump(const Duration(milliseconds: 600));
    }

    // The choices: the parent, each adult with a number, 112, nobody.
    await tap(tester, dropdown);
    await waitFor(tester, find.text(de.sosEmergency112));
    final menu = find
        .ancestor(
          of: find.text(de.sosEmergency112),
          matching: find.byType(ListView),
        )
        .first;
    Finder inMenu(String text) =>
        find.descendant(of: menu, matching: find.text(text));
    expect(inMenu(de.sosParentName('E2E Bea')), findsOneWidget);
    expect(inMenu('E2E Bea'), findsOneWidget);
    expect(inMenu(de.sosDoNotCall), findsOneWidget);
    // Adults without a number are not offered.
    expect(inMenu('E2E Carl'), findsNothing);
    expect(inMenu(kitAdminName), findsNothing);
    await tap(tester, find.text(de.sosParentName('E2E Bea')).last);
    await tester.pump(const Duration(milliseconds: 600));
    expect(await choice(), isNull);
    // Each choice stays after the sync.
    for (final (item, stored) in [
      (de.sosEmergency112, SosSettings.emergency),
      ('E2E Bea', f.bea.id),
      (de.sosDoNotCall, SosSettings.none),
    ]) {
      await pick(item);
      await eventually(
        tester,
        '$item on the server',
        () async => await choice() == stored,
      );
    }
    await finish(tester, state);
  });

  // Der erste Eintrag „Elternteil (…)“ nennt, wen die Standardregel anruft,
  // auch wenn für das Kind gerade „Notruf 112“ oder „Nicht anrufen“ gewählt
  // ist (#547).
  testWidgets(
    'SIC-026 the parent entry names the parent while another choice is set',
    (tester) async {
      final (kid: _, :dropdown, :state) = await callPage(
        tester,
        call: SosSettings.none,
      );
      await tap(tester, dropdown);
      await waitFor(tester, find.text(de.sosEmergency112));
      final menu = find
          .ancestor(
            of: find.text(de.sosEmergency112),
            matching: find.byType(ListView),
          )
          .first;
      final entries = [
        for (final e
            in find
                .descendant(of: menu, matching: find.byType(Text))
                .evaluate())
          (e.widget as Text).data,
      ];
      debugPrint('E2E call menu while "Nicht anrufen": $entries');
      expect(
        find.descendant(
          of: menu,
          matching: find.text(de.sosParentName('E2E Bea')),
        ),
        findsOneWidget,
      );
      await tap(tester, find.text(de.sosDoNotCall).last);
      await tester.pump(const Duration(milliseconds: 600));
      await finish(tester, state);
    },
  );

  testWidgets('SIC-024 SIC-027 children see the button settings, no more', (
    tester,
  ) async {
    await prepare();
    addTearDown(() async {
      final api = await admin();
      final now = SosSettings.fromRecord(
        (await pull(api, Collections.sosSettings))[SosSettings.recordId],
      );
      await putLatest(
        api,
        Collections.sosSettings,
        SosSettings.recordId,
        now.copyWith(siren: true).toData(),
      );
    });
    final state = await start(tester, user: 'e2e-kind');
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsSos));
    await tap(tester, find.text(de.settingsSos));
    await waitFor(tester, find.text(de.sosOnlyAdultsCanChange));
    final siren = find.widgetWithText(SwitchListTile, de.sosSirenPhone);
    final sms = find.widgetWithText(
      SwitchListTile,
      de.sosTextMessageWithoutInternet,
    );
    expect(tester.widget<SwitchListTile>(siren).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(sms).onChanged, isNull);
    expect(find.text(de.sosWhoGetsAlarms), findsNothing);
    // What an adult changes shows up here.
    final api = await admin();
    final now = SosSettings.fromRecord(
      (await pull(api, Collections.sosSettings))[SosSettings.recordId],
    );
    await putLatest(
      api,
      Collections.sosSettings,
      SosSettings.recordId,
      now.copyWith(siren: false).toData(),
    );
    await eventually(
      tester,
      'the child sees the siren off',
      () async => !tester.widget<SwitchListTile>(siren).value,
    );
    await finish(tester, state);
  });

  // === check-ins and ringing ================================================

  testWidgets('SIC-028 SIC-029 SIC-031 SIC-032 a child checks in', (
    tester,
  ) async {
    final s = await prepare();
    final f = s.f;
    final api = await admin();
    final adminFrom = await cursor(api);
    final kid = await sessionOf(f.kid);
    final state = await start(tester, user: 'e2e-kind');

    // SIC-028: "Alles ok".
    await tap(tester, find.text(de.sosCheckAllOkay));
    await tap(tester, find.widgetWithText(OutlinedButton, 'Alles ok'));
    await waitFor(tester, find.text(de.sosCheckSentWithoutLocation));
    final told = await noticeFor(
      tester,
      api,
      adminFrom,
      (n) => n.body == 'E2E Kind: Alles ok',
      'check-in notice',
    );
    expect(told.brief, 'Neuer Check-in');
    await snackGone(tester);

    // SIC-029: an own text, at most 80 characters.
    await tap(tester, find.text(de.sosCheckAllOkay));
    final own = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    );
    await waitFor(tester, own);
    await tester.enterText(own, 'E2E ${'x' * 100}');
    await tester.pump();
    expect(tester.widget<TextField>(own).controller!.text, hasLength(80));
    await tester.enterText(own, 'E2E Bin beim Training');
    await tester.pump();
    final ownFrom = await cursor(api);
    await tap(
      tester,
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byTooltip(de.commonSend),
      ),
    );
    await waitFor(tester, find.text(de.sosCheckSentWithoutLocation));
    await noticeFor(
      tester,
      api,
      ownFrom,
      (n) => n.body == 'E2E Kind: E2E Bin beim Training',
      'own check-in text',
    );
    for (final wrong in ['', 'y' * 81]) {
      await expectLater(
        kid.checkIn(wrong),
        throwsA(apiError('Bitte einen kurzen Text', status: 400)),
      );
    }

    // SIC-031: the other child and the guest get nothing; the service
    // account gets its own entry.
    bool checkIn(SyncRecord r) => r.data['checkIn'] == 'Alles ok';
    expect(
      (await pull(
        await sessionOf(s.kid2),
        Collections.locationAlerts,
      )).values.where(checkIn),
      isEmpty,
    );
    expect(
      (await pull(await sessionOf(f.guest), Collections.locationAlerts)).values,
      isEmpty,
    );
    final forService = (await pull(
      await sessionOf(s.service),
      Collections.locationAlerts,
    )).values.where(checkIn);
    expect(forService, isNotEmpty);
    expect(forService.first.visibleTo, [s.service.id]);

    // SIC-031 SIC-032: a child's "Wo ist wer?": no check-ins, no asking.
    await snackGone(tester);
    await openSection(tester, 'Standort');
    await waitFor(tester, find.text(de.homeWhoWhere));
    await waitFor(tester, find.text('E2E Bea'));
    expect(find.text(de.sosCheckIns), findsNothing);
    final menus = find.byType(PopupMenuButton<String>);
    for (var i = 0; i < menus.evaluate().length; i++) {
      await tap(tester, menus.at(i));
      expect(find.text(de.locationAskCheck), findsNothing);
      expect(find.text(de.locationRingPhone), findsNothing);
      await closeMenu(tester);
    }
    await finish(tester, state);
  });

  testWidgets('SIC-028 SIC-032 SIC-033 adults see check-ins, ask and ring', (
    tester,
  ) async {
    final s = await prepare();
    final f = s.f;
    final kid = await sessionOf(f.kid);
    await kid.checkIn('Alles ok');
    final state = await start(tester);
    await openSection(tester, 'Standort');
    await waitFor(tester, find.text(de.sosCheckIns));
    final entry = find.text('E2E Kind: Alles ok');
    await waitFor(tester, entry);
    final checkInTile = tester.widget<ListTile>(
      find.ancestor(of: entry.first, matching: find.byType(ListTile)).first,
    );
    expect(subtitleOf(checkInTile), endsWith(' Uhr'));

    // SIC-032: ask for a check-in.
    final kidFrom = await cursor(kid);
    await fromMenu(tester, 'E2E Kind', de.locationAskCheck);
    await waitFor(tester, find.text(de.locationNameWasAsked('E2E Kind')));
    await noticeFor(
      tester,
      kid,
      kidFrom,
      (n) => n.title == 'Admin bittet um einen Check-in',
      'the child is asked',
    );
    await snackGone(tester);

    // SIC-033: ring, and not again right away.
    await fromMenu(tester, 'E2E Kind', de.locationRingPhone);
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data == de.locationNameSPhoneRings('E2E Kind') ||
                w.data == de.locationSentButNameS('E2E Kind')),
      ),
    );
    await snackGone(tester);
    await fromMenu(tester, 'E2E Kind', de.locationRingPhone);
    await waitFor(
      tester,
      find.text('Gerade erst geklingelt – bitte eine Minute warten.'),
    );
    await finish(tester, state);
  });

  // === location ===========================================================

  testWidgets('SIC-038 SIC-048 computers share nothing; pause and resume', (
    tester,
  ) async {
    final s = await prepare();
    final f = s.f;
    final api = await admin();
    await api.setLocationCode(_code);
    final kid = await sessionOf(f.kid);
    await kid.resumeLocation();
    await kid.reportLocation([
      LocationFix(
        latitude: 50.1,
        longitude: 8.6,
        accuracy: 20,
        battery: 80,
        at: DateTime.now(),
      ),
    ], device: 'E2E Handy');
    final bea = await sessionOf(f.bea);
    Future<SharingState?> kidState() async {
      final r = (await pull(bea, Collections.memberLocations))[f.kid.id];
      return r == null ? null : MemberLocation.fromRecord(r).state;
    }

    final state = await start(tester);
    await openSection(tester, 'Standort');
    // SIC-038
    await waitFor(tester, find.text(de.locationYouShareOwnLocation));
    expect(find.text(de.locationShareMyLocation), findsNothing);

    // SIC-048: pause with the code, resume without.
    await waitFor(tester, memberMenu('E2E Kind'));
    await fromMenu(tester, 'E2E Kind', de.locationPause);
    await waitFor(tester, find.text(de.locationPauseNameSLocation('E2E Kind')));
    await tap(tester, find.widgetWithText(ChoiceChip, de.locationUntilResumed));
    await enter(tester, field(de.adminParentsCode), _code);
    await submit(tester, de.locationPause);
    await dialogClosed(tester);
    await eventually(
      tester,
      'the child is paused',
      () async => await kidState() == SharingState.paused,
    );
    await waitFor(
      tester,
      tile(
        'E2E Kind',
        where: (t) => subtitleOf(t)?.contains(de.locationPaused) ?? false,
      ),
    );
    await fromMenu(tester, 'E2E Kind', de.locationResume);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AlertDialog), findsNothing);
    await eventually(
      tester,
      'the child shares again',
      () async => await kidState() != SharingState.paused,
    );
    await finish(tester, state);
  });

  testWidgets('SIC-049 SIC-055 adults without admin rights', (tester) async {
    final s = await prepare();
    final f = s.f;
    final api = await admin();
    await api.setLocationCode(_code);
    final kid = await sessionOf(f.kid);
    await kid.resumeLocation();
    await kid.reportLocation([
      LocationFix(
        latitude: 50.1,
        longitude: 8.6,
        accuracy: 20,
        at: DateTime.now(),
      ),
    ]);
    await api.setLocationSchedule(
      code: _code,
      memberId: f.kid.id,
      schedule: LocationSchedule(
        weekdays: [1, 2, 3, 4, 5, 6, 7],
        startMinute: 0,
        endMinute: 24 * 60 - 1,
      ),
    );
    addTearDown(() async {
      await (await admin()).setLocationSchedule(
        code: _code,
        memberId: f.kid.id,
      );
    });
    final bea = await sessionOf(f.bea);

    // SIC-055: the schedule is the parents' business.
    await expectLater(
      bea.locationSchedule(memberId: f.kid.id),
      throwsA(apiError('Nur für Eltern (Administratoren)', status: 403)),
    );
    expect(
      (await api.locationSchedule(memberId: f.kid.id))?.weekdays,
      hasLength(7),
    );
    // SIC-049
    await expectLater(
      bea.resumeLocation(memberId: f.kid.id),
      throwsA(apiError('Nur für Eltern (Administratoren)', status: 403)),
    );
    await expectLater(
      bea.locationHistory(
        memberId: f.kid.id,
        from: DateTime.now().subtract(const Duration(days: 1)),
        to: DateTime.now(),
      ),
      throwsA(apiError('Nur für Eltern (Administratoren)', status: 403)),
    );
    final state = await start(tester, user: 'e2e-bea');
    await openSection(tester, 'Standort');
    await waitFor(tester, memberMenu('E2E Kind'));
    await tap(tester, memberMenu('E2E Kind'));
    await waitFor(tester, find.text(de.locationAskCheck));
    expect(find.text(de.locationRingPhone), findsOneWidget);
    expect(find.text(de.locationHideHere), findsOneWidget);
    expect(find.text(de.pregnancyHistory), findsNothing);
    expect(find.text(de.locationPause), findsNothing);
    expect(find.text(de.locationResume), findsNothing);
    await closeMenu(tester);
    await finish(tester, state);
  });

  testWidgets('SIC-066 the way of a child, day by day', (tester) async {
    final s = await prepare();
    final f = s.f;
    final kid = await sessionOf(f.kid);
    await kid.resumeLocation();
    final yesterday = inDays(-1);
    final now = DateTime.now();
    final earlier = now.subtract(const Duration(minutes: 20));
    final later = now.subtract(const Duration(minutes: 10));
    await kid.reportLocation([
      LocationFix(
        latitude: 50.12,
        longitude: 8.62,
        accuracy: 15,
        at: DateTime(yesterday.year, yesterday.month, yesterday.day, 12),
      ),
      LocationFix(
        latitude: 50.13,
        longitude: 8.64,
        accuracy: 15,
        at: DateTime(yesterday.year, yesterday.month, yesterday.day, 12, 30),
      ),
      LocationFix(
        latitude: 50.1,
        longitude: 8.6,
        accuracy: 15,
        at: earlier.isBefore(today()) ? today() : earlier,
      ),
      LocationFix(latitude: 50.11, longitude: 8.61, accuracy: 15, at: later),
    ]);
    final state = await start(tester);
    await openSection(tester, 'Standort');
    await waitFor(tester, memberMenu('E2E Kind'));
    await fromMenu(tester, 'E2E Kind', de.pregnancyHistory);
    await waitFor(tester, find.text(de.historyNameLast7Days('E2E Kind')));
    await waitFor(tester, find.textContaining(' Positionen von '));
    expect(find.byType(ChoiceChip), findsNWidgets(7));
    await tap(tester, find.widgetWithText(ChoiceChip, de.commonYesterday));
    await waitFor(
      tester,
      find.textContaining(
        '2 Positionen von ${hm(DateTime(2000, 1, 1, 12))} bis '
        '${hm(DateTime(2000, 1, 1, 12, 30))} Uhr · ',
      ),
    );
    await tap(
      tester,
      find.widgetWithText(ChoiceChip, DateFormat.MEd('de').format(inDays(-3))),
    );
    await waitFor(tester, find.text(de.historyNoLocationWasShared));
    await back(tester);
    await finish(tester, state);
  });

  testWidgets('SIC-063 SIC-062 SIC-064 "Bin unterwegs"', (tester) async {
    final s = await prepare();
    final f = s.f;
    final api = await admin();
    // No places on the server yet.
    await remove(
      api,
      Collections.places,
      (await pull(api, Collections.places)).keys,
    );
    // The second child: no own position yet, so the slider sets the time.
    final kid = await sessionOf(s.kid2);
    await kid.resumeLocation();
    final bea = await sessionOf(f.bea);
    Future<SyncRecord?> trip() async => (await pull(bea, Collections.trips))
        .values
        .where((r) => Trip.fromRecord(r).memberId == s.kid2.id)
        .firstOrNull;
    final state = await start(tester, user: 'e2e-kind2');
    await openSection(tester, 'Standort');

    // SIC-063: no places.
    await tap(tester, find.text(de.tripStart));
    await waitFor(tester, find.text(de.tripNoPlaces));
    expect(find.text(de.tripTitle), findsNothing);
    await snackGone(tester);

    // SIC-062: to "E2E Zuhause" by bike.
    final home = Place(
      id: uid('place'),
      name: 'E2E Zuhause',
      latitude: 50.2,
      longitude: 8.7,
      notifyMemberIds: [await adminId()],
    );
    await putOk(api, Collections.places, {home.id: home.toData()});
    await eventually(
      tester,
      'the child has the place',
      () async => state.engine!.places.isNotEmpty,
    );
    final beaFrom = await cursor(bea);
    await tap(tester, find.text(de.tripStart));
    await waitFor(tester, find.text(de.tripTitle));
    await choose(tester, de.tripPlace, 'E2E Zuhause');
    await tap(tester, find.byTooltip(de.tripModeBike));
    // Without an own position the minutes come from the slider.
    expect(find.text(de.tripNoPosition), findsOneWidget);
    final eta = inDialog(find.textContaining('Ankunft ca. '));
    final before = tester.widget<Text>(eta).data;
    await tester.drag(inDialog(find.byType(Slider)), const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<Text>(eta).data, isNot(before));
    await tap(tester, find.text(de.tripTell));
    await dialogClosed(tester);
    final label = find.textContaining('unterwegs nach E2E Zuhause, ca. ');
    await waitFor(tester, label);
    expect(find.text(de.tripArrived), findsOneWidget);
    await eventually(tester, 'Bea sees the way', () async {
      final r = await trip();
      return r != null && Trip.fromRecord(r).mode == TripMode.bike;
    });
    final told = await noticeFor(
      tester,
      bea,
      beaFrom,
      (n) => n.body.startsWith(
        'E2E Kind Zwei ist unterwegs nach E2E Zuhause, ca. ',
      ),
      'Bea hears of the way',
    );
    expect(told.body, endsWith(' da'));

    // SIC-064: "Angekommen" …
    await tap(tester, find.text(de.tripArrived));
    await waitGone(tester, label);
    await eventually(
      tester,
      'the way is over',
      () async => await trip() == null,
    );
    // … or arriving there.
    await tap(tester, find.text(de.tripStart));
    await waitFor(tester, find.text(de.tripTitle));
    await tap(tester, find.text(de.tripTell));
    await dialogClosed(tester);
    await waitFor(tester, label);
    await eventually(
      tester,
      'on the way again',
      () async => await trip() != null,
    );
    await kid.reportLocation([
      LocationFix(
        latitude: 50.2,
        longitude: 8.7,
        accuracy: 10,
        at: DateTime.now(),
      ),
    ]);
    await eventually(tester, 'arrived', () async => await trip() == null);
    await waitGone(tester, label);
    await finish(tester, state);
  });

  testWidgets('SIC-056 SIC-057 SIC-058 places', (tester) async {
    final s = await prepare();
    final f = s.f;
    final api = await admin();
    final places = await pull(api, Collections.places);
    if (!places.values.any((r) => r.data['name'] == 'E2E Zuhause')) {
      final home = Place(
        id: uid('place'),
        name: 'E2E Zuhause',
        latitude: 50.2,
        longitude: 8.7,
      );
      await putOk(api, Collections.places, {home.id: home.toData()});
    }
    final bea = await sessionOf(f.bea);
    Future<Place?> school() async => [
      for (final r in (await pull(bea, Collections.places)).values)
        if (r.data['name'] == 'E2E Schule') Place.fromRecord(r),
    ].firstOrNull;
    final state = await start(tester);
    await openSection(tester, 'Standort');
    await tap(tester, find.byTooltip(de.remindersPlaces));
    await tap(
      tester,
      find.widgetWithText(FloatingActionButton, de.commonPlace),
    );
    await waitFor(tester, find.text(de.placesNewPlace));

    // SIC-057: neither name nor centre; no own position on a Mac.
    await tap(tester, find.text(de.commonSave));
    await waitFor(tester, find.text(de.placesPleaseEnterNameTap));
    await snackGone(tester);
    await tap(tester, find.text(de.placesMyPosition));
    await waitFor(tester, find.text(de.placesNoCurrentPositionYours));
    await snackGone(tester);
    // Back up to the name (the map does not scroll the page).
    await tester.ensureVisible(
      find.byType(TextField, skipOffstage: false).first,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await enter(tester, field(de.commonName), 'E2E Schule');
    await tap(tester, find.text(de.commonSave));
    await waitFor(tester, find.text(de.placesPleaseEnterNameTap));
    await snackGone(tester);
    expect(await school(), isNull);

    // SIC-056: tap the map, a larger circle, save.
    await tester.ensureVisible(find.byType(FlutterMap));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(FlutterMap));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.ensureVisible(find.byType(Slider));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(de.placesRadiusRadiusM(150)), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(de.placesRadiusRadiusM(150)), findsNothing);
    await tap(tester, find.text(de.commonSave));
    await waitGone(tester, find.text(de.placesNewPlace));
    final row = tile('E2E Schule');
    await waitFor(tester, row);
    final saved = await school();
    expect(saved, isNotNull);
    expect(saved!.radius, greaterThan(150));
    expect(saved.notifyMemberIds, [await adminId()]);
    expect(
      subtitleOf(tester.widget<ListTile>(row)),
      de.placesRadiusMRadiusNotify(saved.radius.round(), de.placesYouNotified),
    );

    // SIC-058: delete it for everybody.
    await tap(tester, row);
    await waitFor(tester, find.text(de.placesEditPlace));
    // Dragging on the map moves the map: the form's list goes to its end.
    final form = tester.state<ScrollableState>(
      find
          .ancestor(
            of: find.text(de.placesMyPosition),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    for (
      var i = 0;
      i < 5 && find.text(de.placesDeletePlace).evaluate().isEmpty;
      i++
    ) {
      form.position.jumpTo(form.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tap(tester, find.text(de.placesDeletePlace));
    await waitFor(tester, find.text(de.commonDeleteName('E2E Schule')));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonDelete)),
    );
    await waitGone(tester, row);
    await eventually(
      tester,
      'gone for Bea',
      () async => await school() == null,
    );
    // "Bin unterwegs" does not offer it any more.
    await back(tester);
    await tap(tester, find.text(de.tripStart));
    await waitFor(tester, find.text(de.tripTitle));
    await tap(
      tester,
      find.ancestor(
        of: find.text(de.tripPlace),
        matching: find.byType(DropdownButtonFormField<Place>),
      ),
    );
    await waitFor(tester, find.text('E2E Zuhause'));
    expect(find.text('E2E Schule'), findsNothing);
    await tap(tester, find.text('E2E Zuhause').last);
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    await finish(tester, state);
  });

  testWidgets('SIC-067 how long the way is kept', (tester) async {
    await prepare();
    final api = await admin();
    addTearDown(() async {
      await (await admin()).updateServerSettings({'locationHistoryDays': null});
    });
    final child = await member(
      'e2e-ortkind',
      'E2E Ortkind',
      role: MemberRole.child,
      fresh: true,
    );
    final grandma = Place(
      id: uid('place'),
      name: 'E2E Oma',
      latitude: 50.3,
      longitude: 8.8,
      notifyMemberIds: [await adminId()],
    );
    await putOk(api, Collections.places, {grandma.id: grandma.toData()});
    addTearDown(
      () async => remove(await admin(), Collections.places, [grandma.id]),
    );
    final phone = await login('e2e-ortkind');
    final now = DateTime.now();
    final fourDays = now.subtract(const Duration(days: 4));
    await phone.reportLocation([
      LocationFix(latitude: 50.3, longitude: 8.8, accuracy: 10, at: fourDays),
      LocationFix(
        latitude: 50.4,
        longitude: 8.95,
        accuracy: 10,
        at: fourDays.add(const Duration(hours: 1)),
      ),
      LocationFix(
        latitude: 50.4,
        longitude: 8.96,
        accuracy: 10,
        at: now.subtract(const Duration(days: 1)),
      ),
      LocationFix(latitude: 50.4, longitude: 8.97, accuracy: 10, at: now),
    ]);
    final cutoff = now.subtract(const Duration(days: 2));
    Future<List<LocationFix>> way() => api.locationHistory(
      memberId: child.id,
      from: now.subtract(const Duration(days: 6)),
      to: DateTime.now(),
    );
    Future<List<LocationAlert>> notices() async => [
      for (final r in (await pull(api, Collections.locationAlerts)).values)
        if (LocationAlert.fromRecord(r) case final a
            when a.memberId == child.id)
          a,
    ];
    expect((await way()).where((p) => p.at.isBefore(cutoff)), isNotEmpty);
    expect((await notices()).where((a) => a.at.isBefore(cutoff)), isNotEmpty);

    final state = await start(tester);
    await openAdmin(tester, de.sectionSettings);
    final days = field('Standortverlauf (Tage)');
    await scrollTo(tester, days);
    await enter(tester, days, '2');
    await saveSettings(tester);
    await waitFor(tester, find.text(de.adminServerSettingsSaved));
    await eventually(
      tester,
      'older points gone',
      () async => (await way()).where((p) => p.at.isBefore(cutoff)).isEmpty,
    );
    expect(await way(), isNotEmpty);
    await eventually(
      tester,
      'older place notices gone',
      () async => (await notices()).where((a) => a.at.isBefore(cutoff)).isEmpty,
    );
    final last = MemberLocation.fromRecord(
      (await pull(api, Collections.memberLocations))[child.id]!,
    );
    expect(last.hasPosition, isTrue);
    for (final wrong in ['0', '400']) {
      await snackGone(tester);
      await scrollTo(tester, days);
      await enter(tester, days, wrong);
      await saveSettings(tester);
      await formError(tester, 'Standortverlauf: 1 bis 365 Tage');
    }
    expect((await api.adminOverview()).settings.locationHistoryDays, 2);
    // The history page offers seven days anyway (catalog note).
    await back(tester);
    await openSection(tester, 'Standort');
    await waitFor(tester, memberMenu('E2E Ortkind'));
    await fromMenu(tester, 'E2E Ortkind', de.pregnancyHistory);
    await waitFor(tester, find.text(de.historyNameLast7Days('E2E Ortkind')));
    expect(find.byType(ChoiceChip), findsNWidgets(7));
    await back(tester);
    await finish(tester, state);
  });

  // === notifications ========================================================

  testWidgets('SIC-072 own notifications on this computer', (tester) async {
    await prepare();
    final state = await start(tester);
    await openPushSettings(tester);
    expect(find.text(de.pushLongFamioRunningReports), findsOneWidget);
    final device = find.widgetWithText(SwitchListTile, de.pushDevice);
    final test = find.text(de.pushSendTest);
    await waitFor(tester, test);
    expect(tester.widget<SwitchListTile>(device).value, isTrue);
    await tap(tester, device);
    await waitGone(tester, test);
    expect(tester.widget<SwitchListTile>(device).value, isFalse);
    await tap(tester, device);
    await waitFor(tester, test);
    // The new connection settles first.
    await tester.pump(const Duration(seconds: 3));
    await tap(tester, test);
    await waitFor(tester, find.text(de.pushTestMessageItsWay));
    await eventually(
      tester,
      'the test message reaches this device',
      () async => shown.any((n) => n.tag == 'tada'),
    );
    expect(
      shown.firstWhere((n) => n.tag == 'tada').body,
      'Benachrichtigungen funktionieren 🎉',
    );
    await finish(tester, state);
  });

  testWidgets('SIC-080 quiet time', (tester) async {
    await prepare();
    final api = await admin();
    addTearDown(() async {
      await (await admin()).setQuietHours(const QuietHours());
    });
    await api.setQuietHours(const QuietHours());
    final proxy = _Proxy();
    await proxy.start();
    addTearDown(proxy.stop);
    final state = await start(tester, url: proxy.url);
    await openPushSettings(tester);
    final on = find.widgetWithText(SwitchListTile, de.pushTurnQuietTime);
    await scrollTo(tester, on);
    await tap(tester, on);
    await eventually(
      tester,
      'quiet time on',
      () async => (await api.quietHours()).enabled,
    );

    Future<void> time(String button, int hour, int minute) async {
      await scrollTo(tester, find.text(button));
      await tap(tester, find.text(button));
      await tap(tester, find.byTooltip('Zum Texteingabemodus wechseln'));
      final fields = inDialog(find.byType(TextField));
      await waitFor(tester, fields);
      await tester.enterText(fields.at(0), '$hour');
      await tester.pump();
      await tester.enterText(fields.at(1), minute.toString().padLeft(2, '0'));
      await tester.pump();
      await tap(tester, inDialog(find.text('OK')));
      await dialogClosed(tester);
    }

    await time(de.pushTime(QuietHours.format(21 * 60)), 21, 30);
    final from = de.pushTime(QuietHours.format(21 * 60 + 30));
    await waitFor(tester, find.text(from));
    await time(de.pushUntilTime(QuietHours.format(7 * 60)), 6, 45);
    final until = de.pushUntilTime(QuietHours.format(6 * 60 + 45));
    await waitFor(tester, find.text(until));
    final loud = find.widgetWithText(
      SwitchListTile,
      de.pushPlaceNotificationsLoudAnyway,
    );
    await scrollTo(tester, loud);
    expect(tester.widget<SwitchListTile>(loud).value, isTrue);
    await tap(tester, loud);
    // Another device of the same account.
    await eventually(tester, 'stored on the server', () async {
      final q = await api.quietHours();
      return q.enabled &&
          q.start == 21 * 60 + 30 &&
          q.end == 6 * 60 + 45 &&
          !q.placesLoud;
    });
    // Closed and opened again.
    await back(tester);
    await scrollTo(tester, find.text(de.settingsPush));
    await tap(tester, find.text(de.settingsPush));
    await scrollTo(tester, find.text(from));
    expect(find.text(until), findsOneWidget);
    expect(tester.widget<SwitchListTile>(on).value, isTrue);
    expect(tester.widget<SwitchListTile>(loud).value, isFalse);
    // Without the server a change springs back.
    await proxy.stop();
    await tap(tester, on);
    await waitFor(tester, find.byType(SnackBar));
    await eventually(
      tester,
      'the switch springs back',
      () async => tester.widget<SwitchListTile>(on).value,
    );
    expect((await api.quietHours()).enabled, isTrue);
    await finish(tester, state);
  });

  testWidgets('SIC-077 SIC-076 SIC-078 ntfy devices', (tester) async {
    await prepare();
    final api = await admin();
    final state = await start(tester);
    await openPushSettings(tester);
    await scrollTo(tester, find.text(de.pushAddDevice));
    await tap(tester, find.text(de.pushAddDevice));
    final url = field(de.pushNtfyTopicAddress);
    await waitFor(tester, url);

    Future<void> add(String address, String password) async {
      await enter(tester, url, address);
      await leaveField(tester);
      await tap(tester, find.widgetWithText(FilledButton, de.pushAddTest));
      await confirmPassword(tester, password);
    }

    // SIC-077: a wrong password.
    await add('https://ntfy.invalid/famio-e2e-falsch', 'falsch-falsch-1');
    await waitFor(tester, inDialog(find.text('Passwort falsch')));
    expect(await api.pushTargets(), isEmpty);
    // SIC-076: no topic, not https, private network.
    await add('https://ntfy.sh', kitPassword);
    await waitFor(
      tester,
      inDialog(
        find.text(
          'Bitte die HTTPS-Adresse des ntfy-Themas angeben, z. B. https://ntfy.sh/famio-geheimer-name',
        ),
      ),
    );
    await add('http://192.168.1.5/famio-test', kitPassword);
    await waitFor(
      tester,
      inDialog(
        find.text(
          'Externe Ziele brauchen eine HTTPS-Adresse ohne Zugangsdaten in der Adresse.',
        ),
      ),
    );
    await add('https://192.168.1.5/famio-test', kitPassword);
    await waitFor(
      tester,
      inDialog(find.textContaining('zeigt in ein privates Netzwerk')),
    );
    expect(await api.pushTargets(), isEmpty);

    // SIC-078: an address nobody answers: added with an error, test, remove.
    await add('https://ntfy.invalid/famio-x', kitPassword);
    await dialogClosed(tester);
    await waitFor(
      tester,
      find.text(de.pushAddedButError('Push-Server nicht erreichbar')),
    );
    final row = tile(
      de.commonPhone,
      where: (t) => subtitleOf(t)?.contains('ntfy.invalid') ?? false,
    );
    await scrollTo(tester, row);
    expect(
      subtitleOf(tester.widget<ListTile>(row)),
      contains('Push-Server nicht erreichbar'),
    );
    expect(
      (tester.widget<ListTile>(row).leading! as Icon).icon,
      AppIcons.warningCircle,
    );
    await snackGone(tester);
    await tap(
      tester,
      find.descendant(of: row, matching: find.byTooltip(de.pushSendTest)),
    );
    await waitFor(
      tester,
      find.widgetWithText(SnackBar, 'Push-Server nicht erreichbar'),
    );
    await tap(
      tester,
      find.descendant(of: row, matching: find.byTooltip(de.commonRemove)),
    );
    expect(find.byType(AlertDialog), findsNothing);
    await waitGone(tester, row);
    expect(await api.pushTargets(), isEmpty);
    await finish(tester, state);
  });

  testWidgets('SIC-085 a sign-in on another device is told', (tester) async {
    await prepare();
    await member('e2e-anmeldung', 'E2E Anmeldung', fresh: true);
    final state = await start(tester, user: 'e2e-anmeldung', password: _strong);
    final mine = state.engine!.api;
    // The very first sign-in of the account: nothing.
    await tester.pump(const Duration(seconds: 2));
    bool signIn(Notice n) => n.title == 'Neue Anmeldung bei Famio';
    expect((await mine.notices(after: 0)).notices.where(signIn), isEmpty);
    expect(shown.where(signIn), isEmpty);
    await login('e2e-anmeldung', device: 'E2E Laptop');
    final told = await noticeFor(tester, mine, 0, signIn, 'sign-in notice');
    expect(told.body, contains('Angemeldet auf: E2E Laptop'));
    expect(told.body, contains('Warst du das nicht?'));
    // This device shows it, also in front.
    await eventually(tester, 'shown here', () async => shown.any(signIn));
    await finish(tester, state);
  });

  // === administration: members ===============================================

  testWidgets('SIC-087 only admins reach the administration', (tester) async {
    final s = await prepare();
    final bea = await sessionOf(s.f.bea);
    await expectLater(
      bea.adminUsers(),
      throwsA(apiError('Nur für Administratoren', status: 403)),
    );
    final state = await start(tester, user: 'e2e-bea');
    await openSection(tester, 'Einstellungen');
    await waitFor(tester, find.text(de.settingsChangePassword));
    expect(find.text(de.settingsServerAdministration), findsNothing);
    await scrollTo(tester, find.text(de.settingsFamily));
    expect(find.text(de.settingsServerAdministration), findsNothing);
    await finish(tester, state);
  });

  testWidgets(
    'SIC-088 SIC-089 SIC-090 SIC-091 adding a member; roles; the list',
    (tester) async {
      await prepare();
      final api = await admin();
      for (final u in await api.adminUsers()) {
        if (u.member.username == 'e2e.juergen') {
          await api.deleteMember(u.member.id);
        }
      }
      addTearDown(() async {
        for (final u in await (await admin()).adminUsers()) {
          if (u.member.username == 'e2e.juergen') {
            await (await admin()).deleteMember(u.member.id);
          }
        }
      });
      // A member with two-factor login, for its badge.
      await member('e2e-zwei', 'E2E Zwei', fresh: true);
      final two = await login('e2e-zwei');
      final secret = (await two.beginTotp(password: _strong)).secret;
      await two.confirmTotp(_totp(secret));

      final state = await start(tester);
      await openAdmin(tester, 'Benutzer');
      // SIC-091: the badges.
      for (final (name, badge) in [
        (kitAdminName, de.settingsAdministrator),
        ('E2E Kind', MemberRole.child.label),
        ('E2E Gast', MemberRole.guest.label),
        ('E2E Dienst', MemberRole.service.label),
        ('E2E Zwei', de.adminTwoFactor2),
      ]) {
        await scrollTo(tester, exactly(name));
        expect(
          find.descendant(of: cardOf(name), matching: find.text(badge)),
          findsOneWidget,
          reason: '$name: $badge',
        );
      }
      await scrollTo(tester, exactly(kitAdminName), up: true);
      final line = find.textContaining('@$kitUser · ');
      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).data, contains(' · aktiv '));

      // SIC-088: the login name follows the name.
      await tap(tester, find.byTooltip(de.adminAddMember));
      await tap(tester, find.text(de.adminCreateDirectly));
      await waitFor(tester, find.text(de.adminAddFamilyMember));
      await enter(tester, field(de.commonName), 'E2E Jürgen');
      final username = field(de.adminUsernameSigning);
      expect(
        tester.widget<TextField>(username).controller!.text,
        'e2e.juergen',
      );

      // SIC-090: every role explains itself; no admin guests or services.
      final adminSwitch = find.widgetWithText(
        SwitchListTile,
        de.settingsAdministrator,
      );
      for (final (role, help, mayAdmin) in [
        (MemberRole.adult, de.adminSeesManagesEverythingShared, true),
        (MemberRole.child, de.adminCollectsPointsPocketMoney, true),
        (MemberRole.guest, de.adminEGGrandparentsBabysitter, false),
        (MemberRole.service, de.adminHomeAssistantOtherConnections, false),
      ]) {
        await tap(tester, find.widgetWithText(ChoiceChip, role.label));
        await waitFor(tester, find.text(help));
        expect(
          tester.widget<SwitchListTile>(adminSwitch).onChanged != null,
          mayAdmin,
          reason: role.name,
        );
      }
      await tap(
        tester,
        find.widgetWithText(ChoiceChip, MemberRole.child.label),
      );

      // SIC-089: taken name, bad characters, short and easy passwords.
      final password = field(de.adminInitialPasswordMin8);
      await enter(tester, username, 'e2e-bea');
      await enter(tester, password, 'Kreide-Ofen-Birke-38');
      await tap(tester, find.widgetWithText(FilledButton, de.commonSave));
      await waitFor(tester, inDialog(find.text('Benutzername ist vergeben')));
      await enter(tester, username, 'e2e jürgen!');
      await waitFor(tester, find.text(de.usernamesOnlyLettersWithoutUmlauts));
      await enter(tester, username, 'e2e.juergen');
      await waitGone(
        tester,
        find.text(de.usernamesOnlyLettersWithoutUmlauts),
        timeout: const Duration(seconds: 5),
      );
      await enter(tester, password, 'abcde');
      await tap(tester, find.widgetWithText(FilledButton, de.commonSave));
      await waitFor(
        tester,
        inDialog(find.text('Das Passwort muss mindestens 8 Zeichen haben')),
      );
      await enter(tester, password, 'passwort1');
      await tap(tester, find.widgetWithText(FilledButton, de.commonSave));
      await waitFor(
        tester,
        inDialog(find.textContaining('zu leicht zu erraten')),
      );
      expect(find.text(de.adminAddFamilyMember), findsOneWidget);
      await enter(tester, password, 'Kreide-Ofen-Birke-38');
      await submit(tester, de.commonSave);
      await dialogClosed(tester);
      await scrollTo(tester, exactly('E2E Jürgen'));
      expect(
        find.descendant(
          of: cardOf('E2E Jürgen'),
          matching: find.text(MemberRole.child.label),
        ),
        findsOneWidget,
      );
      final juergen = await login(
        'e2e.juergen',
        password: 'Kreide-Ofen-Birke-38',
      );
      expect((await juergen.me()).role, MemberRole.child);

      // SIC-090: the server agrees.
      await expectLater(
        api.createMember(
          username: 'e2e-gastadmin',
          displayName: 'E2E Gastadmin',
          password: _strong,
          role: MemberRole.guest,
          isAdmin: true,
        ),
        throwsA(apiError('Gäste können keine Administratoren sein')),
      );
      await expectLater(
        api.createMember(
          username: 'e2e-dienstadmin',
          displayName: 'E2E Dienstadmin',
          password: _strong,
          role: MemberRole.service,
          isAdmin: true,
        ),
        throwsA(apiError('Dienstkonten können keine Administratoren sein')),
      );
      await finish(tester, state);
    },
  );

  testWidgets('SIC-092 editing a member', (tester) async {
    final s = await prepare();
    final m = await member('e2e-edit', 'E2E Edit', fresh: true);
    final api = await admin();
    final state = await start(tester);
    await openUser(tester, 'E2E Edit');
    await tap(tester, find.byTooltip(de.commonEdit));
    await waitFor(tester, find.text(de.adminEditMember));
    await enter(tester, field(de.settingsDisplayName), 'E2E Edith');
    await enter(tester, field(de.commonUsername), 'e2e-edith');
    final color = famioPalette[3];
    await tap(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is AnimatedContainer &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == Color(color),
      ),
    );
    await tap(tester, find.text(de.birthdayChooseBirthday));
    await pickDate(tester, DateTime(1985, 6, 12));
    await waitFor(tester, find.text('12. Juni 1985'));
    await submit(tester, de.commonSave);
    await dialogClosed(tester);
    await waitFor(tester, find.text('@e2e-edith'));
    final edited = (await api.adminUsers())
        .firstWhere((u) => u.member.id == m.id)
        .member;
    expect(edited.displayName, 'E2E Edith');
    expect(edited.username, 'e2e-edith');
    expect(edited.color, color);
    expect(
      (edited.birthday?.year, edited.birthday?.month, edited.birthday?.day),
      (1985, 6, 12),
    );
    // Other apps get it.
    final seen = (await (await sessionOf(
      s.f.bea,
    )).members()).firstWhere((x) => x.id == m.id);
    expect(seen.displayName, 'E2E Edith');
    await eventually(
      tester,
      'this app has the new name',
      () async => state.engine!.member(m.id)?.displayName == 'E2E Edith',
    );
    // A birthday the server cannot read is turned down.
    for (final wrong in ['12.6.1985', '1985-13-01', '1985-06-32']) {
      expect(
        await rawStatus(api, 'PATCH', 'api/admin/users/${m.id}', {
          'birthday': wrong,
        }),
        400,
        reason: wrong,
      );
    }
    await finish(tester, state);
  });

  // „1985-02-30“ wird als Geburtstag abgelehnt: Birthday.tryParse prüft den
  // Tag gegen den Monat (29. Februar nur im Schaltjahr oder ohne Jahr).
  testWidgets('SIC-092 an impossible birthday (30 February) is turned down', (
    tester,
  ) async {
    await prepare();
    final m = await member('e2e-edit2', 'E2E Edit Zwei', fresh: true);
    final api = await admin();
    final state = await start(tester);
    expect(
      await rawStatus(api, 'PATCH', 'api/admin/users/${m.id}', {
        'birthday': '1985-02-30',
      }),
      400,
    );
    await finish(tester, state);
  });

  /// A member signed in on this device with documents, a child, a booking
  /// and a medicine; then the admin makes them a guest.
  Future<({AppState state, List<String> Function() left})> demote(
    WidgetTester tester,
    String username,
  ) async {
    await prepare();
    final api = await admin();
    final m = await member(username, 'E2E Rolle', fresh: true);
    final ref = await api.uploadFile(
      bytes: utf8.encode('E2E Rolle'),
      name: 'e2e-rolle.txt',
      mime: 'text/plain',
    );
    final doc = uid('doc');
    final child = uid('child');
    final booking = uid('budget');
    await putOk(api, Collections.documents, {
      doc: FamilyDocument(
        id: doc,
        title: 'E2E Rollen-Dokument',
        category: DocumentCategory.other,
        file: ref,
      ).toData(),
    });
    await putOk(api, Collections.children, {
      child: Child(
        id: child,
        name: 'E2E Rollenkind',
        birthDate: DateTime(2020, 3, 4),
        guardianIds: [await adminId(), m.id],
      ).toData(),
    });
    await putOk(api, Collections.budgetEntries, {
      booking: BudgetEntry(
        id: booking,
        date: today(),
        cents: 1234,
        category: 'E2E Test',
      ).toData(),
    });
    final medicine = uid('medication');
    await putOk(api, Collections.medications, {
      medicine: Medication(
        id: medicine,
        name: 'E2E Rollen-Tropfen',
        start: today(),
      ).toData(),
    });
    addTearDown(() async {
      await remove(await admin(), Collections.medications, [medicine]);
      await remove(await admin(), Collections.documents, [doc]);
      await remove(await admin(), Collections.children, [child]);
      await remove(await admin(), Collections.budgetEntries, [booking]);
    });
    final state = await start(tester, user: username, password: _strong);
    final engine = state.engine!;
    final mine = [
      (Collections.documents, doc),
      (Collections.children, child),
      (Collections.budgetEntries, booking),
      (Collections.medications, medicine),
    ];
    List<String> left() => [
      for (final (c, id) in mine)
        if (engine.records(c).any((r) => r.id == id)) c,
    ];
    await eventually(
      tester,
      'the adult has everything',
      () async => left().length == mine.length,
    );
    for (final a in _roleAreas) {
      expect(nav(a), findsWidgets, reason: a);
    }
    await api.updateUser(m.id, role: MemberRole.guest);
    await eventually(
      tester,
      'the device knows the new role',
      () async => state.me?.role == MemberRole.guest,
    );
    // The server gives the member none of it any more.
    final asGuest = await login(username);
    for (final (c, id) in mine) {
      expect((await pull(asGuest, c)).keys, isNot(contains(id)), reason: c);
    }
    return (state: state, left: left);
  }

  testWidgets('SIC-095 a new role: the areas go, the data with the next sync', (
    tester,
  ) async {
    final (:state, :left) = await demote(tester, 'e2e-rolle');
    // At once: the guest's menu has no documents, children, location.
    for (final a in ['Dokumente', 'Kinder', 'Standort']) {
      await waitGone(tester, nav(a));
    }
    await tester.pump(const Duration(seconds: 3));
    debugPrint(
      'E2E new role, before the next sync: still shown '
      '${[for (final a in _roleAreas)
        for (final e in nav(a).evaluate()) '$a (${e.widget.runtimeType}, '
              '${e.findAncestorWidgetOfExactType<SoftCard>() != null ? 'tile' : 'menu'})']}, still on the device ${left()}',
    );
    // Anything that changes in the family makes the device sync: then it
    // lets go of what the guest may not have.
    final api = await admin();
    final note = uid('note');
    await putOk(api, Collections.notes, {
      note: FamilyNote(id: note, title: 'E2E Anstoß').toData(),
    });
    addTearDown(() async => remove(await admin(), Collections.notes, [note]));
    await eventually(
      tester,
      'the data is gone after the next sync',
      () async => left().isEmpty,
    );
    for (final a in _roleAreas) {
      await waitGone(tester, nav(a));
    }
    await finish(tester, state);
  });

  // Nach dem Rollenwechsel zum Gast verschwinden Dokumente, Kinder,
  // Buchungen und Medikamente sofort vom Gerät (#535): Auf den Hinweis
  // „members“ lädt die App die Mitglieder neu und gleicht ab, wenn sich die
  // eigene Rolle geändert hat; der Server bemerkt den neuen
  // Berechtigungsumfang und schickt alles neu, der Rest wird entfernt.
  testWidgets(
    'SIC-095 the data goes with the new role, without another change',
    (tester) async {
      final (:state, :left) = await demote(tester, 'e2e-rolle2');
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(end) && left().isNotEmpty) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(left(), isEmpty, reason: 'still on the device after 60 s');
      await finish(tester, state);
    },
  );

  testWidgets('SIC-096 giving and taking admin rights', (tester) async {
    final s = await prepare();
    final f = s.f;
    final bea = await sessionOf(f.bea);
    addTearDown(() async {
      await (await admin()).updateUser(f.bea.id, isAdmin: false);
    });
    final state = await start(tester);
    await openUser(tester, 'E2E Bea');
    final sw = find.widgetWithText(SwitchListTile, de.settingsAdministrator);
    await scrollTo(tester, sw);
    await tap(tester, sw);
    await waitFor(tester, find.text(de.adminMakeAdminTitle('E2E Bea')));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.adminMakeAdminAction)),
    );
    await eventually(tester, 'Bea is admin', () async {
      try {
        await bea.adminUsers();
        return true;
      } on ApiError {
        return false;
      }
    });
    expect((await bea.me()).isAdmin, isTrue);
    final invite = await bea.createInvite(
      role: MemberRole.guest,
      displayName: 'E2E Beas Gast',
    );
    await scrollTo(tester, sw);
    await tap(tester, sw);
    await waitFor(tester, find.text(de.adminTakeAdminTitle('E2E Bea')));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.adminTakeAdminAction)),
    );
    await eventually(tester, 'Bea is no admin', () async {
      try {
        await bea.adminUsers();
        return false;
      } on ApiError catch (e) {
        return e.status == 403;
      }
    });
    expect((await bea.me()).isAdmin, isFalse);
    // Her open invitation ended with it.
    await expectLater(
      FamioApiClient(kitUrl).checkInvite(invite.code!),
      throwsA(
        apiError('Diese Einladung gibt es nicht oder sie ist abgelaufen.'),
      ),
    );
    await finish(tester, state);
  });

  testWidgets('SIC-099 an admin sets a new password for a member', (
    tester,
  ) async {
    await prepare();
    await member(
      'e2e-pwkind',
      'E2E Pwkind',
      role: MemberRole.child,
      fresh: true,
    );
    final tablet = await login('e2e-pwkind', device: 'E2E Tablet');
    final phone = await login('e2e-pwkind', device: 'E2E Handy');
    final (_, secret) = await tablet.createAppPassword(
      name: 'E2E Kalender',
      password: _strong,
    );
    expect(await davStatus('e2e-pwkind', secret), 207);
    final state = await start(tester);
    await openUser(tester, 'E2E Pwkind');
    await scrollTo(tester, find.text(de.adminResetPassword));
    await tap(tester, find.text(de.adminResetPassword));
    await waitFor(tester, find.text(de.adminNewPasswordName('E2E Pwkind')));
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, de.adminSignOutAllDevices),
          )
          .value,
      isTrue,
    );
    await enter(tester, field(de.settingsNewPassword), 'Kreide-Ofen-Birke-38');
    await submit(tester, de.adminSet);
    await dialogClosed(tester);
    await waitFor(tester, find.textContaining('Passwort geändert, 2 '));
    expect(
      tester.widget<Text>(find.textContaining('Passwort geändert, 2 ')).data,
      endsWith(' abgemeldet'),
    );
    for (final s in [tablet, phone]) {
      await expectLater(
        s.members(),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
      );
    }
    await login('e2e-pwkind', password: 'Kreide-Ofen-Birke-38');
    expect(await davStatus('e2e-pwkind', secret), 401);
    await finish(tester, state);
  });

  testWidgets('SIC-101 resetting two-factor login', (tester) async {
    await prepare();
    await member('e2e-zf', 'E2E Zf', fresh: true);
    final zf = await login('e2e-zf');
    final secret = (await zf.beginTotp(password: _strong)).secret;
    await zf.confirmTotp(_totp(secret));
    await expectLater(login('e2e-zf'), throwsA(isA<TwoFactorRequired>()));
    final api = await admin();
    final me = await adminId();
    addTearDown(() async {
      final a = await admin();
      if ((await a.twoFactorStatus()).enabled) {
        await a.resetTwoFactor(me, password: kitPassword);
      }
    });
    final state = await start(tester);
    await openUser(tester, 'E2E Zf');
    await scrollTo(tester, find.text(de.adminTwoFactor));
    await tap(
      tester,
      find.descendant(
        of: tile(de.adminTwoFactor),
        matching: find.text(de.commonReset),
      ),
    );
    await waitFor(tester, find.text(de.adminResetTwoFactorName('E2E Zf')));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonReset)),
    );
    await waitFor(tester, find.text(de.adminTwoFactorReset));
    await waitFor(tester, find.text(de.adminTwoFactorOff));
    await login('e2e-zf');

    // The own account: with the password.
    final mine = (await api.beginTotp(password: kitPassword)).secret;
    await api.confirmTotp(_totp(mine));
    await back(tester);
    await tap(tester, find.byTooltip(de.commonRefresh));
    await scrollTo(tester, exactly(kitAdminName), up: true);
    await tap(tester, exactly(kitAdminName));
    await scrollTo(tester, find.text(de.adminTwoFactor));
    await tap(
      tester,
      find.descendant(
        of: tile(de.adminTwoFactor),
        matching: find.text(de.commonReset),
      ),
    );
    await waitFor(tester, find.text(de.adminResetTwoFactorName(kitAdminName)));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonReset)),
    );
    await confirmPassword(tester, kitPassword);
    await waitFor(tester, find.text(de.adminTwoFactorReset));
    expect((await api.twoFactorStatus()).enabled, isFalse);
    await finish(tester, state);
  });

  testWidgets('SIC-102 SIC-103 signing a member out: one device, everywhere', (
    tester,
  ) async {
    await prepare();
    await member('e2e-abm', 'E2E Abm', role: MemberRole.child, fresh: true);
    final tablet = await login('e2e-abm', device: 'E2E Tablet');
    final phone = await login('e2e-abm', device: 'E2E Handy');
    final (_, calendar) = await tablet.createAppPassword(
      name: 'E2E Kalender',
      password: _strong,
    );
    final state = await start(tester);
    await openUser(tester, 'E2E Abm');
    await scrollTo(tester, find.text(de.adminDevicesCount(2)));

    // SIC-103: a single device.
    final handy = find.byWidgetPredicate(
      (w) => w is DeviceTile && w.session.device == 'E2E Handy',
    );
    await scrollTo(tester, handy);
    await tap(
      tester,
      find.descendant(of: handy, matching: find.byTooltip(de.settingsSignOut)),
    );
    await waitFor(tester, find.text(de.adminDevicesCount(1)));
    expect(handy, findsNothing);
    await expectLater(
      phone.members(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    await tablet.members();

    // SIC-102: everywhere.
    await tap(tester, find.text(de.adminSignOutEverywhere));
    await waitFor(tester, find.text(de.adminSignOutAllTitle('E2E Abm')));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.adminSignOutEverywhere)),
    );
    await waitFor(tester, find.text(de.adminNameWasSignedOut('E2E Abm')));
    await waitFor(tester, find.text(de.adminNotSignedAnyDevice));
    await expectLater(
      tablet.members(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    // The catalog's note: the calendar app keeps working.
    expect(await davStatus('e2e-abm', calendar), 207);
    await finish(tester, state);
  });

  testWidgets('SIC-102 an open app of the member goes to the sign-in', (
    tester,
  ) async {
    await prepare();
    final m = await member(
      'e2e-abm2',
      'E2E Abm Zwei',
      role: MemberRole.child,
      fresh: true,
    );
    final state = await start(tester, user: 'e2e-abm2', password: _strong);
    // A window is open: the check-in sheet.
    await tap(tester, find.text(de.sosCheckAllOkay));
    await waitFor(tester, find.byType(BottomSheet));
    await (await admin()).signOutUser(m.id);
    // Without anything else happening in the family (the app keeps its
    // connection).
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end) && state.me != null) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    debugPrint(
      'E2E signed out everywhere: the open app noticed within 20 s: '
      '${state.me == null}',
    );
    // With the next sync (anything that changes in the family) at least.
    final note = uid('note');
    await putOk(await admin(), Collections.notes, {
      note: FamilyNote(id: note, title: 'E2E Anstoß Abmelden').toData(),
    });
    addTearDown(() async => remove(await admin(), Collections.notes, [note]));
    await eventually(
      tester,
      'the app is signed out',
      () async => state.me == null,
    );
    await waitFor(tester, find.text(de.appSessionHasExpiredPlease));
    await waitFor(tester, field('Server-Adresse'));
    expect(find.byType(BottomSheet), findsNothing);
    await finish(tester, state);
  });

  testWidgets('SIC-104 removing a member', (tester) async {
    await prepare();
    final api = await admin();
    final gone = await member(
      'e2e-weg',
      'E2E Weg',
      role: MemberRole.child,
      fresh: true,
    );
    final w = await login('e2e-weg');
    final note = uid('note');
    // Own prefixes: two calls of uid() may fall in the same microsecond.
    final family = uid('task-family');
    final private = uid('task-private');
    final photo = await w.uploadFile(
      bytes: utf8.encode('E2E Foto Weg'),
      name: 'e2e-weg.png',
      mime: 'image/png',
    );
    await putOk(w, Collections.notes, {
      note: FamilyNote(
        id: note,
        title: 'E2E Geheimnis Weg',
        visibleTo: [gone.id],
      ).toData(),
    });
    await putOk(w, Collections.tasks, {
      family: Task(id: family, title: 'E2E Familienaufgabe Weg').toData(),
      private: Task(
        id: private,
        title: 'E2E Privat Weg',
        visibleTo: [gone.id],
        photos: [photo],
      ).toData(),
    });
    addTearDown(() async => remove(await admin(), Collections.tasks, [family]));
    Future<Map<String, List<int>>> exported() async => _unzip(
      Uint8List.fromList(
        await api.exportData(password: kitPassword, family: true),
      ),
    );
    Future<String> everything() async =>
        _unzip(
              Uint8List.fromList(
                await api.exportData(password: kitPassword, family: true),
              ),
            ).entries
            .where((e) => e.key.startsWith('records/'))
            .map((e) => utf8.decode(e.value))
            .join('\n');
    final before = await everything();
    expect(before, contains('E2E Geheimnis Weg'));
    expect(before, contains('E2E Privat Weg'));
    expect(before, contains('E2E Familienaufgabe Weg'));

    final state = await start(tester);
    await openUser(tester, 'E2E Weg');
    final entry = find.text(de.adminRemoveName('E2E Weg'));
    await scrollTo(tester, entry);
    await tap(tester, entry);
    await waitFor(tester, find.text('E2E Weg entfernen?'));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonRemove)),
    );
    await waitGone(tester, find.text(de.adminRole));
    await waitGone(tester, exactly('E2E Weg'));
    await expectLater(
      w.members(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    expect(
      (await api.adminUsers()).map((u) => u.member.username),
      isNot(contains('e2e-weg')),
    );
    final after = await everything();
    expect(after, isNot(contains('E2E Geheimnis Weg')));
    expect(after, isNot(contains('E2E Privat Weg')));
    expect(after, contains('E2E Familienaufgabe Weg'));
    // The photo of the private task: no record refers to it any more; the
    // file maintenance removes unreferenced uploads only after a day.
    expect(after, isNot(contains(photo.id)));
    debugPrint(
      'E2E removed member\'s photo still stored: '
      '${(await exported()).keys.any((k) => k.startsWith('files/${photo.id}'))}',
    );
    expect((await pull(api, Collections.tasks)).keys, contains(family));
    await finish(tester, state);
  });

  testWidgets('SIC-097 SIC-100 SIC-104 the own account in the administration', (
    tester,
  ) async {
    await prepare();
    final api = await admin();
    final me = await adminId();
    // The only admin.
    for (final u in await api.adminUsers()) {
      if (u.member.isAdmin && u.member.id != me) {
        await api.updateUser(u.member.id, isAdmin: false);
      }
    }
    final state = await start(tester);
    await openUser(tester, kitAdminName);

    // SIC-100: the own password only with the current one.
    await scrollTo(tester, find.text(de.adminResetPassword));
    await tap(tester, find.text(de.adminResetPassword));
    await waitFor(tester, inDialog(find.text(de.settingsChangePassword)));
    expect(field(de.settingsCurrentPassword), findsOneWidget);
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    await expectLater(
      api.resetPassword(me, 'Kreide-Ofen-Birke-38'),
      throwsA(
        apiError(
          'Dein eigenes Passwort änderst du in den Einstellungen.',
          status: 403,
        ),
      ),
    );

    // SIC-104: no way to remove oneself.
    await scrollTo(tester, find.byType(DeviceTile).last);
    expect(find.text(de.adminRemoveName(kitAdminName)), findsNothing);
    await expectLater(
      api.deleteMember(me),
      throwsA(apiError('Du kannst dich nicht selbst löschen')),
    );

    // SIC-097: the last admin keeps the rights.
    final sw = find.widgetWithText(SwitchListTile, de.settingsAdministrator);
    await scrollTo(tester, sw, up: true);
    await tap(tester, sw);
    await waitFor(tester, find.text(de.adminTakeOwnAdminTitle));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.adminTakeAdminAction)),
    );
    await confirmPassword(tester, kitPassword);
    await waitFor(
      tester,
      find.text('Es muss mindestens einen Administrator geben'),
    );
    expect((await api.me()).isAdmin, isTrue);
    await finish(tester, state);
  });

  // === invitations ==========================================================

  testWidgets('SIC-105 SIC-107 creating and withdrawing an invitation', (
    tester,
  ) async {
    await prepare();
    final api = await admin();
    final state = await start(tester);
    await openAdmin(tester, 'Benutzer');
    await tap(tester, find.byTooltip(de.adminAddMember));
    await tap(tester, find.text(de.adminInviteQrCodeLink));
    await waitFor(tester, find.text(de.inviteCreateInvitation));
    final roles = find.byType(SegmentedButton<MemberRole>);
    for (final r in [MemberRole.adult, MemberRole.child, MemberRole.guest]) {
      expect(
        find.descendant(of: roles, matching: find.text(r.label)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: roles, matching: find.text(MemberRole.service.label)),
      findsNothing,
    );
    await enter(tester, field(de.inviteNameSuggestion), 'E2E Neffe');
    await tap(
      tester,
      find.descendant(of: roles, matching: find.text(MemberRole.child.label)),
    );
    await tap(tester, find.text(de.inviteCreateInvitation));
    await waitFor(tester, find.byType(QrImageView));
    await waitFor(tester, find.textContaining('Kind · gültig bis '));
    final open = (await api.openInvites()).where(
      (i) => i.displayName == 'E2E Neffe',
    );
    expect(open, hasLength(1));
    final invite = open.single;
    expect(invite.role, MemberRole.child);
    expect(
      invite.expiresAt.difference(DateTime.now()).inMinutes,
      inInclusiveRange(48 * 60 - 5, 48 * 60),
    );
    final code = tester
        .widget<SelectableText>(find.byType(SelectableText).first)
        .data!;

    // The text, read from the copy instead of the person's clipboard.
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    try {
      await tap(tester, find.text(de.inviteCopyInvitationText));
      await waitFor(tester, find.text(de.inviteCopied));
    } finally {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }
    expect(copied, contains(code));
    final row = tile(
      'E2E Neffe',
      where: (t) => subtitleOf(t)?.startsWith('Kind · bis ') ?? false,
    );
    await scrollTo(tester, find.text(de.inviteOpenInvitations));
    await scrollTo(tester, row);

    // SIC-107
    await tap(
      tester,
      find.descendant(of: row, matching: find.byTooltip(de.inviteWithdraw)),
    );
    await waitGone(tester, row);
    expect(
      (await api.openInvites()).where((i) => i.displayName == 'E2E Neffe'),
      isEmpty,
    );
    await expectLater(
      FamioApiClient(
        kitUrl,
      ).redeemInvite(code: code, username: 'e2e-neffe', password: _strong),
      throwsA(
        apiError('Diese Einladung gibt es nicht oder sie ist abgelaufen.'),
      ),
    );
    await finish(tester, state);
  });

  testWidgets('SIC-106 joining with an invitation, once', (tester) async {
    await prepare();
    final api = await admin();
    for (final u in await api.adminUsers()) {
      if (u.member.username == 'e2e-oma') await api.deleteMember(u.member.id);
    }
    addTearDown(() async {
      for (final u in await (await admin()).adminUsers()) {
        if (u.member.username == 'e2e-oma') {
          await (await admin()).deleteMember(u.member.id);
        }
      }
    });
    final invite = await api.createInvite(
      role: MemberRole.guest,
      displayName: 'E2E Oma Inge',
    );
    await initializeDateFormatting('de');
    UrlLauncherPlatform.instance = launcher;
    await freshStart();
    final state = AppState();
    await state.init();
    addTearDown(() async {
      if (state.me != null) await state.signOut();
    });
    await tester.pumpWidget(FamioApp(state: state));
    await tap(tester, find.text(de.inviteJoin));
    await enter(tester, field(de.settingsServer), kitUrl);
    await enter(tester, field(de.commonCode), invite.code!);
    await tap(tester, find.text(de.commonNext));
    await waitFor(tester, find.text(de.inviteYouInvitedRole('Gast')));
    expect(
      tester.widget<TextField>(field(de.inviteName2)).controller!.text,
      'E2E Oma Inge',
    );
    await enter(tester, field(de.commonUsername), 'e2e-oma');
    await enter(tester, field(de.invitePasswordLeast8Characters), _strong);
    await tap(tester, find.text(de.inviteJoin2));
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    expect(state.me!.role, MemberRole.guest);
    expect(state.me!.username, 'e2e-oma');
    await expectLater(
      FamioApiClient(kitUrl).redeemInvite(
        code: invite.code!,
        username: 'e2e-oma2',
        password: _strong,
      ),
      throwsA(
        apiError('Diese Einladung gibt es nicht oder sie ist abgelaufen.'),
      ),
    );
    if (find.text(de.commonLater).evaluate().isNotEmpty) {
      await tap(tester, find.text(de.commonLater).last);
    }
    await finish(tester, state);
  });

  // === calendar apps (CalDAV) ===============================================

  testWidgets('SIC-138 SIC-141 app passwords for calendar apps', (
    tester,
  ) async {
    await prepare();
    final api = await admin();
    for (final p in await api.appPasswords()) {
      if (p.name == 'E2E iPad') await api.deleteAppPassword(p.id);
    }
    final state = await start(tester);
    await openSection(tester, 'Kalender');
    await tap(tester, find.byTooltip(de.calendarConnectGoogleAppleCalendar));
    await scrollTo(tester, find.text(de.calendarConnectCalendarAppsDirectly));
    await scrollTo(tester, find.text(de.caldavCreateAppPassword));
    await tap(tester, find.text(de.caldavCreateAppPassword));
    await waitFor(tester, find.text(de.caldavNewAppPassword));
    await enter(tester, field(de.caldavWhichDevice), 'E2E iPad');
    // A wrong password makes none.
    await leaveField(tester);
    await tap(tester, find.widgetWithText(FilledButton, de.commonCreate));
    await confirmPassword(tester, 'falsch-falsch-1');
    await waitFor(tester, inDialog(find.text('Passwort falsch')));
    expect(
      (await api.appPasswords()).where((p) => p.name == 'E2E iPad'),
      isEmpty,
    );
    await leaveField(tester);
    await tap(tester, find.widgetWithText(FilledButton, de.commonCreate));
    await confirmPassword(tester, kitPassword);
    await waitFor(tester, find.text(de.caldavAppPassword));
    final secretBox = find.descendant(
      of: find.ancestor(
        of: find.text(de.caldavAppPassword),
        matching: find.byType(AlertDialog),
      ),
      matching: find.byType(SelectableText),
    );
    final secret = tester.widget<SelectableText>(secretBox).data!;
    expect(inDialog(find.text(de.commonCopy)), findsOneWidget);
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonDone)),
    );
    await dialogClosed(tester);
    final row = tile('E2E iPad');
    await scrollTo(tester, row);
    expect(subtitleOf(tester.widget<ListTile>(row)), de.caldavNotUsedYet);
    expect(find.text(secret), findsNothing);
    expect(await davStatus(kitUser, secret), 207);

    // SIC-141
    await tap(
      tester,
      find.descendant(of: row, matching: find.byTooltip(de.commonDisconnect)),
    );
    await waitFor(tester, find.text(de.caldavDisconnectName('E2E iPad')));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonDisconnect)),
    );
    await waitGone(tester, row);
    expect(await davStatus(kitUser, secret), 401);
    await finish(tester, state);
  });

  testWidgets('SIC-142 a new password ends app passwords and other devices', (
    tester,
  ) async {
    await prepare();
    await member('e2e-pwwechsel', 'E2E Pwwechsel', fresh: true);
    final other = await login('e2e-pwwechsel', device: 'E2E Zweitgerät');
    final (_, secret) = await other.createAppPassword(
      name: 'E2E Kalender',
      password: _strong,
    );
    expect(await davStatus('e2e-pwwechsel', secret), 207);
    final state = await start(tester, user: 'e2e-pwwechsel', password: _strong);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsChangePassword));
    await tap(tester, find.text(de.settingsChangePassword));
    await waitFor(tester, inDialog(find.text(de.settingsPasswordChangeNote)));
    await enter(tester, field(de.settingsCurrentPassword), 'falsch-wort-1');
    await enter(tester, field(de.settingsNewPassword), 'Kreide-Ofen-Birke-38');
    await tap(tester, find.widgetWithText(FilledButton, de.commonSave));
    await waitFor(tester, inDialog(find.text('Aktuelles Passwort falsch')));
    await enter(tester, field(de.settingsCurrentPassword), _strong);
    await submit(tester, de.commonSave);
    await dialogClosed(tester);
    expect(await davStatus('e2e-pwwechsel', secret), 401);
    await expectLater(
      other.members(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    await state.engine!.api.members();
    expect(state.me, isNotNull);
    await finish(tester, state);
  });

  // === roles ================================================================

  testWidgets('SIC-160 a service account is no family member', (tester) async {
    await prepare();
    final state = await start(tester);
    // Chat
    await openSection(tester, 'Chat');
    await waitFor(tester, exactly('E2E Bea'));
    expect(exactly('E2E Dienst'), findsNothing);
    // Wo ist wer?
    await openSection(tester, 'Standort');
    await waitFor(tester, exactly('E2E Bea'));
    expect(exactly('E2E Dienst'), findsNothing);
    // Who does a task
    await openSection(tester, 'Aufgaben');
    await tap(tester, find.byTooltip('Aufgabe mit Details anlegen'));
    await waitFor(tester, find.text('Neue Aufgabe'));
    await waitFor(tester, find.widgetWithText(FilterChip, 'E2E Bea'));
    expect(find.widgetWithText(FilterChip, 'E2E Dienst'), findsNothing);
    Navigator.of(tester.element(find.text('Neue Aufgabe'))).pop();
    await tester.pump(const Duration(milliseconds: 600));
    // Settings → Familie
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsFamily));
    await scrollTo(tester, exactly('E2E Kind Zwei'));
    expect(exactly('E2E Dienst'), findsNothing);
    // Only the administration shows it.
    await openAdmin(tester, 'Benutzer');
    await scrollTo(tester, exactly('E2E Dienst'));
    expect(
      find.descendant(
        of: cardOf('E2E Dienst'),
        matching: find.text(MemberRole.service.label),
      ),
      findsOneWidget,
    );
    await finish(tester, state);
  });

  // === family export ========================================================

  testWidgets('SIC-133 SIC-132 exporting the family', (tester) async {
    final s = await prepare();
    final f = s.f;
    final bea = await sessionOf(f.bea);
    final api = await admin();
    final note = uid('note');
    await putOk(bea, Collections.notes, {
      note: FamilyNote(
        id: note,
        title: 'E2E Beas Tagebuch',
        visibleTo: [f.bea.id],
      ).toData(),
    });
    addTearDown(() async => remove(bea, Collections.notes, [note]));
    final ref = await api.uploadFile(
      bytes: utf8.encode('E2E Anhang'),
      name: 'e2e-anhang.txt',
      mime: 'text/plain',
    );
    final kidAdmin = await member(
      'e2e-kindadmin',
      'E2E Kindadmin',
      role: MemberRole.child,
      isAdmin: true,
      fresh: true,
    );
    expect(kidAdmin.isAdmin, isTrue);
    final picker = fakePicker();
    final folder = Directory.systemTemp.createTempSync('famio-e2e-export');
    addTearDown(() => folder.deleteSync(recursive: true));
    picker.directory = folder.path;
    final beaFrom = await cursor(bea);

    final state = await start(tester);
    await openAdmin(tester, de.sectionSettings);
    final exportTile = tile(de.adminExportFamily);
    await scrollTo(tester, exportTile);
    await tap(
      tester,
      find.descendant(of: exportTile, matching: find.text(de.adminExport)),
    );
    await waitFor(tester, find.text(de.exportZipFileAllFamily));
    // SIC-133: a wrong password exports nothing.
    await enter(tester, field(de.exportFamioPassword), 'falsch-falsch-9');
    await tap(tester, find.widgetWithText(FilledButton, de.adminExport));
    await waitFor(tester, inDialog(find.text('Passwort falsch')));
    expect(folder.listSync(), isEmpty);
    // SIC-132
    await enter(tester, field(de.exportFamioPassword), kitPassword);
    await submit(tester, de.adminExport);
    await waitFor(
      tester,
      find.text(de.exportExportSaved),
      timeout: const Duration(seconds: 90),
    );
    final zip = folder.listSync().whereType<File>().single;
    expect(zip.path, endsWith('.zip'));
    final files = _unzip(zip.readAsBytesSync());
    expect(files.keys, containsAll(['members.json', 'settings.json']));
    expect(files.keys.where((k) => k.startsWith('location')), isEmpty);
    final members = utf8.decode(files['members.json']!);
    expect(members, contains('E2E Bea'));
    expect(members, isNot(contains('"password')));
    expect(
      utf8.decode(files['records/notes.json']!),
      contains('E2E Beas Tagebuch'),
    );
    expect(
      files.keys.where((k) => k.startsWith('files/${ref.id}')),
      hasLength(1),
    );
    await noticeFor(
      tester,
      bea,
      beaFrom,
      (n) => n.title == 'Daten der Familie exportiert',
      'Bea hears of the export',
    );
    // SIC-133: a child with admin rights may not.
    final kidApi = await login('e2e-kindadmin');
    await expectLater(
      kidApi.exportData(password: _strong, family: true),
      throwsA(apiError('Nur für Erwachsene', status: 403)),
    );
    await finish(tester, state);
  });

  // === areas switched off (server-wide, set back) ===========================

  testWidgets('SIC-117 switching "Finanzen" off and on', (tester) async {
    final s = await prepare();
    final bea = await sessionOf(s.f.bea);
    addTearDown(() async {
      await (await admin()).updateServerSettings({'hiddenModules': null});
    });
    final booking = uid('budget');
    await putOk(bea, Collections.budgetEntries, {
      booking: BudgetEntry(
        id: booking,
        date: today(),
        cents: 4711,
        category: 'E2E Test',
        note: 'E2E Buchung',
      ).toData(),
    });
    addTearDown(() async => remove(bea, Collections.budgetEntries, [booking]));
    final before = (await pull(bea, Collections.budgetEntries))[booking]!;
    final state = await start(tester);
    expect(nav(de.sectionBudget), findsWidgets);

    Future<void> switchArea(String area) async {
      await openAdmin(tester, de.sectionSettings);
      final row = tile(de.adminShowHideAreas);
      await scrollTo(tester, row);
      await tap(
        tester,
        find.descendant(of: row, matching: find.text(de.commonChange)),
      );
      await waitFor(tester, inDialog(find.text(de.adminAreas)));
      await tap(
        tester,
        inDialog(find.widgetWithText(SwitchListTile, area)).first,
      );
      await submit(tester, de.commonSave);
      await waitFor(tester, find.text(de.adminAreasSaved));
    }

    await switchArea(de.sectionBudget);
    final row = tile(de.adminShowHideAreas);
    await scrollTo(tester, row);
    expect(
      subtitleOf(tester.widget<ListTile>(row)),
      de.adminHiddenAreas(de.sectionBudget),
    );
    await eventually(
      tester,
      'gone in this app',
      () async => state.hiddenModules.contains('budget'),
    );
    expect(
      ((await bea.config())['hiddenModules'] as List?) ?? const [],
      contains('budget'),
    );
    await back(tester);
    await openSection(tester, 'Start');
    await waitGone(tester, nav(de.sectionBudget));
    expect(exactly(de.sectionBudget), findsNothing);

    await switchArea(de.sectionBudget);
    await scrollTo(tester, tile(de.adminShowHideAreas));
    expect(
      subtitleOf(tester.widget<ListTile>(tile(de.adminShowHideAreas))),
      de.adminAllAreasVisible,
    );
    await back(tester);
    await waitFor(tester, nav(de.sectionBudget));
    final after = (await pull(bea, Collections.budgetEntries))[booking]!;
    expect(after.data, before.data);
    await finish(tester, state);
  });

  testWidgets('SIC-069 switching "Standort" off', (tester) async {
    final s = await prepare();
    final f = s.f;
    addTearDown(() async {
      await (await admin()).updateServerSettings({'hiddenModules': null});
    });
    final kid = await sessionOf(f.kid);
    await kid.resumeLocation();
    await kid.reportLocation([
      LocationFix(
        latitude: 50.1,
        longitude: 8.6,
        accuracy: 20,
        battery: 55,
        at: DateTime.now(),
      ),
    ], device: 'E2E Handy');
    final bea = await sessionOf(f.bea);
    Future<MemberLocation?> where() async {
      final r = (await pull(bea, Collections.memberLocations))[f.kid.id];
      return r == null ? null : MemberLocation.fromRecord(r);
    }

    expect((await where())?.hasPosition, isTrue);
    final state = await start(tester);
    await openAdmin(tester, de.sectionSettings);
    final row = tile(de.adminShowHideAreas);
    await scrollTo(tester, row);
    await tap(
      tester,
      find.descendant(of: row, matching: find.text(de.commonChange)),
    );
    await waitFor(tester, inDialog(find.text(de.adminAreas)));
    await tap(
      tester,
      inDialog(find.widgetWithText(SwitchListTile, de.sectionLocation)).first,
    );
    await submit(tester, de.commonSave);
    await waitFor(tester, find.text(de.adminAreasSaved));
    await eventually(tester, 'nothing left to see', () async {
      final l = await where();
      return l != null &&
          l.state == SharingState.paused &&
          !l.hasPosition &&
          l.battery == null &&
          l.placeId == null;
    });
    // Phones pause.
    final answer = await kid.reportLocation([
      LocationFix(
        latitude: 50.1,
        longitude: 8.6,
        accuracy: 20,
        at: DateTime.now(),
      ),
    ]);
    expect(answer.paused, isTrue);
    expect((await where())?.hasPosition, isFalse);
    expect(
      ((await bea.config())['hiddenModules'] as List?) ?? const [],
      contains('location'),
    );
    await eventually(
      tester,
      'gone in this app',
      () async => state.hiddenModules.contains('location'),
    );
    await back(tester);
    await openSection(tester, 'Start');
    await waitGone(tester, nav(de.sectionLocation));
    // The start page's tile goes too.
    await waitGone(tester, find.text(de.homeWhoWhere));
    // The emergency button and check-ins go on.
    final id = await kid.raiseSos();
    await kid.sosResolve(id);
    await kid.checkIn('E2E trotzdem ok');
    await finish(tester, state);
  });

  // === own devices, then everything gone ====================================

  testWidgets('SIC-103 signing out the own other devices', (tester) async {
    await prepare();
    final extra = await kitAdminApi();
    final state = await start(tester);
    await openUser(tester, kitAdminName);
    await scrollTo(tester, find.text(de.adminSignOutOthers));
    await tap(tester, find.text(de.adminSignOutOthers));
    await waitFor(tester, find.text(de.adminSignOutOthersTitle));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.adminSignOutOthers)),
    );
    await waitFor(tester, find.text(de.adminSignedOutAllOther));
    await waitFor(tester, find.text(de.adminDevicesCount(1)));
    final here = find.byWidgetPredicate(
      (w) => w is DeviceTile && w.session.current,
    );
    await scrollTo(tester, here);
    expect(
      find.descendant(of: here, matching: find.byTooltip(de.settingsSignOut)),
      findsNothing,
    );
    await expectLater(
      extra.members(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    await state.engine!.api.members();
    expect(state.me, isNotNull);
    // The test's own admin session went with them.
    adminSession = null;
    await finish(tester, state);
  });

  testWidgets('SIC-135 deleting all data with the other members', (
    tester,
  ) async {
    expect(_allowWipe, 'yes', reason: 'only against a throwaway server');
    final s = await prepare();
    final f = s.f;
    final api = await admin();
    await api.updateUser(f.bea.id, isAdmin: true);
    final beaInvite = await (await sessionOf(
      f.bea,
    )).createInvite(role: MemberRole.guest, displayName: 'E2E Beas Gast');
    final others = (await api.adminUsers()).length - 1;
    expect(others, greaterThan(1));
    final state = await start(tester);
    await openAdmin(tester, de.sectionSettings);
    await scrollTo(tester, find.text(de.adminDeleteAllData2));
    await tap(
      tester,
      find.descendant(
        of: tile(de.adminDeleteAllData2),
        matching: find.text(de.commonDeleteEllipsis),
      ),
    );
    await waitFor(tester, find.text(de.adminDeleteAllData));
    await tap(tester, find.text(de.adminAlsoRemoveAllOther));
    await enter(tester, field(de.commonYourPassword), kitPassword);
    await enter(tester, field(de.adminTypeDeleteConfirm), 'LÖSCHEN');
    await submit(tester, de.adminDeletePermanently);
    await dialogClosed(tester);
    await waitFor(tester, find.textContaining('Gelöscht: '));
    expect(find.textContaining(de.adminMembersMembers(others)), findsOneWidget);
    expect(
      [for (final u in await api.adminUsers()) u.member.username],
      [kitUser],
    );
    await expectLater(
      FamioApiClient(kitUrl).checkInvite(beaInvite.code!),
      throwsA(isA<ApiError>()),
    );
    await finish(tester, state);
  });
}
