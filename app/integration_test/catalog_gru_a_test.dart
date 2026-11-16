// Catalog GRU-001 … GRU-073 (first start and connecting, server setup,
// signing in, two-factor, passkeys in the app, invitations, pairing and
// "Meine Geräte", signing out, tour, tips, "Was ist neu", start page,
// tiles, quick entry, search) against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_gru_a_test.dart
//
// Each test signs in through the app's own pages; other members and devices
// are API sessions. Wrong passwords and codes count against the client's
// address (20 an hour over all accounts): the tests with many of them (the
// sign-in throttle, two-factor) reach the server through this Mac's address
// in the home network instead of 127.0.0.1, so the others keep signing in.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/usernames.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/environment.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio/src/screens/home_screen.dart';
import 'package:famio/src/screens/sos_screens.dart';
import 'package:famio/src/screens/tasks_screen.dart';
import 'package:famio/src/weather/weather_tile.dart';
import 'package:famio/src/widgets/account_widgets.dart';
import 'package:famio/src/widgets/famio_glyph.dart';
import 'package:famio/src/widgets/famio_tour.dart';
import 'package:famio/src/widgets/section_shown.dart';
import 'package:famio/src/widgets/setup_checklist.dart';
import 'package:famio/src/widgets/sync_status_icon.dart';
import 'package:famio/src/widgets/whats_new.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';

/// The same server over HTTPS with its own certificate.
const _tlsUrl = String.fromEnvironment('FAMIO_NEW_URL');

final en = lookupL10n(const Locale('en'));

// --- members and data --------------------------------------------------------

final _members = <String, Future<FamilyMember>>{};

/// A member of this file only (password [kitMemberPassword]), created once.
Future<FamilyMember> member(
  String username,
  String name, {
  MemberRole role = MemberRole.adult,
  bool isAdmin = false,
}) => _members[username] ??= () async {
  final f = await theFamily();
  for (final u in await f.admin.adminUsers()) {
    if (u.member.username == username) return u.member;
  }
  return f.admin.createMember(
    username: username,
    displayName: name,
    password: kitMemberPassword,
    role: role,
    isAdmin: isAdmin,
  );
}();

/// Another device of [m]: a fresh API session (not the shared one).
Future<FamioApiClient> deviceOf(
  FamilyMember m, {
  String device = 'e2e Zweitgerät',
  String url = kitUrl,
  String password = kitMemberPassword,
}) async {
  final api = FamioApiClient(
    url,
    pinnedCertificate: url.startsWith('https') ? await lanPin() : null,
  );
  await api.login(username: m.username, password: password, device: device);
  return api;
}

Future<void> seed(
  FamioApiClient api,
  String collection,
  String id,
  Map<String, Object?> data,
) async {
  final r = await put(api, collection, {id: data});
  expect(
    r.rejected.where((x) => x.id == id),
    isEmpty,
    reason: 'the server takes $collection/$id',
  );
}

/// Removes everything of [collections] the admin gets (or what [only]
/// picks), so that a test starts from nothing.
Future<void> clean(
  Iterable<String> collections, {
  bool Function(SyncRecord r)? only,
}) async {
  final f = await theFamily();
  for (final c in collections) {
    final ids = [
      for (final r in (await pull(f.admin, c)).values)
        if (only == null || only(r)) r.id,
    ];
    if (ids.isNotEmpty) await remove(f.admin, c, ids);
  }
}

bool _e2e(SyncRecord r) =>
    '${r.data['title'] ?? r.data['name'] ?? r.data['text'] ?? ''}'.startsWith(
      'E2E',
    );

String? _lan;
var _lanLooked = false;

/// The server through this Mac's address in the home network (falls back
/// to 127.0.0.1): wrong passwords from there count apart. Over HTTPS: the
/// server takes plain HTTP only from the same machine.
Future<String> lanUrl() async {
  final lan = await lanHost();
  return lan == null ? kitUrl : 'https://$lan:${Uri.parse(_tlsUrl).port}';
}

String? _lanPin;

/// The certificate key the app confirms for [lanUrl].
Future<String?> lanPin() async {
  final url = await lanUrl();
  if (!url.startsWith('https')) return null;
  return _lanPin ??= await FamioApiClient.untrustedCertificate(Uri.parse(url));
}

Future<String?> lanHost() async {
  if (!_lanLooked) {
    _lanLooked = true;
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        final b = a.rawAddress;
        final private =
            b[0] == 10 ||
            (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
            (b[0] == 192 && b[1] == 168);
        if (!a.isLoopback && private) _lan ??= a.address;
      }
    }
    debugPrint('E2E-INFO home network address: ${_lan ?? 'none'}');
  }
  return _lan;
}

// --- the app -----------------------------------------------------------------

var _formatted = false;

Future<void> _dates() async {
  if (_formatted) return;
  await initializeDateFormatting('de');
  await initializeDateFormatting('en');
  await initializeDateFormatting('es');
  _formatted = true;
}

/// A window as high as a big screen: lists build what is on it.
void tall(WidgetTester tester, {double width = 800, double height = 1600}) {
  tester.view.physicalSize = Size(width, height) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}

/// The app signed out, as just installed.
Future<AppState> startSignedOut(WidgetTester tester) async {
  await _dates();
  await freshStart();
  final state = AppState();
  await state.init();
  addTearDown(() async {
    if (state.me != null) await state.signOut();
  });
  // A new app, not the page of the one before.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(FamioApp(state: state));
  await waitFor(tester, field(de.connectServerAddress));
  return state;
}

Future<void> connect(WidgetTester tester, String url) async {
  await enter(tester, field(de.connectServerAddress), url);
  await tap(tester, find.text(de.commonConnect));
}

/// [connect], confirming the server's own certificate if asked.
Future<void> connectTrusting(WidgetTester tester, String url) async {
  await connect(tester, url);
  if (url.startsWith('https')) {
    await waitFor(tester, find.text(de.trustMatches));
    await tap(tester, find.text(de.trustMatches));
  }
  await waitFor(tester, field(de.commonUsername));
}

/// Types username and password and taps "Anmelden"; waits until the
/// answer is in (the button comes back).
Future<void> signInHere(
  WidgetTester tester,
  String user, {
  String password = kitMemberPassword,
}) async {
  await enter(tester, field(de.commonUsername), user);
  await enter(tester, field(de.commonPassword), password);
  await tap(tester, find.text(de.commonSignIn));
}

Future<void> laterIfAsked(WidgetTester tester) async {
  if (find.text(de.commonLater).evaluate().isNotEmpty) {
    await tap(tester, find.text(de.commonLater).last);
  }
}

/// Like [startApp], through [url] and with [password].
Future<AppState> startVia(
  WidgetTester tester,
  String url,
  String user, {
  String password = kitMemberPassword,
}) async {
  final state = await startSignedOut(tester);
  await connectTrusting(tester, url);
  await signInHere(tester, user, password: password);
  await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
  await laterIfAsked(tester);
  return state;
}

/// Quits the app (without signing out) and starts it again.
Future<AppState> restart(WidgetTester tester, AppState old) async {
  await leaveApp(tester, old);
  final state = AppState();
  await state.init();
  addTearDown(() async {
    if (state.me != null) await state.signOut();
  });
  await tester.pumpWidget(FamioApp(state: state));
  return state;
}

/// The app goes away without signing out (its session stays valid).
Future<void> leaveApp(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
  final engine = state.engine;
  state
    ..engine = null
    ..me = null;
  if (engine != null) {
    await engine.dispose();
    engine.store.close();
  }
  state.files?.close();
  state.files = null;
}

/// Einstellungen → [title] (a list entry).
Future<void> openSettingsItem(WidgetTester tester, String title) async {
  await openSection(tester, 'Einstellungen');
  await scrollTo(tester, find.text(title));
  await tap(tester, find.text(title));
}

final signOutTile = find.widgetWithText(ListTile, de.settingsSignOut);

/// What the app copies, instead of the person's clipboard.
Future<String?> copiedBy(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  String? text;
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      text = (call.arguments as Map)['text'] as String?;
    }
    return null;
  });
  try {
    await action();
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  }
  return text;
}

bool _is(Widget w, String type) => w.runtimeType.toString() == type;

/// A tile of the start page by its (private) class, e.g. `_TasksTile`.
Finder tile(String type) => find.byWidgetPredicate((w) => _is(w, type));

Finder inTile(String type, Finder what) =>
    find.descendant(of: tile(type), matching: what);

/// Whether the section page [page] is the one in front.
bool inFront(WidgetTester tester, Finder page) {
  final shown = find.ancestor(of: page, matching: find.byType(SectionShown));
  return shown.evaluate().isNotEmpty &&
      tester.widget<SectionShown>(shown.first).shown;
}

String greeting(DateTime now) => switch (now.hour) {
  < 5 => de.homeGoodNight,
  < 11 => de.homeGoodMorning,
  < 17 => de.homeHello,
  < 22 => de.homeGoodEvening,
  _ => de.homeGoodNight,
};

Finder dialogText(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

// --- two-factor --------------------------------------------------------------

/// An authenticator app: RFC 6238 codes of steps not used yet (the server
/// takes one step ahead and never a used one).
class Authenticator {
  Authenticator(this.secret);

  final String secret;
  var _last = -1;

  static int get _now => DateTime.now().millisecondsSinceEpoch ~/ 30000;

  Future<String> next(WidgetTester tester) async {
    final step = max(_now, _last + 1);
    while (step > _now + 1) {
      await tester.pump(const Duration(seconds: 1));
    }
    _last = step;
    return codeAt(step);
  }

  String codeAt(int step) {
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
}

/// The code field of a code dialog that was just opened (empty).
final freshCodeField = find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      (w.controller?.text.isEmpty ?? false) &&
      (w.decoration?.labelText == de.commonCode ||
          w.decoration?.labelText == de.securityRecoveryCode),
);

/// Types [code] into the newly opened code dialog and confirms.
Future<void> answerCode(WidgetTester tester, String code) async {
  await waitFor(tester, freshCodeField);
  final controller = tester.widget<TextField>(freshCodeField.last).controller!;
  await tester.tap(freshCodeField.last, warnIfMissed: false);
  await tester.pump();
  await tester.enterText(freshCodeField.last, code);
  await tester.pump();
  if (controller.text != code) {
    controller.text = code;
    await tester.pump();
  }
  await tap(tester, dialogText(de.commonConfirm));
}

List<String> recoveryCodesOn(WidgetTester tester) => [
  for (final e in find.byType(SelectableText).evaluate())
    for (final m in RegExp(
      r'[a-z0-9]{5}-[a-z0-9]{5}',
    ).allMatches((e.widget as SelectableText).data ?? ''))
      m.group(0)!,
];

// --- other servers and connections ------------------------------------------

/// Passes TCP between the app and the server, counting connections; [cut]
/// makes the server unreachable (as with no network) until [restore].
class Gate {
  Gate(this._upstream);

  final Uri _upstream;
  late final ServerSocket _server;
  final _open = <Socket>{};
  var _up = true;
  var accepted = 0;

  int get port => _server.port;
  String get url => 'http://127.0.0.1:$port';

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_accept);
  }

  Future<void> _accept(Socket client) async {
    accepted++;
    unawaited(client.done.catchError((Object _) {}));
    if (!_up) {
      client.destroy();
      return;
    }
    final Socket server;
    try {
      server = await Socket.connect(_upstream.host, _upstream.port);
    } catch (_) {
      client.destroy();
      return;
    }
    unawaited(server.done.catchError((Object _) {}));
    if (!_up) {
      client.destroy();
      server.destroy();
      return;
    }
    _open
      ..add(client)
      ..add(server);
    void close() {
      client.destroy();
      server.destroy();
      _open
        ..remove(client)
        ..remove(server);
    }

    void pass(Socket to, List<int> data) {
      try {
        to.add(data);
      } catch (_) {
        close();
      }
    }

    client.listen(
      (d) => pass(server, d),
      onDone: close,
      onError: (Object _) => close(),
      cancelOnError: true,
    );
    server.listen(
      (d) => pass(client, d),
      onDone: close,
      onError: (Object _) => close(),
      cancelOnError: true,
    );
  }

  void cut() {
    _up = false;
    for (final s in [..._open]) {
      s.destroy();
    }
    _open.clear();
  }

  void restore() => _up = true;

  Future<void> close() async {
    cut();
    await _server.close();
  }
}

/// In front of the real server: answers `/api/health` like a server that
/// was just started (no account yet, setup code required) and passes
/// everything else on, so "Konto anlegen" reaches the real server.
class NewServerFront {
  NewServerFront._(this._server, this._upstream);

  final HttpServer _server;
  final Uri _upstream;
  final _client = HttpClient();
  var setupRequests = 0;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<NewServerFront> start(Uri upstream) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final front = NewServerFront._(server, upstream);
    server.listen(front._handle);
    return front;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      if (request.uri.path == '/api/auth/setup') setupRequests++;
      final upstream = await _client.openUrl(
        request.method,
        _upstream.replace(
          path: request.uri.path,
          query: request.uri.hasQuery ? request.uri.query : null,
        ),
      );
      for (final h in [
        'content-type',
        'accept',
        'accept-language',
        'authorization',
        'x-famio-app',
      ]) {
        final v = request.headers.value(h);
        if (v != null) upstream.headers.set(h, v);
      }
      upstream.add(body);
      final answer = await upstream.close();
      final bytes = await answer.fold<List<int>>([], (a, b) => a..addAll(b));
      if (request.uri.path == '/api/health') {
        final json =
            (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>()
              ..['setupRequired'] = true
              ..['setupCodeRequired'] = true;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(json));
      } else {
        response.statusCode = answer.statusCode;
        if (answer.headers.contentType case final type?) {
          response.headers.contentType = type;
        }
        response.add(bytes);
      }
    } catch (e) {
      response.statusCode = 502;
    }
    await response.close();
  }

  Future<void> close() async {
    _client.close(force: true);
    await _server.close(force: true);
  }
}

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

String _fold(String fingerprint) =>
    fingerprint.replaceAll(':', '').toUpperCase();

// --- pairing -----------------------------------------------------------------

String pairLink(DevicePairing pairing) =>
    DevicePairLink(server: kitUrl, secret: pairing.secret).encode();

/// A pairing created at the start of the file and redeemed in its last
/// test, more than five minutes later.
({String link, DateTime at})? _earlyPairing;

Future<void> makeEarlyPairing() async {
  if (_earlyPairing != null) return;
  final m = await member('e2e-gru-ablauf', 'E2E Ablauf');
  // This session stays signed in: only the time ends the approval.
  final device = await deviceOf(m, device: 'e2e Altgerät');
  _earlyPairing = (
    link: pairLink(await device.createDevicePairing()),
    at: DateTime.now(),
  );
}

Future<void> joinWithPairing(WidgetTester tester, String code) async {
  await enter(tester, field(de.pairCode), code);
  await tap(tester, find.text(de.pairJoin));
}

const _invalidPairing = 'Der Kopplungscode ist ungültig oder abgelaufen.';

// --- the tour ----------------------------------------------------------------

Finder tourCard(int number) => find.byWidgetPredicate(
  (w) => _is(w, '_Card') && (w as dynamic).number == number,
);

final tourOverlay = find.byWidgetPredicate((w) => _is(w, '_TourOverlay'));

/// Walks the tour from step 1 to "Fertig"; [backAt] taps "Zurück" once on
/// that step. Each step's highlighted button must be on screen.
Future<List<TourStep>> walkTour(WidgetTester tester, {int? backAt}) async {
  await waitFor(tester, tourCard(1));
  final total = (tester.widget(tourCard(1)) as dynamic).total as int;
  final steps = <TourStep>[];
  for (var i = 1; i <= total; i++) {
    await waitFor(tester, tourCard(i));
    final step = (tester.widget(tourCard(i)) as dynamic).step as TourStep;
    steps.add(step);
    expect(
      find.descendant(
        of: tourCard(i),
        matching: find.text(de.tourStep(i, total)),
      ),
      findsOneWidget,
    );
    final box = step.target.currentContext?.findRenderObject();
    expect(
      box is RenderBox && box.attached && box.hasSize && box.size.width > 0,
      isTrue,
      reason: 'step $i (${step.title}) points at a real button',
    );
    if (i == backAt) {
      await tap(
        tester,
        find.descendant(of: tourCard(i), matching: find.text(de.commonBack)),
      );
      await waitFor(tester, tourCard(i - 1));
      await tap(
        tester,
        find.descendant(
          of: tourCard(i - 1),
          matching: find.text(de.commonNext),
        ),
      );
      await waitFor(tester, tourCard(i));
    }
    await tap(
      tester,
      find.descendant(
        of: tourCard(i),
        matching: find.text(i == total ? de.commonDone : de.commonNext),
      ),
    );
  }
  await waitGone(tester, tourOverlay);
  return steps;
}

// --- editors -----------------------------------------------------------------

Finder rowButtons(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
  matching: find.byType(TextButton),
);

String textIn(WidgetTester tester, Finder f) => tester
    .widget<Text>(find.descendant(of: f, matching: find.byType(Text)).first)
    .data!;

/// Start or end as the event editor shows them: (date, time).
(String, String?) shown(WidgetTester tester, String row) {
  final buttons = rowButtons(row);
  final n = buttons.evaluate().length;
  return (
    textIn(tester, buttons.first),
    n > 1 ? textIn(tester, buttons.last) : null,
  );
}

final eventEditorOpen = find.byWidgetPredicate(
  (w) =>
      w is Text && (w.data == de.eventNewEvent || w.data == de.eventEditEvent),
);

String buttonDate(DateTime d) => DateFormat.yMMMEd('de').format(d);
String clock(int h, [int m = 0]) =>
    DateFormat.jm('de').format(DateTime(2000, 1, 1, h, m));

/// The quick entry field on the start page.
final quickEntryField = find.text(de.quickEntryTitle);

Future<void> quickEntry(WidgetTester tester, String line) async {
  await openSection(tester, 'Start');
  await scrollTo(tester, quickEntryField, up: true);
  await tap(tester, quickEntryField);
  final input = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == de.quickEntryHint,
  );
  await waitFor(tester, input);
  await tester.enterText(input, line);
  await tester.pump(const Duration(milliseconds: 400));
}

Finder sheetButton(String label) => find.byWidgetPredicate(
  (w) =>
      (w is FilledButton || w is OutlinedButton) &&
      (w as ButtonStyleButton).child is Text &&
      ((w.child as Text).data == label),
);

bool highlighted(WidgetTester tester, String label) =>
    tester.widget(sheetButton(label)) is FilledButton;

bool enabled(WidgetTester tester, String label) =>
    (tester.widget(sheetButton(label)) as ButtonStyleButton).onPressed != null;

/// Closes the sheet or dialog that holds [inside] (Escape, as on a
/// keyboard; else like swiping it away).
Future<void> closeTop(WidgetTester tester, Finder inside) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 600));
  if (inside.evaluate().isNotEmpty) {
    await Navigator.of(tester.element(inside.first)).maybePop();
    await tester.pump(const Duration(milliseconds: 600));
  }
}

// --- search ------------------------------------------------------------------

final searchInput = find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      w.decoration?.hintText == de.searchEventTaskRecipeContact,
);

Future<void> openSearch(WidgetTester tester) async {
  await openSection(tester, 'Start');
  await tap(tester, find.byTooltip(de.commonSearch));
  await waitFor(tester, searchInput);
}

Future<void> search(WidgetTester tester, String text) async {
  await tester.tap(searchInput, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.enterText(searchInput, text);
  await tester.pump(const Duration(milliseconds: 800));
  final typed = tester.widget<TextField>(searchInput).controller!.text;
  if (typed != text) debugPrint('E2E-INFO search field holds "$typed"');
  expect(typed, text);
}

Finder heading(String text) =>
    find.byWidgetPredicate((w) => w is ListHeading && w.text == text);

void main() {
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // --- Erster Start und Verbinden ---------------------------------------------

  testWidgets('GRU-001 the sign-in page on the first start', (tester) async {
    // The pairing that should run out by the end of the file.
    await makeEarlyPairing();
    final launcher = _FakeLauncher();
    final before = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = before);
    final state = await startSignedOut(tester);

    // GRU-001
    expect(find.byType(FamioGlyph), findsOneWidget);
    expect(find.text(de.connectFamilyOrganizer), findsOneWidget);
    expect(
      tester
          .widget<TextField>(field(de.connectServerAddress))
          .decoration
          ?.hintText,
      de.settingsFamioExampleCom192,
    );
    expect(find.text(de.commonConnect), findsOneWidget);
    expect(find.text(de.inviteJoin), findsOneWidget);
    expect(find.text(de.pairJoinTitle), findsOneWidget);
    final info = await PackageInfo.fromPlatform();
    final version = '${AppEnv.appName} ${info.version} (${info.buildNumber})';
    await waitFor(tester, find.text(version));
    expect(version, matches(RegExp(r'^Famio( Dev)? \d+\.\d+\.\d+ \(\d+\)$')));
    expect(find.text(de.settingsPrivacy), findsOneWidget);
    double y(Finder f) => tester.getCenter(f).dy;
    // Version and "Datenschutz" at the bottom; the two ways in stand
    // between the address and "Verbinden" (connect_screen.dart).
    expect(y(find.text(version)), greaterThan(y(find.text(de.commonConnect))));
    expect(
      y(find.text(de.settingsPrivacy)),
      greaterThan(y(find.text(version))),
    );
    debugPrint(
      'E2E-INFO join ${y(find.text(de.inviteJoin))} pair '
      '${y(find.text(de.pairJoinTitle))} connect '
      '${y(find.text(de.commonConnect))}',
    );
    expect(
      y(find.text(de.inviteJoin)),
      lessThan(y(find.text(de.commonConnect))),
    );
    await tap(tester, find.text(de.settingsPrivacy));
    expect(launcher.opened, [AppEnv.privacyUrl]);
    await finish(tester, state);
  });

  testWidgets('GRU-002 an empty address, then the login fields', (
    tester,
  ) async {
    final state = await startSignedOut(tester);
    await tap(tester, find.text(de.commonConnect));
    await waitFor(tester, find.text(de.connectPleaseEnterAddress));
    expect(field(de.commonUsername), findsNothing);
    await connect(tester, kitUrl);
    await waitFor(tester, field(de.commonUsername));
    expect(field(de.commonPassword), findsOneWidget);
    expect(find.text(de.commonSignIn), findsOneWidget);
    expect(find.text(de.connectPleaseEnterAddress), findsNothing);
    expect(
      tester.widget<TextField>(field(de.connectServerAddress)).enabled,
      isFalse,
    );
    expect(find.byTooltip(de.connectChangeServer), findsOneWidget);
    await finish(tester, state);
  });

  // The address field is disabled once a server is known, and a disabled
  // TextField ignores pointers: the pencil "Server ändern" lies on top of
  // it, outside the field (#546).
  testWidgets('GRU-002 "Server ändern" makes the address editable again', (
    tester,
  ) async {
    final state = await startSignedOut(tester);
    await connect(tester, kitUrl);
    await waitFor(tester, field(de.commonUsername));
    // The pencil in the (now disabled) address field.
    final pencil = find.byTooltip(de.connectChangeServer);
    final icon = tester.renderObject(
      find.descendant(of: pencil, matching: find.byType(RichText)).first,
    );
    final reachable = tester
        .hitTestOnBinding(tester.getCenter(pencil))
        .path
        .any((e) => e.target == icon);
    debugPrint('E2E-INFO the pencil takes taps: $reachable');
    await tester.tap(pencil, warnIfMissed: true);
    await tester.pump(const Duration(milliseconds: 500));
    await waitGone(tester, field(de.commonUsername));
    expect(field(de.commonPassword), findsNothing);
    expect(
      tester.widget<TextField>(field(de.connectServerAddress)).enabled,
      isTrue,
    );
    expect(find.text(de.commonConnect), findsOneWidget);
    expect(find.text(de.commonSignIn), findsNothing);
    await finish(tester, state);
  });

  testWidgets('GRU-005 GRU-004 own certificate: cancel, then confirm', (
    tester,
  ) async {
    final f = await theFamily();
    final fingerprint = (await f.admin.adminOverview()).tlsFingerprint;
    expect(fingerprint, isNotNull, reason: 'the server has its own TLS');
    final gate = Gate(Uri.parse(_tlsUrl).replace(host: '127.0.0.1'));
    await gate.start();
    addTearDown(gate.close);
    final url = 'https://127.0.0.1:${gate.port}';
    final state = await startSignedOut(tester);

    await connect(tester, url);
    await waitFor(tester, find.text(de.trustCheckServerSCertificate));
    final shownPrint = tester
        .widget<SelectableText>(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(SelectableText),
          ),
        )
        .data!;
    final lines = shownPrint.split('\n');
    expect(lines, hasLength(4), reason: shownPrint);
    for (final l in lines) {
      expect(l.split(':'), hasLength(8), reason: l);
    }
    // The same fingerprint as the server prints (and its administration
    // shows).
    expect(_fold(lines.join(':')), _fold(fingerprint!));

    // GRU-005: cancelled, nothing more goes to the server.
    final probes = gate.accepted;
    debugPrint('E2E-INFO connections before the dialog: $probes');
    await tap(tester, dialogText(de.commonCancel));
    await waitFor(tester, find.text(de.appCertificateNotConfirmedConnection));
    expect(field(de.commonUsername), findsNothing);
    expect(field(de.commonPassword), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(gate.accepted, probes, reason: 'no connection after "Abbrechen"');

    // GRU-004: confirmed.
    await tap(tester, find.text(de.commonConnect));
    await waitFor(tester, find.text(de.trustMatches));
    await tap(tester, find.text(de.trustMatches));
    await waitFor(
      tester,
      find.text(de.connectConnectedSecurelyCertificateConfirmed),
    );
    expect(
      find.descendant(
        of: find
            .ancestor(
              of: find.text(de.connectConnectedSecurelyCertificateConfirmed),
              matching: find.byType(Row),
            )
            .first,
        matching: find.byIcon(AppIcons.lock),
      ),
      findsOneWidget,
    );
    await waitFor(tester, field(de.commonUsername));
    expect(field(de.commonPassword), findsOneWidget);
    await signInHere(tester, 'e2e-bea');
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    expect(state.serverUrl, startsWith('https://'));
    expect(_fold(state.certificatePin!), _fold(fingerprint));
    await finish(tester, state);
  });

  testWidgets(
    'GRU-007 GRU-008 GRU-006 no HTTP over the internet, clear errors, home network without HTTPS',
    (tester) async {
      await theFamily();
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      other.listen((r) async {
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode({'name': 'nas', 'version': '7.2'}));
        await r.response.close();
      });
      addTearDown(() => other.close(force: true));
      final state = await startSignedOut(tester);

      Future<void> refused(String input, String message) async {
        await enter(tester, field(de.connectServerAddress), input);
        await tap(tester, find.text(de.commonConnect));
        await waitFor(tester, find.textContaining(message));
        expect(find.text(de.trustCheckServerSCertificate), findsNothing);
        expect(field(de.commonUsername), findsNothing);
      }

      // GRU-007: refused before any connection.
      await refused('http://famio.example.de', de.appOverInternetOnlyEncrypted);
      // GRU-008
      await refused(
        'famio.invalid',
        'Die Adresse wurde nicht gefunden. Ist sie richtig geschrieben?',
      );
      await refused('127.0.0.1:${other.port}', 'Das ist kein Famio-Server');
      await refused(
        '127.0.0.1:9',
        'Unter dieser Adresse antwortet kein Famio-Server.',
      );

      // GRU-006: an IP address without "https://", plain HTTP. The test
      // server takes plain HTTP only from this machine (it has an HTTPS
      // port on its own number, which the app does not try).
      await enter(
        tester,
        field(de.connectServerAddress),
        '127.0.0.1:${Uri.parse(kitUrl).port}',
      );
      await tap(tester, find.text(de.commonConnect));
      await waitFor(tester, find.text(de.connectUnencryptedHomeNetworkServer));
      expect(find.text(de.trustCheckServerSCertificate), findsNothing);
      expect(
        find.descendant(
          of: find
              .ancestor(
                of: find.text(de.connectUnencryptedHomeNetworkServer),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byIcon(AppIcons.warningCircle),
        ),
        findsOneWidget,
      );
      await signInHere(tester, 'e2e-bea');
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      expect(state.serverUrl, startsWith('http://'));
      await finish(tester, state);
    },
  );

  // An ordinary web server answering with HTML (router, NAS) is no Famio
  // server, not an "unexpected answer" (#546).
  testWidgets('GRU-008 an ordinary web page is no Famio server', (
    tester,
  ) async {
    // Another web server in the house (router, NAS): HTML, no JSON.
    final web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    web.listen((r) async {
      r.response
        ..statusCode = r.uri.path == '/' ? 200 : 404
        ..headers.contentType = ContentType.html
        ..write('<html><body><h1>Not Found</h1></body></html>');
      await r.response.close();
    });
    addTearDown(() => web.close(force: true));
    final state = await startSignedOut(tester);
    await connect(tester, '127.0.0.1:${web.port}');
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data ?? '').isNotEmpty &&
            (w.data!.contains('Famio-Server') ||
                w.data!.contains('Unerwartete Antwort')),
      ),
    );
    debugPrint('E2E-INFO other web server: ${onScreen()}');
    expect(find.textContaining('Das ist kein Famio-Server'), findsOneWidget);
    expect(find.textContaining('Unerwartete Antwort'), findsNothing);
    await finish(tester, state);
  });

  // --- Server einrichten -------------------------------------------------------

  testWidgets('GRU-010 GRU-011 GRU-012 GRU-013 setup form of a new server', (
    tester,
  ) async {
    final f = await theFamily();
    final usersBefore = (await f.admin.adminUsers()).length;
    final front = await NewServerFront.start(Uri.parse(kitUrl));
    addTearDown(front.close);
    final state = await startSignedOut(tester);
    await connect(tester, front.url);

    // GRU-010: what a new server asks for.
    await waitFor(tester, find.text(de.connectNewServerCreateFirst));
    expect(find.text(de.connectServerLogEG), findsOneWidget);
    for (final label in [
      de.connectSetupCode,
      de.inviteName2,
      de.commonUsername,
      de.commonPassword,
    ]) {
      expect(field(label), findsOneWidget, reason: label);
    }
    expect(find.text(de.connectCreateAccount), findsOneWidget);
    expect(find.text(de.commonSignIn), findsNothing);

    // GRU-011 GRU-012: the form says what is missing, nothing is sent.
    await tap(tester, find.text(de.connectCreateAccount));
    await waitFor(tester, find.text(de.connectEnterCodeServerLog));
    expect(find.text(de.connectPleaseEnterUsername), findsOneWidget);
    expect(find.text(de.connectLeast8Characters), findsOneWidget);
    await enter(tester, field(de.connectSetupCode), 'FALSCH23');
    await enter(tester, field(de.inviteName2), 'E2E Neu');
    await enter(tester, field(de.commonUsername), 'e2e-neu');
    await enter(tester, field(de.commonPassword), 'Kurz-12');
    await tap(tester, find.text(de.connectCreateAccount));
    await waitGone(tester, find.text(de.connectEnterCodeServerLog));
    expect(find.text(de.connectLeast8Characters), findsOneWidget);
    expect(front.setupRequests, 0);

    // GRU-013: meanwhile set up elsewhere (by tool/integration_tests.sh):
    // the server turns the second setup down.
    await enter(tester, field(de.commonPassword), 'Wolke-Regal-Tulpe-42');
    await tap(tester, find.text(de.connectCreateAccount));
    await waitFor(tester, find.text('Server ist bereits eingerichtet'));
    expect(front.setupRequests, 1);
    expect(state.me, isNull);
    final users = await f.admin.adminUsers();
    expect(users, hasLength(usersBefore));
    expect(users.where((u) => u.member.username == 'e2e-neu'), isEmpty);
    await finish(tester, state);
  });

  // --- Anmeldung ---------------------------------------------------------------

  testWidgets(
    'GRU-015 GRU-016 GRU-014 wrong sign-in, throttle, the session stays',
    (tester) async {
      await member('e2e-gru-tippt', 'E2E Vertippt');
      await member('e2e-gru-bleibt', 'E2E Bleibt');
      var state = await startSignedOut(tester);
      await connectTrusting(tester, await lanUrl());
      await waitFor(tester, field(de.commonUsername));

      // GRU-015: no username.
      await enter(tester, field(de.commonPassword), 'irgendwas-123');
      await tap(tester, find.text(de.commonSignIn));
      await waitFor(tester, find.text(de.connectPleaseEnterUsername));

      // GRU-015 GRU-016: five wrong passwords, then the waiting time.
      Future<void> attempt(String password) async {
        await signInHere(tester, 'e2e-gru-tippt', password: password);
        await waitFor(tester, find.text(de.commonSignIn));
      }

      for (var i = 1; i <= 5; i++) {
        await attempt('falsch-$i-xyz');
        expect(
          find.text('Benutzername oder Passwort falsch'),
          findsOneWidget,
          reason: 'attempt $i',
        );
        expect(state.me, isNull);
      }
      final throttled = RegExp(
        r'^Zu viele Fehlversuche\. Bitte in \d+ Minute\(n\) erneut versuchen\.$',
      );
      Finder throttleText() => find.byWidgetPredicate(
        (w) => w is Text && throttled.hasMatch(w.data ?? ''),
      );
      await attempt('falsch-6-xyz');
      expect(throttleText(), findsOneWidget, reason: onScreen());
      // Also with the right password, until the time is up.
      await attempt(kitMemberPassword);
      expect(throttleText(), findsOneWidget, reason: onScreen());
      expect(state.me, isNull);
      await finish(tester, state);

      // GRU-014: signed in, the session survives quitting the app.
      await tester.pumpWidget(const SizedBox());
      state = await startApp(tester, user: 'e2e-gru-bleibt');
      await openSection(tester, 'Start');
      await waitFor(tester, find.textContaining(', E2E Bleibt!'));
      state = await restart(tester, state);
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      expect(field(de.connectServerAddress), findsNothing);
      expect(state.me?.username, 'e2e-gru-bleibt');
      await waitFor(tester, find.textContaining(', E2E Bleibt!'));
      await finish(tester, state);
    },
  );

  // --- Zwei-Faktor -----------------------------------------------------------

  testWidgets(
    'GRU-019 GRU-018 GRU-026 set up two-factor; passkeys in the app',
    (tester) async {
      await member('e2e-gru-totp1', 'E2E Authenticator');
      final state = await startVia(tester, await lanUrl(), 'e2e-gru-totp1');
      await openSettingsItem(tester, de.settingsSecurity);
      await waitFor(tester, find.text(de.securityOff));

      // GRU-026: passkeys are added in the web app only.
      await scrollTo(tester, find.text(de.passkeysTitle));
      expect(find.text(de.passkeysNone), findsOneWidget);
      expect(find.text(de.passkeyOnlyWeb), findsOneWidget);
      expect(find.text(de.passkeyAdd), findsNothing);

      // GRU-019: the wrong password shows no QR code.
      await scrollTo(tester, find.text(de.commonSetUp), up: true);
      await tap(tester, find.text(de.commonSetUp));
      await waitFor(tester, find.text(de.securitySetUpTwoFactor));
      await enter(tester, field(de.commonPassword), 'falsch-passwort-1');
      await tap(tester, find.text(de.commonNext));
      await waitFor(tester, find.text('Passwort falsch'));
      expect(find.byType(QrImageView), findsNothing);
      await enter(tester, field(de.commonPassword), kitMemberPassword);
      await tap(tester, find.text(de.commonNext));
      await waitFor(tester, find.byType(QrImageView));
      expect(find.byTooltip(de.securityCopyKey), findsOneWidget);
      final secret = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .data!
          .replaceAll(' ', '');
      expect(secret, hasLength(32));
      final auth = Authenticator(secret);
      // A wrong code: still off.
      await enter(tester, field(de.commonCode), '000000');
      await tap(tester, find.text(de.commonTurnOn));
      await waitFor(tester, find.textContaining('Der Code stimmt nicht'));
      expect((await state.engine!.api.twoFactorStatus()).enabled, isFalse);

      // GRU-018
      await enter(tester, field(de.commonCode), await auth.next(tester));
      await tap(tester, find.text(de.commonTurnOn));
      await waitFor(tester, find.text(de.securityTwoFactor));
      final codes = recoveryCodesOn(tester);
      expect(codes, hasLength(10));
      final copied = await copiedBy(
        tester,
        () => tap(tester, find.text(de.commonCopy)),
      );
      await waitFor(tester, find.text(de.securityCodesCopied));
      expect(copied, contains(codes.first));
      expect(copied, contains(codes.last));
      await snackGone(tester);
      await tap(tester, find.text(de.securityCodesSavedDone));
      await waitFor(tester, find.text(de.securityOn));
      expect(find.text(de.securityWhenSigningFamioAlso(10)), findsOneWidget);
      expect(find.text(de.securityNewRecoveryCodes), findsOneWidget);
      expect(find.text(de.commonTurnOff), findsOneWidget);
      expect((await state.engine!.api.twoFactorStatus()).enabled, isTrue);
      await back(tester);
      await finish(tester, state);
    },
  );

  testWidgets(
    'GRU-020 GRU-021 GRU-022 GRU-023 GRU-024 sign in with a code, wrong codes, recovery codes, switching off',
    (tester) async {
      final lan = await lanUrl();
      final m = await member('e2e-gru-totp2', 'E2E Zweiter Faktor');
      final setup = await deviceOf(m, url: lan, device: 'e2e-setup');
      final begun = await setup.beginTotp(password: kitMemberPassword);
      final auth = Authenticator(begun.secret);
      final codes = await setup.confirmTotp(await auth.next(tester));
      // Room for the dialog of new recovery codes (see the next test).
      tall(tester);
      final state = await startSignedOut(tester);

      Future<void> withPassword() async {
        if (field(de.commonUsername).evaluate().isEmpty) {
          await connectTrusting(tester, lan);
        }
        await signInHere(tester, m.username);
        await waitFor(tester, dialogText(de.securityTwoFactorSignIn));
      }

      Future<void> signOutHere() async {
        await snackGone(tester);
        await state.signOut();
        await waitFor(tester, field(de.connectServerAddress));
      }

      // GRU-020: the code is asked after the password.
      await withPassword();
      expect(dialogText(de.securityEnter6DigitCode), findsOneWidget);

      // GRU-021: five wrong codes, then the sign-in has run out.
      for (var i = 1; i <= 5; i++) {
        await answerCode(tester, '000000');
        await waitFor(tester, freshCodeField);
        expect(
          dialogText('Der Code stimmt nicht'),
          findsOneWidget,
          reason: 'after wrong code $i',
        );
      }
      final throttledAt = DateTime.now();
      // Any code now: the sign-in is used up.
      await answerCode(tester, '111111');
      await waitFor(
        tester,
        find.text(
          'Die Anmeldung ist abgelaufen. Bitte noch einmal mit Passwort.',
        ),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(state.me, isNull);
      // Cancelled: no session.
      await tap(tester, find.text(de.commonSignIn));
      await waitFor(tester, dialogText(de.securityTwoFactorSignIn));
      await tap(tester, dialogText(de.commonCancel));
      await dialogClosed(tester);
      expect(find.text(de.commonSignIn), findsOneWidget);
      expect(state.me, isNull);

      // GRU-020: five wrong codes hold the next ones back half a minute.
      while (DateTime.now().difference(throttledAt) <
          const Duration(seconds: 33)) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tap(tester, find.text(de.commonSignIn));
      await waitFor(tester, dialogText(de.securityTwoFactorSignIn));
      await answerCode(tester, await auth.next(tester));
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      await laterIfAsked(tester);
      expect(state.me?.username, m.username);
      await signOutHere();

      // GRU-022: a recovery code once, not twice.
      await withPassword();
      await tap(tester, dialogText(de.securityPhoneNotHandRecovery));
      await waitFor(tester, freshCodeField);
      final recoveryField = tester.widget<TextField>(freshCodeField.last);
      expect(recoveryField.decoration?.labelText, de.securityRecoveryCode);
      expect(recoveryField.decoration?.hintText, 'abcde-12345');
      await answerCode(tester, codes[0]);
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      await laterIfAsked(tester);
      await openSettingsItem(tester, de.settingsSecurity);
      await waitFor(tester, find.text(de.securityWhenSigningFamioAlso(9)));
      await back(tester);
      await signOutHere();
      await withPassword();
      await tap(tester, dialogText(de.securityPhoneNotHandRecovery));
      await answerCode(tester, codes[0]);
      await waitFor(tester, freshCodeField);
      expect(dialogText('Der Code stimmt nicht'), findsOneWidget);
      await tap(tester, dialogText(de.commonCancel));
      await dialogClosed(tester);
      expect(state.me, isNull);

      // GRU-023: new recovery codes replace the old ones.
      await tap(tester, find.text(de.commonSignIn));
      await waitFor(tester, dialogText(de.securityTwoFactorSignIn));
      await answerCode(tester, await auth.next(tester));
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      await laterIfAsked(tester);
      await openSettingsItem(tester, de.settingsSecurity);
      await tap(tester, find.text(de.securityNewRecoveryCodes));
      await waitFor(tester, dialogText(de.securityNewCodes));
      await answerCode(tester, await auth.next(tester));
      await waitFor(tester, dialogText(de.securityNewRecoveryCodes));
      final fresh = recoveryCodesOn(tester);
      expect(fresh, hasLength(10));
      expect(fresh.toSet().intersection(codes.toSet()), isEmpty);
      await tap(tester, dialogText(de.securitySaved));
      await dialogClosed(tester);
      await waitFor(tester, find.text(de.securityWhenSigningFamioAlso(10)));
      await back(tester);
      await signOutHere();
      await withPassword();
      await tap(tester, dialogText(de.securityPhoneNotHandRecovery));
      await answerCode(tester, codes[1]);
      await waitFor(tester, freshCodeField);
      expect(dialogText('Der Code stimmt nicht'), findsOneWidget);
      await tap(tester, dialogText(de.securityPhoneNotHandRecovery));
      await answerCode(tester, fresh[0]);
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      await laterIfAsked(tester);

      // GRU-024: switching off needs the password and a right code.
      await openSettingsItem(tester, de.settingsSecurity);
      Future<void> switchOff(String code) async {
        await snackGone(tester);
        await tap(tester, find.text(de.commonTurnOff));
        await waitFor(tester, dialogText(de.securityTurnOffTwoFactor));
        final inDialog = find.byType(AlertDialog);
        await enter(
          tester,
          find.descendant(of: inDialog, matching: field(de.commonPassword)),
          kitMemberPassword,
        );
        await enter(
          tester,
          find.descendant(
            of: inDialog,
            matching: field(de.securityCodeOrRecoveryCode),
          ),
          code,
        );
        await leaveField(tester);
        await tap(tester, dialogText(de.commonTurnOff));
        await dialogClosed(tester);
      }

      await switchOff('000000');
      await waitFor(
        tester,
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Der Code stimmt nicht'),
        ),
      );
      await waitFor(tester, find.text(de.securityOn));
      await switchOff(await auth.next(tester));
      await waitFor(tester, find.text(de.securityTwoFactorTurnedOff));
      await waitFor(tester, find.text(de.securityOff));
      await back(tester);
      await signOutHere();
      await connectTrusting(tester, lan);
      await signInHere(tester, m.username);
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      expect(find.byType(AlertDialog), findsNothing);
      await finish(tester, state);
    },
  );

  // In a window 600 pixels high the dialog "Neue Wiederherstellungscodes"
  // scrolls instead of running over (#546).
  testWidgets('GRU-023 new recovery codes in a window 600 pixels high', (
    tester,
  ) async {
    final m = await member('e2e-gru-totp3', 'E2E Neue Codes');
    final setup = await deviceOf(m, device: 'e2e-setup');
    final begun = await setup.beginTotp(password: kitMemberPassword);
    final auth = Authenticator(begun.secret);
    final codes = await setup.confirmTotp(await auth.next(tester));
    // A laptop window of ordinary height.
    tall(tester, width: 800, height: 600);
    final state = await startSignedOut(tester);
    await connect(tester, kitUrl);
    await signInHere(tester, m.username);
    await waitFor(tester, dialogText(de.securityTwoFactorSignIn));
    await tap(tester, dialogText(de.securityPhoneNotHandRecovery));
    await answerCode(tester, codes.first);
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    await laterIfAsked(tester);
    await openSettingsItem(tester, de.settingsSecurity);
    await tap(tester, find.text(de.securityNewRecoveryCodes));
    await waitFor(tester, dialogText(de.securityNewCodes));
    await answerCode(tester, await auth.next(tester));
    await waitFor(tester, dialogText(de.securityNewRecoveryCodes));
    await tester.pump(const Duration(seconds: 1));
    // All ten codes and "Kopieren" fit, nothing overflows.
    expect(recoveryCodesOn(tester), hasLength(10));
    final copy = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(de.commonCopy),
    );
    expect(copy, findsOneWidget);
    expect(tester.takeException(), isNull);
    // "Kopieren" may need a scroll, but is reachable within the window.
    await tester.ensureVisible(copy);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getBottomLeft(copy).dy, lessThanOrEqualTo(600));
    await tap(tester, dialogText(de.securitySaved));
    await dialogClosed(tester);
    await back(tester);
    await finish(tester, state);
  });
  testWidgets('GRU-025 two-factor required for adults, not for children', (
    tester,
  ) async {
    final f = await theFamily();
    await member('e2e-gru-pflicht', 'E2E Pflicht');
    // A second admin with an authenticator sets the rule and back.
    final admin2 = await member(
      'e2e-gru-admin2',
      'E2E Admin Zwei',
      isAdmin: true,
    );
    final setup = await deviceOf(admin2, device: 'e2e-setup');
    final begun = await setup.beginTotp(password: kitMemberPassword);
    final codes = await setup.confirmTotp(
      await Authenticator(begun.secret).next(tester),
    );
    final strong = FamioApiClient(kitUrl);
    try {
      await strong.login(
        username: admin2.username,
        password: kitMemberPassword,
      );
      fail('two-factor login expected');
    } on TwoFactorRequired catch (challenge) {
      await strong.loginTwoFactor(
        challenge: challenge.challenge,
        code: codes.first,
      );
    }
    addTearDown(() => strong.updateServerSettings({'twoFactorRequired': null}));
    await strong.updateServerSettings({'twoFactorRequired': 'adults'});
    final state = await startSignedOut(tester);
    await connect(tester, kitUrl);
    await signInHere(tester, 'e2e-gru-pflicht');

    // Only the setup, nothing else.
    await waitFor(tester, find.text(de.securityRequiredAccount2));
    expect(find.text(de.securityTwoFactorSignIn), findsWidgets);
    expect(
      find.text(
        de.securityAdministratorTurnedTwoFactor(de.securitySetUpNowThen),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip(de.settingsSignOut), findsOneWidget);
    // No navigation into the areas. The home screen may still be fading
    // out: the gate comes with the answer to the status request.
    await waitGone(tester, find.byWidgetPredicate((w) => _is(w, 'HomeShell')));
    for (final area in ['Kalender', 'Aufgaben']) {
      expect(
        find.byWidgetPredicate(
          (w) =>
              (w is Text && w.data == area) ||
              (w is Tooltip && w.message == area),
        ),
        findsNothing,
        reason: '$area is not reachable',
      );
    }
    await enter(tester, field(de.commonPassword), kitMemberPassword);
    await tap(tester, find.text(de.commonNext));
    await waitFor(tester, find.byType(QrImageView));
    final secret = tester
        .widget<SelectableText>(find.byType(SelectableText).first)
        .data!
        .replaceAll(' ', '');
    final auth = Authenticator(secret);
    await enter(tester, field(de.commonCode), await auth.next(tester));
    await tap(tester, find.text(de.commonTurnOn));
    await waitFor(tester, find.text(de.securityCodesSavedDone));
    await tap(tester, find.text(de.securityCodesSavedDone));
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    expect(find.text(de.securityRequiredAccount2), findsNothing);

    // Required: no "Ausschalten".
    await openSettingsItem(tester, de.settingsSecurity);
    await waitFor(tester, find.text(de.securityOn));
    expect(find.text(de.securityNewRecoveryCodes), findsOneWidget);
    expect(find.text(de.commonTurnOff), findsNothing);
    await back(tester);
    await finish(tester, state);

    // The child is not asked.
    final kid = await startApp(tester, user: f.kid.username);
    await openSection(tester, 'Start');
    expect(find.text(de.securityRequiredAccount2), findsNothing);
    expect(kid.twoFactorGate, isNull);
    await finish(tester, kid);
  });

  // --- Einladung annehmen ------------------------------------------------------

  testWidgets('GRU-034 GRU-039 GRU-035 join with an invitation', (
    tester,
  ) async {
    final f = await theFamily();
    final invite = await f.admin.createInvite(
      role: MemberRole.child,
      displayName: 'E2E Lina',
    );
    final code = invite.code!;
    var state = await startSignedOut(tester);
    await tap(tester, find.text(de.inviteJoin));
    await waitFor(tester, field(de.settingsServer));
    // No scan button on a Mac.
    expect(find.text(de.inviteScanQrCode), findsNothing);
    await enter(tester, field(de.settingsServer), kitUrl);
    await enter(tester, field(de.commonCode), code);
    await tap(tester, find.text(de.commonNext));

    // GRU-034: the role, the name suggested.
    await waitFor(
      tester,
      find.text(de.inviteYouInvitedRole(MemberRole.child.label)),
    );
    final suggested = suggestUsername('E2E Lina', const []);
    expect(
      tester.widget<TextField>(field(de.inviteName2)).controller!.text,
      'E2E Lina',
    );
    expect(
      tester.widget<TextField>(field(de.commonUsername)).controller!.text,
      suggested,
    );
    expect(field(de.invitePasswordLeast8Characters), findsOneWidget);

    Future<void> join(String username, String password, String error) async {
      await enter(tester, field(de.commonUsername), username);
      await enter(tester, field(de.invitePasswordLeast8Characters), password);
      await tap(tester, find.text(de.inviteJoin2));
      await waitFor(tester, find.textContaining(error));
      expect(state.me, isNull);
    }

    // GRU-039: taken name, bad name, easy password – the invitation stays.
    await join('e2e-bea', 'Wolke-Regal-Tulpe-34', 'Benutzername ist vergeben');
    await join(
      'a',
      'Wolke-Regal-Tulpe-34',
      'Benutzername: 2–32 Zeichen, nur Buchstaben, Ziffern, . _ -',
    );
    await join(suggested, '12345678', 'zu leicht zu erraten');
    await join(suggested, 'passwort123', 'zu leicht zu erraten');
    expect(
      (await f.admin.openInvites()).where((i) => i.id == invite.id),
      isNotEmpty,
      reason: 'still open after the failed tries',
    );

    // GRU-034: joined, the child's start page.
    await enter(tester, field(de.commonUsername), suggested);
    await enter(
      tester,
      field(de.invitePasswordLeast8Characters),
      'Wolke-Regal-Tulpe-34',
    );
    await tap(tester, find.text(de.inviteJoin2));
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    await laterIfAsked(tester);
    expect(state.me?.role, MemberRole.child);
    expect(state.me?.displayName, 'E2E Lina');
    await openSection(tester, 'Start');
    await waitFor(tester, find.byType(SosCard));
    await finish(tester, state);

    // GRU-035: made up and used up.
    state = await startSignedOut(tester);
    for (final c in ['ZZZZ-ZZZZ', code]) {
      // Each time a fresh page: the message is the server's answer to it.
      await tap(tester, find.text(de.inviteJoin));
      await enter(tester, field(de.settingsServer), kitUrl);
      await enter(tester, field(de.commonCode), c);
      await tap(tester, find.text(de.commonNext));
      await waitFor(
        tester,
        find.text('Diese Einladung gibt es nicht oder sie ist abgelaufen.'),
      );
      expect(field(de.inviteName2), findsNothing);
      expect(field(de.invitePasswordLeast8Characters), findsNothing);
      await back(tester);
      await waitFor(tester, field(de.connectServerAddress));
    }
    await finish(tester, state);
  });

  // --- Gerätekopplung und Meine Geräte ----------------------------------------

  testWidgets('GRU-040 GRU-041 GRU-042 pairing a new device', (tester) async {
    final m = await member('e2e-gru-paar', 'E2E Paar');
    final mine = uid('task');
    await seed(
      await sessionOf(m),
      Collections.tasks,
      mine,
      Task(id: mine, title: 'E2E Nur für Paar', visibleTo: [m.id]).toData(),
    );
    final first = await startApp(tester, user: m.username);
    final tokenA = first.engine!.api.token!;

    // GRU-040
    await openSettingsItem(tester, de.settingsMyDevices);
    await tap(tester, find.byTooltip(de.pairTitle));
    await waitFor(tester, find.text(de.pairSecurityHint));
    await tap(tester, find.text(de.pairCreate));
    await waitFor(tester, find.byType(QrImageView));
    final now = DateTime.now();
    final until = {
      for (final m in [4, 5, 6])
        de.pairValidUntil(
          DateFormat.Hm('de').format(now.add(Duration(minutes: m))),
        ),
    };
    expect(
      find.byWidgetPredicate((w) => w is Text && until.contains(w.data)),
      findsOneWidget,
      reason: '$until on ${onScreen()}',
    );
    final link1 = await copiedBy(
      tester,
      () => tap(tester, find.text(de.pairCopy)),
    );
    await waitFor(tester, find.text(de.pairCopied));
    expect(link1, startsWith('famio-pair:'));
    // A new code replaces the first.
    await snackGone(tester);
    await tap(tester, find.text(de.pairReplace));
    await tester.pump(const Duration(seconds: 1));
    final link2 = await copiedBy(
      tester,
      () => tap(tester, find.text(de.pairCopy)),
    );
    expect(link2, isNot(link1));

    // Another computer, nothing saved.
    await leaveApp(tester, first);
    var second = await startSignedOut(tester);
    await tap(tester, find.text(de.pairJoinTitle));
    await waitFor(tester, find.text(de.pairJoinHint));
    // GRU-042: any text, the replaced code.
    await joinWithPairing(tester, 'Hallo, das ist kein Code');
    await waitFor(tester, find.text(de.pairInvalidCode));
    await joinWithPairing(tester, link1!);
    await waitFor(tester, find.text(_invalidPairing));
    expect(second.me, isNull);

    // GRU-041: no password, the same account and its data.
    await joinWithPairing(tester, link2!);
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    await laterIfAsked(tester);
    expect(second.me?.id, m.id);
    await eventually(
      tester,
      'the account data on the new device',
      () async => second.engine!.tasks.any((t) => t.id == mine),
    );
    // The first device lists it as a new sign-in.
    final deviceA = FamioApiClient(kitUrl, token: tokenA);
    final sessions = await deviceA.mySessions();
    final newOne = sessions.where(
      (s) =>
          !s.current &&
          DateTime.now().difference(s.createdAt) < const Duration(minutes: 2),
    );
    expect(newOne, isNotEmpty, reason: '$sessions');
    expect(DeviceTile(session: newOne.first).isNewSignIn, isTrue);
    await openSettingsItem(tester, de.settingsMyDevices);
    await waitFor(tester, find.byType(DeviceTile));
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is DeviceTile && !w.session.current,
        ),
        matching: find.textContaining(de.devicesNewSignIn),
      ),
      findsWidgets,
    );
    await back(tester);
    await finish(tester, second);

    // GRU-042: used once.
    second = await startSignedOut(tester);
    await tap(tester, find.text(de.pairJoinTitle));
    await joinWithPairing(tester, link2);
    await waitFor(tester, find.text(_invalidPairing));
    expect(second.me, isNull);
    await finish(tester, second);
    await deviceA.logout();
  });

  testWidgets('GRU-043 a pairing ends with the session or a new password', (
    tester,
  ) async {
    final signedOff = await member('e2e-gru-paar2', 'E2E Abgemeldet');
    final newPassword = await member('e2e-gru-paar3', 'E2E Neues Passwort');
    final a = await deviceOf(signedOff, device: 'e2e Gerät A');
    final link1 = pairLink(await a.createDevicePairing());
    await a.logout();
    final b = await deviceOf(newPassword, device: 'e2e Gerät A');
    final link2 = pairLink(await b.createDevicePairing());
    await b.changePassword(
      currentPassword: kitMemberPassword,
      newPassword: 'Wolke-Regal-Tulpe-43',
    );

    final state = await startSignedOut(tester);
    for (final link in [link1, link2]) {
      // A fresh page each time: the message answers this code.
      await tap(tester, find.text(de.pairJoinTitle));
      await joinWithPairing(tester, link);
      await waitFor(tester, find.text(_invalidPairing));
      expect(state.me, isNull);
      await back(tester);
      await waitFor(tester, field(de.connectServerAddress));
    }
    await finish(tester, state);
  });

  testWidgets('GRU-046 my devices: the list, signing out another one', (
    tester,
  ) async {
    final m = await member('e2e-gru-geraete', 'E2E Geräte');
    final phone = await deviceOf(m, device: 'android (E2E Altes Handy)');
    // It sends its app version like the app does.
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(Uri.parse(kitUrl).resolve('api/me'));
    request.headers
      ..set('authorization', 'Bearer ${phone.token}')
      ..set('x-famio-app', '2.0.0 android');
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 200);

    final state = await startApp(tester, user: m.username);
    await openSettingsItem(tester, de.settingsMyDevices);
    Finder deviceTile(bool Function(DeviceSession s) which) =>
        find.byWidgetPredicate((w) => w is DeviceTile && which(w.session));
    final here = deviceTile((s) => s.current);
    final old = deviceTile((s) => s.device == 'android (E2E Altes Handy)');
    await waitFor(tester, old);
    expect(
      find.descendant(
        of: here,
        matching: find.textContaining(de.settingsThisDevice),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: here, matching: find.byTooltip(de.settingsSignOut)),
      findsNothing,
    );
    final since = DateFormat.yMd('de').format(DateTime.now());
    for (final text in [
      'Zuletzt aktiv ',
      ' · angemeldet $since',
      de.adminAppVersion('2.0.0'),
      de.adminAppOutdated,
    ]) {
      expect(
        find.descendant(of: old, matching: find.textContaining(text)),
        findsOneWidget,
        reason: text,
      );
    }
    // Signed out at once, no question.
    await tap(
      tester,
      find.descendant(of: old, matching: find.byTooltip(de.settingsSignOut)),
    );
    await waitGone(tester, old);
    expect(find.byType(AlertDialog), findsNothing);
    await expectLater(
      phone.members(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    expect(here, findsOneWidget);
    await back(tester);
    await finish(tester, state);
  });

  // --- Abmelden und Sitzung ----------------------------------------------------

  testWidgets('GRU-048 signing out removes the data on this device', (
    tester,
  ) async {
    final f = await theFamily();
    final carl = await sessionOf(f.carl);
    final id = uid('task');
    await seed(
      carl,
      Collections.tasks,
      id,
      Task(
        id: id,
        title: 'E2E Abmelden Erinnerung',
        due: inDays(1),
        remindAt: DateTime.now().add(const Duration(hours: 3)),
        assigneeIds: [f.carl.id],
        visibleTo: [f.carl.id],
      ).toData(),
    );
    addTearDown(() => remove(carl, Collections.tasks, [id]));
    var state = await startApp(tester, user: f.carl.username);
    await eventually(
      tester,
      'the task on this device',
      () async => state.engine!.tasks.any((t) => t.id == id),
    );
    final support = (await getApplicationSupportDirectory()).path;
    final files = [
      for (final name in ['famio_${f.carl.id}.db', 'files_${f.carl.id}.db'])
        File(p.join(support, name)),
    ];
    expect(files.first.existsSync(), isTrue);
    // The reminder of the task, planned on this device (the app notes
    // what it handed to the system under "reminders.scheduled").
    final prefs = await SharedPreferences.getInstance();
    final notifications = FlutterLocalNotificationsPlugin();
    var pending = <PendingNotificationRequest>[];
    String? planned() => prefs.getString('reminders.scheduled');
    final end = DateTime.now().add(const Duration(seconds: 20));
    while ((planned() ?? '{}') == '{}' && DateTime.now().isBefore(end)) {
      state.remindersChanged();
      await tester.pump(const Duration(seconds: 1));
    }
    try {
      pending = await notifications.pendingNotificationRequests();
    } catch (e) {
      debugPrint('E2E-INFO pending reminders: $e');
    }
    debugPrint(
      'E2E-INFO reminders before signing out: planned ${planned()}, '
      'with the system ${pending.length}, service ${state.reminders != null}',
    );

    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, signOutTile);
    expect(
      find.descendant(
        of: signOutTile,
        matching: find.text(de.settingsSignOutSubtitle),
      ),
      findsOneWidget,
    );
    await tap(tester, signOutTile);
    await waitFor(tester, field(de.connectServerAddress));
    expect(state.me, isNull);
    for (final file in files) {
      expect(file.existsSync(), isFalse, reason: file.path);
    }
    expect(planned(), isNull, reason: 'the reminders went with the account');
    if (pending.isNotEmpty) {
      expect(await notifications.pendingNotificationRequests(), isEmpty);
    }

    // Signed in again: everything comes anew from the server.
    await finish(tester, state);
    state = await startApp(tester, user: f.carl.username);
    expect(files.first.existsSync(), isTrue);
    await eventually(
      tester,
      'the task loaded again',
      () async => state.engine!.tasks.any((t) => t.id == id),
    );
    await finish(tester, state);
  });

  testWidgets('GRU-049 signing out sends what is still waiting', (
    tester,
  ) async {
    final f = await theFamily();
    await member('e2e-gru-ab', 'E2E Abmelder');
    final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
    await gate.start();
    addTearDown(gate.close);
    final state = await startVia(tester, gate.url, 'e2e-gru-ab');
    await openSection(tester, 'Aufgaben');
    await waitFor(tester, field(de.tasksNewTask));

    // Made while the connection is away: it waits on this device.
    gate.cut();
    await enter(tester, field(de.tasksNewTask), 'E2E Vor dem Abmelden');
    await tap(tester, find.byTooltip(de.commonAdd));
    await waitFor(tester, find.text('E2E Vor dem Abmelden'));
    bool waiting() => state.engine!.store.dirty.any(
      (r) => r.record.data['title'] == 'E2E Vor dem Abmelden',
    );
    expect(waiting(), isTrue);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, signOutTile);
    // Back online and straight away "Abmelden".
    gate.restore();
    expect(waiting(), isTrue, reason: 'still waiting when signing out');
    await tap(tester, signOutTile);
    await waitFor(tester, field(de.connectServerAddress));
    await eventually(
      tester,
      'the task on the server',
      () async => (await titlesOf(
        f.admin,
        Collections.tasks,
      )).contains('E2E Vor dem Abmelden'),
      timeout: const Duration(seconds: 10),
    );
    await clean([
      Collections.tasks,
    ], only: (r) => r.data['title'] == 'E2E Vor dem Abmelden');
    await finish(tester, state);
  });

  // #337: signed out while the server cannot be reached and a change still
  // waits, Famio asks first; "Abbrechen" keeps the session and the change,
  // the next sign-out with a connection sends it
  // (app/test/sign_out_unsent_test.dart).
  testWidgets(
    'GRU-049 hint: signing out offline keeps or warns about waiting changes',
    (tester) async {
      final f = await theFamily();
      await member('e2e-gru-ab', 'E2E Abmelder');
      final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
      await gate.start();
      addTearDown(gate.close);
      final state = await startVia(tester, gate.url, 'e2e-gru-ab');
      await openSection(tester, 'Aufgaben');
      gate.cut();
      await enter(tester, field(de.tasksNewTask), 'E2E Offline abgemeldet');
      await tap(tester, find.byTooltip(de.commonAdd));
      await waitFor(tester, find.text('E2E Offline abgemeldet'));
      bool waiting() => state.engine!.store.dirty.any(
        (r) => r.record.data['title'] == 'E2E Offline abgemeldet',
      );
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, signOutTile);
      await tap(tester, signOutTile);
      // The last sync fails: Famio asks instead of dropping the task.
      await waitFor(tester, find.text(de.signOutUnsentBody(1)));
      expect(find.text(de.signOutAnyway), findsOneWidget);
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(de.commonCancel),
        ),
      );
      await dialogClosed(tester);
      expect(state.me, isNotNull, reason: 'cancelled: still signed in');
      expect(waiting(), isTrue, reason: 'the task still waits');

      // With the connection back, signing out sends it without asking.
      gate.restore();
      await scrollTo(tester, signOutTile);
      await tap(tester, signOutTile);
      await waitFor(tester, field(de.connectServerAddress));
      expect(find.byType(AlertDialog), findsNothing);
      await eventually(
        tester,
        'the task on the server',
        () async => (await titlesOf(
          f.admin,
          Collections.tasks,
        )).contains('E2E Offline abgemeldet'),
        timeout: const Duration(seconds: 10),
      );
      await clean([
        Collections.tasks,
      ], only: (r) => r.data['title'] == 'E2E Offline abgemeldet');
      await finish(tester, state);
    },
  );

  testWidgets('GRU-051 signed out from elsewhere closes the open dialog', (
    tester,
  ) async {
    final f = await theFamily();
    final m = await member('e2e-gru-aussen', 'E2E Von Außen');
    final other = await deviceOf(m);
    final state = await startApp(tester, user: m.username);
    await openSection(tester, 'Start');
    await tap(tester, find.byTooltip(de.settingsMyProfile));
    await waitFor(tester, find.text(de.settingsMyProfile));

    // A new password on the other device ends this session.
    await other.changePassword(
      currentPassword: kitMemberPassword,
      newPassword: 'Wolke-Regal-Tulpe-51',
    );
    // The app learns it with its next sync: someone's change sends a hint.
    final note = uid('task');
    await seed(
      f.admin,
      Collections.tasks,
      note,
      Task(id: note, title: 'E2E Anstoß').toData(),
    );
    addTearDown(() => remove(f.admin, Collections.tasks, [note]));
    await waitFor(
      tester,
      field(de.connectServerAddress),
      timeout: const Duration(seconds: 90),
    );
    expect(find.text(de.appSessionHasExpiredPlease), findsOneWidget);
    expect(find.text(de.settingsMyProfile), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    expect(state.me, isNull);
  });

  // #337: a change made offline outlives a sign-out from elsewhere: the
  // app keeps the account's database, the sign-in page says so, and signing
  // in again with the same account at the same server sends the change
  // (app/test/sign_out_unsent_test.dart).
  testWidgets(
    'GRU-051 hint: changes made offline before a sign-out from elsewhere',
    (tester) async {
      final f = await theFamily();
      final m = await member('e2e-gru-aussen2', 'E2E Von Außen Zwei');
      final other = await deviceOf(m);
      final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
      await gate.start();
      addTearDown(gate.close);
      final state = await startVia(tester, gate.url, m.username);
      await openSection(tester, 'Aufgaben');
      gate.cut();
      await enter(tester, field(de.tasksNewTask), 'E2E Offline vor Passwort');
      await tap(tester, find.byTooltip(de.commonAdd));
      await waitFor(tester, find.text('E2E Offline vor Passwort'));
      await other.changePassword(
        currentPassword: kitMemberPassword,
        newPassword: 'Wolke-Regal-Tulpe-52',
      );
      gate.restore();
      final note = uid('task');
      await seed(
        f.admin,
        Collections.tasks,
        note,
        Task(id: note, title: 'E2E Anstoß').toData(),
      );
      addTearDown(() => remove(f.admin, Collections.tasks, [note]));
      await waitFor(
        tester,
        field(de.connectServerAddress),
        timeout: const Duration(seconds: 120),
      );
      expect(state.me, isNull);
      expect(find.text(de.appSessionHasExpiredPlease), findsOneWidget);
      expect(find.text(de.connectWaitingChanges(1)), findsOneWidget);
      expect(state.waitingChanges?.count, 1);

      // The same account again, at the same server: the change goes out.
      await connectTrusting(tester, gate.url);
      await signInHere(tester, m.username, password: 'Wolke-Regal-Tulpe-52');
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      await laterIfAsked(tester);
      expect(state.waitingChanges, isNull);
      final after = FamioApiClient(kitUrl);
      await after.login(username: m.username, password: 'Wolke-Regal-Tulpe-52');
      await eventually(
        tester,
        'the change made offline on the server',
        () async => (await titlesOf(
          after,
          Collections.tasks,
        )).contains('E2E Offline vor Passwort'),
        timeout: const Duration(seconds: 30),
      );
      await clean([
        Collections.tasks,
      ], only: (r) => r.data['title'] == 'E2E Offline vor Passwort');
      await finish(tester, state);
    },
  );

  // --- Tour, Tipps, Was ist neu -------------------------------------------------

  testWidgets('GRU-052 the tour on the start page', (tester) async {
    tall(tester);
    var state = await startApp(tester);
    await openSection(tester, 'Start');
    await waitFor(tester, find.text(de.tourBannerTitle));
    expect(find.text(de.tourBannerText), findsOneWidget);
    await tap(tester, find.text(de.tourBannerTitle));
    final steps = await walkTour(tester, backAt: 2);
    expect(steps.map((s) => s.title), [
      de.tourHomeTitle,
      de.tourCalendarTitle,
      de.tourTasksTitle,
      de.tourShoppingTitle,
      de.tourKidsTitle,
      de.tourSosTitle,
      de.tourSettingsTitle,
    ]);
    expect(steps[1].target, TourTargets.sections[FamioSection.calendar]);
    expect(steps[5].target, TourTargets.sos);
    await waitGone(tester, find.text(de.tourBannerTitle));

    // Gone for good on this device.
    state = await restart(tester, state);
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    await openSection(tester, 'Start');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(de.tourBannerTitle), findsNothing);

    // From the settings, any time; Escape ends it.
    await openSettingsItem(tester, de.tourMenu);
    await waitFor(tester, tourCard(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitGone(tester, tourOverlay);

    // "Ausblenden" on the card, and "Überspringen", also end the offer.
    for (final skip in [false, true]) {
      await (await SharedPreferences.getInstance()).remove('tour.offered');
      state = await restart(tester, state);
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      await openSection(tester, 'Start');
      await waitFor(tester, find.text(de.tourBannerTitle));
      if (skip) {
        await tap(tester, find.text(de.tourBannerTitle));
        await waitFor(tester, tourCard(1));
        await tap(
          tester,
          find.descendant(of: tourCard(1), matching: find.text(de.tourSkip)),
        );
        await waitGone(tester, tourOverlay);
      } else {
        await tap(
          tester,
          find.descendant(
            of: find.byType(TourBanner),
            matching: find.byTooltip(de.commonHide),
          ),
        );
      }
      await waitGone(tester, find.text(de.tourBannerTitle));
      state = await restart(tester, state);
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      await openSection(tester, 'Start');
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(de.tourBannerTitle), findsNothing, reason: 'skip $skip');
    }
    await finish(tester, state);
  });

  testWidgets(
    'GRU-053 the tour of a child and a guest; none for service accounts',
    (tester) async {
      final f = await theFamily();
      final service = await member(
        'e2e-gru-ha',
        'E2E HA',
        role: MemberRole.service,
      );
      tall(tester, width: 400, height: 900);
      for (final user in [f.kid.username, f.guest.username]) {
        final state = await startApp(tester, user: user);
        await waitFor(tester, find.text(de.tourBannerTitle));
        await tap(tester, find.text(de.tourBannerTitle));
        final steps = await walkTour(tester);
        final titles = steps.map((s) => s.title).toList();
        debugPrint('E2E-INFO tour of $user: $titles');
        expect(titles, isNot(contains(de.tourKidsTitle)));
        if (user == f.kid.username) {
          expect(titles, contains(de.tourChoresTitle));
          expect(titles, isNot(contains(de.tourTasksTitle)));
          expect(titles, contains(de.tourSosTitle));
        } else {
          expect(titles, isNot(contains(de.tourSosTitle)));
        }
        final behindMore = steps.where((s) => s.target == TourTargets.more);
        expect(behindMore, isNotEmpty, reason: 'a phone has "Mehr"');
        for (final s in behindMore) {
          if (s.title == de.tourMoreTitle) continue;
          expect(s.text, endsWith(de.tourUnderMore), reason: s.title);
        }
        await finish(tester, state);
      }
      // Service accounts see no tour card.
      final state = await startApp(tester, user: service.username);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(TourBanner), findsNothing);
      expect(find.text(de.tourBannerTitle), findsNothing);
      await finish(tester, state);
    },
  );

  testWidgets('GRU-054 a tip on the first visit of an area', (tester) async {
    tall(tester);
    final state = await startApp(tester);
    final tipCard = find.text(de.tipTitle);

    await openSection(tester, 'Kalender', keepTip: true);
    await waitFor(tester, tipCard);
    expect(find.text(de.tipCalendar), findsOneWidget);
    await tap(tester, find.text(de.tipGotIt));
    await waitGone(tester, tipCard);
    await openSection(tester, 'Start', keepTip: true);
    await openSection(tester, 'Kalender', keepTip: true);
    await tester.pump(const Duration(seconds: 1));
    expect(tipCard, findsNothing);

    await openSection(tester, 'Einkauf', keepTip: true);
    await waitFor(tester, find.text(de.tipShopping));
    await tap(tester, find.text(de.tipNoMore));
    await waitGone(tester, tipCard);
    await openSection(tester, 'Aufgaben', keepTip: true);
    await tester.pump(const Duration(seconds: 1));
    expect(tipCard, findsNothing);
    expect(find.text(de.tipTasks), findsNothing);

    // Switched on again: every tip comes again.
    await openSection(tester, 'Einstellungen', keepTip: true);
    final tips = find.widgetWithText(SwitchListTile, de.tipSettings);
    await scrollTo(tester, tips);
    expect(tester.widget<SwitchListTile>(tips).value, isFalse);
    await tap(tester, tips);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<SwitchListTile>(tips).value, isTrue);
    await openSection(tester, 'Kalender', keepTip: true);
    await waitFor(tester, find.text(de.tipCalendar));
    await finish(tester, state);
  });

  testWidgets('GRU-055 what is new after an update', (tester) async {
    tall(tester);
    final version = (await PackageInfo.fromPlatform()).version;
    final german = await loadChangelog();
    final current = german.firstWhere((e) => e.version == version);
    final newTitle = de.whatsNewNewVersionTitle(
      version,
      current.title.isEmpty ? '' : ': ${current.title}',
    );
    final sheetTitle = find.text(newTitle);

    // A fresh install shows nothing and remembers the version.
    var state = await startApp(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(sheetTitle, findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('whatsNew.seen'), version);

    // After an update: once.
    await prefs.setString('whatsNew.seen', '2.0.0');
    state = await restart(tester, state);
    await waitFor(tester, sheetTitle, timeout: const Duration(seconds: 60));
    expect(find.text(current.points.first), findsOneWidget);
    await closeTop(tester, sheetTitle);
    await waitGone(tester, sheetTitle);
    state = await restart(tester, state);
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 3));
    expect(sheetTitle, findsNothing);

    // From the settings: the last five versions.
    await openSettingsItem(tester, de.settingsWhatsNew);
    await waitFor(tester, sheetTitle);
    final list = find.descendant(
      of: find.byType(DraggableScrollableSheet),
      matching: find.byType(Scrollable),
    );
    for (final e in german.skip(1).take(4)) {
      final title = find.text(
        '${e.version}${e.title.isEmpty ? '' : ' – ${e.title}'}',
      );
      await tester.dragUntilVisible(title, list.first, const Offset(0, -250));
      expect(title, findsOneWidget);
    }
    final older = find.text(de.whatsNewOlderVersionsListedReleases);
    await tester.dragUntilVisible(older, list.first, const Offset(0, -250));
    if (german.length > 5) {
      expect(find.textContaining(german[5].version), findsNothing);
    }
    await closeTop(tester, older);
    await waitGone(tester, older);

    // In English.
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsLanguage));
    await tap(tester, find.byType(DropdownButton<String>));
    await tap(tester, find.text('English').last);
    await tester.pump(const Duration(seconds: 1));
    final english = await loadChangelog();
    final englishCurrent = english.firstWhere((e) => e.version == version);
    await openSection(tester, en.sectionSettings);
    await scrollTo(tester, find.text(en.settingsWhatsNew));
    await tap(tester, find.text(en.settingsWhatsNew));
    await waitFor(
      tester,
      find.text(
        en.whatsNewNewVersionTitle(
          version,
          englishCurrent.title.isEmpty ? '' : ': ${englishCurrent.title}',
        ),
      ),
    );
    expect(englishCurrent.title, isNot(current.title));
    await closeTop(tester, find.byType(DraggableScrollableSheet));
    await openSection(tester, en.sectionSettings);
    await scrollTo(tester, find.text(en.settingsLanguage));
    await tap(tester, find.byType(DropdownButton<String>));
    await tap(tester, find.text('Deutsch').last);
    await tester.pump(const Duration(seconds: 1));

    // Started as a wall display: the sheet waits for the next start.
    await prefs.setString('whatsNew.seen', '2.0.0');
    await prefs.setBool('kiosk.autostart', true);
    state = await restart(tester, state);
    await waitFor(
      tester,
      find.byTooltip(de.kioskCloseWallDisplay),
      timeout: const Duration(seconds: 60),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(sheetTitle, findsNothing);
    expect(prefs.getString('whatsNew.seen'), '2.0.0');
    await prefs.setBool('kiosk.autostart', false);
    state = await restart(tester, state);
    await waitFor(tester, sheetTitle, timeout: const Duration(seconds: 60));
    await closeTop(tester, sheetTitle);
    await finish(tester, state);
  });

  // --- Startseite --------------------------------------------------------------

  testWidgets('GRU-056 the head of the start page', (tester) async {
    tall(tester);
    final state = await startApp(tester);
    await openSection(tester, 'Start');
    final now = DateTime.now();
    await waitFor(tester, find.text('${greeting(now)}, $kitAdminName!'));
    expect(find.text(DateFormat.MMMMEEEEd('de').format(now)), findsWidgets);
    expect(find.byType(SosHoldButton), findsOneWidget);
    for (final tip in [
      de.inboxTitle,
      de.commonSearch,
      de.homeWallDisplay,
      de.settingsMyProfile,
    ]) {
      expect(find.byTooltip(tip), findsWidgets, reason: tip);
    }
    expect(find.byType(SyncStatusIcon), findsOneWidget);
    // Narrow: no wall display.
    tester.view.physicalSize =
        const Size(500, 1000) * tester.view.devicePixelRatio;
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip(de.homeWallDisplay), findsNothing);
    expect(find.byTooltip(de.inboxTitle), findsOneWidget);
    tester.view.physicalSize =
        const Size(800, 1600) * tester.view.devicePixelRatio;
    await tester.pump(const Duration(seconds: 1));
    await waitFor(tester, find.byTooltip(de.homeWallDisplay));
    await tap(tester, find.byTooltip(de.settingsMyProfile));
    await waitFor(tester, find.text(de.settingsMyProfile));
    await tap(tester, dialogText(de.commonCancel));
    await dialogClosed(tester);
    await finish(tester, state);
  });

  testWidgets('GRU-057 GRU-069 start page of a child and of a guest', (
    tester,
  ) async {
    final f = await theFamily();
    // What adults would see a tile for.
    final ids = <String, String>{};
    Future<void> add(String c, String title, Map<String, Object?> data) async {
      final id = uid(c);
      ids[id] = c;
      await seed(f.admin, c, id, data);
    }

    await add(
      Collections.inbox,
      'E2E Zettel Gast',
      InboxItem(id: 'x', title: 'E2E Zettel Gast').toData(),
    );
    await add(
      Collections.deadlines,
      'E2E TÜV Gast',
      Deadline(id: 'x', title: 'E2E TÜV Gast', due: inDays(5)).toData(),
    );
    await add(
      Collections.wishes,
      'E2E Wunsch',
      Wish(id: 'x', ownerId: f.adminMember.id, title: 'E2E Wunsch').toData(),
    );
    await add(
      Collections.loans,
      'E2E Leiter',
      Loan(id: 'x', title: 'E2E Leiter', person: 'E2E Nachbar').toData(),
    );
    addTearDown(() async {
      for (final MapEntry(key: id, value: c) in ids.entries) {
        await remove(f.admin, c, [id]);
      }
    });

    // The child: the big emergency card on top, inbox and quick entry.
    tall(tester);
    var state = await startApp(tester, user: f.kid.username);
    await openSection(tester, 'Start');
    await waitFor(tester, find.byType(SosCard));
    // The card holds the emergency button; the head has none.
    expect(
      find.byType(SosHoldButton).evaluate().length,
      find
          .descendant(
            of: find.byType(SosCard),
            matching: find.byType(SosHoldButton),
          )
          .evaluate()
          .length,
      reason: 'no emergency button in the head',
    );
    expect(find.byTooltip(de.inboxTitle), findsOneWidget);
    expect(quickEntryField, findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(SosCard)).dy,
      lessThan(tester.getTopLeft(quickEntryField).dy),
    );
    await finish(tester, state);

    // The guest on a phone.
    tester.view.physicalSize =
        const Size(400, 900) * tester.view.devicePixelRatio;
    state = await startApp(tester, user: f.guest.username);
    await openSection(tester, 'Start');
    await waitFor(tester, tile('_TodayTile'));
    expect(find.byType(SosCard), findsNothing);
    expect(find.byType(SosHoldButton), findsNothing);
    expect(find.byTooltip(de.inboxTitle), findsNothing);
    expect(quickEntryField, findsNothing);
    expect(find.byTooltip(de.homeWallDisplay), findsOneWidget);
    for (final t in [
      '_InboxTile',
      '_WhereTile',
      '_KidsTile',
      '_DocumentsTile',
      '_DeadlinesTile',
      '_WishesTile',
      '_LoansTile',
    ]) {
      expect(tile(t), findsNothing, reason: t);
    }
    await finish(tester, state);
  });

  testWidgets('GRU-058 the fixed tiles show the day', (tester) async {
    final f = await theFamily();
    await clean([Collections.events]);
    tall(tester);
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Start');
    final later = inDays(3);
    final ids = <String, String>{};
    Future<void> add(
      String c,
      Map<String, Object?> Function(String id) data, {
      FamioApiClient? api,
    }) async {
      final id = uid(c);
      ids[id] = c;
      await seed(api ?? f.admin, c, id, data(id));
    }

    addTearDown(() async {
      for (final MapEntry(key: id, value: c) in ids.entries) {
        await remove(f.admin, c, [id]);
      }
    });

    // Nothing today: the next days.
    await add(
      Collections.events,
      (id) => CalendarEvent(
        id: id,
        title: 'E2E Später',
        start: DateTime(later.year, later.month, later.day, 10),
        end: DateTime(later.year, later.month, later.day, 11),
      ).toData(),
    );
    await waitFor(tester, inTile('_TodayTile', find.text('E2E Später')));
    expect(
      inTile('_TodayTile', find.text(de.homeNothingPlannedToday)),
      findsOneWidget,
    );

    // Today, with the time or "ganztägig".
    final t = today();
    await add(
      Collections.events,
      (id) => CalendarEvent(
        id: id,
        title: 'E2E Heute früh',
        start: DateTime(t.year, t.month, t.day, 0, 5),
        end: DateTime(t.year, t.month, t.day, 0, 35),
      ).toData(),
    );
    await add(
      Collections.events,
      (id) => CalendarEvent(
        id: id,
        title: 'E2E Heute ganz',
        start: t,
        end: inDays(1),
        allDay: true,
      ).toData(),
    );
    await waitFor(tester, inTile('_TodayTile', find.text('E2E Heute ganz')));
    expect(
      inTile('_TodayTile', find.text(de.homeNothingPlannedToday)),
      findsNothing,
    );
    expect(inTile('_TodayTile', find.text('E2E Heute früh')), findsOneWidget);
    expect(inTile('_TodayTile', find.text(clock(0, 5))), findsOneWidget);
    expect(
      inTile('_TodayTile', find.text(de.commonAllDayLower)),
      findsOneWidget,
    );
    final todays = engine.occurrencesOn(engine.calendar.today()).length;
    expect(todays, greaterThanOrEqualTo(2));
    expect(inTile('_TodayTile', find.text('$todays')), findsOneWidget);

    // Tasks: mine first.
    await add(
      Collections.tasks,
      (id) => Task(
        id: id,
        title: 'E2E Carls Aufgabe',
        due: today(),
        assigneeIds: [f.carl.id],
      ).toData(),
    );
    await add(
      Collections.tasks,
      (id) => Task(
        id: id,
        title: 'E2E Meine Aufgabe',
        due: inDays(5),
        assigneeIds: [f.adminMember.id],
      ).toData(),
    );
    await waitFor(tester, inTile('_TasksTile', find.text('E2E Meine Aufgabe')));
    await waitFor(tester, inTile('_TasksTile', find.text('E2E Carls Aufgabe')));
    expect(
      tester
          .getTopLeft(inTile('_TasksTile', find.text('E2E Meine Aufgabe')))
          .dy,
      lessThan(
        tester
            .getTopLeft(inTile('_TasksTile', find.text('E2E Carls Aufgabe')))
            .dy,
      ),
    );
    final open = engine.tasks.where((t) => !t.done).length;
    expect(inTile('_TasksTile', find.text('$open')), findsOneWidget);

    // Shopping: open items per list.
    final list = uid('list');
    ids[list] = Collections.shoppingLists;
    await seed(
      f.admin,
      Collections.shoppingLists,
      list,
      ShoppingList(id: list, name: 'E2E Wocheneinkauf').toData(),
    );
    for (final (name, checked) in [
      ('E2E Milch', false),
      ('E2E Brot', false),
      ('E2E Eier', true),
    ]) {
      await add(
        Collections.shoppingItems,
        (id) => ShoppingItem(
          id: id,
          listId: list,
          name: name,
          checked: checked,
        ).toData(),
      );
    }
    final listLine = find.ancestor(
      of: inTile('_ShoppingTile', find.text('E2E Wocheneinkauf')),
      matching: find.byType(Row),
    );
    await waitFor(tester, listLine);
    await waitFor(
      tester,
      find.descendant(
        of: listLine.first,
        matching: find.text(de.commonOpenCount(2)),
      ),
    );

    // Chat: the last message and how many are new.
    await add(
      Collections.chatMessages,
      (id) => ChatMessage(
        id: id,
        chatId: ChatIds.family,
        authorId: f.bea.id,
        sentAt: DateTime.now(),
        text: 'E2E Hallo von Bea',
      ).toData(),
      api: await sessionOf(f.bea),
    );
    await waitFor(tester, inTile('_ChatTile', find.text('E2E Hallo von Bea')));
    await waitFor(
      tester,
      inTile('_ChatTile', find.text(de.homeCountNew(engine.totalUnread))),
    );
    expect(engine.totalUnread, greaterThan(0));

    // The tile opens its area.
    await tap(tester, inTile('_TasksTile', find.text(de.sectionTasks)));
    await waitFor(tester, field(de.tasksNewTask));
    expect(inFront(tester, find.byType(TasksScreen)), isTrue);
    await finish(tester, state);
  });

  testWidgets('GRU-059 tiles only with something in them', (tester) async {
    final f = await theFamily();
    final collections = [
      Collections.inbox,
      Collections.wasteSettings,
      Collections.deadlines,
      Collections.mealPlan,
      Collections.chores,
      Collections.routines,
      Collections.medications,
      Collections.contacts,
      Collections.budgetEntries,
      Collections.loans,
    ];
    await clean(collections);
    await clean([
      Collections.events,
    ], only: (r) => r.data['countdown'] == true || _e2e(r));
    await clean([Collections.children]);
    final ids = <String, String>{};
    addTearDown(() async {
      for (final MapEntry(key: id, value: c) in ids.entries) {
        await remove(f.admin, c, [id]);
      }
    });
    tall(tester);
    final state = await startApp(tester);
    await openSection(tester, 'Start');
    await waitFor(tester, tile('_TodayTile'));
    const tiles = {
      '_InboxTile',
      '_WasteTile',
      '_DeadlinesTile',
      '_MealsTile',
      '_ChoresTile',
      '_MedsTile',
      '_BirthdaysTile',
      '_BudgetTile',
      '_LoansTile',
      '_CountdownTile',
    };
    for (final t in tiles) {
      expect(tile(t), findsNothing, reason: t);
    }

    Future<void> add(
      String c,
      Map<String, Object?> Function(String id) data, {
      String? id,
    }) async {
      final key = id ?? uid(c);
      ids[key] = c;
      await seed(f.admin, c, key, data(key));
    }

    Future<void> appears(String type, String title, [Finder? also]) async {
      await waitFor(tester, inTile(type, find.text(title)));
      if (also != null) await waitFor(tester, inTile(type, also));
    }

    await add(
      Collections.inbox,
      (id) => InboxItem(id: id, title: 'E2E Zettel').toData(),
    );
    await appears('_InboxTile', de.inboxTitle, find.text('E2E Zettel'));
    expect(inTile('_InboxTile', find.text('1')), findsOneWidget);

    await add(
      Collections.wasteSettings,
      (_) => const WasteSettings().toData(),
      id: WasteSettings.recordId,
    );
    await add(
      Collections.events,
      (id) => CalendarEvent(
        id: id,
        title: 'E2E Gelbe Tonne',
        start: inDays(1),
        end: inDays(2),
        allDay: true,
      ).toData(),
    );
    await appears('_WasteTile', de.homeBins);

    await add(
      Collections.deadlines,
      (id) => Deadline(id: id, title: 'E2E TÜV', due: inDays(10)).toData(),
    );
    await appears(
      '_DeadlinesTile',
      de.commonDeadlines,
      find.textContaining('E2E TÜV'),
    );

    await add(
      Collections.mealPlan,
      (id) => PlannedMeal(
        id: id,
        date: today(),
        slot: MealSlot.dinner,
        title: 'E2E Nudeln',
      ).toData(),
    );
    await appears('_MealsTile', de.sectionMeals);

    await add(
      Collections.chores,
      (id) => Chore(
        id: id,
        title: 'E2E Tisch decken',
        memberIds: [f.kid.id],
        start: today(),
      ).toData(),
    );
    await appears('_ChoresTile', de.sectionChores);

    await add(
      Collections.medications,
      (id) => Medication(
        id: id,
        name: 'E2E Vitamin D',
        times: const ['08:00'],
        start: today(),
      ).toData(),
    );
    await appears('_MedsTile', de.commonMedications);

    final birthday = inDays(5);
    await add(
      Collections.contacts,
      (id) => FamilyContact(
        id: id,
        name: 'E2E Oma',
        birthday: Birthday(birthday.month, birthday.day, 1950),
      ).toData(),
    );
    await appears('_BirthdaysTile', de.commonBirthdays);

    await add(
      Collections.budgetEntries,
      (id) => BudgetEntry(
        id: id,
        date: today(),
        cents: 1250,
        category: 'Lebensmittel',
      ).toData(),
    );
    await appears('_BudgetTile', de.sectionBudget);

    await add(
      Collections.loans,
      (id) => Loan(
        id: id,
        title: 'E2E Bohrmaschine',
        person: 'E2E Nachbar',
      ).toData(),
    );
    await appears('_LoansTile', de.loansTitle);

    // A marked appointment: "N Tage bis …", on the day itself "heute! 🎉".
    await add(
      Collections.events,
      (id) => CalendarEvent(
        id: id,
        title: 'E2E Ferien',
        start: inDays(10),
        end: inDays(11),
        allDay: true,
        countdown: true,
      ).toData(),
    );
    await appears(
      '_CountdownTile',
      de.homeDaysUntilTitle('E2E Ferien'),
      find.text('10'),
    );
    await add(
      Collections.events,
      (id) => CalendarEvent(
        id: id,
        title: 'E2E Fest',
        start: today(),
        end: inDays(1),
        allDay: true,
        countdown: true,
      ).toData(),
    );
    await appears('_CountdownTile', 'E2E Fest: ${de.commonTodayLower}! 🎉');
    for (final t in tiles) {
      expect(tile(t), findsOneWidget, reason: t);
    }
    await finish(tester, state);
  });

  testWidgets('GRU-060 a year ago today, hidden until tomorrow', (
    tester,
  ) async {
    final f = await theFamily();
    final now = today();
    final kid = uid('child');
    // A birthday far from today: no birthday tile in other tests.
    await seed(
      f.admin,
      Collections.children,
      kid,
      Child(
        id: kid,
        name: 'E2E Mia',
        birthDate: DateTime(
          now.year - 3,
          now.month,
          now.day,
        ).add(const Duration(days: 100)),
      ).toData(),
    );
    final one = uid('entry');
    await seed(
      f.admin,
      Collections.childEntries,
      one,
      ChildEntry(
        id: one,
        childId: kid,
        kind: ChildEntryKind.milestone,
        date: DateTime(now.year - 1, now.month, now.day),
        title: 'Erste Schritte',
      ).toData(),
    );
    final two = uid('entry');
    addTearDown(() async {
      await remove(f.admin, Collections.childEntries, [one, two]);
      await remove(f.admin, Collections.children, [kid]);
    });
    tall(tester);
    var state = await startApp(tester);
    await openSection(tester, 'Start');
    await waitFor(tester, inTile('_MemoriesTile', find.text(de.memoriesTitle)));
    expect(
      inTile('_MemoriesTile', find.text('E2E Mia: Erste Schritte')),
      findsOneWidget,
    );

    // Several years: "An diesem Tag".
    await seed(
      f.admin,
      Collections.childEntries,
      two,
      ChildEntry(
        id: two,
        childId: kid,
        kind: ChildEntryKind.milestone,
        date: DateTime(now.year - 2, now.month, now.day),
        title: 'Erstes Wort',
      ).toData(),
    );
    await waitFor(
      tester,
      inTile('_MemoriesTile', find.text(de.memoriesTitleYears)),
    );
    expect(
      inTile('_MemoriesTile', find.text(de.memoriesYearsAgo(2))),
      findsOneWidget,
    );
    expect(
      inTile('_MemoriesTile', find.text(de.memoriesYearsAgo(1))),
      findsOneWidget,
    );

    await tap(tester, inTile('_MemoriesTile', find.text(de.memoriesHide)));
    await waitGone(tester, tile('_MemoriesTile'));
    state = await restart(tester, state);
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    await openSection(tester, 'Start');
    await waitFor(tester, tile('_TodayTile'));
    await tester.pump(const Duration(seconds: 1));
    expect(tile('_MemoriesTile'), findsNothing);
    // The next day: put away "yesterday".
    await (await SharedPreferences.getInstance()).setString(
      'home.memoriesHidden',
      'E2E gestern',
    );
    state = await restart(tester, state);
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    await openSection(tester, 'Start');
    await waitFor(tester, tile('_MemoriesTile'));
    await finish(tester, state);
  });

  testWidgets('GRU-061 crossed change card; no year review in November', (
    tester,
  ) async {
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    // Crossed changes of earlier tests out of the way.
    await clean([Collections.conflicts]);
    final id = uid('task');
    await seed(
      f.admin,
      Collections.tasks,
      id,
      Task(id: id, title: 'E2E Konflikt').toData(),
    );
    addTearDown(() async {
      await remove(f.admin, Collections.tasks, [id]);
      await clean([Collections.conflicts]);
    });
    tall(tester);
    final state = await startApp(tester);
    await openSection(tester, 'Start');
    // Bea's phone has it offline, the admin changes it meanwhile …
    final offline = (await pull(bea, Collections.tasks))[id]!;
    await seed(f.admin, Collections.tasks, id, {
      ...offline.data,
      'title': 'E2E Konflikt (Admin)',
    });
    // … and Bea changes the old version a bit later.
    final r = await bea.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.tasks,
            id: id,
            data: {...offline.data, 'title': 'E2E Konflikt (Bea)'},
            updatedAt: DateTime.now().millisecondsSinceEpoch + 1000,
            rev: offline.rev,
          ),
        ],
      ),
    );
    expect(r.rejected, isEmpty);
    final card = find.byWidgetPredicate(
      (w) =>
          w is Text && (w.data ?? '').endsWith('überschnitten – bitte ansehen'),
    );
    await waitFor(tester, card);
    final open = state.engine!.records(Collections.conflicts).length;
    expect(
      tester.widget<Text>(card).data,
      open == 1
          ? de.homeChangeOverlappedPleaseTake
          : de.homeCountChangesOverlappedPlease(open),
    );
    await scrollTo(tester, card, up: true);
    final now = DateTime.now();
    final yearEnd = (now.month == 12 && now.day >= 15) || now.month == 1;
    expect(
      find.text(de.yearReviewHomeHint('${now.year}')),
      yearEnd ? findsOneWidget : findsNothing,
    );
    expect(
      find.textContaining('im Rückblick ansehen'),
      yearEnd ? findsOneWidget : findsNothing,
    );
    await tap(tester, card);
    await waitFor(tester, find.text(de.conflictsOverlappingChanges));
    await back(tester);
    await finish(tester, state);
  });

  testWidgets('GRU-062 the setup list for admins', (tester) async {
    final f = await theFamily();
    final other = await deviceOf(
      await member('e2e-gru-admin3', 'E2E Admin Drei', isAdmin: true),
    );
    String? ignoredId;
    addTearDown(() async {
      if (ignoredId case final id?) {
        await f.admin.ignoreSetupStep(id, ignored: false);
      }
    });
    tall(tester);
    var state = await startApp(tester);
    await openSection(tester, 'Start');
    // The numbers as the app counts them (it checks the public address
    // from this device itself).
    final bannerText = RegExp(r'^Einrichtung abschließen \((\d+) von (\d+)\)$');
    final banner = find.byWidgetPredicate(
      (w) => w is Text && bannerText.hasMatch(w.data ?? ''),
    );
    await waitFor(tester, banner);
    final numbers = bannerText.firstMatch(tester.widget<Text>(banner).data!)!;
    final done = int.parse(numbers[1]!);
    final total = int.parse(numbers[2]!);
    expect(done, lessThan(total));
    await tap(tester, banner);
    final list = find.byType(SetupChecklist);
    await waitFor(
      tester,
      find.descendant(
        of: list,
        matching: find.text(de.setupDoneTotalDone(done, total)),
      ),
    );
    final steps = await f.admin.setupChecklist();
    final counted = steps.where((s) => !s.ignored).toList();
    expect(counted, hasLength(total));
    var open = 0;
    for (final s in counted) {
      final title = find.descendant(of: list, matching: find.text(s.title));
      expect(title, findsOneWidget, reason: s.title);
      final row = find.ancestor(of: title, matching: find.byType(Row)).first;
      final ok = find
          .descendant(of: row, matching: find.byIcon(AppIcons.check))
          .evaluate()
          .isNotEmpty;
      final warn = find
          .descendant(of: row, matching: find.byIcon(AppIcons.warningCircle))
          .evaluate()
          .isNotEmpty;
      expect(ok != warn, isTrue, reason: '${s.title}: a tick or a warning');
      if (s.id != 'address') {
        expect(
          find.descendant(of: row, matching: find.text(s.detail)),
          findsOneWidget,
          reason: s.title,
        );
      }
      if (warn) {
        open++;
        expect(
          find.descendant(of: row, matching: find.text(de.setupIgnore)),
          findsOneWidget,
        );
        if (s.where.isNotEmpty) {
          expect(
            find.descendant(of: row, matching: find.text('→ ${s.where}')),
            findsOneWidget,
            reason: s.title,
          );
        }
      }
    }
    expect(open, total - done);
    // Leave one as it is: it counts no more, for every admin.
    final step = counted.firstWhere(
      (s) => s.title == 'Zwei-Faktor für dich',
      orElse: () => counted.firstWhere((s) => !s.done),
    );
    final row = find
        .ancestor(
          of: find.descendant(of: list, matching: find.text(step.title)),
          matching: find.byType(Row),
        )
        .first;
    await tap(
      tester,
      find.descendant(of: row, matching: find.text(de.setupIgnore)),
    );
    ignoredId = step.id;
    final ignoredLine = find.descendant(
      of: list,
      matching: find.text('${step.title} · ${de.setupIgnored}'),
    );
    await waitFor(tester, ignoredLine);
    expect(
      find.descendant(
        of: list,
        matching: find.text(de.setupDoneTotalDone(done, total - 1)),
      ),
      findsOneWidget,
    );
    expect(
      (await other.setupChecklist()).firstWhere((s) => s.id == step.id).ignored,
      isTrue,
    );
    await tap(
      tester,
      find.descendant(of: list, matching: find.text(de.setupShowAgain)),
    );
    await waitGone(tester, ignoredLine);
    ignoredId = null;
    expect(
      (await other.setupChecklist()).firstWhere((s) => s.id == step.id).ignored,
      isFalse,
    );
    await tap(
      tester,
      find.descendant(of: list, matching: find.byTooltip(de.commonCheckAgain)),
    );
    await waitFor(
      tester,
      find.descendant(of: list, matching: find.text(step.title)),
    );
    await closeTop(tester, list);
    await waitGone(tester, list);

    // Hidden on this device.
    await tap(
      tester,
      find.descendant(
        of: find.byType(SetupBanner),
        matching: find.byTooltip(de.commonHide),
      ),
    );
    await waitGone(tester, find.textContaining('Einrichtung abschließen ('));
    state = await restart(tester, state);
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    await openSection(tester, 'Start');
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Einrichtung abschließen ('), findsNothing);
    await finish(tester, state);

    // Not for adults without admin rights.
    state = await startApp(tester, user: f.bea.username);
    await openSection(tester, 'Start');
    await waitFor(tester, tile('_TodayTile'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(SetupBanner), findsNothing);
    expect(find.textContaining('Einrichtung abschließen ('), findsNothing);
    await finish(tester, state);
  });

  // --- Kacheln ein- und ausblenden ----------------------------------------------

  testWidgets('GRU-064 GRU-063 hiding an area and single tiles', (
    tester,
  ) async {
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    addTearDown(
      () => f.admin.updateServerSettings({'hiddenModules': <String>[]}),
    );
    final recipe = uid('recipe');
    final meal = uid('meal');
    final inbox = uid('inbox');
    await seed(
      f.admin,
      Collections.recipes,
      recipe,
      Recipe(id: recipe, title: 'E2E Kürbissuppe').toData(),
    );
    await seed(
      f.admin,
      Collections.mealPlan,
      meal,
      PlannedMeal(
        id: meal,
        date: today(),
        slot: MealSlot.dinner,
        recipeId: recipe,
      ).toData(),
    );
    await seed(
      f.admin,
      Collections.inbox,
      inbox,
      InboxItem(id: inbox, title: 'E2E Für später').toData(),
    );
    addTearDown(() async {
      await remove(f.admin, Collections.mealPlan, [meal]);
      await remove(f.admin, Collections.recipes, [recipe]);
      await remove(f.admin, Collections.inbox, [inbox]);
    });
    tall(tester);
    final state = await startApp(tester);
    final mealsNav = find.byWidgetPredicate(
      (w) =>
          (w is Text && w.data == de.sectionMeals) ||
          (w is Tooltip && w.message == de.sectionMeals),
    );

    Future<void> editAreas(void Function() inDialog) async {
      await openAdmin(tester, 'Einstellungen');
      await scrollTo(tester, find.text(de.adminShowHideAreas));
      await tap(
        tester,
        find.descendant(
          of: find.widgetWithText(ListTile, de.adminShowHideAreas),
          matching: find.text(de.commonChange),
        ),
      );
      await waitFor(tester, find.byType(AlertDialog));
      inDialog();
    }

    Finder dialogSwitch(String title) => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(SwitchListTile, title),
    );

    Future<void> saveAreas() async {
      await tap(tester, dialogText(de.commonSave));
      await waitFor(tester, find.text(de.adminAreasSaved));
      await dialogClosed(tester);
    }

    // GRU-064: another device hides "Essen" while it is open here.
    await openSection(tester, 'Start');
    await waitFor(tester, tile('_MealsTile'));
    await openSection(tester, de.sectionMeals);
    await f.admin.updateServerSettings({
      'hiddenModules': ['meals'],
    });
    await waitGone(tester, mealsNav);
    await waitFor(tester, find.byType(HomeScreen));
    await eventually(
      tester,
      'back on the start page',
      () async => inFront(tester, find.byType(HomeScreen)),
    );
    expect(tile('_MealsTile'), findsNothing);
    await f.admin.updateServerSettings({'hiddenModules': <String>[]});
    await waitFor(tester, mealsNav);

    // Found while shown …
    await openSearch(tester);
    await search(tester, 'Kürbissuppe');
    await waitFor(tester, heading(de.mealsRecipes));
    await back(tester);

    // … switched off in the administration: area and tile go together.
    await editAreas(() {});
    expect(
      dialogSwitch(de.sectionMeals),
      findsNWidgets(2),
      reason: 'area and tile',
    );
    await tap(tester, dialogSwitch(de.sectionMeals).first);
    expect(
      dialogSwitch(de.sectionMeals),
      findsOneWidget,
      reason: 'the tile goes with the area',
    );
    await saveAreas();
    expect((await bea.config())['hiddenModules'], contains('meals'));
    await tap(
      tester,
      find.descendant(
        of: find.widgetWithText(ListTile, de.adminShowHideAreas),
        matching: find.text(de.commonChange),
      ),
    );
    await waitFor(tester, find.byType(AlertDialog));
    expect(dialogSwitch(de.sectionMeals), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(dialogSwitch(de.sectionMeals)).value,
      isFalse,
    );
    await tap(tester, dialogText(de.commonCancel));
    await dialogClosed(tester);
    await back(tester);
    await waitGone(tester, mealsNav);
    await openSection(tester, 'Start');
    expect(tile('_MealsTile'), findsNothing);
    await openSearch(tester);
    await search(tester, 'Kürbissuppe');
    await waitFor(tester, find.text(de.commonNothingFound));
    await back(tester);
    await f.admin.updateServerSettings({'hiddenModules': <String>[]});
    await waitFor(tester, mealsNav);

    // GRU-063: single tiles.
    await openSection(tester, 'Start');
    await waitFor(tester, tile('_InboxTile'));
    expect(find.byType(WeatherTile), findsOneWidget);
    await editAreas(() {});
    await tap(tester, dialogSwitch(de.weatherWeather));
    await tap(tester, dialogSwitch(de.inboxTitle));
    await saveAreas();
    await waitFor(
      tester,
      find.text(de.adminHiddenAreas('${de.inboxTitle}, ${de.weatherWeather}')),
    );
    final hidden = (await bea.config())['hiddenModules'] as List;
    expect(hidden, containsAll(['tile.inbox', 'tile.weather']));
    await back(tester);
    await openSection(tester, 'Start');
    await waitGone(tester, tile('_InboxTile'));
    expect(find.byType(WeatherTile), findsNothing);
    expect(
      find.byTooltip(de.inboxTitle),
      findsOneWidget,
      reason: 'the button stays',
    );
    expect(tile('_TodayTile'), findsOneWidget);
    await finish(tester, state);
  });

  // --- Schnell eintragen ---------------------------------------------------------

  testWidgets('GRU-065 GRU-066 an appointment from one line, a day to choose', (
    tester,
  ) async {
    final f = await theFamily();
    addTearDown(
      () => clean([
        Collections.events,
      ], only: (r) => r.data['title'] == 'E2E Kinderarzt'),
    );
    tall(tester);
    final state = await startApp(tester);
    final engine = state.engine!;
    final now = today();
    // Thursday, or Friday on a Thursday (then "Donnerstag" names two days).
    final (word, weekday) = now.weekday == DateTime.thursday
        ? ('Freitag', DateTime.friday)
        : ('Donnerstag', DateTime.thursday);
    final ahead = (weekday - now.weekday) % 7;
    final day = DateUtils.addDaysToDate(now, ahead);

    // GRU-065
    await openSection(tester, 'Start');
    expect(find.text(de.quickEntryHint), findsOneWidget);
    await quickEntry(tester, '$word 16 Uhr E2E Kinderarzt');
    await waitFor(tester, find.text('E2E Kinderarzt'));
    expect(find.text('${buttonDate(day)} · ${clock(16)}'), findsOneWidget);
    expect(highlighted(tester, de.quickEntryAsEvent), isTrue);
    expect(highlighted(tester, de.quickEntryAsTask), isFalse);
    expect(find.text(de.quickEntryCheck), findsOneWidget);
    await tap(tester, sheetButton(de.quickEntryAsEvent));
    await waitFor(tester, eventEditorOpen);
    expect(
      tester.widget<TextField>(field(de.commonTitle)).controller!.text,
      'E2E Kinderarzt',
    );
    expect(shown(tester, de.commonStart), (buttonDate(day), clock(16)));
    expect(shown(tester, de.commonEnd), (buttonDate(day), clock(17)));
    expect(engine.familyTimeZone, 'Europe/Berlin');
    await leaveField(tester);
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, eventEditorOpen);
    await eventually(tester, 'the appointment on the server', () async {
      final events = await pull(f.admin, Collections.events);
      return events.values.any((r) {
        if (r.data['title'] != 'E2E Kinderarzt') return false;
        final e = CalendarEvent.fromRecord(r);
        return e.start.isAtSameMomentAs(
              DateTime(day.year, day.month, day.day, 16),
            ) &&
            e.end.isAtSameMomentAs(DateTime(day.year, day.month, day.day, 17));
      });
    });

    // GRU-066: two days to choose from.
    final nextAhead = ahead == 0 ? 7 : ahead;
    final first = DateUtils.addDaysToDate(now, nextAhead);
    final second = DateUtils.addDaysToDate(first, 7);
    final ambiguous = nextAhead != 7;
    await quickEntry(tester, 'nächsten $word E2E Elternabend');
    await waitFor(tester, find.text('E2E Elternabend'));
    if (ambiguous) {
      expect(find.text(de.quickEntryWhichDay), findsOneWidget);
      final chips = [
        for (final d in [first, second])
          find.widgetWithText(ChoiceChip, DateFormat.MMMEd('de').format(d)),
      ];
      for (final c in chips) {
        expect(c, findsOneWidget);
      }
      expect(enabled(tester, de.quickEntryAsEvent), isFalse);
      expect(enabled(tester, de.quickEntryAsTask), isFalse);
      await tap(tester, chips[1]);
      expect(enabled(tester, de.quickEntryAsEvent), isTrue);
      expect(enabled(tester, de.quickEntryAsTask), isTrue);
    }
    await tap(tester, sheetButton(de.quickEntryAsEvent));
    await waitFor(tester, eventEditorOpen);
    expect(
      shown(tester, de.commonStart).$1,
      buttonDate(ambiguous ? second : first),
    );
    await leaveField(tester);
    await back(tester);
    await waitGone(tester, eventEditorOpen);
    expect(engine.events.where((e) => e.title == 'E2E Elternabend'), isEmpty);
    await finish(tester, state);
  });

  testWidgets('GRU-067 GRU-068 a task from one line; no day, no title, days', (
    tester,
  ) async {
    final f = await theFamily();
    addTearDown(() async {
      await clean([
        Collections.tasks,
      ], only: (r) => r.data['title'] == 'E2E Müll rausbringen');
      await clean([
        Collections.events,
      ], only: (r) => r.data['title'] == 'E2E Skiurlaub');
    });
    tall(tester);
    final state = await startApp(tester);
    final engine = state.engine!;
    final taskEditor = find.text(de.tasksNewTask2);
    Finder chip(String label) => find.widgetWithText(InputChip, label);

    // GRU-067: without a time rather a task, due tomorrow.
    final tomorrow = inDays(1);
    await quickEntry(tester, 'morgen E2E Müll rausbringen');
    await waitFor(tester, find.text('E2E Müll rausbringen'));
    expect(highlighted(tester, de.quickEntryAsTask), isTrue);
    await tap(tester, sheetButton(de.quickEntryAsTask));
    await waitFor(tester, taskEditor);
    expect(
      tester
          .widget<TextField>(
            find.widgetWithText(TextField, de.commonTitle).last,
          )
          .controller!
          .text,
      'E2E Müll rausbringen',
    );
    expect(chip(DateFormat.MMMMEEEEd('de').format(tomorrow)), findsOneWidget);
    expect(chip(de.tasksRemind), findsOneWidget);
    await leaveField(tester);
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, taskEditor);
    await eventually(tester, 'the task with its day', () async {
      final tasks = await pull(f.admin, Collections.tasks);
      return tasks.values.any(
        (r) =>
            r.data['title'] == 'E2E Müll rausbringen' &&
            DateUtils.isSameDay(Task.fromRecord(r).due, tomorrow),
      );
    });

    // With a time still to come: the reminder too.
    final clockNow = DateTime.now();
    final (line, day, hour) = clockNow.hour < 23
        ? (
            'heute ${clockNow.hour + 1} Uhr E2E Blumen gießen',
            today(),
            clockNow.hour + 1,
          )
        : ('morgen 9 Uhr E2E Blumen gießen', tomorrow, 9);
    await quickEntry(tester, line);
    await waitFor(tester, find.text('E2E Blumen gießen'));
    expect(highlighted(tester, de.quickEntryAsEvent), isTrue);
    await tap(tester, sheetButton(de.quickEntryAsTask));
    await waitFor(tester, taskEditor);
    expect(chip(DateFormat.MMMMEEEEd('de').format(day)), findsOneWidget);
    final when = DateTime(day.year, day.month, day.day, hour);
    final dayWord = DateUtils.isSameDay(day, today())
        ? de.commonToday
        : de.commonTomorrow;
    expect(
      chip(
        de.tasksReminderTime('$dayWord, ${DateFormat.jm('de').format(when)}'),
      ),
      findsOneWidget,
      reason: onScreen(),
    );
    await leaveField(tester);
    await closeTop(tester, taskEditor);
    await waitGone(tester, taskEditor);

    // GRU-068: no day …
    await quickEntry(tester, 'E2E Zahnarzt anrufen');
    await waitFor(tester, find.text('E2E Zahnarzt anrufen'));
    expect(find.text(de.quickEntryNoDay), findsOneWidget);
    // … no title: today at that time.
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == de.quickEntryHint,
      ),
      '16 Uhr',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await waitFor(tester, find.text(de.quickEntryNoTitle));
    expect(find.text('${de.quickEntryNoDay} · ${clock(16)}'), findsOneWidget);
    await tap(tester, sheetButton(de.quickEntryAsEvent));
    await waitFor(tester, eventEditorOpen);
    expect(
      tester.widget<TextField>(field(de.commonTitle)).controller!.text,
      isEmpty,
    );
    expect(shown(tester, de.commonStart), (buttonDate(today()), clock(16)));
    await leaveField(tester);
    await back(tester);
    await waitGone(tester, eventEditorOpen);

    // … several days: all day.
    final now = today();
    final year = DateTime(now.year, 12, 4).isBefore(now)
        ? now.year + 1
        : now.year;
    await quickEntry(tester, 'vom 2. bis 4. Dezember E2E Skiurlaub');
    await waitFor(tester, find.text('E2E Skiurlaub'));
    await tap(tester, sheetButton(de.quickEntryAsEvent));
    await waitFor(tester, eventEditorOpen);
    expect(shown(tester, de.commonStart), (
      buttonDate(DateTime(year, 12, 2)),
      null,
    ));
    expect(shown(tester, de.commonEnd), (
      buttonDate(DateTime(year, 12, 4)),
      null,
    ));
    await leaveField(tester);
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, eventEditorOpen);
    await eventually(tester, 'the all-day appointment', () async {
      final events = await pull(f.admin, Collections.events);
      return events.values.any((r) {
        if (r.data['title'] != 'E2E Skiurlaub') return false;
        final e = CalendarEvent.fromRecord(r);
        return e.allDay &&
            DateUtils.isSameDay(e.start, DateTime(year, 12, 2)) &&
            DateUtils.isSameDay(e.end, DateTime(year, 12, 5));
      });
    });

    // Swiped away: nothing saved.
    final before =
        engine.records(Collections.tasks).length +
        engine.records(Collections.events).length;
    await quickEntry(tester, 'morgen E2E Weggewischt');
    await waitFor(tester, find.text('E2E Weggewischt'));
    await tester.tapAt(const Offset(400, 20));
    await tester.pump(const Duration(seconds: 1));
    await waitGone(tester, find.text('E2E Weggewischt'));
    expect(eventEditorOpen, findsNothing);
    expect(taskEditor, findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(
      engine.records(Collections.tasks).length +
          engine.records(Collections.events).length,
      before,
    );
    await finish(tester, state);
  });

  // --- Suche ---------------------------------------------------------------------

  testWidgets(
    'GRU-070 GRU-072 search and open a hit, also without the server',
    (tester) async {
      final f = await theFamily();
      final ids = <String, String>{};
      Future<void> add(
        String c,
        Map<String, Object?> Function(String id) data,
      ) async {
        final id = uid(c);
        ids[id] = c;
        await seed(f.admin, c, id, data(id));
      }

      addTearDown(() async {
        for (final MapEntry(key: id, value: c) in ids.entries) {
          await remove(f.admin, c, [id]);
        }
      });
      final tomorrow = inDays(1);
      await add(
        Collections.events,
        (id) => CalendarEvent(
          id: id,
          title: 'E2E Schwimmen Verein',
          start: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 17),
          end: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 18),
        ).toData(),
      );
      await add(
        Collections.tasks,
        (id) => Task(
          id: id,
          title: 'E2E Turnbeutel',
          notes: 'Schwimmen nicht vergessen',
        ).toData(),
      );
      await add(
        Collections.tasks,
        (id) => Task(id: id, title: 'E2E Schwimmen Tasche').toData(),
      );
      await add(
        Collections.recipes,
        (id) => Recipe(id: id, title: 'E2E Nudeln nach dem Schwimmen').toData(),
      );
      await add(
        Collections.contacts,
        (id) => FamilyContact(id: id, name: 'E2E Schwimmen Trainerin').toData(),
      );
      final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
      await gate.start();
      addTearDown(gate.close);
      tall(tester);
      final state = await startVia(
        tester,
        gate.url,
        kitUser,
        password: kitPassword,
      );
      await eventually(
        tester,
        'everything on this device',
        () async => state.engine!
            .records(Collections.contacts)
            .any((r) => r.data['name'] == 'E2E Schwimmen Trainerin'),
      );

      await openSearch(tester);
      expect(find.text(de.searchEverythingDeviceAlsoOffline), findsOneWidget);
      await search(tester, 'Schwimmen');
      final groups = [
        de.commonEvents,
        de.sectionTasks,
        de.mealsRecipes,
        de.sectionContacts,
      ];
      for (final g in groups) {
        await waitFor(tester, heading(g));
      }
      for (var i = 1; i < groups.length; i++) {
        expect(
          tester.getTopLeft(heading(groups[i])).dy,
          greaterThan(tester.getTopLeft(heading(groups[i - 1])).dy),
          reason: '${groups[i]} after ${groups[i - 1]}',
        );
      }
      // The title hit before the one in the notes.
      expect(
        tester.getTopLeft(find.text('E2E Schwimmen Tasche')).dy,
        lessThan(tester.getTopLeft(find.text('E2E Turnbeutel')).dy),
      );
      // A hit opens its editor; afterwards the search runs again.
      await tap(tester, find.text('E2E Schwimmen Tasche'));
      await waitFor(tester, find.text(de.tasksEditTask));
      await add(
        Collections.tasks,
        (id) => Task(id: id, title: 'E2E Schwimmen Neu').toData(),
      );
      await eventually(
        tester,
        'the new task here',
        () async =>
            state.engine!.tasks.any((t) => t.title == 'E2E Schwimmen Neu'),
      );
      await leaveField(tester);
      await closeTop(tester, find.text(de.tasksEditTask));
      await waitGone(tester, find.text(de.tasksEditTask));
      await waitFor(tester, find.text('E2E Schwimmen Neu'));
      // "Leeren"
      await tap(tester, find.byTooltip(de.settingsStorageClear));
      expect(tester.widget<TextField>(searchInput).controller!.text, isEmpty);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ListTile), findsNothing);

      // GRU-072: the server away, the same hits.
      gate.cut();
      await tester.pump(const Duration(seconds: 2));
      await search(tester, 'Schwimmen');
      for (final g in groups) {
        await waitFor(tester, heading(g));
      }
      expect(find.text('E2E Schwimmen Tasche'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await back(tester);
      gate.restore();
      await finish(tester, state);
    },
  );

  testWidgets('GRU-073 the search keeps to roles and areas', (tester) async {
    final f = await theFamily();
    final file = await f.admin.uploadFile(
      bytes: utf8.encode('E2E Ausweis'),
      name: 'ausweis.txt',
      mime: 'text/plain',
    );
    final doc = uid('document');
    final med = uid('medication');
    await seed(
      f.admin,
      Collections.documents,
      doc,
      FamilyDocument(
        id: doc,
        title: 'E2E Ausweis Lina',
        category: DocumentCategory.identity,
        file: file,
      ).toData(),
    );
    await seed(
      f.admin,
      Collections.medications,
      med,
      Medication(
        id: med,
        name: 'E2E Ibuprofen 400',
        asNeeded: true,
        start: today(),
      ).toData(),
    );
    addTearDown(() async {
      await remove(f.admin, Collections.documents, [doc]);
      await remove(f.admin, Collections.medications, [med]);
    });
    tall(tester);
    // The guest finds neither.
    var state = await startApp(tester, user: f.guest.username);
    await openSearch(tester);
    for (final word in ['Ausweis', 'Ibuprofen']) {
      await search(tester, word);
      await waitFor(tester, find.text(de.commonNothingFound));
    }
    await back(tester);
    await finish(tester, state);

    // The adult finds both; the document opens its area.
    state = await startApp(tester);
    await eventually(
      tester,
      'both on this device',
      () async => state.engine!
          .records(Collections.medications)
          .any((r) => r.id == med),
    );
    await openSearch(tester);
    await search(tester, 'Ibuprofen');
    await waitFor(tester, heading(de.commonMedications));
    expect(find.text('E2E Ibuprofen 400'), findsOneWidget);
    await search(tester, 'Ausweis');
    await waitFor(tester, heading(de.sectionDocuments));
    await tap(tester, find.text('E2E Ausweis Lina'));
    await waitGone(tester, searchInput);
    await eventually(
      tester,
      'the documents in front',
      () async => inFront(tester, find.byType(DocumentsScreen)),
    );
    await finish(tester, state);
  });

  // Runs last: the pairing of the first test is older than five minutes.
  testWidgets('GRU-042 a pairing code lasts five minutes', (tester) async {
    await makeEarlyPairing();
    final early = _earlyPairing!;
    while (DateTime.now().difference(early.at) <
        const Duration(minutes: 5, seconds: 10)) {
      await tester.pump(const Duration(seconds: 5));
    }
    debugPrint('E2E-INFO pairing age: ${DateTime.now().difference(early.at)}');
    final state = await startSignedOut(tester);
    await tap(tester, find.text(de.pairJoinTitle));
    await joinWithPairing(tester, early.link);
    await waitFor(tester, find.text(_invalidPairing));
    expect(state.me, isNull);
    await finish(tester, state);
  });
}
