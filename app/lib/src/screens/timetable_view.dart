import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/school_bag.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../l10n.dart';

List<String> get _days => weekdaysShort(5);

/// Distinct friendly colors for up to twelve subjects.
const _subjectColors = [
  0xFF3587D6,
  0xFFE8703A,
  0xFF2A9D6E,
  0xFFDB4A7E,
  0xFF7B5BE0,
  0xFFE89B1A,
  0xFF1AA3A3,
  0xFFB07A3C,
  0xFF6E8F12,
  0xFFC2410C,
  0xFF0E7490,
  0xFF9D4EDD,
];

/// Colors by alphabetical position of the subject in the timetable, so
/// subjects only share a color beyond twelve.
Color subjectColor(Timetable t, String subject) {
  final subjects = {for (final l in t.lessons) l.subject.toLowerCase()}.toList()
    ..sort();
  final i = subjects.indexOf(subject.toLowerCase());
  return Color(_subjectColors[(i < 0 ? 0 : i) % _subjectColors.length]);
}

/// A child's school week; tap a cell to fill it in.
class TimetableView extends StatelessWidget {
  const TimetableView({super.key, required this.child});

  final Child child;

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final t = engine.timetable(child.id) ?? Timetable(childId: child.id);
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = now.weekday;
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    // Rows up to the last used period plus one free row.
    final used = t.lessons.fold<int>(-1, (m, l) => l.period > m ? l.period : m);
    final rows = (used + 2).clamp(6, t.periods.length);
    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        Table(
          columnWidths: const {0: FixedColumnWidth(56)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              children: [
                const SizedBox.shrink(),
                for (final (i, d) in _days.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      d,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: i + 1 == today
                            ? FamioColors.of(
                                context,
                              ).sectionText(FamioSection.kids)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            for (var p = 0; p < rows; p++)
              TableRow(
                children: [
                  InkWell(
                    onTap: () => _editPeriod(context, t, p),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          Text('${p + 1}.', style: theme.textTheme.labelLarge),
                          Text(
                            t.periods[p].start,
                            style: theme.textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (var d = 1; d <= 5; d++)
                    Padding(
                      padding: const EdgeInsets.all(2),
                      child: _Cell(
                        timetable: t,
                        lesson: t.lesson(d, p),
                        place: tr.timetableLesson(_days[d - 1], p + 1),
                        onTap: () => _editLesson(context, t, d, p),
                      ),
                    ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(tr.timetableTapSubjectEnterTap, style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        if (schoolBag(engine, child, tomorrow) case final bag?)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr.timetableForTomorrow,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(bag.summary),
                ],
              ),
            ),
          ),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(AppIcons.backpack),
                title: Text(tr.timetableBagCheck),
                subtitle: Text(
                  t.bagCheck == null
                      ? tr.timetableBagCheckOff
                      : tr.timetableBagCheckOn(t.bagCheck!),
                ),
                value: t.bagCheck != null,
                onChanged: (on) => engine.saveTimetable(
                  t.withBagCheck(on ? Timetable.defaultBagCheck : null),
                ),
              ),
              if (t.bagCheck != null)
                TextButton.icon(
                  icon: const Icon(AppIcons.clock),
                  label: Text(tr.timetableBagCheckTime),
                  onPressed: () => _editBagCheck(context, t),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _editBagCheck(BuildContext context, Timetable t) async {
    final engine = AppScope.engineOf(context);
    final (hour, minute) =
        parseClock(t.bagCheck) ?? parseClock(Timetable.defaultBagCheck)!;
    final picked = await showTimePicker(
      context: context,
      helpText: tr.timetableBagCheck,
      initialTime: TimeOfDay(hour: hour, minute: minute),
    );
    if (picked == null) return;
    engine.saveTimetable(
      t.withBagCheck(
        '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}',
      ),
    );
  }

  Future<void> _editLesson(
    BuildContext context,
    Timetable t,
    int weekday,
    int period,
  ) async {
    final engine = AppScope.engineOf(context);
    final existing = t.lesson(weekday, period);
    final subject = TextEditingController(text: existing?.subject);
    final room = TextEditingController(text: existing?.room);
    final bring = TextEditingController(
      text: existing == null ? '' : t.bring[existing.subject],
    );
    final subjects = {for (final l in t.lessons) l.subject}.toList()..sort();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: Text(tr.timetableLesson(_days[weekday - 1], period + 1)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: subject,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: tr.timetableSubject),
              ),
              if (subjects.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in subjects)
                      ActionChip(
                        label: Text(s),
                        onPressed: () => setState(() {
                          subject.text = s;
                          bring.text = t.bring[s] ?? '';
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: room,
                decoration: InputDecoration(
                  labelText: tr.timetableRoomOptional,
                ),
              ),
              TextField(
                controller: bring,
                decoration: InputDecoration(
                  labelText: tr.timetableBring,
                  hintText: tr.timetableBringHint,
                ),
              ),
            ],
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () {
                  subject.clear();
                  Navigator.pop(context, true);
                },
                child: Text(tr.settingsStorageClear),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.commonSave),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      var next = t.withLesson(weekday, period, subject.text, room.text);
      if (subject.text.trim().isNotEmpty) {
        next = next.withBring(subject.text.trim(), bring.text);
      }
      engine.saveTimetable(next);
    }
  }

  Future<void> _editPeriod(BuildContext context, Timetable t, int p) async {
    final engine = AppScope.engineOf(context);
    TimeOfDay parse(String s) => TimeOfDay(
      hour: int.parse(s.split(':')[0]),
      minute: int.parse(s.split(':')[1]),
    );
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final start = await showTimePicker(
      context: context,
      helpText: tr.timetablePeriodPeriodStarts(p + 1),
      initialTime: parse(t.periods[p].start),
    );
    if (start == null || !context.mounted) return;
    final end = await showTimePicker(
      context: context,
      helpText: tr.timetablePeriodPeriodEnds(p + 1),
      initialTime: parse(t.periods[p].end),
    );
    if (end == null) return;
    engine.saveTimetable(
      t.copyWith(
        periods: [
          for (final (i, old) in t.periods.indexed)
            i == p ? Period(fmt(start), fmt(end)) : old,
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.timetable,
    required this.lesson,
    required this.place,
    required this.onTap,
  });

  final Timetable timetable;
  final Lesson? lesson;

  /// "Mo, 1. Stunde", for screen readers.
  final String place;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = lesson;
    final c = FamioColors.of(context);
    final color = l == null
        ? c.surfaceSoft
        : subjectColor(timetable, l.subject);
    return Semantics(
      button: true,
      label: l == null ? tr.timetablePlaceFree(place) : place,
      child: Material(
        color: l == null ? c.surfaceSoft : color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Center(
              child: l == null
                  ? Icon(AppIcons.plus, size: 16, color: c.inkSoft)
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            l.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          if (l.room.isNotEmpty)
                            Text(
                              l.room,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
