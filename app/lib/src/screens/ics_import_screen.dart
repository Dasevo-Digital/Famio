import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// The events of a calendar file (`.ics`), all chosen at first: the member
/// unticks what should not go into the family calendar and takes over the
/// rest. Pops with true after saving.
class IcsImportScreen extends StatefulWidget {
  const IcsImportScreen({super.key, required this.preview});

  final IcsFilePreview preview;

  @override
  State<IcsImportScreen> createState() => _IcsImportScreenState();
}

class _IcsImportScreenState extends State<IcsImportScreen> {
  late final _chosen = <int>{
    for (var i = 0; i < widget.preview.events.length; i++) i,
  };

  /// Saves the chosen events with the ids from the file: importing the same
  /// file again updates them instead of adding them twice.
  void _add() {
    final engine = AppScope.engineOf(context);
    final events = widget.preview.events;
    for (final i in _chosen) {
      engine.saveEvent(events[i]);
    }
    final added = _chosen.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 1 ? tr.import1EventAdded : tr.importCountEventsAdded(added),
        ),
      ),
    );
    Navigator.pop(context, true);
  }

  static String _when(CalendarEvent e) {
    final day = DateFormat.yMMMEd(appLanguage);
    if (!e.allDay) {
      final start = e.start.toLocal();
      final end = e.end.toLocal();
      return DateUtils.isSameDay(start, end)
          ? tr.importDay(
              day.format(start),
              DateFormat.jm(appLanguage).format(start),
              DateFormat.jm(appLanguage).format(end),
            )
          : '${day.format(start)} ${DateFormat.jm(appLanguage).format(start)}'
                ' – ${day.format(end)} ${DateFormat.jm(appLanguage).format(end)}';
    }
    final last = DateUtils.addDaysToDate(e.end, -1);
    return !last.isAfter(e.start)
        ? tr.importDayAllDay(day.format(e.start))
        : '${day.format(e.start)} – ${day.format(last)}';
  }

  @override
  Widget build(BuildContext context) {
    final ics = widget.preview;
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.calendar);
    final engine = AppScope.engineOf(context);
    final all = _chosen.length == ics.events.length;
    return SectionPage(
      section: FamioSection.calendar,
      title: tr.importIcsFile,
      subtitle: tr.importIcsCount(ics.events.length),
      maxBodyWidth: 720,
      body: ListView(
        padding: EdgeInsets.only(bottom: listBottomPadding(context)),
        children: [
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr.importIcsCount(ics.events.length),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(tr.importIcsHint, style: theme.textTheme.bodySmall),
                if (ics.expanded > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    tr.importIcsExpanded(ics.expanded),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (ics.events.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(
                  () => all
                      ? _chosen.clear()
                      : _chosen.addAll([
                          for (var i = 0; i < ics.events.length; i++) i,
                        ]),
                ),
                child: Text(all ? tr.importIcsNone : tr.importIcsAll),
              ),
            ),
          for (final (i, e) in ics.events.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SoftCard(
                padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
                onTap: () => setState(
                  () =>
                      _chosen.contains(i) ? _chosen.remove(i) : _chosen.add(i),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: _chosen.contains(i),
                      onChanged: (v) => setState(
                        () => v ?? false ? _chosen.add(i) : _chosen.remove(i),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.title, style: theme.textTheme.titleMedium),
                          Text(
                            [
                              _when(e),
                              if (e.recurrence != null) tr.importIcsRepeats,
                            ].join(' · '),
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: c.text(accent),
                            ),
                          ),
                          if (e.location.isNotEmpty)
                            Text(e.location, style: theme.textTheme.bodySmall),
                          if (engine.event(e.id) != null)
                            Text(
                              tr.importIcsExisting,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: c.inkSoft,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (ics.skipped.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(tr.importIcsSkipped, style: theme.textTheme.titleSmall),
            for (final s in ics.skipped)
              Text(
                '${s.title}: ${localizeServerText(s.reason)}',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr.commonBack),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _chosen.isEmpty ? null : _add,
                child: Text(
                  _chosen.length == 1
                      ? tr.importTakeOver1Event
                      : tr.importTakeOverCountEvents(_chosen.length),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
