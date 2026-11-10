import 'dart:async';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;

/// Waits before the further tries of an urgent notice: an alarm must not
/// get lost to one dropped connection.
const urgentRetries = [Duration(seconds: 10), Duration(seconds: 30)];

/// What a push service answered to one try.
typedef PushAttempt = ({int? status, bool failed});

/// Posts one notice to a push service: one deadline for connection, answer
/// and body; on timeout the request is aborted, not merely abandoned, so a
/// service that hangs does not keep a connection per notice.
Future<PushAttempt> postNotice(
  http.Client client,
  Uri url, {
  required Map<String, String> headers,
  String? body,
  List<int>? bodyBytes,
  Duration timeout = const Duration(seconds: 15),
}) async {
  try {
    final status = await httpTransfer<int>(
      client: client,
      method: 'POST',
      url: url,
      headers: headers,
      body: body,
      bodyBytes: bodyBytes,
      followRedirects: false,
      timeout: timeout,
      // The answer says nothing; it may not hold up the next notice.
      consume: (response, stream) async {
        await stream.drain<void>();
        return response.statusCode;
      },
    );
    return (status: status, failed: false);
  } catch (_) {
    return (status: null, failed: true);
  }
}

/// Whether trying again may help: no answer, too many notices or a
/// failing service; not when the service refused this notice.
bool worthRetrying(PushAttempt attempt) =>
    attempt.failed ||
    attempt.status == 429 ||
    (attempt.status != null && attempt.status! >= 500);

/// Keeps trying [send] for an [urgent] notice after the delays in [retries],
/// until it works, it is not [worthRetrying] or [stopped] completes.
Future<T> withRetries<T>(
  Future<(T, PushAttempt?)> Function() send, {
  required bool urgent,
  required List<Duration> retries,
  required Future<void> stopped,
}) async {
  var done = false;
  unawaited(stopped.then((_) => done = true));
  for (var i = 0; ; i++) {
    final (result, attempt) = await send();
    if (!urgent ||
        attempt == null ||
        !worthRetrying(attempt) ||
        i >= retries.length ||
        done) {
      return result;
    }
    await Future.any([Future<void>.delayed(retries[i]), stopped]);
    if (done) return result;
  }
}
