import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_client.dart';

/// A `dart:io` client that trusts [pin] in addition to the system's CAs.
HttpClient _ioClient(String? pin) => HttpClient()
  ..connectionTimeout = const Duration(seconds: 10)
  ..badCertificateCallback = (cert, host, port) =>
      pin != null && pin.isNotEmpty && _fingerprint(cert) == pin;

/// `AB:CD:…` SHA-256 fingerprint of the certificate's key, as the server
/// prints it. The key stays when the server renews its certificate.
String _fingerprint(X509Certificate cert) {
  try {
    return formatFingerprint(
      sha256.convert(subjectPublicKeyInfo(cert.der)).bytes,
    );
  } on FormatException {
    return '';
  }
}

http.Client platformHttpClient(String? pin) => IOClient(_ioClient(pin));

WebSocketChannel platformWebSocket(
  Uri url, {
  required Map<String, String> headers,
  String? pin,
  Duration? pingInterval,
}) => IOWebSocketChannel.connect(
  url,
  headers: headers,
  customClient: _ioClient(pin),
  pingInterval: pingInterval,
);

bool isTlsFailure(Object error) => error is HandshakeException;

Future<String?> platformUntrustedCertificate(Uri url) async {
  if (url.scheme != 'https') return null;
  String? seen;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..badCertificateCallback = (cert, host, port) {
      seen = _fingerprint(cert);
      return false;
    };
  try {
    final request = await client.getUrl(url.resolve('api/health'));
    await (await request.close()).drain<void>();
    return null;
  } on HandshakeException {
    if (seen != null) return seen;
    throw const ApiError(0, 'tls', 'Verschlüsselte Verbindung fehlgeschlagen');
  } on SocketException catch (e) {
    throw ApiError(0, 'network', 'Server nicht erreichbar ($e)');
  } on HttpException catch (e) {
    throw ApiError(0, 'network', 'Server nicht erreichbar ($e)');
  } finally {
    client.close(force: true);
  }
}
