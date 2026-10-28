import 'dart:convert';

import 'package:famio/src/app_state.dart';
import 'package:famio/src/design/theme.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/trash_screen.dart';
import 'package:famio/src/widgets/assignment_confirmation.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  testWidgets('task confirmation reminders explain why a due date is needed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssignmentSettingsEditor(
            value: const AssignmentSettings(required: true),
            canRemind: false,
            onChanged: (_) => fail('The reminder must stay disabled'),
          ),
        ),
      ),
    );
    final tile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, tr.assignmentRemind),
    );
    expect(tile.onChanged, isNull);
    expect(find.text(tr.assignmentReminderNeedsDue), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  setUpAll(() => initializeDateFormatting('de'));
  const me = FamilyMember(
    id: 'member',
    username: 'member',
    displayName: 'Member',
  );

  Future<void> mount(
    WidgetTester tester,
    SyncEngine engine,
    Widget page,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final state = AppState()
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(theme: famioTheme(Brightness.light), home: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'an offline reply is visible and a changed assignment needs a new reply',
    (tester) async {
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient(
          (_) async => throw http.ClientException('Offline fixture'),
        ),
      );
      final store = LocalStore.open(':memory:')
        ..setMeta('members', jsonEncode([me.toJson()]));
      final engine = SyncEngine(store: store, api: api, memberId: me.id);
      final target = SyncRecord(
        collection: Collections.tasks,
        id: 'task',
        updatedAt: 1,
        data: Task(
          id: 'task',
          title: 'Help',
          assigneeIds: [me.id],
          assignmentConfirmation: const AssignmentSettings(required: true),
        ).toData(),
      );
      store.put(target, dirty: false);
      await mount(
        tester,
        engine,
        Scaffold(body: AssignmentPanel(target: target)),
      );
      expect(find.textContaining(tr.assignmentWaiting), findsOneWidget);
      await tester.tap(find.byType(ActionChip));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.assignmentAccepted));
      await tester.pumpAndSettle();
      expect(find.textContaining(tr.assignmentPendingSync), findsOneWidget);
      expect(
        engine.assignmentDecision(assignmentRequests(target).single),
        AssignmentDecision.accepted,
      );
      engine.put(Collections.tasks, 'task', {
        ...target.data,
        'title': 'Changed',
      });
      await tester.pump();
      await tester.pump();
      expect(find.textContaining(tr.assignmentWaiting), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await engine.dispose();
      store.close();
      api.close();
    },
  );

  testWidgets(
    'trash retries an error and restores without layout overflow at large text',
    (tester) async {
      var fail = true, restored = false;
      final entry = TrashEntry(
        id: 'trash',
        deletedAt: DateTime(2026, 10, 28),
        expiresAt: DateTime(2026, 11, 27),
        deletedBy: me.id,
        deletedRev: 2,
        record: const SyncRecord(
          collection: Collections.notes,
          id: 'note',
          data: {'title': 'A recoverable note'},
          updatedAt: 1,
        ),
      );
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient((request) async {
          Map<String, Object?> body;
          if (request.url.path.endsWith('/sync')) {
            body = SyncResponse(
              rev: 2,
              serverTime: DateTime.now().millisecondsSinceEpoch,
              changes: const [],
            ).toJson();
          } else if (request.url.path.endsWith('/restore')) {
            restored = true;
            body = {'ok': true};
          } else {
            if (fail) {
              return http.Response(
                jsonEncode({'error': 'offline', 'message': 'Offline fixture'}),
                503,
              );
            }
            body = {
              'items': [
                if (!restored) {...entry.toJson(), 'canRestore': true},
              ],
              'next': null,
            };
          }
          return http.Response(jsonEncode(body), 200);
        }),
      );
      final engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: api,
        memberId: me.id,
      );
      await mount(tester, engine, const TrashScreen());
      expect(find.text('Offline fixture'), findsOneWidget);
      fail = false;
      await tester.tap(find.text(tr.commonRetry));
      await tester.pumpAndSettle();
      expect(find.text(entry.title), findsOneWidget);
      await tester.ensureVisible(find.text(tr.trashRestore));
      await tester.tap(find.text(tr.trashRestore));
      await tester.pumpAndSettle();
      expect(restored, isTrue);
      expect(find.text(tr.trashEmpty), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await engine.dispose();
      engine.store.close();
      api.close();
    },
  );
}
