import 'package:famio/src/data/birthdays.dart';
import 'package:famio/src/data/memories.dart';
import 'package:famio/src/screens/kiosk_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

SyncEngine _engine() => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', '[]'),
  api: FamioApiClient('localhost:1'),
  memberId: 'm1',
);

/// As the server writes them (PhotoVaultLink).
void _server(
  SyncEngine e,
  String collection,
  String id,
  Map<String, Object?> data,
) => e.store.put(
  SyncRecord(collection: collection, id: id, data: data, updatedAt: 1),
  dirty: false,
);

Map<String, Object?> _photo(
  String id, {
  String? memoryOf,
  bool album = false,
}) => {
  'source': 'photovault',
  'takenAt': '2025-10-20T10:00:00Z',
  'memoryOf': memoryOf,
  'yearsAgo': memoryOf == null ? null : 1,
  'album': album,
  'file': FileRef(
    id: '$id.jpg',
    name: '$id.jpg',
    mime: 'image/jpeg',
    size: 0,
  ).toJson(),
};

void main() {
  test('birthdays from the family tree are birthdays like any other', () {
    final e = _engine();
    _server(e, Collections.externalBirthdays, 'pv-p1', {
      'name': 'Erna Müller',
      'birthday': '1950-03-14',
      'source': 'photovault',
    });
    final erna = familyBirthdays(e).single;
    expect(
      (erna.of, erna.name, erna.birthday),
      (BirthdayOf.photoVault, 'Erna Müller', const Birthday(3, 14, 1950)),
    );
    expect(erna.headline(DateTime(2027, 3, 14)), 'Erna Müller wird 77');
    expect(birthdayEvents(e).single.title, '🎂 Erna Müller');
  });

  test('PhotoVault photos in the memories of their day and on the wall', () {
    final e = _engine();
    final today = DateTime(2026, 10, 20, 9);
    _server(
      e,
      Collections.externalPhotos,
      'pv-a1',
      _photo('pv-a1', memoryOf: '2026-10-20', album: true),
    );
    _server(
      e,
      Collections.externalPhotos,
      'pv-a2',
      _photo('pv-a2', album: true),
    );
    _server(
      e,
      Collections.externalPhotos,
      'pv-a3',
      _photo('pv-a3', memoryOf: '2026-10-19'),
    );
    final memories = memoriesOn(e, today);
    expect(memories.photos.map((f) => f.id), ['pv-a1.jpg']);
    expect(memories.isEmpty, isFalse);
    expect(
      familyPhotos(e).map((f) => f.id),
      unorderedEquals(['pv-a1.jpg', 'pv-a2.jpg']),
    );
  });
}
