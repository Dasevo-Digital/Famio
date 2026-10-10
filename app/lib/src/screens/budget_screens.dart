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
import '../widgets/undo_delete.dart';
import 'bank_import_screen.dart';
import '../l10n.dart';

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
      title: tr.sectionBudget,
      subtitle: tr.budgetFamilySHouseholdBook,
      actions: [
        BubbleButton(
          icon: AppIcons.fileArrowUp,
          tooltip: tr.budgetImportMenu,
          onPressed: () => importBankStatement(context),
        ),
        const SizedBox(width: 8),
        BubbleButton(
          icon: AppIcons.gearSix,
          tooltip: tr.budgetWhoSeesLimits,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const _BudgetSettings()),
          ),
        ),
        const SizedBox(width: 8),
        const SyncStatusIcon(),
      ],
      floating: AddButton(
        color: color,
        tooltip: tr.budgetAddBooking,
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
              text: tr.budgetKeepEyeIncomeExpenses,
              action: ColorButton(
                label: tr.budgetFirstBooking,
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
                    tooltip: tr.budgetPreviousMonth,
                    onPressed: () => setState(
                      () => _month = DateTime(_month.year, _month.month - 1),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      DateFormat.yMMMM(appLanguage).format(_month),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(AppIcons.caretRight),
                    tooltip: tr.budgetNextMonth,
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
                      (tr.budgetIncome, m.income, color),
                      (tr.budgetExpenses, m.expenses, const Color(0xFFE8703A)),
                      (
                        tr.homeBalance,
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
                              color: FamioColors.of(context).text(col),
                            ),
                          ),
                          Text(label, style: theme.textTheme.bodySmall),
                        ],
                      ),
                  ],
                ),
              ),
              if (categories.isNotEmpty) ...[
                ListHeading(tr.budgetExpensesCategory),
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
              ListHeading(tr.budgetBookings),
              if (m.entries.isEmpty)
                Text(
                  tr.budgetNoBookingsMonth,
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
                  title: Text(
                    e.note.isEmpty ? categoryLabel(e.category) : e.note,
                  ),
                  subtitle: Text(
                    [
                      if (e.note.isNotEmpty) categoryLabel(e.category),
                      e.monthly
                          ? tr.budgetMonthlyUntil(
                              e.until == null
                                  ? ''
                                  : tr.budgetUntilDate(
                                      DateFormat.yM(
                                        appLanguage,
                                      ).format(e.until!),
                                    ),
                            )
                          : DateFormat.Md(appLanguage).format(e.date),
                      ?engine.member(e.memberId)?.displayName,
                    ].join(' · '),
                  ),
                  trailing: Text(
                    '${e.income ? '+' : '−'}${formatEuro(e.cents)}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: e.income
                          ? FamioColors.of(context).text(color)
                          : null,
                    ),
                  ),
                  onTap: () => showBudgetEntryEditor(context, existing: e),
                ),
              const SizedBox(height: 12),
              Text(
                settings.memberIds.isEmpty
                    ? tr.budgetVisibleWholeFamilyRestrict
                    : tr.budgetVisibleNames(
                        [
                          for (final id in settings.memberIds)
                            ?engine.member(id)?.displayName,
                        ].join(', '),
                      ),
                style: theme.textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The name of a budget category in the app's language. Entries keep the
/// German name of the default categories; own ones stay as they are.
String categoryLabel(String category) => switch (category) {
  'Lebensmittel' => tr.budgetGroceries,
  'Haushalt' => tr.budgetHousehold,
  'Wohnen' => tr.budgetHousing,
  'Mobilität' => tr.budgetMobility,
  'Kinder' => tr.budgetKids,
  'Gesundheit' => tr.budgetHealth,
  'Freizeit' => tr.budgetLeisure,
  'Kleidung' => tr.budgetClothing,
  'Versicherungen' => tr.budgetInsurance,
  'Sonstiges' => tr.budgetOther,
  'Gehalt' => tr.budgetSalary,
  'Kindergeld' => tr.budgetChildBenefit,
  'Elterngeld' => tr.budgetParentalAllowance,
  'Sonstige Einnahmen' => tr.budgetOtherIncome,
  _ => category,
};

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
              Expanded(child: Text(categoryLabel(category))),
              Text(
                hasLimit
                    ? tr.budgetSpentLimit(formatEuro(spent), formatEuro(limit!))
                    : '${formatEuro(spent)} · ${(value * 100).round()} %',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: over ? FamioColors.of(context).text(color) : null,
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.budgetPleaseEnterAmount)));
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
        importId: widget.existing?.importId,
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
              segments: [
                ButtonSegment(value: false, label: Text(tr.budgetExpense)),
                ButtonSegment(value: true, label: Text(tr.budgetIncome2)),
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
              decoration: InputDecoration(
                labelText: tr.commonAmount,
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
                    label: Text(categoryLabel(cat)),
                    selected: _category == cat,
                    onSelected: (_) => setState(() => _category = cat),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: tr.budgetWhatOptional,
                hintText: tr.budgetEGWeeklyShopping,
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
                    '${_monthly ? tr.budgetFrom : ''}${DateFormat.yMd(appLanguage).format(_date)}',
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
                  label: Text(tr.budgetMonthly),
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
                    label: Text(tr.commonDelete),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () {
                      deleteWithUndo(
                        context,
                        what: widget.existing!.note.isEmpty
                            ? widget.existing!.category
                            : widget.existing!.note,
                        collections: const {Collections.budgetEntries},
                        delete: () =>
                            engine.deleteBudgetEntry(widget.existing!.id),
                      );
                      Navigator.pop(context);
                    },
                  ),
                if (widget.existing?.monthly == true &&
                    widget.existing?.until == null)
                  TextButton(
                    // Keeps the past months, stops after this one.
                    onPressed: () =>
                        _save(until: DateTime(now.year, now.month + 1, 0)),
                    child: Text(tr.budgetEndAfterMonth),
                  ),
                const Spacer(),
                ColorButton(
                  label: tr.commonSave,
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
      title: tr.budgetBudgetSettings,
      actions: [
        ColorButton(
          label: tr.commonSave,
          color: FamioColors.of(context).strong(FamioSection.budget),
          onPressed: _save,
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          ListHeading(tr.budgetWhoSeesBudget),
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
              tr.budgetNobodySelectedWholeFamily,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          ListHeading(tr.budgetMonthlyLimits),
          for (final c in expenseCategories)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _limits[c],
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: categoryLabel(c),
                  suffixText: '€',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
