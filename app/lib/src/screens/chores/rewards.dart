part of '../chores_screens.dart';

List<(String, String, int)> get _rewardPresets => [
  ('📱', tr.rewards30MinutesTablet, 10),
  ('🍦', tr.rewardsEatIceCream, 15),
  ('🎲', tr.rewardsChooseGameNight, 20),
  ('🌙', tr.rewardsGoBed30Minutes, 25),
  ('🎬', tr.rewardsTripCinema, 50),
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
            content: Text(tr.rewardsYouStillNeedPoints(reward.cost - balance)),
          ),
        );
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${reward.emoji} ${reward.title}'),
          content: Text(tr.rewardsRedeemCostPointsParents(reward.cost)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.rewardsWish),
            ),
          ],
        ),
      );
      if (ok != true) return;
      engine.redeem(reward, me.id);
      messenger.showSnackBar(SnackBar(content: Text(tr.rewardsWishSent)));
      return;
    }
    final who = await _pickMember(context, engine, tr.rewardsWhoRedeems);
    if (who == null) return;
    final balance = engine.pointBalance(who);
    if (balance < reward.cost) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr.rewardsNameOnlyHasBalance(
              engine.member(who)?.displayName,
              balance,
            ),
          ),
        ),
      );
      return;
    }
    engine.redeem(reward, who);
    messenger.showSnackBar(
      SnackBar(content: Text(tr.rewardsTitleRedeemed(reward.title))),
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
                ? tr.rewardsWhatWorthCollectingIdeas
                : tr.rewardsNoRewardsYetAsk,
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
                        child: Text(tr.commonApply),
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
                Text(
                  tr.rewardsYouHave,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
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
                      child: Text(tr.rewardsRedeem),
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
        title: Text(
          reward == null ? tr.rewardsNewReward : tr.rewardsEditReward,
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: reward == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: tr.commonReward),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emoji,
                decoration: InputDecoration(labelText: tr.rewardsEmoji),
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
              child: Text(tr.commonDelete),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.commonCancel),
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
            child: Text(tr.commonSave),
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
