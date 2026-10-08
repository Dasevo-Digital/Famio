import 'sync_record.dart';

/// Body of `POST /api/sync`: push local changes and pull everything newer
/// than [since] in one round trip.
class SyncRequest {
  const SyncRequest({
    required this.since,
    this.changes = const [],
    this.resettable = false,
    this.full = false,
  });

  factory SyncRequest.fromJson(Map<String, Object?> json) => SyncRequest(
    since: json['since'] as int? ?? 0,
    changes: [
      for (final c in (json['changes'] as List? ?? const []))
        SyncRecord.fromJson((c as Map).cast()),
    ],
    resettable: json['resettable'] as bool? ?? false,
    full: json['full'] as bool? ?? false,
  );

  /// Highest server revision the client has already applied.
  final int since;
  final List<SyncRecord> changes;

  /// The client understands [SyncResponse.reset] (since 1.0.10).
  final bool resettable;

  /// The client is downloading everything from revision 0 page by page, so
  /// an old [since] is no reason for another reset.
  final bool full;

  Map<String, Object?> toJson() => {
    'since': since,
    'changes': [for (final c in changes) c.toJson()],
    if (resettable) 'resettable': true,
    if (full) 'full': true,
  };
}

class SyncResponse {
  const SyncResponse({
    required this.rev,
    required this.serverTime,
    this.changes = const [],
    this.rejected = const [],
    this.unsupported = const {},
    this.hasMore = false,
    this.reset = false,
  });

  factory SyncResponse.fromJson(Map<String, Object?> json) => SyncResponse(
    rev: json['rev'] as int,
    serverTime: json['serverTime'] as int,
    changes: [
      for (final c in (json['changes'] as List? ?? const []))
        SyncRecord.fromJson((c as Map).cast()),
    ],
    rejected: [
      for (final c in (json['rejected'] as List? ?? const []))
        SyncRecord.fromJson((c as Map).cast()),
    ],
    unsupported: {
      for (final c in (json['unsupported'] as List? ?? const [])) c as String,
    },
    hasMore: json['hasMore'] as bool? ?? false,
    reset: json['reset'] as bool? ?? false,
  );

  /// Revision the client has caught up to after applying [changes].
  final int rev;

  /// Server clock (ms since epoch), used by clients to correct their clock.
  final int serverTime;

  /// Records with a revision above the request's `since`, oldest first.
  final List<SyncRecord> changes;

  /// Current server versions of pushed records that lost the conflict.
  final List<SyncRecord> rejected;

  /// Collections this server does not know (it is older than the client).
  /// Pushed records of these were not stored; the client keeps them.
  final Set<String> unsupported;

  /// More changes are pending; the client should sync again with [rev].
  final bool hasMore;

  /// The server no longer has the deletions since the client's revision
  /// (they were cleaned up): it sends everything from revision 0, and the
  /// client drops what it has but does not receive in this pass.
  final bool reset;

  Map<String, Object?> toJson() => {
    'rev': rev,
    'serverTime': serverTime,
    'changes': [for (final c in changes) c.toJson()],
    'rejected': [for (final c in rejected) c.toJson()],
    'unsupported': unsupported.toList(),
    'hasMore': hasMore,
    if (reset) 'reset': true,
  };
}
