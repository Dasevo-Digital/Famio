import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/edit_merge.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/screens/medication_screens.dart';
import 'package:famio/src/screens/tasks_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

/// Editors save what was changed in them, not the whole entry as it was
/// when they opened (#483), and the medication editor keeps the stock count
/// it did not change (#480).
void main() {
  setUpAll(() => initializeDateFormatting('de'));
  late SyncEngine engine;

  Future<void> open(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    state
      ..me = engine.members.first
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pumpAndSettle();
  }

  group('mergeEdit', () {
    test('only what the editor changed replaces the current entry', () {
      final merged = mergeEdit(
        opened: {'title': 'A', 'notes': '', 'done': false, 'due': '1'},
        edited: {'title': 'B', 'notes': '', 'done': false, 'due': '1'},
        current: {
          'title': 'A',
          'notes': 'neu',
          'done': true,
          'due': '2',
          'x': 1,
        },
      );
      expect(merged, {
        'title': 'B',
        'notes': 'neu',
        'done': true,
        'due': '2',
        'x': 1,
      });
    });

    test('a key the editor removed goes, one it added comes', () {
      expect(
        mergeEdit(
          opened: {'a': 1, 'b': 2},
          edited: {'b': 2, 'c': 3},
          current: {'a': 1, 'b': 5},
        ),
        {'b': 5, 'c': 3},
      );
    });

    test('lists of entries with ids merge per entry', () {
      Map<String, Object?> step(String id, {bool done = false, String? text}) =>
          {'id': id, 'text': text ?? id, 'done': done};
      final merged = mergeEdit(
        opened: {
          'checklist': [step('a'), step('b'), step('c')],
        },
        // Here: b renamed, c removed, d added.
        edited: {
          'checklist': [step('a'), step('b', text: 'B'), step('d')],
        },
        // There: a ticked, b ticked, e added.
        current: {
          'checklist': [
            step('a', done: true),
            step('b', done: true),
            step('c'),
            step('e'),
          ],
        },
      );
      expect(merged['checklist'], [
        step('a', done: true),
        step('b', done: true, text: 'B'),
        step('d'),
        step('e'),
      ]);
    });
  });

  group('mergeEdit with real entries (2.0.53)', () {
    const f1 = FileRef(id: 'f1', name: 'a.jpg', mime: 'image/jpeg', size: 1);
    const f2 = FileRef(id: 'f2', name: 'b.jpg', mime: 'image/jpeg', size: 1);
    Map<String, Object?> merge(Task opened, Task edited, Task current) =>
        mergeEdit(
          opened: opened.toData(),
          edited: edited.toData(),
          current: current.toData(),
        );
    List<String?> steps(Map<String, Object?> data) => [
      for (final s in data['checklist'] as List? ?? const []) (s as Map)['id'],
    ];

    test('both devices add the first steps', () {
      const opened = Task(id: 't', title: 'Einkauf');
      final merged = merge(
        opened,
        opened.copyWith(
          checklist: const [TaskStep(id: 'brot', text: 'Brot')],
        ),
        opened.copyWith(
          checklist: const [TaskStep(id: 'milch', text: 'Milch')],
        ),
      );
      expect(steps(merged), ['brot', 'milch']);
    });

    test('all steps removed here, one added there', () {
      const opened = Task(
        id: 't',
        title: 'Einkauf',
        checklist: [TaskStep(id: 'eier', text: 'Eier')],
      );
      final merged = merge(
        opened,
        opened.copyWith(checklist: const []),
        opened.copyWith(
          checklist: const [
            TaskStep(id: 'eier', text: 'Eier'),
            TaskStep(id: 'butter', text: 'Butter'),
          ],
        ),
      );
      expect(steps(merged), ['butter']);
    });

    test('both devices attach the first photo', () {
      const opened = Task(id: 't', title: 'Rechnung');
      final merged = merge(
        opened,
        opened.copyWith(photos: const [f2]),
        opened.copyWith(photos: const [f1]),
      );
      expect(Task.fromRecord(_record(merged)).photos.map((f) => f.id), [
        'f2',
        'f1',
      ]);
    });

    test('people: changed there and here, both count', () {
      const opened = Task(id: 't', title: 'Müll', assigneeIds: ['A']);
      final merged = merge(
        opened,
        opened.copyWith(assigneeIds: ['A', 'C']),
        opened.copyWith(assigneeIds: ['B']),
      );
      expect(Task.assigneesIn(merged), ['B', 'C']);
      expect(merged['assigneeId'], 'B');
    });

    test('a series skipped on both devices', () {
      final opened = CalendarEvent(
        id: 'e',
        title: 'Schwimmen',
        start: DateTime(2026, 11, 2, 16),
        end: DateTime(2026, 11, 2, 17),
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
      );
      final merged = mergeEdit(
        opened: opened.toData(),
        edited: opened.copyWith(exceptions: {DateTime(2026, 11, 9)}).toData(),
        current: opened.copyWith(exceptions: {DateTime(2026, 11, 16)}).toData(),
      );
      expect(merged['exceptions'], hasLength(2));
    });

    test('a file removed here, another added there', () {
      final opened = CalendarEvent(
        id: 'e',
        title: 'Arzt',
        start: DateTime(2026, 11, 2, 16),
        end: DateTime(2026, 11, 2, 17),
        files: const [f1],
      );
      final merged = mergeEdit(
        opened: opened.toData(),
        edited: opened.copyWith(files: const []).toData(),
        current: opened.copyWith(files: const [f1, f2]).toData(),
      );
      expect(
        [for (final f in merged['files'] as List) (f as Map)['id']],
        ['f2'],
      );
    });

    test('no audience is everyone, not an empty set', () {
      expect(
        mergeEdit(
          opened: {'visibleTo': null},
          edited: {
            'visibleTo': ['A'],
          },
          current: {
            'visibleTo': ['A', 'B'],
          },
        )['visibleTo'],
        ['A'],
      );
    });
  });

  testWidgets('the task editor keeps a step ticked meanwhile', (tester) async {
    await open(tester, const TasksScreen());
    engine.saveTask(
      Task(
        id: 't1',
        title: 'Koffer packen',
        createdAt: DateTime(2026, 11, 1),
        assigneeIds: const ['k1'],
        checklist: const [
          TaskStep(id: 's1', text: 'Zahnbürste'),
          TaskStep(id: 's2', text: 'Schlafanzug'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Koffer packen'));
    await tester.pumpAndSettle();
    // Meanwhile Mia ticks a step on her phone.
    final now = engine.tasks.single;
    engine.saveTask(
      now.copyWith(
        checklist: [
          now.checklist.first.copyWith(done: true),
          now.checklist.last,
        ],
      ),
    );
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'Titel'),
      'Koffer packen!',
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final after = engine.tasks.single;
    expect(after.title, 'Koffer packen!');
    expect(after.checklist.first.done, isTrue);
  });

  testWidgets('the task editor keeps a task done meanwhile', (tester) async {
    await open(tester, const TasksScreen());
    engine.saveTask(
      Task(
        id: 't2',
        title: 'Müll rausbringen',
        createdAt: DateTime(2026, 11, 1),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Müll rausbringen'));
    await tester.pumpAndSettle();
    final now = engine.tasks.single;
    engine.saveTask(now.copyWith(done: true, completedAt: DateTime.now()));
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'Notizen'),
      'blaue Tonne',
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(engine.tasks.single.done, isTrue);
    expect(engine.tasks.single.notes, 'blaue Tonne');
  });

  group('medication stock (#480)', () {
    late DateTime countedAt;

    Future<void> withDosesTaken(WidgetTester tester) async {
      await open(tester, const MedicationScreen());
      countedAt = DateTime.now().subtract(const Duration(days: 3));
      engine.saveMedication(
        Medication(
          id: 'med1',
          name: 'Vitamin D',
          times: const ['08:00'],
          start: DateTime(2026, 1, 1),
          stock: 30,
          stockAt: countedAt,
          careIds: const ['m1'],
        ),
      );
      for (var d = 0; d < 4; d++) {
        engine.put(Collections.medicationIntakes, 'i$d', {
          'medicationId': 'med1',
          'at': countedAt
              .add(Duration(hours: 10 + d * 12))
              .toUtc()
              .toIso8601String(),
          'byId': 'm1',
          'skipped': false,
          SyncRecord.visibilityKey: ['m1'],
        });
      }
      await tester.pumpAndSettle();
    }

    double? left() {
      final m = engine.medication('med1')!;
      return m.left(engine.takenSinceCount(m));
    }

    Future<void> editAndSave(WidgetTester tester, {String? stock}) async {
      await tester.tap(find.text('Vitamin D').last);
      await tester.pumpAndSettle();
      if (stock != null) {
        await tester.enterText(
          find.widgetWithText(TextField, 'Stück vorrätig'),
          stock,
        );
      }
      await tester.enterText(
        find.widgetWithText(TextField, 'Notizen'),
        'nach dem Frühstück',
      );
      await tester.tap(find.byTooltip('Speichern'));
      await tester.pumpAndSettle();
    }

    testWidgets('saving without a new count keeps it', (tester) async {
      await withDosesTaken(tester);
      expect(left(), 26);
      await editAndSave(tester);
      await editAndSave(tester);
      final m = engine.medication('med1')!;
      expect(m.stock, 30);
      expect(m.stockAt, countedAt.toUtc().toLocal());
      expect(left(), 26);
      expect(m.notes, 'nach dem Frühstück');
    });

    testWidgets('a new count starts over', (tester) async {
      await withDosesTaken(tester);
      await editAndSave(tester, stock: '50');
      final m = engine.medication('med1')!;
      expect(m.stock, 50);
      expect(m.stockAt!.isAfter(countedAt), isTrue);
      expect(left(), 50);
    });

    testWidgets('a count made on another device meanwhile stays', (
      tester,
    ) async {
      await withDosesTaken(tester);
      await tester.tap(find.text('Vitamin D').last);
      await tester.pumpAndSettle();
      final now = engine.medication('med1')!;
      engine.saveMedication(
        Medication(
          id: now.id,
          name: now.name,
          times: now.times,
          start: now.start,
          stock: 100,
          stockAt: DateTime.now(),
          careIds: now.careIds,
        ),
      );
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Notizen'),
        'neue Packung',
      );
      await tester.tap(find.byTooltip('Speichern'));
      await tester.pumpAndSettle();
      expect(engine.medication('med1')!.stock, 100);
      expect(engine.medication('med1')!.notes, 'neue Packung');
    });
  });
}

SyncRecord _record(Map<String, Object?> data) => SyncRecord(
  collection: Collections.tasks,
  id: 't',
  data: data,
  updatedAt: 0,
);
