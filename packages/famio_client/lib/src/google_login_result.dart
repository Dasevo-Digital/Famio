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
