import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/admin_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('connections show what is set up and offer "Ändern"', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    final overview = ServerOverview(
      version: '2.0.1',
      startedAt: DateTime(2026, 10, 12),
      settings: const ServerSettings(),
      defaults: const ServerSettings(),
      effective: const ServerSettings(),
    );
    final answers = <String, Object>{
      '/api/admin/users': {'users': <Object>[]},
      '/api/admin/overview': overview.toJson(),
      '/api/admin/sso': {'configured': false},
      '/api/admin/paperless': {
        'connected': true,
        'url': 'https://paperless.example/',
      },
      '/api/admin/photovault': {'connected': false},
      '/api/admin/app-updates': {
        'enabled': true,
        'version': '2.0.1',
        'packages': {'android': 1, 'windows': 2, 'linux': 3},
      },
    };
    final api = FamioApiClient(
      'https://famio.test',
      token: 't',
      httpClient: MockClient((request) async {
        final answer = answers[request.url.path];
        return answer == null
            ? http.Response('{}', 404)
            : http.Response(jsonEncode(answer), 200);
      }),
    );
    const me = FamilyMember(
      id: 'm1',
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    final state = AppState();
    await state.init();
    state
      ..me = me
      ..engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: api,
        memberId: me.id,
      );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AdminScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen').last);
    await tester.pumpAndSettle();
    // The check mark before the state is part of the rich text.
    expect(
      find.textContaining(
        'Eingeschaltet · Bereit für Version 2.0.1: Android, Windows, Linux',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Verbunden mit paperless.example',
        findRichText: true,
      ),
      findsOneWidget,
    );
    Finder button(String tile, String label) => find.descendant(
      of: find.widgetWithText(ListTile, tile),
      matching: find.text(label),
    );
    expect(button('Paperless-ngx', 'Ändern'), findsOneWidget);
    expect(button('App-Updates über den Server', 'Ändern'), findsOneWidget);
    expect(
      button('Single Sign-On (OpenID Connect)', 'Einrichten'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('PhotoVault: sign in with a code, then album and birthdays', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    final overview = ServerOverview(
      version: '2.0.11',
      startedAt: DateTime(2026, 10, 20),
      settings: const ServerSettings(),
      defaults: const ServerSettings(),
      effective: const ServerSettings(),
    );
    final connected = <String, Object?>{
      'connected': true,
      'url': 'https://photos.example',
      'account': 'familie',
      'memories': true,
      'birthdays': false,
      'memberIds': <String>[],
      'lastSync': '2026-10-20T08:00:00Z',
      'libraryCount': 0,
      'skippedBirthdays': [
        {'name': 'Mia', 'birthday': '2019-06-05', 'reason': 'Kind „Mia“'},
      ],
    };
    var info = <String, Object?>{'connected': false};
    final sent = <Map<String, Object?>>[];
    final api = FamioApiClient(
      'https://famio.test',
      token: 't',
      httpClient: MockClient((request) async {
        final body = request.body.isEmpty
            ? const <String, Object?>{}
            : (jsonDecode(request.body) as Map).cast<String, Object?>();
        Object? answer = switch ((request.method, request.url.path)) {
          ('GET', '/api/admin/users') => {'users': <Object>[]},
          ('GET', '/api/admin/overview') => overview.toJson(),
          ('GET', '/api/admin/sso') => {'configured': false},
          ('GET', '/api/admin/paperless') => {'connected': false},
          ('GET', '/api/admin/app-updates') => {'enabled': false},
          ('GET', '/api/admin/photovault') => info,
          ('GET', '/api/admin/photovault/albums') => {
            'albums': [
              {'id': 'al1', 'name': 'Familie', 'count': 2},
            ],
          },
          ('POST', '/api/admin/photovault/connect') =>
            body['vorgang'] == null
                ? {'step': 'totp', 'vorgang': 'v1'}
                : (info = connected),
          ('PUT', '/api/admin/photovault') => () {
            sent.add(body);
            return info = {...connected, ...body};
          }(),
          _ => null,
        };
        return answer == null
            ? http.Response('{}', 404)
            : http.Response.bytes(utf8.encode(jsonEncode(answer)), 200);
      }),
    );
    const me = FamilyMember(
      id: 'm1',
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    final state = AppState();
    await state.init();
    state
      ..me = me
      ..engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: api,
        memberId: me.id,
      );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AdminScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'PhotoVault'),
        matching: find.text('Einrichten'),
      ),
    );
    await tester.pumpAndSettle();

    Finder field(String label) => find.widgetWithText(TextField, label);
    await tester.enterText(
      field('Adresse von PhotoVault'),
      'https://photos.example',
    );
    await tester.enterText(field('PhotoVault-Konto'), 'familie');
    await tester.enterText(field('Passwort'), 'richtig');
    await tester.tap(find.text('Verbinden'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Code aus der Authenticator-App'), '123456');
    await tester.tap(find.text('Bestätigen'));
    await tester.pumpAndSettle();
    expect(
      find.text('Verbunden als familie mit photos.example'),
      findsOneWidget,
    );
    // An account made just for Famio has an empty library of its own.
    expect(
      find.textContaining(
        'Die Bibliothek des PhotoVault-Kontos „familie“ ist leer',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Keine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Familie (2)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Geburtstage aus dem Stammbaum übernehmen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Kind „Mia“'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Speichern'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (
        sent.single['albumId'],
        sent.single['birthdays'],
        sent.single['memories'],
      ),
      ('al1', true, true),
    );

    // Random photos of the whole timeline instead of the album.
    await tester.tap(find.text('Familie (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Zufällig aus dem ganzen').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Speichern'),
      ),
    );
    await tester.pumpAndSettle();
    expect((sent.last['albumId'], sent.last['timeline']), ('', true));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Paperless-ngx: tag, date field and who sees the documents', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    final overview = ServerOverview(
      version: '2.0.27',
      startedAt: DateTime(2026, 10, 31),
      settings: const ServerSettings(),
      defaults: const ServerSettings(),
      effective: const ServerSettings(),
    );
    var info = <String, Object?>{'connected': false};
    final sent = <Map<String, Object?>>[];
    final api = FamioApiClient(
      'https://famio.test',
      token: 't',
      httpClient: MockClient((request) async {
        final body = request.body.isEmpty
            ? const <String, Object?>{}
            : (jsonDecode(request.body) as Map).cast<String, Object?>();
        Object? answer = switch ((request.method, request.url.path)) {
          ('GET', '/api/admin/users') => {'users': <Object>[]},
          ('GET', '/api/admin/overview') => overview.toJson(),
          ('GET', '/api/admin/sso') => {'configured': false},
          ('GET', '/api/admin/app-updates') => {'enabled': false},
          ('GET', '/api/admin/photovault') => {'connected': false},
          ('GET', '/api/admin/paperless') => info,
          ('PUT', '/api/admin/paperless') => () {
            sent.add(body);
            return info = {
              'connected': true,
              'url': body['url'],
              'tag': body['tag'],
              'memberIds': body['memberIds'],
              'dueField': body['dueField'],
              'count': 3,
              'lastSync': '2026-10-31T08:00:00Z',
            };
          }(),
          _ => null,
        };
        return answer == null
            ? http.Response('{}', 404)
            : http.Response.bytes(utf8.encode(jsonEncode(answer)), 200);
      }),
    );
    const me = FamilyMember(
      id: 'm1',
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    final state = AppState();
    await state.init();
    state
      ..me = me
      ..engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: api,
        memberId: me.id,
      );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AdminScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Paperless-ngx'),
        matching: find.text('Einrichten'),
      ),
    );
    await tester.pumpAndSettle();

    Finder field(String label) => find.widgetWithText(TextField, label);
    await tester.enterText(
      field('Adresse (z. B. http://192.168.1.20:8000)'),
      'http://192.168.1.20:8000',
    );
    await tester.enterText(field('Token eines Paperless-ngx-Benutzers'), 'abc');
    await tester.enterText(
      field('Datumsfeld für die Ablauf-Erinnerung (optional)'),
      ' Ablaufdatum ',
    );
    await tester.tap(find.text('Verbinden'));
    await tester.pumpAndSettle();
    expect(
      (
        sent.single['url'],
        sent.single['token'],
        sent.single['tag'],
        sent.single['dueField'],
      ),
      ('http://192.168.1.20:8000', 'abc', 'Familie', 'Ablaufdatum'),
    );
    expect(find.text('Paperless-ngx verbunden'), findsOneWidget);
    expect(find.textContaining('3 Dokumente, abgeglichen'), findsOneWidget);
    // Saved: the token stays unless a new one is typed.
    expect(
      find.text('Token gespeichert – leer lassen, um es zu behalten'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });
}
