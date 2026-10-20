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

  /// Counts [item] as bought when it is ticked off (not on packing lists).
  void noteBought(ShoppingItem item, {DateTime? now}) {
    final key = shoppingKey(item.name);
    if (key.isEmpty || (shoppingList(item.listId)?.packing ?? false)) return;
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
      final onList = shoppingItems(
        list.id,
      ).any((i) => !i.checked && shoppingKey(i.name) == b.key);
      if (!onList) {
        saveShoppingItem(
          ShoppingItem(
            id: newId(),
            listId: list.id,
            name: b.name,
            quantity: b.quantity,
            category: guessShoppingCategory(b.name, learned: learned),
          ),
        );
        added++;
      }
      saveBoughtItem(b.copyWith(lastAdded: moment));
    }
    return added;
  }
}
