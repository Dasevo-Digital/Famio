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
  FileCache._(this._blobs, this.api, this.tempDir, this.maxBytes);

  /// Opens the cache database at [path] (`:memory:` for tests; in the
  /// browser the cache stays in memory).
  factory FileCache.open(
    String path,
    FamioApiClient api, {
    String? hexKey,
    required String tempDir,
    int maxBytes = defaultMaxBytes,
  }) => FileCache._(
    openBlobBackend(path, hexKey: hexKey),
    api,
    tempDir,
    maxBytes,
  );

  /// Enough for thousands of previews and plenty of documents, little next
  /// to a phone's storage.
  static const defaultMaxBytes = 500 * 1024 * 1024;

  final int maxBytes;

  final BlobBackend _blobs;
  final FamioApiClient api;

  /// Folder where decrypted copies for other apps are written.
  final String tempDir;
  final _pending = <String, Future<Uint8List>>{};
  final _streaming = <String, Future<void>>{};
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
    if (thumb == null && ref.size > FamioApiClient.maxBufferedFileBytes) {
      return Future.error(
        ApiError(413, 'too_large', ClientTexts.transferTooLarge),
      );
    }
    final key = thumb == null ? ref.id : '${ref.id}_t$thumb';
    if (_recent.remove(key) case final data?) {
      _recent[key] = data;
      return Future.value(data);
    }
    final cached = _read(key);
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
    if (ref.size > maxBytes) {
      // A file that cannot remain offline needs only one temporary disk copy.
      return _receive(
        ref,
        (input) => writeTempStream(
          tempDir,
          '${newId()}_${_safe(ref.name)}',
          input,
          ref.size,
        ),
      );
    }
    var stream = _blobs.readStream(ref.id);
    if (stream == null) {
      await (_streaming[ref.id] ??= _download(ref).whenComplete(() {
        if (_current(generation)) _streaming.remove(ref.id);
      }));
      _check(generation);
      stream = _blobs.readStream(ref.id);
    }
    if (stream == null) {
      throw ApiError(0, 'invalid_response', ClientTexts.unexpectedAnswer(200));
    }
    // Trim after the stream has pinned its source; this also permits opening
    // a single file larger than the normal offline cache budget.
    final iterator = StreamIterator(stream);
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
        ref.size,
      );
    } finally {
      await iterator.cancel();
      if (_current(generation)) _blobs.trim(maxBytes);
    }
  }

  Future<void> _download(FileRef ref) => _receive(
    ref,
    (input) => _blobs.writeStream(ref.id, input, expectedBytes: ref.size),
  );

  Future<T> _receive<T>(
    FileRef ref,
    Future<T> Function(Stream<List<int>>) store,
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
    final stored = store(body.stream);
    final transfer = api.downloadFileToSink(
      body.sink,
      ref.id,
      expectedBytes: ref.size,
      cancellation: cancellation,
    );
    try {
      // Observe both failures from the start; a disk error aborts a request
      // even while it is waiting indefinitely for the next body chunk.
      await Future.any<void>([transfer, stored.then<void>((_) {})]);
      await body.close();
      final result = await stored;
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
    Stream<List<int>> verified() async* {
      Digest? copied;
      yield* _digesting(openRead(), (digest) => copied = digest);
      if (copied != uploaded) {
        throw const FormatException('Upload source changed');
      }
    }

    try {
      await putStream(ref, verified());
    } catch (_) {
      // The server already has the file; an optional offline copy may fail.
    }
    return ref;
  }

  Future<void> putStream(FileRef ref, Stream<List<int>> data) async {
    final generation = _generation;
    _check(generation);
    if (ref.size > maxBytes) return;
    await _blobs.writeStream(ref.id, data, expectedBytes: ref.size);
    _check(generation);
    _blobs.trim(maxBytes);
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

  Uint8List? _read(String key) => switch (_blobs.read(key)) {
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
) async* {
  final result = _DigestSink();
  final hash = sha256.startChunkedConversion(result);
  try {
    await for (final chunk in input) {
      hash.add(chunk);
      yield chunk;
    }
  } finally {
    hash.close();
  }
  completed(result.value!);
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest digest) => value = digest;
  @override
  void close() {}
}
