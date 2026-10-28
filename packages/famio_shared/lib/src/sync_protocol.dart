import 'sync_record.dart';

/// Body of `POST /api/sync`: push local changes and pull everything newer
/// than [since] in one round trip.
class SyncRequest {
  const SyncRequest({
    required this.since,
    this.changes = const [],
    this.resettable = false,
    this.full = false,
    this.scope,
    this.deferInvalidFiles = false,
  });

  factory SyncRequest.fromJson(Map<String, Object?> json) => SyncRequest(
    since: json['since'] as int? ?? 0,
    changes: [
      for (final c in (json['changes'] as List? ?? const []))
        SyncRecord.fromJson((c as Map).cast()),
    ],
    resettable: json['resettable'] as bool? ?? false,
    full: json['full'] as bool? ?? false,
    scope: json['scope'] as String?,
    deferInvalidFiles: json['deferInvalidFiles'] as bool? ?? false,
  );

  /// Highest server revision the client has already applied.
  final int since;
  final List<SyncRecord> changes;

  /// The client understands [SyncResponse.reset] (since 1.0.10).
  final bool resettable;

  /// The client is downloading everything from revision 0 page by page, so
  /// an old [since] is no reason for another reset.
  final bool full;

  /// Server instance and access scope of the previous completed page.
  final String? scope;

  /// Understands per-record attachment failures without aborting the pull.
  final bool deferInvalidFiles;

  Map<String, Object?> toJson() => {
    'since': since,
    'changes': [for (final c in changes) c.toJson()],
    if (resettable) 'resettable': true,
    if (full) 'full': true,
    if (scope != null) 'scope': scope,
    if (deferInvalidFiles) 'deferInvalidFiles': true,
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
    this.scope,
    this.blocked = const [],
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
    scope: json['scope'] as String?,
    blocked: [
      for (final issue in json['blocked'] as List? ?? const [])
        SyncWriteIssue.fromJson((issue as Map).cast()),
    ],
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
  final String? scope;

  /// Pending edits that need repair; their contents were not stored.
  final List<SyncWriteIssue> blocked;

  Map<String, Object?> toJson() => {
    'rev': rev,
    'serverTime': serverTime,
    'changes': [for (final c in changes) c.toJson()],
    'rejected': [for (final c in rejected) c.toJson()],
    'unsupported': unsupported.toList(),
    'hasMore': hasMore,
    if (reset) 'reset': true,
    if (scope != null) 'scope': scope,
    if (blocked.isNotEmpty)
      'blocked': [for (final issue in blocked) issue.toJson()],
  };
}

/// Identifies an exact local edit, without echoing its contents.
class SyncWriteIssue {
  const SyncWriteIssue({
    required this.collection,
    required this.id,
    required this.updatedAt,
    required this.code,
  });
  factory SyncWriteIssue.fromJson(Map<String, Object?> json) => SyncWriteIssue(
    collection: json['collection'] as String,
    id: json['id'] as String,
    updatedAt: json['updatedAt'] as int,
    code: json['code'] as String,
  );
  final String collection;
  final String id;
  final int updatedAt;
  final String code;
  Map<String, Object?> toJson() => {
    'collection': collection,
    'id': id,
    'updatedAt': updatedAt,
    'code': code,
  };
}
