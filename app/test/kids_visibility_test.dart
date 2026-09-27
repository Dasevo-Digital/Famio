import 'package:famio/src/data/family_data.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Child development, check-ups and vaccinations are health data: the
/// records carry the guardians as audience, which the server enforces.
void main() {
  SyncEngine engineFor(String memberId, [LocalStore? store]) => SyncEngine(
    store: store ?? LocalStore.open(':memory:'),
    api: FamioApiClient('localhost:1'),
    memberId: memberId,
  );

  List<String>? audienceOf(SyncEngine e, String collection, String id) =>
      e.record(collection, id)?.visibleTo;

  Child mia(List<String> guardians) => Child(
    id: 'c1',
    name: 'Mia',
    birthDate: DateTime(2025, 3, 1),
    guardianIds: guardians,
  );

  final vaccination = ChildEntry(
    id: 'e1',
    childId: 'c1',
    kind: ChildEntryKind.vaccination,
    date: DateTime(2025, 5, 1),
    refId: 'six_1',
  );

  test('child and entries are visible to guardians only', () {
    final engine = engineFor('mama');
    engine.saveChild(mia(['mama', 'papa']));
    engine.saveChildEntry(vaccination);
    expect(audienceOf(engine, Collections.children, 'c1'), ['mama', 'papa']);
    expect(audienceOf(engine, Collections.childEntries, 'e1'), [
      'mama',
      'papa',
    ]);
  });

  test('changing guardians moves all entries along', () {
    final engine = engineFor('mama');
    engine.saveChild(mia(['mama', 'papa']));
    engine.saveChildEntry(vaccination);
    engine.saveChild(mia(['mama']));
    expect(audienceOf(engine, Collections.childEntries, 'e1'), ['mama']);
  });

  test('without guardians the whole family sees the child', () {
    final engine = engineFor('mama');
    engine.saveChild(mia([]));
    engine.saveChildEntry(vaccination);
    expect(audienceOf(engine, Collections.children, 'c1'), isNull);
    expect(audienceOf(engine, Collections.childEntries, 'e1'), isNull);
  });

  test('older records are upgraded by a guardian, not by others', () {
    // Records as written by version 0.4: no audience.
    SyncEngine legacy(String member) {
      final e = engineFor(member);
      e.put(Collections.children, 'c1', mia(['mama']).toData());
      e.put(Collections.childEntries, 'e1', vaccination.toData());
      return e;
    }

    final lena = legacy('lena')..applyChildVisibility();
    expect(audienceOf(lena, Collections.children, 'c1'), isNull);

    final mama = legacy('mama')..applyChildVisibility();
    expect(audienceOf(mama, Collections.children, 'c1'), ['mama']);
    expect(audienceOf(mama, Collections.childEntries, 'e1'), ['mama']);
  });
}
