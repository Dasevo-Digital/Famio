import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../design/app_icons.dart';

import '../data/birthdays.dart';
import '../data/holidays.dart';
import '../data/family_data.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import 'calendar_connect_screen.dart';
import 'event_editor.dart';
import 'event_import_screen.dart';

/// Month grid plus the agenda of the selected day; side by side when wide.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _selected = DateUtils.dateOnly(DateTime.now());
  late DateTime _month = DateTime(_selected.year, _selected.month);

  void _changeMonth(int delta) => setState(() {
    _month = DateTime(_month.year, _month.month + delta);
    final lastDay = DateUtils.getDaysInMonth(_month.year, _month.month);
    _selected = DateTime(
      _month.year,
      _month.month,
      _selected.day.clamp(1, lastDay),
    );
  });

  void _select(DateTime day) => setState(() {
    _selected = day;
    _month = DateTime(day.year, day.month);
  });

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return SectionPage(
      section: FamioSection.calendar,
      title: 'Kalender',
      subtitle: DateFormat('EEEE, d. MMMM', 'de').format(_selected),
      actions: [
        BubbleButton(
          icon: AppIcons.scanBarcode,
          tooltip: 'Termine aus Foto oder Text erkennen',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const EventImportScreen()),
          ),
        ),
        BubbleButton(
          icon: AppIcons.arrowsLeftRight,
          tooltip: 'Mit Google/Apple Kalender verbinden',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const CalendarConnectScreen(),
            ),
          ),
        ),
        BubbleButton(
          icon: AppIcons.calendarDot,
          tooltip: 'Heute',
          onPressed: () => _select(DateUtils.dateOnly(DateTime.now())),
        ),
        const SyncStatusIcon(),
      ],
      floating: AddButton(
        color: c.strong(FamioSection.calendar),
        tooltip: 'Neuer Termin',
        onPressed: () => showEventEditor(context, day: _selected),
      ),
      body: DataBuilder(
        collections: const {
          Collections.events,
          Collections.externalEvents,
          Collections.calendarSubscriptions,
          Collections.children,
          Collections.contacts,
          'members',
        },
        builder: (context, engine) => LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 840;
            final gridStart = _gridStart(_month);
            final occurrences = engine.occurrences(
              gridStart,
              DateTime(gridStart.year, gridStart.month, gridStart.day + 42),
            );
            final byDay = _groupByDay(occurrences);

            final grid = SoftCard(
              padding: const EdgeInsets.all(10),
              child: _MonthGrid(
                month: _month,
                selected: _selected,
                byDay: byDay,
                detailed: wide,
                engine: engine,
                onSelect: _select,
                onChangeMonth: _changeMonth,
              ),
            );
            final agenda = _DayAgenda(
              day: _selected,
              occurrences: byDay[_selected] ?? const [],
              engine: engine,
            );

            if (wide) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: grid),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 360,
                      child: SoftCard(padding: EdgeInsets.zero, child: agenda),
                    ),
                  ],
                ),
              );
            }
            return Column(
              children: [
                SizedBox(height: 52.0 * 6 + 84, child: grid),
                Expanded(child: agenda),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Monday on or before the first of [month].
  static DateTime _gridStart(DateTime month) =>
      DateTime(month.year, month.month, 1 - (month.weekday - 1));

  /// Maps each day to the occurrences touching it (multi-day ones repeat).
  static Map<DateTime, List<Occurrence>> _groupByDay(List<Occurrence> all) {
    final map = <DateTime, List<Occurrence>>{};
    for (final o in all) {
      var day = DateUtils.dateOnly(o.start);
      // End is exclusive; a timed event ending at midnight stays on its day.
      final last = o.end.isAfter(o.start)
          ? DateUtils.dateOnly(o.end.subtract(const Duration(milliseconds: 1)))
          : day;
      while (!day.isAfter(last)) {
        map.putIfAbsent(day, () => []).add(o);
        day = DateTime(day.year, day.month, day.day + 1);
      }
    }
    return map;
  }
}

Color eventColor(BuildContext context, SyncEngine engine, CalendarEvent e) {
  if (isHolidaySource(e.sourceId)) return const Color(0xFF7A8796);
  if (isBirthdaySource(e.sourceId)) {
    final color = engine.birthdayOf(e.sourceId)?.color;
    return color == null ? const Color(0xFFE89B1A) : Color(color);
  }
  if (e.sourceId != null) {
    final color = engine.calendarSubscription(e.sourceId)?.color;
    return color == null
        ? Theme.of(context).colorScheme.tertiary
        : Color(color);
  }
  final member = e.memberIds.isEmpty ? null : engine.member(e.memberIds.first);
  return member?.color != null
      ? Color(member!.color!)
      : Theme.of(context).colorScheme.primary;
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.byDay,
    required this.detailed,
    required this.engine,
    required this.onSelect,
    required this.onChangeMonth,
  });

  final DateTime month;
  final DateTime selected;
  final Map<DateTime, List<Occurrence>> byDay;

  /// Show event titles in the cells (wide screens) instead of dots.
  final bool detailed;
  final SyncEngine engine;
  final ValueChanged<DateTime> onSelect;
  final ValueChanged<int> onChangeMonth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = _CalendarScreenState._gridStart(month);
    final weekdays = [
      for (var i = 0; i < 7; i++)
        DateFormat.E('de').format(DateTime(2024, 1, 1 + i)), // 1.1.24 = Mo
    ];

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v.abs() > 200) onChangeMonth(v < 0 ? 1 : -1);
      },
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(AppIcons.caretLeft),
                  tooltip: 'Voriger Monat',
                  onPressed: () => onChangeMonth(-1),
                ),
                Expanded(
                  child: Text(
                    DateFormat.yMMMM('de').format(month),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(AppIcons.caretRight),
                  tooltip: 'Nächster Monat',
                  onPressed: () => onChangeMonth(1),
                ),
              ],
            ),
          ),
          Row(
            children: [
              for (final w in weekdays)
                Expanded(
                  child: Text(
                    w,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Column(
              children: [
                for (var week = 0; week < 6; week++)
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var d = 0; d < 7; d++)
                          Expanded(
                            child: _DayCell(
                              day: DateTime(
                                start.year,
                                start.month,
                                start.day + week * 7 + d,
                              ),
                              month: month,
                              selected: selected,
                              occurrences:
                                  byDay[DateTime(
                                    start.year,
                                    start.month,
                                    start.day + week * 7 + d,
                                  )] ??
                                  const [],
                              detailed: detailed,
                              engine: engine,
                              onTap: onSelect,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.month,
    required this.selected,
    required this.occurrences,
    required this.detailed,
    required this.engine,
    required this.onTap,
  });

  final DateTime day;
  final DateTime month;
  final DateTime selected;
  final List<Occurrence> occurrences;
  final bool detailed;
  final SyncEngine engine;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isToday = DateUtils.isSameDay(day, DateTime.now());
    final isSelected = day == selected;
    final inMonth = day.month == month.month;
    const maxShown = 3;

    final number = Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: isToday
          ? BoxDecoration(color: scheme.primary, shape: BoxShape.circle)
          : null,
      child: Text(
        '${day.day}',
        style: TextStyle(
          fontSize: 13,
          fontWeight: isToday ? FontWeight.bold : null,
          color: isToday
              ? scheme.onPrimary
              : inMonth
              ? scheme.onSurface
              : scheme.outline,
        ),
      ),
    );

    // The month grid has fixed cells; its numbers grow only a little with
    // large text (the agenda below shows everything at full size).
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: Material(
          color: isSelected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onTap(day),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: detailed
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        number,
                        for (final o in occurrences.take(maxShown))
                          _CellLabel(occurrence: o, engine: engine),
                        if (occurrences.length > maxShown)
                          Text(
                            '+${occurrences.length - maxShown}',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                      ],
                    )
                  // Squeezed cells (large text, low windows) shrink their
                  // number and dots instead of overflowing.
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.topCenter,
                      child: Column(
                        children: [
                          number,
                          const SizedBox(height: 3),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (final o in occurrences.take(maxShown))
                                Container(
                                  width: 6,
                                  height: 6,
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: eventColor(context, engine, o.event),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                            ],
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

class _CellLabel extends StatelessWidget {
  const _CellLabel({required this.occurrence, required this.engine});

  final Occurrence occurrence;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final color = eventColor(context, engine, occurrence.event);
    final e = occurrence.event;
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      width: double.infinity,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        border: Border(left: BorderSide(color: color, width: 3)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        e.allDay ? e.title : '${timeLabel(occurrence.start)} ${e.title}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

class _DayAgenda extends StatelessWidget {
  const _DayAgenda({
    required this.day,
    required this.occurrences,
    required this.engine,
  });

  final DateTime day;
  final List<Occurrence> occurrences;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.only(bottom: listBottomPadding(context)),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            DateFormat('EEEE, d. MMMM', 'de').format(day),
            style: theme.textTheme.titleMedium,
          ),
        ),
        if (occurrences.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Keine Termine',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
        for (final o in occurrences)
          _OccurrenceTile(o, day: day, engine: engine),
      ],
    );
  }
}

class _OccurrenceTile extends StatelessWidget {
  const _OccurrenceTile(
    this.occurrence, {
    required this.day,
    required this.engine,
  });

  final Occurrence occurrence;
  final DateTime day;
  final SyncEngine engine;

  /// Imported events are read-only; show their details instead of the editor.
  void _showImported(BuildContext context) {
    final e = occurrence.event;
    final source = engine.calendarSubscription(e.sourceId);
    final when = e.allDay
        ? dayLabel(occurrence.start)
        : '${dateTimeLabel(occurrence.start)} – ${timeLabel(occurrence.end)}';
    showModalBottomSheet<void>(
      context: context,
      // Above the floating navigation bar.
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(when),
              if (e.location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(e.location),
              ],
              if (e.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(e.notes),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    isBirthdaySource(e.sourceId)
                        ? AppIcons.cake
                        : AppIcons.cloudArrowDown,
                    size: 18,
                    color: eventColor(context, engine, e),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isHolidaySource(e.sourceId)
                          ? 'Das Bundesland stellen Admins in der '
                                'Server-Verwaltung ein.'
                          : isBirthdaySource(e.sourceId)
                          ? '${engine.birthdayOf(e.sourceId)?.headline(occurrence.start) ?? 'Geburtstag'}. '
                                'Ändern im Profil, beim Kind oder unter Kontakte.'
                          : FamilyData.isCalDavSource(e.sourceId)
                          ? 'Aus einem verbundenen Kalender – in Famio nur '
                                'lesbar, weil Famio diese Wiederholung nicht '
                                'genau abbilden kann. Dort ändern.'
                          : 'Aus „${source?.name ?? 'Abo'}“ – nur lesbar. '
                                'Änderungen im Originalkalender vornehmen.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _timeText() {
    final e = occurrence.event;
    if (e.allDay) return 'ganztägig';
    final startsToday = DateUtils.isSameDay(occurrence.start, day);
    final endsToday = DateUtils.isSameDay(occurrence.end, day);
    final from = startsToday ? timeLabel(occurrence.start) : '…';
    final to = endsToday || occurrence.end == occurrence.start
        ? timeLabel(occurrence.end)
        : '…';
    return occurrence.end == occurrence.start ? from : '$from\n$to';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = occurrence.event;
    final color = eventColor(context, engine, e);
    final members = [for (final id in e.memberIds) ?engine.member(id)];
    final details = [
      ?engine.liftsLabel(e),
      if (e.location.isNotEmpty) e.location,
      if (e.notes.isNotEmpty) e.notes.split('\n').first,
    ].join(' · ');

    return InkWell(
      onTap: () => e.sourceId == null
          ? showEventEditor(context, occurrence: occurrence)
          : _showImported(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(_timeText(), style: theme.textTheme.bodySmall),
            ),
            Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          e.title,
                          style: theme.textTheme.bodyLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (e.recurrence != null && !isBirthdaySource(e.sourceId))
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Icon(
                            AppIcons.repeat,
                            size: 14,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      if (e.reminderMinutes != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(
                            AppIcons.bell,
                            size: 14,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                    ],
                  ),
                  if (details.isNotEmpty)
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            if (e.sourceId != null)
              Tooltip(
                message: isHolidaySource(e.sourceId)
                    ? 'Feiertag'
                    : isBirthdaySource(e.sourceId)
                    ? 'Geburtstag'
                    : engine.calendarSubscription(e.sourceId)?.name ??
                          (FamilyData.isCalDavSource(e.sourceId)
                              ? 'Verbundener Kalender'
                              : 'Abonniert'),
                child: Icon(
                  isBirthdaySource(e.sourceId)
                      ? AppIcons.cake
                      : AppIcons.cloudArrowDown,
                  color: theme.colorScheme.outline,
                ),
              )
            else if (members.isEmpty)
              Tooltip(
                message: 'Ganze Familie',
                child: Icon(
                  AppIcons.usersThree,
                  color: theme.colorScheme.outline,
                ),
              )
            else
              for (final m in members.take(3))
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: MemberAvatar(m, radius: 11),
                ),
          ],
        ),
      ),
    );
  }
}
