import '../sync_record.dart';

/// A shopping list, stored in `Collections.shoppingLists`.
class ShoppingList {
  const ShoppingList({
    required this.id,
    required this.name,
    this.sort = 0,
    this.packing = false,
    this.eventId,
  });

  factory ShoppingList.fromRecord(SyncRecord r) => ShoppingList(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    sort: r.data['sort'] as int? ?? 0,
    packing: r.data['packing'] as bool? ?? false,
    eventId: r.data['eventId'] as String?,
  );

  final String id;
  final String name;
  final int sort;

  /// A packing list: grouped by person instead of the shop's aisles.
  final bool packing;

  /// The trip (calendar event) it is packed for; reminds the evening
  /// before it starts.
  final String? eventId;

  ShoppingList copyWith({String? name, int? sort}) => ShoppingList(
    id: id,
    name: name ?? this.name,
    sort: sort ?? this.sort,
    packing: packing,
    eventId: eventId,
  );

  Map<String, Object?> toData() => {
    'name': name,
    'sort': sort,
    if (packing) 'packing': true,
    'eventId': ?eventId,
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
