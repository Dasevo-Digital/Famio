import 'dart:convert';

import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';
import '../data/preppsuite_import.dart';
import '../l10n.dart';

/// Shopping list → menu → "Fehlbestände aus PreppSuite": reads the file
/// PreppSuite exports (Vorräte → Einkaufsliste) and puts the chosen
/// articles on [list], with an aisle each (none on packing lists).
Future<void> importFromPreppSuite(
  BuildContext context,
  SyncEngine engine,
  ShoppingList list,
) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));
  final picked = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  if (picked.isEmpty) return;
  final PreppSuiteList prepp;
  try {
    prepp = parsePreppSuiteList(
      utf8.decode(await picked.first.readAsBytes(), allowMalformed: true),
    );
  } on PreppSuiteFormatException catch (e) {
    say(switch (e.problem) {
      PreppSuiteProblem.notAList => tr.shoppingPreppSuiteNotAList,
      PreppSuiteProblem.newerVersion => tr.shoppingPreppSuiteNewer,
    });
    return;
  }
  if (!context.mounted) return;
  await addFromPreppSuite(context, engine, list, prepp);
}

/// Lets the member pick from [prepp]'s articles and adds them to [list].
Future<void> addFromPreppSuite(
  BuildContext context,
  SyncEngine engine,
  ShoppingList list,
  PreppSuiteList prepp,
) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));
  if (prepp.items.isEmpty) {
    say(tr.shoppingPreppSuiteNothing);
    return;
  }
  final chosen = await showDialog<List<PreppSuiteItem>>(
    context: context,
    builder: (_) => _PreppSuiteDialog(
      prepp: prepp,
      onList: {
        for (final i in engine.shoppingItems(list.id))
          if (!i.checked) i.name.trim().toLowerCase(),
      },
    ),
  );
  if (chosen == null || chosen.isEmpty) return;
  final learned = engine.learnedShoppingCategories;
  for (final item in chosen) {
    engine.saveShoppingItem(
      ShoppingItem(
        id: newId(),
        listId: list.id,
        name: item.name,
        quantity: item.quantity,
        category: list.packing
            ? ''
            : guessShoppingCategory(item.name, learned: learned),
      ),
    );
  }
  say(tr.shoppingPreppSuiteAdded(chosen.length));
}

class _PreppSuiteDialog extends StatefulWidget {
  const _PreppSuiteDialog({required this.prepp, required this.onList});

  final PreppSuiteList prepp;

  /// Names (lower case) already open on the list: not ticked at first.
  final Set<String> onList;

  @override
  State<_PreppSuiteDialog> createState() => _PreppSuiteDialogState();
}

class _PreppSuiteDialogState extends State<_PreppSuiteDialog> {
  late final _chosen = {
    for (final i in widget.prepp.items)
      if (!_already(i)) i,
  };

  bool _already(PreppSuiteItem i) =>
      widget.onList.contains(i.name.trim().toLowerCase());

  @override
  Widget build(BuildContext context) {
    final prepp = widget.prepp;
    final target = prepp.target;
    final number = NumberFormat.decimalPattern(appLanguage);
    final notes = [
      if (prepp.created case final created?)
        tr.shoppingPreppSuiteAsOf(
          DateFormat.yMd(appLanguage).format(created.toLocal()),
        ),
      if (target != null && !target.met)
        tr.shoppingPreppSuiteGoal(
          target.days,
          number.format(target.waterLiters),
          number.format(target.kcal),
        ),
    ];
    return AlertDialog(
      title: Text(tr.shoppingPreppSuiteTitle),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final note in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(note),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final item in prepp.items)
                    CheckboxListTile(
                      value: _chosen.contains(item),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(item.name),
                      subtitle: Text(
                        [
                          if (item.quantity.isNotEmpty) item.quantity,
                          if (_already(item)) tr.shoppingPreppSuiteAlready,
                        ].join(' · '),
                      ),
                      onChanged: (on) => setState(
                        () => on == true
                            ? _chosen.add(item)
                            : _chosen.remove(item),
                      ),
                    ),
                ],
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
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context, [
                  for (final i in prepp.items)
                    if (_chosen.contains(i)) i,
                ]),
          child: Text(tr.shoppingPreppSuiteAddCount(_chosen.length)),
        ),
      ],
    );
  }
}
