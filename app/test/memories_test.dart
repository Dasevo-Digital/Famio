import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/memories.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _members = '[{"id":"m1","username":"mama","displayName":"Mama"}]';

SyncEngine _engine() => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: 'm1',
);

void _photo(SyncEngine e, String id, DateTime at) => e.put(
  Collections.chatMessages,
  id,
  ChatMessage(
    id: id,
    chatId: 'family',
    authorId: 'm1',
    sentAt: at,
    attachment: FileRef(
      id: 'f$id',
      name: '$id.jpg',
      mime: 'image/jpeg',
      size: 1,
    ),
  ).toData(),
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('milestones, trips and photos of this date in earlier years', () {
    final today = DateTime(2026, 10, 20, 9);
    final e = _engine()
      ..saveChild(Child(id: 'k', name: 'Mia', birthDate: DateTime(2023, 1, 5)))
      ..saveChildEntry(
        ChildEntry(
          id: 'm',
          childId: 'k',
          kind: ChildEntryKind.milestone,
          date: DateTime(2025, 10, 20),
          title: 'Erste Schritte',
        ),
      )
      ..saveChildEntry(
        ChildEntry(
          id: 'other',
          childId: 'k',
          kind: ChildEntryKind.milestone,
          date: DateTime(2025, 10, 21),
          title: 'Anderer Tag',
        ),
      )
      ..saveEvent(
        CalendarEvent(
          id: 'ostsee',
          title: 'Ostsee',
          start: DateTime(2024, 10, 18),
          end: DateTime(2024, 10, 25),
          allDay: true,
        ),
      )
      ..saveEvent(
        CalendarEvent(
          id: 'arzt',
          title: 'Zahnarzt',
          start: DateTime(2024, 10, 20, 9),
          end: DateTime(2024, 10, 20, 10),
        ),
      );
    _photo(e, 'a', DateTime(2025, 10, 20, 18));
    _photo(e, 'b', DateTime(2023, 10, 20, 12));
    _photo(e, 'c', DateTime(2026, 10, 20, 8));
    final m = memoriesOn(e, today);
    expect(
      [for (final l in m.lines) (l.yearsAgo, l.text)],
      [(1, 'Mia: Erste Schritte'), (2, 'Ostsee')],
    );
    // Newest first; today's own photo is no memory.
    expect(m.photos.map((f) => f.name), ['a.jpg', 'b.jpg']);
    expect(m.oneYearAgo, isFalse);
  });

  test('29 February shows on the 28th in a common year', () {
    final e = _engine();
    _photo(e, 'leap', DateTime(2024, 2, 29, 12));
    expect(memoriesOn(e, DateTime(2025, 2, 28)).photos, hasLength(1));
    expect(memoriesOn(e, DateTime(2025, 3, 1)).photos, isEmpty);
    expect(memoriesOn(e, DateTime(2028, 2, 28)).photos, isEmpty);
    expect(memoriesOn(e, DateTime(2028, 2, 29)).photos, hasLength(1));
    expect(memoriesOn(e, DateTime(2025, 2, 28)).oneYearAgo, isTrue);
  });
}
