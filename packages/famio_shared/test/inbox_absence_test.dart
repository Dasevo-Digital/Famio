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
}
