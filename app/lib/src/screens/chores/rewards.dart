part of '../chores_screens.dart';

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
                deleteWithUndo(
                  context,
                  what: reward.title,
                  collections: const {Collections.rewards},
                  delete: () => engine.deleteReward(reward.id),
                );
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
