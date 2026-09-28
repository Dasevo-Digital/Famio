import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';

const _collections = {
  Collections.chores,
  Collections.routines,
  Collections.routineRuns,
  Collections.rewards,
  Collections.pointEntries,
  Collections.allowances,
  Collections.moneyEntries,
  'members',
};

enum _Tab {
  today('Heute'),
  chores('Ämter'),
  routines('Routinen'),
  rewards('Belohnungen'),
  accounts('Konto');

  const _Tab(this.label);

  final String label;
}

const _weekdayShort = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

/// Chores with points, kids' routines, rewards and pocket money.
class ChoresScreen extends StatefulWidget {
  const ChoresScreen({super.key});

  @override
  State<ChoresScreen> createState() => _ChoresScreenState();
}

class _ChoresScreenState extends State<ChoresScreen> {
  var _tab = _Tab.today;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.chores);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.chores,
      title: 'Ämter & Punkte',
      subtitle: 'Mithelfen lohnt sich',
      actions: const [SyncStatusIcon()],
      floating: DataBuilder(
        collections: const {'members'},
        builder: (context, engine) {
          if (!engine.iAmAdult) return const SizedBox.shrink();
          return switch (_tab) {
            _Tab.chores || _Tab.today => AddButton(
              color: color,
              tooltip: 'Amt anlegen',
              onPressed: () => showChoreEditor(context),
            ),
            _Tab.routines => AddButton(
              color: color,
              tooltip: 'Routine anlegen',
              onPressed: () => showRoutineEditor(context),
            ),
            _Tab.rewards => AddButton(
              color: color,
              tooltip: 'Belohnung anlegen',
              onPressed: () => showRewardEditor(context),
            ),
            _Tab.accounts => const SizedBox.shrink(),
          };
        },
      ),
      body: Column(
        children: [
          PillTabs<_Tab>(
            values: _Tab.values,
            selected: _tab,
            label: (t) => t.label,
            color: color,
            onChanged: (t) => setState(() => _tab = t),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: DataBuilder(
              collections: _collections,
              builder: (context, engine) => switch (_tab) {
                _Tab.today => _TodayTab(engine: engine),
                _Tab.chores => _ChoresTab(engine: engine),
                _Tab.routines => _RoutinesTab(engine: engine),
                _Tab.rewards => _RewardsTab(engine: engine),
                _Tab.accounts => _AccountsTab(engine: engine),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Members shown on "Heute": children see themselves, adults everyone
/// who collects points.
List<FamilyMember> _people(SyncEngine engine) {
  final me = engine.me;
  if (me != null && me.role == MemberRole.child) return [me];
  return engine.pointCollectors;
}

class _PointsChip extends StatelessWidget {
  const _PointsChip(this.points, {this.big = false});

  final int points;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: big ? 14 : 10,
        vertical: big ? 6 : 3,
      ),
      decoration: BoxDecoration(
        color: c.tint(FamioSection.chores),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '⭐ $points',
        style:
            (big
                    ? Theme.of(context).textTheme.titleMedium
                    : Theme.of(context).textTheme.labelLarge)
                ?.copyWith(color: c.strong(FamioSection.chores)),
      ),
    );
  }
}

// --- today -------------------------------------------------------------------

class _TodayTab extends StatelessWidget {
  const _TodayTab({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.chores);
    final today = DateUtils.dateOnly(DateTime.now());
    final pending = engine.iAmAdult ? engine.pendingPoints : <PointEntry>[];
    final people = _people(engine);
    final shared = [
      for (final ch in engine.chores)
        if (ch.dueOn(today) &&
            ch.assigneeOn(today) == null &&
            ch.memberIds.isEmpty)
          ch,
    ];
    if (engine.chores.isEmpty && engine.routines.isEmpty && pending.isEmpty) {
      return EmptyHint(
        icon: AppIcons.trophy,
        color: color,
        text: engine.iAmAdult
            ? 'Noch keine Ämter.\nLegt fest, wer was im Haushalt übernimmt – '
                  'mit Punkten für die Kinder.'
            : 'Noch keine Ämter – frag deine Eltern!',
        action: engine.iAmAdult
            ? ColorButton(
                label: 'Erstes Amt anlegen',
                color: color,
                icon: AppIcons.plus,
                onPressed: () => showChoreEditor(context),
              )
            : null,
      );
    }
    return ListView(
      padding: EdgeInsets.only(bottom: listBottomPadding(context)),
      children: [
        if (pending.isNotEmpty) ...[
          ListHeading('Wartet auf deine Bestätigung', color: color),
          for (final e in pending)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _PendingTile(entry: e, engine: engine),
            ),
        ],
        for (final person in people)
          _PersonToday(person: person, engine: engine, day: today),
        if (shared.isNotEmpty) ...[
          const ListHeading('Für alle'),
          for (final chore in shared)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ChoreTile(
                chore: chore,
                engine: engine,
                day: today,
                forMember: null,
              ),
            ),
        ],
      ],
    );
  }
}

class _PendingTile extends StatelessWidget {
  const _PendingTile({required this.entry, required this.engine});

  final PointEntry entry;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final who = engine.member(entry.memberId);
    final c = FamioColors.of(context);
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          if (who != null) MemberAvatar(who, radius: 16),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.kind == PointKind.reward
                      ? '${who?.displayName ?? '?'} wünscht sich ${entry.title}'
                      : '${who?.displayName ?? '?'}: ${entry.title}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  entry.points > 0
                      ? '+${entry.points} Punkte'
                      : '${entry.points} Punkte · Kontostand ⭐ '
                            '${engine.pointBalance(entry.memberId)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Ablehnen',
            color: c.danger,
            icon: const Icon(AppIcons.x),
            onPressed: () => engine.decidePoints(entry, approve: false),
          ),
          IconButton.filled(
            tooltip: 'Bestätigen',
            style: IconButton.styleFrom(
              backgroundColor: c.strong(FamioSection.chores),
            ),
            icon: const Icon(AppIcons.check, color: Colors.white),
            onPressed: () => engine.decidePoints(entry, approve: true),
          ),
        ],
      ),
    );
  }
}

class _PersonToday extends StatelessWidget {
  const _PersonToday({
    required this.person,
    required this.engine,
    required this.day,
  });

  final FamilyMember person;
  final SyncEngine engine;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final routines = engine.routinesFor(person.id, day);
    final chores = [
      for (final ch in engine.chores)
        if (ch.dueOn(day) &&
            (ch.assigneeOn(day) == person.id ||
                (ch.assigneeOn(day) == null &&
                    ch.memberIds.contains(person.id))))
          ch,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Row(
            children: [
              MemberAvatar(person, radius: 16),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  person.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _PointsChip(engine.pointBalance(person.id)),
            ],
          ),
        ),
        if (routines.isEmpty && chores.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'Heute frei 🎈',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        for (final r in routines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _RoutineTile(
              routine: r,
              engine: engine,
              day: day,
              memberId: person.id,
            ),
          ),
        for (final chore in chores)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ChoreTile(
              chore: chore,
              engine: engine,
              day: day,
              forMember: person.id,
            ),
          ),
      ],
    );
  }
}

class _ChoreTile extends StatelessWidget {
  const _ChoreTile({
    required this.chore,
    required this.engine,
    required this.day,
    required this.forMember,
  });

  final Chore chore;
  final SyncEngine engine;
  final DateTime day;

  /// Whose turn it is; null for chores anyone may do.
  final String? forMember;

  Future<void> _toggle(BuildContext context, PointEntry? done) async {
    if (done != null) {
      // Confirmed points only adults take back.
      if (done.status == PointStatus.approved && !engine.iAmAdult) return;
      engine.undoChore(chore, day);
      return;
    }
    var who = forMember;
    if (who == null) {
      final me = engine.me;
      if (me != null && me.role != MemberRole.adult) {
        who = me.id;
      } else {
        who = await _pickMember(context, engine, 'Wer hat es erledigt?');
      }
    }
    if (who == null) return;
    engine.completeChore(chore, day, who);
    if (context.mounted && engine.me?.role == MemberRole.child) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Super! Deine Eltern bestätigen die Punkte. ⭐'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final done = engine.choreCompletion(chore, day);
    final canTick =
        !engine.iAmGuest &&
        (engine.iAmAdult || forMember == null || forMember == engine.memberId);
    final status = switch (done?.status) {
      null => chore.repeat == ChoreRepeat.weekly ? 'diese Woche' : null,
      PointStatus.pending => 'wartet auf Bestätigung',
      PointStatus.approved =>
        'erledigt${done!.memberId != forMember ? ' von ${engine.member(done.memberId)?.displayName ?? '?'}' : ''}',
      PointStatus.rejected => 'abgelehnt',
    };
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      onTap: engine.iAmAdult
          ? () => showChoreEditor(context, chore: chore)
          : null,
      child: Row(
        children: [
          Text(chore.emoji, style: const TextStyle(fontSize: 30)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chore.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    decoration: done?.status == PointStatus.approved
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                Text(
                  ['+${chore.points} ⭐', ?status].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (canTick)
            RoundCheck(
              value: done != null && done.status != PointStatus.rejected,
              color: done?.status == PointStatus.pending
                  ? c.inkSoft
                  : c.strong(FamioSection.chores),
              size: 34,
              onChanged: (_) => _toggle(context, done),
            ),
        ],
      ),
    );
  }
}

Future<String?> _pickMember(
  BuildContext context,
  SyncEngine engine,
  String title,
) => showDialog<String>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text(title),
    children: [
      for (final m in engine.pointCollectors)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, m.id),
          child: Row(
            children: [
              MemberAvatar(m),
              const SizedBox(width: 12),
              Text(m.displayName),
            ],
          ),
        ),
    ],
  ),
);

// --- chores --------------------------------------------------------------------

String _choreSchedule(Chore chore, SyncEngine engine) {
  final when = switch (chore.repeat) {
    ChoreRepeat.once =>
      chore.date == null
          ? 'Einmalig'
          : 'Am ${DateFormat('E, d. MMM', 'de').format(chore.date!)}',
    ChoreRepeat.weekly => 'Einmal pro Woche',
    ChoreRepeat.daily =>
      chore.weekdays.isEmpty || chore.weekdays.length == 7
          ? 'Täglich'
          : (chore.weekdays.toList()..sort())
                .map((d) => _weekdayShort[d - 1])
                .join(', '),
  };
  final names = [
    for (final id in chore.memberIds) engine.member(id)?.displayName ?? '?',
  ];
  final who = names.isEmpty
      ? 'alle'
      : chore.rotate
      ? 'abwechselnd ${names.join(' → ')}'
      : names.join(', ');
  return '$when · $who';
}

class _ChoresTab extends StatelessWidget {
  const _ChoresTab({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final chores = engine.chores;
    if (chores.isEmpty) {
      return EmptyHint(
        icon: AppIcons.listChecks,
        color: c.strong(FamioSection.chores),
        text: 'Noch keine Ämter angelegt.',
      );
    }
    final today = DateTime.now();
    return ListView(
      padding: EdgeInsets.only(bottom: listBottomPadding(context)),
      children: [
        for (final chore in chores)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SoftCard(
              onTap: engine.iAmAdult
                  ? () => showChoreEditor(context, chore: chore)
                  : null,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Text(chore.emoji, style: const TextStyle(fontSize: 28)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chore.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          [
                            _choreSchedule(chore, engine),
                            if (chore.paused) 'pausiert',
                            if (chore.dueOn(today) &&
                                chore.assigneeOn(today) != null)
                              'heute: ${engine.member(chore.assigneeOn(today))?.displayName ?? '?'}',
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  _PointsChip(chore.points),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

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
                      engine.deleteChore(chore.id);
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

class _RoutinesTab extends StatelessWidget {
  const _RoutinesTab({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final routines = engine.routines;
    if (routines.isEmpty) {
      return EmptyHint(
        icon: AppIcons.sunrise,
        color: c.strong(FamioSection.chores),
        text:
            'Routinen sind Checklisten mit Bildern, z. B. für morgens:\n'
            'Anziehen, Frühstücken, Zähne putzen …',
        action: engine.iAmAdult
            ? ColorButton(
                label: 'Morgenroutine anlegen',
                color: c.strong(FamioSection.chores),
                icon: AppIcons.sunrise,
                onPressed: () =>
                    showRoutineEditor(context, preset: _morningPreset),
              )
            : null,
      );
    }
    final today = DateUtils.dateOnly(DateTime.now());
    return ListView(
      padding: EdgeInsets.only(bottom: listBottomPadding(context)),
      children: [
        for (final r in routines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SoftCard(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
              onTap: () async {
                var who = r.memberId;
                if (who == null) {
                  final me = engine.me;
                  who = me != null && me.role != MemberRole.adult
                      ? me.id
                      : await _pickMember(context, engine, 'Für wen?');
                }
                if (who != null && context.mounted) {
                  openRoutine(context, r, who);
                }
              },
              child: Row(
                children: [
                  Text(r.emoji, style: const TextStyle(fontSize: 28)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          [
                            engine.member(r.memberId)?.displayName ?? 'alle',
                            '${r.steps.length} Schritte',
                            if (r.time != null) '⏰ ${r.time}',
                            if (r.points > 0) '+${r.points} ⭐',
                            if (!r.dueOn(today)) 'heute nicht',
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (engine.iAmAdult)
                    IconButton(
                      tooltip: 'Bearbeiten',
                      icon: const Icon(AppIcons.pencilSimple),
                      onPressed: () => showRoutineEditor(context, routine: r),
                    ),
                ],
              ),
            ),
          ),
        if (engine.iAmAdult &&
            !routines.any((r) => r.title == _eveningPreset.title))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.moonStar),
                label: const Text('Abendroutine aus Vorlage'),
                onPressed: () =>
                    showRoutineEditor(context, preset: _eveningPreset),
              ),
            ),
          ),
      ],
    );
  }
}

class _RoutineTile extends StatelessWidget {
  const _RoutineTile({
    required this.routine,
    required this.engine,
    required this.day,
    required this.memberId,
  });

  final Routine routine;
  final SyncEngine engine;
  final DateTime day;
  final String memberId;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final run = engine.routineRun(routine, day, memberId);
    final total = routine.steps.length;
    final done = routine.steps.where((s) => run.done.contains(s.id)).length;
    return SoftCard(
      color: c.tint(FamioSection.chores),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: () => openRoutine(context, routine, memberId),
      child: Row(
        children: [
          Text(routine.emoji, style: const TextStyle(fontSize: 30)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  routine.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : done / total,
                    minHeight: 8,
                    color: c.strong(FamioSection.chores),
                    backgroundColor: c.surface,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            done == total && total > 0 ? '🎉' : '$done/$total',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

void openRoutine(BuildContext context, Routine routine, String memberId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            RoutineRunScreen(routineId: routine.id, memberId: memberId),
      ),
    );

/// A routine as big, kid-friendly checklist.
class RoutineRunScreen extends StatelessWidget {
  const RoutineRunScreen({
    super.key,
    required this.routineId,
    required this.memberId,
  });

  final String routineId;
  final String memberId;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.chores);
    return DataBuilder(
      collections: _collections,
      builder: (context, engine) {
        final routine = engine.routines
            .where((r) => r.id == routineId)
            .firstOrNull;
        if (routine == null) {
          return const SectionPage(
            section: FamioSection.chores,
            title: 'Routine',
            body: SizedBox.shrink(),
          );
        }
        final day = DateUtils.dateOnly(DateTime.now());
        final run = engine.routineRun(routine, day, memberId);
        final allDone =
            routine.steps.isNotEmpty &&
            routine.steps.every((s) => run.done.contains(s.id));
        final canTick =
            !engine.iAmGuest &&
            (engine.iAmAdult || memberId == engine.memberId);
        return SectionPage(
          maxBodyWidth: 720,
          section: FamioSection.chores,
          title: '${routine.emoji} ${routine.title}',
          subtitle: engine.member(memberId)?.displayName,
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              if (allDone)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SoftCard(
                    color: c.tint(FamioSection.chores),
                    child: Text(
                      routine.points > 0
                          ? 'Geschafft! 🎉 +${routine.points} Punkte'
                          : 'Geschafft! 🎉',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ),
              for (final step in routine.steps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SoftCard(
                    padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
                    onTap: canTick
                        ? () => engine.toggleRoutineStep(
                            routine,
                            day,
                            memberId,
                            step.id,
                          )
                        : null,
                    child: Row(
                      children: [
                        Text(
                          step.emoji.isEmpty ? '✅' : step.emoji,
                          style: const TextStyle(fontSize: 40),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            step.title,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  decoration: run.done.contains(step.id)
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                          ),
                        ),
                        RoundCheck(
                          value: run.done.contains(step.id),
                          color: color,
                          size: 40,
                          onChanged: canTick
                              ? (_) => engine.toggleRoutineStep(
                                  routine,
                                  day,
                                  memberId,
                                  step.id,
                                )
                              : (_) {},
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

final _morningPreset = Routine(
  id: '',
  title: 'Morgenroutine',
  emoji: '☀️',
  time: '07:00',
  weekdays: const {1, 2, 3, 4, 5},
  points: 2,
  steps: [
    for (final (e, t) in [
      ('🛏️', 'Aufstehen'),
      ('🚽', 'Toilette & Hände waschen'),
      ('👕', 'Anziehen'),
      ('🥣', 'Frühstücken'),
      ('🪥', 'Zähne putzen'),
      ('🎒', 'Tasche packen'),
    ])
      RoutineStep(id: t, title: t, emoji: e),
  ],
);

final _eveningPreset = Routine(
  id: '',
  title: 'Abendroutine',
  emoji: '🌙',
  time: '19:00',
  points: 2,
  steps: [
    for (final (e, t) in [
      ('🧸', 'Aufräumen'),
      ('🛁', 'Waschen / Baden'),
      ('👚', 'Schlafanzug anziehen'),
      ('🪥', 'Zähne putzen'),
      ('🎒', 'Sachen für morgen bereitlegen'),
      ('📖', 'Vorlesen'),
    ])
      RoutineStep(id: t, title: t, emoji: e),
  ],
);

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
                      engine.deleteRoutine(widget.routine!.id);
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

const _rewardPresets = [
  ('📱', '30 Minuten Tablet', 10),
  ('🍦', 'Eis essen', 15),
  ('🎲', 'Spieleabend aussuchen', 20),
  ('🌙', '30 Minuten später ins Bett', 25),
  ('🎬', 'Kinobesuch', 50),
];

class _RewardsTab extends StatelessWidget {
  const _RewardsTab({required this.engine});

  final SyncEngine engine;

  Future<void> _redeem(BuildContext context, Reward reward) async {
    final me = engine.me;
    final messenger = ScaffoldMessenger.of(context);
    if (me == null || engine.iAmGuest) return;
    if (!engine.iAmAdult) {
      final balance = engine.pointBalance(me.id);
      if (balance < reward.cost) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Dir fehlen noch ${reward.cost - balance} Punkte – weiter so!',
            ),
          ),
        );
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${reward.emoji} ${reward.title}'),
          content: Text(
            'Für ${reward.cost} Punkte einlösen? Deine Eltern bekommen '
            'Bescheid.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Wünschen'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      engine.redeem(reward, me.id);
      messenger.showSnackBar(
        const SnackBar(content: Text('Wunsch gesendet 🎁')),
      );
      return;
    }
    final who = await _pickMember(context, engine, 'Wer löst ein?');
    if (who == null) return;
    final balance = engine.pointBalance(who);
    if (balance < reward.cost) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${engine.member(who)?.displayName} hat nur $balance Punkte.',
          ),
        ),
      );
      return;
    }
    engine.redeem(reward, who);
    messenger.showSnackBar(
      SnackBar(content: Text('${reward.title} eingelöst 🎁')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.chores);
    final rewards = engine.rewards;
    if (rewards.isEmpty) {
      return ListView(
        children: [
          EmptyHint(
            icon: AppIcons.gift,
            color: color,
            text: engine.iAmAdult
                ? 'Wofür lohnt sich das Sammeln? Ideen zum Übernehmen:'
                : 'Noch keine Belohnungen – frag deine Eltern!',
          ),
          if (engine.iAmAdult)
            for (final (emoji, title, cost) in _rewardPresets)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SoftCard(
                  padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                  child: Row(
                    children: [
                      Text(emoji, style: const TextStyle(fontSize: 26)),
                      const SizedBox(width: 12),
                      Expanded(child: Text('$title · $cost ⭐')),
                      TextButton(
                        onPressed: () => engine.saveReward(
                          Reward(
                            id: newId(),
                            title: title,
                            emoji: emoji,
                            cost: cost,
                          ),
                        ),
                        child: const Text('Übernehmen'),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      );
    }
    final me = engine.me;
    final balance = me == null ? 0 : engine.pointBalance(me.id);
    return ListView(
      padding: EdgeInsets.only(bottom: listBottomPadding(context)),
      children: [
        if (me != null && me.role == MemberRole.child)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Text('Du hast', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                _PointsChip(balance, big: true),
              ],
            ),
          ),
        for (final r in rewards)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SoftCard(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              onTap: engine.iAmAdult
                  ? () => showRewardEditor(context, reward: r)
                  : null,
              child: Row(
                children: [
                  Text(r.emoji, style: const TextStyle(fontSize: 30)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      r.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  _PointsChip(r.cost),
                  const SizedBox(width: 8),
                  if (!engine.iAmGuest)
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: color),
                      onPressed: () => _redeem(context, r),
                      child: const Text('Einlösen'),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

Future<void> showRewardEditor(BuildContext context, {Reward? reward}) {
  final title = TextEditingController(text: reward?.title);
  final emoji = TextEditingController(text: reward?.emoji ?? '🎁');
  var cost = reward?.cost ?? 10;
  final engine = AppScope.engineOf(context);
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        scrollable: true,
        title: Text(reward == null ? 'Neue Belohnung' : 'Belohnung bearbeiten'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: reward == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Belohnung'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emoji,
                decoration: const InputDecoration(labelText: 'Emoji'),
              ),
              const SizedBox(height: 12),
              _Stepper(
                value: cost,
                min: 1,
                max: 1000,
                step: cost >= 50 ? 5 : 1,
                onChanged: (v) => setState(() => cost = v),
              ),
            ],
          ),
        ),
        actions: [
          if (reward != null)
            TextButton(
              onPressed: () {
                engine.deleteReward(reward.id);
                Navigator.pop(context);
              },
              child: const Text('Löschen'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              if (title.text.trim().isEmpty) return;
              engine.saveReward(
                Reward(
                  id: reward?.id ?? newId(),
                  title: title.text.trim(),
                  emoji: emoji.text.trim().isEmpty ? '🎁' : emoji.text.trim(),
                  cost: cost,
                ),
              );
              Navigator.pop(context);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  ).whenComplete(() {
    title.dispose();
    emoji.dispose();
  });
}

// --- accounts ---------------------------------------------------------------------

class _AccountsTab extends StatelessWidget {
  const _AccountsTab({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final people = _people(engine);
    return ListView(
      padding: EdgeInsets.only(bottom: listBottomPadding(context)),
      children: [
        for (final m in people)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SoftCard(
              onTap: engine.iAmGuest
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MemberAccountScreen(memberId: m.id),
                      ),
                    ),
              child: Row(
                children: [
                  MemberAvatar(m, radius: 20),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.displayName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          _allowanceLabel(engine.allowance(m.id)),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _PointsChip(engine.pointBalance(m.id)),
                      const SizedBox(height: 4),
                      Text(
                        formatEuro(engine.moneyBalance(m.id)),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _allowanceLabel(Allowance? a) {
  if (a == null || a.weeklyCents <= 0) return 'Kein Taschengeld eingestellt';
  return '${formatEuro(a.weeklyCents)} pro Woche, '
      '${_weekdayLong[a.payday - 1]}s';
}

const _weekdayLong = [
  'Montag',
  'Dienstag',
  'Mittwoch',
  'Donnerstag',
  'Freitag',
  'Samstag',
  'Sonntag',
];

/// Points and pocket money of one member, with the adults' tools.
class MemberAccountScreen extends StatelessWidget {
  const MemberAccountScreen({super.key, required this.memberId});

  final String memberId;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.chores);
    return DataBuilder(
      collections: _collections,
      builder: (context, engine) {
        final member = engine.member(memberId);
        final points = engine.pointsOf(memberId);
        final money = engine.moneyOf(memberId);
        final allowance = engine.allowance(memberId);
        final adult = engine.iAmAdult;
        final day = DateFormat('d.M.', 'de');
        return SectionPage(
          maxBodyWidth: 720,
          section: FamioSection.chores,
          title: member?.displayName ?? 'Konto',
          subtitle: _allowanceLabel(allowance),
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              Row(
                children: [
                  Expanded(
                    child: SoftCard(
                      color: c.tint(FamioSection.chores),
                      child: Column(
                        children: [
                          const Text('Punkte'),
                          Text(
                            '⭐ ${engine.pointBalance(memberId)}',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SoftCard(
                      color: c.tint(FamioSection.budget),
                      child: Column(
                        children: [
                          const Text('Taschengeld'),
                          Text(
                            formatEuro(engine.moneyBalance(memberId)),
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (adult) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(AppIcons.star, size: 18),
                      label: const Text('Bonuspunkte'),
                      onPressed: () => _bonus(context, engine),
                    ),
                    ActionChip(
                      avatar: const Icon(AppIcons.coins, size: 18),
                      label: const Text('Buchung'),
                      onPressed: () => _booking(context, engine),
                    ),
                    ActionChip(
                      avatar: const Icon(AppIcons.gearSix, size: 18),
                      label: const Text('Taschengeld einstellen'),
                      onPressed: () => _settings(context, engine, allowance),
                    ),
                    if ((allowance?.centsPerPoint ?? 0) > 0 &&
                        engine.pointBalance(memberId) > 0)
                      ActionChip(
                        avatar: const Icon(AppIcons.handCoins, size: 18),
                        label: const Text('Punkte eintauschen'),
                        onPressed: () => _convert(context, engine, allowance!),
                      ),
                  ],
                ),
              ],
              ListHeading('Punkte', color: color),
              if (points.isEmpty) const Text('Noch keine Punkte.'),
              for (final e in points.take(50))
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: Text(e.title),
                  subtitle: Text(
                    [
                      day.format(e.at),
                      switch (e.status) {
                        PointStatus.pending => 'wartet',
                        PointStatus.rejected => 'abgelehnt',
                        PointStatus.approved => null,
                      },
                    ].nonNulls.join(' · '),
                  ),
                  trailing: Text(
                    '${e.points > 0 ? '+' : ''}${e.points}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: e.counts ? null : c.inkSoft,
                      decoration: e.status == PointStatus.rejected
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  onLongPress: adult
                      ? () => engine.deletePointEntry(e.id)
                      : null,
                ),
              ListHeading('Taschengeld', color: color),
              if (money.isEmpty) const Text('Noch keine Buchungen.'),
              for (final e in money.take(50))
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: Text(e.note.isEmpty ? e.kind.label : e.note),
                  subtitle: Text('${day.format(e.at)} · ${e.kind.label}'),
                  trailing: Text(
                    '${e.cents > 0 ? '+' : '−'}${formatEuro(e.cents.abs())}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  onLongPress: adult
                      ? () => engine.deleteMoneyEntry(e.id)
                      : null,
                ),
              if (adult)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Lange drücken löscht einen Eintrag.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _bonus(BuildContext context, SyncEngine engine) async {
    final reason = TextEditingController(text: 'Bonus');
    var points = 5;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Punkte geben oder abziehen'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: reason,
                decoration: const InputDecoration(labelText: 'Wofür?'),
              ),
              const SizedBox(height: 12),
              _Stepper(
                value: points,
                min: -100,
                max: 100,
                onChanged: (v) => setState(() => points = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Buchen'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && points != 0) {
      engine.savePointEntry(
        PointEntry(
          id: newId(),
          memberId: memberId,
          points: points,
          title: reason.text.trim().isEmpty ? 'Bonus' : reason.text.trim(),
          kind: PointKind.bonus,
          at: DateTime.now(),
          decidedBy: engine.memberId,
        ),
      );
    }
    reason.dispose();
  }

  Future<void> _booking(BuildContext context, SyncEngine engine) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    var kind = MoneyKind.spent;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: const Text('Buchung'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final k in [
                      MoneyKind.spent,
                      MoneyKind.gift,
                      MoneyKind.other,
                    ])
                      ChoiceChip(
                        label: Text(k.label),
                        selected: kind == k,
                        onSelected: (_) => setState(() => kind = k),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Betrag',
                    suffixText: '€',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(
                    labelText: 'Notiz',
                    hintText: 'z. B. Comic, von Oma',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Buchen'),
            ),
          ],
        ),
      ),
    );
    final cents = parseEuro(amount.text);
    if (ok == true && cents != null && cents != 0) {
      engine.saveMoneyEntry(
        MoneyEntry(
          id: newId(),
          memberId: memberId,
          cents: kind == MoneyKind.spent ? -cents.abs() : cents.abs(),
          at: DateTime.now(),
          kind: kind,
          note: note.text.trim(),
        ),
      );
    }
    amount.dispose();
    note.dispose();
  }

  Future<void> _settings(
    BuildContext context,
    SyncEngine engine,
    Allowance? current,
  ) async {
    final weekly = TextEditingController(
      text: current == null || current.weeklyCents == 0
          ? ''
          : formatEuro(current.weeklyCents).replaceAll(' €', ''),
    );
    final rate = TextEditingController(
      text: current == null || current.centsPerPoint == 0
          ? ''
          : formatEuro(current.centsPerPoint).replaceAll(' €', ''),
    );
    var payday = current?.payday ?? DateTime.saturday;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: const Text('Taschengeld'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: weekly,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Pro Woche',
                    suffixText: '€',
                    helperText: 'Leer lassen für kein Taschengeld',
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Wird gebucht am'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      ChoiceChip(
                        label: Text(_weekdayShort[d - 1]),
                        selected: payday == d,
                        onSelected: (_) => setState(() => payday = d),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: rate,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Wert eines Punktes',
                    suffixText: '€',
                    helperText: 'z. B. 0,10 – leer: Punkte nicht eintauschbar',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      engine.saveAllowance(
        Allowance(
          memberId: memberId,
          weeklyCents: parseEuro(weekly.text)?.abs() ?? 0,
          payday: payday,
          // Changing the amount must not book the past again.
          since: current?.since ?? DateUtils.dateOnly(DateTime.now()),
          centsPerPoint: parseEuro(rate.text)?.abs() ?? 0,
        ),
      );
    }
    weekly.dispose();
    rate.dispose();
  }

  Future<void> _convert(
    BuildContext context,
    SyncEngine engine,
    Allowance allowance,
  ) async {
    final balance = engine.pointBalance(memberId);
    var points = balance;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Punkte eintauschen'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Stepper(
                value: points,
                min: 1,
                max: balance,
                onChanged: (v) => setState(() => points = v),
              ),
              const SizedBox(height: 8),
              Text('= ${formatEuro(points * allowance.centsPerPoint)}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Eintauschen'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) engine.convertPoints(memberId, points);
  }
}
