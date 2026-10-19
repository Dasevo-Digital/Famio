import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/budget_month.dart';
import '../data/family_data.dart';
import '../design/palette.dart';
import '../l10n.dart';
import '../widgets/undo_delete.dart';

/// Whether the member may put a purchase into the household budget: it is
/// switched on, and they are among those who see it (never guests).
bool canBookPurchase(AppState state, SyncEngine engine) {
  final me = state.me;
  if (me == null || me.role == MemberRole.guest) return false;
  if (state.hiddenModules.contains(FamioSection.budget.name)) return false;
  final audience = engine.budgetSettings.memberIds;
  return audience.isEmpty || audience.contains(me.id);
}

/// "Einkauf ins Haushaltsbuch": after shopping, the amount of the receipt
/// goes into the budget as an expense (groceries unless chosen otherwise);
/// on request the ticked items leave [list]. Both can be undone.
Future<void> bookPurchase(
  BuildContext context,
  ShoppingList list,
  List<ShoppingItem> checked,
) async {
  final engine = AppScope.engineOf(context);
  final me = AppScope.read(context).me?.id;
  final messenger = ScaffoldMessenger.of(context);
  final result = await showDialog<_Purchase>(
    context: context,
    builder: (_) => _PurchaseDialog(list: list, count: checked.length),
  );
  if (result == null) return;
  final entry = BudgetEntry(
    id: newId(),
    date: DateUtils.dateOnly(DateTime.now()),
    cents: result.cents,
    category: result.category,
    note: result.note,
    memberId: me,
  );
  engine.saveBudgetEntry(entry);
  final removed = <SyncRecord>[];
  if (result.clear) {
    for (final item in checked) {
      final record = engine.record(Collections.shoppingItems, item.id);
      if (record == null) continue;
      removed.add(record);
      engine.deleteShoppingItem(item.id);
    }
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        // With an action a snack bar would stay until tapped.
        persist: false,
        content: Text(
          tr.purchaseBooked(
            formatEuro(entry.cents),
            categoryLabel(entry.category),
          ),
        ),
        action: SnackBarAction(
          label: tr.commonUndo,
          onPressed: () {
            engine.deleteBudgetEntry(entry.id);
            restoreRecords(engine, removed);
          },
        ),
      ),
    );
}

typedef _Purchase = ({int cents, String category, String note, bool clear});

class _PurchaseDialog extends StatefulWidget {
  const _PurchaseDialog({required this.list, required this.count});

  final ShoppingList list;
  final int count;

  @override
  State<_PurchaseDialog> createState() => _PurchaseDialogState();
}

class _PurchaseDialogState extends State<_PurchaseDialog> {
  final _amount = TextEditingController();
  late final _note = TextEditingController(text: widget.list.name);
  var _category = expenseCategories.first;
  var _clear = true;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final cents = parseEuro(_amount.text);
    if (cents == null || cents == 0) {
      setState(() => _error = tr.budgetPleaseEnterAmount);
      return;
    }
    Navigator.pop<_Purchase>(context, (
      cents: cents,
      category: _category,
      note: _note.text.trim(),
      clear: _clear,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(tr.purchaseTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: theme.textTheme.headlineSmall,
            decoration: InputDecoration(
              labelText: tr.purchaseAmount,
              suffixText: '€',
              errorText: _error,
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: InputDecoration(labelText: tr.purchaseCategory),
            items: [
              for (final c in expenseCategories)
                DropdownMenuItem(value: c, child: Text(categoryLabel(c))),
            ],
            onChanged: (c) => setState(() => _category = c ?? _category),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: tr.purchaseNote),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _clear,
            onChanged: (v) => setState(() => _clear = v ?? true),
            title: Text(tr.purchaseClear(widget.count)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonCancel),
        ),
        FilledButton(onPressed: _save, child: Text(tr.purchaseSave)),
      ],
    );
  }
}
