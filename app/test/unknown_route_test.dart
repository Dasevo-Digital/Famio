// An address the platform hands over as a page (a calendar file opened on
// Android, KAL-095) is dropped: Famio has no named pages.
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('a pushed address is no error and leaves the page as it is', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    expect(navigator.canPop(), isFalse);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        const MethodCall('pushRouteInformation', {
          'location': '/document/raw:/storage/emulated/0/Download/schule.ics',
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Back on the start page alone.
    expect(navigator.canPop(), isFalse);
  });

  test('deep linking is off on Android and iOS', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      RegExp(
        r'android:name="flutter_deeplinking_enabled"\s+android:value="false"',
      ).hasMatch(manifest),
      isTrue,
    );
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(
      RegExp(
        r'<key>FlutterDeepLinkingEnabled</key>\s*<false/>',
      ).hasMatch(plist),
      isTrue,
    );
  });
}
