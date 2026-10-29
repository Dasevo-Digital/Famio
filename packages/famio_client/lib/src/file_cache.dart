import 'dart:typed_data';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';

import 'api_client.dart';
import 'client_texts.dart';
import 'platform/platform.dart';

/// Keeps downloaded files on the device, so photos and documents opened once
/// are available offline. Files never change (new upload = new id), so a
/// cached copy is always valid.
///
/// The cache is an encrypted database: documents and photos are never
/// stored in plain text, except for a short-lived copy in [tempDir] when a
/// file is handed to another app (PDF viewer …); [clearTemp] removes those.
///
/// It keeps at most [maxBytes]; beyond that the files not shown for the
/// longest time go first (they are downloaded again when needed).
class FileCache {
  FileCache._(
    this._blobs,
    this.api,
    this.tempDir,
    this.maxBytes,
    this.copyTimeout,
  );

  /// Opens the cache database at [path] (`:memory:` for tests; in the
  /// browser the cache stays in memory).
  factory FileCache.open(
    String path,
    FamioApiClient api, {
    String? hexKey,
    required String tempDir,
    int maxBytes = defaultMaxBytes,
    Duration copyTimeout = const Duration(minutes: 2),
  }) => FileCache._(
    openBlobBackend(path, hexKey: hexKey),
    api,
    tempDir,
    maxBytes,
    copyTimeout,
  );

  /// Enough for thousands of previews and plenty of documents, little next
  /// to a phone's storage.
  static const defaultMaxBytes = 500 * 1024 * 1024;

  final int maxBytes;
  final Duration copyTimeout;

  final BlobBackend _blobs;
  final FamioApiClient api;

  /// Folder where decrypted copies for other apps are written.
  final String tempDir;
  final _pending = <String, Future<Uint8List>>{};
  final _streaming = <String, Future<String?>>{};
  final _cancellations = <TransferCancellation>{};
  var _generation = 0;
  var _closed = false;

  bool _current(int generation) => !_closed && generation == _generation;
  ApiError _cancelled() =>
      ApiError(499, 'cancelled', ClientTexts.transferCancelled);
  void _check(int generation) {
    if (!_current(generation)) throw _cancelled();
  }

  /// Recently shown previews, most recent last. Handing out the same bytes
  /// again spares the database read and lets Flutter's image cache reuse
  /// the decoded picture instead of decoding it on every rebuild.
  final _recent = <String, Uint8List>{};
  var _recentBytes = 0;

  /// Upper bound for [_recent].
  static const recentLimit = 16 * 1024 * 1024;

  /// The contents of [ref] (or its [thumb] preview), downloading them once.
  Future<Uint8List> bytes(FileRef ref, {int? thumb}) {
    if (_closed) return Future.error(_cancelled());
    final generation = _generation;
    final key = thumb == null ? ref.id : '${ref.id}_t$thumb';
    if (_recent.remove(key) case final data?) {
      _recent[key] = data;
      return Future.value(data);
    }
    Uint8List? cached;
    try {
      cached = _read(key);
    } on TransferTooLarge {
      return Future.error(
        ApiError(413, 'too_large', ClientTexts.transferTooLarge),
      );
    }
    if (cached != null) return Future.value(_remember(key, cached, thumb));
    return _pending[key] ??= () async {
      try {
        final downloaded = await api.downloadFile(ref.id, thumb: thumb);
        final data = downloaded is Uint8List
            ? downloaded
            : Uint8List.fromList(downloaded);
        _check(generation);
        _write(key, data);
        return _remember(key, data, thumb);
      } finally {
        if (_current(generation)) _pending.remove(key);
      }
    }();
  }

  /// Keeps previews (not whole documents) in [_recent].
  Uint8List _remember(String key, Uint8List data, int? thumb) {
    if (thumb == null || data.length > recentLimit ~/ 8) return data;
    _recent[key] = data;
    _recentBytes += data.length;
    while (_recentBytes > recentLimit) {
      final oldest = _recent.keys.first;
      _recentBytes -= _recent.remove(oldest)!.length;
    }
    return data;
  }

  /// A plain copy of [ref] for opening it with another app; returns its
  /// path (not in the browser).
  Future<String> openable(FileRef ref) async {
    try {
      return await _openable(ref);
    } on ApiError {
      rethrow;
    } catch (_) {
      throw ApiError(0, 'file_storage', ClientTexts.fileStorageFailed);
    }
  }

  Future<String> _openable(FileRef ref) async {
    final generation = _generation;
    _check(generation);
    var stream = _blobs.readStream(ref.id);
    if (stream == null) {
      final path = await (_streaming[ref.id] ??= _download(ref).whenComplete(
        () {
          if (_current(generation)) _streaming.remove(ref.id);
        },
      ));
      _check(generation);
      if (path != null) return path;
      stream = _blobs.readStream(ref.id);
    }
    if (stream == null) {
      throw ApiError(0, 'invalid_response', ClientTexts.unexpectedAnswer(200));
    }
    // Trim after the stream has pinned its source; this also permits opening
    // a single file larger than the normal offline cache budget.
    final iterator = StreamIterator(stream.stream);
    Stream<List<int>> chunks() async* {
      while (await iterator.moveNext()) {
        yield iterator.current;
      }
    }

    try {
      return await writeTempStream(
        tempDir,
        '${newId()}_${_safe(ref.name)}',
        chunks(),
        stream.size,
      );
    } finally {
      await iterator.cancel();
      if (_current(generation)) _blobs.trim(maxBytes);
    }
  }

  Future<String?> _download(FileRef ref) =>
      _receive(ref, (input, length) async {
        // The server's length decides whether this file fits offline, even
        // when an old reference still carries different metadata.
        if (length > maxBytes) {
          return writeTempStream(
            tempDir,
            '${newId()}_${_safe(ref.name)}',
            input,
            length,
          );
        }
        await _blobs.writeStream(ref.id, input, expectedBytes: length);
        return null;
      });

  Future<T> _receive<T>(
    FileRef ref,
    Future<T> Function(Stream<List<int>>, int) store,
  ) async {
    final generation = _generation;
    _check(generation);
    final cancellation = TransferCancellation();
    _cancellations.add(cancellation);
    var listened = false;
    final body = StreamController<List<int>>(
      onListen: () {
        listened = true;
      },
    );
    Future<T>? stored;
    final failed = Completer<void>();
    final transfer = api.downloadFileToSink(
      body.sink,
      ref.id,
      expectedBytes: ref.size.clamp(0, 4096 * 1024 * 1024),
      maxBytes: 4096 * 1024 * 1024,
      onLength: (length) {
        stored = store(body.stream, length);
        stored!.then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            if (!failed.isCompleted) failed.completeError(error, stack);
          },
        );
      },
      cancellation: cancellation,
    );
    try {
      // Observe both failures from the start; a disk error aborts a request
      // even while it is waiting indefinitely for the next body chunk.
      await Future.any<void>([transfer, failed.future]);
      await body.close();
      final result = await stored!;
      _check(generation);
      return result;
    } catch (error, stack) {
      cancellation.cancel();
      // A target can fail before listening (e.g. an unwritable temp folder).
      // Cancel that target stream as well, so its paused addStream can finish.
      if (!listened) {
        await body.stream.listen((_) {}, onError: (Object _) {}).cancel();
      }
      try {
        await transfer;
      } catch (_) {}
      if (!body.isClosed) {
        body.addError(error, stack);
        await body.close();
      }
      try {
        await stored;
      } catch (_) {}
      rethrow;
    } finally {
      cancellation.cancel();
      _cancellations.remove(cancellation);
    }
  }

  /// Deletes plain copies made by [openable].
  void clearTemp() => clearTempFiles(tempDir);

  /// Puts freshly uploaded bytes into the cache, so the uploader never
  /// downloads their own file again.
  void put(FileRef ref, List<int> data) {
    _check(_generation);
    _write(ref.id, data);
  }

  Future<FileRef> uploadBytes({
    required List<int> bytes,
    required String name,
    required String mime,
  }) async {
    final generation = _generation;
    final ref = await api.uploadFile(bytes: bytes, name: name, mime: mime);
    if (_current(generation)) {
      try {
        put(ref, bytes);
      } catch (_) {
        // A cache failure must not discard a successful upload.
      }
    }
    return ref;
  }

  /// Keeps a second read only if it contains exactly the uploaded bytes.
  /// Both hashing passes are streamed; no full-file buffer is retained.
  Future<FileRef> uploadStream({
    required Stream<List<int>> Function() openRead,
    required String name,
    required String mime,
    required int maxBytes,
    int? length,
  }) async {
    final generation = _generation;
    final keep =
        _current(generation) && (length == null || length <= this.maxBytes);
    Digest? uploaded;
    final input = openRead();
    final ref = await api.uploadFileStream(
      stream: keep ? _digesting(input, (digest) => uploaded = digest) : input,
      name: name,
      mime: mime,
      maxBytes: maxBytes,
      length: length,
    );
    if (!keep ||
        !_current(generation) ||
        uploaded == null ||
        ref.size > this.maxBytes) {
      return ref;
    }
    try {
      await putStream(
        ref,
        _digesting(openRead(), (copied) {
          if (copied != uploaded) {
            throw const FormatException('Upload source changed');
          }
        }),
      );
    } catch (_) {
      // The server already has the file; an optional offline copy may fail.
    }
    return ref;
  }

  Future<void> putStream(FileRef ref, Stream<List<int>> data) async {
    final generation = _generation;
    _check(generation);
    if (ref.size > maxBytes) return;
    final cancellation = TransferCancellation();
    _cancellations.add(cancellation);
    final interrupted = Completer<void>();
    StreamSubscription<List<int>>? source;
    Object? failure;
    void cancelSource() {
      final active = source;
      if (active != null) unawaited(active.cancel().catchError((Object _) {}));
    }

    late final StreamController<List<int>> body;
    void stop(Object error) {
      if (failure != null) return;
      failure = error;
      cancellation.cancel();
      if (!interrupted.isCompleted) interrupted.completeError(error);
      cancelSource();
      if (!body.isClosed) {
        body.addError(error);
        unawaited(body.close());
      }
    }

    body = StreamController<List<int>>(
      onListen: () {
        try {
          source = data.listen(
            (chunk) {
              if (failure == null && !body.isClosed) body.add(chunk);
            },
            onError: (Object error, StackTrace stack) {
              if (failure == null && !body.isClosed) {
                body.addError(error, stack);
              }
            },
            onDone: () {
              if (!body.isClosed) unawaited(body.close());
            },
          );
        } catch (error) {
          stop(error);
        }
        if (failure != null) cancelSource();
      },
      onPause: () => source?.pause(),
      onResume: () => source?.resume(),
      onCancel: cancelSource,
    );
    final detach = cancellation.listen(
      () => stop(StateError('Cache copy cancelled')),
    );
    final timer = Timer(
      copyTimeout,
      () => stop(TimeoutException('Offline copy deadline', copyTimeout)),
    );
    try {
      final stored = _blobs.writeStream(
        ref.id,
        body.stream,
        expectedBytes: ref.size,
        cancellation: cancellation,
      );
      await Future.any<void>([stored, interrupted.future]);
      _check(generation);
      _blobs.trim(maxBytes);
    } finally {
      timer.cancel();
      detach();
      cancellation.cancel();
      cancelSource();
      if (!body.isClosed) unawaited(body.close());
      _cancellations.remove(cancellation);
    }
  }

  /// Bytes the cache takes on this device.
  int get size => _blobs.size;

  /// Forgets all files; they are downloaded again when shown.
  void clear() {
    if (_closed) return;
    _generation++;
    for (final cancellation in _cancellations.toList()) {
      cancellation.cancel();
    }
    _recent.clear();
    _recentBytes = 0;
    _pending.clear();
    _streaming.clear();
    _blobs.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _generation++;
    for (final cancellation in _cancellations.toList()) {
      cancellation.cancel();
    }
    _pending.clear();
    _streaming.clear();
    _recent.clear();
    _recentBytes = 0;
    _blobs.close();
  }

  Uint8List? _read(String key) =>
      switch (_blobs.read(key, maxBytes: FamioApiClient.maxBufferedFileBytes)) {
        null => null,
        final Uint8List data => data,
        final data => Uint8List.fromList(data),
      };

  void _write(String key, List<int> data) {
    _blobs.write(key, data);
    _blobs.trim(maxBytes);
  }

  static String _safe(String name) => name.replaceAll(RegExp(r'[^\w.\-]'), '_');
}

Stream<List<int>> _digesting(
  Stream<List<int>> input,
  void Function(Digest) completed,
) {
  final result = _DigestSink();
  final hash = sha256.startChunkedConversion(result);
  // A transformer forwards cancellation directly to the source. An async
  // generator waiting for the next event can defer that cancellation.
  return input.transform(
    StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, output) {
        hash.add(chunk);
        output.add(chunk);
      },
      handleDone: (output) {
        try {
          hash.close();
          completed(result.value!);
        } catch (error, stack) {
          output.addError(error, stack);
        }
        output.close();
      },
    ),
  );
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest digest) => value = digest;
  @override
  void close() {}
}
