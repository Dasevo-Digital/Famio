import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';

const _collections = {
  Collections.budgetEntries,
  Collections.budgetSettings,
  'members',
};

/// Totals of one month.
class BudgetMonth {
  BudgetMonth(List<BudgetEntry> all, DateTime month)
    : entries = all.where((e) => e.inMonth(month)).toList() {
    for (final e in entries) {
      if (e.income) {
        income += e.cents;
      } else {
        expenses += e.cents;
        byCategory[e.category] = (byCategory[e.category] ?? 0) + e.cents;
      }
    }
  }

  final List<BudgetEntry> entries;
  var income = 0;
  var expenses = 0;
  final byCategory = <String, int>{};

  int get balance => income - expenses;
}

/// Household budget: income, expenses, monthly limits.
class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  var _month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.budget);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.budget,
      title: 'Finanzen',
      subtitle: 'Haushaltsbuch der Familie',
      actions: [
        BubbleButton(
          icon: AppIcons.gearSix,
          tooltip: 'Wer sieht es, Limits',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const _BudgetSettings()),
          ),
        ),
        const SizedBox(width: 8),
        const SyncStatusIcon(),
      ],
      floating: AddButton(
        color: color,
        tooltip: 'Buchung hinzufügen',
        onPressed: () => showBudgetEntryEditor(context),
      ),
      body: DataBuilder(
        collections: _collections,
        builder: (context, engine) {
          final all = engine.budgetEntries;
          final settings = engine.budgetSettings;
          final m = BudgetMonth(all, _month);
          if (all.isEmpty) {
            return EmptyHint(
              icon: AppIcons.wallet,
              color: color,
              text:
                  'Behaltet Einnahmen und Ausgaben im Blick –\n'
                  'mit Limits pro Kategorie. Wer es sieht, legt ihr fest.',
              action: ColorButton(
                label: 'Erste Buchung',
                color: color,
                onPressed: () => showBudgetEntryEditor(context),
              ),
            );
          }
          final categories =
              {...settings.limits.keys, ...m.byCategory.keys}.toList()..sort(
                (a, b) =>
                    (m.byCategory[b] ?? 0).compareTo(m.byCategory[a] ?? 0),
              );
          return ListView(
            padding: EdgeInsets.only(
              top: 4,
              bottom: listBottomPadding(context),
            ),
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(AppIcons.caretLeft),
                    tooltip: 'Voriger Monat',
                    onPressed: () => setState(
                      () => _month = DateTime(_month.year, _month.month - 1),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      DateFormat('MMMM y', 'de').format(_month),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(AppIcons.caretRight),
                    tooltip: 'Nächster Monat',
                    onPressed: () => setState(
                      () => _month = DateTime(_month.year, _month.month + 1),
                    ),
                  ),
                ],
              ),
              SoftCard(
                color: c.tint(FamioSection.budget),
                child: Wrap(
                  spacing: 28,
                  runSpacing: 12,
                  children: [
                    for (final (label, cents, col) in [
                      ('Einnahmen', m.income, color),
                      ('Ausgaben', m.expenses, const Color(0xFFE8703A)),
                      (
                        'Saldo',
                        m.balance,
                        m.balance < 0 ? theme.colorScheme.error : color,
                      ),
                    ])
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            formatEuro(cents),
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: col,
                            ),
                          ),
                          Text(label, style: theme.textTheme.bodySmall),
                        ],
                      ),
                  ],
                ),
              ),
              if (categories.isNotEmpty) ...[
                const ListHeading('Ausgaben nach Kategorie'),
                SoftCard(
                  child: Column(
                    children: [
                      for (final cat in categories)
                        _CategoryBar(
                          category: cat,
                          spent: m.byCategory[cat] ?? 0,
                          limit: settings.limits[cat],
                          total: m.expenses,
                        ),
                    ],
                  ),
                ),
              ],
              const ListHeading('Buchungen'),
              if (m.entries.isEmpty)
                Text(
                  'Keine Buchungen in diesem Monat.',
                  style: theme.textTheme.bodySmall,
                ),
              for (final e in m.entries)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: IconBlob(
                    categoryIcon(e.category, income: e.income),
                    color: e.income ? color : const Color(0xFFE8703A),
                    size: 38,
                  ),
                  title: Text(e.note.isEmpty ? e.category : e.note),
                  subtitle: Text(
                    [
                      if (e.note.isNotEmpty) e.category,
                      e.monthly
                          ? 'monatlich${e.until == null ? '' : ' bis ${DateFormat('M/y').format(e.until!)}'}'
                          : DateFormat('d.M.', 'de').format(e.date),
                      ?engine.member(e.memberId)?.displayName,
                    ].join(' · '),
                  ),
                  trailing: Text(
                    '${e.income ? '+' : '−'}${formatEuro(e.cents)}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: e.income ? color : null,
                    ),
                  ),
                  onTap: () => showBudgetEntryEditor(context, existing: e),
                ),
              const SizedBox(height: 12),
              Text(
                settings.memberIds.isEmpty
                    ? 'Sichtbar für die ganze Familie – über ⚙ einschränken.'
                    : 'Sichtbar für: ${[for (final id in settings.memberIds) ?engine.member(id)?.displayName].join(', ')}.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Icon of a budget category (own categories: wallet or piggy bank).
IconData categoryIcon(String category, {bool income = false}) =>
    switch (category) {
      'Lebensmittel' => AppIcons.basket,
      'Haushalt' => AppIcons.sofa,
      'Wohnen' => AppIcons.house,
      'Mobilität' => AppIcons.car,
      'Kinder' => AppIcons.baby,
      'Gesundheit' => AppIcons.heartPulse,
      'Freizeit' => AppIcons.ticket,
      'Kleidung' => AppIcons.shirt,
      'Versicherungen' => AppIcons.shield,
      'Gehalt' => AppIcons.briefcase,
      'Kindergeld' || 'Elterngeld' => AppIcons.piggyBank,
      'Sonstige Einnahmen' => AppIcons.coins,
      _ => income ? AppIcons.banknote : AppIcons.wallet,
    };

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.category,
    required this.spent,
    required this.limit,
    required this.total,
  });

  final String category;
  final int spent;
  final int? limit;

  /// All expenses of the month: without a limit the bar shows the share.
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final over = limit != null && spent > limit!;
    final c = FamioColors.of(context);
    final hasLimit = limit != null && limit! > 0;
    final color = over
        ? theme.colorScheme.error
        : hasLimit
        ? c.strong(FamioSection.budget)
        : c.inkSoft;
    final value = hasLimit
        ? spent / limit!
        : (total <= 0 ? 0.0 : spent / total);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(categoryIcon(category), size: 16, color: c.inkSoft),
              const SizedBox(width: 8),
              Expanded(child: Text(category)),
              Text(
                hasLimit
                    ? '${formatEuro(spent)} von ${formatEuro(limit!)}'
                    : '${formatEuro(spent)} · ${(value * 100).round()} %',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: over ? color : null,
                ),
              ),
            ],
          ),
          ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: LinearProgressIndicator(
                value: value.clamp(0, 1),
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

/// Adds or edits a booking.
Future<void> showBudgetEntryEditor(
  BuildContext context, {
  BudgetEntry? existing,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _EntryEditor(existing: existing),
);

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({this.existing});

  final BudgetEntry? existing;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  late var _income = widget.existing?.income ?? false;
  late final _amount = TextEditingController(
    text: widget.existing == null
        ? ''
        : formatEuro(widget.existing!.cents).replaceAll(' €', ''),
  );
  late final _note = TextEditingController(text: widget.existing?.note);
  late String _category = widget.existing?.category ?? expenseCategories.first;
  late DateTime _date =
      widget.existing?.date ?? DateUtils.dateOnly(DateTime.now());
  late var _monthly = widget.existing?.monthly ?? false;
  late String? _member =
      widget.existing?.memberId ?? AppScope.read(context).me?.id;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save({DateTime? until}) {
    final cents = parseEuro(_amount.text);
    if (cents == null || cents == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte einen Betrag angeben')),
      );
      return;
    }
    AppScope.engineOf(context).saveBudgetEntry(
      BudgetEntry(
        id: widget.existing?.id ?? newId(),
        date: _date,
        cents: cents,
        category: _category,
        income: _income,
        note: _note.text.trim(),
        memberId: _member,
        monthly: _monthly,
        until: until ?? widget.existing?.until,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = AppScope.engineOf(context);
    final color = FamioColors.of(context).strong(FamioSection.budget);
    final categories = _income ? incomeCategories : expenseCategories;
    if (!categories.contains(_category)) _category = categories.first;
    final now = DateTime.now();
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
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Ausgabe')),
                ButtonSegment(value: true, label: Text('Einnahme')),
              ],
              selected: {_income},
              onSelectionChanged: (s) => setState(() => _income = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              autofocus: widget.existing == null,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: theme.textTheme.headlineSmall,
              decoration: const InputDecoration(
                labelText: 'Betrag',
                suffixText: '€',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cat in categories)
                  ChoiceChip(
                    label: Text(cat),
                    selected: _category == cat,
                    onSelected: (_) => setState(() => _category = cat),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Wofür? (optional)',
                hintText: 'z. B. Wocheneinkauf, Miete, Schwimmkurs',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                InputChip(
                  avatar: const Icon(AppIcons.calendarBlank, size: 18),
                  label: Text(
                    '${_monthly ? 'Ab ' : ''}${DateFormat('d.M.y', 'de').format(_date)}',
                  ),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(now.year - 5),
                      lastDate: DateTime(now.year + 2),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                ),
                FilterChip(
                  avatar: const Icon(AppIcons.repeat, size: 16),
                  label: const Text('Monatlich'),
                  selected: _monthly,
                  onSelected: (v) => setState(() => _monthly = v),
                ),
                for (final m in engine.members)
                  ChoiceChip(
                    avatar: MemberAvatar(m, radius: 10),
                    label: Text(m.displayName),
                    selected: _member == m.id,
                    onSelected: (on) =>
                        setState(() => _member = on ? m.id : null),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (widget.existing != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: const Text('Löschen'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () {
                      engine.deleteBudgetEntry(widget.existing!.id);
                      Navigator.pop(context);
                    },
                  ),
                if (widget.existing?.monthly == true &&
                    widget.existing?.until == null)
                  TextButton(
                    // Keeps the past months, stops after this one.
                    onPressed: () =>
                        _save(until: DateTime(now.year, now.month + 1, 0)),
                    child: const Text('Nach diesem Monat beenden'),
                  ),
                const Spacer(),
                ColorButton(
                  label: 'Speichern',
                  color: color,
                  onPressed: () => _save(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BudgetSettings extends StatefulWidget {
  const _BudgetSettings();

  @override
  State<_BudgetSettings> createState() => _BudgetSettingsState();
}

class _BudgetSettingsState extends State<_BudgetSettings> {
  late final BudgetSettings _old = AppScope.engineOf(context).budgetSettings;
  late final _members = {..._old.memberIds};
  late final _limits = {
    for (final c in expenseCategories)
      c: TextEditingController(
        text: _old.limits[c] == null
            ? ''
            : formatEuro(_old.limits[c]!).replaceAll(' €', ''),
      ),
  };

  @override
  void dispose() {
    for (final c in _limits.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final engine = AppScope.engineOf(context);
    final me = engine.memberId;
    engine.saveBudgetSettings(
      BudgetSettings(
        // Whoever restricts it keeps seeing it.
        memberIds: _members.isEmpty ? const [] : {..._members, me}.toList(),
        limits: {
          for (final e in _limits.entries)
            if (parseEuro(e.value.text) case final cents? when cents > 0)
              e.key: cents,
        },
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.budget,
      title: 'Budget-Einstellungen',
      actions: [
        ColorButton(
          label: 'Speichern',
          color: FamioColors.of(context).strong(FamioSection.budget),
          onPressed: _save,
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          const ListHeading('Wer sieht das Budget?'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in engine.members)
                FilterChip(
                  avatar: MemberAvatar(m, radius: 10),
                  label: Text(m.displayName),
                  selected: _members.contains(m.id),
                  onSelected: (on) => setState(
                    () => on ? _members.add(m.id) : _members.remove(m.id),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Niemand ausgewählt: die ganze Familie. Der Server gibt die '
              'Buchungen nur an die Ausgewählten heraus.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const ListHeading('Monatliche Limits'),
          for (final c in expenseCategories)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _limits[c],
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(labelText: c, suffixText: '€'),
              ),
            ),
        ],
      ),
    );
  }
}
