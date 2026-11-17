// Tapping a notification opens what it is about (#385): the reminder keys
// give their targets, and the app shell opens the task, the appointment's
// date, the chat, the section or the page; nothing that is not the
// member's, and only once the app lock is gone.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/reminder_targets.dart';
import 'package:famio/src/screens/chat_screens.dart';
import 'package:famio/src/screens/chores_screens.dart';
import 'package:famio/src/screens/deadlines_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"bea","displayName":"Bea","isAdmin":true},'
    '{"id":"m2","username":"tom","displayName":"Tom"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('reminder keys', () {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    engine.put(Collections.childLogs, 'l1', const {
      'childId': 'k1',
      'kind': 'note',
    });
    final at = DateTime(2026, 11, 20, 18, 30);
    NoticeTarget? of(String key) =>
        reminderTarget(DueReminder(key: key, at: at, title: ''), engine);

    test('give what tapping them opens', () {
      final start = DateTime(2026, 11, 21, 10);
      final occurrence = 'ev@cal.example@${start.toIso8601String()}';
      expect(
        of('task:t1@${at.toIso8601String()}'),
        const NoticeTarget.task('t1'),
      );
      expect(
        of('event:$occurrence'),
        NoticeTarget.event('ev@cal.example', start),
      );
      expect(
        of('departure:$occurrence'),
        NoticeTarget.event('ev@cal.example', start),
      );
      expect(
        of('lift:bring:$occurrence'),
        NoticeTarget.event('ev@cal.example', start),
      );
      expect(of('kid:k1:u5:start'), const NoticeTarget.child('k1'));
      expect(of('log:l1'), const NoticeTarget.child('k1'));
      expect(of('preg:p1:leave'), const NoticeTarget.pregnancy('p1'));
      expect(of('bday:c1:2026:eve'), NoticeTarget.day(DateTime(2026, 11, 21)));
      expect(of('bday:c1:2026'), NoticeTarget.day(DateTime(2026, 11, 20)));
      expect(of('day:2026-11-22'), NoticeTarget.day(DateTime(2026, 11, 22)));
      expect(of('week:2026-11-23'), NoticeTarget.day(DateTime(2026, 11, 23)));
      expect(of('med:m1:x'), const NoticeTarget.section('health'));
      expect(
        of('deadline:d1:2026-11-20'),
        const NoticeTarget.page(NoticeTarget.deadlines),
      );
      expect(
        of('subscription:a1:2026-11-20'),
        const NoticeTarget.page(NoticeTarget.subscriptions),
      );
      expect(
        of('loan:l1:2026-11-20'),
        const NoticeTarget.page(NoticeTarget.loans),
      );
      expect(
        of('waste:2026-11-20'),
        const NoticeTarget.page(NoticeTarget.waste),
      );
      expect(of('doc:d1:7'), const NoticeTarget.section('documents'));
      expect(of('profile:1:24'), isNull);
      expect(of('log:unknown'), isNull);
    });
  });

  group('the app shell opens', () {
    late AppState state;
    late SyncEngine engine;
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final start = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 10);

    Future<void> run(
      WidgetTester tester, {
      MemberRole role = MemberRole.adult,
      Set<String> hidden = const {},
    }) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'tips.off': true});
      FlutterSecureStorage.setMockInitialValues({});
      state = AppState();
      await state.init();
      engine = SyncEngine(
        store: LocalStore.open(':memory:')
          ..setMeta(
            'members',
            role == MemberRole.adult
                ? _members
                : '[{"id":"m1","username":"bea","displayName":"Bea",'
                      '"role":"${role.name}"},'
                      '{"id":"m2","username":"tom","displayName":"Tom"}]',
          ),
        api: FamioApiClient('localhost:1'),
        memberId: 'm1',
      );
      engine
        ..saveTask(
          Task(id: 't1', title: 'Rezept abholen', assigneeIds: const ['m1']),
        )
        ..saveEvent(
          CalendarEvent(
            id: 'e1',
            title: 'Elternabend',
            start: start,
            end: start.add(const Duration(hours: 1)),
          ),
        );
      state
        ..me = engine.members.firstWhere((m) => m.id == 'm1')
        ..engine = engine
        ..hiddenModules = hidden;
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pumpAndSettle();
    }

    Future<void> tap(WidgetTester tester, NoticeTarget target) async {
      state.openRequest.value = target;
      await tester.pumpAndSettle();
    }

    testWidgets('a task', (tester) async {
      await run(tester);
      await tap(tester, const NoticeTarget.task('t1'));
      expect(find.widgetWithText(TextField, 'Rezept abholen'), findsOneWidget);
    });

    testWidgets('an appointment, on its day', (tester) async {
      await run(tester);
      await tap(tester, NoticeTarget.event('e1', start));
      expect(find.widgetWithText(TextField, 'Elternabend'), findsOneWidget);
    });

    testWidgets('a chat', (tester) async {
      await run(tester);
      await tap(tester, NoticeTarget.chat(ChatIds.direct('m1', 'm2')));
      final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(chat.title, 'Tom');
    });

    testWidgets('a section and a page', (tester) async {
      await run(tester);
      await tap(tester, const NoticeTarget.section('chores'));
      expect(find.byType(ChoresScreen), findsOneWidget);
      await tap(tester, const NoticeTarget.page(NoticeTarget.deadlines));
      expect(find.byType(DeadlinesScreen), findsOneWidget);
    });

    testWidgets('nothing of a section that is not the member\'s', (
      tester,
    ) async {
      await run(tester, hidden: {'chores'});
      await tap(tester, const NoticeTarget.section('chores'));
      expect(find.byType(ChoresScreen), findsNothing);
      // A task that no longer exists: its section only.
      await tap(tester, const NoticeTarget.task('gone'));
      expect(find.byType(BottomSheet), findsNothing);
      // Nor a chat of others.
      final others = ChatIds.direct('m2', 'm3');
      await tap(tester, NoticeTarget.chat(others));
      expect(
        find.byWidgetPredicate((w) => w is ChatScreen && w.chatId == others),
        findsNothing,
      );
    });

    testWidgets('only once the app lock is gone', (tester) async {
      await run(tester);
      state.lock.locked = true;
      await tap(tester, const NoticeTarget.task('t1'));
      expect(find.widgetWithText(TextField, 'Rezept abholen'), findsNothing);
      state.lock.signedOut(); // unlocked, as far as the waiting goes
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Rezept abholen'), findsOneWidget);
    });
  });
}
