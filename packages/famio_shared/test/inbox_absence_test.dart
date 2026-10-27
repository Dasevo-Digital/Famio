import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('inbox item keeps text, files and origin', () {
    final item = InboxItem(
      id: 'inbox-1',
      title: 'Brief vom Amt',
      text: 'Bis Freitag beantworten',
      files: const [
        FileRef(
          id: 'file-1',
          name: 'brief.pdf',
          mime: 'application/pdf',
          size: 42,
        ),
      ],
      createdAt: DateTime.utc(2026, 10, 25, 12),
      createdBy: 'member-1',
    );
    final record = SyncRecord(
      collection: Collections.inbox,
      id: item.id,
      data: item.toData(),
      updatedAt: 1,
      updatedBy: 'member-2',
    );

    final back = InboxItem.fromRecord(record);
    expect(back.title, 'Brief vom Amt');
    expect(back.text, 'Bis Freitag beantworten');
    expect(back.files.single.name, 'brief.pdf');
    expect(back.createdBy, 'member-1');
    expect(Collections.all, contains(Collections.inbox));
  });

  test('absence covers inclusive local days and selects the substitute', () {
    final absence = MemberAbsence(
      id: 'away-1',
      memberId: 'child-1',
      from: DateTime(2026, 10, 25),
      to: DateTime(2026, 10, 27),
      substituteId: 'adult-1',
      title: 'Klassenfahrt',
    );
    final record = SyncRecord(
      collection: Collections.absences,
      id: absence.id,
      data: absence.toData(),
      updatedAt: 1,
    );
    final back = MemberAbsence.fromRecord(record);

    expect(back.covers(DateTime(2026, 10, 25, 23)), isTrue);
    expect(back.covers(DateTime(2026, 10, 27, 23)), isTrue);
    expect(back.covers(DateTime(2026, 10, 28)), isFalse);
    expect(absenceFor([back], 'child-1', DateTime(2026, 10, 26)), back);
    expect(absenceFor([back], 'adult-1', DateTime(2026, 10, 26)), isNull);
    expect(Collections.adultOnly, contains(Collections.absences));
  });

  test('overlapping absences: the most precise one counts everywhere', () {
    MemberAbsence away(String id, int from, int to, [String member = 'm']) =>
        MemberAbsence(
          id: id,
          memberId: member,
          from: DateTime(2026, 11, from),
          to: DateTime(2026, 11, to),
          substituteId: 'sub-$id',
        );
    final long = away('lang', 1, 20);
    final weekend = away('wochenende', 7, 8);
    final sameStart = away('kurz', 7, 7);
    final twin = away('a-zwilling', 7, 7);
    final other = away('anders', 7, 8, 'x');
    for (final order in [
      [long, weekend, sameStart, twin, other],
      [other, twin, sameStart, weekend, long],
    ]) {
      expect(absenceFor(order, 'm', DateTime(2026, 11, 3)), long);
      expect(absenceFor(order, 'm', DateTime(2026, 11, 8)), weekend);
      expect(absenceFor(order, 'm', DateTime(2026, 11, 7)), twin);
    }
    expect(long.overlaps(weekend), isTrue);
    expect(weekend.overlaps(long), isTrue);
    expect(long.overlaps(long), isFalse);
    expect(weekend.overlaps(other), isFalse);
    expect(away('vorher', 1, 6).overlaps(weekend), isFalse);
    expect(away('angrenzend', 8, 9).overlaps(weekend), isTrue);
  });
}
