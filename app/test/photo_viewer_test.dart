import 'dart:async';
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/widgets/files.dart';
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

  testWidgets('the viewer shows the preview first, then the original', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    // Two real pictures: the server's preview and the original.
    final preview = File(
      '../docs/screenshots/tasks-mobile.png',
    ).readAsBytesSync();
    final original = File('../docs/screenshots/calendar.png').readAsBytesSync();
    final asked = <String>[];
    final api = FamioApiClient(
      'https://famio.test',
      token: 't',
      httpClient: MockClient((request) async {
        if (!request.url.path.startsWith('/api/files/')) {
          return http.Response('{}', 404);
        }
        final thumb = request.url.queryParameters['thumb'];
        asked.add(thumb ?? 'original');
        return http.Response.bytes(
          thumb == null ? original : preview,
          200,
          headers: {'content-type': 'image/png'},
        );
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
      )
      ..files = FileCache.open(':memory:', api, tempDir: '');
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();

    const photo = FileRef(id: 'f1', name: 'a.png', mime: 'image/png', size: 1);
    unawaited(openFileRef(tester.element(find.byType(Scaffold).first), photo));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(asked, containsAll(['1920', 'original']));
    // The original, decoded at most 4096 pixels on its longest side.
    final shown = find.byWidgetPredicate(
      (w) =>
          w is Image &&
          w.image is ResizeImage &&
          ((w.image as ResizeImage).imageProvider as MemoryImage)
                  .bytes
                  .length ==
              original.length,
    );
    expect(shown, findsOneWidget);
    expect((tester.widget<Image>(shown).image as ResizeImage).width, 4096);
  });
}
