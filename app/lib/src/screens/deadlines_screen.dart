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

final _date = DateFormat('d.M.y', 'de');

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
          title: 'Fristen & Wartung',
          subtitle: 'Auto, Haus und Haustiere',
          maxBodyWidth: 720,
          floating: mayEdit
              ? AddButton(
                  color: accent,
                  tooltip: 'Frist hinzufügen',
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
                      const Text(
                        'Famio erinnert rechtzeitig an TÜV, Heizungswartung, '
                        'Impfungen der Haustiere und alles, was regelmäßig '
                        'wiederkommt. Ist es erledigt, rückt die Frist '
                        'automatisch weiter.',
                      ),
                      if (mayEdit) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final p in deadlinePresets.where(
                              (p) => const {
                                'HU/TÜV',
                                'Heizungswartung',
                                'Rauchmelder testen',
                                'Impfung',
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
                ListHeading('Erledigt', color: accent),
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
                        ? 'Erledigt am ${_date.format(d.lastDone ?? d.due)}'
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
                            ? '„${d.title}“ erledigt'
                            : 'Nächstes Mal: ${_date.format(next.due)}',
                      ),
                      action: SnackBarAction(
                        label: 'Rückgängig',
                        onPressed: () => engine.saveDeadline(d),
                      ),
                    ),
                  );
                },
                child: const Text('Erledigt'),
              ),
          ],
        ),
      ),
    );
  }
}

String _every(int months) => switch (months) {
  1 => 'jeden Monat',
  12 => 'jedes Jahr',
  24 => 'alle 2 Jahre',
  36 => 'alle 3 Jahre',
  _ => 'alle $months Monate',
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
                existing == null ? 'Neue Frist' : 'Frist bearbeiten',
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
                decoration: const InputDecoration(labelText: 'Was?'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _subject,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: switch (_area) {
                    DeadlineArea.car => 'Welches Auto? (optional)',
                    DeadlineArea.pet => 'Welches Tier? (optional)',
                    _ => 'Wofür? (optional)',
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
                title: const Text('Fällig am'),
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
                title: const Text('Wiederholen'),
                trailing: DropdownButton<int?>(
                  value: _repeat,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('einmalig'),
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
                title: const Text('Erinnern'),
                trailing: DropdownButton<int>(
                  value: _lead,
                  items: [
                    for (final d in {3, 7, 14, 30, 60, _lead})
                      DropdownMenuItem(
                        value: d,
                        child: Text(
                          d == 0 ? 'am Tag selbst' : '$d Tage vorher',
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
                decoration: const InputDecoration(
                  labelText: 'Wer kümmert sich?',
                ),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Die Erwachsenen'),
                  ),
                  for (final m in adults)
                    DropdownMenuItem(value: m.id, child: Text(m.displayName)),
                ],
                onChanged: (v) => setState(() => _assignee = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                decoration: const InputDecoration(
                  labelText: 'Notiz (Werkstatt, Telefonnummer …)',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (existing != null)
                    TextButton.icon(
                      icon: const Icon(AppIcons.trash),
                      label: const Text('Löschen'),
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
                  FilledButton(
                    onPressed: _save,
                    child: const Text('Speichern'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
