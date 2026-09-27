import '../sync_record.dart';

/// Who besides its owner sees a calendar a member connected (Google, iCloud,
/// an ICS subscription …).
class CalendarSharing {
  /// The whole family, also members added later.
  const CalendarSharing.family() : members = null;

  /// The owner and [members] (none: only the owner).
  const CalendarSharing.only(List<String> this.members);

  const CalendarSharing.private() : members = const [];

  /// `null` in JSON means the whole family, a list the chosen members.
  factory CalendarSharing.fromJson(Object? json) => json is List
      ? CalendarSharing.only([for (final id in json) id as String])
      : const CalendarSharing.family();

  final List<String>? members;

  bool get family => members == null;
  bool get private => members?.isEmpty ?? false;

  /// Record audience for [owner]: null for the whole family.
  List<String>? audience(String owner) =>
      members == null ? null : {owner, ...members!}.toList();

  Object? toJson() => members;

  @override
  bool operator ==(Object other) =>
      other is CalendarSharing &&
      (members == null) == (other.members == null) &&
      (members == null ||
          {...members!}.length == {...other.members!}.length &&
              members!.toSet().containsAll(other.members!));

  @override
  int get hashCode => members == null ? 0 : Object.hashAllUnordered(members!);
}

/// An external calendar (Google, iCloud, …) imported via its ICS address,
/// stored in `Collections.calendarSubscriptions`.
class CalendarSubscription {
  const CalendarSubscription({
    required this.id,
    required this.name,
    required this.url,
    this.color,
    this.ownerId,
    this.sharing = const CalendarSharing.family(),
  });

  factory CalendarSubscription.fromRecord(SyncRecord r) => CalendarSubscription(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    url: r.data['url'] as String? ?? '',
    color: r.data['color'] as int?,
    ownerId: r.data['ownerId'] as String?,
    sharing: CalendarSharing.fromJson(r.data['sharedWith']),
  );

  final String id;
  final String name;

  /// `https://…` or `webcal://…` address of the ICS file.
  final String url;

  /// ARGB color for its events.
  final int? color;

  /// Member who added it; only they may change it. Null for subscriptions
  /// from before 0.12, which belong to the whole family.
  final String? ownerId;

  /// Who sees it and its events (the server also applies the calendar
  /// profiles set by an admin).
  final CalendarSharing sharing;

  /// Only the owner may change it; family subscriptions everyone.
  bool editableBy(String memberId) => ownerId == null || ownerId == memberId;

  Map<String, Object?> toData() => {
    'name': name,
    'url': url,
    'color': color,
    if (ownerId != null) 'ownerId': ownerId,
    if (ownerId != null) 'sharedWith': sharing.toJson(),
    if (ownerId != null) SyncRecord.visibilityKey: ?sharing.audience(ownerId!),
  };
}

/// Result of the server's last import of a subscription (same id), stored in
/// `Collections.calendarSyncStatus`.
class SubscriptionStatus {
  const SubscriptionStatus({
    required this.id,
    this.lastSync,
    this.error,
    this.eventCount = 0,
  });

  factory SubscriptionStatus.fromRecord(SyncRecord r) => SubscriptionStatus(
    id: r.id,
    lastSync: DateTime.tryParse(r.data['lastSync'] as String? ?? '')?.toLocal(),
    error: r.data['error'] as String?,
    eventCount: r.data['eventCount'] as int? ?? 0,
  );

  final String id;
  final DateTime? lastSync;
  final String? error;
  final int eventCount;

  Map<String, Object?> toData() => {
    'lastSync': lastSync?.toUtc().toIso8601String(),
    'error': error,
    'eventCount': eventCount,
  };
}

enum FeedScope {
  /// All family events.
  all,

  /// Only events the owner takes part in (or whole-family events).
  mine,
}

/// A private ICS address publishing Famio events for other calendar apps.
class CalendarFeed {
  const CalendarFeed({
    required this.id,
    required this.name,
    required this.scope,
    required this.path,
    this.hideDetails = false,
  });

  factory CalendarFeed.fromJson(Map<String, Object?> json) => CalendarFeed(
    id: json['id'] as String,
    name: json['name'] as String,
    scope: FeedScope.values.byName(json['scope'] as String),
    path: json['path'] as String,
    hideDetails: json['hideDetails'] as bool? ?? false,
  );

  final String id;
  final String name;
  final FeedScope scope;

  /// Server-relative path including the secret token, e.g. `ical/abc.ics`.
  final String path;

  /// Only "Belegt" blocks without title, place or notes.
  final bool hideDetails;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'scope': scope.name,
    'path': path,
    'hideDetails': hideDetails,
  };
}
