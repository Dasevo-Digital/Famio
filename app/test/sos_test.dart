import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/sos/sos_controller.dart';
import 'package:famio/src/sos/sos_device.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  Future<void> open(WidgetTester tester, String memberId) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: memberId,
    );
    state
      ..me = engine.members.firstWhere((m) => m.id == memberId)
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
  }

  testWidgets('a child holds the button for three seconds', (tester) async {
    await open(tester, 'k1');
    expect(find.text('Notfall?'), findsOneWidget);
    final button = find.text('SOS');

    // A short tap only explains.
    await tester.tap(button);
    await tester.pump();
    expect(
      find.text('Für einen Notruf 3 Sekunden gedrückt halten'),
      findsOneWidget,
    );
    expect(find.text('Ich bin sicher – Alarm beenden'), findsNothing);

    final hold = await tester.startGesture(tester.getCenter(button));
    // The animation starts with the next frame.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2, milliseconds: 100));
    await hold.up();
    await tester.pumpAndSettle();

    expect(find.text('Ich bin sicher – Alarm beenden'), findsOneWidget);
    // No server in tests: the screen says so and offers the call instead.
    expect(
      find.textContaining(RegExp('Kein Internet|nicht gesendet')),
      findsOneWidget,
    );

    await tester.tap(find.text('Ich bin sicher – Alarm beenden'));
    await tester.pumpAndSettle();
    expect(find.text('Ich bin sicher – Alarm beenden'), findsNothing);
    expect(SosController.current, isNull);
  });

  testWidgets('adults see the alarm and can answer', (tester) async {
    await open(tester, 'm1');
    engine.put(Collections.sosAlerts, 'a1', {
      ...SosAlert(
        id: 'a1',
        memberId: 'k1',
        startedAt: DateTime.now(),
        latitude: 53.55,
        longitude: 10,
        accuracy: 12,
        battery: 30,
      ).toData(),
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('SOS von Mia'), findsOneWidget);
    await tester.tap(find.text('SOS von Mia'));
    await tester.pumpAndSettle();
    expect(find.text('Noch niemand hat reagiert.'), findsOneWidget);
    expect(find.text('Ich komme'), findsOneWidget);
    expect(find.textContaining('Akku 30 %'), findsOneWidget);
  });

  test('the text without internet and the siren sound', () {
    expect(
      SosController.smsText(
        'Mia',
        const SosFix(latitude: 53.55, longitude: 10),
      ),
      'SOS von Mia (Famio): Ich brauche Hilfe! Standort: '
      'https://www.openstreetmap.org/?mlat=53.550000&mlon=10.000000',
    );
    expect(SosController.smsText('Mia', null), endsWith('Standort unbekannt.'));
    final wav = SosDevice.sirenWav();
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(wav.length, 44 + 22050 * 2);
  });
}
