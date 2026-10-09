import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';

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

const _collectionLabels = {
  Collections.events: 'Termin',
  Collections.tasks: 'Aufgabe',
  Collections.notes: 'Notiz',
  Collections.contacts: 'Kontakt',
  Collections.recipes: 'Rezept',
  Collections.mealPlan: 'Essensplan',
  Collections.children: 'Kind',
  Collections.childEntries: 'Kinder-Eintrag',
  Collections.pregnancies: 'Schwangerschaft',
  Collections.timetables: 'Stundenplan',
  Collections.budgetEntries: 'Buchung',
  Collections.documents: 'Dokument',
  Collections.medications: 'Medikament',
  Collections.chores: 'Amt',
  Collections.routines: 'Routine',
  Collections.rewards: 'Belohnung',
  Collections.listTemplates: 'Listen-Vorlage',
  Collections.pantryItems: 'Vorrat',
  Collections.wishes: 'Wunsch',
  Collections.deadlines: 'Frist',
  Collections.wasteSettings: 'Abfallkalender',
  Collections.sosSettings: 'Notfallknopf',
  Collections.shoppingLists: 'Einkaufsliste',
};

const _fieldLabels = {
  'title': 'Titel',
  'name': 'Name',
  'text': 'Text',
  'notes': 'Notizen',
  'note': 'Hinweis',
  'start': 'Beginn',
  'end': 'Ende',
  'allDay': 'Ganztägig',
  'location': 'Ort',
  'due': 'Fällig',
  'done': 'Erledigt',
  'quantity': 'Menge',
  'amount': 'Betrag',
  'memberIds': 'Wer',
  'assigneeId': 'Zuständig',
  'recurrence': 'Wiederholung',
  'reminderMinutes': 'Erinnerung',
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
  return 'Eintrag';
}

/// Fields in which [a] and [b] differ (apart from visibility and other
/// apps' fields), as (label, value in a, value in b).
List<(String, String, String)> conflictDiff(
  Map<String, Object?> a,
  Map<String, Object?> b,
) {
  String show(Object? v) => switch (v) {
    null => '–',
    true => 'ja',
    false => 'nein',
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
          title: 'Überschnittene Änderungen',
          subtitle: 'Zwei Fassungen – du entscheidest',
          maxBodyWidth: 720,
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              const SoftCard(
                child: Text(
                  'Hier hat jemand etwas geändert, ohne die Änderung eines '
                  'anderen zu sehen – meist, weil ein Handy offline war. '
                  'Famio hat die neuere Fassung behalten und die andere hier '
                  'aufgehoben. Wer entscheidet, entscheidet für beide.',
                ),
              ),
              const SizedBox(height: 8),
              if (all.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Nichts zu entscheiden.'),
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
        ? 'dir'
        : engine.member(id)?.displayName ?? 'jemand anderem';
    final when = DateFormat('d.M., HH:mm', 'de');
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
            '${_collectionLabels[c.collection] ?? 'Eintrag'}: $title',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            current == null
                ? 'Gelöscht von ${who(c.keptBy)} (${when.format(c.keptAt)}); '
                      'die Änderung von ${who(c.lostBy)} '
                      '(${when.format(c.lostAt)}) ist aufgehoben.'
                : c.lostDeleted
                ? '${who(c.lostBy)[0].toUpperCase()}${who(c.lostBy).substring(1)} '
                      'hat es gelöscht (${when.format(c.lostAt)}), '
                      '${who(c.keptBy)} hat es gleichzeitig geändert '
                      '(${when.format(c.keptAt)}) – es ist noch da.'
                : 'Behalten: die Fassung von ${who(c.keptBy)} '
                      '(${when.format(c.keptAt)}). Aufgehoben: die von '
                      '${who(c.lostBy)} (${when.format(c.lostAt)}).',
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
                        text: '  statt  ',
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
                label: Text(current == null ? 'Gelöscht lassen' : 'So lassen'),
                onPressed: () => engine.keepCurrent(c),
              ),
              OutlinedButton.icon(
                icon: const Icon(AppIcons.rotateCcw, size: 18),
                label: Text(
                  c.lostDeleted
                      ? 'Doch löschen'
                      : 'Fassung von ${who(c.lostBy)} zurückholen',
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
