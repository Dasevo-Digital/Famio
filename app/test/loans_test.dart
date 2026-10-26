import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/loans.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/loans_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

SyncEngine _engine(String memberId) => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: memberId,
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('reminds whoever lent or borrowed it, borrowed things earlier', () {
    final now = DateTime(2026, 10, 26, 12);
    final drill = Loan(
      id: 'd',
      title: 'Bohrmaschine',
      person: 'Familie Weber',
      memberId: 'm2',
      due: DateTime(2026, 11, 2),
    );
    final book = Loan(
      id: 'b',
      title: 'Pferdebuch',
      lentOut: false,
      person: 'Lena',
      memberId: 'k1',
      due: DateTime(2026, 10, 30),
    );
    final ladder = Loan(
      id: 'l',
      title: 'Leiter',
      person: 'Nachbarn',
      due: DateTime(2026, 10, 28),
    );
    final back = Loan(
      id: 'x',
      title: 'Zelt',
      memberId: 'm2',
      due: DateTime(2026, 10, 29),
      returned: true,
    );
    Map<String, (DateTime, String, String?)> due(String member) => {
      for (final r in familyReminders(
        _engine(member)
          ..saveLoan(drill)
          ..saveLoan(book)
          ..saveLoan(ladder)
          ..saveLoan(back),
        from: now,
        to: now.add(const Duration(days: 14)),
      ))
        if (r.key.startsWith('loan:')) r.key: (r.at, r.title, r.body),
    };
    expect(due('m2'), {
      'loan:d:2026-11-02': (
        DateTime(2026, 11, 2, 9),
        '„Bohrmaschine“ sollte heute zurückkommen',
        'an Familie Weber',
      ),
      // Nobody in particular: all adults.
      'loan:l:2026-10-28': (
        DateTime(2026, 10, 28, 9),
        '„Leiter“ sollte heute zurückkommen',
        'an Nachbarn',
      ),
    });
    expect(due('k1'), {
      'loan:b:2026-10-30:soon': (
        DateTime(2026, 10, 28, 9),
        '„Pferdebuch“ in zwei Tagen zurückgeben',
        'von Lena',
      ),
      'loan:b:2026-10-30': (
        DateTime(2026, 10, 30, 9),
        '„Pferdebuch“ heute zurückgeben',
        'von Lena',
      ),
    });
    expect(book.overdueOn(DateTime(2026, 10, 30, 20)), isFalse);
    expect(book.overdueOn(DateTime(2026, 10, 31)), isTrue);
    expect(back.overdueOn(DateTime(2027)), isFalse);
  });

  testWidgets('a loan is noted, given back and shown as returned', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = _engine('m1');
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const LoansScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Noch nichts eingetragen'), findsOneWidget);

    await tester.tap(find.byTooltip('Leihgabe eintragen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Geliehen'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Was?'),
      'Kinderwagen',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Von wem?'),
      'Tante Jule',
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final loan = engine.loans.single;
    expect(
      (loan.title, loan.lentOut, loan.person, loan.memberId, loan.returned),
      ('Kinderwagen', false, 'Tante Jule', 'm1', false),
    );
    expect(loan.since, isNotNull);
    expect(find.text('von Tante Jule'), findsNothing);
    expect(find.textContaining('von Tante Jule'), findsOneWidget);

    await tester.tap(find.byTooltip('Ist zurück'));
    await tester.pumpAndSettle();
    expect(engine.loans.single.returned, isTrue);
    expect(find.text('Zurückgegeben'), findsOneWidget);
    expect(find.textContaining('Noch nichts eingetragen'), findsOneWidget);
    // Let the timers the changes started run out.
    await tester.pump(const Duration(seconds: 5));
  });
}
