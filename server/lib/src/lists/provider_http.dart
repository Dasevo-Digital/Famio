import 'dart:async';
import 'dart:io';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// HTTP for Bring! and Microsoft To Do.
///
/// Every attempt has one deadline for connecting, the headers and the whole
/// body; after it the request is aborted, not merely abandoned, so a hanging
/// connection does not linger. Requests that may be sent twice (GET, PUT,
/// DELETE) get one more attempt after a connection failure; a sign-in or a
/// new entry (POST) is never repeated, because the first one may have
/// arrived.
class ProviderHttpClient extends http.BaseClient {
  ProviderHttpClient(
    this._inner, {
    required this.timeout,
    this.retryDelay = const Duration(seconds: 2),
    this.maxResponseBytes = 32 * 1024 * 1024,
  });

  /// A client that gives up connecting after [connectTimeout] (this covers
  /// the name lookup and the TLS handshake).
  static http.Client connecting(Duration connectTimeout) =>
      IOClient(HttpClient()..connectionTimeout = connectTimeout);

  final http.Client _inner;
  final Duration timeout;
  final Duration retryDelay;
  final int maxResponseBytes;

  static const _repeatable = {'GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS'};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    Future<http.StreamedResponse> attempt() => httpTransfer(
      client: _inner,
      method: request.method,
      url: request.url,
      headers: request.headers,
      bodyBytes: body,
      followRedirects: request.followRedirects,
      timeout: timeout,
      consume: (response, stream) async {
        final bytes = await readTransferBytes(
          stream,
          maxBytes: maxResponseBytes,
        );
        return http.StreamedResponse(
          http.ByteStream.fromBytes(bytes),
          response.statusCode,
          contentLength: bytes.length,
          request: request,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
        );
      },
    );
    try {
      return await attempt();
    } on http.ClientException {
      if (!_repeatable.contains(request.method.toUpperCase())) rethrow;
      await Future<void>.delayed(retryDelay);
      return attempt();
    }
  }

  @override
  void close() => _inner.close();
}
