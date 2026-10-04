part of '../chores_screens.dart';

const _choreEmojis = [
  '🧹',
  '🍽️',
  '🗑️',
  '🛏️',
  '🧺',
  '🐶',
  '🪴',
  '🧸',
  '🚗',
  '🛒',
  '🧽',
  '📚',
];

Future<void> showChoreEditor(BuildContext context, {Chore? chore}) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ChoreEditor(chore: chore),
    );

class _ChoreEditor extends StatefulWidget {
  const _ChoreEditor({this.chore});

  final Chore? chore;

  @override
  State<_ChoreEditor> createState() => _ChoreEditorState();
}

class _ChoreEditorState extends State<_ChoreEditor> {
  late final _title = TextEditingController(text: widget.chore?.title);
  late var _emoji = widget.chore?.emoji ?? _choreEmojis.first;
  late var _points = widget.chore?.points ?? 2;
  late var _repeat = widget.chore?.repeat ?? ChoreRepeat.daily;
  late var _weekdays = {...?widget.chore?.weekdays};
  late var _date = widget.chore?.date ?? DateUtils.dateOnly(DateTime.now());
  late final _members = [...?widget.chore?.memberIds];
  late var _rotate = widget.chore?.rotate ?? false;
  late var _paused = widget.chore?.paused ?? false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final engine = AppScope.engineOf(context);
    final today = DateUtils.dateOnly(DateTime.now());
    final old = widget.chore;
    // A new rotation (other people or order) starts today.
    final restart =
        old == null ||
        old.rotate != _rotate ||
        old.memberIds.join() != _members.join();
    engine.saveChore(
      Chore(
        id: old?.id ?? newId(),
        title: title,
        emoji: _emoji,
        points: _points,
        memberIds: _members,
        rotate: _rotate && _members.length > 1,
        repeat: _repeat,
        weekdays: _repeat == ChoreRepeat.daily ? _weekdays : const {},
        date: _repeat == ChoreRepeat.once ? _date : null,
        start: restart ? today : old.start,
        paused: _paused,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final c = FamioColors.of(context);
    final tint = c.tint(FamioSection.chores);
    final chore = widget.chore;
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
              chore == null ? 'Neues Amt' : 'Amt bearbeiten',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: chore == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Was ist zu tun?',
                hintText: 'z. B. Spülmaschine ausräumen',
              ),
            ),
            const SizedBox(height: 12),
            _EmojiRow(
              emojis: _choreEmojis,
              selected: _emoji,
              onSelected: (e) => setState(() => _emoji = e),
            ),
            const ListHeading('Punkte'),
            _Stepper(
              value: _points,
              min: 0,
              max: 100,
              onChanged: (v) => setState(() => _points = v),
            ),
            const ListHeading('Wie oft?'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in ChoreRepeat.values)
                  ChoiceChip(
                    label: Text(r.label),
                    selected: _repeat == r,
                    selectedColor: tint,
                    onSelected: (_) => setState(() => _repeat = r),
                  ),
              ],
            ),
            if (_repeat == ChoreRepeat.daily) ...[
              const SizedBox(height: 8),
              _WeekdayPicker(
                selected: _weekdays,
                onChanged: (d) => setState(() => _weekdays = d),
              ),
            ],
            if (_repeat == ChoreRepeat.once) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  avatar: const Icon(AppIcons.calendarCheck, size: 18),
                  label: Text(DateFormat('EEEE, d. MMMM', 'de').format(_date)),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(_date.year - 1),
                      lastDate: DateTime(_date.year + 2),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                ),
              ),
            ],
            const ListHeading('Wer?'),
            Text(
              _members.isEmpty
                  ? 'Niemand ausgewählt: jeder darf es übernehmen.'
                  : 'Reihenfolge = Reihenfolge beim Abwechseln.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in engine.members.where(
                  (m) => m.role != MemberRole.guest,
                ))
                  FilterChip(
                    avatar: MemberAvatar(m, radius: 10),
                    label: Text(
                      _members.contains(m.id)
                          ? '${_members.indexOf(m.id) + 1}. ${m.displayName}'
                          : m.displayName,
                    ),
                    selected: _members.contains(m.id),
                    selectedColor: tint,
                    showCheckmark: false,
                    onSelected: (on) => setState(
                      () => on ? _members.add(m.id) : _members.remove(m.id),
                    ),
                  ),
              ],
            ),
            if (_members.length > 1)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Abwechseln'),
                subtitle: Text(
                  _repeat == ChoreRepeat.weekly
                      ? 'Jede Woche ist jemand anderes dran'
                      : 'Jeden Tag ist jemand anderes dran',
                ),
                value: _rotate,
                onChanged: (v) => setState(() => _rotate = v),
              ),
            if (chore != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pausieren'),
                subtitle: const Text('z. B. in den Ferien'),
                value: _paused,
                onChanged: (v) => setState(() => _paused = v),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (chore != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: const Text('Löschen'),
                    style: TextButton.styleFrom(foregroundColor: c.danger),
                    onPressed: () {
                      deleteWithUndo(
                        context,
                        what: chore.title,
                        collections: const {Collections.chores},
                        delete: () => engine.deleteChore(chore.id),
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

class _EmojiRow extends StatelessWidget {
  const _EmojiRow({
    required this.emojis,
    required this.selected,
    required this.onSelected,
  });

  final List<String> emojis;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final e in emojis)
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onSelected(e),
            child: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: e == selected ? c.tint(FamioSection.chores) : null,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: e == selected ? c.strong(FamioSection.chores) : c.line,
                ),
              ),
              child: Text(e, style: const TextStyle(fontSize: 22)),
            ),
          ),
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 999,
    this.step = 1,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  final int step;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton.outlined(
        tooltip: 'Weniger',
        icon: const Icon(AppIcons.minus),
        onPressed: value - step < min ? null : () => onChanged(value - step),
      ),
      SizedBox(
        width: 80,
        child: Text(
          '$value ⭐',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      IconButton.outlined(
        tooltip: 'Mehr',
        icon: const Icon(AppIcons.plus),
        onPressed: value + step > max ? null : () => onChanged(value + step),
      ),
    ],
  );
}

class _WeekdayPicker extends StatelessWidget {
  const _WeekdayPicker({required this.selected, required this.onChanged});

  /// Empty = every day.
  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;

  @override
  Widget build(BuildContext context) {
    final tint = FamioColors.of(context).tint(FamioSection.chores);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var d = 1; d <= 7; d++)
          FilterChip(
            label: Text(_weekdayShort[d - 1]),
            showCheckmark: false,
            selectedColor: tint,
            selected: selected.isEmpty || selected.contains(d),
            onSelected: (on) {
              final days = selected.isEmpty
                  ? {1, 2, 3, 4, 5, 6, 7}
                  : {...selected};
              on ? days.add(d) : days.remove(d);
              if (days.isEmpty) return;
              onChanged(days.length == 7 ? {} : days);
            },
          ),
      ],
    );
  }
}

// --- routines -------------------------------------------------------------------
