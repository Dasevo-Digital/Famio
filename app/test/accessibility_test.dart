// Every area of the app against Flutter's accessibility guidelines: tap
// targets of at least 48 dp with a label everywhere, WCAG AA text contrast
// in the "Hoher Kontrast" mode (light and dark), and no overflow at 200 %
// text size.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"lena","displayName":"Lena","role":"child"}]';

/// A little of everything, so the areas show real content.
void _demo(SyncEngine e) {
  final today = DateUtils.dateOnly(DateTime.now());
  e
    ..saveTask(
      Task(id: 't1', title: 'Müll rausbringen', due: today, assigneeId: 'k1'),
    )
    ..saveEvent(
      CalendarEvent(
        id: 'e1',
        title: 'Elternabend',
        start: today.add(const Duration(hours: 19)),
        end: today.add(const Duration(hours: 20)),
      ),
    )
    ..saveShoppingList(const ShoppingList(id: 'l1', name: 'Einkauf'))
    ..saveShoppingItem(
      const ShoppingItem(id: 'i1', listId: 'l1', name: 'Milch'),
    )
    ..saveChild(Child(id: 'c1', name: 'Lena', birthDate: DateTime(2019, 4, 2)));
}

/// Areas reached from the side rail (wide window).
const _areas = [
  FamioSection.home,
  FamioSection.tasks,
  FamioSection.shopping,
  FamioSection.calendar,
  FamioSection.chat,
  FamioSection.documents,
  FamioSection.kids,
  FamioSection.chores,
  FamioSection.meals,
  FamioSection.budget,
  FamioSection.health,
  FamioSection.contacts,
  FamioSection.settings,
];

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Future<AppState> open(
    WidgetTester tester, {
    bool highContrast = false,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    Size size = const Size(1400, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    SharedPreferences.setMockInitialValues({'highContrast': highContrast});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(
      id: 'm1',
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    _demo(engine);
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> visit(
    WidgetTester tester,
    Future<void> Function(String area) check,
  ) async {
    for (final area in _areas) {
      final target = find.text(area.label);
      if (target.evaluate().isEmpty) continue; // switched off or behind "Mehr"
      await tester.tap(target.first);
      await tester.pumpAndSettle();
      await check(area.label);
    }
    // Let the sync debounce of the demo data run out.
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('every control has a label and a 48 dp target', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    final problems = <String>[];
    await visit(tester, (area) async {
      for (final g in [labeledTapTargetGuideline, androidTapTargetGuideline]) {
        final r = await g.evaluate(tester);
        if (!r.passed) problems.add('$area: ${r.reason}');
      }
    });
    semantics.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  for (final brightness in Brightness.values) {
    testWidgets('high contrast reaches WCAG AA (${brightness.name})', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await open(tester, highContrast: true, brightness: brightness);
      final problems = <String>[];
      await visit(tester, (area) async {
        final r = await textContrastGuideline.evaluate(tester);
        if (!r.passed) problems.add('$area: ${r.reason}');
      });
      semantics.dispose();
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  testWidgets('200 % text size fits on a phone', (tester) async {
    await open(tester, textScale: 2, size: const Size(390, 844));
    final problems = <String>[];
    // Phones show the main areas in the bottom bar (icons) and the rest
    // behind "Mehr"; the start page and the bar are what everyone sees.
    for (final tooltip in ['Aufgaben', 'Einkauf', 'Kalender', 'Chat']) {
      final target = find.byTooltip(tooltip);
      if (target.evaluate().isEmpty) continue;
      await tester.tap(target.first);
      await tester.pumpAndSettle();
      final error = tester.takeException();
      if (error != null) problems.add('$tooltip: $error');
    }
    await tester.pump(const Duration(seconds: 1));
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
