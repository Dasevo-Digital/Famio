import 'dart:async';

import 'package:http/http.dart' as http;

/// A GET to another service (GitHub, Paperless-ngx, PhotoVault) whose body
/// is passed on or saved as it arrives, so it has no deadline as a whole:
/// at most [answer] until the headers, then at most [pause] between two
/// parts of the body. After either the request is aborted, not merely
/// abandoned, and the body ends with a [TimeoutException].
Future<http.StreamedResponse> getStreamed(
  http.Client client,
  Uri url, {
  Map<String, String> headers = const {},
  Duration answer = const Duration(seconds: 30),
  Duration pause = const Duration(minutes: 2),
}) async {
  final abort = Completer<void>();
  void stop() {
    if (!abort.isCompleted) abort.complete();
  }

  final sent = client.send(
    http.AbortableRequest('GET', url, abortTrigger: abort.future)
      ..headers.addAll(headers),
  );
  final http.StreamedResponse response;
  try {
    response = await sent.timeout(answer);
  } on TimeoutException {
    stop();
    // An answer that arrives after all does not keep its connection.
    unawaited(
      sent.then(
        (late) => late.stream.listen((_) {}, onError: (Object _) {}).cancel(),
        onError: (Object _) {},
      ),
    );
    rethrow;
  }
  final body = response.stream.timeout(
    pause,
    onTimeout: (sink) {
      stop();
      sink
        ..addError(TimeoutException('No data from ${url.host}', pause))
        ..close();
    },
  );
  return http.StreamedResponse(
    body,
    response.statusCode,
    contentLength: response.contentLength,
    request: response.request,
    headers: response.headers,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
}
