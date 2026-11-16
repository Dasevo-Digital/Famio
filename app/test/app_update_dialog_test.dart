import 'package:famio/src/l10n.dart';
import 'package:famio/src/widgets/app_update_banner.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The update dialog explains what happens next: on Android (both packages)
/// Android asks to install, on Windows and Linux Famio restarts (GRU-158).
void main() {
  const offer = AppUpdateOffer(
    version: '2.0.54',
    file: 'Famio-2.0.54-android-arm64.apk',
    size: 32 * 1024 * 1024,
    sha256: '00',
    sums: '',
    signature: '',
  );

  Future<String> hint(WidgetTester tester, AppPlatform platform) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppUpdateDialog(context, offer, platform),
            child: const Text('los'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('los'));
    await tester.pumpAndSettle();
    final android = find.text(tr.appUpdateAndroidHint).evaluate().isNotEmpty;
    final restart = find.text(tr.appUpdateRestartHint).evaluate().isNotEmpty;
    await tester.pumpWidget(const SizedBox());
    return android ? 'android' : (restart ? 'restart' : 'none');
  }

  testWidgets('both Android packages name the install step', (tester) async {
    expect(await hint(tester, AppPlatform.androidArm64), 'android');
    expect(await hint(tester, AppPlatform.android), 'android');
  });

  testWidgets('Windows and Linux restart', (tester) async {
    expect(await hint(tester, AppPlatform.windows), 'restart');
    expect(await hint(tester, AppPlatform.linux), 'restart');
  });
}
