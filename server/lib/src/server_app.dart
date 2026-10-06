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
import 'web_app.dart';
import 'auth/mfa.dart';
import 'auth/sso.dart';
import 'calendar/calendar_access.dart';
import 'calendar/calendar_feeds.dart';
import 'calendar/calendar_importer.dart';
import 'database.dart';
import 'dav/caldav_sync.dart';
import 'export/data_export.dart';
import 'lists/list_sync.dart';
import 'dav/google_oauth.dart';
import 'family/invites.dart';
import 'family/sos.dart';
import 'family/allowance_job.dart';
import 'hub.dart';
import 'push/notice_box.dart';
import 'push/push_service.dart';
import 'location/location_service.dart';
import 'files/file_store.dart';
import 'record_store.dart';
import 'security.dart';
import 'settings.dart';
import 'crypto/encrypted_db.dart';
import 'remote_url_policy.dart';

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
    int locationHistoryDays = 7,
    int maxStorageMb = 5120,
    bool allowPrivateCalendarHosts = false,
    bool allowPrivatePushHosts = false,
    http.Client? httpClient,
    void Function(String line)? auditLog,
    Database? blobs,
    String? dataKey,
    bool keySeparate = false,
    bool requireTls = false,
    int? tlsPort,
    ServerTls? tls,
    Uri? googleBase,
    WebApp? webApp,
  }) : dataDir = dataDir,
       trustProxy = trustProxy,
       ingressAuth = ingressAuth {
    settings = SettingsStore(
      db,
      defaults: ServerSettings(
        publicUrl: publicUrl,
        timeZone: location.name,
        maxUploadMb: maxUploadMb,
        locationHistoryDays: locationHistoryDays,
      ),
    );
    accounts = Accounts(db);
    records = RecordStore(
      db,
      memberIds: () => [for (final m in accounts.members()) m.id],
      roleOf: accounts.roleOf,
      accessOf: accounts.accessOf,
    );
    calendarAccess = CalendarAccess(
      db,
      records: records,
      memberIds: () => [for (final m in accounts.members()) m.id],
    );
    final remoteUrlPolicy = RemoteUrlPolicy(
      allowPrivateNetwork: allowPrivateCalendarHosts,
    );
    importer = CalendarImporter(
      records: records,
      access: calendarAccess,
      location: () => settings.location,
      onChanged: () => hub.notifyRev(records.currentRev),
      client: httpClient,
      urlPolicy: remoteUrlPolicy,
    );
    lists = ListSync(
      db: db,
      records: records,
      timeZone: () => settings.location.name,
      location: () => settings.location,
      onChanged: () => hub.notifyRev(records.currentRev),
      enabled: () => !(settings.effective.hiddenModules ?? const []).contains(
        ServerSettings.listSyncModule,
      ),
      client: httpClient,
      log: auditLog,
    );
    caldav = CalDavSync(
      db: db,
      records: records,
      access: calendarAccess,
      location: () => settings.location,
      onChanged: () => hub.notifyRev(records.currentRev),
      client: httpClient,
      urlPolicy: remoteUrlPolicy,
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
      // Schedules are evaluated in the family's configured time zone, not
      // in the container's potentially unrelated system time zone.
      clock: () => tz.TZDateTime.now(settings.location),
      retention: () =>
          Duration(days: settings.effective.locationHistoryDays ?? 7),
    );
    files = FileStore(
      db,
      blobs:
          blobs ?? openEncrypted(p.join(dataDir, 'files.db'), hexKey: dataKey),
      dataDir: dataDir,
      records: records,
      maxBytes: () => settings.maxUploadBytes,
      maxTotalBytes: () => maxStorageMb * 1024 * 1024,
    );
    exports = DataExport(
      db: db,
      records: records,
      accounts: accounts,
      files: files,
      settings: settings,
      tempDir: p.join(dataDir, 'tmp'),
    );
    push = PushService(
      db: db,
      records: records,
      accounts: accounts,
      location: () => settings.location,
      client: httpClient,
      urlPolicy: RemoteUrlPolicy(allowPrivateNetwork: allowPrivatePushHosts),
      onOperationalError: auditLog,
    );
    notices = NoticeBox(db);
    sos = SosService(records: records, accounts: accounts, push: push);
    invites = Invites(db, accounts);
    push.onNotice = notices.add;
    records
      ..onStored = push.stored
      ..onServerStored = push.serverStored;
    allowances = AllowanceJob(
      records: records,
      accounts: accounts,
      location: () => settings.location,
      onChanged: () => hub.notifyRev(records.currentRev),
    );
    mfa = Mfa(db);
    sso = SsoService(
      db,
      publicUrl: () => settings.publicUrl,
      client: httpClient,
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
      lists: lists,
      exports: exports,
      calendarAccess: calendarAccess,
      locations: locations,
      push: push,
      notices: notices,
      sos: sos,
      invites: invites,
      mfa: mfa,
      sso: sso,
      webApp: webApp,
      onEventsChanged: caldav.eventsChanged,
    );
  }

  /// In-memory server in the Europe/Berlin zone, for tests.
  factory FamioServerApp.inMemory({
    http.Client? httpClient,
    Uri? googleBase,
    WebApp? webApp,
  }) {
    initTimeZones();
    return FamioServerApp(
      db: openFamioDatabase(':memory:'),
      location: tz.getLocation('Europe/Berlin'),
      dataDir: Directory.systemTemp.createTempSync('famio_test_').path,
      httpClient: httpClient,
      allowPrivateCalendarHosts: true,
      googleBase: googleBase,
      webApp: webApp,
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

  /// Bring! and Microsoft To Do connections.
  late final ListSync lists;

  /// Exports for members and admins.
  late final DataExport exports;
  late final LocationService locations;
  late final FileStore files;
  late final PushService push;
  late final NoticeBox notices;
  late final SosService sos;
  late final Invites invites;
  late final AllowanceJob allowances;
  late final Mfa mfa;
  late final SsoService sso;
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
    lists.start();
    exports.cleanUp();
    allowances.start();
    accounts.deleteExpiredSessions();
    locations.collectGarbage();
    notices.collectGarbage();
    _gc = Timer.periodic(const Duration(hours: 6), (_) {
      notices.collectGarbage();
      files.collectGarbage();
      accounts.deleteExpiredSessions();
      locations.collectGarbage();
    });
  }

  Future<void> close() async {
    _gc?.cancel();
    importer.stop();
    caldav.stop();
    lists.stop();
    allowances.stop();
    notices.close();
    push.close();
    await hub.close();
    files.blobs.close();
    db.close();
  }
}
