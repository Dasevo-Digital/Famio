import 'dart:async';
import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
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

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('"Das war ich nicht" signs out a new sign-in and asks for a '
      'new password', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    final now = DateTime.now();
    final sessions = {
      'this': {
        'id': 'this',
        'device': 'macos (Familien-MacBook)',
        'createdAt': now.subtract(const Duration(days: 90)),
        'current': true,
      },
      'new': {
        'id': 'new',
        'device': 'android (Pixel)',
        'createdAt': now.subtract(const Duration(hours: 1)),
      },
      'old': {
        'id': 'old',
        'device': 'windows (Küchen-PC)',
        'createdAt': now.subtract(const Duration(days: 30)),
      },
    };
    final deleted = <String>[];
    final api = FamioApiClient(
      'localhost:1',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/api/me/sessions') {
          return http.Response(
            jsonEncode({
              'sessions': [
                for (final s in sessions.values)
                  {
                    ...s,
                    'createdAt':
                        (s['createdAt']! as DateTime).millisecondsSinceEpoch,
                    'lastSeen': now.millisecondsSinceEpoch,
                  },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'DELETE' &&
            path.startsWith('/api/me/sessions/')) {
          final id = path.split('/').last;
          deleted.add(id);
          sessions.remove(id);
          return http.Response('{}', 200);
        }
        return http.Response('{"error":"not_found"}', 404);
      }),
    );
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: api,
      memberId: 'm1',
    );
    state
      ..me = engine.members.single
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const MyDevicesScreen())),
    );
    await tester.pumpAndSettle();

    // Only the sign-in of the last days offers it, not this device and
    // not the one from a month ago.
    expect(find.text('Das war ich nicht'), findsOneWidget);
    expect(find.textContaining('neu angemeldet'), findsOneWidget);

    await tester.tap(find.text('Das war ich nicht'));
    await tester.pumpAndSettle();
    expect(find.text('Unbekannte Anmeldung'), findsOneWidget);
    expect(find.textContaining('Android · Pixel wird abgemeldet'), findsOne);
    await tester.tap(find.widgetWithText(FilledButton, 'Abmelden'));
    await tester.pumpAndSettle();

    expect(deleted, ['new']);
    expect(find.text('Android · Pixel ist abgemeldet.'), findsOneWidget);
    // Straight on to a new password, which signs out the rest as well.
    expect(find.text('Passwort ändern'), findsOneWidget);
    await tester.tap(find.text('Abbrechen').last);
    await tester.pumpAndSettle();
    expect(find.text('Das war ich nicht'), findsNothing);
    expect(find.textContaining('Küchen-PC'), findsOneWidget);

    await engine.dispose();
  });

  group("a phone's location sharing (#594)", () {
    /// "id body" of each sign-out.
    late List<String> deleted;

    /// "Meine Geräte" with this computer and a phone's location sharing;
    /// [code] the family's parents' code, if any.
    Future<SyncEngine> open(WidgetTester tester, {String? code}) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final now = DateTime.now();
      final sessions = {
        'this': {
          'id': 'this',
          'device': 'macos (Familien-MacBook)',
          'current': true,
        },
        'loc': {
          'id': 'loc',
          // As the server names it.
          'device': 'android (Pixel) · Standort',
          'location': true,
        },
      };
      deleted = [];
      final api = FamioApiClient(
        'localhost:1',
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path == '/api/me/sessions') {
            return http.Response(
              jsonEncode({
                'sessions': [
                  for (final s in sessions.values)
                    {
                      ...s,
                      'createdAt': now
                          .subtract(const Duration(days: 30))
                          .millisecondsSinceEpoch,
                      'lastSeen': now.millisecondsSinceEpoch,
                    },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'DELETE' &&
              path.startsWith('/api/me/sessions/')) {
            final id = path.split('/').last;
            final body = request.body.isEmpty
                ? <String, Object?>{}
                : (jsonDecode(request.body) as Map).cast<String, Object?>();
            deleted.add('$id ${jsonEncode(body)}');
            if (code != null &&
                sessions[id]?['location'] == true &&
                body['code'] != code) {
              return http.Response(
                jsonEncode({
                  'error': 'wrong_code',
                  'message': 'Der Eltern-Code stimmt nicht',
                }),
                403,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            sessions.remove(id);
            return http.Response('{}', 200);
          }
          return http.Response('{"error":"not_found"}', 404);
        }),
      );
      final state = AppState();
      await state.init();
      final engine = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: api,
        memberId: 'm1',
      );
      state
        ..me = engine.members.single
        ..engine = engine;
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const MyDevicesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      // Recognisable as such.
      expect(find.text('Android · Pixel · Standort'), findsOneWidget);
      expect(find.textContaining('Nur Standortfreigabe'), findsOneWidget);
      return engine;
    }

    final inDialog = find.byType(AlertDialog);

    testWidgets('signing it out asks for the parents code, a wrong one '
        'shows why', (tester) async {
      final engine = await open(tester, code: '2468');
      await tester.tap(find.byTooltip('Abmelden'));
      await tester.pumpAndSettle();
      expect(find.text('Standortfreigabe beenden'), findsOneWidget);
      expect(
        find.text(
          'Danach teilt Android · Pixel · Standort keinen Standort mehr. '
          'Dafür braucht es den Eltern-Code.',
        ),
        findsOneWidget,
      );
      final signOut = find.descendant(
        of: inDialog,
        matching: find.text('Abmelden'),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Eltern-Code'),
        '1111',
      );
      await tester.tap(signOut);
      await tester.pumpAndSettle();
      expect(find.text('Der Eltern-Code stimmt nicht'), findsOneWidget);
      expect(inDialog, findsOneWidget, reason: 'another try');

      await tester.enterText(
        find.widgetWithText(TextField, 'Eltern-Code'),
        '2468',
      );
      await tester.tap(signOut);
      await tester.pumpAndSettle();
      expect(inDialog, findsNothing);
      expect(find.text('Android · Pixel · Standort'), findsNothing);
      // First without: a family without a code is not asked for one.
      expect(deleted, ['loc {}', 'loc {"code":"1111"}', 'loc {"code":"2468"}']);
      await engine.dispose();
    });

    testWidgets('without a parents code set it is signed out at once', (
      tester,
    ) async {
      final engine = await open(tester);
      await tester.tap(find.byTooltip('Abmelden'));
      await tester.pumpAndSettle();
      expect(inDialog, findsNothing);
      expect(find.text('Android · Pixel · Standort'), findsNothing);
      expect(deleted, ['loc {}']);
      await engine.dispose();
    });
  });
}
