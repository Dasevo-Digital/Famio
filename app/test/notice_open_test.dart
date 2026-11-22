// Tapping a notification opens what it is about (#385): the reminder keys
// give their targets, and the app shell opens the task, the appointment's
// date, the chat, the section or the page; nothing that is not the
// member's, and only once the app lock is gone.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/reminder_targets.dart';
import 'package:famio/src/platform/opened_files.dart';
import 'package:famio/src/screens/calendar_screen.dart';
import 'package:famio/src/screens/chat_screens.dart';
import 'package:famio/src/screens/chores_screens.dart';
import 'package:famio/src/screens/deadlines_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
      FamioApiClient? api,
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
        api: api ?? FamioApiClient('localhost:1'),
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

    testWidgets('an imported appointment opens its read-only view', (
      tester,
    ) async {
      await run(tester);
      final appointment = CalendarEvent(
        id: 'external',
        title: 'Train timetable',
        notes: 'Details from the subscription',
        start: start,
        end: start.add(const Duration(hours: 1)),
        sourceId: 'caldav:test',
      );
      engine.put(
        Collections.externalEvents,
        appointment.id,
        appointment.toData(),
      );
      await tap(tester, NoticeTarget.event(appointment.id, start));
      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: sheet, matching: find.text(appointment.title)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.byType(TextField)),
        findsNothing,
      );
      final details = find.descendant(
        of: sheet,
        matching: find.byType(SelectableText),
      );
      expect(tester.widget<SelectableText>(details).data, appointment.notes);
    });

    testWidgets(
      'a target opens when it arrives instead of needing another tap',
      (tester) async {
        await run(tester);
        const id = 'pending';
        await tap(tester, const NoticeTarget.task(id));
        expect(find.widgetWithText(TextField, 'Just synced'), findsNothing);
        engine.saveTask(Task(id: id, title: 'Just synced'));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'Just synced'), findsOneWidget);
      },
    );

    testWidgets('a missing target falls back when an offline sync ends', (
      tester,
    ) async {
      await run(
        tester,
        api: FamioApiClient(
          'localhost:1',
          httpClient: MockClient(
            (_) async => http.Response('Unavailable', 503),
          ),
        ),
      );
      await tap(tester, const NoticeTarget.event('missing'));
      expect(find.byType(CalendarScreen), findsNothing);
      final sync = engine.sync();
      await tester.pumpAndSettle();
      await sync;
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a missing target falls back after the wait expires', (
      tester,
    ) async {
      await run(tester);
      await tap(tester, const NoticeTarget.event('missing'));
      expect(find.byType(CalendarScreen), findsNothing);
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a target waiting for sync is dropped with the old session', (
      tester,
    ) async {
      await run(tester);
      await tap(tester, const NoticeTarget.event('pending'));
      state.engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: FamioApiClient('localhost:1'),
        memberId: 'different-member',
      );
      engine.saveEvent(
        CalendarEvent(
          id: 'pending',
          title: 'Previous session',
          start: start,
          end: start.add(const Duration(hours: 1)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      await engine.stop();
    });

    testWidgets('share signals drain the queue one dialog at a time', (
      tester,
    ) async {
      final pending = ['First share', 'Second share'];
      const channel = MethodChannel('famio/open_file');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'takeShare' || pending.isEmpty) return null;
        return <String, Object?>{'text': pending.removeAt(0)};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await run(tester);
      expect(find.text('First share'), findsOneWidget);
      OpenedFiles.onOpened!();
      await tester.pumpAndSettle();
      expect(pending, ['Second share']);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Second share'), findsOneWidget);
      expect(pending, isEmpty);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    group('a link from ntfy (#578)', () {
      const key = 'R4nd0mKeyOfANotice_123';

      /// The phone hands over [handedOver] once, as from `famio://open?…`;
      /// the server knows only [key], as a link to the task.
      Future<List<Uri>> open(WidgetTester tester, String handedOver) async {
        final asked = <Uri>[];
        String? pending = handedOver;
        const channel = MethodChannel('famio/open_file');
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'takeTarget') return null;
          final value = pending;
          pending = null;
          return value;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await run(
          tester,
          api: FamioApiClient(
            'https://famio.test',
            token: 't',
            httpClient: MockClient((request) async {
              if (!request.url.path.startsWith('/api/notifications/link/')) {
                return http.Response('Unavailable', 503);
              }
              asked.add(request.url);
              return request.url.pathSegments.last == key
                  ? http.Response(
                      '{"target":"task:t1"}',
                      200,
                      headers: {'content-type': 'application/json'},
                    )
                  : http.Response(
                      '{"error":"not_found","message":"nicht gefunden"}',
                      404,
                      headers: {'content-type': 'application/json'},
                    );
            }),
          ),
        );
        await tester.pumpAndSettle();
        // The engine's write from the start: its upload waits a moment.
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        return asked;
      }

      testWidgets('opens what the server says it is about', (tester) async {
        final asked = await open(tester, 'notice:$key');
        expect(asked.single.path, '/api/notifications/link/$key');
        expect(
          find.widgetWithText(TextField, 'Rezept abholen'),
          findsOneWidget,
        );
      });

      testWidgets('a notification the server no longer knows opens only '
          'the app', (tester) async {
        final asked = await open(tester, 'notice:UnknownKeyOfANotice_9');
        expect(asked, hasLength(1));
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
      });

      testWidgets('a link with the target itself (older servers) still '
          'opens it', (tester) async {
        final asked = await open(tester, 'task:t1');
        expect(asked, isEmpty);
        expect(
          find.widgetWithText(TextField, 'Rezept abholen'),
          findsOneWidget,
        );
      });
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
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      // Nor a chat of others.
      final others = ChatIds.direct('m2', 'm3');
      await tap(tester, NoticeTarget.chat(others));
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
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
