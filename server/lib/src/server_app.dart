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
import 'auth/passkeys.dart';
import 'auth/sso.dart';
import 'calendar/calendar_access.dart';
import 'calendar/calendar_feeds.dart';
import 'calendar/calendar_importer.dart';
import 'database.dart';
import 'fallback_fonts.dart';
import 'dav/caldav_sync.dart';
import 'export/data_export.dart';
import 'lists/list_sync.dart';
import 'dav/google_oauth.dart';
import 'backup/backup_job.dart';
import 'metrics.dart';
import 'family/invites.dart';
import 'family/sos.dart';
import 'family/allowance_job.dart';
import 'hub.dart';
import 'push/notice_box.dart';
import 'push/push_service.dart';
import 'push/web_push.dart';
import 'location/location_service.dart';
import 'files/file_store.dart';
import 'record_store.dart';
import 'security.dart';
import 'settings.dart';
import 'crypto/encrypted_db.dart';
import 'remote_url_policy.dart';
import 'dav/dav_properties.dart';
import 'dav/step_marks.dart';
import 'documents/paperless.dart';
import 'photos/photovault.dart';
import 'updates/app_updates.dart';
import 'updates/profile_notices.dart';
import 'updates/update_notices.dart';

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
    int maxExportMb = 4096,
    bool allowPrivateCalendarHosts = false,
    bool allowPrivatePushHosts = false,
    http.Client? httpClient,
    HostLookup? hostLookup,
    void Function(String line)? auditLog,
    Database? blobs,
    String? dataKey,
    bool keySeparate = false,
    bool requireTls = false,
    int? tlsPort,
    ServerTls? tls,
    Uri? googleBase,
    WebApp? webApp,
    String? backupDir,
    String? metricsToken,
    String releaseKey = famioReleaseKey,
    LoginThrottle? throttle,
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
      assignmentLocation: () => settings.location,
      today: () {
        final now = tz.TZDateTime.now(settings.location);
        return DateTime(now.year, now.month, now.day);
      },
    );
    records.restrictGuestTasks();
    calendarAccess = CalendarAccess(
      db,
      records: records,
      memberIds: () => [for (final m in accounts.members()) m.id],
    );
    final lookup = hostLookup ?? InternetAddress.lookup;
    final remoteUrlPolicy = RemoteUrlPolicy(
      allowPrivateNetwork: allowPrivateCalendarHosts,
      lookup: lookup,
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
      maxExportBytes: maxExportMb * 1024 * 1024,
    );
    push = PushService(
      db: db,
      records: records,
      accounts: accounts,
      location: () => settings.location,
      client: httpClient,
      urlPolicy: RemoteUrlPolicy(
        allowPrivateNetwork: allowPrivatePushHosts,
        lookup: lookup,
      ),
      onOperationalError: auditLog,
      onSent: metrics.pushResult,
    );
    notices = NoticeBox(db);
    sos = SosService(records: records, accounts: accounts, push: push);
    invites = Invites(db, accounts);
    backups = backupDir == 'off'
        ? null
        : BackupJob(
            db: db,
            blobs: files.blobs,
            dir: backupDir ?? p.join(dataDir, 'backups'),
            dbPath: p.join(dataDir, 'famio.db'),
            blobsPath: blobs == null ? p.join(dataDir, 'files.db') : null,
            hexKey: dataKey,
            location: () => settings.location,
            onError: auditLog,
          );
    push.onNotice = notices.add;
    push.web = WebPush(
      db,
      client: httpClient,
      publicUrl: () => settings.publicUrl,
      urlPolicy: RemoteUrlPolicy(
        allowPrivateNetwork: allowPrivatePushHosts,
        lookup: lookup,
      ),
      onSent: metrics.pushResult,
    );
    locations.onShopArrival = push.shopArrival;
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
    paperless = PaperlessLink(
      db: db,
      records: records,
      accounts: accounts,
      onChanged: () => hub.notifyRev(records.currentRev),
      client: httpClient,
    )..adoptPaperBuddy();
    photoVault = PhotoVaultLink(
      db: db,
      records: records,
      accounts: accounts,
      files: files,
      location: () => settings.location,
      onChanged: () => hub.notifyRev(records.currentRev),
      client: httpClient,
    );
    appUpdates = AppUpdates(
      db: db,
      dir: p.join(dataDir, 'app-updates'),
      version: serverVersion,
      client: httpClient,
      publicKey: releaseKey,
      onError: auditLog,
    );
    // CJK fallback fonts through this server instead of Google's (see
    // FallbackFonts).
    if (webApp != null) {
      webApp.fallbackFonts ??= FallbackFonts.forWebApp(
        webApp.dir,
        cacheDir: p.join(dataDir, 'font-cache'),
        client: httpClient,
      );
    }
    api = FamioApi(
      accounts: accounts,
      records: records,
      hub: hub,
      feeds: CalendarFeeds(db),
      files: files,
      clientAddress: ClientAddress(trustProxy: trustProxy),
      throttle: throttle,
      setupCode: setupCode,
      importer: importer,
      settings: settings,
      ingressAuth: ingressAuth,
      trustProxy: trustProxy,
      dbSize: _dbSize,
      metrics: metrics,
      metricsToken: metricsToken,
      selfCheckClient: httpClient ?? http.Client(),
      hostLookup: lookup,
      compactDatabase: _compact,
      davSteps: DavStepMarks(db),
      davProperties: DavProperties(db),
      paperless: paperless,
      photoVault: photoVault,
      appUpdates: appUpdates,
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
      backups: backups,
      mfa: mfa,
      passkeys: Passkeys(db),
      sso: sso,
      webApp: webApp,
      onEventsChanged: caldav.eventsChanged,
    );
  }

  /// In-memory server in the Europe/Berlin zone, for tests. Host names
  /// resolve to nothing unless [hostLookup] says otherwise: tests must not
  /// depend on (or hang in) a real resolver.
  factory FamioServerApp.inMemory({
    http.Client? httpClient,
    HostLookup hostLookup = _noHosts,
    Uri? googleBase,
    WebApp? webApp,
    String? metricsToken,
    String releaseKey = famioReleaseKey,
    LoginThrottle? throttle,
  }) {
    initTimeZones();
    return FamioServerApp(
      releaseKey: releaseKey,
      db: openFamioDatabase(':memory:'),
      metricsToken: metricsToken,
      location: tz.getLocation('Europe/Berlin'),
      dataDir: Directory.systemTemp.createTempSync('famio_test_').path,
      httpClient: httpClient,
      hostLookup: hostLookup,
      allowPrivateCalendarHosts: true,
      googleBase: googleBase,
      webApp: webApp,
      throttle: throttle,
    );
  }

  static Future<List<InternetAddress>> _noHosts(String host) =>
      throw SocketException('No name resolution in tests', address: null);

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
  late final PaperlessLink paperless;
  late final PhotoVaultLink photoVault;
  late final AppUpdates appUpdates;
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

  /// Nightly backups; null when switched off (`FAMIO_BACKUP_DIR=off`).
  late final BackupJob? backups;

  /// Counters for `/metrics` (see [FamioApi.metricsToken]).
  final metrics = ServerMetrics();
  late final AllowanceJob allowances;
  late final Mfa mfa;
  late final SsoService sso;
  late final String? setupCode;
  Timer? _gc;
  Timer? _silent;
  Timer? _assignmentTimer;
  late final FamioApi api;

  /// The family's time zone (may be changed by admins at runtime).
  tz.Location get location => settings.location;

  Handler get handler => api.handler;

  /// The route templates, for the request log.
  List<String> get routes => api.routes;

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
    paperless.start();
    photoVault.start();
    appUpdates
      ..onReady = UpdateNotices(
        db: db,
        accounts: accounts,
        push: push,
        version: serverVersion,
      ).announce
      ..start();
    caldav.start();
    lists.start();
    exports.cleanUp();
    allowances.start();
    accounts.deleteExpiredSessions();
    locations.collectGarbage();
    notices.collectGarbage();
    records.purgeDeleted();
    records.expireTrash();
    records.expireConflicts();
    invites.collectGarbage();
    backups?.start();
    push.remindAssignments();
    _assignmentTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => push.remindAssignments(),
    );
    // Hourly, the first time an hour after the start: after the server was
    // down, devices report again before anybody counts as silent.
    final profiles = ProfileNotices(
      accounts: accounts,
      push: push,
      location: () => settings.location,
    );
    _silent = Timer.periodic(const Duration(hours: 1), (_) {
      // iPhones whose Famio stops opening soon.
      profiles.check();
      for (final (member, since) in locations.newlySilent()) {
        sos.deviceSilent(member, since);
      }
      // Absences begin and end with the day.
      if (records.refreshSubstitutes()) hub.notifyRev(records.currentRev);
    });
    _gc = Timer.periodic(const Duration(hours: 6), (_) {
      notices.collectGarbage();
      records.purgeDeleted();
      records.expireTrash();
      if (records.expireConflicts() > 0) hub.notifyRev(records.currentRev);
      invites.collectGarbage();
      unawaited(files.collectGarbageAsync());
      accounts.deleteExpiredSessions();
      locations.collectGarbage();
    });
  }

  Future<void> close() async {
    _assignmentTimer?.cancel();
    _gc?.cancel();
    _silent?.cancel();
    backups?.stop();
    importer.stop();
    paperless.stop();
    photoVault.stop();
    appUpdates.stop();
    caldav.stop();
    lists.stop();
    allowances.stop();
    await files.maintenanceIdle;
    await push.idle;
    notices.close();
    push.close();
    await hub.close();
    files.blobs.close();
    db.close();
  }
}
