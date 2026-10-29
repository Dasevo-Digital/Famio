part of 'api_client.dart';

extension _Transfers on FamioApiClient {
  Future<T> _transfer<T>(
    String method,
    Uri url, {
    required Future<T> Function(http.StreamedResponse, Stream<List<int>>)
    consume,
    Map<String, String>? headers,
    String? body,
    List<int>? bodyBytes,
    required Duration timeout,
    TransferCancellation? cancellation,
  }) async {
    try {
      return await httpTransfer(
        client: _http,
        method: method,
        url: url,
        headers: headers ?? authHeaders,
        body: body,
        bodyBytes: bodyBytes,
        timeout: timeout,
        cancellation: cancellation,
        consume: consume,
      );
    } on ApiError {
      rethrow;
    } on TransferTooLarge {
      throw ApiError(413, 'too_large', ClientTexts.transferTooLarge);
    } on TransferCancelled {
      throw ApiError(499, 'cancelled', ClientTexts.transferCancelled);
    } catch (e) {
      if (isTlsFailure(e) ||
          e.toString().contains('CERTIFICATE_VERIFY_FAILED')) {
        throw ApiError(0, 'tls', FamioApiClient.tlsRejected);
      }
      throw ApiError(0, 'network', ClientTexts.unreachable(e));
    }
  }

  Future<http.Response> _bufferedTransfer(
    String method,
    Uri url, {
    Map<String, String>? headers,
    String? body,
    List<int>? bodyBytes,
    required Duration timeout,
    required int maxBytes,
    TransferCancellation? cancellation,
    void Function(int, int?)? onProgress,
  }) => _transfer(
    method,
    url,
    headers: headers,
    body: body,
    bodyBytes: bodyBytes,
    timeout: timeout,
    cancellation: cancellation,
    consume: (response, stream) async {
      if ((response.contentLength ?? 0) > maxBytes) throw TransferTooLarge();
      final bytes = await readTransferBytes(
        stream,
        maxBytes: maxBytes,
        onProgress: (n) => onProgress?.call(n, response.contentLength),
      );
      return http.Response.bytes(
        bytes,
        response.statusCode,
        headers: response.headers,
      );
    },
  );
}

extension _FileTransfers on FamioApiClient {
  Future<FileRef> _uploadFile({
    required List<int> bytes,
    required String name,
    required String mime,
  }) async {
    final response = await _bufferedTransfer(
      'POST',
      baseUrl.resolve('api/files').replace(queryParameters: {'name': name}),
      headers: {...authHeaders, 'content-type': mime},
      bodyBytes: bytes,
      timeout: const Duration(minutes: 5),
      maxBytes: 1024 * 1024,
    );
    return FileRef.fromJson(FamioApiClient._decode(response))!;
  }

  Future<List<int>> _downloadFile(String id, {int? thumb}) async {
    final response = await _bufferedTransfer(
      'GET',
      fileUrl(id, thumb: thumb),
      timeout: const Duration(minutes: 5),
      maxBytes: 128 * 1024 * 1024,
    );
    if (response.statusCode != 200) FamioApiClient._decode(response);
    return response.bodyBytes;
  }

  /// Bounded compatibility path, also used by browsers. Installed apps use
  /// [exportDataToSink] so archives need not fit into memory.
  Future<List<int>> _exportData({
    required String password,
    bool family = false,
    TransferCancellation? cancellation,
    void Function(int, int?)? onProgress,
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    final response = await _bufferedTransfer(
      'POST',
      baseUrl.resolve(family ? 'api/admin/export' : 'api/me/export'),
      headers: {...authHeaders, 'content-type': 'application/json'},
      body: jsonEncode({'password': password}),
      timeout: const Duration(minutes: 10),
      maxBytes: maxBytes,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    if (response.statusCode != 200) FamioApiClient._decode(response);
    return response.bodyBytes;
  }

  Future<void> _exportDataToSink(
    StreamSink<List<int>> sink, {
    required String password,
    bool family = false,
    TransferCancellation? cancellation,
    void Function(int, int?)? onProgress,
    int maxBytes = 16 * 1024 * 1024 * 1024,
  }) async {
    Future<void>? writing;
    try {
      await _transfer<void>(
        'POST',
        baseUrl.resolve(family ? 'api/admin/export' : 'api/me/export'),
        headers: {...authHeaders, 'content-type': 'application/json'},
        body: jsonEncode({'password': password}),
        timeout: const Duration(minutes: 10),
        cancellation: cancellation,
        consume: (response, stream) async {
          if (response.statusCode != 200) {
            FamioApiClient._decode(
              http.Response.bytes(
                await readTransferBytes(stream, maxBytes: 64 * 1024),
                response.statusCode,
              ),
            );
          }
          if ((response.contentLength ?? 0) > maxBytes) {
            throw TransferTooLarge();
          }
          var received = 0;
          Stream<List<int>> bounded() async* {
            await for (final chunk in stream) {
              if (chunk.length > maxBytes - received) throw TransferTooLarge();
              received += chunk.length;
              onProgress?.call(received, response.contentLength);
              yield chunk;
            }
          }

          final failed = Completer<void>();
          final checked = bounded().transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleError:
                  (
                    Object error,
                    StackTrace stack,
                    EventSink<List<int>> output,
                  ) {
                    if (!failed.isCompleted) failed.completeError(error, stack);
                    output.close();
                  },
            ),
          );
          writing = sink.addStream(checked);
          await Future.any<void>([writing!, failed.future]);
        },
      );
    } finally {
      // Leave the caller's sink unbound before it flushes or closes the file.
      await writing?.catchError((Object _) {});
    }
  }
}
