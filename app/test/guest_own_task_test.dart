// Guests edit and delete the tasks they created themselves; the others they
// only read and tick off (#365).
import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/screens/tasks_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"g1","username":"oma","displayName":"Oma","role":"guest"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  Future<BuildContext> start(
    WidgetTester tester, {
    String memberId = 'g1',
  }) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/api/me')) {
        return http.Response(
          jsonEncode({'id': memberId, 'username': 'x', 'displayName': 'X'}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 503);
    });
    final state = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1', httpClient: client),
      memberId: memberId,
    );
    state
      ..me = engine.members.firstWhere((m) => m.id == memberId)
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    return tester.element(find.byType(Scaffold).first);
  }

  /// A task as the server holds it, created by [creator] (null: from
  /// before the server noted it).
  void stored(String id, String title, {String? creator}) =>
      engine.put(Collections.tasks, id, {
        ...Task(id: id, title: title, assigneeIds: const ['g1']).toData(),
        Task.createdByKey: ?creator,
      });

  Future<void> openTasks(WidgetTester tester, BuildContext context) async {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const TasksScreen()));
    await tester.pumpAndSettle();
  }

  DismissDirection swipe(WidgetTester tester, String title) => tester
      .widget<Dismissible>(
        find.ancestor(of: find.text(title), matching: find.byType(Dismissible)),
      )
      .direction;

  testWidgets('a guest edits an own task', (tester) async {
    final context = await start(tester);
    stored('t1', 'Kuchen backen', creator: 'g1');
    await openTasks(tester, context);
    await tester.tap(find.text('Kuchen backen'));
    await tester.pumpAndSettle();
    expect(find.text('Speichern'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Kuchen backen'),
      'Apfelkuchen backen',
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final saved = engine.record(Collections.tasks, 't1')!;
    expect(saved.data['title'], 'Apfelkuchen backen');
    expect(saved.data[Task.createdByKey], 'g1');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a guest deletes an own task', (tester) async {
    final context = await start(tester);
    stored('t1', 'Kuchen backen', creator: 'g1');
    await openTasks(tester, context);
    expect(swipe(tester, 'Kuchen backen'), DismissDirection.endToStart);
    await tester.tap(find.text('Kuchen backen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    expect(engine.tasks, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a task the guest adds is the guest\'s own', (tester) async {
    await start(tester);
    engine.saveTask(const Task(id: 'neu', title: 'Blumen gießen'));
    expect(
      engine.record(Collections.tasks, 'neu')!.data[Task.createdByKey],
      'g1',
    );
    expect(engine.mayChangeTask(engine.tasks.single), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the family\'s tasks and older ones stay for reading', (
    tester,
  ) async {
    final context = await start(tester);
    stored('t1', 'Rasen mähen', creator: 'm1');
    // From before the server noted who created a task.
    stored('t2', 'Hecke schneiden');
    await openTasks(tester, context);
    for (final title in ['Rasen mähen', 'Hecke schneiden']) {
      expect(swipe(tester, title), DismissDirection.none, reason: title);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.text('Speichern'), findsNothing, reason: title);
      await tester.tap(find.text('Schließen'));
      await tester.pumpAndSettle();
    }
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an adult\'s edit keeps who created the task', (tester) async {
    await start(tester, memberId: 'm1');
    stored('t1', 'Kuchen backen', creator: 'g1');
    final task = engine.tasks.single;
    engine.saveTask(task.copyWith(title: 'Torte backen'), opened: task);
    expect(
      engine.record(Collections.tasks, 't1')!.data[Task.createdByKey],
      'g1',
    );
    expect(engine.mayChangeTask(task), isTrue, reason: 'adults change all');
    await tester.pump(const Duration(seconds: 5));
  });
}
