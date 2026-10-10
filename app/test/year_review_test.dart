import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/year_review.dart';
import 'package:famio/src/design/theme.dart';
import 'package:famio/src/screens/year_review_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

SyncEngine _family() {
  final e = SyncEngine(
    store: LocalStore.open(':memory:')..setMeta('members', _members),
    api: FamioApiClient('localhost:1'),
    memberId: 'm1',
  );
  e
    ..saveEvent(
      CalendarEvent(
        id: 'urlaub',
        title: 'Ostsee',
        start: DateTime(2026, 7, 20),
        end: DateTime(2026, 7, 27),
        allDay: true,
      ),
    )
    ..saveEvent(
      CalendarEvent(
        id: 'arzt',
        title: 'Zahnarzt',
        start: DateTime(2026, 3, 3, 9),
        end: DateTime(2026, 3, 3, 10),
      ),
    )
    ..saveEvent(
      CalendarEvent(
        id: 'alt',
        title: 'Vorjahr',
        start: DateTime(2025, 5, 1),
        end: DateTime(2025, 5, 2),
        allDay: true,
      ),
    )
    ..saveTask(
      Task(
        id: 't1',
        title: 'Steuer',
        done: true,
        completedAt: DateTime(2026, 5, 1),
      ),
    )
    ..saveTask(const Task(id: 't2', title: 'Offen'));
  for (final (id, member) in [('p1', 'k1'), ('p2', 'k1'), ('p3', 'm2')]) {
    e.put(
      Collections.pointEntries,
      id,
      PointEntry(
        id: id,
        memberId: member,
        points: 1,
        title: 'Tisch decken',
        kind: PointKind.chore,
        at: DateTime(2026, 4, 1),
      ).toData(),
    );
  }
  for (var i = 0; i < 30; i++) {
    e.put(
      Collections.chatMessages,
      'c$i',
      ChatMessage(
        id: 'c$i',
        chatId: 'family',
        authorId: 'm1',
        sentAt: DateTime(2026, 1 + i % 12, 1 + i),
        attachment: FileRef(
          id: 'f$i',
          name: 'foto$i.jpg',
          mime: 'image/jpeg',
          size: 1,
        ),
      ).toData(),
    );
  }
  e.saveChild(Child(id: 'k', name: 'Mia', birthDate: DateTime(2024, 3, 1)));
  for (final entry in [
    ChildEntry(
      id: 'e1',
      childId: 'k',
      kind: ChildEntryKind.milestone,
      date: DateTime(2026, 2, 10),
      title: 'Erste Schritte',
    ),
    ChildEntry(
      id: 'e2',
      childId: 'k',
      kind: ChildEntryKind.measurement,
      date: DateTime(2026, 1, 10),
      heightCm: 80,
    ),
    ChildEntry(
      id: 'e3',
      childId: 'k',
      kind: ChildEntryKind.measurement,
      date: DateTime(2026, 11, 10),
      heightCm: 87.5,
    ),
  ]) {
    e.saveChildEntry(entry);
  }
  return e;
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('the year: numbers, trips, children, photos, chores', () {
    final r = yearReview(_family(), 2026);
    expect(r.events, 2);
    expect(r.tasksDone, 1);
    expect(r.choresDone, 3);
    expect(r.messages, 30);
    expect(r.trips.map((t) => t.title), ['Ostsee']);
    expect(r.kids.single.milestones, ['Erste Schritte']);
    expect(r.kids.single.grownCm, closeTo(7.5, 0.001));
    expect((r.photoCount, r.photos.length), (30, 12));
    expect(
      [for (final c in r.chores) (c.member.displayName, c.count)],
      [('Mia', 2), ('Papa', 1)],
    );
    expect(yearReview(_family(), 2024).isEmpty, isTrue);
  });

  test('looks back on the past year until December', () {
    expect(reviewYear(DateTime(2026, 11, 30)), 2025);
    expect(reviewYear(DateTime(2026, 12, 1)), 2026);
    expect(reviewYear(DateTime(2027, 1, 15)), 2026);
  });

  testWidgets('the page and the PDF', (tester) async {
    final engine = _family();
    final state = AppState()..engine = engine;
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: famioTheme(Brightness.light),
          home: const YearReviewScreen(year: 2026),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Unser Jahr 2026'), findsOneWidget);
    expect(find.text('Mia · 7,5 cm gewachsen'), findsOneWidget);
    expect(find.text('Ostsee'), findsOneWidget);
    expect(find.text('20. Juli – 26. Juli'), findsOneWidget);

    final bytes = await tester.runAsync(
      () => yearReviewPdf(yearReview(engine, 2026)),
    );
    expect(String.fromCharCodes(bytes!.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
    // Lets the sync debounce run out.
    await tester.pump(const Duration(seconds: 1));
  });
}
