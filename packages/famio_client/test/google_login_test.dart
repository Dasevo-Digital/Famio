import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test('google login returns the code via the loopback redirect', () async {
    late Uri asked;
    final result = await GoogleLogin.run(
      clientId: ' client-1 ',
      open: (url) async {
        asked = url;
        // Plays the browser after the user agreed on Google's page.
        final q = url.queryParameters;
        final back = Uri.parse(q['redirect_uri']!);
        await http.get(back.replace(path: '/favicon.ico'));
        await http.get(
          back.replace(queryParameters: {'code': 'abc', 'state': q['state']}),
        );
      },
    );
    final q = asked.queryParameters;
    expect(asked.host, 'accounts.google.com');
    expect(q['client_id'], 'client-1');
    expect(q['access_type'], 'offline');
    expect(q['scope'], GoogleLogin.scope);
    expect(result.code, 'abc');
    expect(result.redirectUri, q['redirect_uri']);
    // PKCE: the challenge is the hashed verifier.
    expect(
      q['code_challenge'],
      base64Url
          .encode(sha256.convert(ascii.encode(result.codeVerifier)).bytes)
          .replaceAll('=', ''),
    );
  });

  test('a denied login is reported', () async {
    expect(
      GoogleLogin.run(
        clientId: 'c',
        open: (url) async {
          final back = Uri.parse(url.queryParameters['redirect_uri']!);
          await http.get(
            back.replace(
              queryParameters: {
                'error': 'access_denied',
                'state': url.queryParameters['state'],
              },
            ),
          );
        },
      ),
      throwsA(
        isA<ApiError>().having(
          (e) => e.message,
          'message',
          contains('abgebrochen'),
        ),
      ),
    );
  });
}
