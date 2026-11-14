import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/widgets/open_in_maps.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// The first start (#498): what someone gets who types a server address,
/// and the map links of an emergency (#499).
void main() {
  tearDown(() => useLanguage('de'));

  group('the server address', () {
    test('without a host is no address', () {
      for (final input in ['', '   ', 'https://', 'http://', 'https:///']) {
        expect(
          () => FamioApiClient.normalizeUrl(input),
          throwsFormatException,
          reason: input,
        );
      }
    });

    test('a name on the internet is tried with HTTPS', () async {
      // The real resolver, not the test's fake HTTP.
      final fake = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = fake);
      // Reserved: never resolves, so nothing leaves this machine.
      for (final input in ['demo.famio.invalid', 'Demo.Famio.invalid/']) {
        await expectLater(
          AppState().resolveServer(input, trust: (_) async => false),
          throwsA(
            isA<ApiError>()
                .having((e) => e.code, 'code', 'network')
                .having(
                  (e) => e.message,
                  'message',
                  contains('Adresse wurde nicht gefunden'),
                ),
          ),
          reason: input,
        );
      }
      // Plain HTTP typed on purpose stays refused.
      await expectLater(
        AppState().resolveServer(
          'http://demo.famio.invalid',
          trust: (_) async => false,
        ),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'insecure')),
      );
    });

    test('the usual failures say what to check', () {
      expect(
        ClientTexts.unreachable(
          const SocketException(
            "Failed host lookup: 'famio.local' (OS Error: nodename nor "
            'servname provided, or not known, errno = 8)',
          ),
        ),
        'Server nicht erreichbar: Die Adresse wurde nicht gefunden. Ist sie '
        'richtig geschrieben?',
      );
      expect(
        ClientTexts.unreachable(
          const SocketException(
            'Connection refused (OS Error: Connection refused, errno = 61)',
          ),
        ),
        contains('antwortet kein Famio-Server'),
      );
      expect(
        ClientTexts.unreachable('TimeoutException after 0:00:20.000000'),
        contains('im richtigen Netz'),
      );
      useLanguage('en');
      expect(
        ClientTexts.unreachable(const SocketException('Connection refused')),
        'Server not reachable: No Famio server answers at this address.',
      );
      // Anything else keeps its technical reason.
      expect(ClientTexts.unreachable('odd'), contains('(odd)'));
    });

    testWidgets('"https://" alone is told off, not thrown', (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final state = AppState();
      await state.init();
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'https://');
      await tester.showKeyboard(find.byType(TextFormField).first);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(tr.settingsInvalidServerAddress), findsOneWidget);
    });
  });

  group('an emergency position', () {
    test('opens in the map app of the device', () {
      expect(
        mapUri(52.5, 13.4, platform: TargetPlatform.iOS).toString(),
        'https://maps.apple.com/?ll=52.500000%2C13.400000'
        '&q=52.500000%2C13.400000',
      );
      expect(
        mapUri(52.5, 13.4, platform: TargetPlatform.android).toString(),
        'geo:52.500000,13.400000?q=52.500000,13.400000',
      );
      expect(
        mapUri(52.5, 13.4, platform: TargetPlatform.linux).host,
        'www.openstreetmap.org',
      );
    });

    test('and in the browser when no app takes it', () async {
      for (final answer in [false, null]) {
        final opened = <Uri>[];
        await openInMaps(
          52.5,
          13.4,
          launch: (url, {mode = LaunchMode.platformDefault}) async {
            opened.add(url);
            if (opened.length == 1 && answer == null) {
              throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
            }
            return opened.length > 1 || answer!;
          },
        );
        expect(opened.last.host, 'www.openstreetmap.org', reason: '$answer');
        expect(opened, hasLength(2));
      }
    });
  });
}
