import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';
import '../data/free_slots.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import 'event_editor.dart';

/// "Wann haben alle Zeit?": free times of the chosen people in the next
/// two weeks; a tap creates the appointment for them.
class FreeTimeScreen extends StatefulWidget {
  const FreeTimeScreen({super.key});

  @override
  State<FreeTimeScreen> createState() => _FreeTimeScreenState();
}

class _FreeTimeScreenState extends State<FreeTimeScreen> {
  Set<String>? _who;
  var _length = const Duration(hours: 1);
  var _hours = (8, 20);

  static const _lengths = [
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(minutes: 90),
    Duration(hours: 2),
    Duration(hours: 3),
  ];

  static String _lengthLabel(Duration d) => d.inMinutes < 60
      ? tr.cookMinutes('${d.inMinutes}')
      : tr.freeTimeHours(
          NumberFormat.decimalPattern(appLanguage).format(d.inMinutes / 60),
        );

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.calendar);
    final theme = Theme.of(context);
    return DataBuilder(
      collections: const {
        Collections.events,
        Collections.externalEvents,
        'members',
      },
      builder: (context, engine) {
        final people = [
          for (final m in engine.members)
            if (!m.isService) m,
        ];
        final who =
            _who ??
            {
              engine.memberId,
              for (final m in people)
                if (m.isAdult) m.id,
            };
        final now = DateTime.now();
        final slots = who.isEmpty
            ? const <FreeSlot>[]
            : freeSlots(
                occurrences: engine.occurrences(
                  DateTime(now.year, now.month, now.day),
                  DateTime(now.year, now.month, now.day + 15),
                ),
                memberIds: who,
                from: now,
                length: _length,
                startHour: _hours.$1,
                endHour: _hours.$2,
                max: 20,
              );
        final day = DateFormat.MMMMEEEEd(appLanguage);
        final time = DateFormat.Hm(appLanguage);
        final byDay = <DateTime, List<FreeSlot>>{};
        for (final s in slots) {
          (byDay[DateUtils.dateOnly(s.start)] ??= []).add(s);
        }
        return SectionPage(
          section: FamioSection.calendar,
          title: tr.freeTimeTitle,
          subtitle: tr.freeTimeSubtitle,
          body: ListView(
            padding: EdgeInsets.only(
              top: 4,
              bottom: listBottomPadding(context),
            ),
            children: [
              ListHeading(tr.freeTimeWho, color: color),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in people)
                    FilterChip(
                      avatar: MemberAvatar(m, radius: 12),
                      label: Text(m.displayName),
                      selected: who.contains(m.id),
                      onSelected: (on) =>
                          setState(() => _who = {...who}..toggle(m.id, on)),
                    ),
                ],
              ),
              ListHeading(tr.freeTimeHowLong, color: color),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final l in _lengths)
                    ChoiceChip(
                      label: Text(_lengthLabel(l)),
                      selected: _length == l,
                      onSelected: (_) => setState(() => _length = l),
                    ),
                ],
              ),
              ListHeading(tr.freeTimeWhen, color: color),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (label, hours) in [
                    (tr.freeTimeMorning, (7, 12)),
                    (tr.freeTimeDay, (8, 20)),
                    (tr.freeTimeEvening, (17, 22)),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _hours == hours,
                      onSelected: (_) => setState(() => _hours = hours),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(tr.freeTimeHint, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              if (slots.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(tr.freeTimeNone),
                ),
              for (final MapEntry(key: d, value: free) in byDay.entries) ...[
                ListHeading(day.format(d)),
                for (final s in free)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SoftCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        title: Text(
                          '${time.format(s.start)} – ${time.format(s.end)}',
                        ),
                        trailing: Icon(AppIcons.plus, color: color),
                        onTap: () => showEventEditor(
                          context,
                          start: s.start,
                          end: s.end,
                          memberIds: who,
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

extension on Set<String> {
  void toggle(String id, bool on) => on ? add(id) : remove(id);
}
