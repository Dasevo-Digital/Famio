import 'dart:convert';

import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/preppsuite_import.dart';
import 'package:famio/src/widgets/preppsuite_import.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// As PreppSuite writes it (docs/einkaufsliste-format.md, version 1).
final _export = jsonEncode({
  'format': 'preppsuite-einkaufsliste',
  'version': 1,
  'created': '2026-10-10T09:30:00.000Z',
  'language': 'de',
  'items': [
    {
      'name': 'Reis',
      'quantity': '1,5 kg',
      'amount': 1.5,
      'unit': 'kg',
      'minimum': 2,
      'supplyCategory': 'food',
    },
    {
      'name': 'Mineralwasser',
      'quantity': '12 l',
      'amount': 12,
      'unit': 'l',
      'supplyCategory': 'water',
      'futureField': {'ignored': true},
    },
    {'name': 'Pflaster', 'quantity': '1', 'supplyCategory': 'medical'},
    {'name': '', 'quantity': '3'},
  ],
  'target': {'days': 10, 'met': false, 'waterLiters': 34, 'kcal': 12000},
});

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('reads a PreppSuite export, skipping what it does not know', () {
    final list = parsePreppSuiteList(_export);
    expect(
      [for (final i in list.items) (i.name, i.quantity)],
      [('Reis', '1,5 kg'), ('Mineralwasser', '12 l'), ('Pflaster', '1')],
    );
    expect(list.items.first.supplyCategory, 'food');
    expect(list.created, DateTime.utc(2026, 10, 10, 9, 30));
    expect(
      (list.target!.days, list.target!.met, list.target!.waterLiters),
      (10, false, 34),
    );
  });

  test('other files and newer versions are refused', () {
    Matcher refused(PreppSuiteProblem p) => throwsA(
      isA<PreppSuiteFormatException>().having((e) => e.problem, 'problem', p),
    );
    expect(
      () => parsePreppSuiteList('kein json'),
      refused(PreppSuiteProblem.notAList),
    );
    expect(
      () => parsePreppSuiteList('{"format":"bring","version":1}'),
      refused(PreppSuiteProblem.notAList),
    );
    expect(
      () => parsePreppSuiteList(
        '{"format":"preppsuite-einkaufsliste","version":2,"items":[]}',
      ),
      refused(PreppSuiteProblem.newerVersion),
    );
  });

  testWidgets('chosen articles go on the list, each in its aisle', (
    tester,
  ) async {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    const list = ShoppingList(id: 'l', name: 'Einkauf');
    engine
      ..saveShoppingList(list)
      ..saveShoppingItem(
        const ShoppingItem(id: 'r', listId: 'l', name: 'reis'),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => addFromPreppSuite(
                context,
                engine,
                list,
                parsePreppSuiteList(_export),
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Aus PreppSuite übernehmen'), findsOneWidget);
    expect(find.textContaining('34 l Wasser und 12.000 kcal'), findsOneWidget);
    // Rice is on the list already: not ticked.
    expect(find.text('1,5 kg · steht schon auf der Liste'), findsOneWidget);
    await tester.tap(find.text('Pflaster'));
    await tester.pump();
    await tester.tap(find.text('Übernehmen (1)'));
    await tester.pumpAndSettle();
    expect(find.text('1 Artikel übernommen'), findsOneWidget);
    final added = engine.shoppingItems('l').where((i) => i.id != 'r').single;
    expect((added.name, added.quantity), ('Mineralwasser', '12 l'));
    expect(added.category, guessShoppingCategory('Mineralwasser'));
    expect(added.category, isNotEmpty);
  });
}
