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
import '../widgets/files.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import 'list_connect_screen.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

enum _Filter {
  open,
  mine,
  done;

  String get label => switch (this) {
    open => tr.tasksFilterOpen,
    mine => tr.tasksFilterMine,
    done => tr.commonDoneCap,
  };
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
        assigneeIds: [if (_filter == _Filter.mine) engine.memberId],
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
      title: tr.sectionTasks,
      subtitle: tr.tasksTogetherWeCanDo,
      actions: [
        if (canConnectLists(AppScope.of(context)))
          BubbleButton(
            icon: AppIcons.arrowsLeftRight,
            tooltip: tr.commonConnectOtherApps,
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
        tooltip: tr.tasksCreateTaskDetails,
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
                      hintText: tr.tasksNewTask,
                      prefixIcon: const Icon(AppIcons.plus, size: 20),
                      suffixIcon: BubbleButton(
                        icon: AppIcons.arrowUp,
                        tooltip: tr.commonAdd,
                        color: Colors.white,
                        background: color,
                        size: 38,
                        onPressed: () => _add(engine),
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
                          _Filter.open => tr.tasksNothingDoEnjoyDay,
                          _Filter.mine => tr.tasksNothingAssignedYouRight,
                          _Filter.done => tr.tasksNothingDoneYet,
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
                                color: title == tr.commonOverdue
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
          (_filter != _Filter.mine || t.isAssignedTo(engine.memberId)),
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
      if (overdue.isNotEmpty) (tr.commonOverdue, overdue),
      if (dueToday.isNotEmpty) (tr.commonToday, dueToday),
      if (later.isNotEmpty) (tr.tasksComingUp, later),
      if (undated.isNotEmpty) (tr.tasksWithoutDate, undated),
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
    final assignees = [for (final id in task.assigneeIds) ?engine.member(id)];
    final overdue =
        !task.done &&
        task.due != null &&
        DateUtils.dateOnly(
          task.due!,
        ).isBefore(DateUtils.dateOnly(DateTime.now()));
    final remind = task.remindAt;
    final subtitle = [
      if (task.due != null) DateFormat.MMMEd(appLanguage).format(task.due!),
      if (task.repeat case final r?) '↻ ${r.label(task.repeatEvery)}',
      if (task.checklistProgress case final p?) '☑ $p',
      if (task.photos.where((f) => !f.isImage).length case final n when n > 0)
        '📎 $n',
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
                        persist: false,
                        content: Text(
                          tr.tasksTitleDoneDueAgain(
                            task.title,
                            DateFormat.MMMMEEEEd(appLanguage).format(next.due!),
                          ),
                        ),
                        action: SnackBarAction(
                          label: tr.commonUndo,
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            task.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              decoration: task.done
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: task.done ? c.inkSoft : null,
                            ),
                          ),
                        ),
                        if (task.visibleTo case final ids?) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: tr.caldavVisibleWho(
                              [
                                for (final id in ids)
                                  ?engine.member(id)?.displayName,
                              ].join(', '),
                            ),
                            child: Icon(
                              AppIcons.lockKey,
                              size: 16,
                              color: c.inkSoft,
                            ),
                          ),
                        ],
                      ],
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
            if (task.photos.where((f) => f.isImage).firstOrNull
                case final photo?) ...[
              Semantics(
                label: tr.commonPhoto,
                child: SizedBox.square(
                  dimension: 40,
                  child: CachedImage(photo, thumb: 160, radius: 10),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (assignees.isNotEmpty) _Assignees(assignees),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet to create or edit a task.
/// Up to three people taking care of a task, overlapping.
class _Assignees extends StatelessWidget {
  const _Assignees(this.members);

  final List<FamilyMember> members;

  @override
  Widget build(BuildContext context) {
    final shown = members.take(3).toList();
    return Semantics(
      label: members.map((m) => m.displayName).join(', '),
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, m) in shown.indexed)
              Align(
                widthFactor: i == shown.length - 1 ? 1 : 0.7,
                child: MemberAvatar(m),
              ),
            if (members.length > shown.length)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  '+${members.length - shown.length}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Audience { family, me, selected }

/// [draft]: a new task filled in beforehand (e.g. shared to Famio).
Future<void> showTaskEditor(BuildContext context, {Task? task, Task? draft}) =>
    showModalBottomSheet<void>(
      context: context,
      // Above the floating navigation bar.
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TaskEditor(task: task, draft: draft),
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
  const _TaskEditor({this.task, this.draft});

  final Task? task;
  final Task? draft;

  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  /// What the fields start with: the task, or the draft of a new one.
  Task? get _initial => widget.task ?? widget.draft;

  late final _title = TextEditingController(text: _initial?.title);
  late final _notes = TextEditingController(text: _initial?.notes);
  late DateTime? _due = _initial?.due;
  late final _assignees = [...?_initial?.assigneeIds];

  /// Checklist, files and who sees it; open when the task uses one of them.
  late var _more =
      (_initial?.checklist.isNotEmpty ?? false) ||
      (_initial?.photos.isNotEmpty ?? false) ||
      _initial?.visibleTo != null;

  /// Who else may see it, apart from me and whoever takes care of it.
  late final _seers = {...?_initial?.visibleTo}
    ..removeAll([..._assignees, AppScope.engineOf(context).memberId]);
  late var _audience = _initial?.visibleTo == null
      ? _Audience.family
      : _seers.isEmpty
      ? _Audience.me
      : _Audience.selected;
  late DateTime? _remindAt = _initial?.remindAt;
  late TaskRepeat? _repeat = _initial?.repeat;
  late int _repeatEvery = _initial?.repeatEvery ?? 1;
  late final _steps = [...?_initial?.checklist];
  final _newStep = TextEditingController();
  late final _photos = [...?_initial?.photos];
  var _uploading = false;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _newStep.dispose();
    super.dispose();
  }

  void _addStep() {
    final text = _newStep.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _steps.add(TaskStep(id: newId(), text: text));
      _newStep.clear();
    });
  }

  /// Camera, gallery or any file (PDF …); uploaded right away, so the task
  /// stays small.
  Future<void> _addPhoto() async {
    final picked = await pickFile(context);
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final ref = await uploadPicked(context, picked);
      if (mounted) setState(() => _photos.add(ref));
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty || _uploading) return;
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
        assigneeIds: [..._assignees],
        // Whoever takes care of it always sees it (the server adds them too).
        visibleTo: switch (_audience) {
          _Audience.family => null,
          _Audience.me => {engine.memberId, ..._assignees}.toList(),
          _Audience.selected => {
            engine.memberId,
            ..._seers,
            ..._assignees,
          }.toList(),
        },
        remindAt: _remindAt,
        repeat: _repeat,
        repeatEvery: _repeatEvery,
        checklist: [
          ..._steps,
          // Typed but not yet added with Enter: keep it too.
          if (_newStep.text.trim().isNotEmpty)
            TaskStep(id: newId(), text: _newStep.text.trim()),
        ],
        photos: _photos,
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
              task == null ? tr.tasksNewTask2 : tr.tasksEditTask,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: task == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr.commonTitle),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr.commonNotes),
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
                        ? tr.tasksDue
                        : DateFormat.MMMMEEEEd(appLanguage).format(_due!),
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
                        ? tr.tasksRemind
                        : tr.tasksReminderTime(dateTimeLabel(_remindAt!)),
                  ),
                  onPressed: _pickReminder,
                  onDeleted: _remindAt == null
                      ? null
                      : () => setState(() => _remindAt = null),
                ),
                PopupMenuButton<(TaskRepeat?, int)>(
                  tooltip: tr.eventRepeat,
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
                          r == null ? tr.tasksDoNotRepeat : _cap(r.label(n)),
                        ),
                      ),
                  ],
                  child: Chip(
                    avatar: const Icon(AppIcons.repeat, size: 18),
                    label: Text(
                      _repeat == null
                          ? tr.tasksRepeat
                          : _cap(_repeat!.label(_repeatEvery)),
                    ),
                  ),
                ),
              ],
            ),
            ListHeading(tr.tasksWhoTakesCare),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  avatar: const Icon(AppIcons.usersThree, size: 18),
                  label: Text(tr.commonEveryone),
                  selected: _assignees.isEmpty,
                  selectedColor: c.tint(FamioSection.tasks),
                  onSelected: (_) => setState(_assignees.clear),
                ),
                // Several people can share a task.
                for (final m in engine.members)
                  FilterChip(
                    avatar: MemberAvatar(m, radius: 10),
                    label: Text(m.displayName),
                    selected: _assignees.contains(m.id),
                    selectedColor: c.tint(FamioSection.tasks),
                    onSelected: (on) => setState(
                      () => on ? _assignees.add(m.id) : _assignees.remove(m.id),
                    ),
                  ),
              ],
            ),
            // Rarely needed: folded away, unless the task already uses it.
            if (!_more)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  icon: const Icon(AppIcons.plus, size: 18),
                  label: Text(tr.tasksMoreOptions),
                  onPressed: () => setState(() => _more = true),
                ),
              ),
            if (_more) ...[
              ListHeading(
                _steps.isEmpty
                    ? tr.tasksChecklist
                    : tr.tasksChecklistDoneTotal(
                        _steps.where((s) => s.done).length,
                        _steps.length,
                      ),
              ),
              for (final (i, step) in _steps.indexed)
                Row(
                  children: [
                    Checkbox(
                      value: step.done,
                      onChanged: (v) => setState(
                        () => _steps[i] = step.copyWith(done: v ?? false),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        step.text,
                        style: step.done
                            ? TextStyle(
                                decoration: TextDecoration.lineThrough,
                                color: c.inkSoft,
                              )
                            : null,
                      ),
                    ),
                    IconButton(
                      tooltip: tr.tasksRemoveItem,
                      icon: Icon(AppIcons.x, size: 18, color: c.inkSoft),
                      onPressed: () => setState(() => _steps.removeAt(i)),
                    ),
                  ],
                ),
              TextField(
                controller: _newStep,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: tr.tasksAddItemEG,
                  suffixIcon: IconButton(
                    tooltip: tr.commonAdd,
                    icon: const Icon(AppIcons.plus),
                    onPressed: _addStep,
                  ),
                ),
                onSubmitted: (_) => _addStep(),
              ),
              ListHeading(tr.tasksPhotos),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, photo) in _photos.indexed)
                    _PhotoThumb(
                      photo: photo,
                      onRemove: () => setState(() => _photos.removeAt(i)),
                    ),
                  SizedBox.square(
                    dimension: 72,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: _uploading ? null : _addPhoto,
                      child: _uploading
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Tooltip(
                              message: tr.tasksAddPhoto,
                              child: Icon(AppIcons.paperclip, color: color),
                            ),
                    ),
                  ),
                ],
              ),
              ListHeading(tr.commonWhoMaySee),
              RadioGroup<_Audience>(
                groupValue: _audience,
                onChanged: (v) => setState(() => _audience = v!),
                child: Column(
                  children: [
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _Audience.family,
                      title: Text(tr.tasksWholeFamily),
                    ),
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _Audience.me,
                      title: Text(tr.docsOnlyMe),
                    ),
                    if (engine.members.length > 1)
                      RadioListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _Audience.selected,
                        title: Text(tr.docsMe),
                      ),
                  ],
                ),
              ),
              if (_audience == _Audience.selected)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in engine.members)
                      if (m.id != engine.memberId)
                        FilterChip(
                          avatar: MemberAvatar(m, radius: 10),
                          label: Text(m.displayName),
                          selected:
                              _seers.contains(m.id) ||
                              _assignees.contains(m.id),
                          selectedColor: c.tint(FamioSection.tasks),
                          // Whoever takes care of it sees it anyway.
                          onSelected: _assignees.contains(m.id)
                              ? null
                              : (on) => setState(
                                  () => on
                                      ? _seers.add(m.id)
                                      : _seers.remove(m.id),
                                ),
                        ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr.tasksAudienceHint,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: c.inkSoft),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                if (task != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: Text(tr.commonDelete),
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
                ColorButton(
                  label: tr.commonSave,
                  color: color,
                  onPressed: _uploading ? null : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A task's photo in the editor: tap opens it, the cross takes it off.
class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.photo, required this.onRemove});

  final FileRef photo;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final open = Semantics(
      button: true,
      label: '${tr.tasksOpenPhoto}: ${photo.name}',
      child: GestureDetector(
        onTap: () => openFileRef(context, photo),
        child: photo.isImage
            ? CachedImage(photo, thumb: 160, radius: 14)
            // Other files (PDF …) as their icon and name.
            : Container(
                height: 72,
                constraints: const BoxConstraints(maxWidth: 200),
                padding: const EdgeInsets.fromLTRB(10, 8, 32, 8),
                decoration: BoxDecoration(
                  color: c.tint(FamioSection.tasks),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      fileIcon(photo.mime),
                      color: c.strong(FamioSection.tasks),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        photo.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
    final remove = Positioned(
      top: 2,
      right: 2,
      child: Material(
        color: c.surface.withValues(alpha: 0.9),
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: tr.tasksRemovePhoto,
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          icon: const Icon(AppIcons.x),
          onPressed: onRemove,
        ),
      ),
    );
    return photo.isImage
        ? SizedBox.square(
            dimension: 72,
            child: Stack(fit: StackFit.expand, children: [open, remove]),
          )
        : Stack(children: [open, remove]);
  }
}
