import 'package:famio_shared/famio_shared.dart';

/// Where [LocalStore] keeps its records: an encrypted SQLite database on
/// devices, memory in the browser (the web app loads everything again on
/// each visit – nothing stays behind in the browser).
abstract class RecordBackend {
  /// All stored records with their dirty flag.
  Iterable<(SyncRecord, bool)> load();

  void put(SyncRecord record, {required bool dirty});

  void markClean(String collection, String id);

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

  void close();
}
