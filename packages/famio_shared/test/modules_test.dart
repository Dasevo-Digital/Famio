import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  const a = '3f2b8c1e-1111-4a2b-9c3d-000000000001';
  const b = '0a9e7d6c-2222-4b3c-8d4e-000000000002';

  test('direct chat ids are symmetric and fit the id limit', () {
    expect(ChatIds.direct(a, b), ChatIds.direct(b, a));
    expect(ChatIds.direct(a, b).length, lessThanOrEqualTo(64));
    expect(ChatIds.isDirect(ChatIds.direct(a, b)), isTrue);
    expect(ChatIds.isDirect(ChatIds.family), isFalse);
    expect(
      ChatRead.idFor(ChatIds.direct(a, b), a).length,
      lessThanOrEqualTo(64),
    );
    expect(
      ChatRead.idFor(ChatIds.family, a),
      isNot(ChatRead.idFor(ChatIds.family, b)),
    );
  });

  test('messages keep their audience and attachment', () {
    final m = ChatMessage(
      id: 'm1',
      chatId: ChatIds.direct(a, b),
      authorId: a,
      sentAt: DateTime.utc(2026, 9, 26, 12),
      text: 'Hallo',
      attachment: const FileRef(
        id: 'f',
        name: 'bild.jpg',
        mime: 'image/jpeg',
        size: 10,
      ),
      visibleTo: const [a, b],
    );
    final r = SyncRecord(
      collection: Collections.chatMessages,
      id: m.id,
      data: m.toData(),
      updatedAt: 1,
    );
    expect(r.visibleTo, [a, b]);
    final back = ChatMessage.fromRecord(SyncRecord.fromJson(r.toJson()));
    expect(back.attachment!.isImage, isTrue);
    expect(back.sentAt, DateTime.utc(2026, 9, 26, 12).toLocal());
  });

  test('child age handles month ends', () {
    final child = Child(
      id: 'c',
      name: 'Lena',
      birthDate: DateTime(2025, 1, 31),
    );
    expect(child.ageDate(1), DateTime(2025, 2, 28));
    expect(child.ageDate(12), DateTime(2026, 1, 31));
    expect(child.ageInMonths(DateTime(2025, 2, 27)), 0);
    expect(child.ageInMonths(DateTime(2026, 1, 31)), 12);
    expect(child.ageInMonths(DateTime(2024, 12, 1)), 0);
  });

  test('catalogs are consistent', () {
    for (final list in [
      milestones.map((m) => m.id),
      checkups.map((c) => c.id),
      vaccinations.map((v) => v.id),
    ]) {
      expect(list.toSet().length, list.length, reason: 'unique ids');
    }
    for (final m in milestones) {
      expect(m.fromMonth, lessThan(m.toMonth), reason: m.id);
    }
    for (final c in checkups) {
      expect(
        c.fromDay <= c.toDay && c.toDay <= c.toleranceTo,
        isTrue,
        reason: c.id,
      );
    }
    // Check-ups follow each other.
    for (var i = 1; i < checkups.length; i++) {
      expect(checkups[i].fromDay, greaterThan(checkups[i - 1].fromDay));
    }
    expect(checkupById('U7a')!.window, '34.–36. Lebensmonat');
    expect(milestoneById('walk')!.toMonth, 18);
  });

  test('documents roundtrip with visibility and expiry', () {
    final d = FamilyDocument(
      id: 'd',
      title: 'Reisepass Lena',
      category: DocumentCategory.identity,
      file: const FileRef(
        id: 'f',
        name: 'pass.pdf',
        mime: 'application/pdf',
        size: 1,
      ),
      expiresAt: DateTime(2031, 5, 1),
      visibleTo: const [a],
    );
    final back = FamilyDocument.fromRecord(
      SyncRecord(
        collection: Collections.documents,
        id: 'd',
        data: d.toData(),
        updatedAt: 1,
      ),
    );
    expect(back.expiresAt, DateTime(2031, 5, 1));
    expect(back.visibleTo, [a]);
    expect(back.category, DocumentCategory.identity);
  });
}
