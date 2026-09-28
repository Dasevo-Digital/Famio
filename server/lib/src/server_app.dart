import 'dart:async';
import 'dart:io';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'accounts.dart';
import 'crypto/tls.dart';
import 'api.dart';
import 'calendar/calendar_access.dart';
import 'calendar/calendar_feeds.dart';
import 'calendar/calendar_importer.dart';
import 'database.dart';
import 'dav/caldav_sync.dart';
import 'dav/google_oauth.dart';
import 'family/allowance_job.dart';
import 'hub.dart';
import 'push/push_service.dart';
import 'location/location_service.dart';
import 'files/file_store.dart';
import 'record_store.dart';
import 'security.dart';
import 'settings.dart';
import 'crypto/encrypted_db.dart';

/// Wires all server components together; used by `bin/server.dart` and tests.
class FamioServerApp {
  FamioServerApp({
    required this.db,
    required tz.Location location,
    required String dataDir,
    String? publicUrl,
    bool ingressAuth = false,
    bool trustProxy = false,
    int maxUploadMb = 100,
    http.Client? httpClient,
    void Function(String line)? auditLog,
    Database? blobs,
    String? dataKey,
    bool keySeparate = false,
    bool requireTls = false,
    int? tlsPort,
    ServerTls? tls,
    Uri? googleBase,
  }) : dataDir = dataDir,
       trustProxy = trustProxy,
       ingressAuth = ingressAuth {
    settings = SettingsStore(
      db,
      defaults: ServerSettings(
        publicUrl: publicUrl,
        timeZone: location.name,
        maxUploadMb: maxUploadMb,
      ),
    );
    accounts = Accounts(db);
    records = RecordStore(
      db,
      memberIds: () => [for (final m in accounts.members()) m.id],
      roleOf: accounts.roleOf,
    );
    calendarAccess = CalendarAccess(
      db,
      records: records,
      memberIds: () => [for (final m in accounts.members()) m.id],
    );
    importer = CalendarImporter(
      records: records,
      access: calendarAccess,
      location: () => settings.location,
      onChanged: () => hub.notifyRev(records.currentRev),
      client: httpClient,
    );
    caldav = CalDavSync(
      db: db,
      records: records,
      access: calendarAccess,
      location: () => settings.location,
      onChanged: () => hub.notifyRev(records.currentRev),
      client: httpClient,
      // Tests replace Google with a fake at [googleBase].
      google: googleBase == null
          ? null
          : GoogleOAuth(
              http.Client(),
              tokenEndpoint: googleBase.resolve('token'),
              calendarList: googleBase.resolve('calendarList'),
              caldavBase: googleBase.resolve('caldav/v2/'),
            ),
    );
    locations = LocationService(
      db: db,
      records: records,
      accounts: accounts,
      onChanged: () => hub.notifyRev(records.currentRev),
    );
    files = FileStore(
      db,
      blobs:
          blobs ?? openEncrypted(p.join(dataDir, 'files.db'), hexKey: dataKey),
      dataDir: dataDir,
      records: records,
      maxBytes: () => settings.maxUploadBytes,
    );
    push = PushService(
      db: db,
      records: records,
      accounts: accounts,
      location: () => settings.location,
      client: httpClient,
    );
    records
      ..onStored = push.stored
      ..onServerStored = push.serverStored;
    allowances = AllowanceJob(
      records: records,
      accounts: accounts,
      location: () => settings.location,
      onChanged: () => hub.notifyRev(records.currentRev),
    );
    // A fresh server over the internet may only be claimed with this code.
    setupCode = accounts.hasUsers ? null : newSetupCode();
    api = FamioApi(
      accounts: accounts,
      records: records,
      hub: hub,
      feeds: CalendarFeeds(db),
      files: files,
      clientAddress: ClientAddress(trustProxy: trustProxy),
      setupCode: setupCode,
      importer: importer,
      settings: settings,
      ingressAuth: ingressAuth,
      trustProxy: trustProxy,
      dbSize: _dbSize,
      compactDatabase: _compact,
      auditLog: auditLog,
      requireTls: requireTls,
      tlsPort: tlsPort,
      tls: tls,
      encryptedAtRest: dataKey != null,
      keySeparate: dataKey != null && keySeparate,
      caldav: caldav,
      calendarAccess: calendarAccess,
      locations: locations,
      push: push,
      onEventsChanged: caldav.eventsChanged,
    );
  }

  /// In-memory server in the Europe/Berlin zone, for tests.
  factory FamioServerApp.inMemory({http.Client? httpClient, Uri? googleBase}) {
    initTimeZones();
    return FamioServerApp(
      db: openFamioDatabase(':memory:'),
      location: tz.getLocation('Europe/Berlin'),
      dataDir: Directory.systemTemp.createTempSync('famio_test_').path,
      httpClient: httpClient,
      googleBase: googleBase,
    );
  }

  /// Loads the embedded time zone database (idempotent).
  static void initTimeZones() {
    if (!_tzReady) tzdata.initializeTimeZones();
    _tzReady = true;
  }

  static var _tzReady = false;

  final Database db;
  final String dataDir;
  final bool trustProxy;
  final bool ingressAuth;
  final hub = ChangeHub();
  late final SettingsStore settings;
  late final Accounts accounts;
  late final RecordStore records;
  late final CalendarAccess calendarAccess;
  late final CalendarImporter importer;
  late final CalDavSync caldav;
  late final LocationService locations;
  late final FileStore files;
  late final PushService push;
  late final AllowanceJob allowances;
  late final String? setupCode;
  Timer? _gc;
  late final FamioApi api;

  /// The family's time zone (may be changed by admins at runtime).
  tz.Location get location => settings.location;

  Handler get handler => api.handler;

  int _dbSize() {
    final pages = db.select('PRAGMA page_count').first.columnAt(0) as int;
    final size = db.select('PRAGMA page_size').first.columnAt(0) as int;
    return pages * size;
  }

  /// Deleted content stays in free pages of the file until it is rebuilt.
  void _compact() {
    db.execute('VACUUM');
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  /// Periodic jobs (calendar import); not started in tests.
  void startBackgroundJobs() {
    importer.start();
    caldav.start();
    allowances.start();
    accounts.deleteExpiredSessions();
    locations.collectGarbage();
    _gc = Timer.periodic(const Duration(hours: 6), (_) {
      files.collectGarbage();
      accounts.deleteExpiredSessions();
      locations.collectGarbage();
    });
  }

  Future<void> close() async {
    _gc?.cancel();
    importer.stop();
    caldav.stop();
    allowances.stop();
    await hub.close();
    files.blobs.close();
    db.close();
  }
}
