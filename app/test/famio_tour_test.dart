import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Future<void> open(
    WidgetTester tester, {
    required Size size,
    bool child = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final me = FamilyMember(
      id: 'm1',
      username: 'lena',
      displayName: 'Lena',
      isAdmin: !child,
      role: child ? MemberRole.child : MemberRole.adult,
    );
    final state = AppState();
    await state.init();
    state
      ..me = me
      ..engine = SyncEngine(
        store: LocalStore.open(':memory:')
          ..setMeta(
            'members',
            '[{"id":"m1","username":"lena","displayName":"Lena",'
                '"isAdmin":${!child},"role":"${child ? 'child' : 'adult'}"}]',
          ),
        api: FamioApiClient('localhost:1'),
        memberId: me.id,
      );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
  }

  /// The tour's titles from the first step to the last.
  Future<List<String>> walk(WidgetTester tester) async {
    final titles = <String>[];
    for (var i = 0; i < 12; i++) {
      final counter = tester.widget<Text>(find.textContaining('Schritt '));
      final total = int.parse(counter.data!.split(' ').last);
      final card = find
          .ancestor(of: find.byWidget(counter), matching: find.byType(Column))
          .first;
      final texts = tester
          .widgetList<Text>(
            find.descendant(of: card, matching: find.byType(Text)),
          )
          .map((t) => t.data ?? '')
          .toList();
      titles.add(texts[1]);
      if (titles.length == total) {
        expect(find.text('Fertig'), findsOneWidget);
        await tester.tap(find.text('Fertig'));
        await tester.pumpAndSettle();
        break;
      }
      await tester.tap(find.text('Weiter'));
      await tester.pumpAndSettle();
    }
    return titles;
  }

  testWidgets('offered once on the start page, walks the real buttons', (
    tester,
  ) async {
    await open(tester, size: const Size(1400, 1000));
    final banner = find.text('Neu bei Famio? Eine Minute Rundgang');
    expect(banner, findsOneWidget);
    await tester.tap(banner);
    await tester.pumpAndSettle();
    expect(find.text('Schritt 1 von 7'), findsOneWidget);
    expect(await walk(tester), [
      'Start',
      'Kalender',
      'Aufgaben',
      'Einkauf',
      'Kinder',
      'Notfallknopf',
      'Einstellungen',
    ]);
    expect(find.textContaining('Schritt '), findsNothing);
    expect(banner, findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getBool('tour.offered'),
      isTrue,
    );
  });

  testWidgets('a child on a phone: duties instead of children, "Mehr"', (
    tester,
  ) async {
    await open(tester, size: const Size(390, 844), child: true);
    await tester.tap(find.text('Neu bei Famio? Eine Minute Rundgang'));
    await tester.pumpAndSettle();
    final titles = await walk(tester);
    expect(titles, [
      'Start',
      'Kalender',
      'Ämter',
      'Einkauf',
      'Notfallknopf',
      'Mehr',
    ]);
    expect(titles, isNot(contains('Kinder')));
  });

  testWidgets('again from the settings; Escape ends it', (tester) async {
    await open(tester, size: const Size(1400, 1000));
    await tester.tap(find.byTooltip('Ausblenden').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen').first);
    await tester.pumpAndSettle();
    final entry = find.text('Kurze Tour durch Famio');
    await tester.scrollUntilVisible(
      entry,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('Schritt 1 von 7'), findsOneWidget);
    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();
    expect(find.text('Schritt 2 von 7'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('Schritt '), findsNothing);
  });
}
