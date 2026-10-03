part of '../chores_screens.dart';

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
                          label: step.title,
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
