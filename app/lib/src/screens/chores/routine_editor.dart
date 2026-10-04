part of '../chores_screens.dart';

Future<void> showRoutineEditor(
  BuildContext context, {
  Routine? routine,
  Routine? preset,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _RoutineEditor(routine: routine, preset: preset),
);

class _RoutineEditor extends StatefulWidget {
  const _RoutineEditor({this.routine, this.preset});

  final Routine? routine;
  final Routine? preset;

  @override
  State<_RoutineEditor> createState() => _RoutineEditorState();
}

class _EditableStep {
  _EditableStep(this.id, String title, String emoji)
    : title = TextEditingController(text: title),
      emoji = TextEditingController(text: emoji);

  final String id;
  final TextEditingController title;
  final TextEditingController emoji;

  void dispose() {
    title.dispose();
    emoji.dispose();
  }
}

class _RoutineEditorState extends State<_RoutineEditor> {
  late final Routine? _base = widget.routine ?? widget.preset;
  late final _title = TextEditingController(text: _base?.title);
  late var _emoji = _base?.emoji ?? '☀️';
  late String? _memberId = _base?.memberId;
  late var _weekdays = {...?_base?.weekdays};
  late String? _time = _base?.time;
  late var _points = _base?.points ?? 0;
  late final _steps = [
    for (final s in _base?.steps ?? const <RoutineStep>[])
      _EditableStep(widget.routine == null ? newId() : s.id, s.title, s.emoji),
  ];

  @override
  void dispose() {
    _title.dispose();
    for (final s in _steps) {
      s.dispose();
    }
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    AppScope.engineOf(context).saveRoutine(
      Routine(
        id: widget.routine?.id ?? newId(),
        title: title,
        emoji: _emoji,
        memberId: _memberId,
        weekdays: _weekdays,
        time: _time,
        points: _points,
        steps: [
          for (final s in _steps)
            if (s.title.text.trim().isNotEmpty)
              RoutineStep(
                id: s.id,
                title: s.title.text.trim(),
                emoji: s.emoji.text.trim(),
              ),
        ],
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final c = FamioColors.of(context);
    final tint = c.tint(FamioSection.chores);
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
              widget.routine == null ? 'Neue Routine' : 'Routine bearbeiten',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            _EmojiRow(
              emojis: const ['☀️', '🌙', '🏫', '🏃', '🧼', '🎹'],
              selected: _emoji,
              onSelected: (e) => setState(() => _emoji = e),
            ),
            const ListHeading('Für wen?'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Alle'),
                  selected: _memberId == null,
                  selectedColor: tint,
                  onSelected: (_) => setState(() => _memberId = null),
                ),
                for (final m in engine.pointCollectors)
                  ChoiceChip(
                    avatar: MemberAvatar(m, radius: 10),
                    label: Text(m.displayName),
                    selected: _memberId == m.id,
                    selectedColor: tint,
                    onSelected: (_) => setState(() => _memberId = m.id),
                  ),
              ],
            ),
            const ListHeading('An welchen Tagen?'),
            _WeekdayPicker(
              selected: _weekdays,
              onChanged: (d) => setState(() => _weekdays = d),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                InputChip(
                  avatar: const Icon(AppIcons.alarm, size: 18),
                  label: Text(
                    _time == null ? 'Erinnern um …' : 'Erinnerung $_time',
                  ),
                  onPressed: () async {
                    final parts = (_time ?? '07:00').split(':');
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                        hour: int.parse(parts[0]),
                        minute: int.parse(parts[1]),
                      ),
                    );
                    if (picked != null) {
                      setState(
                        () => _time =
                            '${picked.hour.toString().padLeft(2, '0')}:'
                            '${picked.minute.toString().padLeft(2, '0')}',
                      );
                    }
                  },
                  onDeleted: _time == null
                      ? null
                      : () => setState(() => _time = null),
                ),
              ],
            ),
            const ListHeading('Punkte, wenn alles erledigt ist'),
            _Stepper(
              value: _points,
              max: 50,
              onChanged: (v) => setState(() => _points = v),
            ),
            const ListHeading('Schritte'),
            for (final (i, step) in _steps.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: TextField(
                        controller: step.emoji,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 22),
                        decoration: const InputDecoration(
                          hintText: '🙂',
                          contentPadding: EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: step.title,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: 'Schritt ${i + 1}',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Nach oben',
                      icon: const Icon(AppIcons.arrowUp),
                      onPressed: i == 0
                          ? null
                          : () => setState(() {
                              _steps.insert(i - 1, _steps.removeAt(i));
                            }),
                    ),
                    IconButton(
                      tooltip: 'Entfernen',
                      icon: const Icon(AppIcons.x),
                      onPressed: () => setState(() {
                        _steps.removeAt(i).dispose();
                      }),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.plus),
                label: const Text('Schritt hinzufügen'),
                onPressed: () =>
                    setState(() => _steps.add(_EditableStep(newId(), '', ''))),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.routine != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: const Text('Löschen'),
                    style: TextButton.styleFrom(foregroundColor: c.danger),
                    onPressed: () {
                      deleteWithUndo(
                        context,
                        what: widget.routine!.title,
                        collections: const {Collections.routines},
                        delete: () => engine.deleteRoutine(widget.routine!.id),
                      );
                      Navigator.pop(context);
                    },
                  ),
                const Spacer(),
                ColorButton(
                  label: 'Speichern',
                  color: c.strong(FamioSection.chores),
                  onPressed: _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// --- rewards -----------------------------------------------------------------------
