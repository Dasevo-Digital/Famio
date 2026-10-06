import '../sync_record.dart';

/// A note on the family's pinboard (Wi-Fi for guests, babysitter info,
/// waste collection …), seen by [visibleTo] (everyone if null).
class FamilyNote {
  const FamilyNote({
    required this.id,
    required this.title,
    this.text = '',
    this.pinned = false,
    this.color,
    this.visibleTo,
    this.updatedAt,
  });

  factory FamilyNote.fromRecord(SyncRecord r) => FamilyNote(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    text: r.data['text'] as String? ?? '',
    pinned: r.data['pinned'] as bool? ?? false,
    color: (r.data['color'] as num?)?.toInt(),
    visibleTo: r.visibleTo,
    updatedAt: r.updatedAt == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r.updatedAt),
  );

  final String id;
  final String title;
  final String text;

  /// Shown on the start page.
  final bool pinned;

  /// ARGB of the paper; null: the default.
  final int? color;
  final List<String>? visibleTo;
  final DateTime? updatedAt;

  Map<String, Object?> toData() => {
    'title': title,
    'text': text,
    'pinned': pinned,
    'color': color,
    SyncRecord.visibilityKey: visibleTo,
  };
}
