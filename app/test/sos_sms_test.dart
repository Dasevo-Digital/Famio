import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/l10n.dart';
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

/// The emergency text without internet: Android sends it, an iPhone opens
/// it ready to send (#605).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('an alarm without internet', () {
    const channel = MethodChannel('famio/sos');
    late List<MethodCall> calls;
    late bool sent;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls = [];
      sent = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'composeSms' || 'sendSms' => sent,
              _ => null,
            };
          });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    SosController offline({bool sms = true}) {
      final engine = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: FamioApiClient(
          'https://famio.test',
          httpClient: MockClient(
            (r) async => throw http.ClientException('offline', r.url),
          ),
        ),
        memberId: 'k1',
      );
      engine.put(
        Collections.sosSettings,
        SosSettings.recordId,
        SosSettings(
          siren: false,
          sms: sms,
          phones: const {'m1': '0151 111', 'm2': '+49 152 222'},
        ).toData(),
      );
      return SosController(engine, device: 'Telefon');
    }

    List<String> methods() => [for (final c in calls) c.method];

    test('an iPhone opens the prepared text', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final sos = offline();
      await sos.trigger(call: false);
      expect(sos.step, SosStep.offline);
      expect(methods(), contains('composeSms'));
      expect(methods(), isNot(contains('sendSms')));
      final args =
          calls.firstWhere((c) => c.method == 'composeSms').arguments as Map;
      expect(args['numbers'], ['0151111', '+49152222']);
      expect(args['text'], startsWith('SOS von Mia (Famio)'));
      expect(sos.smsSent, isTrue);
    });

    test('a cancelled text on the iPhone counts as not sent', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      sent = false;
      final sos = offline();
      await sos.trigger(call: false);
      expect(methods(), contains('composeSms'));
      expect(sos.smsSent, isFalse);
    });

    test('Android still sends on its own', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final sos = offline();
      await sos.trigger(call: false);
      expect(methods(), contains('sendSms'));
      expect(methods(), isNot(contains('composeSms')));
      expect(sos.smsSent, isTrue);
    });

    test('nothing is texted when it is switched off or on a desktop', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await offline(sms: false).trigger(call: false);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await offline().trigger(call: false);
      expect(methods(), isNot(contains('composeSms')));
      expect(methods(), isNot(contains('sendSms')));
    });
  });

  group('the emergency settings', () {
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'tour.offered': true});
      FlutterSecureStorage.setMockInitialValues({});
      final state = AppState();
      await state.init();
      final engine = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: FamioApiClient('localhost:1'),
        memberId: 'm1',
      );
      state
        ..me = engine.members.firstWhere((m) => m.id == 'm1')
        ..engine = engine;
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pump();
      Navigator.of(tester.element(find.byType(Scaffold).first)).push(
        MaterialPageRoute<void>(builder: (_) => const SosSettingsScreen()),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an iPhone explains the text and Apple\'s Emergency SOS', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await open(tester);
        expect(find.text(tr.sosIfPhoneOfflineTextApple), findsOneWidget);
        expect(find.text(tr.sosAppleEmergencySos), findsOneWidget);
        expect(find.textContaining('Android'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Android shows the plain switch', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await open(tester);
        expect(
          find.text(tr.sosTextMessageWithoutInternetShort),
          findsOneWidget,
        );
        expect(find.text(tr.sosIfPhoneOfflineText), findsOneWidget);
        expect(find.text(tr.sosAppleEmergencySos), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
