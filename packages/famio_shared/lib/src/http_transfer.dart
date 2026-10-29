import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class TransferCancelled implements Exception {}

class TransferTooLarge implements Exception {}

class _StreamRequest extends http.BaseRequest with http.Abortable {
  _StreamRequest(super.method, super.url, this._body, this.abortTrigger);
  final Stream<List<int>> _body;
  @override
  final Future<void>? abortTrigger;
  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}

/// Cancellation has removable listeners, so completed transfers do not retain
/// their clients or response buffers until the next user action.
class TransferCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get cancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

/// One deadline covers connection, headers and the complete response body.
/// Both the HTTP request and the body subscription are cancelled on failure.
Future<T> httpTransfer<T>({
  required http.Client client,
  required String method,
  required Uri url,
  required Future<T> Function(http.StreamedResponse, Stream<List<int>>) consume,
  Map<String, String> headers = const {},
  String? body,
  List<int>? bodyBytes,
  Stream<List<int>>? bodyStream,
  int? bodyLength,
  bool followRedirects = true,
  Duration timeout = const Duration(seconds: 30),
  TransferCancellation? cancellation,
}) async {
  final abort = Completer<void>();
  final interrupted = Completer<T>();
  StreamSubscription<List<int>>? subscription;
  StreamSubscription<List<int>>? uploadSubscription;
  StreamController<List<int>>? guarded;
  Object? reason;
  void stop(Object error) {
    if (reason != null) return;
    reason = error;
    if (!abort.isCompleted) abort.complete();
    if (!interrupted.isCompleted) interrupted.completeError(error);
    final active = subscription;
    if (active != null) unawaited(active.cancel().catchError((Object _) {}));
    final upload = uploadSubscription;
    if (upload != null) unawaited(upload.cancel().catchError((Object _) {}));
  }

  StreamController<List<int>>? upload;
  if (bodyStream != null) {
    upload = StreamController<List<int>>(
      onListen: () {
        uploadSubscription = bodyStream.listen(
          (bytes) {
            if (reason == null && !upload!.isClosed) upload.add(bytes);
          },
          onError: (Object e, StackTrace s) {
            if (reason == null && !upload!.isClosed) upload.addError(e, s);
          },
          onDone: () => upload!.close(),
        );
      },
      onPause: () => uploadSubscription?.pause(),
      onResume: () => uploadSubscription?.resume(),
      onCancel: () {
        final active = uploadSubscription;
        if (active != null) {
          unawaited(active.cancel().catchError((Object _) {}));
        }
      },
    );
  }
  final http.BaseRequest request =
      (upload == null
            ? http.AbortableRequest(method, url, abortTrigger: abort.future)
            : _StreamRequest(method, url, upload.stream, abort.future))
        ..headers.addAll(headers)
        ..followRedirects = followRedirects;
  if (request is http.Request) {
    if (body != null) request.body = body;
    if (bodyBytes != null) request.bodyBytes = bodyBytes;
  } else {
    request.contentLength = bodyLength;
  }
  final timer = Timer(
    timeout,
    () => stop(TimeoutException('Transfer deadline', timeout)),
  );
  final detach = cancellation?.listen(() => stop(TransferCancelled()));
  final work = () async {
    if (reason != null) throw reason!;
    final response = await client.send(request);
    if (reason != null) {
      await response.stream.listen((_) {}).cancel();
      throw reason!;
    }
    final stream = guarded = StreamController<List<int>>(
      onListen: () {
        subscription = response.stream.listen(
          (bytes) {
            if (reason == null && !guarded!.isClosed) guarded!.add(bytes);
          },
          onError: (Object e, StackTrace s) {
            if (reason == null && !guarded!.isClosed) guarded!.addError(e, s);
          },
          onDone: () => guarded!.close(),
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        final active = subscription;
        if (active != null) {
          unawaited(active.cancel().catchError((Object _) {}));
        }
      },
    );
    try {
      return await consume(response, stream.stream);
    } finally {
      if (subscription == null) {
        // An early header rejection never listens to the guarded stream.
        // Attach and cancel before signalling abort: the native HTTP adapter
        // otherwise leaves an unconsumed response occupying its connection.
        await response.stream.listen((_) {}, onError: (Object _) {}).cancel();
      }
    }
  }();
  try {
    return await Future.any([work, interrupted.future]);
  } finally {
    timer.cancel();
    detach?.call();
    if (!abort.isCompleted) abort.complete();
    final active = subscription;
    if (active != null) unawaited(active.cancel().catchError((Object _) {}));
    if (guarded != null && !guarded!.isClosed) unawaited(guarded!.close());
    final activeUpload = uploadSubscription;
    if (activeUpload != null) {
      unawaited(activeUpload.cancel().catchError((Object _) {}));
    }
    if (upload != null && !upload.isClosed) unawaited(upload.close());
  }
}

Future<Uint8List> readTransferBytes(
  Stream<List<int>> stream, {
  required int maxBytes,
  void Function(int received)? onProgress,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > maxBytes - bytes.length) throw TransferTooLarge();
    bytes.add(chunk);
    onProgress?.call(bytes.length);
  }
  return bytes.takeBytes();
}

Stream<List<int>> limitedTransferStream(
  Stream<List<int>> input, {
  required int maxBytes,
}) async* {
  var count = 0;
  await for (final chunk in input) {
    if (chunk.length > maxBytes - count) throw TransferTooLarge();
    count += chunk.length;
    yield chunk;
  }
}
