import 'google_login_result.dart';
import 'client_texts.dart';

export 'google_login_result.dart';

/// Google sign-in needs a local callback server – only in the installed
/// apps, not in the web app.
class GoogleLogin {
  GoogleLogin._();

  static const scope = 'https://www.googleapis.com/auth/calendar';

  static Future<GoogleLoginResult> run({
    required String clientId,
    required Future<void> Function(Uri url) open,
    Duration timeout = const Duration(minutes: 5),
    Uri? endpoint,
  }) => throw UnsupportedError(ClientTexts.googleInApp);
}
