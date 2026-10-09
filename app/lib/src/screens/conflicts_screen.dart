import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../l10n.dart';

/// Changes that crossed: two members edited the same thing without seeing
/// each other's change. One version stayed; the other is shown here to
/// keep or bring back.
extension ConflictData on SyncEngine {
  List<SyncConflict> get conflicts =>
      records(Collections.conflicts).map(SyncConflict.fromRecord).toList()
        ..sort((a, b) => b.keptAt.compareTo(a.keptAt));

  /// The version that stayed is fine: the conflict goes, for both.
  void keepCurrent(SyncConflict c) => delete(Collections.conflicts, c.id);

  /// Brings the other version back (it becomes the newest) and closes the
  /// conflict.
  void restoreLost(SyncConflict c) {
    if (c.lostDeleted) {
      delete(c.collection, c.recordId);
    } else {
      put(c.collection, c.recordId, c.lost);
    }
    delete(Collections.conflicts, c.id);
  }
}

Map<String, String> get _collectionLabels => {
  Collections.events: tr.commonEvent,
  Collections.tasks: tr.commonTask,
  Collections.notes: tr.commonNote,
  Collections.contacts: tr.commonContact,
  Collections.recipes: tr.commonRecipe,
  Collections.mealPlan: tr.conflictsMealPlan,
  Collections.children: tr.commonChild,
  Collections.childEntries: tr.conflictsKidsEntry,
  Collections.pregnancies: tr.commonPregnancy,
  Collections.timetables: tr.commonTimetable,
  Collections.budgetEntries: tr.conflictsBooking,
  Collections.documents: tr.commonDocument,
  Collections.medications: tr.kidsLogMedication,
  Collections.chores: tr.commonChore,
  Collections.routines: tr.commonRoutine,
  Collections.rewards: tr.commonReward,
  Collections.listTemplates: tr.conflictsListTemplate,
  Collections.pantryItems: tr.conflictsPantry,
  Collections.wishes: tr.commonWish,
  Collections.deadlines: tr.commonDeadline,
  Collections.wasteSettings: tr.settingsWaste,
  Collections.sosSettings: tr.settingsSos,
  Collections.shoppingLists: tr.commonShoppingList,
};

Map<String, String> get _fieldLabels => {
  'title': tr.commonTitle,
  'name': tr.commonName,
  'text': tr.commonText,
  'notes': tr.commonNotes,
  'note': tr.commonHint,
  'start': tr.commonStart,
  'end': tr.commonEnd,
  'allDay': tr.commonAllDay,
  'location': tr.commonPlace,
  'due': tr.commonDue,
  'done': tr.commonDoneCap,
  'quantity': tr.commonQuantity,
  'amount': tr.commonAmount,
  'memberIds': tr.commonWho,
  'assigneeId': tr.commonResponsible,
  'recurrence': tr.commonRepeat,
  'reminderMinutes': tr.commonReminder,
};

/// What a record is called: its title, name or the start of its text.
String conflictTitle(Map<String, Object?> data) {
  for (final key in ['title', 'name', 'text', 'subject']) {
    final v = data[key];
    if (v is String && v.trim().isNotEmpty) {
      final t = v.trim().split('\n').first;
      return t.length > 60 ? '${t.substring(0, 57)}…' : t;
    }
  }
  return tr.commonEntry;
}

/// Fields in which [a] and [b] differ (apart from visibility and other
/// apps' fields), as (label, value in a, value in b).
List<(String, String, String)> conflictDiff(
  Map<String, Object?> a,
  Map<String, Object?> b,
) {
  String show(Object? v) => switch (v) {
    null => '–',
    true => tr.commonYesLower,
    false => tr.commonNoLower,
    final List<Object?> l => l.isEmpty ? '–' : l.join(', '),
    final Map<Object?, Object?> _ => '…',
    _ => '$v'.length > 80 ? '${'$v'.substring(0, 77)}…' : '$v',
  };
  final keys = {...a.keys, ...b.keys}.where(
    (k) =>
        k != SyncRecord.visibilityKey &&
        !k.startsWith(SyncRecord.externalPrefix),
  );
  return [
    for (final k in keys)
      if (show(a[k]) != show(b[k]))
        (_fieldLabels[k] ?? k, show(a[k]), show(b[k])),
  ];
}

class ConflictsScreen extends StatelessWidget {
  const ConflictsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: {
        Collections.conflicts,
        'members',
        ...Collections.conflictTracked,
      },
      builder: (context, engine) {
        final all = engine.conflicts;
        return SectionPage(
          section: FamioSection.home,
          title: tr.conflictsOverlappingChanges,
          subtitle: tr.conflictsTwoVersionsYouDecide,
          maxBodyWidth: 720,
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              SoftCard(child: Text(tr.conflictsHereSomeoneChangedSomething)),
              const SizedBox(height: 8),
              if (all.isEmpty)
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(tr.conflictsNothingDecide),
                ),
              for (final c in all)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ConflictCard(conflict: c, engine: engine),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({required this.conflict, required this.engine});

  final SyncConflict conflict;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final c = conflict;
    final theme = Theme.of(context);
    final colors = FamioColors.of(context);
    final current = engine.record(c.collection, c.recordId);
    String who(String id) => id == engine.memberId
        ? tr.calendarYou
        : engine.member(id)?.displayName ?? tr.conflictsSomeoneElse;
    final when = DateFormat.Md(appLanguage).add_jm();
    final title = conflictTitle(
      current?.data ?? (c.lost.isEmpty ? const {} : c.lost),
    );
    final diff = current == null || c.lostDeleted
        ? const <(String, String, String)>[]
        : conflictDiff(current.data, c.lost);
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_collectionLabels[c.collection] ?? tr.commonEntry}: $title',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            current == null
                ? tr.conflictsDeletedWhoWhenChange(
                    who(c.keptBy),
                    when.format(c.keptAt),
                    who(c.lostBy),
                    when.format(c.lostAt),
                  )
                : c.lostDeleted
                ? tr.conflictsDeletedWhoWhenChanged(
                    who(c.lostBy),
                    when.format(c.lostAt),
                    who(c.keptBy),
                    when.format(c.keptAt),
                  )
                : tr.conflictsKeptVersionWhoWhen(
                    who(c.keptBy),
                    when.format(c.keptAt),
                    who(c.lostBy),
                    when.format(c.lostAt),
                  ),
            style: theme.textTheme.bodyMedium,
          ),
          if (diff.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final (field, kept, lost) in diff)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$field: ',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: kept),
                      TextSpan(
                        text: tr.conflictsInstead,
                        style: TextStyle(color: colors.inkSoft),
                      ),
                      TextSpan(
                        text: lost,
                        style: TextStyle(color: colors.inkSoft),
                      ),
                    ],
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                icon: const Icon(AppIcons.check, size: 18),
                label: Text(
                  current == null
                      ? tr.conflictsKeepDeleted
                      : tr.conflictsLeaveLike,
                ),
                onPressed: () => engine.keepCurrent(c),
              ),
              OutlinedButton.icon(
                icon: const Icon(AppIcons.rotateCcw, size: 18),
                label: Text(
                  c.lostDeleted
                      ? tr.conflictsDeleteAfterAll
                      : tr.conflictsBringBackVersionWho(who(c.lostBy)),
                ),
                onPressed: () => engine.restoreLost(c),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
