import 'models/calendar_sync.dart';

/// A password for one calendar app (Apple Calendar, DAVx5 …) that connects
/// to Famio's CalDAV server. Separate from the login password, so it can be
/// revoked per device and never unlocks the rest of Famio.
class AppPassword {
  const AppPassword({
    required this.id,
    required this.name,
    required this.createdAt,
    this.lastUsed,
    this.includeConfidential = false,
  });

  factory AppPassword.fromJson(Map<String, Object?> json) => AppPassword(
    id: json['id'] as String,
    name: json['name'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
    lastUsed: DateTime.tryParse(json['lastUsed'] as String? ?? '')?.toLocal(),
    includeConfidential: json['includeConfidential'] as bool? ?? false,
  );

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime? lastUsed;

  /// Whether confidential events are shown to this calendar app.
  final bool includeConfidential;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastUsed': lastUsed?.toUtc().toIso8601String(),
    'includeConfidential': includeConfidential,
  };
}

/// A calendar found on a CalDAV server (iCloud, Nextcloud, …).
class CalDavCalendarInfo {
  const CalDavCalendarInfo({
    required this.url,
    required this.name,
    this.color,
    this.readOnly = false,
  });

  factory CalDavCalendarInfo.fromJson(Map<String, Object?> json) =>
      CalDavCalendarInfo(
        url: json['url'] as String,
        name: json['name'] as String,
        color: json['color'] as int?,
        readOnly: json['readOnly'] as bool? ?? false,
      );

  final String url;
  final String name;

  /// ARGB color as set in the calendar app.
  final int? color;
  final bool readOnly;

  Map<String, Object?> toJson() => {
    'url': url,
    'name': name,
    'color': color,
    'readOnly': readOnly,
  };
}

/// Two-way sync between Famio and a calendar on another CalDAV server.
/// The password stays on the Famio server and is never sent back.
class CalDavAccount {
  const CalDavAccount({
    required this.id,
    required this.name,
    required this.serverUrl,
    required this.username,
    required this.calendarUrl,
    required this.calendarName,
    this.onlyMine = false,
    this.privateImport = false,
    this.lastSync,
    this.error,
    this.linkedEvents = 0,
    this.google = false,
    this.sharing = const CalendarSharing.family(),
  });

  factory CalDavAccount.fromJson(Map<String, Object?> json) => CalDavAccount(
    id: json['id'] as String,
    name: json['name'] as String,
    serverUrl: json['serverUrl'] as String,
    username: json['username'] as String,
    calendarUrl: json['calendarUrl'] as String,
    calendarName: json['calendarName'] as String,
    onlyMine: json['onlyMine'] as bool? ?? false,
    privateImport: json['privateImport'] as bool? ?? false,
    lastSync: DateTime.tryParse(json['lastSync'] as String? ?? '')?.toLocal(),
    error: json['error'] as String?,
    linkedEvents: json['linkedEvents'] as int? ?? 0,
    google: json['google'] as bool? ?? false,
    // Servers before 0.12 only knew "just me" (privateImport).
    sharing: json.containsKey('sharedWith')
        ? CalendarSharing.fromJson(json['sharedWith'])
        : json['privateImport'] == true
        ? const CalendarSharing.private()
        : const CalendarSharing.family(),
  );

  final String id;
  final String name;
  final String serverUrl;
  final String username;
  final String calendarUrl;
  final String calendarName;

  /// Send only events the owner takes part in (and whole-family events).
  final bool onlyMine;

  /// Events coming from the other calendar are visible to the owner only
  /// (same as a private [sharing]; kept for older apps).
  final bool privateImport;
  final DateTime? lastSync;
  final String? error;

  /// Events currently kept in sync.
  final int linkedEvents;

  /// Signed in with Google (OAuth) instead of a password.
  final bool google;

  /// Who sees the events coming from the other calendar.
  final CalendarSharing sharing;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'serverUrl': serverUrl,
    'username': username,
    'calendarUrl': calendarUrl,
    'calendarName': calendarName,
    'onlyMine': onlyMine,
    'privateImport': privateImport,
    'lastSync': lastSync?.toUtc().toIso8601String(),
    'error': error,
    'linkedEvents': linkedEvents,
    'google': google,
    'sharedWith': sharing.toJson(),
  };
}

/// A calendar connected by some member that reaches a member by its owner's
/// sharing – what an admin can switch off in that member's calendar profile.
class MemberCalendar {
  const MemberCalendar({
    required this.source,
    required this.name,
    required this.kind,
    this.ownerId,
    this.hidden = false,
  });

  factory MemberCalendar.fromJson(Map<String, Object?> json) => MemberCalendar(
    source: json['source'] as String,
    name: json['name'] as String,
    kind: json['kind'] as String,
    ownerId: json['ownerId'] as String?,
    hidden: json['hidden'] as bool? ?? false,
  );

  /// Subscription id or `caldav:<account id>`.
  final String source;
  final String name;

  /// `subscription`, `caldav` or `google`.
  final String kind;

  /// Null for family subscriptions from before 0.12.
  final String? ownerId;

  /// Switched off by an admin for this member.
  final bool hidden;

  Map<String, Object?> toJson() => {
    'source': source,
    'name': name,
    'kind': kind,
    'ownerId': ownerId,
    'hidden': hidden,
  };
}

/// Answer of the server to a device's location report.
class LocationReportResult {
  const LocationReportResult({
    required this.paused,
    this.pausedUntil,
    this.intervalSeconds = 120,
  });

  factory LocationReportResult.fromJson(Map<String, Object?> json) =>
      LocationReportResult(
        paused: json['paused'] as bool? ?? false,
        pausedUntil: DateTime.tryParse(
          json['pausedUntil'] as String? ?? '',
        )?.toLocal(),
        intervalSeconds: json['interval'] as int? ?? 120,
      );

  final bool paused;
  final DateTime? pausedUntil;

  /// How often the device should report.
  final int intervalSeconds;

  Map<String, Object?> toJson() => {
    'paused': paused,
    'pausedUntil': pausedUntil?.toUtc().toIso8601String(),
    'interval': intervalSeconds,
  };
}
