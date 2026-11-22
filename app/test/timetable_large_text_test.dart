import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/timetable_view.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('a timetable with rooms fits at 200 % text on a phone', (
    tester,
  ) async {
    await tester.runAsync(() async {
      Future<void> load(String family, List<String> assets) async {
        final loader = FontLoader(family);
        for (final a in assets) {
          loader.addFont(rootBundle.load(a));
        }
        await loader.load();
      }

      await load('Nunito', [
        for (final w in [400, 600, 700, 800]) 'assets/fonts/Nunito-$w.ttf',
      ]);
      await load('Fredoka', [
        'assets/fonts/Fredoka-500.ttf',
        'assets/fonts/Fredoka-600.ttf',
      ]);
      await load('Lucide', ['assets/fonts/Lucide.ttf']);
    });
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final child = Child(
      id: 'c1',
      name: 'Mia',
      birthDate: DateTime(2018, 5, 4),
      guardianIds: const ['m1'],
    );
    engine
      ..saveChild(child)
      ..saveTimetable(
        Timetable(childId: 'c1')
            .withLesson(1, 0, 'Mathematik', 'Raum 214')
            .withLesson(2, 0, 'Deutsch')
            .withLesson(3, 1, 'Sachunterricht', 'Aula'),
      );
    state
      ..me = const FamilyMember(
        id: 'm1',
        username: 'mama',
        displayName: 'Mama',
        isAdmin: true,
      )
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: TimetableView(child: child)),
          ),
        );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    Finder cell(String text) => find.ancestor(
      of: find.descendant(of: find.byType(Table), matching: find.text(text)),
      matching: find.byType(InkWell),
    );
    expect(cell('Raum 214'), findsOneWidget);
    // The lessons of a row are as tall as each other.
    final room = tester.getSize(cell('Raum 214'));
    final plain = tester.getSize(cell('Deutsch'));
    expect(room.height, greaterThanOrEqualTo(52));
    expect(plain.height, room.height);
    await tester.pump(const Duration(seconds: 1));
  });
}
