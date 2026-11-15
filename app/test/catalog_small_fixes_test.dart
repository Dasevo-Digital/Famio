import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/deadlines.dart';
import 'package:famio/src/data/web_link.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/deadlines_screen.dart';
import 'package:famio/src/screens/meals_screens.dart';
import 'package:famio/src/screens/security_screens.dart';
import 'package:famio/src/screens/sos_screens.dart';
import 'package:famio/src/sos/sos_controller.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

/// Smaller findings of the test catalogue: the server address, recovery
/// codes, the side rail, deadlines, the emergency button, links and the
/// recipe import (#536, #546, #547).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Future<(AppState, SyncEngine)> signedIn(
    WidgetTester tester, {
    String me = 'm1',
    Size size = const Size(900, 1600),
    Widget? page,
    void Function(SyncEngine engine)? seed,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: me,
    );
    seed?.call(engine);
    state
      ..me = engine.members.firstWhere((m) => m.id == me)
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    if (page != null) {
      Navigator.of(
        tester.element(find.byType(Scaffold).first),
      ).push(MaterialPageRoute<void>(builder: (_) => page));
    }
    await tester.pumpAndSettle();
    return (state, engine);
  }

  testWidgets('GRU-002 "Server ändern" opens the address again', (
    tester,
  ) async {
    // A Famio server on this machine (the test's HTTP is fake otherwise).
    final fake = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = fake);
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      r.response
        ..persistentConnection = false
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'name': 'famio',
            'version': '2.0.53',
            'setupRequired': false,
          }),
        );
      await r.response.close();
    });
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    final address = find.byType(TextFormField).first;
    await tester.enterText(address, '127.0.0.1:${server.port}');
    await tester.tap(find.text(tr.commonConnect));
    for (var i = 0; i < 50 && find.text(tr.commonSignIn).evaluate().isEmpty;) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      i++;
    }
    expect(find.text(tr.commonSignIn), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).enabled,
      isFalse,
    );
    // The pencil takes the tap although the field is disabled.
    await tester.tap(find.byTooltip(tr.connectChangeServer));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).enabled,
      isTrue,
    );
    expect(find.text(tr.commonSignIn), findsNothing);
    expect(find.text(tr.commonConnect), findsOneWidget);
  });

  testWidgets('GRU-023 new recovery codes fit a low window', (tester) async {
    await signedIn(tester, size: const Size(800, 600));
    final context = tester.element(find.byType(Scaffold).first);
    unawaited(
      showNewRecoveryCodes(context, [
        for (var i = 0; i < 10; i++) 'abcd-efgh-$i',
      ]),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final copy = find.text(tr.commonCopy);
    await tester.ensureVisible(copy);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(copy).dy, lessThanOrEqualTo(600));
    expect(find.text(tr.securitySaved), findsOneWidget);
  });

  testWidgets('GRU-092 the side rail at twice the text size', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await signedIn(tester, size: const Size(1366, 768));
    expect(tester.takeException(), isNull);
    expect(find.text('Famio'), findsWidgets);
  });

  testWidgets('ALL-194 soon due deadlines stand out in bold', (tester) async {
    final now = DateTime.now();
    await signedIn(
      tester,
      page: const DeadlinesScreen(),
      seed: (e) => e
        ..saveDeadline(
          Deadline(
            id: 'soon',
            title: 'Bald',
            due: DateUtils.addDaysToDate(now, 3),
            leadDays: 14,
          ),
        )
        ..saveDeadline(
          Deadline(
            id: 'later',
            title: 'Später',
            due: DateUtils.addDaysToDate(now, 200),
            leadDays: 14,
          ),
        ),
    );
    FontWeight? weightOf(String title) {
      final line = find.descendant(
        of: find.ancestor(of: find.text(title), matching: find.byType(Column)),
        matching: find.textContaining('·'),
      );
      return tester.widget<Text>(line.first).style?.fontWeight;
    }

    final body = Theme.of(
      tester.element(find.text('Bald')),
    ).textTheme.bodyMedium!.fontWeight!;
    expect(weightOf('Bald')!.value, greaterThan(body.value));
    expect(weightOf('Später')?.value ?? body.value, body.value);
  });

  testWidgets('SIC-026 the default call names its parent whatever is chosen', (
    tester,
  ) async {
    await signedIn(
      tester,
      page: const SosSettingsScreen(),
      seed: (e) => e.put(
        Collections.sosSettings,
        SosSettings.recordId,
        const SosSettings(
          phones: {'m2': '0151 1234'},
          call: {'k1': SosSettings.emergency},
        ).toData(),
      ),
    );
    // Mia's line under "Wen ruft der Knopf an?" (after the numbers).
    final mia = find
        .ancestor(of: find.text('Mia'), matching: find.byType(ListTile))
        .last;
    final choice = tester.widget<DropdownButton<String>>(
      find.descendant(of: mia, matching: find.byType(DropdownButton<String>)),
    );
    expect(choice.value, SosSettings.emergency);
    // The first entry, "Elternteil (…)", names the one it would call.
    final first = choice.items!.first;
    expect(first.value, '');
    expect((first.child as Text).data, tr.sosParentName('Papa'));
  });

  test('HAU-101 what counts as a web address', () {
    expect(
      webLink('beispiel.de/konto').toString(),
      'https://beispiel.de/konto',
    );
    expect(webLink('  https://x.de/a ').toString(), 'https://x.de/a');
    expect(webLink('http://x.de').toString(), 'http://x.de');
    expect(
      webLink('beispiel.de:8080/k').toString(),
      'https://beispiel.de:8080/k',
    );
    expect(webLink('localhost:3000').toString(), 'https://localhost:3000');
    // A host in the home network without a dot (HAU-101 review).
    expect(webLink('nas:5000/rezept').toString(), 'https://nas:5000/rezept');
    expect(
      webLink('homeassistant:8123').toString(),
      'https://homeassistant:8123',
    );
    expect(webLink('tel:110'), isNull);
    expect(webLink('tel:+49 30 1234'), isNull);
    for (final other in [
      'mailto:x@y',
      'MAILTO:x@y',
      'tel:+4930123',
      'tel:030123',
      'sms:0151',
      'ftp://x.de',
      'https://',
      '',
      '   ',
    ]) {
      expect(webLink(other), isNull, reason: other);
    }
  });

  group('the recipe import (HAU-013, HAU-015)', () {
    Future<void> importing(WidgetTester tester, String address) async {
      await signedIn(tester);
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(showRecipeEditor(context));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.mealsTakeWebsite));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        address,
      );
      await tester.tap(find.text(tr.commonApply));
      await tester.pumpAndSettle();
    }

    String source(WidgetTester tester) => tester
        .widget<TextField>(
          find.widgetWithText(TextField, tr.mealsSourceOptional),
        )
        .controller!
        .text;

    testWidgets('an address without https:// is tried with it', (tester) async {
      // The test's HTTP answers every request with 400: no recipe there.
      await importing(tester, 'e2e.invalid/rezept');
      expect(find.text(tr.mealsNoRecipeWasFound), findsOneWidget);
      // The address stays as the source.
      expect(source(tester), 'https://e2e.invalid/rezept');
    });

    testWidgets('another kind of link is told off', (tester) async {
      await importing(tester, 'mailto:koch@example.com');
      expect(find.text(tr.mealsWebAddressNeeded), findsOneWidget);
      expect(source(tester), isEmpty);
    });
  });

  group('an alarm ended at once (SIC-021)', () {
    const channel = MethodChannel('famio/sos');
    late List<MethodCall> calls;
    late Completer<String> token;
    late List<http.Request> signedOut;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls = [];
      token = Completer();
      signedOut = [];
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'startLive' ? true : null;
          });
      SosController.signOutClient =
          (url, {String? token, String? pinnedCertificate}) => FamioApiClient(
            url,
            token: token,
            httpClient: MockClient((r) async {
              signedOut.add(r);
              return http.Response('{}', 200);
            }),
          );
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      SosController.signOutClient = null;
    });

    SosController controller() {
      final engine = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: FamioApiClient(
          'https://famio.test',
          httpClient: MockClient((r) async {
            final path = r.url.path;
            if (path.endsWith('/api/sos')) {
              return http.Response('{"id":"a1"}', 201);
            }
            if (path.endsWith('/device-token')) {
              return http.Response(
                jsonEncode({'token': await token.future}),
                201,
              );
            }
            return http.Response('{}', 200);
          }),
        ),
        memberId: 'k1',
      );
      engine.put(
        Collections.sosSettings,
        SosSettings.recordId,
        const SosSettings(siren: false, sms: false).toData(),
      );
      return SosController(
        engine,
        serverUrl: 'https://famio.test/',
        device: 'Telefon',
      );
    }

    test('starts no position service after it ended', () async {
      final sos = controller();
      final pressed = sos.trigger(call: false);
      // "Ich bin sicher" while the token for the service is on its way.
      await pumpEventQueue();
      await sos.resolve();
      token.complete('t-late');
      await pressed;
      await pumpEventQueue();
      expect(calls.map((c) => c.method), isNot(contains('startLive')));
      // The unused token is signed out again.
      expect(signedOut.single.url.path, endsWith('/api/auth/logout'));
      expect(signedOut.single.headers['authorization'], 'Bearer t-late');
    });

    test('a running alarm still starts it', () async {
      final sos = controller();
      final pressed = sos.trigger(call: false);
      token.complete('t-1');
      await pressed;
      final start = calls.singleWhere((c) => c.method == 'startLive');
      expect((start.arguments as Map)['token'], 't-1');
      expect(signedOut, isEmpty);
      sos.dispose();
    });
  });
}
