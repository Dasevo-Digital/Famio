import '../sync_record.dart';

/// Conversations need no records of their own: the family chat has a fixed
/// id, and every pair of members has a direct chat whose id derives from both
/// member ids.
abstract final class ChatIds {
  static const family = 'family';

  /// Direct chat between two members; the same id from either side.
  static String direct(String a, String b) {
    final pair = [a, b]..sort();
    return 'dm-${_short(pair[0])}-${_short(pair[1])}';
  }

  static String _short(String id) =>
      id.replaceAll('-', '').padRight(16, '0').substring(0, 16);

  static bool isDirect(String chatId) => chatId.startsWith('dm-');
}

/// A chat message, stored in `Collections.chatMessages`. Direct messages
/// carry `visibleTo` with both members, so the server only delivers them
/// (and their attachments) to those two.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.chatId,
    required this.authorId,
    required this.sentAt,
    this.text = '',
    this.attachment,
    this.visibleTo,
  });

  factory ChatMessage.fromRecord(SyncRecord r) => ChatMessage(
    id: r.id,
    chatId: r.data['chatId'] as String? ?? ChatIds.family,
    authorId: r.data['authorId'] as String? ?? r.updatedBy ?? '',
    sentAt:
        DateTime.tryParse(r.data['sentAt'] as String? ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(r.updatedAt),
    text: r.data['text'] as String? ?? '',
    attachment: FileRef.fromJson(r.data['attachment']),
    visibleTo: r.visibleTo,
  );

  final String id;
  final String chatId;
  final String authorId;
  final DateTime sentAt;
  final String text;
  final FileRef? attachment;
  final List<String>? visibleTo;

  Map<String, Object?> toData() => {
    'chatId': chatId,
    'authorId': authorId,
    'sentAt': sentAt.toUtc().toIso8601String(),
    'text': text,
    'attachment': attachment?.toJson(),
    SyncRecord.visibilityKey: visibleTo,
  };
}

/// How far a member has read a chat, stored in `Collections.chatReads`
/// (id from [idFor]) with the same audience as the chat.
class ChatRead {
  const ChatRead({
    required this.chatId,
    required this.memberId,
    required this.lastRead,
  });

  factory ChatRead.fromRecord(SyncRecord r) => ChatRead(
    chatId: r.data['chatId'] as String? ?? '',
    memberId: r.data['memberId'] as String? ?? '',
    lastRead:
        DateTime.tryParse(r.data['lastRead'] as String? ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  final String chatId;
  final String memberId;
  final DateTime lastRead;

  /// Stable on every device: at most 2 + 36 + 1 + 16 = 55 characters.
  static String idFor(String chatId, String memberId) =>
      'r-$chatId-${ChatIds._short(memberId)}';

  Map<String, Object?> toData({List<String>? visibleTo}) => {
    'chatId': chatId,
    'memberId': memberId,
    'lastRead': lastRead.toUtc().toIso8601String(),
    SyncRecord.visibilityKey: visibleTo,
  };
}

/// Reference to an uploaded file (see `POST /api/files`).
class FileRef {
  const FileRef({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
  });

  static FileRef? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    return FileRef(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'datei',
      mime: json['mime'] as String? ?? 'application/octet-stream',
      size: json['size'] as int? ?? 0,
    );
  }

  final String id;
  final String name;
  final String mime;
  final int size;

  bool get isImage => mime.startsWith('image/');

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'mime': mime,
    'size': size,
  };
}
