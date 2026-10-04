import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import 'list_connect_screen.dart';
import '../widgets/undo_delete.dart';

enum _Filter {
  open('Offen'),
  mine('Meine'),
  done('Erledigt');

  const _Filter(this.label);

  final String label;
}

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  var _filter = _Filter.open;
  final _quickAdd = TextEditingController();
  final _quickAddFocus = FocusNode();

  @override
  void dispose() {
    _quickAdd.dispose();
    _quickAddFocus.dispose();
    super.dispose();
  }

  void _add(SyncEngine engine) {
    final title = _quickAdd.text.trim();
    if (title.isEmpty) return;
    engine.saveTask(
      Task(
        id: newId(),
        title: title,
        createdAt: DateTime.now(),
        assigneeId: _filter == _Filter.mine ? engine.memberId : null,
      ),
    );
    _quickAdd.clear();
    _quickAddFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.tasks);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.tasks,
      title: 'Aufgaben',
      subtitle: 'Gemeinsam schaffen wir das',
      actions: [
        if (canConnectLists(AppScope.of(context)))
          BubbleButton(
            icon: AppIcons.arrowsLeftRight,
            tooltip: 'Mit anderen Apps verbinden',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    const ListConnectScreen(section: FamioSection.tasks),
              ),
            ),
          ),
        const SyncStatusIcon(),
      ],
      floating: AddButton(
        color: color,
        tooltip: 'Aufgabe mit Details anlegen',
        onPressed: () => showTaskEditor(context),
      ),
      body: DataBuilder(
        collections: const {Collections.tasks, 'members'},
        builder: (context, engine) {
          final sections = _sections(engine);
          return Column(
            children: [
              PillTabs<_Filter>(
                values: _Filter.values,
                selected: _filter,
                label: (f) => f.label,
                color: color,
                onChanged: (f) => setState(() => _filter = f),
              ),
              if (_filter != _Filter.done)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: TextField(
                    controller: _quickAdd,
                    focusNode: _quickAddFocus,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Neue Aufgabe …',
                      prefixIcon: const Icon(AppIcons.plus, size: 20),
                      suffixIcon: Padding(
                        padding: const EdgeInsets.all(6),
                        child: BubbleButton(
                          icon: AppIcons.arrowUp,
                          tooltip: 'Hinzufügen',
                          color: Colors.white,
                          background: color,
                          size: 38,
                          onPressed: () => _add(engine),
                        ),
                      ),
                    ),
                    onSubmitted: (_) => _add(engine),
                  ),
                ),
              Expanded(
                child: sections.isEmpty
                    ? EmptyHint(
                        icon: _filter == _Filter.done
                            ? AppIcons.hourglassMedium
                            : AppIcons.confetti,
                        color: color,
                        text: switch (_filter) {
                          _Filter.open => 'Nichts zu tun – genießt den Tag!',
                          _Filter.mine => 'Dir ist gerade nichts zugewiesen.',
                          _Filter.done => 'Noch nichts erledigt.',
                        },
                      )
                    : ListView(
                        padding: EdgeInsets.only(
                          bottom: listBottomPadding(context),
                        ),
                        children: [
                          for (final (title, tasks) in sections) ...[
                            if (title != null)
                              ListHeading(
                                title,
                                color: title == 'Überfällig'
                                    ? Theme.of(context).colorScheme.error
                                    : null,
                              ),
                            for (final task in tasks)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _TaskTile(task: task, engine: engine),
                              ),
                          ],
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<(String?, List<Task>)> _sections(SyncEngine engine) {
    final all = engine.tasks;
    if (_filter == _Filter.done) {
      final done = all.where((t) => t.done).toList()
        ..sort(
          (a, b) => (b.completedAt ?? DateTime(0)).compareTo(
            a.completedAt ?? DateTime(0),
          ),
        );
      return done.isEmpty ? [] : [(null, done)];
    }

    final open = all.where(
      (t) =>
          !t.done &&
          (_filter != _Filter.mine || t.assigneeId == engine.memberId),
    );
    final today = DateUtils.dateOnly(DateTime.now());
    final overdue = <Task>[],
        dueToday = <Task>[],
        later = <Task>[],
        undated = <Task>[];
    for (final t in open) {
      final due = t.due == null ? null : DateUtils.dateOnly(t.due!);
      if (due == null) {
        undated.add(t);
      } else if (due.isBefore(today)) {
        overdue.add(t);
      } else if (due == today) {
        dueToday.add(t);
      } else {
        later.add(t);
      }
    }
    int byDue(Task a, Task b) => a.due!.compareTo(b.due!);
    overdue.sort(byDue);
    later.sort(byDue);
    undated.sort(
      (a, b) =>
          (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
    );
    return [
      if (overdue.isNotEmpty) ('Überfällig', overdue),
      if (dueToday.isNotEmpty) ('Heute', dueToday),
      if (later.isNotEmpty) ('Demnächst', later),
      if (undated.isNotEmpty) ('Ohne Datum', undated),
    ];
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.engine});

  final Task task;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final assignee = engine.member(task.assigneeId);
    final overdue =
        !task.done &&
        task.due != null &&
        DateUtils.dateOnly(
          task.due!,
        ).isBefore(DateUtils.dateOnly(DateTime.now()));
    final remind = task.remindAt;
    final subtitle = [
      if (task.due != null) DateFormat('E, d. MMM', 'de').format(task.due!),
      if (task.repeat case final r?) '↻ ${r.label(task.repeatEvery)}',
      if (!task.done && remind != null && remind.isAfter(DateTime.now()))
        '⏰ ${dateTimeLabel(remind)}',
      if (task.notes.isNotEmpty) task.notes.split('\n').first,
    ].join(' · ');

    return Dismissible(
      key: ValueKey(task.id),
      direction: DismissDirection.endToStart,
      background: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(26),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Icon(AppIcons.trash, color: theme.colorScheme.onErrorContainer),
      ),
      onDismissed: (_) => deleteWithUndo(
        context,
        what: task.title,
        collections: const {Collections.tasks},
        delete: () => engine.deleteTask(task.id),
      ),
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
        onTap: () => showTaskEditor(context, task: task),
        child: Row(
          children: [
            RoundCheck(
              label: task.title,
              value: task.done,
              color: c.strong(FamioSection.tasks),
              onChanged: (done) {
                if (!done) {
                  engine.saveTask(
                    task.copyWith(done: false, completedAt: null),
                  );
                  return;
                }
                final next = task.completed();
                engine.saveTask(next);
                if (!next.done && next.due != null) {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(
                          '„${task.title}“ erledigt – wieder fällig '
                          '${DateFormat('EEEE, d. MMMM', 'de').format(next.due!)}',
                        ),
                        action: SnackBarAction(
                          label: 'Rückgängig',
                          onPressed: () => engine.saveTask(task),
                        ),
                      ),
                    );
                }
              },
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        decoration: task.done
                            ? TextDecoration.lineThrough
                            : null,
                        color: task.done ? c.inkSoft : null,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: overdue ? theme.colorScheme.error : null,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (assignee != null) MemberAvatar(assignee),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet to create or edit a task.
Future<void> showTaskEditor(BuildContext context, {Task? task}) =>
    showModalBottomSheet<void>(
      context: context,
      // Above the floating navigation bar.
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TaskEditor(task: task),
    );

const _repeatChoices = <(TaskRepeat?, int)>[
  (null, 1),
  (TaskRepeat.daily, 1),
  (TaskRepeat.weekly, 1),
  (TaskRepeat.weekly, 2),
  (TaskRepeat.monthly, 1),
  (TaskRepeat.monthly, 3),
  (TaskRepeat.yearly, 1),
];

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class _TaskEditor extends StatefulWidget {
  const _TaskEditor({this.task});

  final Task? task;

  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  late final _title = TextEditingController(text: widget.task?.title);
  late final _notes = TextEditingController(text: widget.task?.notes);
  late DateTime? _due = widget.task?.due;
  late String? _assigneeId = widget.task?.assigneeId;
  late DateTime? _remindAt = widget.task?.remindAt;
  late TaskRepeat? _repeat = widget.task?.repeat;
  late int _repeatEvery = widget.task?.repeatEvery ?? 1;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final engine = AppScope.engineOf(context);
    final base =
        widget.task ??
        Task(id: newId(), title: title, createdAt: DateTime.now());
    engine.saveTask(
      base.copyWith(
        title: title,
        notes: _notes.text.trim(),
        // A repeating task needs a day to count from.
        due: _repeat != null && _due == null
            ? DateUtils.dateOnly(DateTime.now())
            : _due,
        assigneeId: _assigneeId,
        remindAt: _remindAt,
        repeat: _repeat,
        repeatEvery: _repeatEvery,
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _due = picked);
  }

  Future<void> _pickReminder() async {
    final now = DateTime.now();
    final initial = _remindAt ?? _due ?? now;
    final day = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: DateUtils.dateOnly(now),
      lastDate: DateTime(now.year + 5),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _remindAt == null
          ? const TimeOfDay(hour: 18, minute: 0)
          : TimeOfDay.fromDateTime(_remindAt!),
    );
    if (time == null) return;
    setState(
      () => _remindAt = DateTime(
        day.year,
        day.month,
        day.day,
        time.hour,
        time.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final task = widget.task;
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.tasks);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              task == null ? 'Neue Aufgabe' : 'Aufgabe bearbeiten',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: task == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Titel'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Notizen'),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                InputChip(
                  avatar: const Icon(AppIcons.calendarCheck, size: 18),
                  label: Text(
                    _due == null
                        ? 'Fällig am …'
                        : DateFormat('EEEE, d. MMMM', 'de').format(_due!),
                  ),
                  onPressed: _pickDate,
                  onDeleted: _due == null
                      ? null
                      : () => setState(() => _due = null),
                ),
                InputChip(
                  avatar: const Icon(AppIcons.alarm, size: 18),
                  label: Text(
                    _remindAt == null
                        ? 'Erinnern …'
                        : 'Erinnerung ${dateTimeLabel(_remindAt!)}',
                  ),
                  onPressed: _pickReminder,
                  onDeleted: _remindAt == null
                      ? null
                      : () => setState(() => _remindAt = null),
                ),
                PopupMenuButton<(TaskRepeat?, int)>(
                  tooltip: 'Wiederholen',
                  initialValue: (_repeat, _repeatEvery),
                  onSelected: (v) => setState(() {
                    _repeat = v.$1;
                    _repeatEvery = v.$2;
                  }),
                  itemBuilder: (_) => [
                    for (final (r, n) in _repeatChoices)
                      PopupMenuItem(
                        value: (r, n),
                        child: Text(
                          r == null ? 'Nicht wiederholen' : _cap(r.label(n)),
                        ),
                      ),
                  ],
                  child: Chip(
                    avatar: const Icon(AppIcons.repeat, size: 18),
                    label: Text(
                      _repeat == null
                          ? 'Wiederholen …'
                          : _cap(_repeat!.label(_repeatEvery)),
                    ),
                  ),
                ),
              ],
            ),
            const ListHeading('Wer kümmert sich?'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  avatar: const Icon(AppIcons.usersThree, size: 18),
                  label: const Text('Alle'),
                  selected: _assigneeId == null,
                  selectedColor: c.tint(FamioSection.tasks),
                  onSelected: (_) => setState(() => _assigneeId = null),
                ),
                for (final m in engine.members)
                  ChoiceChip(
                    avatar: MemberAvatar(m, radius: 10),
                    label: Text(m.displayName),
                    selected: _assigneeId == m.id,
                    selectedColor: c.tint(FamioSection.tasks),
                    onSelected: (_) => setState(() => _assigneeId = m.id),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                if (task != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: const Text('Löschen'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: () {
                      deleteWithUndo(
                        context,
                        what: task.title,
                        collections: const {Collections.tasks},
                        delete: () => engine.deleteTask(task.id),
                      );
                      Navigator.pop(context);
                    },
                  ),
                const Spacer(),
                ColorButton(label: 'Speichern', color: color, onPressed: _save),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
