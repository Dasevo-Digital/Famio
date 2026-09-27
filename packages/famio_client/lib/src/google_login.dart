import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'api_client.dart';

/// What Google's login page hands back; the Famio server exchanges it.
class GoogleLoginResult {
  const GoogleLoginResult({
    required this.code,
    required this.codeVerifier,
    required this.redirectUri,
  });

  final String code;
  final String codeVerifier;
  final String redirectUri;
}

/// Google sign-in for installed apps (OAuth 2.0 with PKCE and a loopback
/// redirect): the browser shows Google's page, which then calls back a
/// short-lived server on 127.0.0.1 in this app.
class GoogleLogin {
  GoogleLogin._();

  static final authEndpoint = Uri.parse(
    'https://accounts.google.com/o/oauth2/v2/auth',
  );
  static const scope = 'https://www.googleapis.com/auth/calendar';

  static Future<GoogleLoginResult> run({
    required String clientId,
    required Future<void> Function(Uri url) open,
    Duration timeout = const Duration(minutes: 5),
    Uri? endpoint,
  }) async {
    final random = Random.secure();
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final verifier = [
      for (var i = 0; i < 64; i++) chars[random.nextInt(chars.length)],
    ].join();
    final state = base64Url
        .encode(List<int>.generate(16, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}/';
    final result = Completer<GoogleLoginResult>();
    // The answer may come while [open] still runs: handled below.
    unawaited(result.future.then((_) {}, onError: (_) {}));
    // Listening before the browser opens, so no answer can be missed.
    final sub = server.listen((request) async {
      final query = request.uri.queryParameters;
      if (query['state'] != state || result.isCompleted) {
        request.response.statusCode = 404;
        await request.response.close();
        return; // e.g. the browser asking for a favicon
      }
      final code = query['code'];
      request.response
        ..headers.contentType = ContentType.html
        ..write(_page(code != null));
      await request.response.close();
      if (code == null) {
        result.completeError(
          ApiError(
            0,
            'google_denied',
            query['error'] == 'access_denied'
                ? 'Anmeldung bei Google abgebrochen'
                : 'Google-Anmeldung fehlgeschlagen (${query['error']})',
          ),
        );
      } else {
        result.complete(
          GoogleLoginResult(
            code: code,
            codeVerifier: verifier,
            redirectUri: redirect,
          ),
        );
      }
    });
    try {
      await open(
        (endpoint ?? authEndpoint).replace(
          queryParameters: {
            'client_id': clientId.trim(),
            'redirect_uri': redirect,
            'response_type': 'code',
            'scope': scope,
            'code_challenge': challenge,
            'code_challenge_method': 'S256',
            // A refresh token, so the server can keep syncing.
            'access_type': 'offline',
            'prompt': 'consent',
            'state': state,
          },
        ),
      );
      return await result.future.timeout(timeout);
    } on TimeoutException {
      throw const ApiError(
        0,
        'google_timeout',
        'Die Google-Anmeldung wurde nicht abgeschlossen',
      );
    } finally {
      await sub.cancel();
      await server.close(force: true);
    }
  }

  static String _page(bool ok) =>
      '<!doctype html><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width">'
      '<body style="font-family:sans-serif;text-align:center;padding:3em">'
      '<h2>${ok ? 'Mit Google verbunden' : 'Nicht verbunden'}</h2>'
      '<p>Du kannst dieses Fenster schließen und zu Famio zurückkehren.</p>';
}
