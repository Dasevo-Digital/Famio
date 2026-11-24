import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/location/location_sharing.dart';
import 'package:famio/src/screens/location/pause_dialog.dart';
import 'package:famio/src/screens/security_screens.dart';
import 'package:famio_client/famio_client.dart';
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
    '{"id":"m2","username":"mia","displayName":"Mia","role":"child"}]';

/// What a server answers to the location routes, by path.
typedef _Answer = http.Response Function(String route, String code);

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

final _wrongCode = _json(403, {
  'error': 'wrong_code',
  'message': 'Der Eltern-Code stimmt nicht',
});
final _noCodeYet = _json(409, {
  'error': 'no_code',
  'message': 'Es ist noch kein Eltern-Code festgelegt.',
});
final _secondFactor = _json(403, {
  'error': 'two_factor_required',
  'message': 'Bitte mit dem Code aus der Authenticator-App bestätigen.',
});
final _routeNotFound = http.Response('Route not found', 404);

/// The servers Famio meets: without a parents' code set (now, 2.0.60 and
/// before), with one, and an older one on the two-factor page.
final _servers = <String, _Answer>{
  'no code, new server': (route, code) => route == 'api/location/code'
      ? _json(200, {'ok': true, 'noCode': true})
      : _wrongCode,
  'no code, 2.0.60': (route, code) =>
      route == 'api/location/code' ? _noCodeYet : _wrongCode,
  'no code, before 2.0.60': (route, code) =>
      route == 'api/location/code' ? _routeNotFound : _noCodeYet,
  'two-factor page, before 2.0.60': (route, code) =>
      route == 'api/location/code' ? _routeNotFound : _secondFactor,
  'code set': (route, code) =>
      code == '2468' ? _json(200, {'ok': true}) : _wrongCode,
};

/// Ending sharing on a phone, also by signing out there, asks for the
/// parents' code only when one is needed (#595), and a phone failing to
/// stop says so (#337).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late List<(String, String)> posts;
  late int stopped;
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('famio_sharing_code_');
    AppState.debugSupportDir = dir.path;
  });
  tearDown(() {
    AppState.debugSupportDir = null;
    dir.deleteSync(recursive: true);
  });

  /// This phone shares its location; [failsToStop] as a broken service.
  void phoneShares(WidgetTester tester, {bool failsToStop = false}) {
    stopped = 0;
    LocationSharing.debugSupported = true;
    addTearDown(() => LocationSharing.debugSupported = null);
    const channel = MethodChannel('famio/location');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'status':
          return {'enabled': stopped == 0};
        case 'stop':
          if (failsToStop) {
            throw PlatformException(code: 'error', message: 'stop failed');
          }
          stopped++;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  Future<AppState> open(
    WidgetTester tester,
    _Answer server, {
    Set<String> hidden = const {},
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    posts = [];
    final client = MockClient((r) async {
      final path = r.url.path;
      if (r.method == 'POST' && path.contains('api/location/')) {
        final route = path.substring(path.indexOf('api/location/'));
        final code = (jsonDecode(r.body) as Map)['code'] as String;
        posts.add((route, code));
        return server(route, code);
      }
      // Syncs and everything else: the server is busy.
      return http.Response('{"error":"busy"}', 503);
    });
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1', httpClient: client),
      memberId: 'm2',
    );
    state
      ..me = engine.members.last
      ..engine = engine
      ..hiddenModules = hidden;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    return state;
  }

  BuildContext page(WidgetTester tester) =>
      tester.element(find.byType(Scaffold).first);

  group('without a parents code, signing out asks nothing', () {
    for (final name in [
      'no code, new server',
      'no code, 2.0.60',
      'no code, before 2.0.60',
      'two-factor page, before 2.0.60',
    ]) {
      testWidgets(name, (tester) async {
        phoneShares(tester);
        final state = await open(tester, _servers[name]!);
        expect(await endingSharingNeedsCode(state), isFalse);
        final ended = confirmSharingEnds(page(tester));
        await tester.pumpAndSettle();
        expect(find.text('Standortfreigabe beenden'), findsNothing);
        expect(await ended, isTrue);
        // Asked with an empty code, which never matches a set one.
        expect({for (final p in posts) p.$2}, {''});
      });
    }
  });

  testWidgets('a parents code set: asked, and only the right one ends it', (
    tester,
  ) async {
    phoneShares(tester);
    final state = await open(tester, _servers['code set']!);
    expect(await endingSharingNeedsCode(state), isTrue);
    posts.clear();
    final ended = confirmSharingEnds(page(tester));
    await tester.pumpAndSettle();
    expect(find.text('Standortfreigabe beenden'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Eltern-Code'),
      '1111',
    );
    await tester.tap(find.text('Beenden').last);
    await tester.pumpAndSettle();
    expect(find.text('Der Eltern-Code stimmt nicht'), findsOneWidget);
    expect(stopped, 0);
    await tester.enterText(
      find.widgetWithText(TextField, 'Eltern-Code'),
      '2468',
    );
    await tester.tap(find.text('Beenden').last);
    await tester.pumpAndSettle();
    expect(await ended, isTrue);
    expect(stopped, 1);
    expect([for (final p in posts) p.$2], ['', '1111', '2468']);
  });

  testWidgets('the family switched location sharing off: no code is asked', (
    tester,
  ) async {
    phoneShares(tester);
    final state = await open(
      tester,
      _servers['code set']!,
      hidden: {ServerSettings.locationModule},
    );
    expect(await endingSharingNeedsCode(state), isFalse);
    final ended = confirmSharingEnds(page(tester));
    await tester.pumpAndSettle();
    expect(find.text('Standortfreigabe beenden'), findsNothing);
    expect(await ended, isTrue);
    expect(posts, isEmpty);
  });

  testWidgets('the code removed while the field showed: it ends all the '
      'same', (tester) async {
    phoneShares(tester);
    final state = await open(tester, _servers['no code, 2.0.60']!);
    final ended = showPauseDialog(
      page(tester),
      member: state.me!,
      stopOnThisDevice: true,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Eltern-Code'),
      '2468',
    );
    await tester.tap(find.text('Beenden').last);
    await tester.pumpAndSettle();
    expect(find.text('Standortfreigabe beenden'), findsNothing);
    expect(await ended, isTrue);
    expect(stopped, 1);
  });

  testWidgets('"Beenden" needs no dialog without a code', (tester) async {
    phoneShares(tester);
    await open(tester, _servers['no code, new server']!);
    final ended = endSharingAsking(page(tester));
    await tester.pumpAndSettle();
    expect(find.text('Standortfreigabe beenden'), findsNothing);
    expect(await ended, isTrue);
    expect(stopped, 1);
  });

  testWidgets('a phone failing to stop says so in the dialog (#337)', (
    tester,
  ) async {
    phoneShares(tester, failsToStop: true);
    final state = await open(tester, _servers['code set']!);
    final ended = showPauseDialog(
      page(tester),
      member: state.me!,
      stopOnThisDevice: true,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Eltern-Code'),
      '2468',
    );
    await tester.tap(find.text('Beenden').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Die Standortfreigabe ließ sich auf diesem Handy nicht beenden. '
        'Bitte noch einmal versuchen.',
      ),
      findsOneWidget,
    );
    // Still open for another try.
    expect(find.text('Standortfreigabe beenden'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(await ended, isFalse);
  });

  testWidgets('an older server on the two-factor page: signing out there '
      'works without the code (#595)', (tester) async {
    phoneShares(tester);
    final state = await open(
      tester,
      _servers['two-factor page, before 2.0.60']!,
    );
    final navigator = Navigator.of(page(tester));
    // Pushed as the app shows it while the second factor is missing.
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const TwoFactorGateScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Abmelden'));
    for (var i = 0; i < 50 && state.me != null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text('Standortfreigabe beenden'), findsNothing);
    expect(state.me, isNull);
    expect(stopped, 1, reason: 'signing out ended sharing on the phone');
  });
}
