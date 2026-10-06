import '../sync_record.dart';
import 'chat.dart';

enum DocumentCategory {
  identity('Ausweise & Pässe'),
  health('Gesundheit'),
  school('Schule & Kita'),
  insurance('Versicherungen'),
  finance('Finanzen & Steuern'),
  home('Haus & Wohnen'),
  contracts('Verträge'),

  /// Family photos; the wall display shows them as a screen saver.
  photos('Fotos'),
  other('Sonstiges');

  const DocumentCategory(this.label);

  final String label;
}

/// A family document, stored in `Collections.documents`. Its file is only
/// downloadable by members in [visibleTo] (everyone if null).
class FamilyDocument {
  const FamilyDocument({
    required this.id,
    required this.title,
    required this.category,
    required this.file,
    this.notes = '',
    this.memberIds = const [],
    this.expiresAt,
    this.visibleTo,
    this.createdAt,
  });

  factory FamilyDocument.fromRecord(SyncRecord r) => FamilyDocument(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    category:
        DocumentCategory.values
            .where((c) => c.name == r.data['category'])
            .firstOrNull ??
        DocumentCategory.other,
    file: FileRef.fromJson(r.data['file']),
    notes: r.data['notes'] as String? ?? '',
    memberIds: [
      for (final m in r.data['memberIds'] as List? ?? const []) m as String,
    ],
    expiresAt: _date(r.data['expiresAt']),
    visibleTo: r.visibleTo,
    createdAt: _date(r.data['createdAt']),
  );

  final String id;
  final String title;
  final DocumentCategory category;
  final FileRef? file;
  final String notes;

  /// Who the document is about (e.g. whose passport), for filtering.
  final List<String> memberIds;

  /// Expiry date (passport, ID card, contract) – reminded in advance.
  final DateTime? expiresAt;

  /// Members allowed to see it; null for the whole family.
  final List<String>? visibleTo;
  final DateTime? createdAt;

  Map<String, Object?> toData() => {
    'title': title,
    'category': category.name,
    'file': file?.toJson(),
    'notes': notes,
    'memberIds': memberIds,
    'expiresAt': expiresAt == null ? null : _day(expiresAt!),
    'createdAt': createdAt?.toUtc().toIso8601String(),
    SyncRecord.visibilityKey: visibleTo,
  };
}

DateTime? _date(Object? v) {
  final d = v is String ? DateTime.tryParse(v) : null;
  return d == null ? null : (d.isUtc ? d.toLocal() : d);
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
