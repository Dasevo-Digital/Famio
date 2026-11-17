// "Teilen an Famio" offers only what the member may do, and says what it
// really did (GRU-088, ALL-132).
import 'dart:async';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/platform/opened_files.dart';
import 'package:famio/src/screens/share_target.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  Future<void> start(
    WidgetTester tester, {
    MemberRole role = MemberRole.adult,
    Set<String> hidden = const {},
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tips.off': true});
    FlutterSecureStorage.setMockInitialValues({});
    final me = FamilyMember(
      id: 'm1',
      username: 'bea',
      displayName: 'Bea',
      role: role,
    );
    final state = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          '[{"id":"m1","username":"bea","displayName":"Bea",'
              '"role":"${role.name}"}]',
        ),
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    state
      ..me = me
      ..engine = engine
      ..hiddenModules = hidden;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
  }

  void share(WidgetTester tester, String text) => unawaited(
    showShareTarget(
      tester.element(find.byType(Scaffold).first),
      SharedContent(text: text),
      go: (FamioSection _) {},
      navigatorOf: (FamioSection _) => null,
    ),
  );

  testWidgets('a guest is offered no note for the pin board', (tester) async {
    await start(tester, role: MemberRole.guest);
    share(tester, 'Milch');
    await tester.pumpAndSettle();
    expect(find.text('Teilen an Famio'), findsOneWidget);
    expect(find.text('Als Notiz auf die Pinnwand'), findsNothing);
    expect(find.text('Auf die Einkaufsliste'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
  });

  testWidgets('no shopping list when the area is switched off', (tester) async {
    await start(tester, hidden: {FamioSection.shopping.name});
    share(tester, 'Milch\nBrot');
    await tester.pumpAndSettle();
    expect(find.text('Auf die Einkaufsliste'), findsNothing);
    expect(find.text('Als Notiz auf die Pinnwand'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
  });

  testWidgets('what is on the list already is not counted as added', (
    tester,
  ) async {
    await start(tester);
    engine
      ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'))
      ..saveShoppingItem(
        const ShoppingItem(id: 'a', listId: 'l1', name: 'Milch'),
      )
      ..saveShoppingItem(
        const ShoppingItem(id: 'b', listId: 'l1', name: 'Brot'),
      );
    await tester.pump();
    share(tester, '- Milch\n- Brot');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auf die Einkaufsliste'));
    await tester.pumpAndSettle();
    expect(find.text('Steht schon alles auf „Einkauf“'), findsOneWidget);
    expect(engine.shoppingItems('l1'), hasLength(2));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    share(tester, 'Milch\nEier\nEier');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auf die Einkaufsliste'));
    await tester.pumpAndSettle();
    expect(find.text('1 Artikel auf „Einkauf“'), findsOneWidget);
    expect([for (final i in engine.shoppingItems('l1')) i.name]..sort(), [
      'Brot',
      'Eier',
      'Milch',
    ]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a link of a recipe site offers the import first (#567)', (
    tester,
  ) async {
    await start(tester);
    double top(String label) => tester.getTopLeft(find.text(label)).dy;
    share(
      tester,
      'Spaghetti Carbonara – Rezept | Chefkoch '
      'https://www.chefkoch.de/rezepte/1234/Spaghetti-Carbonara.html',
    );
    await tester.pumpAndSettle();
    expect(
      top('Als Rezept importieren'),
      lessThan(top('Im Familien-Eingang ablegen')),
    );
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    // Another link: the inbox first, the recipe offered after it.
    share(tester, 'https://example.com/termine/elternabend');
    await tester.pumpAndSettle();
    expect(
      top('Als Rezept importieren'),
      greaterThan(top('Im Familien-Eingang ablegen')),
    );
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
  });
}
