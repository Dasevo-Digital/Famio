import 'package:famio_client/famio_client.dart';

import 'family_data.dart';

/// The open items of [list] as plain text, for someone without Famio:
/// sorted by aisle like on screen (headings only with more than one),
/// amounts first; on packing lists whose thing it is.
///
///     Wocheneinkauf
///
///     Obst & Gemüse
///     • 3 Äpfel
///     Kühlregal
///     • 2 l Milch
String shoppingListText(SyncEngine engine, ShoppingList list) {
  final open = [
    for (final i in engine.shoppingItems(list.id))
      if (!i.checked) i,
  ];
  String line(ShoppingItem i) {
    final owner = list.packing && i.memberId != null
        ? engine.member(i.memberId!)?.displayName
        : null;
    return [
      '•',
      if (i.quantity.trim().isNotEmpty) i.quantity.trim(),
      i.name.trim(),
      if (owner != null) '($owner)',
    ].join(' ');
  }

  final out = [list.name, ''];
  if (list.packing) {
    out.addAll([for (final i in open) line(i)]);
  } else {
    final learned = engine.learnedShoppingCategories;
    final byAisle = <String, List<ShoppingItem>>{
      for (final c in shoppingCategories) c.key: [],
    };
    for (final i in open) {
      byAisle[engine.shoppingCategoryOf(i, learned)]?.add(i);
    }
    final aisles = [
      for (final e in byAisle.entries)
        if (e.value.isNotEmpty) e,
    ];
    for (final aisle in aisles) {
      if (aisles.length > 1) {
        out.add(shoppingCategory(aisle.key)?.label ?? aisle.key);
      }
      out.addAll([for (final i in aisle.value) line(i)]);
    }
  }
  return out.join('\n').trimRight();
}
