import 'package:famio_client/famio_client.dart';

import 'birthdays.dart';

/// Typed access to the generic records, one section per module.
extension FamilyData on SyncEngine {
  // --- tasks ----------------------------------------------------------------

  List<Task> get tasks =>
      records(Collections.tasks).map(Task.fromRecord).toList();

  void saveTask(Task task) => put(Collections.tasks, task.id, task.toData());

  void deleteTask(String id) => delete(Collections.tasks, id);

  // --- shopping -------------------------------------------------------------

  List<ShoppingList> get shoppingLists =>
      records(Collections.shoppingLists).map(ShoppingList.fromRecord).toList()
        ..sort((a, b) {
          final bySort = a.sort.compareTo(b.sort);
          return bySort != 0
              ? bySort
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

  ShoppingList? shoppingList(String id) {
    final r = record(Collections.shoppingLists, id);
    return r == null ? null : ShoppingList.fromRecord(r);
  }

  List<ShoppingItem> shoppingItems(String listId) =>
      records(
          Collections.shoppingItems,
        ).map(ShoppingItem.fromRecord).where((i) => i.listId == listId).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Which aisle the family put each article in, newest choice first
  /// ([shoppingKey] → category key).
  Map<String, String> get learnedShoppingCategories {
    final rows = records(Collections.shoppingItems).toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final corrected =
        record(
          Collections.shoppingAisles,
          Collections.shoppingAislesId,
        )?.data ??
        const {};
    return {
      for (final r in rows)
        if (ShoppingItem.fromRecord(r) case final i
            when i.category.isNotEmpty && shoppingCategory(i.category) != null)
          shoppingKey(i.name): i.category,
      // Chosen by hand: wins, also after the items are gone.
      for (final e in corrected.entries)
        if (e.value is String && shoppingCategory(e.value as String) != null)
          e.key: e.value as String,
    };
  }

  /// Remembers that [name] belongs in [category] for the whole family.
  void rememberShoppingCategory(String name, String category) {
    final key = shoppingKey(name);
    if (key.isEmpty) return;
    final current =
        record(
          Collections.shoppingAisles,
          Collections.shoppingAislesId,
        )?.data ??
        const {};
    if (current[key] == category) return;
    put(Collections.shoppingAisles, Collections.shoppingAislesId, {
      ...current,
      key: category,
    });
  }

  /// [item]'s aisle: as stored, else guessed (e.g. from Bring! or older
  /// versions).
  String shoppingCategoryOf(
    ShoppingItem item, [
    Map<String, String>? learned,
  ]) => shoppingCategory(item.category) != null
      ? item.category
      : guessShoppingCategory(
          item.name,
          learned: learned ?? learnedShoppingCategories,
        );

  void saveShoppingList(ShoppingList list) =>
      put(Collections.shoppingLists, list.id, list.toData());

  void saveShoppingItem(ShoppingItem item) =>
      put(Collections.shoppingItems, item.id, item.toData());

  void deleteShoppingItem(String id) => delete(Collections.shoppingItems, id);

  /// Deletes the list together with its items.
  void deleteShoppingList(String id) {
    for (final item in shoppingItems(id)) {
      deleteShoppingItem(item.id);
    }
    delete(Collections.shoppingLists, id);
  }

  // --- calendar -------------------------------------------------------------

  List<CalendarEvent> get events =>
      records(Collections.events).map(CalendarEvent.fromRecord).toList();

  CalendarEvent? event(String id) {
    final r = record(Collections.events, id);
    return r == null ? null : CalendarEvent.fromRecord(r);
  }

  void saveEvent(CalendarEvent event) =>
      put(Collections.events, event.id, event.toData());

  void deleteEvent(String id) => delete(Collections.events, id);

  /// Read-only events imported from subscribed calendars. Leftovers of a
  /// subscription deleted on this device are hidden until the server cleans
  /// them up.
  List<CalendarEvent> get externalEvents {
    final subscriptions = {for (final s in calendarSubscriptions) s.id};
    return [
      for (final r in records(Collections.externalEvents))
        if (subscriptions.contains(r.data['sourceId']) ||
            isCalDavSource(r.data['sourceId'] as String?))
          CalendarEvent.fromRecord(r),
    ];
  }

  List<CalendarSubscription> get calendarSubscriptions =>
      records(
          Collections.calendarSubscriptions,
        ).map(CalendarSubscription.fromRecord).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Read-only events of a two-way synced calendar (iCloud …) that Famio
  /// cannot edit without losing details.
  static bool isCalDavSource(String? sourceId) =>
      sourceId?.startsWith('caldav:') ?? false;

  CalendarSubscription? calendarSubscription(String? id) {
    final r = id == null ? null : record(Collections.calendarSubscriptions, id);
    return r == null ? null : CalendarSubscription.fromRecord(r);
  }

  SubscriptionStatus? subscriptionStatus(String id) {
    final r = record(Collections.calendarSyncStatus, id);
    return r == null ? null : SubscriptionStatus.fromRecord(r);
  }

  void saveCalendarSubscription(CalendarSubscription s) =>
      put(Collections.calendarSubscriptions, s.id, s.toData());

  void deleteCalendarSubscription(String id) =>
      delete(Collections.calendarSubscriptions, id);

  /// All occurrences (own and imported) overlapping `[from, to)`; all-day
  /// ones first per start.
  List<Occurrence> occurrences(DateTime from, DateTime to) =>
      [
        for (final e in [...events, ...externalEvents, ...birthdayEvents(this)])
          ...e.occurrencesBetween(from, to),
      ]..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        if (byStart != 0) return byStart;
        if (a.event.allDay != b.event.allDay) return a.event.allDay ? -1 : 1;
        return a.event.title.compareTo(b.event.title);
      });

  // --- chat ---------------------------------------------------------------

  List<ChatMessage> chatMessages(String chatId) =>
      records(
          Collections.chatMessages,
        ).map(ChatMessage.fromRecord).where((m) => m.chatId == chatId).toList()
        ..sort((a, b) => a.sentAt.compareTo(b.sentAt));

  /// Audience of a chat: null (everyone) for the family chat.
  List<String>? chatAudience(String chatId) {
    if (!ChatIds.isDirect(chatId)) return null;
    final other = members.where(
      (m) => m.id != memberId && ChatIds.direct(memberId, m.id) == chatId,
    );
    return [memberId, ...other.map((m) => m.id)];
  }

  void sendChatMessage(String chatId, {String text = '', FileRef? attachment}) {
    final message = ChatMessage(
      id: newId(),
      chatId: chatId,
      authorId: memberId,
      sentAt: DateTime.now(),
      text: text,
      attachment: attachment,
      visibleTo: chatAudience(chatId),
    );
    put(Collections.chatMessages, message.id, message.toData());
    markChatRead(chatId, at: message.sentAt);
  }

  void deleteChatMessage(String id) => delete(Collections.chatMessages, id);

  DateTime lastRead(String chatId, [String? member]) {
    final r = record(
      Collections.chatReads,
      ChatRead.idFor(chatId, member ?? memberId),
    );
    return r == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : ChatRead.fromRecord(r).lastRead;
  }

  void markChatRead(String chatId, {DateTime? at}) {
    final time = at ?? DateTime.now();
    if (!time.isAfter(lastRead(chatId))) return;
    final read = ChatRead(chatId: chatId, memberId: memberId, lastRead: time);
    put(
      Collections.chatReads,
      ChatRead.idFor(chatId, memberId),
      read.toData(visibleTo: chatAudience(chatId)),
    );
  }

  int unreadCount(String chatId) {
    final since = lastRead(chatId);
    return chatMessages(
      chatId,
    ).where((m) => m.authorId != memberId && m.sentAt.isAfter(since)).length;
  }

  int get totalUnread => [
    ChatIds.family,
    for (final m in members)
      if (m.id != memberId) ChatIds.direct(memberId, m.id),
  ].fold(0, (sum, chat) => sum + unreadCount(chat));

  // --- documents ------------------------------------------------------------

  List<FamilyDocument> get documents =>
      records(Collections.documents).map(FamilyDocument.fromRecord).toList()
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );

  void saveDocument(FamilyDocument d) =>
      put(Collections.documents, d.id, d.toData());

  void deleteDocument(String id) => delete(Collections.documents, id);

  // --- kids -----------------------------------------------------------------

  List<Child> get children =>
      records(Collections.children).map(Child.fromRecord).toList()
        ..sort((a, b) => a.birthDate.compareTo(b.birthDate));

  Child? child(String id) {
    final r = record(Collections.children, id);
    return r == null ? null : Child.fromRecord(r);
  }

  /// Development, check-ups, vaccinations and photos are health data: only
  /// the child's guardians see them (enforced by the server). Without
  /// guardians the whole family does.
  static List<String>? _childAudience(Child? c) =>
      c == null || c.guardianIds.isEmpty ? null : c.guardianIds;

  void saveChild(Child c) {
    final audience = _childAudience(c);
    put(Collections.children, c.id, {
      ...c.toData(),
      SyncRecord.visibilityKey: audience,
    });
    for (final e in childEntries(c.id)) {
      _putChildEntry(e, audience);
    }
    for (final l in childLogs(c.id)) {
      _putChildLog(l, audience);
    }
  }

  /// Applies the guardian-only visibility to records written before it
  /// existed. Only guardians do this: anyone else saving would be added to
  /// the audience as author.
  void applyChildVisibility() {
    for (final c in children) {
      final audience = _childAudience(c);
      if (audience == null || !audience.contains(memberId)) continue;
      final stale =
          !_sameAudience(
            record(Collections.children, c.id)?.visibleTo,
            audience,
          ) ||
          childEntries(c.id).any(
            (e) => !_sameAudience(
              record(Collections.childEntries, e.id)?.visibleTo,
              audience,
            ),
          ) ||
          childLogs(c.id).any(
            (l) => !_sameAudience(
              record(Collections.childLogs, l.id)?.visibleTo,
              audience,
            ),
          );
      if (stale) saveChild(c);
    }
  }

  static bool _sameAudience(List<String>? a, List<String>? b) =>
      (a == null && b == null) ||
      (a != null &&
          b != null &&
          a.toSet().containsAll(b) &&
          b.toSet().containsAll(a));

  /// Deletes the child together with all its entries.
  void deleteChild(String id) {
    for (final e in childEntries(id)) {
      delete(Collections.childEntries, e.id);
    }
    for (final l in childLogs(id)) {
      delete(Collections.childLogs, l.id);
    }
    delete(Collections.children, id);
  }

  List<ChildEntry> childEntries(String childId) =>
      records(
          Collections.childEntries,
        ).map(ChildEntry.fromRecord).where((e) => e.childId == childId).toList()
        ..sort((a, b) => a.date.compareTo(b.date));

  void saveChildEntry(ChildEntry e) =>
      _putChildEntry(e, _childAudience(child(e.childId)));

  void _putChildEntry(ChildEntry e, List<String>? audience) => put(
    Collections.childEntries,
    e.id,
    {...e.toData(), SyncRecord.visibilityKey: audience},
  );

  void deleteChildEntry(String id) => delete(Collections.childEntries, id);

  /// The child's daily log, newest first.
  List<ChildLog> childLogs(String childId) =>
      records(
          Collections.childLogs,
        ).map(ChildLog.fromRecord).where((l) => l.childId == childId).toList()
        ..sort((a, b) => b.start.compareTo(a.start));

  void saveChildLog(ChildLog l) =>
      _putChildLog(l, _childAudience(child(l.childId)));

  void _putChildLog(ChildLog l, List<String>? audience) => put(
    Collections.childLogs,
    l.id,
    {...l.toData(), SyncRecord.visibilityKey: audience},
  );

  void deleteChildLog(String id) => delete(Collections.childLogs, id);

  // --- pregnancies ----------------------------------------------------------

  List<Pregnancy> get pregnancies =>
      records(Collections.pregnancies).map(Pregnancy.fromRecord).toList()
        ..sort((a, b) => a.dueDate.compareTo(b.dueDate));

  /// Pregnancies not yet ended by a birth.
  List<Pregnancy> get activePregnancies =>
      pregnancies.where((p) => !p.born).toList();

  Pregnancy? pregnancy(String id) {
    final r = record(Collections.pregnancies, id);
    return r == null ? null : Pregnancy.fromRecord(r);
  }

  /// Health data like the children's: only the chosen members see it.
  void savePregnancy(Pregnancy p) => put(Collections.pregnancies, p.id, {
    ...p.toData(),
    SyncRecord.visibilityKey: p.guardianIds.isEmpty ? null : p.guardianIds,
  });

  void deletePregnancy(String id) => delete(Collections.pregnancies, id);

  // --- meals ----------------------------------------------------------------

  List<Recipe> get recipes =>
      records(Collections.recipes).map(Recipe.fromRecord).toList()..sort(
        (a, b) => a.favorite != b.favorite
            ? (a.favorite ? -1 : 1)
            : a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );

  Recipe? recipe(String? id) {
    final r = id == null ? null : record(Collections.recipes, id);
    return r == null ? null : Recipe.fromRecord(r);
  }

  void saveRecipe(Recipe r) => put(Collections.recipes, r.id, r.toData());

  void deleteRecipe(String id) => delete(Collections.recipes, id);

  /// Planned meals between [from] and [to] (exclusive), by day and slot.
  List<PlannedMeal> plannedMeals(DateTime from, DateTime to) =>
      records(Collections.mealPlan)
          .map(PlannedMeal.fromRecord)
          .where((m) => !m.date.isBefore(from) && m.date.isBefore(to))
          .toList()
        ..sort((a, b) {
          final byDay = a.date.compareTo(b.date);
          return byDay != 0 ? byDay : a.slot.index.compareTo(b.slot.index);
        });

  void saveMeal(PlannedMeal m) => put(Collections.mealPlan, m.id, m.toData());

  void deleteMeal(String id) => delete(Collections.mealPlan, id);

  /// Puts [items] on the list [listId]: open items of the same name get the
  /// amount added (same unit) or appended.
  int addToShoppingList(String listId, List<Ingredient> items) {
    var added = 0;
    final open = {
      for (final i in shoppingItems(listId))
        if (!i.checked) i.name.trim().toLowerCase(): i,
    };
    for (final item in items) {
      if (item.name.trim().isEmpty) continue;
      final key = item.name.trim().toLowerCase();
      final existing = open[key];
      if (existing == null) {
        final created = ShoppingItem(
          id: newId(),
          listId: listId,
          name: item.name.trim(),
          quantity: item.quantity(),
        );
        saveShoppingItem(created);
        open[key] = created;
        added++;
        continue;
      }
      final before = Ingredient.parse('${existing.quantity} x');
      final quantity =
          before.amount != null &&
              item.amount != null &&
              before.unit.toLowerCase() == item.unit.toLowerCase()
          ? Ingredient(
              name: item.name,
              amount: before.amount! + item.amount!,
              unit: item.unit,
            ).quantity()
          : [
              existing.quantity,
              item.quantity(),
            ].where((q) => q.isNotEmpty).join(' + ');
      final updated = existing.copyWith(quantity: quantity);
      saveShoppingItem(updated);
      open[key] = updated;
    }
    return added;
  }

  // --- timetables ------------------------------------------------------------

  Timetable? timetable(String childId) {
    final r = record(Collections.timetables, childId);
    return r == null ? null : Timetable.fromRecord(r);
  }

  /// Visible like the child.
  void saveTimetable(Timetable t) => put(Collections.timetables, t.childId, {
    ...t.toData(),
    SyncRecord.visibilityKey: _childAudience(child(t.childId)),
  });

  // --- budget ----------------------------------------------------------------

  BudgetSettings get budgetSettings => BudgetSettings.fromRecord(
    record(Collections.budgetSettings, BudgetSettings.recordId),
  );

  List<String>? get _budgetAudience {
    final ids = budgetSettings.memberIds;
    return ids.isEmpty ? null : ids;
  }

  /// Changing who sees the budget moves all entries along.
  void saveBudgetSettings(BudgetSettings s) {
    final audience = s.memberIds.isEmpty ? null : s.memberIds;
    put(Collections.budgetSettings, BudgetSettings.recordId, {
      ...s.toData(),
      SyncRecord.visibilityKey: audience,
    });
    for (final e in budgetEntries) {
      put(Collections.budgetEntries, e.id, {
        ...e.toData(),
        SyncRecord.visibilityKey: audience,
      });
    }
  }

  List<BudgetEntry> get budgetEntries =>
      records(Collections.budgetEntries).map(BudgetEntry.fromRecord).toList()
        ..sort((a, b) => b.date.compareTo(a.date));

  void saveBudgetEntry(BudgetEntry e) => put(Collections.budgetEntries, e.id, {
    ...e.toData(),
    SyncRecord.visibilityKey: _budgetAudience,
  });

  void deleteBudgetEntry(String id) => delete(Collections.budgetEntries, id);

  // --- contacts -------------------------------------------------------------

  List<FamilyContact> get contacts =>
      records(Collections.contacts).map(FamilyContact.fromRecord).toList()
        ..sort((a, b) {
          final byRole = a.role.index.compareTo(b.role.index);
          return byRole != 0
              ? byRole
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

  FamilyContact? contact(String? id) {
    final r = id == null ? null : record(Collections.contacts, id);
    return r == null ? null : FamilyContact.fromRecord(r);
  }

  void saveContact(FamilyContact c) =>
      put(Collections.contacts, c.id, c.toData());

  void deleteContact(String id) => delete(Collections.contacts, id);

  // --- members --------------------------------------------------------------

  FamilyMember? member(String? id) =>
      id == null ? null : allMembers.where((m) => m.id == id).firstOrNull;

  // --- location -----------------------------------------------------------

  List<Place> get places =>
      records(Collections.places).map(Place.fromRecord).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Place? place(String? id) {
    final r = id == null ? null : record(Collections.places, id);
    return r == null ? null : Place.fromRecord(r);
  }

  void savePlace(Place place) =>
      put(Collections.places, place.id, place.toData());

  void deletePlace(String id) => delete(Collections.places, id);

  /// Last position and sharing status per member id.
  Map<String, MemberLocation> get memberLocations => {
    for (final r in records(Collections.memberLocations))
      r.id: MemberLocation.fromRecord(r),
  };

  List<LocationAlert> get locationAlerts =>
      records(Collections.locationAlerts).map(LocationAlert.fromRecord).toList()
        ..sort((a, b) => b.at.compareTo(a.at));
}
