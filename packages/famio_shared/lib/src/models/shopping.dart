import '../sync_record.dart';

/// A shopping list, stored in `Collections.shoppingLists`.
class ShoppingList {
  const ShoppingList({
    required this.id,
    required this.name,
    this.sort = 0,
    this.packing = false,
    this.eventId,
    this.visibleTo,
  });

  factory ShoppingList.fromRecord(SyncRecord r) => ShoppingList(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    sort: r.data['sort'] as int? ?? 0,
    packing: r.data['packing'] as bool? ?? false,
    eventId: r.data['eventId'] as String?,
    visibleTo: r.visibleTo,
  );

  final String id;
  final String name;
  final int sort;

  /// A packing list: grouped by person instead of the shop's aisles.
  final bool packing;

  /// The trip (calendar event) it is packed for; reminds the evening
  /// before it starts.
  final String? eventId;

  /// Who sees the list and its items (see [SyncRecord.visibleTo]); null:
  /// the whole family. The server gives every item its list's audience.
  final List<String>? visibleTo;

  ShoppingList copyWith({
    String? name,
    int? sort,
    List<String>? Function()? visibleTo,
  }) => ShoppingList(
    id: id,
    name: name ?? this.name,
    sort: sort ?? this.sort,
    packing: packing,
    eventId: eventId,
    visibleTo: visibleTo == null ? this.visibleTo : visibleTo(),
  );

  Map<String, Object?> toData() => {
    'name': name,
    'sort': sort,
    if (packing) 'packing': true,
    'eventId': ?eventId,
    // Always written: "the whole family" (null) lifts a restriction, while
    // older apps leave the key out and the server keeps what was set.
    SyncRecord.visibilityKey: visibleTo,
  };
}

/// An item on a shopping list, stored in `Collections.shoppingItems`.
///
/// Items are separate records (not embedded in the list) so two people can
/// tick off different items at the same time without conflicting.
class ShoppingItem {
  const ShoppingItem({
    required this.id,
    required this.listId,
    required this.name,
    this.quantity = '',
    this.checked = false,
    this.category = '',
    this.memberId,
  });

  factory ShoppingItem.fromRecord(SyncRecord r) => ShoppingItem(
    id: r.id,
    listId: r.data['listId'] as String? ?? '',
    name: r.data['name'] as String? ?? '',
    quantity: r.data['quantity'] as String? ?? '',
    checked: r.data['checked'] as bool? ?? false,
    category: r.data['category'] as String? ?? '',
    memberId: r.data['memberId'] as String?,
  );

  final String id;
  final String listId;
  final String name;
  final String quantity;
  final bool checked;
  final String category;

  /// Packing lists: whose thing it is; null for everyone's.
  final String? memberId;

  ShoppingItem copyWith({
    String? name,
    String? quantity,
    bool? checked,
    String? category,
  }) => ShoppingItem(
    id: id,
    listId: listId,
    name: name ?? this.name,
    quantity: quantity ?? this.quantity,
    checked: checked ?? this.checked,
    category: category ?? this.category,
    memberId: memberId,
  );

  Map<String, Object?> toData() => {
    'listId': listId,
    'name': name,
    'quantity': quantity,
    'checked': checked,
    'category': category,
    'memberId': ?memberId,
  };
}

/// An article the family buys, stored in `Collections.shoppingHistory`
/// (record id: `shoppingKey` of the name). Ticked items are deleted from the
/// lists, so this is what Famio remembers: how often, when last, and – for a
/// staple – after how many days it goes back on the list by itself.
class BoughtItem {
  const BoughtItem({
    required this.key,
    required this.name,
    this.quantity = '',
    this.count = 0,
    this.lastBought,
    this.listId,
    this.everyDays,
    this.lastAdded,
  });

  factory BoughtItem.fromRecord(SyncRecord r) => BoughtItem(
    key: r.id,
    name: r.data['name'] as String? ?? r.id,
    quantity: r.data['quantity'] as String? ?? '',
    count: (r.data['count'] as num?)?.toInt() ?? 0,
    lastBought: DateTime.tryParse(r.data['lastBought'] as String? ?? ''),
    listId: r.data['listId'] as String?,
    everyDays: (r.data['everyDays'] as num?)?.toInt(),
    lastAdded: DateTime.tryParse(r.data['lastAdded'] as String? ?? ''),
  );

  final String key;
  final String name;

  /// The amount bought last time ("2 l").
  final String quantity;
  final int count;
  final DateTime? lastBought;

  /// The list it was bought from last; staples go back there.
  final String? listId;

  /// A staple: back on the list this many days after it was last bought
  /// (or put back); null for none.
  final int? everyDays;

  /// When it was last put back on the list as a staple.
  final DateTime? lastAdded;

  /// When a staple is due again; null for others.
  DateTime? get nextDue {
    final days = everyDays;
    if (days == null || days <= 0) return null;
    final base = [
      ?lastBought,
      ?lastAdded,
    ].fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if (base == null) return null;
    final day = DateTime(base.year, base.month, base.day);
    return DateTime(day.year, day.month, day.day + days);
  }

  BoughtItem copyWith({
    String? name,
    String? quantity,
    int? count,
    DateTime? lastBought,
    String? listId,
    int? Function()? everyDays,
    DateTime? lastAdded,
  }) => BoughtItem(
    key: key,
    name: name ?? this.name,
    quantity: quantity ?? this.quantity,
    count: count ?? this.count,
    lastBought: lastBought ?? this.lastBought,
    listId: listId ?? this.listId,
    everyDays: everyDays == null ? this.everyDays : everyDays(),
    lastAdded: lastAdded ?? this.lastAdded,
  );

  Map<String, Object?> toData() => {
    'name': name,
    'quantity': quantity,
    'count': count,
    'lastBought': lastBought?.toUtc().toIso8601String(),
    'listId': listId,
    'everyDays': everyDays,
    'lastAdded': lastAdded?.toUtc().toIso8601String(),
  };
}
