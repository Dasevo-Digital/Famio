import '../sync_record.dart';

/// A wish on a member's wish list (birthday, Christmas …).
class Wish {
  const Wish({
    required this.id,
    required this.ownerId,
    required this.title,
    this.link = '',
    this.price = '',
    this.note = '',
    this.received = false,
    this.createdAt,
  });

  factory Wish.fromRecord(SyncRecord r) => Wish(
    id: r.id,
    ownerId: r.data['ownerId'] as String? ?? '',
    title: r.data['title'] as String? ?? '',
    link: r.data['link'] as String? ?? '',
    price: r.data['price'] as String? ?? '',
    note: r.data['note'] as String? ?? '',
    received: r.data['received'] as bool? ?? false,
    createdAt: DateTime.tryParse(r.data['createdAt'] as String? ?? ''),
  );

  final String id;

  /// Whose wish it is.
  final String ownerId;
  final String title;
  final String link;

  /// Free text ("ca. 20 €").
  final String price;
  final String note;

  /// Got it: off the list for the others.
  final bool received;
  final DateTime? createdAt;

  Map<String, Object?> toData() => {
    'ownerId': ownerId,
    'title': title,
    'link': link,
    'price': price,
    'note': note,
    'received': received,
    'createdAt': createdAt?.toUtc().toIso8601String(),
  };
}

/// "I'll get that": record id = the wish's id. Visible to everyone except
/// the wish's owner, so the surprise stays one.
class WishClaim {
  const WishClaim({required this.wishId, required this.claimedBy});

  factory WishClaim.fromRecord(SyncRecord r) =>
      WishClaim(wishId: r.id, claimedBy: r.data['claimedBy'] as String? ?? '');

  final String wishId;
  final String claimedBy;

  /// The data to store; [audience]: all members but the wish's owner.
  Map<String, Object?> toData(List<String> audience) => {
    'claimedBy': claimedBy,
    SyncRecord.visibilityKey: audience,
  };
}
