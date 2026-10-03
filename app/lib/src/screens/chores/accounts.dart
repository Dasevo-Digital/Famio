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
