import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/conflicts_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"m2","username":"papa","displayName":"Papa"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('the fields that differ, with readable names', () {
    expect(
      conflictDiff(
        {'title': 'Einkaufen (Aldi)', 'done': false, 'visibleTo': null},
        {'title': 'Einkaufen gehen', 'done': false, 'ext:prio': 1},
      ),
      [('Titel', 'Einkaufen (Aldi)', 'Einkaufen gehen')],
    );
    expect(conflictTitle({'text': 'WLAN\nPasswort'}), 'WLAN');
  });

  testWidgets('start page points to it; bringing the other version back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    final kept = SyncRecord(
      collection: Collections.tasks,
      id: 't1',
      data: const Task(id: 't1', title: 'Einkaufen (Aldi)').toData(),
      updatedAt: DateTime(2026, 10, 9, 12).millisecondsSinceEpoch,
      updatedBy: 'm1',
      rev: 3,
    );
    final lost = SyncRecord(
      collection: Collections.tasks,
      id: 't1',
      data: const Task(id: 't1', title: 'Einkaufen gehen').toData(),
      updatedAt: DateTime(2026, 10, 9, 11).millisecondsSinceEpoch,
      updatedBy: 'm2',
      rev: 2,
    );
    final conflict = SyncConflict.between(lost: lost, kept: kept);
    // As the server sends them.
    engine.store
      ..put(kept, dirty: false)
      ..put(
        SyncRecord(
          collection: Collections.conflicts,
          id: conflict.id,
          data: conflict.toData(audience: ['m1', 'm2']),
          updatedAt: 1,
          updatedBy: 'server',
          rev: 4,
        ),
        dirty: false,
      );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    await tester.pump();
    final banner = find.text(
      'Eine Änderung hat sich überschnitten – bitte ansehen',
    );
    expect(banner, findsOneWidget);
    await tester.tap(banner);
    await tester.pumpAndSettle();
    expect(find.text('Aufgabe: Einkaufen (Aldi)'), findsOneWidget);
    expect(find.textContaining('Aufgehoben: die von Papa'), findsOneWidget);
    await tester.tap(find.text('Fassung von Papa zurückholen'));
    await tester.pumpAndSettle();
    expect(
      engine.record(Collections.tasks, 't1')!.data['title'],
      'Einkaufen gehen',
    );
    expect(engine.records(Collections.conflicts), isEmpty);
    expect(find.text('Nichts zu entscheiden.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
