import 'dart:convert';

import 'package:famio/src/widgets/update_check.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('versions compare by number, not as text', () {
    expect(compareVersions('1.0.9', '1.0.10'), lessThan(0));
    expect(compareVersions('v1.1.0', '1.0.12'), greaterThan(0));
    expect(compareVersions('1.0.4+39', '1.0.4'), 0);
    expect(compareVersions('1.0', '1.0.1'), lessThan(0));
  });

  test('the newest release is read from the public list', () async {
    final client = MockClient((request) async {
      expect(request.url, releasesUrl);
      return http.Response(
        jsonEncode({
          'tag_name': 'v1.0.5',
          'html_url':
              'https://github.com/Dasevo-Digital/Famio/releases/tag/v1.0.5',
          'published_at': '2026-10-05T10:00:00Z',
        }),
        200,
      );
    });
    final latest = await fetchLatestRelease(client: client);
    expect(latest.version, '1.0.5');
    expect(latest.url.path, endsWith('/v1.0.5'));
    expect(latest.published, DateTime.utc(2026, 10, 5, 10));

    final down = MockClient((_) async => http.Response('', 503));
    expect(fetchLatestRelease(client: down), throwsException);
  });

  // Only the App Store build leaves the app out (App Review 2.3.10). Until
  // #496 every iPhone did, also an own installation from Xcode, which is
  // updated by hand from the releases.
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('outside the App Store the app is compared too '
        '(${platform.name})', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      PackageInfo.setMockInitialValues(
        appName: 'Famio',
        packageName: 'de.status403.famio',
        version: '2.0.50',
        buildNumber: '100',
        buildSignature: '',
      );
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'tag_name': 'v2.0.61',
            'html_url':
                'https://github.com/Dasevo-Digital/Famio/releases/tag/v2.0.61',
          }),
          200,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showUpdateCheck(
                context,
                serverVersion: '2.0.61',
                client: client,
              ),
              child: const Text('start'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Diese App: 2.0.50'), findsOneWidget);
      expect(find.text('Release ansehen'), findsOneWidget);
      // Flutter checks before the tear-down that it is unset again.
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
