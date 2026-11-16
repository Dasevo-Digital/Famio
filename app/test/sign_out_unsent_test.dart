// Changes made on this device and not sent yet are not lost without a word
// when the session ends (#337):
//
// - signing out while the last sync fails asks first (GRU-049);
// - a session ended elsewhere (new password, "Überall abmelden") keeps the
//   account's database; the same account signing in again at the same
//   server sends them, anyone else, a discard or 14 days delete them
//   (GRU-051).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/waiting_changes.dart';
import 'package:famio/src/screens/settings_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true}]';

/// A Famio server on loopback that knows mama (m1) and papa (m2): sessions
/// it can end, a sync that keeps what it gets, and "offline".
class _Server {
  late final HttpServer _http;
  final _tokens = <String, String>{};
  var _next = 0;
  var rev = 0;

  /// Answers every sync with 503.
  var offline = false;

  /// What the devices sent, by member.
  final pushed = <(String, SyncRecord)>[];

  String get url => 'http://127.0.0.1:${_http.port}/';

  static const _accounts = {
    'mama': {'id': 'm1', 'username': 'mama', 'displayName': 'Mama'},
    'papa': {'id': 'm2', 'username': 'papa', 'displayName': 'Papa'},
  };

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen(_handle);
  }

  Future<void> close() => _http.close(force: true);

  /// A new password elsewhere: every session of this server ends.
  void endSessions() => _tokens.clear();

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final response = request.response..headers.contentType = ContentType.json;
    final path = request.uri.path;
    final token = request.headers.value('authorization')?.substring(7);
    final member = _tokens[token];
    void answer(int status, Object json) {
      response
        ..statusCode = status
        ..write(jsonEncode(json));
    }

    if (path.endsWith('api/auth/login')) {
      final username = (jsonDecode(body) as Map)['username'] as String;
      final account = _accounts[username]!;
      final token = 'session-${_next++}';
      _tokens[token] = account['id']!;
      answer(200, {'token': token, 'member': account});
    } else if (member == null) {
      answer(401, {'error': 'unauthorized', 'message': 'Sitzung abgelaufen'});
    } else if (path.endsWith('api/sync')) {
      if (offline) {
        answer(503, {'error': 'unavailable', 'message': 'Nicht erreichbar'});
      } else {
        final request = SyncRequest.fromJson((jsonDecode(body) as Map).cast());
        for (final change in request.changes) {
          pushed.add((member, change));
        }
        answer(200, {
          'rev': ++rev,
          'serverTime': DateTime.now().millisecondsSinceEpoch,
        });
      }
    } else if (path.endsWith('api/members')) {
      answer(200, _accounts.values.toList());
    } else if (path.endsWith('api/auth/logout')) {
      _tokens.remove(token);
      answer(200, {});
    } else {
      answer(404, {'error': 'not_found', 'message': 'Nicht gefunden'});
    }
    await response.close();
  }
}

/// Waits (for real) until [check] holds.
Future<void> _until(String what, bool Function() check) async {
  for (var i = 0; i < 200; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('waited in vain: $what');
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('famio_unsent_');
    AppState.debugSupportDir = dir.path;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() {
    AppState.debugSupportDir = null;
    dir.deleteSync(recursive: true);
  });

  File database(String member) =>
      File('${dir.path}/${WaitingChanges.databaseName(member)}');

  group('signing out from the settings (GRU-049)', () {
    late SyncEngine engine;
    late AppState state;
    final sent = <SyncRecord>[];

    Future<void> open(WidgetTester tester, {required bool online}) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      sent.clear();
      state = AppState();
      await state.init();
      engine = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: FamioApiClient(
          'localhost:1',
          httpClient: MockClient((request) async {
            if (!online) throw http.ClientException('offline');
            if (request.url.path.endsWith('api/sync')) {
              final body = SyncRequest.fromJson(
                (jsonDecode(request.body) as Map).cast(),
              );
              sent.addAll(body.changes);
              return http.Response(
                jsonEncode({'rev': 1, 'serverTime': 0}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('{}', 200);
          }),
        ),
        memberId: 'm1',
      );
      state
        ..me = engine.members.single
        ..engine = engine;
      // The files a sign-out deletes.
      database('m1').writeAsStringSync('');
      File('${dir.path}/files_m1.db').writeAsStringSync('');
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Einstellungen').first);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    }

    final signOutTile = find.widgetWithText(ListTile, 'Abmelden');

    Future<void> tapSignOut(WidgetTester tester) async {
      await tester.ensureVisible(signOutTile);
      await tester.pumpAndSettle();
      await tester.tap(signOutTile);
      await tester.pumpAndSettle();
    }

    Future<void> signedOut(WidgetTester tester) async {
      for (var i = 0; i < 50 && state.me != null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(state.me, isNull);
    }

    testWidgets('offline with a waiting change: asks before signing out', (
      tester,
    ) async {
      await open(tester, online: false);
      engine.put(Collections.tasks, 't1', const {'title': 'Offline gemacht'});
      await tester.pump(const Duration(seconds: 1));

      await tapSignOut(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(
          'Eine Änderung ist noch nicht übertragen. Famio konnte sie gerade '
          'nicht an den Server senden; wenn du dich jetzt abmeldest, geht sie '
          'verloren.',
        ),
        findsOneWidget,
      );
      // Cancelled: still signed in, the change still waits.
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(state.me, isNotNull);
      expect(state.engine, same(engine));
      expect(engine.store.dirty, hasLength(1));
      expect(database('m1').existsSync(), isTrue);

      // Signed out anyway: as before, the device keeps nothing.
      await tapSignOut(tester);
      await tester.tap(find.text('Trotzdem abmelden'));
      await signedOut(tester);
      expect(database('m1').existsSync(), isFalse);
      expect(state.waitingChanges, isNull);
    });

    testWidgets('tapped again while it asks: asked once', (tester) async {
      await open(tester, online: false);
      engine.put(Collections.tasks, 't1', const {'title': 'Offline gemacht'});
      await tester.pump(const Duration(seconds: 1));
      var asked = 0;
      Future<bool> proceed(int unsent) async {
        asked++;
        return false;
      }

      final first = state.signOut(proceed: proceed);
      final second = state.signOut(proceed: proceed);
      await tester.pumpAndSettle();
      expect(await first, isFalse);
      expect(await second, isFalse);
      expect(asked, 1);
      expect(state.me, isNotNull);
    });

    testWidgets('two waiting changes are counted', (tester) async {
      await open(tester, online: false);
      engine.put(Collections.tasks, 't1', const {'title': 'Eins'});
      engine.put(Collections.notes, 'n1', const {'title': 'Zwei'});
      await tester.pump(const Duration(seconds: 1));
      await tapSignOut(tester);
      expect(
        find.textContaining('2 Änderungen sind noch nicht übertragen'),
        findsOneWidget,
      );
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
    });

    testWidgets('online: the last sync sends it, nothing is asked', (
      tester,
    ) async {
      await open(tester, online: true);
      engine.put(Collections.tasks, 't1', const {'title': 'Noch schnell'});
      await tapSignOut(tester);
      await signedOut(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(sent.map((r) => r.id), contains('t1'));
    });

    testWidgets('offline without waiting changes: nothing is asked', (
      tester,
    ) async {
      await open(tester, online: false);
      await tapSignOut(tester);
      await signedOut(tester);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('a session ended elsewhere (GRU-051)', () {
    late _Server server;
    setUp(() async {
      // flutter_test answers every HttpClient with 400; this needs the real
      // loopback connection.
      HttpOverrides.global = null;
      server = _Server();
      await server.start();
    });
    tearDown(() => server.close());

    ResolvedServer at(_Server s) => ResolvedServer(
      s.url,
      const ServerInfo(version: '2.0.54', setupRequired: false),
    );

    /// Signed in as [user], a change made offline, then the session ends
    /// on another device and the next sync hears it.
    Future<AppState> endedWithChange(String user) async {
      final state = AppState();
      await state.init();
      server.offline = true;
      await state.signIn(at(server), user, 'geheim');
      final engine = state.engine!;
      engine.put(Collections.tasks, 't1', const {'title': 'Offline gemacht'});
      await engine.sync();
      expect(engine.store.dirty, hasLength(1));
      server
        ..offline = false
        ..endSessions();
      unawaited(engine.sync());
      await _until('signed out', () => state.me == null);
      await _until('database closed', () => state.engine == null);
      return state;
    }

    test('the same account signs in again: the change is sent', () async {
      final state = await endedWithChange('mama');
      expect(state.notice, 'Deine Sitzung ist abgelaufen. Bitte neu anmelden.');
      expect(database('m1').existsSync(), isTrue);
      expect(File('${dir.path}/files_m1.db').existsSync(), isFalse);
      final waiting = state.waitingChanges!;
      expect((waiting.memberId, waiting.count), ('m1', 1));
      expect(server.pushed, isEmpty);

      // Kept over a restart of the app.
      final again = AppState();
      await again.init();
      expect(again.waitingChanges?.count, 1);

      await again.signIn(at(server), 'mama', 'neues Passwort');
      await _until(
        'the change on the server',
        () => server.pushed.any((p) => p.$1 == 'm1' && p.$2.id == 't1'),
      );
      expect(
        server.pushed.singleWhere((p) => p.$2.id == 't1').$2.data['title'],
        'Offline gemacht',
      );
      expect(again.waitingChanges, isNull);
      expect(
        WaitingChanges.read(await SharedPreferences.getInstance()),
        isNull,
      );
      await again.signOut();
    });

    test('another account signs in: the change is deleted', () async {
      final state = await endedWithChange('mama');
      expect(state.waitingChanges, isNotNull);
      await state.signIn(at(server), 'papa', 'geheim');
      expect(database('m1').existsSync(), isFalse);
      expect(state.waitingChanges, isNull);
      await state.engine!.sync();
      expect(server.pushed.where((p) => p.$2.id == 't1'), isEmpty);
      await state.signOut();
    });

    test('the same account at another server: deleted', () async {
      final state = await endedWithChange('mama');
      final other = _Server();
      await other.start();
      addTearDown(other.close);
      await state.signIn(at(other), 'mama', 'geheim');
      await state.engine!.sync();
      expect(other.pushed.where((p) => p.$2.id == 't1'), isEmpty);
      expect(state.engine!.store.dirty, isEmpty);
      expect(state.waitingChanges, isNull);
      await state.signOut();
    });

    test('discarded on the sign-in page: deleted', () async {
      final state = await endedWithChange('mama');
      await state.discardWaitingChanges();
      expect(database('m1').existsSync(), isFalse);
      expect(state.waitingChanges, isNull);
      expect(
        WaitingChanges.read(await SharedPreferences.getInstance()),
        isNull,
      );
    });

    test('nothing waiting: the database goes as before', () async {
      final state = AppState();
      await state.init();
      await state.signIn(at(server), 'mama', 'geheim');
      await state.engine!.sync();
      expect(database('m1').existsSync(), isTrue);
      server.endSessions();
      unawaited(state.engine!.sync());
      await _until('signed out', () => state.me == null);
      await _until('database closed', () => state.engine == null);
      expect(database('m1').existsSync(), isFalse);
      expect(state.waitingChanges, isNull);
    });
  });

  group('at the start', () {
    Future<WaitingChanges?> startWith(Duration age, {bool file = true}) async {
      final prefs = await SharedPreferences.getInstance();
      await WaitingChanges(
        server: 'https://famio.example/',
        memberId: 'm1',
        username: 'mama',
        count: 2,
        since: DateTime.now().subtract(age),
      ).save(prefs);
      if (file) database('m1').writeAsStringSync('');
      final state = AppState();
      await state.init();
      return state.waitingChanges;
    }

    test('kept for 14 days', () async {
      expect((await startWith(const Duration(days: 13)))?.count, 2);
      expect(database('m1').existsSync(), isTrue);
    });

    test('older: deleted', () async {
      expect(await startWith(const Duration(days: 14, hours: 1)), isNull);
      expect(database('m1').existsSync(), isFalse);
      expect(
        WaitingChanges.read(await SharedPreferences.getInstance()),
        isNull,
      );
    });

    test('its database gone: forgotten', () async {
      expect(await startWith(const Duration(days: 1), file: false), isNull);
      expect(
        WaitingChanges.read(await SharedPreferences.getInstance()),
        isNull,
      );
    });
  });

  testWidgets('the sign-in page tells and offers to discard', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    await WaitingChanges(
      server: 'https://famio.example/',
      memberId: 'm1',
      username: 'mama',
      count: 3,
      since: DateTime.now(),
    ).save(prefs);
    database('m1').writeAsStringSync('');
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();

    const text =
        '3 Änderungen konnten noch nicht übertragen werden. Melde dich mit '
        'demselben Konto wieder an, damit sie gesendet werden. Sie bleiben '
        'höchstens 14 Tage auf diesem Gerät.';
    expect(find.text(text), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Server-Adresse'))
          .controller!
          .text,
      'https://famio.example/',
    );

    await tester.tap(find.text('Verwerfen'));
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    // Not yet: cancelled.
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(state.waitingChanges, isNotNull);

    await tester.tap(find.text('Verwerfen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verwerfen').last);
    await tester.pumpAndSettle();
    expect(state.waitingChanges, isNull);
    expect(database('m1').existsSync(), isFalse);
    expect(find.text(text), findsNothing);
  });
}
