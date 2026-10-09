import 'package:famio_client/famio_client.dart';

import 'family_data.dart';
import '../l10n.dart';

/// Typed access to the modules added in 0.13: chores, points and pocket
/// money, routines, event comments, polls, list templates, the pantry and
/// medication plans.
extension FamilyExtras on SyncEngine {
  /// The signed-in member (null until the member list arrived).
  FamilyMember? get me => member(memberId);

  MemberRole get myRole => me?.role ?? MemberRole.adult;

  bool get iAmAdult => myRole == MemberRole.adult;

  bool get iAmGuest => myRole == MemberRole.guest;

  List<FamilyMember> get kidMembers =>
      members.where((m) => m.role == MemberRole.child).toList();

  /// Who collects points: children, or everyone if the family has none.
  List<FamilyMember> get pointCollectors {
    final kids = kidMembers;
    return kids.isNotEmpty
        ? kids
        : members.where((m) => m.role != MemberRole.guest).toList();
  }

  // --- chores ---------------------------------------------------------------

  List<Chore> get chores =>
      records(Collections.chores).map(Chore.fromRecord).toList()..sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );

  void saveChore(Chore c) => put(Collections.chores, c.id, c.toData());

  void deleteChore(String id) => delete(Collections.chores, id);

  /// The entry recording that [chore] was done in the period of [day].
  PointEntry? choreCompletion(Chore chore, DateTime day) {
    final r = record(Collections.pointEntries, chore.completionId(day));
    return r == null ? null : PointEntry.fromRecord(r);
  }

  /// Ticks [chore] off for [memberId]: children ask for the points, adults
  /// get them right away.
  /// With [asRequest] (the shared wall display) adults confirm it later.
  void completeChore(
    Chore chore,
    DateTime day,
    String memberId, {
    bool asRequest = false,
  }) {
    final byChild =
        asRequest || (member(memberId)?.role == MemberRole.child && !iAmAdult);
    final entry = PointEntry(
      id: chore.completionId(day),
      memberId: memberId,
      points: chore.points,
      title: chore.title,
      kind: PointKind.chore,
      at: DateTime.now(),
      refId: chore.id,
      status: byChild ? PointStatus.pending : PointStatus.approved,
      decidedBy: byChild ? null : this.memberId,
    );
    put(Collections.pointEntries, entry.id, entry.toData());
  }

  void undoChore(Chore chore, DateTime day) =>
      delete(Collections.pointEntries, chore.completionId(day));

  // --- points & rewards -----------------------------------------------------

  List<PointEntry> get pointEntries =>
      records(Collections.pointEntries).map(PointEntry.fromRecord).toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  List<PointEntry> pointsOf(String memberId) =>
      pointEntries.where((e) => e.memberId == memberId).toList();

  int pointBalance(String memberId) => pointsOf(
    memberId,
  ).where((e) => e.counts).fold(0, (sum, e) => sum + e.points);

  /// Requests waiting for an adult.
  List<PointEntry> get pendingPoints =>
      pointEntries.where((e) => e.status == PointStatus.pending).toList();

  void savePointEntry(PointEntry e) =>
      put(Collections.pointEntries, e.id, e.toData());

  void deletePointEntry(String id) => delete(Collections.pointEntries, id);

  void decidePoints(PointEntry e, {required bool approve}) => savePointEntry(
    e.decide(approve ? PointStatus.approved : PointStatus.rejected, memberId),
  );

  List<Reward> get rewards =>
      records(Collections.rewards).map(Reward.fromRecord).toList()
        ..sort((a, b) => a.cost.compareTo(b.cost));

  void saveReward(Reward r) => put(Collections.rewards, r.id, r.toData());

  void deleteReward(String id) => delete(Collections.rewards, id);

  /// Exchanges points for [reward]: a wish for children, booked directly
  /// by adults.
  void redeem(Reward reward, String forMember) {
    final asRequest = !iAmAdult;
    final entry = PointEntry(
      id: newId(),
      memberId: forMember,
      points: -reward.cost,
      title: '${reward.emoji} ${reward.title}',
      kind: PointKind.reward,
      at: DateTime.now(),
      refId: reward.id,
      status: asRequest ? PointStatus.pending : PointStatus.approved,
      decidedBy: asRequest ? null : memberId,
    );
    savePointEntry(entry);
  }

  // --- pocket money ----------------------------------------------------------

  Allowance? allowance(String memberId) {
    final r = record(Collections.allowances, memberId);
    return r == null ? null : Allowance.fromRecord(r);
  }

  void saveAllowance(Allowance a) =>
      put(Collections.allowances, a.memberId, a.toData());

  List<MoneyEntry> moneyOf(String memberId) =>
      records(Collections.moneyEntries)
          .map(MoneyEntry.fromRecord)
          .where((e) => e.memberId == memberId)
          .toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  int moneyBalance(String memberId) =>
      moneyOf(memberId).fold(0, (sum, e) => sum + e.cents);

  void saveMoneyEntry(MoneyEntry e) =>
      put(Collections.moneyEntries, e.id, e.toData());

  void deleteMoneyEntry(String id) => delete(Collections.moneyEntries, id);

  /// Turns [points] into pocket money at the member's rate.
  void convertPoints(String memberId, int points) {
    final rate = allowance(memberId)?.centsPerPoint ?? 0;
    if (rate <= 0 || points <= 0) return;
    final now = DateTime.now();
    savePointEntry(
      PointEntry(
        id: newId(),
        memberId: memberId,
        points: -points,
        title: tr.extrasExchangedPocketMoney,
        kind: PointKind.payout,
        at: now,
        decidedBy: this.memberId,
      ),
    );
    saveMoneyEntry(
      MoneyEntry(
        id: newId(),
        memberId: memberId,
        cents: points * rate,
        at: now,
        kind: MoneyKind.points,
        note: tr.extrasPointsPoints(points),
      ),
    );
  }

  // --- routines ---------------------------------------------------------------

  List<Routine> get routines =>
      records(Collections.routines).map(Routine.fromRecord).toList()
        ..sort((a, b) => (a.time ?? '99').compareTo(b.time ?? '99'));

  void saveRoutine(Routine r) => put(Collections.routines, r.id, r.toData());

  void deleteRoutine(String id) => delete(Collections.routines, id);

  /// Routines [memberId] has on [day].
  List<Routine> routinesFor(String memberId, DateTime day) => routines
      .where(
        (r) => r.dueOn(day) && (r.memberId == null || r.memberId == memberId),
      )
      .toList();

  RoutineRun routineRun(Routine routine, DateTime day, String memberId) {
    final id = routine.runId(day, memberId);
    final r = record(Collections.routineRuns, id);
    return r == null
        ? RoutineRun(
            id: id,
            routineId: routine.id,
            memberId: memberId,
            day: DateTime(day.year, day.month, day.day),
          )
        : RoutineRun.fromRecord(r);
  }

  /// Ticks a step; finishing all steps earns the routine's points.
  void toggleRoutineStep(
    Routine routine,
    DateTime day,
    String memberId,
    String stepId,
  ) {
    final run = routineRun(routine, day, memberId);
    final done = {...run.done};
    done.contains(stepId) ? done.remove(stepId) : done.add(stepId);
    put(
      Collections.routineRuns,
      run.id,
      RoutineRun(
        id: run.id,
        routineId: routine.id,
        memberId: memberId,
        day: run.day,
        done: done,
      ).toData(),
    );
    if (routine.points <= 0) return;
    final pointsId = routine.pointsId(day, memberId);
    final complete = routine.steps.every((s) => done.contains(s.id));
    final existing = record(Collections.pointEntries, pointsId);
    if (complete && existing == null) {
      final byChild = !iAmAdult;
      savePointEntry(
        PointEntry(
          id: pointsId,
          memberId: memberId,
          points: routine.points,
          title: '${routine.emoji} ${routine.title}',
          kind: PointKind.routine,
          at: DateTime.now(),
          refId: routine.id,
          status: byChild ? PointStatus.pending : PointStatus.approved,
          decidedBy: byChild ? null : this.memberId,
        ),
      );
    } else if (!complete && existing != null) {
      final entry = PointEntry.fromRecord(existing);
      // Confirmed points stay; an open request is withdrawn.
      if (entry.status == PointStatus.pending || iAmAdult) {
        deletePointEntry(pointsId);
      }
    }
  }

  // --- event comments ---------------------------------------------------------

  List<EventComment> eventComments(String eventId) =>
      records(Collections.eventComments)
          .map(EventComment.fromRecord)
          .where((c) => c.eventId == eventId)
          .toList()
        ..sort((a, b) => a.at.compareTo(b.at));

  void addEventComment(String eventId, String text) {
    final c = EventComment(
      id: newId(),
      eventId: eventId,
      authorId: memberId,
      at: DateTime.now(),
      text: text,
    );
    put(Collections.eventComments, c.id, c.toData());
  }

  void deleteEventComment(String id) => delete(Collections.eventComments, id);

  // --- polls --------------------------------------------------------------------

  void sendPoll(String chatId, Poll poll) {
    final message = ChatMessage(
      id: newId(),
      chatId: chatId,
      authorId: memberId,
      sentAt: DateTime.now(),
      poll: poll,
      visibleTo: chatAudience(chatId),
    );
    put(Collections.chatMessages, message.id, message.toData());
    markChatRead(chatId, at: message.sentAt);
  }

  void closePoll(ChatMessage message) => put(
    Collections.chatMessages,
    message.id,
    ChatMessage(
      id: message.id,
      chatId: message.chatId,
      authorId: message.authorId,
      sentAt: message.sentAt,
      text: message.text,
      poll: message.poll?.close(),
      visibleTo: message.visibleTo,
    ).toData(),
  );

  List<PollVote> pollVotes(String messageId) => [
    for (final r in records(Collections.pollVotes))
      if (r.data['messageId'] == messageId) PollVote.fromRecord(r),
  ];

  void vote(ChatMessage message, List<String> optionIds) {
    final id = PollVote.idFor(message.id, memberId);
    if (optionIds.isEmpty) {
      delete(Collections.pollVotes, id);
      return;
    }
    put(
      Collections.pollVotes,
      id,
      PollVote(
        messageId: message.id,
        memberId: memberId,
        optionIds: optionIds,
      ).toData(visibleTo: chatAudience(message.chatId)),
    );
  }

  // --- list templates -------------------------------------------------------------

  List<ListTemplate> get listTemplates =>
      records(Collections.listTemplates).map(ListTemplate.fromRecord).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  void saveListTemplate(ListTemplate t) =>
      put(Collections.listTemplates, t.id, t.toData());

  void deleteListTemplate(String id) => delete(Collections.listTemplates, id);

  /// Creates a new list with the template's items; returns its id.
  String listFromTemplate(ListTemplate t, {String? name}) {
    final list = ShoppingList(
      id: newId(),
      name: name ?? '${t.emoji} ${t.name}',
    );
    saveShoppingList(list);
    for (final item in t.items) {
      saveShoppingItem(
        ShoppingItem(
          id: newId(),
          listId: list.id,
          name: item.name,
          quantity: item.quantity,
          category: item.category,
        ),
      );
    }
    return list.id;
  }

  /// The packing list for [event] (the trip), if there is one.
  ShoppingList? packingListOf(String eventId) =>
      shoppingLists.where((l) => l.eventId == eventId).firstOrNull;

  /// Creates a packing list for [event] from [t]: everyone's things once,
  /// the rest once per member in [memberIds] (children's things only for
  /// children). Without members every entry comes once.
  String packingListFor(
    CalendarEvent event,
    ListTemplate t, {
    List<String> memberIds = const [],
  }) {
    final list = ShoppingList(
      id: newId(),
      name: '🧳 ${event.title}',
      packing: true,
      eventId: event.id,
    );
    saveShoppingList(list);
    final people = [for (final id in memberIds) ?member(id)];
    final kids = people.where((m) => m.isChild).toList();
    for (final item in t.items) {
      final List<String?> owners;
      if (people.isEmpty || sharedPackingCategories.contains(item.category)) {
        owners = [null];
      } else if (item.category == 'Kinder') {
        owners = kids.isEmpty ? [null] : [for (final k in kids) k.id];
      } else {
        owners = [for (final p in people) p.id];
      }
      for (final owner in owners) {
        saveShoppingItem(
          ShoppingItem(
            id: newId(),
            listId: list.id,
            name: item.name,
            quantity: item.quantity,
            category: item.category,
            memberId: owner,
          ),
        );
      }
    }
    return list.id;
  }

  /// Saves the items of a list as a template (unticked).
  ListTemplate templateFromList(ShoppingList list, {String emoji = '📋'}) {
    final t = ListTemplate(
      id: newId(),
      name: list.name,
      emoji: emoji,
      items: [
        // A packing list has each person's things once per person.
        for (final i in {
          for (final i in shoppingItems(list.id)) (i.name, i.category): i,
        }.values)
          TemplateItem(i.name, quantity: i.quantity, category: i.category),
      ],
    );
    saveListTemplate(t);
    return t;
  }

  // --- pantry -----------------------------------------------------------------------

  List<PantryItem> get pantryItems =>
      records(Collections.pantryItems).map(PantryItem.fromRecord).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  PantryItem? pantryByBarcode(String code) =>
      pantryItems.where((i) => i.barcode == code).firstOrNull;

  void savePantryItem(PantryItem i) =>
      put(Collections.pantryItems, i.id, i.toData());

  void deletePantryItem(String id) => delete(Collections.pantryItems, id);

  // --- medications --------------------------------------------------------------------

  List<Medication> get medications =>
      records(Collections.medications).map(Medication.fromRecord).toList()
        ..sort((a, b) {
          final byPerson = a.personName.compareTo(b.personName);
          return byPerson != 0 ? byPerson : a.name.compareTo(b.name);
        });

  Medication? medication(String id) {
    final r = record(Collections.medications, id);
    return r == null ? null : Medication.fromRecord(r);
  }

  /// Health data: only the chosen members (and the author) see it.
  void saveMedication(Medication m) =>
      put(Collections.medications, m.id, m.toData());

  void deleteMedication(String id) {
    for (final i in intakes(id)) {
      delete(Collections.medicationIntakes, i.id);
    }
    delete(Collections.medications, id);
  }

  List<MedicationIntake> intakes(String medicationId) =>
      records(Collections.medicationIntakes)
          .map(MedicationIntake.fromRecord)
          .where((i) => i.medicationId == medicationId)
          .toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  MedicationIntake? intakeAt(Medication m, DateTime scheduled) {
    final r = record(Collections.medicationIntakes, m.intakeId(scheduled));
    return r == null ? null : MedicationIntake.fromRecord(r);
  }

  /// Doses taken since the stock was last counted.
  int takenSinceCount(Medication m) => intakes(m.id)
      .where(
        (i) => !i.skipped && (m.stockAt == null || i.at.isAfter(m.stockAt!)),
      )
      .length;

  void recordIntake(Medication m, {DateTime? scheduled, bool skipped = false}) {
    final intake = MedicationIntake(
      id: scheduled == null ? newId() : m.intakeId(scheduled),
      medicationId: m.id,
      at: DateTime.now(),
      byId: memberId,
      scheduled: scheduled,
      skipped: skipped,
    );
    put(
      Collections.medicationIntakes,
      intake.id,
      intake.toData(visibleTo: m.careIds.isEmpty ? null : m.careIds),
    );
  }

  void deleteIntake(String id) => delete(Collections.medicationIntakes, id);
}

/// Things a family packs once, not once per person.
const sharedPackingCategories = {
  'Dokumente',
  'Unterwegs',
  'Technik',
  'Gemeinsam',
};
