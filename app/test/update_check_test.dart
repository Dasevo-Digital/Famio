import 'dart:convert';

import 'package:famio/src/widgets/update_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
}
