// A declined chore: its child asks for the points again by ticking it; a
// sibling's declined one it cannot touch, as the server refuses it (#581).
import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/chores_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const mama = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
const lina = FamilyMember(
  id: 'k1',
  username: 'lina',
  displayName: 'Lina',
  role: MemberRole.child,
);
const fips = FamilyMember(
  id: 'k2',
  username: 'fips',
  displayName: 'Fips',
  role: MemberRole.child,
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('a child asks again for its own declined chore only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final store = LocalStore.open(':memory:')
      ..setMeta(
        'members',
        jsonEncode([
          for (final m in [mama, lina, fips]) m.toJson(),
        ]),
      );
    final today = DateUtils.dateOnly(DateTime.now());
    final asMama = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: mama.id,
    );
    Chore chore(String id, String title, List<String> members) =>
        Chore(id: id, title: title, memberIds: members, start: DateTime(2026));
    final own = chore('c1', 'Spülmaschine', [lina.id]);
    final shared = chore('c2', 'Tisch decken', [lina.id, fips.id]);
    void declined(Chore c, FamilyMember who) => asMama.put(
      Collections.pointEntries,
      c.completionId(today),
      PointEntry(
        id: c.completionId(today),
        memberId: who.id,
        points: c.points,
        title: c.title,
        kind: PointKind.chore,
        at: DateTime.now(),
        refId: c.id,
        status: PointStatus.rejected,
        decidedBy: mama.id,
      ).toData(),
    );
    asMama
      ..saveChore(own)
      ..saveChore(shared);
    declined(own, lina);
    declined(shared, fips);

    final engine = SyncEngine(
      store: store,
      api: FamioApiClient('localhost:1'),
      memberId: lina.id,
    );
    final state = AppState();
    await state.init();
    state
      ..me = lina
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => const ChoresScreen()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    RoundCheck check(String title) => tester.widget<RoundCheck>(
      find.byWidgetPredicate((w) => w is RoundCheck && w.label == title),
    );
    expect(find.text('+1 ⭐ · ${tr.choresDeclined}'), findsNWidgets(2));
    expect(check('Tisch decken').onChanged, isNull);
    expect(check('Spülmaschine').onChanged, isNotNull);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is RoundCheck && w.label == 'Spülmaschine',
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final asked = engine.choreCompletion(own, today)!;
    expect((asked.status, asked.memberId), (PointStatus.pending, lina.id));
    expect(engine.choreCompletion(shared, today)!.status, PointStatus.rejected);
    await tester.pump(const Duration(seconds: 5));
  });
}
