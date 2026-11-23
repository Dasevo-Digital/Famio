import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/location/pause_dialog.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"mia","displayName":"Mia","role":"child"}]';

/// Ending sharing on a phone (also when signing out there) checks the
/// parents' code but pauses nobody: another phone of the member goes on
/// sharing, and a pause running keeps its end (#587).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late List<(String, Map<String, Object?>)> posts;

  Future<BuildContext> open(
    WidgetTester tester, {
    bool oldServer = false,
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
        posts.add((
          path.substring(path.indexOf('api/location/')),
          (jsonDecode(r.body) as Map).cast<String, Object?>(),
        ));
        if (oldServer && path.endsWith('api/location/code')) {
          return http.Response('Route not found', 404);
        }
      } else {
        // Syncs and everything else: the server is busy.
        return http.Response('{"error":"busy"}', 503);
      }
      return http.Response(
        '{"ok":true}',
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
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
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    return tester.element(find.byType(Scaffold).first);
  }

  Future<bool> enter(
    WidgetTester tester,
    BuildContext context, {
    required bool stop,
  }) async {
    final state = AppScope.read(context);
    final result = showPauseDialog(
      context,
      member: state.me!,
      stopOnThisDevice: stop,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Eltern-Code'),
      '2468',
    );
    await tester.tap(find.text(stop ? 'Beenden' : 'Pausieren').last);
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('ending sharing on the phone pauses nobody', (tester) async {
    final context = await open(tester);
    expect(await enter(tester, context, stop: true), isTrue);
    expect(posts, hasLength(1));
    expect(posts.single.$1, 'api/location/code');
    expect(posts.single.$2, {'code': '2468'});
  });

  testWidgets('an older server checks the code by pausing', (tester) async {
    final context = await open(tester, oldServer: true);
    expect(await enter(tester, context, stop: true), isTrue);
    expect(
      [for (final p in posts) p.$1],
      ['api/location/code', 'api/location/pause'],
    );
  });

  testWidgets('pausing still pauses for the chosen time', (tester) async {
    final context = await open(tester);
    expect(await enter(tester, context, stop: false), isTrue);
    expect(posts.single.$1, 'api/location/pause');
    expect(posts.single.$2['minutes'], 60);
    expect(posts.single.$2['code'], '2468');
  });
}
