part of '../chores_screens.dart';

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
  if (a == null || a.weeklyCents <= 0) return tr.choresNoPocketMoneySet;
  return tr.choresAmountPerWeekDay(
    formatEuro(a.weeklyCents),
    weekdayLong(a.payday),
  );
}

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
        final day = DateFormat.Md(appLanguage);
        return SectionPage(
          maxBodyWidth: 720,
          section: FamioSection.chores,
          title: member?.displayName ?? tr.settingsAccount,
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
                          Text(tr.choresPoints),
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
                          Text(tr.choresPocketMoney),
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
              _SavingsGoals(memberId: memberId, engine: engine),
              if (adult) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(AppIcons.star, size: 18),
                      label: Text(tr.choresBonusPoints),
                      onPressed: () => _bonus(context, engine),
                    ),
                    ActionChip(
                      avatar: const Icon(AppIcons.coins, size: 18),
                      label: Text(tr.conflictsBooking),
                      onPressed: () => _booking(context, engine),
                    ),
                    ActionChip(
                      avatar: const Icon(AppIcons.gearSix, size: 18),
                      label: Text(tr.choresSetPocketMoney),
                      onPressed: () => _settings(context, engine, allowance),
                    ),
                    if ((allowance?.centsPerPoint ?? 0) > 0 &&
                        engine.pointBalance(memberId) > 0)
                      ActionChip(
                        avatar: const Icon(AppIcons.handCoins, size: 18),
                        label: Text(tr.choresRedeemPoints),
                        onPressed: () => _convert(context, engine, allowance!),
                      ),
                  ],
                ),
              ],
              ListHeading(tr.choresPoints, color: color),
              if (points.isEmpty) Text(tr.choresNoPointsYet),
              for (final e in points.take(50))
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: Text(e.title),
                  subtitle: Text(
                    [
                      day.format(e.at),
                      switch (e.status) {
                        PointStatus.pending => tr.choresWaiting,
                        PointStatus.rejected => tr.choresDeclined,
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
                      ? () => deleteWithUndo(
                          context,
                          what: e.title,
                          collections: const {Collections.pointEntries},
                          delete: () => engine.deletePointEntry(e.id),
                        )
                      : null,
                ),
              ListHeading(tr.choresPocketMoney, color: color),
              if (money.isEmpty) Text(tr.choresNoTransactionsYet),
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
                      ? () => deleteWithUndo(
                          context,
                          what: e.note.isEmpty ? e.kind.label : e.note,
                          collections: const {Collections.moneyEntries},
                          delete: () => engine.deleteMoneyEntry(e.id),
                        )
                      : null,
                ),
              if (adult)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    tr.choresLongPressDeletesEntry,
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
    final reason = TextEditingController(text: tr.choresBonus);
    var points = 5;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr.choresGiveTakePoints),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: reason,
                decoration: InputDecoration(labelText: tr.choresWhat),
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
              child: Text(tr.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.choresBook),
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
          title: reason.text.trim().isEmpty
              ? tr.choresBonus
              : reason.text.trim(),
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
          title: Text(tr.conflictsBooking),
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
                  decoration: InputDecoration(
                    labelText: tr.commonAmount,
                    suffixText: '€',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  decoration: InputDecoration(
                    labelText: tr.commonNote,
                    hintText: tr.choresEGComicGrandma,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.choresBook),
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
          title: Text(tr.choresPocketMoney),
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
                  decoration: InputDecoration(
                    labelText: tr.choresPerWeek,
                    suffixText: '€',
                    helperText: tr.choresLeaveEmptyNoPocket,
                  ),
                ),
                const SizedBox(height: 12),
                Text(tr.choresPaid),
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
                  decoration: InputDecoration(
                    labelText: tr.choresValueOnePoint,
                    suffixText: '€',
                    helperText: tr.choresEG010,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.commonSave),
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
          title: Text(tr.choresRedeemPoints),
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
              child: Text(tr.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.choresRedeem),
            ),
          ],
        ),
      ),
    );
    if (ok == true) engine.convertPoints(memberId, points);
  }
}

/// What the child saves for: progress from the pocket money balance and,
/// with a weekly amount, when it will be enough.
class _SavingsGoals extends StatelessWidget {
  const _SavingsGoals({required this.memberId, required this.engine});

  final String memberId;
  final SyncEngine engine;

  static const _emojis = [
    '🎯',
    '🚲',
    '🎮',
    '🧸',
    '📚',
    '⚽',
    '🎧',
    '🛹',
    '👟',
    '🎁',
  ];

  bool get _mayEdit => engine.iAmAdult || engine.memberId == memberId;

  Future<void> _edit(BuildContext context, [SavingsGoal? old]) async {
    final title = TextEditingController(text: old?.title);
    final amount = TextEditingController(
      text: old == null ? '' : formatEuro(old.targetCents).replaceAll(' €', ''),
    );
    var emoji = old?.emoji ?? _emojis.first;
    // The values come back from the dialog; its fields stay alive until it
    // has faded out (saving rebuilds the screen meanwhile).
    final result = await showDialog<(String, int?, String)>(
      context: context,
      builder: (context) => DisposeWith(
        controllers: [title, amount],
        child: StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            scrollable: true,
            title: Text(old == null ? tr.savingsGoalNew : tr.savingsGoalEdit),
            content: SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in _emojis)
                        ChoiceChip(
                          label: Text(e, style: const TextStyle(fontSize: 20)),
                          selected: emoji == e,
                          onSelected: (_) => setState(() => emoji = e),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: title,
                    autofocus: old == null,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: tr.savingsGoalWhat,
                      hintText: tr.savingsGoalWhatHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: tr.savingsGoalAmount,
                      suffixText: '€',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr.commonCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, (
                  title.text.trim(),
                  parseEuro(amount.text),
                  emoji,
                )),
                child: Text(tr.commonSave),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    final (what, cents, chosen) = result;
    if (cents == null || cents <= 0 || what.isEmpty) return;
    engine.saveSavingsGoal(
      SavingsGoal(
        id: old?.id ?? newId(),
        memberId: memberId,
        title: what,
        targetCents: cents,
        emoji: chosen,
      ),
    );
  }

  Future<void> _buy(BuildContext context, SavingsGoal g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(
          tr.savingsGoalBuyConfirm(
            '${g.emoji} ${g.title}',
            formatEuro(g.targetCents),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.savingsGoalBuy),
          ),
        ],
      ),
    );
    if (ok == true) engine.buySavingsGoal(g);
  }

  String _when(SavingsGoal g, int balance, Allowance? allowance) {
    final missing = g.targetCents - balance;
    final on = g.reachedOn(
      balanceCents: balance,
      allowance: allowance,
      today: DateTime.now(),
    );
    if (on == null) return tr.savingsGoalLeft(formatEuro(missing));
    final date = DateFormat.MMMd(appLanguage).format(on);
    final weeks = (missing / allowance!.weeklyCents).ceil();
    return weeks <= 1
        ? tr.savingsGoalNextPayday(date)
        : tr.savingsGoalWhen(weeks, date);
  }

  @override
  Widget build(BuildContext context) {
    final goals = engine.savingsGoals(memberId);
    if (goals.isEmpty && !_mayEdit) return const SizedBox.shrink();
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.chores);
    final theme = Theme.of(context);
    final balance = engine.moneyBalance(memberId);
    final allowance = engine.allowance(memberId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListHeading(
          tr.savingsGoals,
          color: color,
          trailing: _mayEdit
              ? TextButton.icon(
                  icon: const Icon(AppIcons.plus, size: 18),
                  label: Text(tr.savingsGoalAdd),
                  onPressed: () => _edit(context),
                )
              : null,
        ),
        for (final g in goals)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onLongPress: _mayEdit
                  ? () => deleteWithUndo(
                      context,
                      what: g.title,
                      collections: const {Collections.savingsGoals},
                      delete: () => engine.deleteSavingsGoal(g.id),
                    )
                  : null,
              child: SoftCard(
                onTap: _mayEdit ? () => _edit(context, g) : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(g.emoji, style: theme.textTheme.headlineSmall),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            g.title,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          tr.savingsGoalProgress(
                            formatEuro(balance.clamp(0, g.targetCents).toInt()),
                            formatEuro(g.targetCents),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: g.progress(balance),
                        minHeight: 10,
                        color: color,
                        backgroundColor: c.tint(FamioSection.chores),
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (balance >= g.targetCents)
                      Row(
                        children: [
                          Text(
                            tr.savingsGoalReached,
                            style: theme.textTheme.titleSmall,
                          ),
                          const Spacer(),
                          if (engine.iAmAdult)
                            FilledButton.tonal(
                              onPressed: () => _buy(context, g),
                              child: Text(tr.savingsGoalBuy),
                            ),
                        ],
                      )
                    else
                      Text(
                        _when(g, balance, allowance),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
