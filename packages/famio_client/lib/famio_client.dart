/// Famio client core: API client, offline store and sync engine.
///
/// Pure Dart so it can be tested end-to-end against the real server.
library;

export 'package:famio_shared/famio_shared.dart';

export 'src/api_client.dart';
export 'src/client_texts.dart';
export 'src/file_cache.dart';
export 'src/google_login.dart'
    if (dart.library.js_interop) 'src/google_login_web.dart';
export 'src/local_store.dart';
export 'src/reminders.dart';
export 'src/sync_engine.dart';
export 'src/encrypted_db.dart'
    if (dart.library.js_interop) 'src/encrypted_db_web.dart';
