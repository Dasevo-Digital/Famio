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
  });

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
  );

  final String id;
  final String title;
  final String text;
  final List<FileRef> files;
  final DateTime? createdAt;
  final String? createdBy;

  Map<String, Object?> toData() => {
    'title': title,
    'text': text,
    if (files.isNotEmpty) 'files': [for (final file in files) file.toJson()],
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'createdBy': ?createdBy,
  };
}
