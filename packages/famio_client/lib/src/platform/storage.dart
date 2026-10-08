import 'package:famio_shared/famio_shared.dart';

/// Where [LocalStore] keeps its records: an encrypted SQLite database on
/// devices, memory in the browser (the web app loads everything again on
/// each visit – nothing stays behind in the browser).
abstract class RecordBackend {
  /// All stored records with their dirty flag.
  Iterable<(SyncRecord, bool)> load();

  void put(SyncRecord record, {required bool dirty});

  void markClean(String collection, String id);

  void remove(String collection, String id);

  /// Removes deletions the server already knows about.
  void removeCleanDeleted();

  void begin();

  void commit();

  void rollback();

  String? getMeta(String key);

  void setMeta(String key, String? value);

  void close();
}

/// Where [FileCache] keeps downloaded files.
abstract class BlobBackend {
  List<int>? read(String key);

  void write(String key, List<int> data);

  /// Bytes stored.
  int get size;

  /// Drops the least recently used files until at most [maxBytes] remain.
  void trim(int maxBytes);

  /// Drops everything.
  void clear();

  void close();
}
