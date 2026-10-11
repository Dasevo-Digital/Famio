import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/kids_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  /// The milestones tab (or another [tab], null: the one it opens with) of a
  /// child born [months] months ago today.
  Future<SyncEngine> openMilestones(
    WidgetTester tester,
    int months, {
    ChildSex? sex,
    String? tab = 'Meilensteine',
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    final now = DateTime.now();
    engine.saveChild(
      Child(
        id: 'c1',
        name: 'Ben',
        birthDate: DateTime(now.year, now.month - months, now.day),
        sex: sex,
      ),
    );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => const ChildScreen(childId: 'c1'),
          ),
        );
    await tester.pumpAndSettle();
    if (tab != null) {
      await tester.tap(find.text(tab).first);
      await tester.pumpAndSettle();
    }
    return engine;
  }

  testWidgets('a two-year-old is not asked about first steps', (tester) async {
    await openMilestones(tester, 24);
    // What is due now.
    expect(find.text('Springt mit beiden Beinen'), findsWidgets);
    expect(find.text('Zweiwortsätze („Mama Auto“)'), findsWidgets);
    // First steps only folded away, to add them afterwards.
    expect(find.text('Erste freie Schritte'), findsNothing);
    final folded = find.text('Früher erreicht? Nachtragen');
    await tester.scrollUntilVisible(
      folded,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(folded);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Erste freie Schritte'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Erste freie Schritte'), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a toddler of 16 months still sees first steps', (tester) async {
    await openMilestones(tester, 16);
    expect(find.text('Erste freie Schritte'), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a reached milestone stays in the list', (tester) async {
    final engine = await openMilestones(tester, 30);
    engine.saveChildEntry(
      ChildEntry(
        id: 'e1',
        childId: 'c1',
        kind: ChildEntryKind.milestone,
        refId: 'walk',
        date: DateTime.now().subtract(const Duration(days: 400)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Erste freie Schritte'), findsWidgets);
    expect(find.textContaining('Geschafft am'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  Future<void> scrollTo(WidgetTester tester, String text) =>
      tester.scrollUntilVisible(
        find.text(text),
        300,
        scrollable: find.byType(Scrollable).last,
      );

  testWidgets('a newborn: what it sees and hears', (tester) async {
    await openMilestones(tester, 0);
    expect(find.text('Entwicklungsphasen'), findsOneWidget);
    expect(find.text('Sehen: Gesichter auf Armlänge'), findsOneWidget);
    expect(find.text('Hören: von Anfang an'), findsOneWidget);
    expect(find.textContaining('Gerade dran · Geburt bis'), findsWidgets);
    expect(find.textContaining('20 bis 30 Zentimetern'), findsOneWidget);
    await scrollTo(tester, 'Schaut Gesichter aufmerksam an');
    expect(find.text('Schaut Gesichter aufmerksam an'), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('puberty follows the sex in the profile', (tester) async {
    await openMilestones(tester, 150, sex: ChildSex.female);
    expect(find.text('Pubertät: Beginn'), findsOneWidget);
    expect(find.text('Pubertät: Mitte'), findsOneWidget);
    expect(find.textContaining('Trag im Profil'), findsNothing);
    await scrollTo(tester, 'Erste Periode');
    expect(find.text('Erste Periode'), findsWidgets);
    expect(find.text('Stimmbruch'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('without the sex both are shown and the app asks for it', (
    tester,
  ) async {
    await openMilestones(tester, 150);
    expect(find.textContaining('Trag im Profil'), findsOneWidget);
    await scrollTo(tester, 'Stimmbruch');
    expect(find.text('Stimmbruch'), findsWidgets);
    expect(find.text('Erste Periode'), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the timeline announces a coming phase and explains it', (
    tester,
  ) async {
    await openMilestones(tester, 17, tab: 'Zeitstrahl');
    final phase = find.text('Autonomiephase („Trotzphase“)');
    expect(phase, findsOneWidget);
    await tester.tap(phase);
    await tester.pumpAndSettle();
    expect(find.textContaining('Wutanfälle gehören dazu'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
