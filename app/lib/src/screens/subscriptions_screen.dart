import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import '../widgets/undo_delete.dart';

const _collections = {Collections.subscriptions, 'members'};

/// Whether the family keeps track of subscriptions (it can switch that off)
/// and this member gets them.
bool subscriptionsShown(BuildContext context) =>
    !AppScope.of(
      context,
    ).hiddenModules.contains(ServerSettings.subscriptionsModule) &&
    AppScope.engineOf(context).iAmAdult;

/// The name of a category in the app's language; the family's own stay as
/// they are.
String subscriptionCategoryLabel(String category) => switch (category) {
  'Streaming' => tr.subscriptionsCatStreaming,
  'Musik' => tr.subscriptionsCatMusic,
  'Software' => tr.subscriptionsCatSoftware,
  'Cloud' => tr.subscriptionsCatCloud,
  'Spiele' => tr.subscriptionsCatGames,
  'Zeitung' => tr.subscriptionsCatNews,
  'Sport' => tr.subscriptionsCatSport,
  'Mobilfunk' => tr.subscriptionsCatMobile,
  'Versicherung' => tr.subscriptionsCatInsurance,
  'Sonstiges' => tr.subscriptionsCatOther,
  _ => category,
};

/// "monatlich", "alle 3 Monate".
String subscriptionCycleLabel(Subscription s) => switch (s.unit) {
  SubscriptionUnit.days => tr.subscriptionsEveryDays(s.every),
  SubscriptionUnit.weeks => tr.subscriptionsEveryWeeks(s.every),
  SubscriptionUnit.months => switch (s.every) {
    3 => tr.subscriptionsQuarterly,
    6 => tr.subscriptionsHalfYearly,
    _ => tr.subscriptionsEveryMonths(s.every),
  },
  SubscriptionUnit.years => tr.subscriptionsEveryYears(s.every),
};

String _unitLabel(SubscriptionUnit unit, int count) => switch (unit) {
  SubscriptionUnit.days => tr.subscriptionsUnitDays(count),
  SubscriptionUnit.weeks => tr.subscriptionsUnitWeeks(count),
  SubscriptionUnit.months => tr.subscriptionsUnitMonths(count),
  SubscriptionUnit.years => tr.subscriptionsUnitYears(count),
};

String _dueLabel(DateTime due, DateTime now) {
  final days = daysBetween(now, due);
  return switch (days) {
    0 => tr.commonToday,
    1 => tr.commonTomorrow,
    < 31 => tr.subscriptionsInDays(days),
    _ => DateFormat.yMMMd(appLanguage).format(due),
  };
}

/// On the budget page: what the subscriptions come to, and the way in.
class SubscriptionsCard extends StatelessWidget {
  const SubscriptionsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = FamioColors.of(context).strong(FamioSection.budget);
    final stats = SubscriptionStats(
      AppScope.engineOf(context).subscriptions,
      DateTime.now(),
    );
    return SoftCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SubscriptionsScreen()),
      ),
      child: Row(
        children: [
          IconBlob(AppIcons.repeat, color: color, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr.subscriptionsTitle, style: theme.textTheme.titleMedium),
                Text(
                  stats.running.isEmpty
                      ? tr.subscriptionsSubtitle
                      : tr.subscriptionsCardSummary(
                          stats.running.length,
                          formatEuro(stats.perMonth),
                        ),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Icon(AppIcons.caretRight),
        ],
      ),
    );
  }
}

enum _Sort { next, name, price, category }

/// What is paid again and again: what it comes to, and when the next
/// payments are due.
class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  var _sort = _Sort.next;

  List<Subscription> _sorted(List<Subscription> running) => switch (_sort) {
    // [SubscriptionStats.running] already has the next one first.
    _Sort.next => running,
    _Sort.name => [
      ...running,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
    _Sort.price => [
      ...running,
    ]..sort((a, b) => b.centsPerMonth.compareTo(a.centsPerMonth)),
    _Sort.category =>
      [...running]..sort(
        (a, b) => subscriptionCategoryLabel(
          a.category,
        ).compareTo(subscriptionCategoryLabel(b.category)),
      ),
  };

  String _sortLabel(_Sort s) => switch (s) {
    _Sort.next => tr.subscriptionsSortNext,
    _Sort.name => tr.commonName,
    _Sort.price => tr.subscriptionsSortPrice,
    _Sort.category => tr.commonCategory,
  };

  @override
  Widget build(BuildContext context) {
    final color = FamioColors.of(context).strong(FamioSection.budget);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.budget,
      title: tr.subscriptionsTitle,
      subtitle: tr.subscriptionsSubtitle,
      actions: const [SyncStatusIcon()],
      floating: AddButton(
        color: color,
        tooltip: tr.subscriptionsAdd,
        onPressed: () => showSubscriptionEditor(context),
      ),
      body: DataBuilder(
        collections: _collections,
        builder: (context, engine) {
          final now = DateTime.now();
          final all = engine.subscriptions;
          if (all.isEmpty) {
            return EmptyHint(
              icon: AppIcons.repeat,
              color: color,
              text: tr.subscriptionsEmpty,
              action: ColorButton(
                label: tr.subscriptionsFirst,
                color: color,
                onPressed: () => showSubscriptionEditor(context),
              ),
            );
          }
          final stats = SubscriptionStats(all, now);
          String who(String? id) => id == null
              ? tr.subscriptionsTogether
              : engine.member(id)?.displayName ?? tr.subscriptionsTogether;
          return ListView(
            padding: EdgeInsets.only(
              top: 4,
              bottom: listBottomPadding(context),
            ),
            children: [
              _Summary(stats: stats),
              if (stats.running.isNotEmpty) ...[
                ListHeading(tr.subscriptionsRunning),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in _Sort.values)
                      ChoiceChip(
                        label: Text(_sortLabel(s)),
                        selected: _sort == s,
                        onSelected: (_) => setState(() => _sort = s),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final s in _sorted(stats.running))
                  _Row(subscription: s, now: now, payer: who(s.memberId)),
              ],
              if (stats.running.isNotEmpty) ...[
                ListHeading(tr.subscriptionsPerMonth),
                _Breakdown(
                  title: tr.commonCategory,
                  total: stats.perMonth,
                  rows: [
                    for (final e in stats.byCategory.entries)
                      (subscriptionCategoryLabel(e.key), e.value),
                  ],
                ),
              ],
              if (stats.byMember.keys.any((id) => id != null)) ...[
                const SizedBox(height: 12),
                _Breakdown(
                  title: tr.subscriptionsByPerson,
                  total: stats.perMonth,
                  rows: [
                    for (final e in stats.byMember.entries)
                      (who(e.key), e.value),
                  ],
                ),
              ],
              if (stats.ended.isNotEmpty) ...[
                ListHeading(tr.subscriptionsEnded),
                for (final s in stats.ended)
                  _Row(subscription: s, now: now, payer: who(s.memberId)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.stats});

  final SubscriptionStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    return SoftCard(
      color: c.tint(FamioSection.budget),
      child: Wrap(
        spacing: 28,
        runSpacing: 12,
        children: [
          for (final (label, value) in [
            (tr.subscriptionsPerMonth, formatEuro(stats.perMonth)),
            (tr.subscriptionsPerYear, formatEuro(stats.perYear)),
            (tr.subscriptionsNextDays, formatEuro(stats.nextDays)),
            (tr.subscriptionsCount, '${stats.running.length}'),
            if (stats.savedPerMonth > 0)
              (tr.subscriptionsSaved, formatEuro(stats.savedPerMonth)),
          ])
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: theme.textTheme.headlineSmall),
                Text(label, style: theme.textTheme.bodySmall),
              ],
            ),
        ],
      ),
    );
  }
}

/// Cents a month by what they are spent on, the most first.
class _Breakdown extends StatelessWidget {
  const _Breakdown({
    required this.title,
    required this.rows,
    required this.total,
  });

  final String title;
  final List<(String, int)> rows;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = FamioColors.of(context).strong(FamioSection.budget);
    final sorted = [...rows]..sort((a, b) => b.$2.compareTo(a.$2));
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.bodySmall),
          for (final (label, cents) in sorted) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text(label)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    formatEuro(cents),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: LinearProgressIndicator(
                value: total > 0 ? (cents / total).clamp(0, 1) : 0,
                minHeight: 8,
                color: color,
                backgroundColor: color.withValues(alpha: 0.15),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.subscription,
    required this.now,
    required this.payer,
  });

  final Subscription subscription;
  final DateTime now;
  final String payer;

  @override
  Widget build(BuildContext context) {
    final s = subscription;
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final due = s.nextPayment(now);
    final dateFormat = DateFormat.yMd(appLanguage);
    final details = [
      subscriptionCycleLabel(s),
      subscriptionCategoryLabel(s.category),
      if (s.memberId != null) payer,
      if (s.payment.isNotEmpty) s.payment,
    ].join(' · ');
    final initial = s.name.trim().isEmpty
        ? '?'
        : s.name.trim().characters.first.toUpperCase();
    final price = Text(formatEuro(s.cents), style: theme.textTheme.titleMedium);
    final when = due == null
        ? null
        : Text(_dueLabel(due, now), style: theme.textTheme.bodySmall);
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => showSubscriptionEditor(context, existing: s),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: c.tint(FamioSection.budget),
              child: Text(
                initial,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: c.sectionText(FamioSection.budget),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name, style: theme.textTheme.titleMedium),
                  Text(details, style: theme.textTheme.bodySmall),
                  if (s.endsOn != null)
                    Text(
                      tr.subscriptionsEndsOn(dateFormat.format(s.endsOn!)),
                      style: theme.textTheme.bodySmall,
                    ),
                  if (largeText) ...[price, ?when],
                ],
              ),
            ),
            if (!largeText) ...[
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [price, ?when],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> showSubscriptionEditor(
  BuildContext context, {
  Subscription? existing,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _Editor(existing: existing),
);

class _Editor extends StatefulWidget {
  const _Editor({this.existing});

  final Subscription? existing;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final Subscription? _old = widget.existing;
  late final _name = TextEditingController(text: _old?.name);
  late final _amount = TextEditingController(
    text: _old == null ? '' : formatEuro(_old.cents).replaceAll(' €', ''),
  );
  late final _every = TextEditingController(text: '${_old?.every ?? 1}');
  late final _payment = TextEditingController(text: _old?.payment);
  late final _url = TextEditingController(text: _old?.url);
  late final _note = TextEditingController(text: _old?.note);
  late final _customCategory = TextEditingController();
  late var _unit = _old?.unit ?? SubscriptionUnit.months;
  late DateTime _start = _old?.start ?? DateUtils.dateOnly(DateTime.now());
  late DateTime? _endsOn = _old?.endsOn;
  late String? _memberId = _old?.memberId;
  late int? _remindDays = _old == null ? 3 : _old.remindDays;

  String? _nameError;
  String? _amountError;
  String? _everyError;
  String? _linkError;

  /// Null: the family's own, typed into [_customCategory].
  late String? _category = _old?.category ?? subscriptionCategories.first;

  @override
  void dispose() {
    for (final c in [
      _name,
      _amount,
      _every,
      _payment,
      _url,
      _note,
      _customCategory,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final cents = parseEuro(_amount.text);
    final every = int.tryParse(_every.text.trim());
    final periodOk = every != null && every >= 1 && every <= 999;
    // Next to the fields: a snack bar would be behind this sheet.
    setState(() {
      _nameError = name.isEmpty ? tr.subscriptionsEnterName : null;
      _amountError = cents == null || cents == 0
          ? tr.budgetPleaseEnterAmount
          : null;
      _everyError = periodOk ? null : tr.subscriptionsEnterPeriod;
    });
    if (name.isEmpty || cents == null || cents == 0 || !periodOk) return;
    final typed = _customCategory.text.trim();
    AppScope.engineOf(context).saveSubscription(
      Subscription(
        id: _old?.id ?? newId(),
        name: name,
        cents: cents,
        start: _start,
        every: every,
        unit: _unit,
        // l10n: stored key, shown through subscriptionCategoryLabel
        category: _category ?? (typed.isEmpty ? 'Sonstiges' : typed),
        payment: _payment.text.trim(),
        memberId: _memberId,
        url: _url.text.trim(),
        note: _note.text.trim(),
        endsOn: _endsOn,
        remindDays: _remindDays,
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _openLink() async {
    final text = _url.text.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      setState(() => _linkError = tr.subscriptionsLinkInvalid);
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<DateTime?> _pick(DateTime initial, {DateTime? first}) {
    final now = DateTime.now();
    return showFamioDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first ?? DateTime(now.year - 30),
      lastDate: DateTime(now.year + 10),
    );
  }

  /// Quick choices for the usual periods.
  static const _usual = [
    (1, SubscriptionUnit.months),
    (3, SubscriptionUnit.months),
    (6, SubscriptionUnit.months),
    (1, SubscriptionUnit.years),
  ];

  /// What the field says, as far as it is a period at all.
  int get _period => (int.tryParse(_every.text.trim()) ?? 1).clamp(1, 999);

  Subscription get _preview => Subscription(
    id: '',
    name: '',
    cents: 0,
    start: _start,
    every: _period,
    unit: _unit,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = AppScope.engineOf(context);
    final color = FamioColors.of(context).strong(FamioSection.budget);
    final dates = DateFormat.yMd(appLanguage);
    final count = _period;
    final categories = {
      ...subscriptionCategories,
      for (final s in engine.subscriptions) s.category,
      ?_category,
    };
    final old = _old;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: old == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: tr.commonName,
                hintText: tr.subscriptionsNameHint,
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: theme.textTheme.headlineSmall,
              decoration: InputDecoration(
                labelText: tr.commonAmount,
                suffixText: '€',
                errorText: _amountError,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (every, unit) in _usual)
                  ChoiceChip(
                    label: Text(
                      subscriptionCycleLabel(
                        Subscription(
                          id: '',
                          name: '',
                          cents: 0,
                          start: _start,
                          every: every,
                          unit: unit,
                        ),
                      ),
                    ),
                    selected: _preview.every == every && _unit == unit,
                    onSelected: (_) => setState(() {
                      _every.text = '$every';
                      _unit = unit;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _every,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: tr.subscriptionsEvery,
                      errorText: _everyError,
                      errorMaxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<SubscriptionUnit>(
                    initialValue: _unit,
                    key: ValueKey(_unit),
                    isExpanded: true,
                    items: [
                      for (final u in SubscriptionUnit.values)
                        DropdownMenuItem(
                          value: u,
                          child: Text(
                            _unitLabel(u, count),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (u) => setState(() => _unit = u ?? _unit),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(tr.commonCategory, style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cat in categories)
                  ChoiceChip(
                    label: Text(subscriptionCategoryLabel(cat)),
                    selected: _category == cat,
                    onSelected: (_) => setState(() => _category = cat),
                  ),
                ChoiceChip(
                  label: Text(tr.subscriptionsOwnCategory),
                  selected: _category == null,
                  onSelected: (_) => setState(() => _category = null),
                ),
              ],
            ),
            if (_category == null) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _customCategory,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: tr.subscriptionsOwnCategory,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                InputChip(
                  avatar: const Icon(AppIcons.calendarBlank, size: 18),
                  label: Text(
                    tr.subscriptionsFirstPayment(dates.format(_start)),
                  ),
                  onPressed: () async {
                    final picked = await _pick(_start);
                    if (picked != null) setState(() => _start = picked);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(tr.subscriptionsByPerson, style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final m in engine.members)
                  if (m.role == MemberRole.adult)
                    ChoiceChip(
                      avatar: MemberAvatar(m, radius: 10),
                      label: Text(m.displayName),
                      selected: _memberId == m.id,
                      onSelected: (on) =>
                          setState(() => _memberId = on ? m.id : null),
                    ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _payment,
              decoration: InputDecoration(
                labelText: tr.subscriptionsPayment,
                hintText: tr.subscriptionsPaymentHint,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() => _linkError = null),
              decoration: InputDecoration(
                labelText: tr.subscriptionsLink,
                errorText: _linkError,
                suffixIcon: _url.text.trim().isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(AppIcons.arrowSquareOut),
                        tooltip: tr.subscriptionsOpenLink,
                        onPressed: _openLink,
                      ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr.commonNotes),
            ),
            const SizedBox(height: 12),
            Text(tr.subscriptionsRemind, style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: Text(tr.subscriptionsRemindOff),
                  selected: _remindDays == null,
                  onSelected: (_) => setState(() => _remindDays = null),
                ),
                for (final days in const [1, 3, 7, 14])
                  ChoiceChip(
                    label: Text(tr.subscriptionsRemindDays(days)),
                    selected: _remindDays == days,
                    onSelected: (_) => setState(() => _remindDays = days),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_endsOn case final ends?)
                  InputChip(
                    avatar: const Icon(AppIcons.calendarBlank, size: 18),
                    label: Text(tr.subscriptionsEndsOn(dates.format(ends))),
                    onPressed: () async {
                      final picked = await _pick(ends);
                      if (picked != null) setState(() => _endsOn = picked);
                    },
                    onDeleted: () => setState(() => _endsOn = null),
                    deleteButtonTooltipMessage: tr.subscriptionsNotCancelled,
                  )
                else
                  OutlinedButton(
                    onPressed: () async {
                      // The day before the next payment: that one is saved.
                      final now = DateTime.now();
                      final next = _preview.nextPayment(now);
                      final picked = await _pick(
                        next == null
                            ? now
                            : DateTime(next.year, next.month, next.day - 1),
                      );
                      if (picked != null) setState(() => _endsOn = picked);
                    },
                    child: Text(tr.subscriptionsMarkCancelled),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                if (old != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: Text(tr.commonDelete),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () {
                      deleteWithUndo(
                        context,
                        what: old.name,
                        collections: const {Collections.subscriptions},
                        delete: () => engine.deleteSubscription(old.id),
                      );
                      Navigator.pop(context);
                    },
                  )
                else
                  const SizedBox.shrink(),
                ColorButton(
                  label: tr.commonSave,
                  color: color,
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
