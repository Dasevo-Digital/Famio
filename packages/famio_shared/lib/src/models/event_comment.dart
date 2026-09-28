import '../sync_record.dart';

/// A comment on a calendar event (`Collections.eventComments`), e.g. "Wer
/// bringt den Kuchen mit?". Visible to everyone who sees the event.
class EventComment {
  const EventComment({
    required this.id,
    required this.eventId,
    required this.authorId,
    required this.at,
    required this.text,
  });

  factory EventComment.fromRecord(SyncRecord r) => EventComment(
    id: r.id,
    eventId: r.data['eventId'] as String? ?? '',
    authorId: r.data['authorId'] as String? ?? r.updatedBy ?? '',
    at:
        DateTime.tryParse(r.data['at'] as String? ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(r.updatedAt),
    text: r.data['text'] as String? ?? '',
  );

  final String id;
  final String eventId;
  final String authorId;
  final DateTime at;
  final String text;

  Map<String, Object?> toData() => {
    'eventId': eventId,
    'authorId': authorId,
    'at': at.toUtc().toIso8601String(),
    'text': text,
  };
}
