part of '../chores_screens.dart';

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
        text: tr.choresNoChoresCreatedYet,
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
