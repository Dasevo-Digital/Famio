import 'package:famio_client/famio_client.dart';

import 'family_data.dart';
import 'search.dart';

/// What the family buys: suggestions while typing and as quick picks, and
/// staples that go back on the list by themselves.
extension ShoppingHistory on SyncEngine {
  List<BoughtItem> get boughtItems =>
      records(Collections.shoppingHistory).map(BoughtItem.fromRecord).toList();

  BoughtItem? boughtItem(String key) {
    final r = record(Collections.shoppingHistory, key);
    return r == null ? null : BoughtItem.fromRecord(r);
  }

  void saveBoughtItem(BoughtItem item) =>
      put(Collections.shoppingHistory, item.key, item.toData());

  void forgetBoughtItem(String key) => delete(Collections.shoppingHistory, key);

  /// Puts [item] on its list the way Bring! does: an entry of the same
  /// name that is ticked off comes back (with the new amount, if any)
  /// instead of a second one, and one still open stays as it is – also so
  /// a linked Bring! list does not count it twice. Returns whether it was
  /// open already.
  bool putOnList(ShoppingItem item) {
    final key = shoppingKey(item.name);
    final same = [
      for (final i in shoppingItems(item.listId))
        if (shoppingKey(i.name) == key && i.memberId == item.memberId) i,
    ];
    if (same.any((i) => !i.checked)) return true;
    final done = same.firstOrNull;
    saveShoppingItem(
      done == null
          ? item
          : done.copyWith(
              checked: false,
              quantity: item.quantity.isEmpty ? null : item.quantity,
            ),
    );
    return false;
  }

  /// Counts [item] as bought when it is ticked off (not on packing lists).
  void noteBought(ShoppingItem item, {DateTime? now}) {
    final key = shoppingKey(item.name);
    final list = shoppingList(item.listId);
    // The history is the whole family's: what is bought from a list only
    // some see stays out of everybody's suggestions.
    if (key.isEmpty || list == null || list.packing || list.visibleTo != null) {
      return;
    }
    final before =
        boughtItem(key) ?? BoughtItem(key: key, name: item.name.trim());
    saveBoughtItem(
      before.copyWith(
        name: item.name.trim(),
        quantity: item.quantity.trim(),
        count: before.count + 1,
        lastBought: now ?? DateTime.now(),
        listId: item.listId,
      ),
    );
  }

  /// For list [listId]: what matches [typed] (names starting with it first)
  /// or, with nothing typed, what the family buys most, recent buys weighing
  /// more. Never what is open on the list already.
  List<BoughtItem> shoppingSuggestions(
    String listId, {
    String typed = '',
    DateTime? now,
    int max = 8,
  }) {
    final open = {
      for (final i in shoppingItems(listId))
        if (!i.checked) shoppingKey(i.name),
    };
    final t = foldForSearch(typed.trim());
    final today = now ?? DateTime.now();
    double score(BoughtItem b) {
      final days = b.lastBought == null
          ? 365
          : today.difference(b.lastBought!).inDays;
      return b.count / (1 + days / 30);
    }

    final found = [
      for (final b in boughtItems)
        if (b.count > 0 &&
            !open.contains(b.key) &&
            (t.isEmpty || foldForSearch(b.name).contains(t)))
          b,
    ];
    found.sort((a, b) {
      if (t.isNotEmpty) {
        final aStarts = foldForSearch(a.name).startsWith(t);
        final bStarts = foldForSearch(b.name).startsWith(t);
        if (aStarts != bStarts) return aStarts ? -1 : 1;
      }
      return score(b).compareTo(score(a));
    });
    return found.take(max).toList();
  }

  /// Puts the staples that are due back on their list (or the first one),
  /// unless they are on it already; returns how many were added. Marks them,
  /// so other devices do not add them again.
  int addDueStaples({DateTime? now}) {
    final moment = now ?? DateTime.now();
    final today = DateTime(moment.year, moment.month, moment.day);
    final lists = [
      for (final l in shoppingLists)
        if (!l.packing) l,
    ];
    if (lists.isEmpty) return 0;
    final learned = learnedShoppingCategories;
    var added = 0;
    for (final b in boughtItems) {
      final due = b.nextDue;
      if (due == null || due.isAfter(today)) continue;
      final list = lists.firstWhere(
        (l) => l.id == b.listId,
        orElse: () => lists.first,
      );
      final open = putOnList(
        ShoppingItem(
          // The same on every device: phones that open the list before they
          // heard of each other write one entry, not one each.
          id: _stapleId(b.key, due),
          listId: list.id,
          name: b.name,
          quantity: b.quantity,
          category: guessShoppingCategory(b.name, learned: learned),
        ),
      );
      if (!open) added++;
      saveBoughtItem(b.copyWith(lastAdded: moment));
    }
    return added;
  }
}

/// The entry a staple due on [due] becomes: from its name and the day.
String _stapleId(String key, DateTime due) {
  // djb2 kept below 2^31: the same on phones, desktops and in the browser
  // (String.hashCode is not, and bigger products lose bits in JavaScript).
  var hash = 5381;
  for (final unit in key.codeUnits) {
    hash = (hash * 33 + unit) % 0x7fffffff;
  }
  return 'staple-${dayKey(due)}-${hash.toRadixString(16)}';
}
