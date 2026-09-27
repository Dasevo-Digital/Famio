import 'sync_record.dart';

/// Body of `POST /api/sync`: push local changes and pull everything newer
/// than [since] in one round trip.
class SyncRequest {
  const SyncRequest({required this.since, this.changes = const []});

  factory SyncRequest.fromJson(Map<String, Object?> json) => SyncRequest(
    since: json['since'] as int? ?? 0,
    changes: [
      for (final c in (json['changes'] as List? ?? const []))
        SyncRecord.fromJson((c as Map).cast()),
    ],
  );

  /// Highest server revision the client has already applied.
  final int since;
  final List<SyncRecord> changes;

  Map<String, Object?> toJson() => {
    'since': since,
    'changes': [for (final c in changes) c.toJson()],
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

  Map<String, Object?> toJson() => {
    'rev': rev,
    'serverTime': serverTime,
    'changes': [for (final c in changes) c.toJson()],
    'rejected': [for (final c in rejected) c.toJson()],
    'unsupported': unsupported.toList(),
    'hasMore': hasMore,
  };
}
