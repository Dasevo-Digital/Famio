import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

// In the browser the page's own server (Home Assistant ingress or the
// Famio server) is reached over the page's connection: the browser checks
// the certificate, and the proxy in front adds the sign-in.

http.Client platformHttpClient(String? pin) => http.Client();

/// Browsers cannot send headers with a WebSocket; the proxy in front of the
/// web app (Home Assistant ingress) signs the connection in.
WebSocketChannel platformWebSocket(
  Uri url, {
  required Map<String, String> headers,
  String? pin,
  Duration? pingInterval,
}) => WebSocketChannel.connect(url);

bool isTlsFailure(Object error) => false;

Future<String?> platformUntrustedCertificate(Uri url) async => null;
