import 'member.dart';

/// A signed-in device (login session) of a member.
class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.createdAt,
    required this.lastSeen,
    this.device,
    this.current = false,
  });

  factory DeviceSession.fromJson(Map<String, Object?> json) => DeviceSession(
    id: json['id'] as String,
    device: json['device'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(json['lastSeen'] as int),
    current: json['current'] as bool? ?? false,
  );

  /// Short public handle; the token itself is only stored hashed.
  final String id;
  final String? device;
  final DateTime createdAt;
  final DateTime lastSeen;

  /// The session the request was made with.
  final bool current;

  Map<String, Object?> toJson() => {
    'id': id,
    'device': device,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'lastSeen': lastSeen.millisecondsSinceEpoch,
    'current': current,
  };
}

/// A member as seen in the server's user management.
class AdminUser {
  const AdminUser({
    required this.member,
    required this.createdAt,
    this.hasPassword = true,
    this.homeAssistant = false,
    this.sessions = const [],
    this.twoFactor = false,
    this.singleSignOn = false,
  });

  factory AdminUser.fromJson(Map<String, Object?> json) => AdminUser(
    member: FamilyMember.fromJson(json),
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
    hasPassword: json['hasPassword'] as bool? ?? true,
    homeAssistant: json['homeAssistant'] as bool? ?? false,
    twoFactor: json['twoFactor'] as bool? ?? false,
    singleSignOn: json['singleSignOn'] as bool? ?? false,
    sessions: [
      for (final s in json['sessions'] as List? ?? const [])
        DeviceSession.fromJson((s as Map).cast()),
    ],
  );

  final FamilyMember member;
  final DateTime createdAt;

  /// Members created through Home Assistant start without a password.
  final bool hasPassword;
  final bool homeAssistant;
  final List<DeviceSession> sessions;

  /// Signs in with an authenticator app as second factor.
  final bool twoFactor;

  /// Linked to the single sign-on provider.
  final bool singleSignOn;

  DateTime? get lastSeen => sessions.isEmpty
      ? null
      : sessions.map((s) => s.lastSeen).reduce((a, b) => a.isAfter(b) ? a : b);

  Map<String, Object?> toJson() => {
    ...member.toJson(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    'hasPassword': hasPassword,
    'homeAssistant': homeAssistant,
    'twoFactor': twoFactor,
    'singleSignOn': singleSignOn,
    'sessions': [for (final s in sessions) s.toJson()],
  };
}

/// Server settings that admins can change from any app.
///
/// A `null` value means "use the default" (environment variable or built-in).
class ServerSettings {
  const ServerSettings({
    this.publicUrl,
    this.timeZone,
    this.maxUploadMb,
    this.mapTileUrl,
    this.mapProvider,
    this.locationHistoryDays,
    this.twoFactorRequired,
    this.hiddenModules,
    this.holidayRegion,
  });

  factory ServerSettings.fromJson(Map<String, Object?> json) => ServerSettings(
    publicUrl: json['publicUrl'] as String?,
    timeZone: json['timeZone'] as String?,
    maxUploadMb: json['maxUploadMb'] as int?,
    mapTileUrl: json['mapTileUrl'] as String?,
    mapProvider: MapTileProvider.parse(json['mapProvider']),
    locationHistoryDays: json['locationHistoryDays'] as int?,
    twoFactorRequired: TwoFactorPolicy.parse(json['twoFactorRequired']),
    hiddenModules: (json['hiddenModules'] as List?)?.cast<String>(),
    holidayRegion: json['holidayRegion'] as String?,
  );

  /// Address under which the server is reachable from the internet.
  final String? publicUrl;

  /// IANA zone of the family, e.g. `Europe/Berlin`.
  final String? timeZone;
  final int? maxUploadMb;

  /// Map tiles for the family map, e.g. `https://tiles.example.org/{z}/{x}/{y}.png`;
  /// null uses OpenStreetMap.
  final String? mapTileUrl;

  /// The selected family-wide map provider. Older servers omit this field;
  /// clients then infer OpenStreetMap or a custom XYZ address from the URL.
  final MapTileProvider? mapProvider;

  /// How long precise location points remain available. The current position
  /// is unaffected; null means the server default (seven days).
  final int? locationHistoryDays;

  /// Who must sign in with a second factor; null: nobody.
  final TwoFactorPolicy? twoFactorRequired;

  /// Areas the family does not use (e.g. `budget`): hidden in every app.
  /// Their data stays on the server. Null or empty: all are shown.
  final List<String>? hiddenModules;

  /// Federal state whose public holidays the calendars show
  /// ([GermanState.code], e.g. `NW`); null: none.
  final String? holidayRegion;

  /// Areas that can be hidden (the names of the app's sections); start and
  /// settings always stay.
  static const optionalModules = [
    'tasks',
    'shopping',
    'calendar',
    'chat',
    'documents',
    'kids',
    'location',
    'chores',
    'meals',
    'budget',
    'health',
    'contacts',
    // Not a section: connections to Bring! and Microsoft To Do.
    listSyncModule,
  ];

  /// In [hiddenModules]: the family does not connect lists in other apps.
  static const listSyncModule = 'listSync';

  static const keys = [
    'publicUrl',
    'timeZone',
    'maxUploadMb',
    'mapTileUrl',
    'mapProvider',
    'locationHistoryDays',
    'twoFactorRequired',
    'hiddenModules',
    'holidayRegion',
  ];

  Map<String, Object?> toJson() => {
    'publicUrl': publicUrl,
    'timeZone': timeZone,
    'maxUploadMb': maxUploadMb,
    'mapTileUrl': mapTileUrl,
    'mapProvider': mapProvider?.wire,
    'locationHistoryDays': locationHistoryDays,
    'twoFactorRequired': twoFactorRequired?.name,
    'hiddenModules': hiddenModules,
    'holidayRegion': holidayRegion,
  };
}

/// Basemap choice. Martin is an own, privacy-friendly XYZ tile service that
/// serves the family's PMTiles/MBTiles; it is not a different data format for
/// the clients.
enum MapTileProvider {
  openStreetMap('osm'),
  martin('martin'),
  custom('custom');

  const MapTileProvider(this.wire);

  final String wire;

  static MapTileProvider? parse(Object? value) =>
      values.where((provider) => provider.wire == value).firstOrNull;
}

/// Members who must use two-factor login (or single sign-on).
enum TwoFactorPolicy {
  admins('Administratoren'),
  all('Alle Mitglieder');

  const TwoFactorPolicy(this.label);

  final String label;

  static TwoFactorPolicy? parse(Object? value) =>
      values.where((p) => p.name == value).firstOrNull;

  bool appliesTo(FamilyMember member) =>
      this == all || (this == admins && member.isAdmin);
}

/// Status and configuration of the server, for admins.
class ServerOverview {
  const ServerOverview({
    required this.version,
    required this.startedAt,
    required this.settings,
    required this.defaults,
    required this.effective,
    this.trustProxy = false,
    this.ingressAuth = false,
    this.databaseBytes = 0,
    this.fileCount = 0,
    this.fileBytes = 0,
    this.recordCounts = const {},
    this.memberCount = 0,
    this.sessionCount = 0,
    this.connectedClients = 0,
    this.tlsPort,
    this.tlsFingerprint,
    this.requireTls = false,
    this.encryptedAtRest = false,
    this.keySeparate = false,
    this.locationCodeSet = false,
  });

  factory ServerOverview.fromJson(Map<String, Object?> json) => ServerOverview(
    version: json['version'] as String,
    startedAt: DateTime.fromMillisecondsSinceEpoch(json['startedAt'] as int),
    settings: ServerSettings.fromJson((json['settings'] as Map).cast()),
    defaults: ServerSettings.fromJson((json['defaults'] as Map).cast()),
    effective: ServerSettings.fromJson((json['effective'] as Map).cast()),
    trustProxy: json['trustProxy'] as bool? ?? false,
    ingressAuth: json['ingressAuth'] as bool? ?? false,
    databaseBytes: json['databaseBytes'] as int? ?? 0,
    fileCount: json['fileCount'] as int? ?? 0,
    fileBytes: json['fileBytes'] as int? ?? 0,
    recordCounts: (json['recordCounts'] as Map? ?? const {}).cast(),
    memberCount: json['memberCount'] as int? ?? 0,
    sessionCount: json['sessionCount'] as int? ?? 0,
    connectedClients: json['connectedClients'] as int? ?? 0,
    tlsPort: json['tlsPort'] as int?,
    tlsFingerprint: json['tlsFingerprint'] as String?,
    requireTls: json['requireTls'] as bool? ?? false,
    encryptedAtRest: json['encryptedAtRest'] as bool? ?? false,
    keySeparate: json['keySeparate'] as bool? ?? false,
    locationCodeSet: json['locationCodeSet'] as bool? ?? false,
  );

  final String version;
  final DateTime startedAt;

  /// Values set in the app (null = not overridden).
  final ServerSettings settings;

  /// Values from environment / add-on options or built-in defaults.
  final ServerSettings defaults;

  /// What the server currently uses.
  final ServerSettings effective;

  /// Only configurable on the host (security relevant).
  final bool trustProxy;
  final bool ingressAuth;

  final int databaseBytes;
  final int fileCount;
  final int fileBytes;

  /// Live records per collection.
  final Map<String, int> recordCounts;
  final int memberCount;
  final int sessionCount;
  final int connectedClients;

  /// HTTPS port with the server's own certificate (null: off).
  final int? tlsPort;

  /// SHA-256 of that certificate, to compare when an app asks.
  final String? tlsFingerprint;

  /// Unencrypted access only through the proxy, ingress or localhost.
  final bool requireTls;

  /// Database and files are encrypted on disk.
  final bool encryptedAtRest;

  /// The key is kept outside the data directory (and its backups).
  final bool keySeparate;

  /// Whether the parents' code for pausing location sharing is set.
  final bool locationCodeSet;

  Map<String, Object?> toJson() => {
    'version': version,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'settings': settings.toJson(),
    'defaults': defaults.toJson(),
    'effective': effective.toJson(),
    'trustProxy': trustProxy,
    'ingressAuth': ingressAuth,
    'databaseBytes': databaseBytes,
    'fileCount': fileCount,
    'fileBytes': fileBytes,
    'recordCounts': recordCounts,
    'memberCount': memberCount,
    'sessionCount': sessionCount,
    'connectedClients': connectedClients,
    'tlsPort': tlsPort,
    'tlsFingerprint': tlsFingerprint,
    'requireTls': requireTls,
    'encryptedAtRest': encryptedAtRest,
    'keySeparate': keySeparate,
    'locationCodeSet': locationCodeSet,
  };
}

/// One point of the setup checklist admins see after the first start
/// (`GET /api/admin/setup`).
class SetupStep {
  const SetupStep({
    required this.id,
    required this.title,
    required this.done,
    required this.detail,
    this.where = '',
  });

  factory SetupStep.fromJson(Map<String, Object?> json) => SetupStep(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    done: json['done'] as bool? ?? false,
    detail: json['detail'] as String? ?? '',
    where: json['where'] as String? ?? '',
  );

  final String id;
  final String title;
  final bool done;

  /// What is the matter, or what was found.
  final String detail;

  /// Where to change it ("Server-Verwaltung → Einstellungen").
  final String where;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'done': done,
    'detail': detail,
    if (where.isNotEmpty) 'where': where,
  };
}
