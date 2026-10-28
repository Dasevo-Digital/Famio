import '../sync_record.dart';

/// A server-held deletion snapshot. It is fetched with current access checks,
/// rather than copied into every device's offline cache.
class TrashEntry {
  const TrashEntry({
    required this.id,
    required this.record,
    required this.deletedAt,
    required this.expiresAt,
    required this.deletedBy,
    required this.deletedRev,
    this.canRestore = false,
  });

  factory TrashEntry.fromJson(Map<String, Object?> json) => TrashEntry(
    id: json['id'] as String,
    record: SyncRecord.fromJson((json['record'] as Map).cast()),
    deletedAt: DateTime.fromMillisecondsSinceEpoch(json['deletedAt'] as int),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int),
    deletedBy: json['deletedBy'] as String?,
    deletedRev: json['deletedRev'] as int,
    canRestore: json['canRestore'] as bool? ?? false,
  );

  final String id;
  final SyncRecord record;
  final DateTime deletedAt;
  final DateTime expiresAt;
  final String? deletedBy;
  final int deletedRev;
  final bool canRestore;

  String get title =>
      [
        record.data['title'],
        record.data['name'],
      ].whereType<String>().where((v) => v.trim().isNotEmpty).firstOrNull ??
      '';

  Map<String, Object?> toJson() => {
    'id': id,
    'record': record.toJson(),
    'deletedAt': deletedAt.millisecondsSinceEpoch,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'deletedBy': deletedBy,
    'deletedRev': deletedRev,
    'canRestore': canRestore,
  };
}
