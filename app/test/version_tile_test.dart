import 'package:famio/src/screens/settings_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('settings show the app version', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'Famio',
      packageName: 'de.status403.famio',
      version: '0.14.2',
      buildNumber: '19',
      buildSignature: '',
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // Nothing listens there: the server counts as unreachable.
            body: VersionTile(api: FamioApiClient('http://127.0.0.1:9')),
          ),
        ),
      );
      for (
        var i = 0;
        i < 50 && find.textContaining('nicht erreichbar').evaluate().isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    expect(find.text('Famio 0.14.2 (19)'), findsOneWidget);
    expect(find.text('Server nicht erreichbar'), findsOneWidget);
  });
}
