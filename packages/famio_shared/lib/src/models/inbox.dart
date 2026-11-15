import '../sync_record.dart';
import 'chat.dart' show FileRef;

/// An unsorted family item that can later become a task, event, note,
/// document or shopping item.
class InboxItem {
  const InboxItem({
    required this.id,
    required this.title,
    this.text = '',
    this.files = const [],
    this.createdAt,
    this.createdBy,
    this.forChildren = false,
  });

  /// Key of [forChildren] in the record (the server reads it).
  static const forChildrenKey = 'forChildren';

  factory InboxItem.fromRecord(SyncRecord r) => InboxItem(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    text: r.data['text'] as String? ?? '',
    files: [
      for (final file in r.data['files'] as List? ?? const [])
        ?FileRef.fromJson(file),
    ],
    createdAt: DateTime.tryParse(
      r.data['createdAt'] as String? ?? '',
    )?.toLocal(),
    createdBy: r.data['createdBy'] as String? ?? r.updatedBy,
    forChildren: r.data[forChildrenKey] == true,
  );

  final String id;
  final String title;
  final String text;
  final List<FileRef> files;
  final DateTime? createdAt;
  final String? createdBy;

  /// Whether children's accounts receive it: scanned letters are often
  /// about health or money, so only when the one filing it says so. A child
  /// always receives what it filed itself (see `RecordStore.canAccess`).
  final bool forChildren;

  Map<String, Object?> toData() => {
    'title': title,
    'text': text,
    if (files.isNotEmpty) 'files': [for (final file in files) file.toJson()],
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'createdBy': ?createdBy,
    if (forChildren) forChildrenKey: true,
  };
}
