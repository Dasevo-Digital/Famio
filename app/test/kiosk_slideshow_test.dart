// The slideshow of the wall display names the day of the next appointment
// when it is not today's.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/kiosk_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  /// The slideshow at [now] with one appointment at [start].
  Future<void> show(WidgetTester tester, DateTime now, DateTime start) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          '[{"id":"m1","username":"mama","displayName":"Mama"}]',
        ),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    state
      ..me = const FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama')
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    engine.saveEvent(
      CalendarEvent(
        id: 'e1',
        title: 'Zahnarzt',
        start: start,
        end: start.add(const Duration(hours: 1)),
      ),
    );
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: PhotoSlideshow(
            photos: const [
              FileRef(id: 'f1', name: 'a.jpg', mime: 'image/jpeg', size: 10),
            ],
            now: now,
            engine: engine,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> end(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(PhotoSlideshow))).pop();
    await tester.pump(const Duration(seconds: 3));
  }

  // Wednesday evening.
  final now = DateTime(2026, 11, 18, 20);

  testWidgets('today: only the time', (tester) async {
    await show(tester, now, DateTime(2026, 11, 18, 21));
    expect(find.text('21:00 Zahnarzt'), findsOneWidget);
    await end(tester);
  });

  testWidgets('tomorrow: "Morgen"', (tester) async {
    await show(tester, now, DateTime(2026, 11, 19, 9));
    expect(find.text('Morgen, 09:00 Zahnarzt'), findsOneWidget);
    await end(tester);
  });

  testWidgets('the day after: the weekday', (tester) async {
    await show(tester, now, DateTime(2026, 11, 20, 9));
    expect(find.text('Freitag, 09:00 Zahnarzt'), findsOneWidget);
    await end(tester);
  });
}
