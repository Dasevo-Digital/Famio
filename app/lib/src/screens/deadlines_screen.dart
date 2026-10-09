import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/deadlines.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/dispose_with.dart';
import '../widgets/member_avatar.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

DateFormat get _date => DateFormat.yMd(appLanguage);

/// TÜV, boiler service, the dog's vaccination: dates that come back and
/// must not be missed, with a reminder ahead of time.
class DeadlinesScreen extends StatelessWidget {
  const DeadlinesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {Collections.deadlines, 'members'},
      builder: (context, engine) {
        final all = engine.deadlines;
        final open = all.where((d) => !d.done).toList();
        final done = all.where((d) => d.done).toList();
        final mayEdit = engine.iAmAdult;
        final c = FamioColors.of(context);
        final accent = c.strong(FamioSection.tasks);
        return SectionPage(
          section: FamioSection.tasks,
          title: tr.settingsDeadlines,
          subtitle: tr.deadlinesCarHousePets,
          maxBodyWidth: 720,
          floating: mayEdit
              ? AddButton(
                  color: accent,
                  tooltip: tr.deadlinesAddDeadline,
                  icon: AppIcons.plus,
                  onPressed: () => showDeadlineEditor(context),
                )
              : null,
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              if (open.isEmpty)
                SoftCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr.deadlinesFamioRemindsYouGood),
                      if (mayEdit) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final p in deadlinePresets.where(
                              (p) => {
                                tr.deadlinesCarInspection,
                                tr.deadlinesHeatingMaintenance,
                                tr.deadlinesTestSmokeDetectors,
                                tr.commonVaccination,
                              }.contains(p.title),
                            ))
                              ActionChip(
                                avatar: Text(p.area.emoji),
                                label: Text(p.title),
                                onPressed: () =>
                                    showDeadlineEditor(context, preset: p),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              for (final area in DeadlineArea.values)
                if (open.any((d) => d.area == area)) ...[
                  ListHeading('${area.emoji} ${area.label}', color: accent),
                  for (final d in open.where((d) => d.area == area))
                    _DeadlineCard(deadline: d, engine: engine),
                ],
              if (done.isNotEmpty) ...[
                ListHeading(tr.commonDoneCap, color: accent),
                for (final d in done)
                  _DeadlineCard(deadline: d, engine: engine),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DeadlineCard extends StatelessWidget {
  const _DeadlineCard({required this.deadline, required this.engine});

  final Deadline deadline;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final d = deadline;
    final now = DateTime.now();
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final days = d.daysLeft(now);
    final urgent = !d.done && days <= d.leadDays;
    final who = d.assigneeId == null ? null : engine.member(d.assigneeId!);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SoftCard(
        color: d.done ? c.surfaceSoft : null,
        onTap: engine.iAmAdult
            ? () => showDeadlineEditor(context, existing: d)
            : null,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.label, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    d.done
                        ? tr.deadlinesDoneDate(
                            _date.format(d.lastDone ?? d.due),
                          )
                        : '${_date.format(d.due)} · ${deadlineWhen(d, now)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: days < 0 && !d.done
                          ? theme.colorScheme.error
                          : urgent
                          ? c.strong(FamioSection.tasks)
                          : c.inkSoft,
                      fontWeight: urgent ? FontWeight.w600 : null,
                    ),
                  ),
                  if (d.repeatMonths != null || d.note.isNotEmpty)
                    Text(
                      [
                        if (d.repeatMonths != null) _every(d.repeatMonths!),
                        if (d.note.isNotEmpty) d.note,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            if (who != null) ...[
              MemberAvatar(who, radius: 14),
              const SizedBox(width: 8),
            ],
            if (!d.done && (engine.iAmAdult || d.assigneeId == engine.memberId))
              FilledButton.tonal(
                onPressed: () {
                  final next = d.completed(DateTime.now());
                  engine.saveDeadline(next);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      persist: false,
                      content: Text(
                        next.done
                            ? tr.deadlinesTitleDone(d.title)
                            : tr.deadlinesNextTimeDate(_date.format(next.due)),
                      ),
                      action: SnackBarAction(
                        label: tr.commonUndo,
                        onPressed: () => engine.saveDeadline(d),
                      ),
                    ),
                  );
                },
                child: Text(tr.commonDoneCap),
              ),
          ],
        ),
      ),
    );
  }
}

String _every(int months) => switch (months) {
  1 => tr.deadlinesEveryMonth,
  12 => tr.deadlinesEveryYear,
  24 => tr.deadlinesEvery2Years,
  36 => tr.deadlinesEvery3Years,
  _ => tr.deadlinesEveryMonthsMonths(months),
};

/// Adds or edits a deadline; [preset] fills in a suggestion.
Future<void> showDeadlineEditor(
  BuildContext context, {
  Deadline? existing,
  DeadlinePreset? preset,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => _DeadlineEditor(existing: existing, preset: preset),
);

class _DeadlineEditor extends StatefulWidget {
  const _DeadlineEditor({this.existing, this.preset});

  final Deadline? existing;
  final DeadlinePreset? preset;

  @override
  State<_DeadlineEditor> createState() => _DeadlineEditorState();
}

class _DeadlineEditorState extends State<_DeadlineEditor> {
  late final _title = TextEditingController(
    text: widget.existing?.title ?? widget.preset?.title,
  );
  late final _subject = TextEditingController(text: widget.existing?.subject);
  late final _note = TextEditingController(text: widget.existing?.note);
  late var _area =
      widget.existing?.area ?? widget.preset?.area ?? DeadlineArea.car;
  late var _due =
      widget.existing?.due ??
      DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 30));
  late int? _repeat = widget.existing != null
      ? widget.existing!.repeatMonths
      : widget.preset?.repeatMonths ?? 12;
  late var _lead = widget.existing?.leadDays ?? 14;
  late String? _assignee = widget.existing?.assigneeId;

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final engine = AppScope.engineOf(context);
    final old = widget.existing;
    engine.saveDeadline(
      Deadline(
        id: old?.id ?? newId(),
        title: title,
        due: _due,
        area: _area,
        subject: _subject.text.trim(),
        repeatMonths: _repeat,
        leadDays: _lead,
        assigneeId: _assignee,
        note: _note.text.trim(),
        lastDone: old?.lastDone,
        // A new date opens a finished one-off again.
        done: (old?.done ?? false) && old?.due == _due,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final existing = widget.existing;
    final adults = [
      for (final m in engine.members)
        if (!m.isGuest && !m.isService) m,
    ];
    return DisposeWith(
      controllers: [_title, _subject, _note],
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                existing == null
                    ? tr.deadlinesNewDeadline
                    : tr.deadlinesEditDeadline,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in DeadlineArea.values)
                    ChoiceChip(
                      label: Text('${a.emoji} ${a.label}'),
                      selected: _area == a,
                      onSelected: (_) => setState(() => _area = a),
                    ),
                ],
              ),
              if (existing == null) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in deadlinePresets.where(
                      (p) => p.area == _area,
                    ))
                      ActionChip(
                        label: Text(p.title),
                        onPressed: () => setState(() {
                          _title.text = p.title;
                          _repeat = p.repeatMonths;
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: tr.wishesWhat),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _subject,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: switch (_area) {
                    DeadlineArea.car => tr.deadlinesWhichCarOptional,
                    DeadlineArea.pet => tr.deadlinesWhichPetOptional,
                    _ => tr.budgetWhatOptional,
                  },
                ),
              ),
              if (widget.preset?.hint case final hint?) ...[
                const SizedBox(height: 6),
                Text(hint, style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(AppIcons.calendarBlank),
                title: Text(tr.deadlinesDue),
                trailing: Text(_date.format(_due)),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _due,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _due = picked);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(AppIcons.arrowsClockwise),
                title: Text(tr.eventRepeat),
                trailing: DropdownButton<int?>(
                  value: _repeat,
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(tr.deadlinesOnce),
                    ),
                    for (final m in const [1, 3, 6, 12, 24, 36])
                      DropdownMenuItem(value: m, child: Text(_every(m))),
                    if (_repeat != null &&
                        !const [1, 3, 6, 12, 24, 36].contains(_repeat))
                      DropdownMenuItem(
                        value: _repeat,
                        child: Text(_every(_repeat!)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _repeat = v),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(AppIcons.bell),
                title: Text(tr.deadlinesRemind),
                trailing: DropdownButton<int>(
                  value: _lead,
                  items: [
                    for (final d in {3, 7, 14, 30, 60, _lead})
                      DropdownMenuItem(
                        value: d,
                        child: Text(
                          d == 0
                              ? tr.deadlinesDayItself
                              : tr.deadlinesDaysDaysBefore(d),
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _lead = v ?? _lead),
                ),
              ),
              DropdownButtonFormField<String?>(
                initialValue: adults.any((m) => m.id == _assignee)
                    ? _assignee
                    : null,
                decoration: InputDecoration(labelText: tr.tasksWhoTakesCare),
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(tr.deadlinesAdults),
                  ),
                  for (final m in adults)
                    DropdownMenuItem(value: m.id, child: Text(m.displayName)),
                ],
                onChanged: (v) => setState(() => _assignee = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                decoration: InputDecoration(
                  labelText: tr.deadlinesNoteGaragePhoneNumber,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (existing != null)
                    TextButton.icon(
                      icon: const Icon(AppIcons.trash),
                      label: Text(tr.commonDelete),
                      onPressed: () {
                        Navigator.pop(context);
                        deleteWithUndo(
                          context,
                          what: existing.title,
                          collections: const {Collections.deadlines},
                          delete: () => engine.deleteDeadline(existing.id),
                        );
                      },
                    ),
                  const Spacer(),
                  FilledButton(onPressed: _save, child: Text(tr.commonSave)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
