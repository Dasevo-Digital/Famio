import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/bank_import.dart';
import '../data/family_data.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';
import 'budget_screens.dart';

/// Budget → "Kontoauszug importieren": a CSV or CAMT file from the bank,
/// read on this device only.
Future<void> importBankStatement(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final picked = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['csv', 'xml', 'txt'],
  );
  if (picked.isEmpty) return;
  final List<BankTransaction> transactions;
  try {
    transactions = parseBankStatement(await picked.first.readAsBytes());
  } on BankFormatException {
    messenger.showSnackBar(SnackBar(content: Text(tr.budgetImportUnknown)));
    return;
  }
  if (transactions.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(tr.budgetImportEmpty)));
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BankImportScreen(transactions: transactions),
    ),
  );
}

/// The bookings of a statement to pick from: new ones ticked, ones already
/// in the budget not; a category suggested for each.
class BankImportScreen extends StatefulWidget {
  const BankImportScreen({super.key, required this.transactions});

  final List<BankTransaction> transactions;

  @override
  State<BankImportScreen> createState() => _BankImportScreenState();
}

class _BankImportScreenState extends State<BankImportScreen> {
  final _chosen = <int>{};
  final _categories = <int, String>{};
  final _duplicates = <int, BankDuplicate>{};
  var _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final entries = AppScope.engineOf(context).budgetEntries;
    for (final (i, t) in widget.transactions.indexed) {
      _categories[i] = suggestBudgetCategory(t, entries);
      final duplicate = bankDuplicate(t, entries);
      if (duplicate == null) {
        _chosen.add(i);
      } else {
        _duplicates[i] = duplicate;
      }
    }
  }

  Future<void> _pickCategory(int i) async {
    final t = widget.transactions[i];
    final defaults = t.income ? incomeCategories : expenseCategories;
    final own = {
      for (final e in AppScope.engineOf(context).budgetEntries)
        if (e.income == t.income && !defaults.contains(e.category)) e.category,
    };
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr.commonCategory),
        children: [
          for (final c in [...defaults, ...own.toList()..sort()])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, c),
              child: Text(categoryLabel(c)),
            ),
        ],
      ),
    );
    if (chosen != null) setState(() => _categories[i] = chosen);
  }

  void _save() {
    final engine = AppScope.engineOf(context);
    for (final i in _chosen) {
      final t = widget.transactions[i];
      engine.saveBudgetEntry(
        BudgetEntry(
          id: newId(),
          date: t.date,
          cents: t.cents.abs(),
          category: _categories[i]!,
          income: t.income,
          note: t.note,
          importId: t.importId,
        ),
      );
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr.budgetImportAdded(_chosen.length))),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.budget);
    final date = DateFormat.yMd(appLanguage);
    final all = widget.transactions;
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.budget,
      title: tr.budgetImportTitle,
      subtitle: [
        tr.budgetImportCount(all.length),
        if (_duplicates.isNotEmpty) tr.budgetImportKnown(_duplicates.length),
      ].join(' · '),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(tr.budgetImportHint, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: all.length,
              itemBuilder: (context, i) {
                final t = all[i];
                final duplicate = _duplicates[i];
                return CheckboxListTile(
                  value: _chosen.contains(i),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  onChanged: (on) => setState(
                    () => on == true ? _chosen.add(i) : _chosen.remove(i),
                  ),
                  title: Text(
                    t.counterparty.isEmpty ? t.purpose : t.counterparty,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          date.format(t.date),
                          if (t.counterparty.isNotEmpty && t.purpose.isNotEmpty)
                            t.purpose,
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (duplicate != null)
                        Text(
                          switch (duplicate) {
                            BankDuplicate.imported => tr.budgetImportAlready,
                            BankDuplicate.likely => tr.budgetImportMaybe,
                          },
                          style: TextStyle(
                            color: c.sectionText(FamioSection.budget),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: ActionChip(
                          label: Text(categoryLabel(_categories[i]!)),
                          avatar: Icon(
                            categoryIcon(_categories[i]!, income: t.income),
                            size: 18,
                          ),
                          tooltip: tr.commonCategory,
                          onPressed: () => _pickCategory(i),
                        ),
                      ),
                    ],
                  ),
                  secondary: Text(
                    '${t.income ? '+' : '−'}${formatEuro(t.cents.abs())}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: t.income ? Colors.green.shade700 : null,
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: ColorButton(
              label: tr.budgetImportAdd(_chosen.length),
              color: color,
              onPressed: _chosen.isEmpty ? null : _save,
            ),
          ),
        ],
      ),
    );
  }
}
