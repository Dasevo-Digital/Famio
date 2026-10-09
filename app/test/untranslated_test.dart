// Every area in English and Spanish: no German text may be left on screen
// (umlauts and common German words give it away).
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mum","displayName":"Mum","isAdmin":true},'
    '{"id":"m2","username":"dad","displayName":"Dad"},'
    '{"id":"k1","username":"lena","displayName":"Lena","role":"child"}]';

final _german = RegExp(
  r'[äöüÄÖÜß]|\b(und|nicht|oder|mit|für|eine?|der|die|das|noch|keine?|'
  r'Termine?|Aufgabe|Einkauf|Kinder|Familie|Einstellungen|heute|morgen)\b',
);

void main() {
  setUpAll(initializeDateFormatting);

  for (final language in ['en', 'es']) {
    testWidgets('no German left ($language)', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(() => useLanguage('de'));
      SharedPreferences.setMockInitialValues({'language': language});
      FlutterSecureStorage.setMockInitialValues({});
      const me = FamilyMember(
        id: 'm1',
        username: 'mum',
        displayName: 'Mum',
        isAdmin: true,
      );
      final state = AppState();
      await state.init();
      final engine = SyncEngine(
        store: LocalStore.open(':memory:')..setMeta('members', _members),
        api: FamioApiClient('localhost:1'),
        memberId: me.id,
      );
      final today = DateUtils.dateOnly(DateTime.now());
      engine
        ..saveTask(Task(id: 't1', title: 'Trash', due: today, assigneeId: 'k1'))
        ..saveEvent(
          CalendarEvent(
            id: 'e1',
            title: 'Meeting',
            start: today.add(const Duration(hours: 19)),
            end: today.add(const Duration(hours: 20)),
          ),
        )
        ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Groceries'))
        ..saveShoppingItem(
          const ShoppingItem(id: 'i1', listId: 'l1', name: 'Milk'),
        )
        ..saveChild(
          Child(id: 'c1', name: 'Lena', birthDate: DateTime(2019, 4, 2)),
        );
      state
        ..me = me
        ..engine = engine;
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pumpAndSettle();

      final found = <String>{};
      void collect(String area) {
        for (final w in tester.widgetList<Text>(find.byType(Text))) {
          final text = w.data ?? w.textSpan?.toPlainText() ?? '';
          if (_german.hasMatch(text)) found.add('$area: $text');
        }
      }

      for (final area in FamioSection.values) {
        final target = find.text(
          area.title(tester.element(find.byType(Scaffold).first)),
        );
        if (target.evaluate().isEmpty) continue;
        await tester.tap(target.first);
        await tester.pumpAndSettle();
        collect(area.name);
      }
      await tester.pump(const Duration(seconds: 1));
      expect(found, isEmpty, reason: found.join('\n'));
    });
  }
}
