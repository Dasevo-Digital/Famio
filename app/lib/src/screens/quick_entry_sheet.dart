import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/event_extract.dart';
import '../design/app_icons.dart';
import '../l10n.dart';
import 'event_editor.dart';
import 'tasks_screen.dart';

/// Quick entry: one line ("Donnerstag 16 Uhr Kinderarzt") becomes the draft
/// of an event or a task, which then opens in its editor to be checked and
/// saved. A day it cannot tell ("nächsten Donnerstag") is asked first.
/// Everything is read on the device.
Future<void> showQuickEntry(BuildContext context) async {
  final choice = await showModalBottomSheet<QuickChoice>(
    context: context,
    // Above the floating navigation bar.
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const QuickEntrySheet(),
  );
  if (choice == null || !context.mounted) return;
  await openQuickChoice(context, choice);
}

/// What the sheet hands on: the entry, the day meant and what it becomes.
typedef QuickChoice = ({QuickEntry entry, DateTime? day, bool event});

/// Opens the editor for [choice], filled in.
Future<void> openQuickChoice(BuildContext context, QuickChoice choice) {
  final engine = AppScope.engineOf(context);
  final (:entry, :day, :event) = choice;
  final time = entry.time;
  if (event) {
    // Times are the family's, as everywhere in the calendar.
    final now = inCalendarZone(DateTime.now(), engine.familyTimeZone);
    final title = entry.title.isEmpty ? null : entry.title;
    if (time != null) {
      final d = day ?? now;
      final start = calendarDate(now, d.year, d.month, d.day, time.$1, time.$2);
      var end = time.$3 == null
          ? start.add(const Duration(hours: 1))
          : calendarDate(now, d.year, d.month, d.day, time.$3!, time.$4 ?? 0);
      if (!end.isAfter(start)) end = start.add(const Duration(hours: 1));
      return showEventEditor(context, start: start, end: end, title: title);
    }
    if (day != null) {
      final last = entry.lastDay ?? day;
      return showEventEditor(
        context,
        start: calendarDate(now, day.year, day.month, day.day),
        end: calendarDate(now, last.year, last.month, last.day + 1),
        allDay: true,
        title: title,
      );
    }
    return showEventEditor(context, title: title);
  }
  // Tasks keep their dates on the device, as the task editor does.
  final now = DateTime.now();
  final due = day ?? (time == null ? null : DateUtils.dateOnly(now));
  final remind = due == null || time == null
      ? null
      : DateTime(due.year, due.month, due.day, time.$1, time.$2);
  return showTaskEditor(
    context,
    draft: Task(
      id: newId(),
      title: entry.title,
      due: due,
      remindAt: remind != null && remind.isAfter(now) ? remind : null,
      createdAt: now,
    ),
  );
}

class QuickEntrySheet extends StatefulWidget {
  const QuickEntrySheet({super.key});

  @override
  State<QuickEntrySheet> createState() => _QuickEntrySheetState();
}

class _QuickEntrySheetState extends State<QuickEntrySheet> {
  final _text = TextEditingController();
  late final DateTime _today;
  QuickEntry? _entry;

  /// The day picked when the entry names two.
  DateTime? _picked;

  @override
  void initState() {
    super.initState();
    _today = inCalendarZone(
      DateTime.now(),
      AppScope.read(context).engine!.familyTimeZone,
    );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _changed(String text) => setState(() {
    _entry = text.trim().isEmpty ? null : parseQuickEntry(text, today: _today);
    if (!(_entry?.days.contains(_picked) ?? false)) _picked = null;
  });

  DateTime? get _day {
    final e = _entry;
    if (e == null || e.days.isEmpty) return null;
    return e.ambiguous ? _picked : e.days.single;
  }

  bool get _ready {
    final e = _entry;
    return e != null && (!e.ambiguous || _picked != null);
  }

  /// With a time it is rather an appointment, else rather a task.
  bool get _eventFirst => _entry?.time != null;

  void _done(bool event) {
    if (!_ready) return;
    Navigator.pop<QuickChoice>(context, (
      entry: _entry!,
      day: _day,
      event: event,
    ));
  }

  String _when(QuickEntry e) {
    final dayFormat = DateFormat.yMMMEd(appLanguage);
    final time = DateFormat.Hm(appLanguage);
    String clock(int h, int m) => time.format(DateTime(2000, 1, 1, h, m));
    final parts = [
      if (_day case final d?)
        e.lastDay == null
            ? dayFormat.format(d)
            : '${dayFormat.format(d)} – ${dayFormat.format(e.lastDay!)}'
      else if (!e.ambiguous)
        tr.quickEntryNoDay,
      if (e.time case (final h, final m, final eh, final em))
        eh == null ? clock(h, m) : '${clock(h, m)}–${clock(eh, em ?? 0)}',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = _entry;
    final asEvent = _eventFirst;
    Widget button(bool event) {
      final label = Text(event ? tr.quickEntryAsEvent : tr.quickEntryAsTask);
      final onPressed = _ready ? () => _done(event) : null;
      return event == asEvent
          ? FilledButton(onPressed: onPressed, child: label)
          : OutlinedButton(onPressed: onPressed, child: label);
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr.quickEntryTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: tr.quickEntryHint,
              prefixIcon: const Icon(AppIcons.sparkle),
            ),
            onChanged: _changed,
            onSubmitted: (_) => _done(asEvent),
          ),
          if (e != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  asEvent ? AppIcons.calendarBlank : AppIcons.checkSquareOffset,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.title.isEmpty ? tr.quickEntryNoTitle : e.title,
                        style: theme.textTheme.titleMedium,
                      ),
                      if (_when(e) case final text when text.isNotEmpty)
                        Text(text, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            if (e.ambiguous) ...[
              const SizedBox(height: 12),
              Text(tr.quickEntryWhichDay, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final d in e.days)
                    ChoiceChip(
                      label: Text(DateFormat.MMMEd(appLanguage).format(d)),
                      selected: _picked == d,
                      onSelected: (_) => setState(() => _picked = d),
                    ),
                ],
              ),
            ],
          ],
          const SizedBox(height: 12),
          Text(
            tr.quickEntryCheck,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [button(!asEvent), button(asEvent)],
          ),
        ],
      ),
    );
  }
}
