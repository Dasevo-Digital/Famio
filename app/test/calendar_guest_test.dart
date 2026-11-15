// What the calendar offers a guest: reading and commenting, no editor and
// no connected calendars (KAL-050, KAL-121).
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
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

  late SyncEngine engine;
  late List<String> requests;

  Future<void> openCalendar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tips.off': true});
    FlutterSecureStorage.setMockInitialValues({});
    requests = [];
    final client = MockClient((r) async {
      requests.add(r.url.path);
      return http.Response('{}', 500);
    });
    const me = FamilyMember(
      id: 'g1',
      username: 'oma',
      displayName: 'Oma',
      role: MemberRole.guest,
    );
    final state = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          '[{"id":"g1","username":"oma","displayName":"Oma","role":"guest"},'
              '{"id":"m1","username":"mama","displayName":"Mama"}]',
        ),
      api: FamioApiClient('localhost:1', httpClient: client),
      memberId: me.id,
    );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.tap(find.text('Kalender').first);
    await tester.pumpAndSettle();
  }

  testWidgets('a guest reads and comments, but enters and changes nothing', (
    tester,
  ) async {
    await openCalendar(tester);
    final today = DateUtils.dateOnly(DateTime.now());
    engine.saveEvent(
      CalendarEvent(
        id: 'e1',
        title: 'Sommerfest',
        start: today.add(const Duration(hours: 15)),
        end: today.add(const Duration(hours: 17)),
        location: 'Kita',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Neuer Termin'), findsNothing);
    expect(
      find.byTooltip('Termine aus Foto, Text oder Kalenderdatei'),
      findsNothing,
    );

    await tester.tap(find.text('Sommerfest').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Als Gast kannst du Termine ansehen und kommentieren, aber nicht '
        'ändern.',
      ),
      findsOneWidget,
    );
    expect(find.text('Kita'), findsWidgets);
    expect(find.text('Speichern'), findsNothing);
    expect(find.text('Termin löschen'), findsNothing);
    // Comments are a guest's to write.
    await tester.enterText(find.byType(TextField).last, 'Ich bringe Kuchen');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(
      engine.eventComments('e1').map((c) => c.text),
      contains('Ich bringe Kuchen'),
    );
    expect(engine.event('e1')!.title, 'Sommerfest');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('connected calendars and subscriptions say they are not for '
      'guests', (tester) async {
    await openCalendar(tester);
    await tester.tap(find.byTooltip('Mit Google/Apple Kalender verbinden'));
    await tester.pumpAndSettle();
    const hint =
        'Verbundene Kalender und Kalender-Abos sind für Gäste nicht '
        'verfügbar.';
    await tester.scrollUntilVisible(find.text(hint).last, 300);
    await tester.pumpAndSettle();
    expect(find.text(hint), findsNWidgets(2));
    expect(find.text('Kalender abonnieren'), findsNothing);
    // The server refuses guests: not asked at all, no "Nur mit Verbindung".
    expect(requests.where((p) => p.endsWith('calendar/caldav')), isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });
}
