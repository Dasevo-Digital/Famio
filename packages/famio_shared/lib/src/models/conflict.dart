import '../sync_record.dart';

/// Two members changed the same record without seeing each other's change
/// (e.g. one of them offline). Last-writer-wins kept one version; the other
/// is stored here so nothing is lost silently. Written by the server into
/// `Collections.conflicts`, seen by both authors; resolving deletes it.
class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.collection,
    required this.recordId,
    required this.lost,
    required this.lostDeleted,
    required this.lostBy,
    required this.lostAt,
    required this.keptBy,
    required this.keptAt,
  });

  factory SyncConflict.fromRecord(SyncRecord r) => SyncConflict(
    id: r.id,
    collection: r.data['collection'] as String? ?? '',
    recordId: r.data['recordId'] as String? ?? '',
    lost: (r.data['lost'] as Map?)?.cast<String, Object?>() ?? const {},
    lostDeleted: r.data['lostDeleted'] as bool? ?? false,
    lostBy: r.data['lostBy'] as String? ?? '',
    lostAt: DateTime.fromMillisecondsSinceEpoch(
      (r.data['lostAt'] as num?)?.toInt() ?? 0,
    ),
    keptBy: r.data['keptBy'] as String? ?? '',
    keptAt: DateTime.fromMillisecondsSinceEpoch(
      (r.data['keptAt'] as num?)?.toInt() ?? 0,
    ),
  );

  /// [lost] gave way to [kept] (both versions of the same record).
  factory SyncConflict.between({
    required SyncRecord lost,
    required SyncRecord kept,
  }) => SyncConflict(
    // Ids may have at most 64 characters.
    id: 'cf${_hash('${lost.collection}/${lost.id}/${kept.updatedAt}/${lost.updatedAt}')}',
    collection: lost.collection,
    recordId: lost.id,
    lost: lost.deleted ? const {} : lost.data,
    lostDeleted: lost.deleted,
    lostBy: lost.updatedBy ?? '',
    lostAt: DateTime.fromMillisecondsSinceEpoch(lost.updatedAt),
    keptBy: kept.updatedBy ?? '',
    keptAt: DateTime.fromMillisecondsSinceEpoch(kept.updatedAt),
  );

  final String id;

  /// Where the record lives and its id.
  final String collection;
  final String recordId;

  /// The version that lost (its data; empty if it was a deletion).
  final Map<String, Object?> lost;
  final bool lostDeleted;
  final String lostBy;
  final DateTime lostAt;

  /// Who wrote the version that stayed.
  final String keptBy;
  final DateTime keptAt;

  /// 16 hex digits (two FNV-1a hashes), the same in Dart VM and browser.
  static String _hash(String s) {
    var a = 0x811c9dc5, b = 0x01000193;
    for (final c in s.codeUnits) {
      a = ((a ^ c) * 0x01000193) & 0xffffffff;
      b = ((b ^ c) * 0x811c9dc5 + 7) & 0xffffffff;
    }
    return a.toRadixString(16).padLeft(8, '0') +
        b.toRadixString(16).padLeft(8, '0');
  }

  Map<String, Object?> toData({List<String>? audience}) => {
    'collection': collection,
    'recordId': recordId,
    'lost': lost,
    'lostDeleted': lostDeleted,
    'lostBy': lostBy,
    'lostAt': lostAt.millisecondsSinceEpoch,
    'keptBy': keptBy,
    'keptAt': keptAt.millisecondsSinceEpoch,
    SyncRecord.visibilityKey: ?audience,
  };
}
