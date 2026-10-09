part of '../chores_screens.dart';

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
              label: chore.title,
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
          : 'Am ${DateFormat.MMMEd(appLanguage).format(chore.date!)}',
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
