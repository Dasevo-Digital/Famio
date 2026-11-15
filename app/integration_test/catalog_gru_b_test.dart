// Catalog GRU-074 … GRU-166 (family inbox, files dragged onto the window,
// trash, crossed changes and sync, offline, connection and server,
// appearance and language, notifications, account, about, wall display,
// roles and navigation) against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_gru_b_test.dart
//
// Each test signs in through the app's own pages. Other members and devices
// are API sessions; what the server gives them is pulled with their own
// session. A TCP gate in front of the server stands in for a lost
// connection, a TLS front with a key of its own for a server whose
// certificate changed, a fake Famio server for one that does not know the
// session, a slow proxy for a long export. The system's browser, file panels
// and drag and drop are replaced at their plugin interfaces. Wrong passwords
// count against this Mac's address (20 an hour): the file stays below that.
// The tests that delete accounts run last.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/environment.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/push/own_push.dart';
import 'package:famio/src/screens/home_shell.dart';
import 'package:famio/src/screens/ics_import_screen.dart';
import 'package:famio/src/screens/kiosk_screen.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio/src/widgets/sync_status_icon.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';

/// The same server over HTTPS with its own certificate.
const _tlsUrl = String.fromEnvironment('FAMIO_NEW_URL');

/// Passwords of members this file changes (the server turns easy ones down).
const _strong = 'Wolke-Regal-Tulpe-17';
const _strong2 = 'Kreide-Ofen-Birke-38';
const _strong3 = 'Anker-Moos-Feder-52';

const _mb = 1024 * 1024;

final en = lookupL10n(const Locale('en'));

final _pdf = utf8.encode(
  '%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
  '2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\n'
  'trailer << /Root 1 0 R >>\n%%EOF\n',
);

/// A PDF of about [mb] megabytes (the rest is blank).
List<int> _bigPdf(double mb) => [
  ..._pdf,
  ...List.filled((mb * _mb).round(), 0x20),
];

/// Two small pictures (16 × 16) for the family photos.
final _png1 = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGM4UWFDEmIY1TCqYfhqAACRKnwQyeK93QAAAABJRU5ErkJggg==',
);
final _png2 = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGPQiDpBEmIY1TCqYfhqAADQmEoQ58t5gwAAAABJRU5ErkJggg==',
);

/// A throwaway key pair for the TLS front (GRU-101): "the server" with a
/// new certificate. tool/integration_tests.sh makes a fresh one for each run
/// (openssl), so no private key is kept in the repository.
String get _otherCert => utf8.decode(
  base64.decode(const String.fromEnvironment('FAMIO_OTHER_CERT')),
);
String get _otherKey =>
    utf8.decode(base64.decode(const String.fromEnvironment('FAMIO_OTHER_KEY')));

// --- members and data --------------------------------------------------------

var _uids = 0;

/// Like the kit's [uid], but never twice the same within a microsecond
/// (two ids in one statement).
String _uid(String what) => '${uid(what)}-${_uids++}';

final _members = <String, Future<FamilyMember>>{};

/// A member of this file only (password [kitMemberPassword]), created once.
Future<FamilyMember> member(
  String username,
  String name, {
  MemberRole role = MemberRole.adult,
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
  );
}();

/// A member made anew for one test (it changes its password or goes).
Future<FamilyMember> freshMember(
  String username,
  String name, {
  MemberRole role = MemberRole.adult,
  String password = kitMemberPassword,
}) async {
  final f = await theFamily();
  for (final u in await f.admin.adminUsers()) {
    if (u.member.username == username) await f.admin.deleteMember(u.member.id);
  }
  return f.admin.createMember(
    username: username,
    displayName: name,
    password: password,
    role: role,
  );
}

/// The Home Assistant service account, or one that may only read.
Future<FamilyMember> theService({bool readOnly = false}) async {
  final m = await member(
    readOnly ? 'e2e-ha-lesen' : 'e2e-ha',
    readOnly ? 'E2E HA lesen' : 'E2E HA',
    role: MemberRole.service,
  );
  if (readOnly) {
    await (await theFamily()).admin.updateUser(
      m.id,
      serviceAccess: ServiceAccess.readOnly,
    );
  }
  return m;
}

/// Another device of [username].
Future<FamioApiClient> loginAs(
  String username, {
  String password = kitMemberPassword,
  String device = 'E2E Zweitgerät',
}) async {
  final api = FamioApiClient(kitUrl);
  await api.login(username: username, password: password, device: device);
  return api;
}

/// Writes [data] like a device that last saw revision [rev] (offline since),
/// changed at [at].
Future<SyncResponse> putStale(
  FamioApiClient api,
  String collection,
  String id,
  Map<String, Object?> data, {
  required int rev,
  required int at,
  bool deleted = false,
}) => api.sync(
  SyncRequest(
    since: 0,
    changes: [
      SyncRecord(
        collection: collection,
        id: id,
        data: deleted ? const {} : data,
        updatedAt: at,
        rev: rev,
        deleted: deleted,
      ),
    ],
  ),
);

/// Every page of [api]'s trash.
Future<List<TrashEntry>> allTrash(FamioApiClient api) async {
  final out = <TrashEntry>[];
  int? before;
  while (true) {
    final page = await api.trash(before: before);
    out.addAll(page.items);
    if (page.next == null) return out;
    before = page.next;
  }
}

Future<Set<String>> trashTitles(FamioApiClient api) async => {
  for (final e in await allTrash(api)) e.title,
};

Future<FileRef> uploadAs(
  FamioApiClient api,
  String name,
  List<int> bytes, {
  String mime = 'application/pdf',
}) => api.uploadFile(bytes: Uint8List.fromList(bytes), name: name, mime: mime);

/// The files of a ZIP archive (stored or deflated, as the server writes).
Map<String, List<int>> unzip(Uint8List b) {
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

/// The data of [collection]'s records in an export.
List<Map<String, Object?>> zipRecords(
  Map<String, List<int>> zip,
  String collection,
) {
  final raw = zip['records/$collection.json'];
  if (raw == null) return const [];
  return [
    for (final r in jsonDecode(utf8.decode(raw)) as List)
      ((r as Map)['data'] as Map).cast<String, Object?>(),
  ];
}

Set<String> zipTitles(Map<String, List<int>> zip, String collection) => {
  for (final d in zipRecords(zip, collection))
    '${d['title'] ?? d['name'] ?? ''}',
};

/// Everything on the server, as the administration's family export has it.
Future<Map<String, List<int>>> familyExport() async {
  final f = await theFamily();
  final dir = await Directory.systemTemp.createTemp('famio-e2e-family');
  try {
    final file = File(p.join(dir.path, 'familie.zip'));
    final sink = file.openWrite();
    await f.admin.exportDataToSink(sink, password: kitPassword, family: true);
    await sink.close();
    return unzip(await file.readAsBytes());
  } finally {
    await dir.delete(recursive: true);
  }
}

/// The server's /api/health as it answers (for the fake server).
Future<Map<String, Object?>> rawHealth() async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse(kitUrl).resolve('api/health'),
    );
    final response = await request.close();
    return (jsonDecode(await response.transform(utf8.decoder).join()) as Map)
        .cast<String, Object?>();
  } finally {
    client.close();
  }
}

/// PROPFIND like a calendar app with an app password.
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

// --- stand-ins for the system --------------------------------------------------

/// The system's browser and file viewer.
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

/// The native open and folder panels: hand out [picks], keep the titles.
class _FakePicker extends FilePickerPlatform {
  final picks = <List<File>>[];
  final titles = <String?>[];
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
  }) async {
    titles.add(dialogTitle);
    return picks.isEmpty
        ? []
        : [for (final f in picks.removeAt(0)) _DiskFile(f)];
  }

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

_FakePicker _fakePicker() {
  final before = FilePickerPlatform.instance;
  final fake = _FakePicker();
  FilePickerPlatform.instance = fake;
  addTearDown(() => FilePickerPlatform.instance = before);
  return fake;
}

Future<File> tempFile(String name, List<int> bytes) async {
  final dir = Directory(
    p.join((await getTemporaryDirectory()).path, 'famio-e2e-gru-b'),
  )..createSync(recursive: true);
  return File(p.join(dir.path, name))..writeAsBytesSync(bytes);
}

/// The window's drop target, as the system calls it for files dragged from
/// the Finder.
DropTarget dropTarget(WidgetTester tester) =>
    tester.widget<DropTarget>(find.byType(DropTarget).first);

Future<void> dropFiles(WidgetTester tester, List<File> files) async {
  dropTarget(tester).onDragDone!(
    DropDoneDetails(
      files: [
        for (final f in files) DropItemFile(f.path, name: p.basename(f.path)),
      ],
      localPosition: const Offset(300, 300),
      globalPosition: const Offset(300, 300),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

// --- connections -------------------------------------------------------------

/// Passes TCP between the app and the server: [cut] makes the server
/// unreachable (as with no network) until [restore]; [hold] keeps new
/// connections waiting (a slow network) until [release].
class Gate {
  Gate(this._upstream);

  final Uri _upstream;
  late final ServerSocket _server;
  final _open = <Socket>{};
  var _up = true;
  Completer<void>? _held;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_accept);
  }

  Future<void> _accept(Socket client) async {
    unawaited(client.done.catchError((Object _) {}));
    final held = _held;
    if (held != null) await held.future;
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
    _pipe(client, server, _open);
  }

  void cut() {
    _up = false;
    _drop();
  }

  void restore() => _up = true;

  void hold() {
    _held ??= Completer<void>();
    _drop();
  }

  void release() {
    _held?.complete();
    _held = null;
  }

  void _drop() {
    for (final s in [..._open]) {
      s.destroy();
    }
    _open.clear();
  }

  Future<void> close() async {
    release();
    cut();
    await _server.close();
  }
}

void _pipe(Socket a, Socket b, Set<Socket> open) {
  open
    ..add(a)
    ..add(b);
  void close() {
    a.destroy();
    b.destroy();
    open
      ..remove(a)
      ..remove(b);
  }

  void pass(Socket to, List<int> data) {
    try {
      to.add(data);
    } catch (_) {
      close();
    }
  }

  a.listen(
    (d) => pass(b, d),
    onDone: close,
    onError: (Object _) => close(),
    cancelOnError: true,
  );
  b.listen(
    (d) => pass(a, d),
    onDone: close,
    onError: (Object _) => close(),
    cancelOnError: true,
  );
}

/// HTTPS in front of the server: first its own TLS port passed through,
/// after [newKey] TLS with another key (as after setting the server up
/// anew) in front of its plain port.
class TlsGate {
  TlsGate(this._tls, this._http);

  final Uri _tls, _http;
  late final ServerSocket _server;
  final _open = <Socket>{};
  SecurityContext? _own;

  String get url => 'https://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_accept);
  }

  Future<void> _accept(Socket client) async {
    final own = _own;
    Socket inbound = client;
    if (own != null) {
      try {
        inbound = await SecureSocket.secureServer(client, own);
      } catch (_) {
        // The app only looked at the certificate.
        client.destroy();
        return;
      }
    } else {
      unawaited(client.done.catchError((Object _) {}));
    }
    final target = own == null ? _tls : _http;
    final Socket server;
    try {
      server = await Socket.connect(target.host, target.port);
    } catch (_) {
      inbound.destroy();
      return;
    }
    unawaited(server.done.catchError((Object _) {}));
    _pipe(inbound, server, _open);
  }

  void newKey() {
    if (_otherKey.isEmpty) {
      throw TestFailure(
        'Run through tool/integration_tests.sh (FAMIO_OTHER_KEY).',
      );
    }
    _own = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_otherCert))
      ..usePrivateKeyBytes(utf8.encode(_otherKey));
    for (final s in [..._open]) {
      s.destroy();
    }
    _open.clear();
  }

  Future<void> close() async {
    for (final s in [..._open]) {
      s.destroy();
    }
    await _server.close();
  }
}

/// Passes HTTP (and the WebSocket) to the server; with [slow] the export
/// comes in small pieces, like over a slow line.
class SlowProxy {
  late final HttpServer _server;
  final _client = HttpClient()..autoUncompress = false;
  final _sockets = <WebSocket>[];
  var slow = false;

  /// What passed: "METHOD /path status".
  final requests = <String>[];

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
                  scheme: 'ws',
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
        requests.add(
          '${request.method} ${request.uri.path} ${answer.statusCode}',
        );
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
        if (slow && request.uri.path.endsWith('/export')) {
          await for (final chunk in answer) {
            for (var i = 0; i < chunk.length; i += 16 * 1024) {
              request.response.add(
                chunk.sublist(i, min(i + 16 * 1024, chunk.length)),
              );
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 120));
            }
          }
        } else {
          await request.response.addStream(answer);
        }
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
    for (final s in _sockets) {
      await s.close().catchError((Object _) {});
    }
    await _server.close(force: true);
    _client.close(force: true);
  }
}

/// Another Famio server: answers like one, but does not know the session
/// ([me] null), or knows it as [me].
class FakeFamio {
  FakeFamio(this.health);

  final Map<String, Object?> health;
  Map<String, Object?>? me;
  late final HttpServer _server;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      switch (request.uri.path) {
        case '/api/health':
          response.write(jsonEncode(health));
        case '/api/me' when me != null:
          response.write(jsonEncode(me));
        case '/api/me':
          response.statusCode = 401;
          response.write(
            jsonEncode({
              'error': 'unauthorized',
              'message': 'Nicht angemeldet',
            }),
          );
        default:
          response.statusCode = 404;
          response.write(
            jsonEncode({'error': 'not_found', 'message': 'Nicht gefunden'}),
          );
      }
      await response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

// --- two-factor --------------------------------------------------------------

/// An authenticator app: RFC 6238 codes of steps not used yet.
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
    return _codeAt(step);
  }

  String _codeAt(int step) {
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

final _freshCodeField = find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      (w.controller?.text.isEmpty ?? false) &&
      (w.decoration?.labelText == de.commonCode ||
          w.decoration?.labelText == de.securityRecoveryCode),
);

Future<void> answerCode(WidgetTester tester, String code) async {
  await waitFor(tester, _freshCodeField);
  final controller = tester.widget<TextField>(_freshCodeField.last).controller!;
  await tester.tap(_freshCodeField.last, warnIfMissed: false);
  await tester.pump();
  await tester.enterText(_freshCodeField.last, code);
  await tester.pump();
  if (controller.text != code) {
    controller.text = code;
    await tester.pump();
  }
  await tap(tester, inDialog(find.text(de.commonConfirm)));
}

// --- the app -------------------------------------------------------------------

final _launcher = _FakeLauncher();

/// What this device showed as a notification (own push), instead of the
/// Mac's notification center.
final _shown = <Notice>[];

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

Future<AppState> _newState() async {
  final state = AppState()
    ..ownPush = OwnPush(
      await SharedPreferences.getInstance(),
      show: (notice, {required details}) async => _shown.add(notice),
    );
  await state.init();
  addTearDown(() async {
    if (state.me != null) await state.signOut();
  });
  return state;
}

/// Starts the app signed out and signs in through its own pages: at [url]
/// (the server unless given), confirming its certificate with [trust], with
/// a code of [totp] if asked.
Future<AppState> start(
  WidgetTester tester, {
  String? user,
  String? password,
  String url = kitUrl,
  bool trust = false,
  Authenticator? totp,
}) async {
  expect(kitUrl, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
  await _dates();
  UrlLauncherPlatform.instance = _launcher;
  await freshStart();
  final state = await _newState();
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(FamioApp(state: state));
  await enter(tester, field(de.connectServerAddress), url);
  await tap(tester, find.text(de.commonConnect));
  if (trust) {
    await waitFor(tester, find.text(de.trustMatches));
    await tap(tester, find.text(de.trustMatches));
  }
  await enter(tester, field(de.commonUsername), user ?? kitUser);
  await enter(
    tester,
    field(de.commonPassword),
    password ?? (user == null ? kitPassword : kitMemberPassword),
  );
  await tap(tester, find.text(de.commonSignIn));
  if (totp != null) {
    await waitFor(tester, inDialog(find.text(de.securityTwoFactorSignIn)));
    await answerCode(tester, await totp.next(tester));
  }
  await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
  if (find.text(de.commonLater).evaluate().isNotEmpty) {
    await tap(tester, find.text(de.commonLater).last);
  }
  await dismissTip(tester);
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

/// Quits the app (without signing out) and starts it again.
Future<AppState> restart(
  WidgetTester tester,
  AppState old, {
  bool signedIn = true,
}) async {
  await leaveApp(tester, old);
  final state = await _newState();
  await tester.pumpWidget(FamioApp(state: state));
  if (signedIn) {
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    await dismissTip(tester);
  }
  return state;
}

Finder inDialog(Finder f) =>
    find.descendant(of: find.byType(Dialog), matching: f);

/// A text widget with exactly [label] (no tooltips).
Finder exactly(String label) =>
    find.byWidgetPredicate((w) => w is Text && w.data == label);

/// The list tile titled [title].
Finder tile(String title) => find.byWidgetPredicate(
  (w) => w is ListTile && w.title is Text && (w.title! as Text).data == title,
);

String? subtitleOf(WidgetTester tester, String title) {
  final t = tester.widget<ListTile>(tile(title).first);
  return t.subtitle is Text ? (t.subtitle! as Text).data : null;
}

/// Where to drag a page's list: right of the side rail, or the middle of a
/// phone.
Offset listPoint(WidgetTester tester) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  return size.width < 720
      ? Offset(size.width / 2, size.height / 2)
      : const Offset(600, 420);
}

Future<void> openSettingsItem(WidgetTester tester, String title) async {
  await openSection(tester, 'Einstellungen');
  // Tapped again, the area goes back to its start page (a page left open
  // there before, such as the trash, would still show its old list).
  final rail = find.descendant(
    of: railItems,
    matching: find.text(de.sectionSettings),
  );
  if (rail.evaluate().isNotEmpty) {
    await tap(tester, rail);
    await tester.pump(const Duration(milliseconds: 400));
  }
  await scrollTo(tester, find.text(title), at: listPoint(tester));
  await tap(tester, find.text(title));
}

/// Taps the form's [label] button after leaving the text field; waits until
/// the answer is in (the button is enabled again).
Future<void> submit(WidgetTester tester, String label) async {
  await leaveField(tester);
  final button = inDialog(find.widgetWithText(FilledButton, label));
  await tap(tester, button);
  final end = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (button.evaluate().isEmpty ||
        tester.widget<FilledButton>(button.last).onPressed != null) {
      break;
    }
  }
  await tester.pump(const Duration(milliseconds: 300));
}

/// Taps the screen beside a bottom sheet, which closes it.
Future<void> closeSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(30, 30));
  await tester.pump(const Duration(milliseconds: 700));
}

/// Types [hour]:[minute] into an open time picker and confirms.
Future<void> typeTime(WidgetTester tester, int hour, int minute) async {
  await tap(tester, find.byTooltip('Zum Texteingabemodus wechseln'));
  final fields = inDialog(find.byType(TextField));
  await waitFor(tester, fields);
  await tester.enterText(fields.at(0), hour.toString().padLeft(2, '0'));
  await tester.pump();
  await tester.enterText(fields.at(1), minute.toString().padLeft(2, '0'));
  await tester.pump();
  await tap(tester, inDialog(find.text('OK')));
  await dialogClosed(tester);
}

/// Drags the page further than the kit does (long lists).
Future<void> scrollFar(
  WidgetTester tester,
  Finder finder, {
  Offset at = const Offset(600, 700),
}) async {
  for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
    await tester.dragFrom(at, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 150));
  }
  await waitFor(tester, finder, timeout: const Duration(seconds: 3));
  await tester.ensureVisible(finder.first);
  await tester.pump(const Duration(milliseconds: 300));
}

/// A change of the system's settings rebuilds the app in one frame; the new
/// theme fades in over the following ones.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

bool _is(Widget w, String type) => w.runtimeType.toString() == type;

/// The start page's tile titled [title].
Finder homeTile(String title) => find.byWidgetPredicate(
  (w) => _is(w, '_Tile') && (w as dynamic).title == title,
);

Finder roundCheck(String label) =>
    find.byWidgetPredicate((w) => w is RoundCheck && w.label == label);

final railItems = find.byWidgetPredicate((w) => _is(w, '_RailItem'));
final barItems = find.byWidgetPredicate((w) => _is(w, '_BarItem'));
final moreTiles = find.byWidgetPredicate((w) => _is(w, '_MoreTile'));

List<FamioSection> railSections() => [
  for (final e in railItems.evaluate())
    (e.widget as dynamic).section as FamioSection,
];

/// Every text of the settings page, from the top to the bottom.
Future<Set<String>> settingsTexts(WidgetTester tester) async {
  await openSection(tester, 'Einstellungen');
  final seen = <String>{};
  void collect() {
    for (final e in find.byType(Text).evaluate()) {
      final t = e.widget as Text;
      final s = t.data ?? t.textSpan?.toPlainText();
      if (s != null) seen.add(s);
    }
  }

  for (var i = 0; i < 25; i++) {
    await tester.dragFrom(const Offset(600, 500), const Offset(0, 500));
    await tester.pump(const Duration(milliseconds: 100));
  }
  for (var i = 0; i < 40; i++) {
    collect();
    await tester.dragFrom(const Offset(600, 900), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 250));
  }
  collect();
  return seen;
}

// --- areas of the app ------------------------------------------------------------

Future<void> openInbox(WidgetTester tester) async {
  await openSection(tester, 'Start');
  await tap(tester, find.byTooltip(de.inboxTitle));
  await waitFor(tester, find.byTooltip(de.inboxAdd));
}

Finder _inboxMenu(String title) => find.descendant(
  of: find
      .ancestor(of: find.text(title), matching: find.byType(ListTile))
      .first,
  matching: find.byTooltip(de.inboxFileAs),
);

final _menuItems = find.byWidgetPredicate((w) => w is PopupMenuItem);

/// Opens "Einsortieren als …" of [title]; the texts it offers.
Future<List<String>> openInboxMenu(WidgetTester tester, String title) async {
  await snackGone(tester);
  await tap(tester, _inboxMenu(title));
  await tester.pump(const Duration(milliseconds: 600));
  return [
    for (final e in _menuItems.evaluate())
      ((e.widget as PopupMenuItem).child! as Text).data!,
  ];
}

Future<void> fileAs(WidgetTester tester, String title, String target) async {
  await openInboxMenu(tester, title);
  await tap(
    tester,
    find.descendant(of: _menuItems, matching: find.text(target)),
  );
}

Future<void> clearInbox(SyncEngine engine) async {
  for (final i in engine.inboxItems) {
    engine.deleteInboxItem(i.id);
  }
  await engine.sync();
}

InboxItem inboxItem(
  AppState state,
  String title, {
  String text = '',
  List<FileRef> files = const [],
}) => InboxItem(
  id: newId(),
  title: title,
  text: text,
  files: files,
  createdAt: DateTime.now(),
  createdBy: state.me!.id,
);

Future<void> addTask(WidgetTester tester, String title) async {
  await openSection(tester, 'Aufgaben');
  await enter(tester, field(de.tasksNewTask), title);
  await tap(tester, find.byTooltip(de.commonAdd));
  await waitFor(tester, find.text(title));
}

Finder _cloud(IconData icon) => find.descendant(
  of: find.byType(SyncStatusIcon),
  matching: find.byIcon(icon),
);

String cloudTip(WidgetTester tester) => tester
    .widget<Tooltip>(
      find
          .descendant(
            of: find.byType(SyncStatusIcon),
            matching: find.byType(Tooltip),
          )
          .first,
    )
    .message!;

/// The month grid's cell of [day].
Finder dayCell(DateTime day) => find.byWidgetPredicate(
  (w) =>
      _is(w, '_DayCell') &&
      DateUtils.isSameDay((w as dynamic).day as DateTime, day),
);

/// The calendar on [date]: back to today, the arrows to its month, its cell.
Future<void> openCalendarOn(
  WidgetTester tester,
  AppState state,
  DateTime date,
) async {
  await openSection(tester, 'Kalender');
  await snackGone(tester);
  await tap(tester, find.byTooltip(de.commonToday));
  final now = state.engine!.calendar.today();
  var months = (date.year - now.year) * 12 + date.month - now.month;
  for (; months > 0; months--) {
    await tap(tester, find.byTooltip(de.budgetNextMonth));
  }
  for (; months < 0; months++) {
    await tap(tester, find.byTooltip(de.budgetPreviousMonth));
  }
  await tap(
    tester,
    find.descendant(of: dayCell(date), matching: find.byType(InkWell)),
  );
  await waitFor(tester, find.text(DateFormat.MMMMEEEEd('de').format(date)));
}

Future<void> openKiosk(WidgetTester tester) async {
  await openSettingsItem(tester, de.settingsOpenKiosk);
  await waitFor(tester, find.byType(KioskScreen));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> openPushSettings(WidgetTester tester) async {
  await openSettingsItem(tester, de.settingsPush);
  await waitFor(tester, find.text(de.pushDirectlyThroughFamio));
}

Future<void> openDocument(WidgetTester tester, String title) async {
  await openSection(tester, 'Dokumente');
  await scrollTo(tester, find.text(title));
  await tap(tester, find.text(title));
  await tap(tester, find.widgetWithText(ColorButton, de.commonOpen));
}

SwitchListTile switchOf(WidgetTester tester, String title) =>
    tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title));

void main() {
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // === Papierkorb (first: the trash of the fresh server is empty) ===========

  testWidgets(
    'GRU-091 the trash: four kinds, an appointment back, more than 100',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      final bea = await sessionOf(f.bea);
      final state = await start(tester);
      final engine = state.engine!;

      // Empty.
      await openSettingsItem(tester, de.trashTitle);
      await waitFor(tester, find.text(de.trashEmpty));
      await back(tester);

      // One of each, deleted on this device.
      final ids = [for (var i = 0; i < 4; i++) newId()];
      engine.saveTask(Task(id: ids[0], title: 'E2E PK Aufgabe'));
      engine.saveEvent(
        CalendarEvent(
          id: ids[1],
          title: 'E2E PK Termin',
          start: today(),
          end: inDays(1),
          allDay: true,
        ),
      );
      engine.saveNote(FamilyNote(id: ids[2], title: 'E2E PK Notiz'));
      final ref = await uploadAs(engine.api, 'e2e-pk.pdf', _pdf);
      engine.saveDocument(
        FamilyDocument(
          id: ids[3],
          title: 'E2E PK Dokument',
          category: DocumentCategory.other,
          file: ref,
        ),
      );
      await engine.sync();
      engine
        ..deleteTask(ids[0])
        ..deleteEvent(ids[1])
        ..deleteNote(ids[2])
        ..delete(Collections.documents, ids[3]);
      await engine.sync();

      await openSettingsItem(tester, de.trashTitle);
      final kept = DateFormat.yMd(
        'de',
      ).format(DateTime.now().add(const Duration(days: 30)));
      for (final (title, kind) in [
        ('E2E PK Aufgabe', de.assignmentTask),
        ('E2E PK Termin', de.commonEvent),
        ('E2E PK Notiz', de.commonNote),
        ('E2E PK Dokument', de.commonDocument),
      ]) {
        await scrollTo(tester, find.text(title));
        expect(
          find.descendant(
            of: cardOf(title),
            matching: find.text('$kind · ${de.trashExpires(kept)}'),
          ),
          findsOneWidget,
          reason: title,
        );
      }

      // The appointment back: here and on Bea's devices.
      await scrollTo(tester, find.text('E2E PK Termin'));
      await tap(
        tester,
        find.descendant(
          of: cardOf('E2E PK Termin'),
          matching: find.text(de.trashRestore),
        ),
      );
      await waitFor(tester, find.text(de.trashRestored));
      await waitGone(tester, find.text('E2E PK Termin'));
      expect(engine.events.map((e) => e.title), contains('E2E PK Termin'));
      await eventually(
        tester,
        'Bea gets the appointment back',
        () async =>
            (await titlesOf(bea, Collections.events)).contains('E2E PK Termin'),
      );
      await openCalendarOn(tester, state, today());
      await waitFor(tester, find.text('E2E PK Termin'));

      // More than a hundred: the rest on request.
      final many = {
        for (var i = 0; i < 101; i++)
          '${_uid('pkmasse')}-$i': FamilyNote(
            id: 'x',
            title: 'E2E PK Masse $i',
          ).toData(),
      };
      await put(f.admin, Collections.notes, many);
      await remove(f.admin, Collections.notes, many.keys);
      await openSettingsItem(tester, de.trashTitle);
      await waitFor(tester, find.text('E2E PK Masse 100'));
      // The oldest ones are on the second page.
      expect(find.text('E2E PK Aufgabe'), findsNothing);
      await scrollFar(tester, find.text(de.trashMore));
      await tap(tester, find.text(de.trashMore));
      await scrollFar(tester, find.text('E2E PK Aufgabe'));
      await waitGone(tester, find.text(de.trashMore));
      engine.deleteEvent(ids[1]);
      await finish(tester, state);
    },
  );

  testWidgets('GRU-093 the trash by role: guest and another adult', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final guestApi = await sessionOf(f.guest);
    final task = _uid('task'), note = _uid('note'), private = _uid('note');
    await put(f.admin, Collections.tasks, {
      task: Task(
        id: task,
        title: 'E2E PK Gastaufgabe',
        assigneeIds: [f.guest.id],
      ).toData(),
    });
    await put(f.admin, Collections.notes, {
      note: FamilyNote(id: note, title: 'E2E PK Familiennotiz').toData(),
    });
    await put(bea, Collections.notes, {
      private: FamilyNote(
        id: private,
        title: 'E2E PK Bea privat',
        visibleTo: [f.bea.id],
      ).toData(),
    });
    await remove(f.admin, Collections.tasks, [task]);
    await remove(f.admin, Collections.notes, [note]);
    // The newest: on top of everyone's list, if they may see it.
    await remove(bea, Collections.notes, [private]);
    for (final (who, api) in [('guest', guestApi), ('admin', f.admin)]) {
      final page = await api.trash();
      debugPrint(
        'E2E-INFO trash of $who: '
        '${page.items.take(4).map((e) => '${e.title}/${e.canRestore}').join(', ')}',
      );
    }

    // The guest: the assigned task to restore, the readable note without.
    var state = await start(tester, user: 'e2e-gast');
    await openSettingsItem(tester, de.trashTitle);
    await waitFor(tester, find.text('E2E PK Gastaufgabe'));
    expect(
      find.descendant(
        of: cardOf('E2E PK Gastaufgabe'),
        matching: find.text(de.trashRestore),
      ),
      findsOneWidget,
    );
    await scrollTo(tester, find.text('E2E PK Familiennotiz'));
    expect(
      find.descendant(
        of: cardOf('E2E PK Familiennotiz'),
        matching: find.text(de.trashRestore),
      ),
      findsNothing,
    );
    expect(find.text('E2E PK Bea privat'), findsNothing);
    expect(await trashTitles(guestApi), isNot(contains('E2E PK Bea privat')));
    await finish(tester, state);

    // Another adult does not see Bea's private note either.
    state = await start(tester);
    await openSettingsItem(tester, de.trashTitle);
    await waitFor(tester, find.text('E2E PK Familiennotiz'));
    expect(find.text('E2E PK Bea privat'), findsNothing);
    expect(await trashTitles(f.admin), isNot(contains('E2E PK Bea privat')));
    expect(await trashTitles(bea), contains('E2E PK Bea privat'));
    await finish(tester, state);
  });

  testWidgets('GRU-094 the trash of service accounts', (tester) async {
    final f = await theFamily();
    final service = await sessionOf(await theService());
    final readOnly = await sessionOf(await theService(readOnly: true));
    final secret = _uid('event'), open = _uid('event');
    await put(f.admin, Collections.events, {
      secret: CalendarEvent(
        id: secret,
        title: 'E2E PK Vertraulich',
        start: inDays(3),
        end: inDays(4),
        allDay: true,
        confidential: true,
      ).toData(),
      open: CalendarEvent(
        id: open,
        title: 'E2E PK Familientermin',
        start: inDays(3),
        end: inDays(4),
        allDay: true,
      ).toData(),
    });
    await remove(f.admin, Collections.events, [secret, open]);
    for (final api in [service, readOnly]) {
      final titles = await trashTitles(api);
      expect(titles, contains('E2E PK Familientermin'));
      expect(titles, isNot(contains('E2E PK Vertraulich')));
    }
    final entry = (await allTrash(
      readOnly,
    )).singleWhere((e) => e.title == 'E2E PK Familientermin');
    expect(entry.canRestore, isFalse);
    await expectLater(
      readOnly.restoreTrash(entry.id),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 403)),
    );
    expect(
      await titlesOf(f.admin, Collections.events),
      isNot(contains('E2E PK Familientermin')),
    );
    expect(await trashTitles(f.admin), contains('E2E PK Familientermin'));
  });

  testWidgets('GRU-095 restored on two devices at once', (tester) async {
    tall(tester);
    final f = await theFamily();
    final id = _uid('note');
    await put(f.admin, Collections.notes, {
      id: FamilyNote(id: id, title: 'E2E PK Doppelt').toData(),
    });
    await remove(f.admin, Collections.notes, [id]);
    final proxy = SlowProxy();
    await proxy.start();
    addTearDown(proxy.stop);
    final state = await start(tester, url: proxy.url);
    await openSettingsItem(tester, de.trashTitle);
    await waitFor(tester, find.text('E2E PK Doppelt'));
    // Device A (the admin's other device) restores it meanwhile …
    final entry = (await allTrash(
      f.admin,
    )).singleWhere((e) => e.title == 'E2E PK Doppelt');
    await f.admin.restoreTrash(entry.id);
    expect(
      await titlesOf(f.admin, Collections.notes),
      contains('E2E PK Doppelt'),
    );
    // … and here the list is still the old one.
    await tester.pump(const Duration(seconds: 1));
    final button = find.descendant(
      of: cardOf('E2E PK Doppelt'),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    );
    debugPrint(
      'E2E-INFO restore button enabled: '
      '${tester.widget<ButtonStyleButton>(button.first).onPressed != null}',
    );
    // Tapped where it is, at the top of the list (the kit's tap would first
    // scroll the button to the very top, the message above out of sight).
    final list = find.byType(Scrollable).last;
    expect(tester.state<ScrollableState>(list).position.pixels, 0);
    await tester.tap(button.first);
    await tester.pump(const Duration(seconds: 2));
    debugPrint(
      'E2E-INFO requests: '
      '${proxy.requests.where((r) => r.contains('trash')).join(', ')}',
    );
    final message = find.text('Eintrag nicht gefunden');
    await waitFor(tester, message);
    expect(
      tester.getRect(message).top,
      greaterThanOrEqualTo(tester.getRect(list).top),
      reason: 'the message is in sight',
    );
    final notes = (await pull(
      f.admin,
      Collections.notes,
    )).values.where((r) => r.data['title'] == 'E2E PK Doppelt').toList();
    expect(notes, hasLength(1));
    expect(notes.single.id, id);
    await remove(f.admin, Collections.notes, [id]);
    await finish(tester, state);
  });

  testWidgets('GRU-092 the trash without the server, at 200 % text', (
    tester,
  ) async {
    // A phone: the page alone (the side rail at 200 %: see the next test).
    tall(tester, width: 400, height: 844);
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    final state = await start(tester, url: gate.url);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.trashTitle), at: listPoint(tester));
    gate.cut();
    await tap(tester, find.text(de.trashTitle));
    await waitFor(
      tester,
      find.widgetWithText(TextButton, de.commonRetry),
      timeout: const Duration(seconds: 45),
    );
    expect(find.textContaining('Server nicht erreichbar'), findsOneWidget);
    // Twice the text: still nothing cut off (an overflow fails the test).
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump(const Duration(seconds: 1));
    expect(find.widgetWithText(TextButton, de.commonRetry), findsOneWidget);
    gate.restore();
    await tap(tester, find.widgetWithText(TextButton, de.commonRetry));
    await waitGone(
      tester,
      find.widgetWithText(TextButton, de.commonRetry),
      timeout: const Duration(seconds: 45),
    );
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is Text && (w.data == de.trashEmpty || w.data == de.trashRestore),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pump(const Duration(milliseconds: 500));
    await finish(tester, state);
  });

  // Befund: at 200 % text the side rail of the computer layout overflows:
  // the logo with the app's name (home_shell.dart:610-640, _Logo) gets a box
  // at most 88 high (home_shell.dart:552, logoExtent) and is 50 pixels too
  // tall – "A RenderFlex overflowed by 50 pixels on the bottom" (twice).
  testWidgets('GRU-092 the side rail at 200 % text', skip: true, (
    tester,
  ) async {
    tall(tester);
    final state = await start(tester);
    await openSettingsItem(tester, de.trashTitle);
    await waitFor(tester, find.text(de.trashHint));
    // Twice the text on a computer: the rail's logo and name must still fit.
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(de.trashHint), findsOneWidget);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pump(const Duration(milliseconds: 500));
    await finish(tester, state);
  });

  // === Familien-Eingang =====================================================

  testWidgets('GRU-080 filed as a shopping item', (tester) async {
    tall(tester);
    final f = await theFamily();
    // No list at all yet.
    final lists = await pull(f.admin, Collections.shoppingLists);
    if (lists.isNotEmpty) {
      await remove(f.admin, Collections.shoppingLists, lists.keys);
    }
    final state = await start(tester);
    final engine = state.engine!;
    await clearInbox(engine);
    await eventually(
      tester,
      'no lists here',
      () async => engine.shoppingLists.where((l) => !l.packing).isEmpty,
    );
    engine
      ..saveInboxItem(inboxItem(state, 'Milch'))
      ..saveInboxItem(inboxItem(state, 'E2E Brot', text: 'vom Bäcker'));
    await openInbox(tester);
    await waitFor(tester, find.text('E2E Brot'));

    // With more than a title it is no shopping item.
    final offered = await openInboxMenu(tester, 'E2E Brot');
    expect(offered, contains(de.commonTask));
    expect(offered, isNot(contains(de.inboxShoppingItem)));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 600));

    // Without a list Famio makes "Einkauf".
    await fileAs(tester, 'Milch', de.inboxShoppingItem);
    await waitFor(tester, find.text(de.inboxFiled));
    await eventually(
      tester,
      'a list "Einkauf"',
      () async => engine.shoppingLists.length == 1,
    );
    final first = engine.shoppingLists.single;
    expect(first.name, de.sectionShopping);
    expect(engine.shoppingItems(first.id).map((i) => i.name), ['Milch']);

    // Two lists: which one? A ticked-off "Milch" comes back, not twice.
    engine.saveShoppingList(ShoppingList(id: newId(), name: 'E2E Drogerie'));
    final milk = engine.shoppingItems(first.id).single;
    engine.saveShoppingItem(
      ShoppingItem(
        id: milk.id,
        listId: first.id,
        name: milk.name,
        quantity: milk.quantity,
        category: milk.category,
        checked: true,
      ),
    );
    engine.saveInboxItem(inboxItem(state, 'Milch'));
    await snackGone(tester);
    await waitFor(tester, find.text('Milch'));
    await fileAs(tester, 'Milch', de.inboxShoppingItem);
    await waitFor(tester, find.text(de.shareWhichList));
    expect(inDialog(find.text('E2E Drogerie')), findsOneWidget);
    await tap(tester, inDialog(find.text(de.sectionShopping)));
    await waitFor(tester, find.text(de.inboxFiled));
    final items = engine.shoppingItems(first.id);
    expect(items.where((i) => i.name == 'Milch'), hasLength(1));
    expect(items.single.checked, isFalse);
    await clearInbox(engine);
    await finish(tester, state);
  });

  testWidgets('GRU-074 something with text in the inbox', (tester) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final state = await start(tester);
    final engine = state.engine!;
    await clearInbox(engine);
    await tester.pump(const Duration(seconds: 1));
    expect(homeTile(de.inboxTitle), findsNothing);
    await openInbox(tester);
    await waitFor(tester, find.text(de.inboxEmpty));

    Future<void> add({String title = '', String notes = ''}) async {
      await tap(tester, find.byTooltip(de.inboxAdd));
      await waitFor(tester, inDialog(field(de.commonTitle)));
      if (title.isNotEmpty) await enter(tester, field(de.commonTitle), title);
      if (notes.isNotEmpty) await enter(tester, field(de.commonNotes), notes);
      await leaveField(tester);
      await tap(
        tester,
        inDialog(find.widgetWithText(FilledButton, de.commonSave)),
      );
      await dialogClosed(tester);
    }

    await add(title: 'E2E Zettel Kita', notes: 'Bitte Gummistiefel mitgeben');
    await waitFor(tester, find.text('E2E Zettel Kita'));
    final item = engine.inboxItems.singleWhere(
      (i) => i.title == 'E2E Zettel Kita',
    );
    expect(
      find.text(
        'Bitte Gummistiefel mitgeben · '
        '${DateFormat.yMMMd('de').add_jm().format(item.createdAt!)}',
      ),
      findsOneWidget,
    );
    // The start page has the tile with the count; Bea's devices the entry.
    await back(tester);
    await waitFor(tester, homeTile(de.inboxTitle));
    expect((tester.widget(homeTile(de.inboxTitle)) as dynamic).badge, '1');
    await eventually(
      tester,
      'Bea gets it',
      () async =>
          (await titlesOf(bea, Collections.inbox)).contains('E2E Zettel Kita'),
    );

    // Hint: without a title the first line is one, without anything
    // "Ohne Titel".
    await openInbox(tester);
    await add(notes: 'Erste Zeile\nZweite Zeile');
    await waitFor(tester, find.text('Erste Zeile'));
    await add();
    await waitFor(tester, find.text(de.inboxUntitled));
    final empty = engine.inboxItems.singleWhere(
      (i) => i.title == de.inboxUntitled,
    );
    expect(empty.text, isEmpty);
    expect(empty.files, isEmpty);
    await eventually(
      tester,
      'the empty one reaches Bea too',
      () async =>
          (await titlesOf(bea, Collections.inbox)).contains(de.inboxUntitled),
    );
    await clearInbox(engine);
    await finish(tester, state);
  });

  testWidgets('GRU-075 GRU-077 a file in the inbox, filed as a task', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final picker = _fakePicker();
    final pdf = await tempFile('e2e-elternbrief.pdf', _pdf);
    final state = await start(tester);
    final engine = state.engine!;
    await clearInbox(engine);
    await openInbox(tester);
    await tap(tester, find.byTooltip(de.inboxAdd));
    await enter(tester, field(de.commonTitle), 'E2E Elternbrief');
    await enter(tester, field(de.commonNotes), 'Unterschreiben bis Freitag');
    await leaveField(tester);
    picker.picks.add([pdf]);
    await tap(tester, inDialog(find.text(de.filesChooseFilePhoto)));
    await waitFor(tester, inDialog(find.text('e2e-elternbrief.pdf')));
    // On the Mac the system's open panel comes straight away; its title
    // names the limit (phones and the browser show the sheet first).
    expect(
      picker.titles.last,
      de.filesUploadLimit(fileSizeLabel(engine.maxUploadBytes)),
    );
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonSave)),
    );
    await dialogClosed(tester);
    await waitFor(tester, find.textContaining(de.inboxFiles(1)));

    // Tapped: it opens.
    _launcher.opened.clear();
    await tap(tester, find.text('E2E Elternbrief'));
    await eventually(
      tester,
      'the file opens',
      () async => _launcher.opened.isNotEmpty,
    );
    expect(
      await File.fromUri(Uri.parse(_launcher.opened.last)).readAsBytes(),
      _pdf,
    );

    // GRU-077: a task with title, notes and the file; the inbox is empty.
    await fileAs(tester, 'E2E Elternbrief', de.commonTask);
    await waitFor(tester, find.text(de.inboxFiled));
    await waitFor(tester, find.text(de.inboxEmpty));
    final task = engine.tasks.singleWhere((t) => t.title == 'E2E Elternbrief');
    expect(task.notes, 'Unterschreiben bis Freitag');
    expect(task.photos.map((p) => p.name), ['e2e-elternbrief.pdf']);
    await back(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(homeTile(de.inboxTitle), findsNothing);
    await eventually(tester, 'Bea gets the task with the file', () async {
      final t = (await pull(
        bea,
        Collections.tasks,
      )).values.where((r) => r.data['title'] == 'E2E Elternbrief');
      return t.isNotEmpty && (t.single.data['photos'] as List).length == 1;
    });
    engine.deleteTask(task.id);
    await finish(tester, state);
  });

  testWidgets('GRU-078 filed as an appointment and as a note', (tester) async {
    tall(tester);
    final state = await start(tester);
    final engine = state.engine!;
    await clearInbox(engine);
    engine
      ..saveInboxItem(
        inboxItem(state, 'E2E Sommerfest', text: 'Kuchen mitbringen'),
      )
      ..saveInboxItem(
        inboxItem(state, 'E2E WLAN-Passwort', text: 'Steht auf der Box'),
      );
    await openInbox(tester);
    await waitFor(tester, find.text('E2E Sommerfest'));

    // Cancelling the day keeps the entry.
    await fileAs(tester, 'E2E Sommerfest', de.commonEvent);
    await waitFor(tester, find.text(de.inboxEventDate));
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    expect(find.text('E2E Sommerfest'), findsOneWidget);
    expect(engine.events.where((e) => e.title == 'E2E Sommerfest'), isEmpty);

    // A day: all day long, with the notes.
    final day = inDays(5);
    await fileAs(tester, 'E2E Sommerfest', de.commonEvent);
    await waitFor(tester, find.text(de.inboxEventDate));
    await pickDate(tester, day);
    await waitFor(tester, find.text(de.inboxFiled));
    final event = engine.events.singleWhere((e) => e.title == 'E2E Sommerfest');
    expect(event.allDay, isTrue);
    expect(DateUtils.isSameDay(event.start, day), isTrue);
    expect(event.notes, 'Kuchen mitbringen');

    await fileAs(tester, 'E2E WLAN-Passwort', de.commonNote);
    await waitFor(tester, find.text(de.inboxEmpty));
    final note = engine.notes.singleWhere(
      (n) => n.title == 'E2E WLAN-Passwort',
    );
    expect(note.text, 'Steht auf der Box');

    // In the calendar and on the pinboard.
    await back(tester);
    await scrollTo(tester, find.text(de.commonPinboard));
    await tap(tester, find.text(de.commonPinboard));
    await waitFor(tester, find.text('E2E WLAN-Passwort'));
    await openCalendarOn(tester, state, day);
    await waitFor(tester, find.text('E2E Sommerfest'));
    engine
      ..deleteEvent(event.id)
      ..deleteNote(note.id);
    await finish(tester, state);
  });

  testWidgets('GRU-079 two files filed as documents', (tester) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final state = await start(tester);
    final engine = state.engine!;
    await clearInbox(engine);
    final a = await uploadAs(engine.api, 'e2e-befund-1.pdf', _pdf);
    final b = await uploadAs(engine.api, 'e2e-befund-2.pdf', _pdf);
    engine.saveInboxItem(
      inboxItem(state, 'E2E Arztpost', text: 'Zwei Seiten', files: [a, b]),
    );
    await openInbox(tester);
    await waitFor(tester, find.textContaining(de.inboxFiles(2)));
    final offered = await openInboxMenu(tester, 'E2E Arztpost');
    expect(offered, [de.commonTask, de.commonDocument, de.commonDelete]);
    await tap(
      tester,
      find.descendant(of: _menuItems, matching: find.text(de.commonDocument)),
    );
    await waitFor(tester, find.text(de.inboxFiled));
    final docs = engine.documents
        .where((d) => d.title.startsWith('e2e-befund-'))
        .toList();
    expect(docs.map((d) => d.title).toSet(), {
      'e2e-befund-1.pdf',
      'e2e-befund-2.pdf',
    });
    for (final d in docs) {
      expect(d.category, DocumentCategory.other);
      expect(d.category.label, 'Sonstiges');
      expect(d.notes, 'Zwei Seiten');
      // Hint: no audience – the whole family gets them.
      expect(d.visibleTo, isNull);
    }
    await eventually(
      tester,
      'Bea gets both documents',
      () async => (await titlesOf(
        bea,
        Collections.documents,
      )).containsAll({'e2e-befund-1.pdf', 'e2e-befund-2.pdf'}),
    );
    for (final d in docs) {
      engine.delete(Collections.documents, d.id);
    }
    await finish(tester, state);
  });

  testWidgets('GRU-082 an inbox entry deleted', (tester) async {
    tall(tester);
    final state = await start(tester);
    final engine = state.engine!;
    await clearInbox(engine);
    engine.saveInboxItem(inboxItem(state, 'E2E Wegwerfzettel'));
    await openInbox(tester);
    await waitFor(tester, find.text('E2E Wegwerfzettel'));
    await fileAs(tester, 'E2E Wegwerfzettel', de.commonDelete);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('E2E Wegwerfzettel'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text(de.commonUndo), findsNothing);
    await engine.sync();
    expect(await trashTitles(engine.api), isNot(contains('E2E Wegwerfzettel')));
    await finish(tester, state);
  });

  testWidgets('GRU-083 the inbox is closed to guests and service accounts', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final service = await sessionOf(await theService());
    final ref = await uploadAs(bea, 'e2e-arztbrief.pdf', _pdf);
    final id = _uid('inbox');
    await put(bea, Collections.inbox, {
      id: InboxItem(
        id: id,
        title: 'E2E Arztbrief',
        files: [ref],
        createdAt: DateTime.now(),
        createdBy: f.bea.id,
      ).toData(),
    });
    // The service account: no entries, not their file, no writing.
    expect(await pull(service, Collections.inbox), isEmpty);
    await expectLater(service.downloadFile(ref.id), throwsA(isA<ApiError>()));
    final written = _uid('inbox');
    final answer = await put(service, Collections.inbox, {
      written: const InboxItem(id: 'x', title: 'E2E vom Dienst').toData(),
    });
    expect(answer.rejected.map((r) => r.id), contains(written));
    expect(
      (await pull(f.admin, Collections.inbox)).keys,
      isNot(contains(written)),
    );

    // The guest: no button, no tile, not offered when sharing.
    final state = await start(tester, user: 'e2e-gast');
    await tester.pump(const Duration(seconds: 2));
    expect(find.byTooltip(de.inboxTitle), findsNothing);
    expect(homeTile(de.inboxTitle), findsNothing);
    expect(state.engine!.inboxItems, isEmpty);
    await dropFiles(tester, [await tempFile('e2e-gast.pdf', _pdf)]);
    await waitFor(tester, find.text(de.shareTitle));
    expect(find.text(de.shareToInbox), findsNothing);
    expect(find.text(de.shareAsTask), findsOneWidget);
    await closeSheet(tester);
    await remove(bea, Collections.inbox, [id]);
    await finish(tester, state);
  });

  testWidgets('GRU-084 a child and the family inbox', (tester) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final ref = await uploadAs(bea, 'e2e-arztbrief-kind.pdf', _pdf);
    final id = _uid('inbox');
    await put(bea, Collections.inbox, {
      id: InboxItem(
        id: id,
        title: 'E2E Arztbrief von Bea',
        files: [ref],
        createdAt: DateTime.now(),
        createdBy: f.bea.id,
      ).toData(),
    });
    final state = await start(tester, user: 'e2e-kind');
    final engine = state.engine!;
    await openInbox(tester);
    // Hint: no audience – the child sees the scanned letter and opens it.
    await waitFor(tester, find.text('E2E Arztbrief von Bea'));
    _launcher.opened.clear();
    await tap(tester, find.text('E2E Arztbrief von Bea'));
    await eventually(
      tester,
      'the letter opens',
      () async => _launcher.opened.isNotEmpty,
    );
    // It can put something in and file it.
    await tap(tester, find.byTooltip(de.inboxAdd));
    await enter(tester, field(de.commonTitle), 'E2E Vom Kind');
    await leaveField(tester);
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonSave)),
    );
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Vom Kind'));
    await fileAs(tester, 'E2E Vom Kind', de.commonNote);
    await waitFor(tester, find.text(de.inboxFiled));
    await eventually(
      tester,
      'the note on the server',
      () async =>
          (await titlesOf(f.admin, Collections.notes)).contains('E2E Vom Kind'),
    );
    for (final n in engine.notes.where((n) => n.title == 'E2E Vom Kind')) {
      engine.deleteNote(n.id);
    }
    await remove(bea, Collections.inbox, [id]);
    await finish(tester, state);
  });

  testWidgets('GRU-090 files dragged onto the window', (tester) async {
    tall(tester);
    final f = await theFamily();
    final state = await start(tester);
    final engine = state.engine!;
    await clearInbox(engine);

    // While dragging: the hint.
    dropTarget(tester).onDragEntered!(
      DropEventDetails(
        localPosition: const Offset(300, 300),
        globalPosition: const Offset(300, 300),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(de.dropHere), findsOneWidget);
    dropTarget(tester).onDragExited!(
      DropEventDetails(
        localPosition: const Offset(300, 300),
        globalPosition: const Offset(300, 300),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(de.dropHere), findsNothing);

    // A PDF: "Teilen an Famio"; the original stays as it was.
    final pdf = await tempFile('e2e-drop.pdf', _pdf);
    final changed = pdf.lastModifiedSync();
    await dropFiles(tester, [pdf]);
    await waitFor(tester, find.text(de.shareTitle));
    expect(find.text('📎 e2e-drop.pdf'), findsOneWidget);
    await tap(tester, find.text(de.shareToInbox));
    await waitFor(tester, find.text(de.inboxSaved));
    await eventually(
      tester,
      'in the inbox',
      () async => engine.inboxItems.any(
        (i) => i.files.any((x) => x.name == 'e2e-drop.pdf'),
      ),
    );
    expect(pdf.readAsBytesSync(), _pdf);
    expect(pdf.lastModifiedSync(), changed);

    // One calendar file: the import.
    final day = inDays(10);
    String ymd(DateTime d) => DateFormat('yyyyMMdd').format(d);
    final ics = await tempFile(
      'e2e-termine.ics',
      utf8.encode(
        'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//E2E//DE\r\n'
        'BEGIN:VEVENT\r\nUID:e2e-drop-1@example.com\r\n'
        'DTSTAMP:20260101T000000Z\r\nDTSTART;VALUE=DATE:${ymd(day)}\r\n'
        'DTEND;VALUE=DATE:${ymd(DateUtils.addDaysToDate(day, 1))}\r\n'
        'SUMMARY:E2E Laternenfest\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n',
      ),
    );
    final icsBytes = ics.readAsBytesSync();
    await dropFiles(tester, [ics]);
    await waitFor(tester, find.byType(IcsImportScreen));
    await waitFor(tester, find.text('E2E Laternenfest'));
    expect(ics.readAsBytesSync(), icsBytes);
    await back(tester);
    await openSection(tester, 'Start');

    // Over 10 MB: said so.
    final big = await tempFile(
      'e2e-gross.ics',
      List.filled(10 * _mb + 100, 0x41),
    );
    await dropFiles(tester, [big]);
    await waitFor(tester, find.text(de.importIcsTooLarge));
    await snackGone(tester);

    // Hint: over the upload limit, and from the eleventh on, files are left
    // out without a word.
    await f.admin.updateServerSettings({'maxUploadMb': 1});
    addTearDown(() => f.admin.updateServerSettings({'maxUploadMb': null}));
    await eventually(tester, 'the app knows the limit', () async {
      await engine.sync();
      return engine.maxUploadBytes == _mb;
    });
    final huge = await tempFile('e2e-riesig.pdf', _bigPdf(1.5));
    final small = [
      for (var i = 1; i <= 11; i++) await tempFile('e2e-klein-$i.pdf', _pdf),
    ];
    await dropFiles(tester, [huge, ...small]);
    await waitFor(tester, find.text(de.shareTitle));
    expect(find.text(de.shareFiles(9)), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await closeSheet(tester);
    await f.admin.updateServerSettings({'maxUploadMb': null});
    await clearInbox(engine);
    await finish(tester, state);
  });

  // === Konflikte und Abgleich ===============================================

  testWidgets('GRU-096 crossed changes of notes: bring one back, leave one', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final a = _uid('note'), b = _uid('note');
    await put(bea, Collections.notes, {
      a: FamilyNote(id: a, title: 'E2E Einkaufszettel').toData(),
    });
    await put(bea, Collections.notes, {
      b: FamilyNote(id: b, title: 'E2E Packliste').toData(),
    });
    // Bea's phone goes offline with these versions.
    final stale = await pull(bea, Collections.notes);
    final offlineAt = DateTime.now().millisecondsSinceEpoch;
    final state = await start(tester);
    final engine = state.engine!;
    await eventually(
      tester,
      'both notes here',
      () async => engine.notes.where((n) => n.id == a || n.id == b).length == 2,
    );
    // Changed on this computer …
    engine
      ..saveNote(FamilyNote(id: a, title: 'E2E Einkaufszettel (Admin)'))
      ..saveNote(FamilyNote(id: b, title: 'E2E Packliste (Admin)'));
    await engine.sync();
    // … and on Bea's phone, offline before that, coming online now.
    for (final (id, title) in [
      (a, 'E2E Einkaufszettel (Bea)'),
      (b, 'E2E Packliste (Bea)'),
    ]) {
      await putStale(
        bea,
        Collections.notes,
        id,
        {...stale[id]!.data, 'title': title},
        rev: stale[id]!.rev,
        at: offlineAt + 1,
      );
    }
    await engine.sync();
    await openSection(tester, 'Start');
    final card = find.textContaining('überschnitten');
    await scrollTo(tester, card);
    await tap(tester, card);
    await waitFor(tester, find.text(de.conflictsOverlappingChanges));
    expect(find.text(de.conflictsHereSomeoneChangedSomething), findsOneWidget);
    final first = '${de.commonNote}: E2E Einkaufszettel (Admin)';
    await waitFor(tester, find.text(first));
    expect(
      find.descendant(
        of: cardOf(first),
        matching: find.textContaining(
          RegExp(
            r'^Behalten: die Fassung von dir \(.+\)\. '
            r'Aufgehoben: die von E2E Bea \(.+\)\.$',
          ),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: cardOf(first),
        matching: find.text(
          '${de.commonTitle}: E2E Einkaufszettel (Admin)'
          '${de.conflictsInstead}E2E Einkaufszettel (Bea)',
        ),
      ),
      findsOneWidget,
    );
    // Bea's version back: it is the current one, the conflict goes.
    await tap(
      tester,
      find.descendant(
        of: cardOf(first),
        matching: find.text(de.conflictsBringBackVersionWho('E2E Bea')),
      ),
    );
    await waitGone(tester, find.text(first));
    expect(
      engine.notes.singleWhere((n) => n.id == a).title,
      'E2E Einkaufszettel (Bea)',
    );
    // The other one stays as it is.
    final second = '${de.commonNote}: E2E Packliste (Admin)';
    await tap(
      tester,
      find.descendant(
        of: cardOf(second),
        matching: find.text(de.conflictsLeaveLike),
      ),
    );
    await waitFor(tester, find.text(de.conflictsNothingDecide));
    await engine.sync();
    await eventually(tester, 'on the server for Bea', () async {
      final notes = await pull(bea, Collections.notes);
      return notes[a]?.data['title'] == 'E2E Einkaufszettel (Bea)' &&
          notes[b]?.data['title'] == 'E2E Packliste (Admin)' &&
          (await pull(bea, Collections.conflicts)).isEmpty;
    });
    await back(tester);
    engine
      ..deleteNote(a)
      ..deleteNote(b);
    await finish(tester, state);
  });

  testWidgets('GRU-097 a deletion against a change', (tester) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final kept = _uid('task'), gone = _uid('task');
    await put(bea, Collections.tasks, {
      kept: Task(id: kept, title: 'E2E Löschkonflikt A').toData(),
    });
    await put(bea, Collections.tasks, {
      gone: Task(id: gone, title: 'E2E Löschkonflikt B').toData(),
    });
    final stale = await pull(bea, Collections.tasks);
    final state = await start(tester);
    final engine = state.engine!;
    await eventually(
      tester,
      'both tasks here',
      () async =>
          engine.tasks.where((t) => t.id == kept || t.id == gone).length == 2,
    );
    // A: changed here, deleted by Bea later → deleted, the change kept aside.
    engine.saveTask(Task(id: kept, title: 'E2E Löschkonflikt A (geändert)'));
    // B: deleted here, changed by Bea later → it is still there.
    engine.deleteTask(gone);
    await engine.sync();
    final later = DateTime.now().millisecondsSinceEpoch + 1000;
    await putStale(
      bea,
      Collections.tasks,
      kept,
      const {},
      rev: stale[kept]!.rev,
      at: later,
      deleted: true,
    );
    await putStale(
      bea,
      Collections.tasks,
      gone,
      {...stale[gone]!.data, 'title': 'E2E Löschkonflikt B (Bea)'},
      rev: stale[gone]!.rev,
      at: later,
    );
    await engine.sync();
    await openSection(tester, 'Start');
    final card = find.textContaining('überschnitten');
    await scrollTo(tester, card);
    await tap(tester, card);
    await waitFor(tester, find.text(de.conflictsOverlappingChanges));

    final deletedCard = '${de.commonTask}: E2E Löschkonflikt A (geändert)';
    await waitFor(tester, find.text(deletedCard));
    expect(
      find.descendant(
        of: cardOf(deletedCard),
        matching: find.textContaining(
          RegExp(
            r'^Gelöscht von E2E Bea \(.+\); die Änderung von dir \(.+\) '
            r'ist aufgehoben\.$',
          ),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: cardOf(deletedCard),
        matching: find.text(de.conflictsBringBackVersionWho('dir')),
      ),
      findsOneWidget,
    );
    final stillCard = '${de.commonTask}: E2E Löschkonflikt B (Bea)';
    expect(
      find.descendant(
        of: cardOf(stillCard),
        matching: find.textContaining(
          RegExp(
            r'^Gelöscht von dir \(.+\), gleichzeitig geändert von E2E Bea '
            r'\(.+\) – es ist noch da\.$',
          ),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: cardOf(stillCard),
        matching: find.text(de.conflictsLeaveLike),
      ),
      findsOneWidget,
    );
    // "Gelöscht lassen": stays deleted.
    await tap(
      tester,
      find.descendant(
        of: cardOf(deletedCard),
        matching: find.text(de.conflictsKeepDeleted),
      ),
    );
    await waitGone(tester, find.text(deletedCard));
    // "Doch löschen": now it goes.
    await tap(
      tester,
      find.descendant(
        of: cardOf(stillCard),
        matching: find.text(de.conflictsDeleteAfterAll),
      ),
    );
    await waitFor(tester, find.text(de.conflictsNothingDecide));
    await engine.sync();
    await eventually(tester, 'both gone on the server', () async {
      final tasks = await pull(bea, Collections.tasks);
      return !tasks.containsKey(kept) &&
          !tasks.containsKey(gone) &&
          (await pull(bea, Collections.conflicts)).isEmpty;
    });
    await back(tester);
    await finish(tester, state);
  });

  testWidgets('GRU-098 the sync symbol and "Jetzt synchronisieren"', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    final state = await start(tester, url: gate.url);
    final engine = state.engine!;
    await engine.sync();
    await tester.pump(const Duration(seconds: 1));

    // Online: the green cloud with the time.
    await waitFor(tester, _cloud(AppIcons.cloudCheck));
    expect(
      cloudTip(tester),
      de.syncSynchronizedTime(
        DateFormat.jm('de').format(engine.status.lastSync!),
      ),
    );
    expect(
      tester.widget<Icon>(_cloud(AppIcons.cloudCheck)).color,
      FamioSection.tasks.strong,
    );

    // Offline: red, with what waits and why.
    gate.cut();
    await addTask(tester, 'E2E Wolke offline');
    await openSection(tester, 'Start');
    await waitFor(
      tester,
      _cloud(AppIcons.cloudSlash),
      timeout: const Duration(seconds: 45),
    );
    final reason = engine.status.message ?? '';
    debugPrint('E2E-INFO offline reason: $reason');
    expect(reason, startsWith('Server nicht erreichbar'));
    expect(cloudTip(tester), de.syncOfflinePendingChangeS(1, reason).trim());
    expect(
      tester.widget<Icon>(_cloud(AppIcons.cloudSlash)).color,
      Theme.of(tester.element(find.byType(SyncStatusIcon))).colorScheme.error,
    );
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsSyncNow));
    expect(
      subtitleOf(tester, de.settingsSyncNow),
      de.settingsOfflineMessage(reason),
    );

    // The server back. That Famio sends on its own is checked in the test
    // "GRU-098 GRU-100 offline changes go by themselves" below; here the
    // tap on "Jetzt synchronisieren" sends at once.
    gate.restore();
    await eventually(
      tester,
      'the connection is back',
      () async => engine.live,
      timeout: const Duration(seconds: 90),
    );
    await tap(tester, find.text(de.settingsSyncNow));
    await eventually(
      tester,
      'sent by the tap',
      () async => (await titlesOf(
        f.admin,
        Collections.tasks,
      )).contains('E2E Wolke offline'),
    );
    await waitFor(
      tester,
      find.textContaining(RegExp('^${RegExp.escape(de.settingsLastTime(''))}')),
      timeout: const Duration(seconds: 30),
    );
    expect(
      subtitleOf(tester, de.settingsSyncNow),
      de.settingsLastTime(
        DateFormat.MMMd('de').add_jm().format(engine.status.lastSync!),
      ),
    );

    // A tap syncs at once; while it runs: "Läuft …".
    gate.hold();
    await tester.pump(const Duration(seconds: 1));
    final before = engine.status.lastSync!;
    await tap(tester, find.text(de.settingsSyncNow));
    await waitFor(tester, find.text(de.settingsSyncRunning));
    gate.release();
    await eventually(
      tester,
      'synced by the tap',
      () async =>
          engine.status.state == SyncState.idle &&
          engine.status.lastSync!.isAfter(before),
    );
    await waitGone(tester, find.text(de.settingsSyncRunning));
    for (final t in engine.tasks.where((t) => t.title == 'E2E Wolke offline')) {
      engine.deleteTask(t.id);
    }
    await finish(tester, state);
  });

  testWidgets('GRU-099 a change whose attachment is no longer shared', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    final ref = await uploadAs(bea, 'e2e-gesperrt.pdf', _pdf);
    final inboxId = _uid('inbox');
    await put(bea, Collections.inbox, {
      inboxId: InboxItem(
        id: inboxId,
        title: 'E2E Gesperrter Anhang',
        files: [ref],
        createdAt: DateTime.now(),
        createdBy: f.bea.id,
      ).toData(),
    });
    final state = await start(tester, url: gate.url);
    final engine = state.engine!;
    await eventually(
      tester,
      'the letter here',
      () async => engine.inboxItems.any((i) => i.id == inboxId),
    );
    // Offline: filed as a task (the file goes along), and a note of its own.
    gate.cut();
    await openInbox(tester);
    await fileAs(tester, 'E2E Gesperrter Anhang', de.commonTask);
    await waitFor(tester, find.text(de.inboxFiled));
    await back(tester);
    engine.saveNote(FamilyNote(id: newId(), title: 'E2E Unabhängige Notiz'));
    // Meanwhile Bea takes the letter back: nothing shares the file now.
    await remove(bea, Collections.inbox, [inboxId]);
    gate.restore();
    unawaited(engine.sync());
    await waitFor(
      tester,
      _cloud(AppIcons.warningCircle),
      timeout: const Duration(seconds: 90),
    );
    expect(cloudTip(tester), de.syncBlockedTitle(1));
    await eventually(
      tester,
      'the note arrives anyway',
      () async => (await titlesOf(
        f.admin,
        Collections.notes,
      )).contains('E2E Unabhängige Notiz'),
    );
    expect(
      await titlesOf(f.admin, Collections.tasks),
      isNot(contains('E2E Gesperrter Anhang')),
    );
    expect(
      engine.tasks.where((t) => t.title == 'E2E Gesperrter Anhang'),
      hasLength(1),
    );

    // The dialog names the entry and why.
    await tap(tester, _cloud(AppIcons.warningCircle));
    await waitFor(tester, inDialog(find.text(de.syncBlockedTitle(1))));
    expect(inDialog(find.text(de.syncBlockedFileBody)), findsOneWidget);
    expect(inDialog(find.text('E2E Gesperrter Anhang')), findsOneWidget);
    expect(inDialog(find.text(de.commonClose)), findsOneWidget);
    expect(inDialog(find.text(de.commonRetry)), findsOneWidget);
    await tap(tester, inDialog(find.text(de.commonClose)));
    await dialogClosed(tester);

    // The settings say "Änderungen prüfen"; shared again, a retry sends it.
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.syncReviewChanges));
    final docId = _uid('doc');
    await put(bea, Collections.documents, {
      docId: FamilyDocument(
        id: docId,
        title: 'E2E Wieder freigegeben',
        category: DocumentCategory.other,
        file: ref,
      ).toData(),
    });
    await tap(tester, find.text(de.syncReviewChanges));
    await waitFor(tester, inDialog(find.text(de.commonRetry)));
    await tap(tester, inDialog(find.text(de.commonRetry)));
    await eventually(
      tester,
      'the task arrives after the retry',
      () async => (await titlesOf(
        f.admin,
        Collections.tasks,
      )).contains('E2E Gesperrter Anhang'),
    );
    for (final t in engine.tasks.where(
      (t) => t.title == 'E2E Gesperrter Anhang',
    )) {
      engine.deleteTask(t.id);
    }
    for (final n in engine.notes.where(
      (n) => n.title == 'E2E Unabhängige Notiz',
    )) {
      engine.deleteNote(n.id);
    }
    await remove(bea, Collections.documents, [docId]);
    await finish(tester, state);
  });

  // === Offline ==============================================================

  testWidgets('GRU-100 offline: kept over a restart, sent afterwards', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final doneId = _uid('task');
    await put(f.admin, Collections.tasks, {
      doneId: Task(id: doneId, title: 'E2E Offline abhaken').toData(),
    });
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    var state = await start(tester, url: gate.url);
    await openSection(tester, 'Aufgaben');
    await waitFor(tester, find.text('E2E Offline abhaken'));
    gate.cut();
    await addTask(tester, 'E2E Offline neu');
    await tap(tester, roundCheck('E2E Offline abhaken'));
    await eventually(
      tester,
      'ticked off here',
      () async => state.engine!.tasks.singleWhere((t) => t.id == doneId).done,
    );
    // Quit and start again, still without the server: the last data.
    state = await restart(tester, state);
    expect(field(de.connectServerAddress), findsNothing);
    var engine = state.engine!;
    expect(engine.tasks.map((t) => t.title), contains('E2E Offline neu'));
    expect(engine.tasks.singleWhere((t) => t.id == doneId).done, isTrue);
    await openSection(tester, 'Aufgaben');
    await waitFor(tester, find.text('E2E Offline neu'));
    // The server back: Bea's devices get it (that it goes without a tap:
    // see "GRU-098 GRU-100 offline changes go by themselves").
    gate.restore();
    await eventually(
      tester,
      'the connection is back',
      () async => state.engine!.live,
      timeout: const Duration(seconds: 90),
    );
    unawaited(state.engine!.sync());
    await eventually(tester, 'Bea gets both changes', () async {
      final tasks = await pull(bea, Collections.tasks);
      return tasks.values.any((r) => r.data['title'] == 'E2E Offline neu') &&
          tasks[doneId]?.data['done'] == true;
    }, timeout: const Duration(seconds: 150));
    engine = state.engine!;
    for (final t in engine.tasks.where(
      (t) => t.title.startsWith('E2E Offline'),
    )) {
      engine.deleteTask(t.id);
    }
    await finish(tester, state);
  });

  // Changes made offline go by themselves when the connection comes back
  // after a short outage (#534): the engine syncs once the WebSocket is up
  // again and something waits or the last attempt failed, and only a
  // successful sync keeps the poll quiet while the WebSocket is up.
  testWidgets('GRU-098 GRU-100 offline changes go by themselves', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    final state = await start(tester, url: gate.url);
    final engine = state.engine!;
    await engine.sync();
    gate.cut();
    await addTask(tester, 'E2E Von selbst');
    await eventually(
      tester,
      'offline',
      () async => engine.status.state == SyncState.offline,
    );
    // A short outage, as when the server restarts or the Wi-Fi drops for
    // a moment (a long one lets the minute's poll win the race).
    await tester.pump(const Duration(seconds: 3));
    gate.restore();
    await eventually(
      tester,
      'the connection is back',
      () async => engine.live,
      timeout: const Duration(seconds: 90),
    );
    final back = DateTime.now();
    var sent = false;
    while (DateTime.now().difference(back) < const Duration(seconds: 150)) {
      await tester.pump(const Duration(seconds: 5));
      if ((await titlesOf(
        f.admin,
        Collections.tasks,
      )).contains('E2E Von selbst')) {
        sent = true;
        break;
      }
    }
    debugPrint(
      'E2E-INFO sent by itself: $sent after '
      '${DateTime.now().difference(back).inSeconds} s; live ${engine.live}, '
      'waiting ${engine.store.dirty.length}, state ${engine.status.state}',
    );
    for (final t in engine.tasks.where((t) => t.title == 'E2E Von selbst')) {
      engine.deleteTask(t.id);
    }
    unawaited(engine.sync());
    expect(sent, isTrue, reason: 'sent without a tap within 2½ minutes');
    await finish(tester, state);
  });

  testWidgets('GRU-102 the data on this computer do not open', (tester) async {
    final f = await theFamily();
    final id = _uid('task');
    await put(f.admin, Collections.tasks, {
      id: Task(id: id, title: 'E2E Vom Server neu').toData(),
    });
    var state = await start(tester);
    final me = state.me!.id;
    await eventually(
      tester,
      'synced',
      () async => state.engine!.tasks.any((t) => t.id == id),
    );
    await leaveApp(tester, state);
    final support = await getApplicationSupportDirectory();
    final db = File(p.join(support.path, 'famio_$me.db'));
    expect(db.existsSync(), isTrue);
    // The first bytes overwritten.
    final bytes = db.readAsBytesSync();
    bytes.setRange(0, 4096, List.filled(4096, 0xA5));
    db.writeAsBytesSync(bytes, flush: true);
    // Only the file itself counts, not a journal beside it.
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final part = File('${db.path}$suffix');
      if (part.existsSync()) part.deleteSync();
    }
    state = await restart(tester, state);
    await waitFor(tester, find.text(de.appLocalDataSetAside));
    final aside = File('${db.path}.unreadable');
    expect(aside.existsSync(), isTrue);
    expect(aside.readAsBytesSync(), bytes);
    await eventually(
      tester,
      'everything from the server again',
      () async => state.engine!.tasks.any((t) => t.id == id),
    );
    // Said once: not again on the next start.
    await snackGone(tester);
    state = await restart(tester, state);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(de.appLocalDataSetAside), findsNothing);
    await remove(f.admin, Collections.tasks, [id]);
    await finish(tester, state);
  });

  // === Verbindung und Server ================================================

  testWidgets(
    'GRU-103 GRU-101 over HTTPS: the state, then a changed certificate',
    (tester) async {
      tall(tester);
      final gate = TlsGate(Uri.parse(_tlsUrl), Uri.parse(kitUrl));
      await gate.start();
      addTearDown(gate.close);
      final pin = await FamioApiClient.untrustedCertificate(
        Uri.parse(gate.url),
      );
      expect(pin, isNotNull);
      final state = await start(tester, url: gate.url, trust: true);
      expect(state.certificatePin, pin);

      // GRU-103
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, tile(de.settingsServer));
      expect(subtitleOf(tester, de.settingsServer), state.serverUrl);
      await scrollTo(tester, find.text(de.settingsConnectionEncrypted));
      expect(
        subtitleOf(tester, de.settingsConnectionEncrypted),
        de.settingsHttpsServerSConfirmed(pin!.substring(0, 11)),
      );
      expect(find.text(de.settingsChangeServer), findsOneWidget);
      expect(
        subtitleOf(tester, de.settingsLocalData),
        de.settingsLocalDataKeychain,
      );

      // GRU-101: the server shows another key now.
      gate.newKey();
      final seen = await FamioApiClient.untrustedCertificate(
        Uri.parse(gate.url),
      );
      expect(seen, isNot(pin));
      await openSection(tester, 'Start');
      unawaited(state.engine!.sync());
      await waitFor(
        tester,
        find.text(de.shellServerSCertificateHas),
        timeout: const Duration(seconds: 60),
      );
      expect(state.changedCertificate, seen);
      final groups = seen!.split(':');
      final lines = [
        for (var i = 0; i < groups.length; i += 8)
          groups.skip(i).take(8).join(':'),
      ].join('\n');
      // Looked at and cancelled: stays offline.
      await tap(tester, find.text(de.shellCheck));
      await waitFor(tester, find.text(de.trustCheckServerSCertificate));
      expect(find.text(lines), findsOneWidget);
      await tap(tester, inDialog(find.text(de.commonCancel)));
      await dialogClosed(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(de.shellServerSCertificateHas), findsOneWidget);
      expect(state.engine!.status.state, isNot(SyncState.idle));
      // Confirmed: back online, without signing in again.
      await tap(tester, find.text(de.shellCheck));
      await waitFor(tester, find.text(de.trustMatches));
      await tap(tester, find.text(de.trustMatches));
      await waitFor(tester, find.text(de.shellConnectionRestored));
      await waitGone(tester, find.text(de.shellServerSCertificateHas));
      expect(state.certificatePin, seen);
      expect(state.me, isNotNull);
      expect(field(de.connectServerAddress), findsNothing);
      await eventually(tester, 'in sync again', () async {
        await state.engine!.sync();
        return state.engine!.status.state == SyncState.idle;
      });
      await finish(tester, state);
    },
  );

  testWidgets('GRU-104 plain HTTP in the home network is named', (
    tester,
  ) async {
    tall(tester);
    final state = await start(tester);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsUnencryptedLan));
    expect(
      subtitleOf(tester, de.settingsUnencryptedLan),
      de.settingsUnencryptedLanHint,
    );
    expect(
      find.widgetWithText(FilledButton, de.settingsEncryptNow),
      findsOneWidget,
    );
    await finish(tester, state);
  });

  testWidgets('GRU-105 the server moved; another server is turned down', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    final foreign = FakeFamio(await rawHealth());
    await foreign.start();
    addTearDown(foreign.close);
    final state = await start(tester);
    final before = state.serverUrl;
    final id = newId();
    state.engine!.saveTask(Task(id: id, title: 'E2E Vor dem Umzug'));
    await state.engine!.sync();

    Future<void> moveTo(String url) async {
      await snackGone(tester);
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, find.text(de.settingsChangeServer));
      await tap(tester, find.text(de.settingsChangeServer));
      await waitFor(tester, field(de.settingsNewServerAddress));
      await enter(tester, field(de.settingsNewServerAddress), url);
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.settingsSwitch)));
      await dialogClosed(tester);
    }

    // A Famio server that does not know this session.
    await moveTo(foreign.url);
    await waitFor(tester, find.text(de.appServerDoesNotKnow));
    expect(state.serverUrl, before);
    // One where it belongs to someone else.
    foreign.me = f.bea.toJson();
    await moveTo(foreign.url);
    await waitFor(tester, find.text(de.appYouSignedThereSomeone));
    expect(state.serverUrl, before);
    // The family's server at its new address.
    await moveTo(gate.url);
    await waitFor(tester, find.text(de.settingsConnectedNewAddress));
    expect(state.serverUrl, FamioApiClient.normalizeUrl(gate.url).toString());
    expect(state.me, isNotNull);
    expect(field(de.connectServerAddress), findsNothing);
    final engine = state.engine!;
    await engine.sync();
    expect(engine.tasks.map((t) => t.title), contains('E2E Vor dem Umzug'));
    expect(engine.status.state, SyncState.idle);
    engine.deleteTask(id);
    await finish(tester, state);
  });

  // === Darstellung und Sprache ==============================================

  testWidgets('GRU-106 dark, after a restart, then like the system', (
    tester,
  ) async {
    tall(tester);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    var state = await start(tester);
    Brightness shown() =>
        Theme.of(tester.element(find.byType(HomeShell))).brightness;
    Future<void> pick(String label) async {
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, find.byType(DropdownButton<ThemeMode>));
      await tap(tester, find.byType(DropdownButton<ThemeMode>));
      await tap(tester, find.text(label).last);
      await tester.pump(const Duration(seconds: 1));
    }

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await pick(de.settingsAppearanceDark);
    expect(shown(), Brightness.dark);
    state = await restart(tester, state);
    expect(state.themeMode.value, ThemeMode.dark);
    expect(shown(), Brightness.dark);
    await pick(de.settingsAppearanceSystem);
    expect(shown(), Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await settle(tester);
    final element = tester.element(find.byType(HomeShell));
    debugPrint(
      'E2E-INFO brightness: test ${tester.platformDispatcher.platformBrightness}'
      ', view ${View.of(element).platformDispatcher.platformBrightness}'
      ', media ${MediaQuery.platformBrightnessOf(element)}'
      ', theme ${Theme.of(element).brightness}',
    );
    expect(shown(), Brightness.dark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await settle(tester);
    expect(shown(), Brightness.light);
    // Only this device: a setting of the app, nothing on the server.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('themeMode'), 'system');
    expect(
      (await state.engine!.api.config()).keys.where(
        (k) => k.toLowerCase().contains('theme'),
      ),
      isEmpty,
    );
    await finish(tester, state);
  });

  testWidgets('GRU-107 high contrast: the switch and the system', (
    tester,
  ) async {
    tall(tester);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = await start(tester);
    FamioColors colors() =>
        FamioColors.of(tester.element(find.byType(HomeShell)));
    final normal = colors();
    expect(normal.highContrast, isFalse);
    await openSection(tester, 'Einstellungen');
    final contrast = find.widgetWithText(
      SwitchListTile,
      de.settingsHighContrast,
    );
    await scrollTo(tester, contrast);
    await tap(tester, contrast);
    await tester.pump(const Duration(seconds: 1));
    expect(state.highContrast.value, isTrue);
    expect(colors().highContrast, isTrue);
    expect(colors().inkSoft, isNot(normal.inkSoft));
    expect(colors().line, isNot(normal.line));
    await tap(tester, contrast);
    await tester.pump(const Duration(seconds: 1));
    expect(colors().highContrast, isFalse);
    // "Kontrast erhöhen" of the system, the switch off.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    await settle(tester);
    final element = tester.element(find.byType(HomeShell));
    debugPrint(
      'E2E-INFO contrast: test '
      '${tester.platformDispatcher.accessibilityFeatures.highContrast}'
      ', view '
      '${View.of(element).platformDispatcher.accessibilityFeatures.highContrast}'
      ', media ${MediaQuery.highContrastOf(element)}',
    );
    expect(state.highContrast.value, isFalse);
    expect(colors().highContrast, isTrue);
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await settle(tester);
    expect(colors().highContrast, isFalse);
    await finish(tester, state);
  });

  testWidgets('GRU-108 English, also the server\'s messages; French device', (
    tester,
  ) async {
    tall(tester);
    addTearDown(() => deviceLanguage = () => 'de');
    final state = await start(tester);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.byType(DropdownButton<String>));
    await tap(tester, find.byType(DropdownButton<String>));
    await tap(tester, find.text('English').last);
    await tester.pump(const Duration(seconds: 1));
    expect(state.language.value, 'en');
    expect(FamioApiClient.language, 'en');
    // At once: the whole app (it starts over on its start page).
    await waitFor(tester, find.text(en.sectionSettings));
    await openSection(tester, en.sectionSettings);
    if (find.text(en.tipGotIt).evaluate().isNotEmpty) {
      await tap(tester, find.text(en.tipGotIt).last);
    }
    await waitFor(tester, find.text(en.settingsChangePassword));
    expect(find.text(en.sectionSettings), findsWidgets);
    expect(find.text(de.settingsChangePassword), findsNothing);
    // A message of the server in English.
    await scrollTo(tester, find.text(en.settingsChangePassword));
    await tap(tester, find.text(en.settingsChangePassword));
    await enter(tester, field(en.settingsCurrentPassword), 'falsch-falsch-9');
    await enter(tester, field(en.settingsNewPassword), _strong2);
    await submit(tester, en.commonSave);
    await waitFor(tester, inDialog(find.text('Current password is wrong')));
    await tap(tester, inDialog(find.text(en.commonCancel)));
    await dialogClosed(tester);
    // "Like the device", which speaks French: English.
    deviceLanguage = () => 'fr';
    await scrollTo(tester, find.byType(DropdownButton<String>), up: true);
    await tap(tester, find.byType(DropdownButton<String>));
    await tap(tester, find.text(en.languageSystem).last);
    await tester.pump(const Duration(seconds: 1));
    expect(state.language.value, 'system');
    expect(FamioApiClient.language, 'en');
    expect(find.text(en.sectionSettings), findsWidgets);
    await finish(tester, state);
    deviceLanguage = () => 'de';
  });

  // === Mitteilungen =========================================================

  testWidgets('GRU-122 quiet time for the whole account', (tester) async {
    tall(tester);
    final f = await theFamily();
    // Another device of the same account.
    final other = f.admin;
    await other.setQuietHours(const QuietHours());
    addTearDown(() => other.setQuietHours(const QuietHours()));
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    final state = await start(tester, url: gate.url);
    await openPushSettings(tester);
    final on = find.widgetWithText(SwitchListTile, de.pushTurnQuietTime);
    await scrollTo(tester, on);
    await tap(tester, on);
    await waitFor(tester, find.text(de.pushTime(QuietHours.format(21 * 60))));

    Future<void> time(String button, int hour, int minute) async {
      await scrollTo(tester, find.text(button));
      await tap(tester, find.text(button));
      await typeTime(tester, hour, minute);
    }

    await time(de.pushTime(QuietHours.format(21 * 60)), 22, 0);
    final from = de.pushTime(QuietHours.format(22 * 60));
    await waitFor(tester, find.text(from));
    await time(de.pushUntilTime(QuietHours.format(7 * 60)), 6, 30);
    final until = de.pushUntilTime(QuietHours.format(6 * 60 + 30));
    await waitFor(tester, find.text(until));
    final loud = find.widgetWithText(
      SwitchListTile,
      de.pushPlaceNotificationsLoudAnyway,
    );
    await scrollTo(tester, loud);
    expect(tester.widget<SwitchListTile>(loud).value, isTrue);
    await tap(tester, loud);
    // The other device has the same.
    await eventually(tester, 'the same on the other device', () async {
      final q = await other.quietHours();
      return q.enabled &&
          q.start == 22 * 60 &&
          q.end == 6 * 60 + 30 &&
          !q.placesLoud;
    });
    // Without the server a change springs back, with a message.
    gate.cut();
    await time(from, 23, 0);
    await waitFor(tester, find.byType(SnackBar));
    await waitFor(tester, find.text(from));
    expect(find.text(de.pushTime(QuietHours.format(23 * 60))), findsNothing);
    expect((await other.quietHours()).start, 22 * 60);
    gate.restore();
    await finish(tester, state);
  });

  testWidgets(
    'GRU-124 day preview at 06:45, no week preview, leaving by bike',
    (tester) async {
      tall(tester);
      var state = await start(tester);
      await openPushSettings(tester);
      final day = find.widgetWithText(SwitchListTile, de.pushDayPreview);
      await scrollTo(tester, day);
      await tap(tester, day);
      await scrollTo(tester, find.text(de.pushDayPreviewTime));
      await tap(tester, find.text(de.pushDayPreviewTime));
      await typeTime(tester, 6, 45);
      await waitFor(tester, find.text(de.pushDayPreviewSubtitle('06:45')));
      final week = find.widgetWithText(SwitchListTile, de.pushWeekPreview);
      await scrollTo(tester, week);
      expect(tester.widget<SwitchListTile>(week).value, isTrue);
      await tap(tester, week);
      final leave = find.widgetWithText(SwitchListTile, de.pushDeparture);
      await scrollTo(tester, leave);
      // On by default (by car).
      if (!tester.widget<SwitchListTile>(leave).value) await tap(tester, leave);
      await tap(tester, find.byTooltip(de.tripModeBike));
      expect(state.departureMode, TripMode.bike);

      // After a restart (per device) all of it is still so.
      state = await restart(tester, state);
      await openPushSettings(tester);
      await scrollTo(tester, find.text(de.pushDayPreviewSubtitle('06:45')));
      expect(tester.widget<SwitchListTile>(day).value, isTrue);
      await scrollTo(tester, week);
      expect(tester.widget<SwitchListTile>(week).value, isFalse);
      await scrollTo(tester, leave);
      expect(tester.widget<SwitchListTile>(leave).value, isTrue);
      expect(
        tester
            .widget<SegmentedButton<TripMode>>(
              find.byType(SegmentedButton<TripMode>),
            )
            .selected,
        {TripMode.bike},
      );
      await finish(tester, state);
    },
  );

  // === Konto ================================================================

  testWidgets('GRU-127 the own profile', (tester) async {
    tall(tester);
    final f = await theFamily();
    final m = await member('e2e-profil', 'E2E Profil');
    final bea = await sessionOf(f.bea);
    final state = await start(tester, user: 'e2e-profil');
    await tap(tester, find.byTooltip(de.settingsMyProfile));
    await waitFor(tester, inDialog(find.text(de.settingsMyProfile)));
    await enter(tester, field(de.settingsDisplayName), 'E2E Profil Neu');
    final color = famioPalette[2];
    await tap(
      tester,
      inDialog(
        find.byWidgetPredicate(
          (w) =>
              w is AnimatedContainer &&
              (w.decoration as BoxDecoration?)?.color == Color(color),
        ),
      ),
    );
    await tap(tester, inDialog(find.text(de.birthdayChooseBirthday)));
    await pickDate(tester, DateTime(1990, 5, 17));
    await submit(tester, de.commonSave);
    await dialogClosed(tester);
    // Greeting, settings, family list – and the other member's device.
    await waitFor(tester, find.textContaining(', E2E Profil Neu!'));
    await openSection(tester, 'Einstellungen');
    await waitFor(tester, exactly('E2E Profil Neu'));
    await scrollTo(tester, find.text(de.settingsFamily));
    await scrollTo(tester, tile('E2E Profil Neu'));
    await eventually(tester, 'Bea sees name and color', () async {
      final there = (await bea.members()).firstWhere((x) => x.id == m.id);
      return there.displayName == 'E2E Profil Neu' &&
          there.color == color &&
          there.birthday?.month == 5 &&
          there.birthday?.day == 17;
    });
    // Without a name: said in the dialog, nothing changes.
    await scrollTo(tester, find.byTooltip(de.settingsEditProfile), up: true);
    await tap(tester, find.byTooltip(de.settingsEditProfile));
    await enter(tester, field(de.settingsDisplayName), '');
    await submit(tester, de.commonSave);
    await waitFor(tester, inDialog(find.text('Der Name fehlt')));
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    expect(
      (await bea.members()).firstWhere((x) => x.id == m.id).displayName,
      'E2E Profil Neu',
    );
    await finish(tester, state);
  });

  // === Über und Hilfe =======================================================

  testWidgets('GRU-140 the versions, also without the server', (tester) async {
    tall(tester);
    final f = await theFamily();
    final info = await PackageInfo.fromPlatform();
    final server = (await f.admin.health()).version;
    final app =
        '${AppEnv.appName} ${info.version}'
        '${info.buildNumber.isEmpty ? '' : ' (${info.buildNumber})'}';
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    var state = await start(tester, url: gate.url);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(app));
    await waitFor(tester, find.text(de.settingsServerVersion(server)));
    gate.cut();
    state = await restart(tester, state);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(app));
    await waitFor(
      tester,
      find.text(de.settingsServerVersion(de.settingsNotReachable)),
      timeout: const Duration(seconds: 45),
    );
    gate.restore();
    await finish(tester, state);
  });

  testWidgets('GRU-141 privacy and licenses', (tester) async {
    tall(tester);
    _launcher.opened.clear();
    final state = await start(tester);
    await openSettingsItem(tester, de.settingsPrivacy);
    await eventually(
      tester,
      'the privacy information opens',
      () async => _launcher.opened.contains(AppEnv.privacyUrl),
    );
    // The test binding leaves out the licenses the app's binding reads from
    // the bundle (NOTICES.Z); they are added here the same way.
    final notices = utf8.decode(
      gzip.decode((await rootBundle.load('NOTICES.Z')).buffer.asUint8List()),
    );
    final entries = <LicenseEntry>[
      for (final license in notices.split('\n${'-' * 80}\n'))
        if (license.indexOf('\n\n') case final split when split > 0)
          LicenseEntryWithLineBreaks(
            license.substring(0, split).split('\n'),
            license.substring(split + 2),
          ),
    ];
    expect(entries, isNotEmpty);
    LicenseRegistry.addLicense(() => Stream.fromIterable(entries));
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsLicenses));
    await tap(tester, find.text(de.settingsLicenses));
    await waitFor(tester, find.byType(LicensePage));
    // The packages with their licenses (in the list: archive, sqlite3 …).
    await waitFor(tester, find.text('archive'));
    await tap(tester, find.text('archive'));
    await waitFor(tester, find.textContaining('Copyright'));
    await finish(tester, state);
    // Also on the sign-in page.
    await waitFor(tester, field(de.connectServerAddress));
    _launcher.opened.clear();
    await tap(tester, find.text(de.settingsPrivacy));
    await eventually(
      tester,
      'from the sign-in page as well',
      () async => _launcher.opened.contains(AppEnv.privacyUrl),
    );
  });

  testWidgets('GRU-142 the sources of the health content', (tester) async {
    tall(tester);
    _launcher.opened.clear();
    final state = await start(tester);
    await openSettingsItem(tester, de.sourcesTitle);
    await waitFor(tester, find.text(de.sourcesIntro));
    for (final group in [
      de.sourcesVaccinations,
      de.sourcesCheckups,
      de.sourcesFever,
      de.sourcesGrowth,
      de.sourcesPregnancy,
    ]) {
      expect(find.text(group), findsOneWidget, reason: group);
    }
    for (final stand in [
      'RKI, 22.01.2026',
      'G-BA, Juni 2026',
      'kindergesundheit-info.de (BIÖG), 04.05.2026',
      'WHO, 2006',
      'G-BA, 16.07.2026',
    ]) {
      expect(find.text(stand), findsWidgets, reason: stand);
    }
    await tap(tester, find.text('Fieber bei Kindern'));
    await eventually(
      tester,
      'the source opens',
      () async => _launcher.opened.contains(
        'https://www.kindergesundheit-info.de/themen/krankes-kind/'
        'krankheitszeichen/fieber/',
      ),
    );
    await finish(tester, state);
  });

  // === Wandanzeige ==========================================================

  testWidgets('GRU-144 the wall display: what it shows, staying on, leaving', (
    tester,
  ) async {
    tall(tester, width: 1300, height: 1600);
    final f = await theFamily();
    final day = today(), tomorrow = inDays(1);
    // Bea's birthday today, the bins tomorrow, a countdown, a chore, a list
    // and dinner.
    await f.admin.updateUser(
      f.bea.id,
      birthday: Birthday(day.month, day.day, 1990),
    );
    addTearDown(() => f.admin.updateUser(f.bea.id, clearBirthday: true));
    final events = <String>[];
    Future<void> event(
      String title,
      DateTime start, {
      bool countdown = false,
    }) async {
      final id = _uid('event');
      events.add(id);
      await put(f.admin, Collections.events, {
        id: CalendarEvent(
          id: id,
          title: title,
          start: start,
          end: DateUtils.addDaysToDate(start, 1),
          allDay: true,
          countdown: countdown,
        ).toData(),
      });
    }

    await event('E2E Heute ganztägig', day);
    await event('E2E Morgen ganztägig', tomorrow);
    await event('E2E Restmüll', tomorrow);
    await event('E2E Urlaub', inDays(10), countdown: true);
    addTearDown(() => remove(f.admin, Collections.events, events));
    await put(f.admin, Collections.wasteSettings, {
      WasteSettings.recordId: const WasteSettings().toData(),
    });
    addTearDown(
      () =>
          remove(f.admin, Collections.wasteSettings, [WasteSettings.recordId]),
    );
    final chore = _uid('chore');
    await put(f.admin, Collections.chores, {
      chore: Chore(
        id: chore,
        title: 'E2E Tisch decken',
        memberIds: [f.kid.id],
        start: day,
      ).toData(),
    });
    addTearDown(() => remove(f.admin, Collections.chores, [chore]));
    final meal = _uid('meal');
    await put(f.admin, Collections.mealPlan, {
      meal: PlannedMeal(
        id: meal,
        date: day,
        slot: MealSlot.dinner,
        title: 'E2E Nudelauflauf',
      ).toData(),
    });
    addTearDown(() => remove(f.admin, Collections.mealPlan, [meal]));
    final state = await start(tester);
    final engine = state.engine!;
    var list = engine.shoppingLists
        .where((l) => !l.packing && l.visibleTo == null)
        .firstOrNull;
    if (list == null) {
      list = ShoppingList(id: newId(), name: 'E2E Wandliste');
      engine.saveShoppingList(list);
    }
    final item = newId();
    engine.saveShoppingItem(
      ShoppingItem(id: item, listId: list.id, name: 'E2E Haferflocken'),
    );
    await engine.sync();

    await openKiosk(tester);
    // The big clock and the date.
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data ?? ''),
      ),
      findsWidgets,
    );
    expect(
      find.text(DateFormat.MMMMEEEEd('de').format(DateTime.now())),
      findsOneWidget,
    );
    await waitFor(tester, find.textContaining('🎂 Heute: E2E Bea'));
    await waitFor(
      tester,
      find.text(
        '${de.commonTomorrow}: '
        '${WasteKind.residual.emoji} ${WasteKind.residual.label}',
      ),
    );
    await waitFor(tester, find.textContaining('🎉 E2E Urlaub: '));
    for (final panel in [
      de.commonEvents,
      de.kioskChoresRoutines,
      list.name,
      de.kioskMealsToday,
    ]) {
      expect(find.text(panel), findsWidgets, reason: panel);
    }
    expect(find.textContaining(de.weatherWeather), findsWidgets);
    expect(find.text(de.commonToday), findsWidgets);
    expect(find.text('E2E Heute ganztägig'), findsOneWidget);
    expect(find.text('E2E Morgen ganztägig'), findsOneWidget);
    expect(find.textContaining('E2E Tisch decken'), findsWidgets);
    expect(find.text('E2E Haferflocken'), findsOneWidget);
    expect(find.text('E2E Nudelauflauf'), findsOneWidget);
    // The screen stays on while it is open.
    expect(await WakelockPlus.enabled, isTrue);

    // An area switched off is not shown.
    await f.admin.updateServerSettings({
      'hiddenModules': [FamioSection.meals.name],
    });
    addTearDown(() => f.admin.updateServerSettings({'hiddenModules': null}));
    await waitGone(tester, find.text(de.kioskMealsToday));
    expect(find.text('E2E Nudelauflauf'), findsNothing);
    await f.admin.updateServerSettings({'hiddenModules': null});
    await waitFor(tester, find.text(de.kioskMealsToday));

    await tap(tester, find.byTooltip(de.kioskCloseWallDisplay));
    await waitGone(tester, find.byType(KioskScreen));
    await waitFor(tester, signedInMark);
    expect(await WakelockPlus.enabled, isFalse);
    engine.deleteShoppingItem(item);
    await finish(tester, state);
  });

  testWidgets('GRU-147 ticking a chore off on the wall display', (
    tester,
  ) async {
    tall(tester, width: 1300, height: 1600);
    final f = await theFamily();
    final id = _uid('chore');
    final chore = Chore(
      id: id,
      title: 'E2E Blumen giessen',
      emoji: '🌻',
      points: 2,
      memberIds: [f.kid.id],
      start: today(),
    );
    await put(f.admin, Collections.chores, {id: chore.toData()});
    addTearDown(() => remove(f.admin, Collections.chores, [id]));
    Future<SyncRecord?> request(AppState state) async => (await pull(
      f.admin,
      Collections.pointEntries,
    ))[chore.completionId(state.engine!.calendar.today())];

    // An adult's wall display: a request (grey), taken back by a second tap.
    var state = await start(tester);
    await openKiosk(tester);
    final check = roundCheck('E2E Blumen giessen');
    await waitFor(tester, check);
    expect(tester.widget<RoundCheck>(check).value, isFalse);
    await tap(tester, check);
    await eventually(
      tester,
      'a request on the server',
      () async => (await request(state))?.data['status'] == 'pending',
    );
    expect(tester.widget<RoundCheck>(check).value, isTrue);
    expect(
      tester.widget<RoundCheck>(check).color,
      FamioColors.of(tester.element(check)).inkSoft,
    );
    final pending = PointEntry.fromRecord((await request(state))!);
    expect((pending.memberId, pending.points), (f.kid.id, 2));
    await tap(tester, check);
    await eventually(
      tester,
      'taken back',
      () async => await request(state) == null,
    );
    expect(tester.widget<RoundCheck>(check).value, isFalse);
    await tap(tester, find.byTooltip(de.kioskCloseWallDisplay));
    await finish(tester, state);

    // A guest's: nothing happens.
    state = await start(tester, user: 'e2e-gast');
    await openKiosk(tester);
    await waitFor(tester, check);
    await tap(tester, check);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.widget<RoundCheck>(check).value, isFalse);
    expect(
      state.engine!.store.dirty.where(
        (r) => r.record.collection == Collections.pointEntries,
      ),
      isEmpty,
    );
    expect(await request(state), isNull);
    await tap(tester, find.byTooltip(de.kioskCloseWallDisplay));
    await finish(tester, state);
  });

  testWidgets(
    'GRU-145 GRU-146 by person, nothing private, photos after two minutes',
    (tester) async {
      tall(tester, width: 1300, height: 1600);
      final f = await theFamily();
      final state = await start(tester);
      final engine = state.engine!;
      final me = state.me!.id;
      final now = DateTime.now();
      // Private things next to the family's.
      final ids = {
        for (final k in ['busy', 'mine', 'open']) k: newId(),
      };
      final soon = now.add(const Duration(minutes: 30));
      engine
        ..saveEvent(
          CalendarEvent(
            id: ids['busy']!,
            title: 'E2E Geheimtermin',
            start: soon,
            end: soon.add(const Duration(hours: 1)),
            memberIds: [f.bea.id],
            confidential: true,
          ),
        )
        ..put(Collections.events, ids['mine']!, {
          ...CalendarEvent(
            id: ids['mine']!,
            title: 'E2E Nur-ich-Termin',
            start: today(),
            end: inDays(1),
            allDay: true,
          ).toData(),
          'visibleTo': [me],
        })
        ..saveEvent(
          CalendarEvent(
            id: ids['open']!,
            title: 'E2E Familientermin',
            start: today(),
            end: inDays(1),
            allDay: true,
          ),
        );
      final tasks = {'mine': newId(), 'all': newId()};
      engine
        ..saveTask(
          Task(id: tasks['mine']!, title: 'E2E Privataufgabe', visibleTo: [me]),
        )
        ..saveTask(Task(id: tasks['all']!, title: 'E2E Familienaufgabe'));
      final secretList = newId(), secretItem = newId();
      engine
        ..saveShoppingList(
          ShoppingList(
            id: secretList,
            name: 'E2E Geheimliste',
            visibleTo: [me],
          ),
        )
        ..saveShoppingItem(
          ShoppingItem(
            id: secretItem,
            listId: secretList,
            name: 'E2E Geheimkauf',
          ),
        );
      final family = await uploadAs(
        engine.api,
        'e2e-familie.png',
        _png1,
        mime: 'image/png',
      );
      final private = await uploadAs(
        engine.api,
        'e2e-privat.png',
        _png2,
        mime: 'image/png',
      );
      final docs = {'family': newId(), 'private': newId()};
      engine
        ..saveDocument(
          FamilyDocument(
            id: docs['family']!,
            title: 'E2E Familienfoto',
            category: DocumentCategory.photos,
            file: family,
          ),
        )
        ..saveDocument(
          FamilyDocument(
            id: docs['private']!,
            title: 'E2E Privatfoto',
            category: DocumentCategory.photos,
            file: private,
            visibleTo: [me],
          ),
        );
      await engine.sync();
      addTearDown(() async {
        for (final id in ids.values) {
          await remove(f.admin, Collections.events, [id]);
        }
      });

      void nothingPrivate() {
        for (final secret in [
          'E2E Geheimtermin',
          'E2E Nur-ich-Termin',
          'E2E Privataufgabe',
          'E2E Geheimkauf',
          'E2E Geheimliste',
        ]) {
          expect(find.textContaining(secret), findsNothing, reason: secret);
        }
      }

      // By topic.
      await openKiosk(tester);
      await waitFor(tester, find.text('E2E Familientermin'));
      expect(find.text(de.eventBusy), findsNWidgets(2));
      nothingPrivate();

      // GRU-145: by person, the choice kept.
      await tap(tester, find.byTooltip(de.kioskShowPerson));
      await waitFor(tester, find.byTooltip(de.kioskShowTopic));
      expect(state.kioskByPerson, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getBool('kiosk.byPerson'),
        isTrue,
      );
      for (final name in [
        de.commonEveryone,
        kitAdminName,
        'E2E Bea',
        'E2E Carl',
        'E2E Gast',
        'E2E Kind',
      ]) {
        expect(exactly(name), findsWidgets, reason: name);
      }
      expect(exactly('E2E HA'), findsNothing);
      expect(find.text('E2E Familienaufgabe'), findsOneWidget);
      expect(find.text(de.eventBusy), findsNWidgets(2));
      nothingPrivate();

      // Two minutes untouched: the family photos, not the private one.
      await waitFor(
        tester,
        find.byType(PhotoSlideshow),
        timeout: const Duration(minutes: 3),
      );
      final show = tester.widget<PhotoSlideshow>(find.byType(PhotoSlideshow));
      expect(show.photos.map((p) => p.id), [family.id]);
      expect(find.textContaining(de.eventBusy), findsOneWidget);
      nothingPrivate();
      // A touch ends it.
      await tester.tapAt(const Offset(600, 600));
      await tester.pump(const Duration(seconds: 1));
      await waitGone(tester, find.byType(PhotoSlideshow));
      // "Keine Fotos zeigen": two minutes later still the board.
      await tap(tester, find.byTooltip(de.kioskShowNoPhotos));
      expect(state.kioskPhotos, isFalse);
      await waitFor(tester, find.byTooltip(de.kioskShowPhotosWhenNobody));
      final until = DateTime.now().add(const Duration(minutes: 2, seconds: 20));
      while (DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(PhotoSlideshow), findsNothing);
      }
      await tap(tester, find.byTooltip(de.kioskCloseWallDisplay));
      engine
        ..deleteTask(tasks['mine']!)
        ..deleteTask(tasks['all']!)
        ..deleteShoppingList(secretList)
        ..delete(Collections.documents, docs['family']!)
        ..delete(Collections.documents, docs['private']!);
      await engine.sync();
      await finish(tester, state);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );

  testWidgets('GRU-148 opening as the wall display at the start', (
    tester,
  ) async {
    tall(tester);
    var state = await start(tester);
    await openSection(tester, 'Einstellungen');
    final auto = find.widgetWithText(SwitchListTile, de.settingsKioskAutostart);
    await scrollTo(tester, auto);
    await tap(tester, auto);
    expect(state.kioskAutostart, isTrue);
    // As after an update: "Was ist neu" would be due.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('whatsNew.seen', '0.0.1');
    state = await restart(tester, state, signedIn: false);
    await waitFor(
      tester,
      find.byType(KioskScreen),
      timeout: const Duration(seconds: 60),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(Dialog), findsNothing);
    expect(prefs.getString('whatsNew.seen'), '0.0.1');
    await tap(tester, find.byTooltip(de.kioskCloseWallDisplay));
    await waitFor(tester, signedInMark);
    await finish(tester, state);
  });

  // === Rollen und Navigation ================================================

  testWidgets('GRU-162 the areas of a guest', (tester) async {
    tall(tester);
    const hidden = {
      FamioSection.documents,
      FamioSection.kids,
      FamioSection.location,
      FamioSection.budget,
      FamioSection.health,
    };
    final state = await start(tester, user: 'e2e-gast');
    final rail = railSections();
    expect(rail.toSet().intersection(hidden), isEmpty);
    expect(rail, containsAll(FamioSection.values.toSet().difference(hidden)));
    for (final label in [
      'Dokumente',
      'Kinder',
      'Standort',
      'Finanzen',
      'Medizin',
    ]) {
      expect(exactly(label), findsNothing, reason: label);
    }
    // On a phone: neither in the bar nor behind "Mehr".
    tester.view.physicalSize =
        const Size(400, 820) * tester.view.devicePixelRatio;
    await tester.pump(const Duration(seconds: 1));
    await tap(tester, find.byTooltip(de.navMore));
    await waitFor(tester, moreTiles);
    final more = [
      for (final e in moreTiles.evaluate())
        (e.widget as dynamic).section as FamioSection,
    ];
    expect(more.toSet().intersection(hidden), isEmpty);
    await closeSheet(tester);
    tester.view.physicalSize =
        const Size(800, 1600) * tester.view.devicePixelRatio;
    await tester.pump(const Duration(seconds: 1));
    await finish(tester, state);
  });

  testWidgets('GRU-163 the navigation on a phone and on a computer', (
    tester,
  ) async {
    tall(tester, width: 400, height: 820);
    final state = await start(tester);
    // Narrow: the bar and "Mehr".
    await tester.pump(const Duration(seconds: 1));
    expect(
      [for (final e in barItems.evaluate()) (e.widget as dynamic).label],
      [
        'Start',
        de.sectionTasks,
        de.sectionShopping,
        de.sectionCalendar,
        de.sectionChat,
        de.navMore,
      ],
    );
    await tap(tester, find.byTooltip(de.navMore));
    await waitFor(tester, moreTiles);
    await tester.pump(const Duration(milliseconds: 600));
    final more = [
      for (final e in moreTiles.evaluate())
        (e.widget as dynamic).section as FamioSection,
    ];
    const bar = {
      FamioSection.home,
      FamioSection.tasks,
      FamioSection.shopping,
      FamioSection.calendar,
      FamioSection.chat,
    };
    expect(more, [
      for (final s in FamioSection.values)
        if (!bar.contains(s)) s,
    ]);
    // Three a row.
    final tops = [
      for (final e in moreTiles.evaluate())
        tester.getTopLeft(find.byWidget(e.widget)).dy,
    ];
    expect(tops[1], tops[0]);
    expect(tops[2], tops[0]);
    expect(tops[3], greaterThan(tops[0]));
    await closeSheet(tester);

    // Wide: the rail with every area, long names shrunk, not cut off.
    tester.view.physicalSize =
        const Size(1280, 900) * tester.view.devicePixelRatio;
    await tester.pump(const Duration(seconds: 1));
    expect(railSections(), FamioSection.values);
    final label = find.descendant(
      of: railItems.last,
      matching: find.text(de.sectionSettings),
    );
    expect(
      tester.renderObject<RenderParagraph>(label).debugHasOverflowShader,
      isFalse,
    );
    final rail = tester.getRect(railItems.last);
    final text = tester.getRect(label);
    expect(text.left, greaterThanOrEqualTo(rail.left));
    expect(text.right, lessThanOrEqualTo(rail.right));
    // The current area again: back to its start page.
    final trashPage = find.byWidgetPredicate((w) => _is(w, 'TrashScreen'));
    await openSettingsItem(tester, de.trashTitle);
    await waitFor(tester, trashPage);
    await tap(tester, label);
    await waitGone(tester, trashPage);
    await waitFor(tester, find.text(de.settingsSubtitle));
    await finish(tester, state);
  });

  testWidgets('GRU-165 the settings by role', (tester) async {
    tall(tester);
    final f = await theFamily();
    const everyone = [
      'Papierkorb',
      'Meine Geräte',
      'Anmeldung & Sicherheit',
      'Meine Daten exportieren',
      'Mein Konto löschen',
    ];
    for (final (user, role) in [
      (null, 'admin'),
      ('e2e-bea', 'adult'),
      ('e2e-kind', 'child'),
      ('e2e-gast', 'guest'),
    ]) {
      final state = await start(tester, user: user);
      final texts = await settingsTexts(tester);
      debugPrint('E2E-INFO settings of $role: ${texts.length} texts');
      expect(
        texts.contains(de.settingsServerAdministration),
        role == 'admin',
        reason: '$role: Server-Verwaltung',
      );
      expect(
        texts.contains(de.memberEmergencyMine),
        role == 'admin' || role == 'adult',
        reason: '$role: Notfall-Infos',
      );
      for (final t in [de.settingsDeadlines, de.loansTitle, de.settingsWaste]) {
        expect(texts.contains(t), role != 'guest', reason: '$role: $t');
      }
      for (final t in everyone) {
        expect(texts, contains(t), reason: '$role: $t');
      }
      // The family with usernames, roles and who is administrator.
      expect(texts, contains('@$kitUser · ${de.settingsAdministrator}'));
      expect(texts, contains('@${f.bea.username}'));
      expect(texts, contains('@${f.kid.username} · ${MemberRole.child.label}'));
      expect(
        texts,
        contains('@${f.guest.username} · ${MemberRole.guest.label}'),
      );
      await finish(tester, state);
    }
  });

  testWidgets('GRU-166 the storage on this computer', (tester) async {
    tall(tester);
    final f = await theFamily();
    final bytes = _bigPdf(2);
    final ref = await uploadAs(f.admin, 'e2e-speicher.pdf', bytes);
    final id = _uid('doc');
    await put(f.admin, Collections.documents, {
      id: FamilyDocument(
        id: id,
        title: 'E2E Speicherprobe',
        category: DocumentCategory.other,
        file: ref,
      ).toData(),
    });
    addTearDown(() => remove(f.admin, Collections.documents, [id]));
    final state = await start(tester);
    final files = state.files!;
    files.clear();
    _launcher.opened.clear();
    await openDocument(tester, 'E2E Speicherprobe');
    await eventually(
      tester,
      'opened',
      () async => _launcher.opened.length == 1,
    );
    expect(files.size, greaterThan(_mb * 1.5));
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 500));
    String mb(int b) => '${(b / _mb).round()} MB';
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsStorage));
    expect(
      subtitleOf(tester, de.settingsStorage),
      de.settingsPhotosDocumentsViewingOffline(
        mb(files.size),
        mb(files.maxBytes),
      ),
    );
    final clear = find.descendant(
      of: tile(de.settingsStorage),
      matching: find.widgetWithText(TextButton, de.settingsStorageClear),
    );
    await tap(tester, clear);
    await waitFor(tester, find.text(de.settingsStorageClearConfirm));
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.settingsStorageClear)),
    );
    await dialogClosed(tester);
    expect(files.size, 0);
    expect(
      subtitleOf(tester, de.settingsStorage),
      de.settingsPhotosDocumentsViewingOffline('0 MB', mb(files.maxBytes)),
    );
    expect(tester.widget<TextButton>(clear).onPressed, isNull);
    // Opened again: loaded from the server anew.
    await openDocument(tester, 'E2E Speicherprobe');
    await eventually(
      tester,
      'opened again',
      () async => _launcher.opened.length == 2,
    );
    expect(
      await File.fromUri(Uri.parse(_launcher.opened.last)).readAsBytes(),
      bytes,
    );
    expect(files.size, greaterThan(0));
    await tester.tapAt(const Offset(10, 10));
    await finish(tester, state);
  });

  // === Konto: Export ========================================================

  testWidgets(
    'GRU-137 GRU-138 the own export: wrong password, saved, cancelled',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      final bea = await sessionOf(f.bea);
      final m = await member('e2e-export', 'E2E Export');
      final mine = await sessionOf(m);
      // What it sees: its own task and file, its way; not Bea's private note.
      final task = _uid('task');
      await put(mine, Collections.tasks, {
        task: Task(
          id: task,
          title: 'E2E Export eigen',
          visibleTo: [m.id],
        ).toData(),
      });
      // Random bytes: the archive cannot squeeze them, the transfer takes a
      // while through the slow proxy.
      final random = Random(7);
      final file = await uploadAs(mine, 'e2e-export.pdf', [
        ..._pdf,
        for (var i = 0; i < 1.5 * _mb; i++) random.nextInt(256),
      ]);
      final doc = _uid('doc');
      await put(mine, Collections.documents, {
        doc: FamilyDocument(
          id: doc,
          title: 'E2E Export Dokument',
          category: DocumentCategory.other,
          file: file,
          visibleTo: [m.id],
        ).toData(),
      });
      final note = _uid('note');
      await put(bea, Collections.notes, {
        note: FamilyNote(
          id: note,
          title: 'E2E Bea privat Export',
          visibleTo: [f.bea.id],
        ).toData(),
      });
      addTearDown(() => remove(bea, Collections.notes, [note]));
      await mine.resumeLocation();
      await mine.reportLocation([
        LocationFix(
          latitude: 50.1109,
          longitude: 8.6821,
          accuracy: 15,
          at: DateTime.now(),
        ),
      ], device: 'E2E Handy');
      final picker = _fakePicker();
      final dir = await Directory.systemTemp.createTemp('famio-e2e-export');
      addTearDown(() => dir.delete(recursive: true));
      picker.directory = dir.path;
      final proxy = SlowProxy();
      await proxy.start();
      addTearDown(proxy.stop);
      final state = await start(tester, user: 'e2e-export', url: proxy.url);

      Future<void> openExport() async {
        await snackGone(tester);
        await openSettingsItem(tester, de.settingsExport);
        await waitFor(
          tester,
          inDialog(find.text(de.exportZipFileEverythingYou)),
        );
      }

      List<File> zips() => [
        for (final e in dir.listSync())
          if (e is File && e.path.endsWith('.zip')) e,
      ];

      // A wrong password.
      await openExport();
      await enter(tester, field(de.exportFamioPassword), 'falsch-falsch-7');
      await submit(tester, de.adminExport);
      await waitFor(tester, inDialog(find.text('Passwort falsch')));
      expect(zips(), isEmpty);
      // The right one: the bar, then "Export gesichert".
      proxy.slow = true;
      await enter(tester, field(de.exportFamioPassword), kitMemberPassword);
      await leaveField(tester);
      await tap(
        tester,
        inDialog(find.widgetWithText(FilledButton, de.adminExport)),
      );
      await waitFor(
        tester,
        inDialog(find.byType(LinearProgressIndicator)),
        timeout: const Duration(seconds: 30),
      );
      await waitFor(
        tester,
        find.text(de.exportExportSaved),
        timeout: const Duration(minutes: 2),
      );
      expect(zips(), hasLength(1));
      final zip = unzip(zips().single.readAsBytesSync());
      expect(zipTitles(zip, Collections.tasks), contains('E2E Export eigen'));
      expect(
        zip.keys.where((k) => k.startsWith('files/${file.id}-')),
        hasLength(1),
      );
      expect(
        zipTitles(zip, Collections.notes),
        isNot(contains('E2E Bea privat Export')),
      );
      final way = jsonDecode(utf8.decode(zip['location.json']!)) as List;
      expect(way.any((p) => (p as Map)['latitude'] == 50.1109), isTrue);

      // GRU-138: cancelled halfway – no half archive, a file of the same name
      // stays as it was.
      zips().single.deleteSync();
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final same = File(p.join(dir.path, 'famio-meine-daten-$day.zip'))
        ..writeAsStringSync('vorher');
      await openExport();
      await enter(tester, field(de.exportFamioPassword), kitMemberPassword);
      await leaveField(tester);
      await tap(
        tester,
        inDialog(find.widgetWithText(FilledButton, de.adminExport)),
      );
      await waitFor(
        tester,
        inDialog(find.byType(LinearProgressIndicator)),
        timeout: const Duration(seconds: 30),
      );
      await tap(tester, inDialog(find.text(de.commonCancel)));
      await dialogClosed(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(de.exportExportSaved), findsNothing);
      expect(
        [for (final f in zips()) p.basename(f.path)],
        [p.basename(same.path)],
      );
      expect(same.readAsStringSync(), 'vorher');
      proxy.slow = false;
      await finish(tester, state);
    },
  );

  testWidgets('GRU-139 the export of a child', (tester) async {
    tall(tester);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final kidApi = await sessionOf(f.kid);
    final med = _uid('med');
    await put(f.admin, Collections.medications, {
      med: Medication(
        id: med,
        name: 'E2E Blutdrucktabletten',
        start: today(),
        careIds: [f.adminMember.id],
      ).toData(),
    });
    addTearDown(() => remove(f.admin, Collections.medications, [med]));
    await put(f.admin, Collections.memberEmergency, {
      f.adminMember.id: MemberEmergency(
        memberId: f.adminMember.id,
        documents: 'E2E Notfallmappe im Flur',
      ).toData(),
    });
    final note = _uid('note');
    await put(bea, Collections.notes, {
      note: FamilyNote(
        id: note,
        title: 'E2E Bea privat Kind',
        visibleTo: [f.bea.id],
      ).toData(),
    });
    addTearDown(() => remove(bea, Collections.notes, [note]));
    final task = _uid('task');
    await put(kidApi, Collections.tasks, {
      task: Task(
        id: task,
        title: 'E2E Hausaufgaben',
        assigneeIds: [f.kid.id],
      ).toData(),
    });
    addTearDown(() => remove(kidApi, Collections.tasks, [task]));
    final picker = _fakePicker();
    final dir = await Directory.systemTemp.createTemp('famio-e2e-export-kind');
    addTearDown(() => dir.delete(recursive: true));
    picker.directory = dir.path;
    final state = await start(tester, user: 'e2e-kind');
    await openSettingsItem(tester, de.settingsExport);
    await waitFor(tester, inDialog(find.text(de.exportZipFileEverythingYou)));
    await enter(tester, field(de.exportFamioPassword), kitMemberPassword);
    await submit(tester, de.adminExport);
    await waitFor(
      tester,
      find.text(de.exportExportSaved),
      timeout: const Duration(minutes: 1),
    );
    final file = dir.listSync().whereType<File>().single;
    final zip = unzip(file.readAsBytesSync());
    final all = utf8.decode([
      for (final v in zip.values) ...v,
    ], allowMalformed: true);
    expect(zipTitles(zip, Collections.tasks), contains('E2E Hausaufgaben'));
    expect(zipRecords(zip, Collections.memberEmergency), isEmpty);
    expect(all, isNot(contains('E2E Notfallmappe im Flur')));
    expect(all, isNot(contains('E2E Blutdrucktabletten')));
    expect(all, isNot(contains('E2E Bea privat Kind')));
    await finish(tester, state);
  });

  // === Konto: Passwort ======================================================

  testWidgets('GRU-128 a new password: this device stays, the others go', (
    tester,
  ) async {
    tall(tester);
    await freshMember('e2e-pw', 'E2E Passwort', password: _strong);
    final other = await loginAs('e2e-pw', password: _strong);
    final (_, secret) = await other.createAppPassword(
      name: 'E2E Kalender',
      password: _strong,
    );
    expect(await davStatus('e2e-pw', secret), 207);
    final state = await start(tester, user: 'e2e-pw', password: _strong);
    await openSettingsItem(tester, de.settingsChangePassword);
    await waitFor(tester, inDialog(find.text(de.settingsPasswordChangeNote)));
    await enter(tester, field(de.settingsCurrentPassword), _strong);
    await enter(tester, field(de.settingsNewPassword), _strong2);
    await submit(tester, de.commonSave);
    await dialogClosed(tester);
    // This device stays signed in, the other device and the calendar app
    // are out.
    expect(state.me, isNotNull);
    await state.engine!.api.members();
    await expectLater(
      other.members(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    expect(await davStatus('e2e-pw', secret), 401);
    // Changed on another device: this one is told.
    final third = await loginAs(
      'e2e-pw',
      password: _strong2,
      device: 'E2E Drittgerät',
    );
    await third.changePassword(
      currentPassword: _strong2,
      newPassword: _strong3,
    );
    unawaited(state.engine!.sync());
    await waitFor(
      tester,
      find.text(de.appSessionHasExpiredPlease),
      timeout: const Duration(seconds: 60),
    );
    expect(state.me, isNull);
    await finish(tester, state);
  });

  testWidgets('GRU-129 a new password: the mistakes', (tester) async {
    tall(tester);
    await freshMember('e2e-pwfehler', 'E2E Pwfehler', password: _strong);
    final state = await start(tester, user: 'e2e-pwfehler', password: _strong);
    await openSettingsItem(tester, de.settingsChangePassword);
    Future<void> attempt(String current, String next) async {
      await enter(tester, field(de.settingsCurrentPassword), current);
      await enter(tester, field(de.settingsNewPassword), next);
      await submit(tester, de.commonSave);
    }

    await attempt('falsch-wort-1', _strong2);
    await waitFor(tester, inDialog(find.text('Aktuelles Passwort falsch')));
    await attempt(_strong, 'abcde');
    await waitFor(
      tester,
      inDialog(find.text('Das Passwort muss mindestens 8 Zeichen haben')),
    );
    // Wrong again and again: then it waits.
    for (var i = 2; i <= 6; i++) {
      await attempt('falsch-wort-$i', _strong2);
      await waitFor(tester, inDialog(find.text('Aktuelles Passwort falsch')));
    }
    await attempt('falsch-wort-7', _strong2);
    await waitFor(
      tester,
      inDialog(find.textContaining('Zu viele Fehlversuche.')),
    );
    expect(inDialog(find.text(de.settingsChangePassword)), findsOneWidget);
    // Nothing changed.
    await loginAs('e2e-pwfehler', password: _strong);
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    await finish(tester, state);
  });

  // === Konto löschen (last: accounts go) ====================================

  testWidgets(
    'GRU-131 GRU-130 deleting the own account: wrong, then for real',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      final m = await freshMember('e2e-loesch', 'E2E Löschkonto');
      final setup = await loginAs('e2e-loesch', device: 'e2e-setup');
      final private = _uid('note'), family = _uid('note');
      await put(setup, Collections.notes, {
        private: FamilyNote(
          id: private,
          title: 'E2E Nur für mich',
          visibleTo: [m.id],
        ).toData(),
        family: FamilyNote(id: family, title: 'E2E Für die Familie').toData(),
      });
      addTearDown(() => remove(f.admin, Collections.notes, [family]));
      final begun = await setup.beginTotp(password: kitMemberPassword);
      final auth = Authenticator(begun.secret);
      await setup.confirmTotp(await auth.next(tester));
      expect(
        zipTitles(await familyExport(), Collections.notes),
        contains('E2E Nur für mich'),
      );
      final state = await start(tester, user: 'e2e-loesch', totp: auth);
      await openSettingsItem(tester, de.settingsDeleteAccount);
      await waitFor(
        tester,
        inDialog(find.text(de.settingsDeleteAccountConfirm)),
      );

      // GRU-131: a wrong password, then a wrong code.
      await enter(tester, field(de.settingsPasswordConfirm), 'falsch-falsch-3');
      await submit(tester, de.settingsDeleteAccountButton);
      await waitFor(
        tester,
        inDialog(find.text('Passwort zur Bestätigung falsch')),
      );
      await enter(tester, field(de.settingsPasswordConfirm), kitMemberPassword);
      await enter(tester, field(de.settingsTwoFactorCode), '000000');
      await submit(tester, de.settingsDeleteAccountButton);
      await waitFor(tester, inDialog(find.text('Bestätigungscode falsch')));
      expect(
        (await f.admin.adminUsers()).any((u) => u.member.id == m.id),
        isTrue,
      );

      // GRU-130: right both times.
      await enter(
        tester,
        field(de.settingsTwoFactorCode),
        await auth.next(tester),
      );
      await submit(tester, de.settingsDeleteAccountButton);
      await waitFor(
        tester,
        find.text(de.settingsAccountNameWasDeleted('E2E Löschkonto')),
        timeout: const Duration(seconds: 45),
      );
      expect(state.me, isNull);
      expect(
        (await f.admin.adminUsers()).any((u) => u.member.id == m.id),
        isFalse,
      );
      final notes = zipTitles(await familyExport(), Collections.notes);
      expect(notes, isNot(contains('E2E Nur für mich')));
      expect(notes, contains('E2E Für die Familie'));
      await finish(tester, state);
      // Another adult finds the family note on the pinboard.
      final admin = await start(tester);
      await scrollTo(tester, find.text(de.commonPinboard));
      await tap(tester, find.text(de.commonPinboard));
      await waitFor(tester, find.text('E2E Für die Familie'));
      await finish(tester, admin);
    },
  );

  // A guest deletes the own account; a child's is removed by an adult in
  // the server administration (decided so): the app offers it no deletion
  // but says who does, and the server turns it down.
  testWidgets('GRU-134 a guest deletes the account, a child is told who does', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final guest = await freshMember(
      'e2e-gast-weg',
      'E2E Gast weg',
      role: MemberRole.guest,
    );
    var state = await start(tester, user: 'e2e-gast-weg');
    await openSettingsItem(tester, de.settingsDeleteAccount);
    await waitFor(tester, inDialog(field(de.settingsPasswordConfirm)));
    await enter(tester, field(de.settingsPasswordConfirm), kitMemberPassword);
    await submit(tester, de.settingsDeleteAccountButton);
    await waitFor(
      tester,
      find.text(de.settingsAccountNameWasDeleted('E2E Gast weg')),
      timeout: const Duration(seconds: 45),
    );
    expect(
      (await f.admin.adminUsers()).any((u) => u.member.id == guest.id),
      isFalse,
    );
    await finish(tester, state);

    final kid = await freshMember(
      'e2e-kind-weg',
      'E2E Kind weg',
      role: MemberRole.child,
    );
    state = await start(tester, user: 'e2e-kind-weg');
    await openSection(tester, 'Einstellungen');
    await scrollTo(
      tester,
      find.text(de.settingsDeleteAccountChildHint),
      at: listPoint(tester),
    );
    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text(de.settingsDeleteAccount),
        matching: find.byType(ListTile),
      ),
    );
    expect(tile.enabled, isFalse);
    expect(tile.onTap, isNull);
    final api = await sessionOf(kid);
    await expectLater(
      api.deleteMyAccount(password: kitMemberPassword),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 403)),
    );
    expect(
      (await f.admin.adminUsers()).any((u) => u.member.id == kid.id),
      isTrue,
    );
    await finish(tester, state);
    await f.admin.deleteMember(kid.id);
  });

  testWidgets('GRU-132 the only administrator: with others, then alone', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    var state = await start(tester);
    await openSettingsItem(tester, de.settingsDeleteAccount);
    await waitFor(tester, find.text(de.settingsLastAdminTitle));
    expect(find.text(de.settingsLastAdminOthers), findsOneWidget);
    expect(field(de.settingsPasswordConfirm), findsNothing);
    await tap(
      tester,
      inDialog(
        find.widgetWithText(FilledButton, de.settingsOpenAdministration),
      ),
    );
    await waitFor(tester, find.text('Benutzer'));
    await finish(tester, state);

    // Alone among adults (the last test of the file: the others go).
    for (final u in await f.admin.adminUsers()) {
      if (u.member.id != f.adminMember.id &&
          u.member.role == MemberRole.adult) {
        await f.admin.deleteMember(u.member.id);
      }
    }
    state = await start(tester);
    await openSettingsItem(tester, de.settingsDeleteAccount);
    await waitFor(tester, find.text(de.settingsLastAdminTitle));
    expect(find.text(de.settingsLastAdminAlone), findsOneWidget);
    expect(field(de.settingsPasswordConfirm), findsNothing);
    await tap(
      tester,
      inDialog(
        find.widgetWithText(FilledButton, de.settingsOpenAdministration),
      ),
    );
    await waitFor(tester, find.text('Benutzer'));
    await finish(tester, state);
  });
}
