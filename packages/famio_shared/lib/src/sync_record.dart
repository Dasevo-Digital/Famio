/// The unit of synchronisation: one document in a collection.
///
/// Conflicts are resolved per record with last-writer-wins on [updatedAt].
/// Clients correct their clock with the server time offset they learn during
/// sync, so [updatedAt] is roughly comparable across devices.
class SyncRecord {
  const SyncRecord({
    required this.collection,
    required this.id,
    required this.data,
    required this.updatedAt,
    this.deleted = false,
    this.updatedBy,
    this.rev = 0,
  });

  factory SyncRecord.fromJson(Map<String, Object?> json) => SyncRecord(
    collection: json['collection'] as String,
    id: json['id'] as String,
    data: (json['data'] as Map?)?.cast<String, Object?>() ?? const {},
    updatedAt: json['updatedAt'] as int,
    deleted: json['deleted'] as bool? ?? false,
    updatedBy: json['updatedBy'] as String?,
    rev: json['rev'] as int? ?? 0,
  );

  final String collection;
  final String id;
  final Map<String, Object?> data;

  /// Data key restricting who receives the record: a list of member ids.
  /// Absent or null means the whole family. Enforced by the server.
  static const visibilityKey = 'visibleTo';

  /// Members allowed to see this record; null for the whole family.
  List<String>? get visibleTo => switch (data[visibilityKey]) {
    final List<Object?> ids => [for (final id in ids) id as String],
    _ => null,
  };

  /// Milliseconds since epoch (server-corrected client clock) of the last edit.
  final int updatedAt;

  /// Tombstone flag; deleted records are kept so the deletion syncs.
  final bool deleted;

  /// Member id of the last editor, set by the server.
  final String? updatedBy;

  /// Server revision at which this version was stored; 0 if never synced.
  final int rev;

  /// Whether this version should replace [other] under last-writer-wins.
  /// Ties are broken by [updatedBy] so every node picks the same winner.
  bool winsOver(SyncRecord other) {
    if (updatedAt != other.updatedAt) return updatedAt > other.updatedAt;
    return (updatedBy ?? '').compareTo(other.updatedBy ?? '') >= 0;
  }

  SyncRecord copyWith({
    Map<String, Object?>? data,
    int? updatedAt,
    bool? deleted,
    String? updatedBy,
    int? rev,
  }) => SyncRecord(
    collection: collection,
    id: id,
    data: data ?? this.data,
    updatedAt: updatedAt ?? this.updatedAt,
    deleted: deleted ?? this.deleted,
    updatedBy: updatedBy ?? this.updatedBy,
    rev: rev ?? this.rev,
  );

  Map<String, Object?> toJson() => {
    'collection': collection,
    'id': id,
    'data': data,
    'updatedAt': updatedAt,
    'deleted': deleted,
    'updatedBy': updatedBy,
    'rev': rev,
  };

  @override
  String toString() => 'SyncRecord($collection/$id rev=$rev deleted=$deleted)';
}
