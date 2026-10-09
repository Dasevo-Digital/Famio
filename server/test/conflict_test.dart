import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  late RecordStore records;
  late String mama, papa;

  setUp(() {
    final app = FamioServerApp.inMemory();
    mama = app.accounts
        .create(username: 'mama', displayName: 'Mama', passwordHash: 'x')
        .id;
    papa = app.accounts
        .create(username: 'papa', displayName: 'Papa', passwordHash: 'x')
        .id;
    records = app.records;
  });

  SyncRecord task(String title, {required int at, int base = 0}) => SyncRecord(
    collection: Collections.tasks,
    id: 't1',
    data: Task(id: 't1', title: title).toData(),
    updatedAt: at,
    rev: base,
  );

  /// Pushes [r] for [who] and returns the server's revision of the record.
  int push(String who, SyncRecord r) {
    records.sync(SyncRequest(since: 0, changes: [r]), who);
    return records.get(r.collection, r.id)!.rev;
  }

  List<SyncConflict> conflicts([String? who]) => [
    for (final r in records.all(Collections.conflicts, visibleToMember: who))
      SyncConflict.fromRecord(r),
  ];

  test('the offline change wins: the other version is kept', () {
    final r1 = push(mama, task('Einkaufen', at: 1));
    // Mama changes it; Papa, offline, still has r1.
    push(mama, task('Einkaufen gehen', at: 2, base: r1));
    push(papa, task('Einkaufen (Aldi)', at: 3, base: r1));
    expect(
      records.get(Collections.tasks, 't1')!.data['title'],
      'Einkaufen (Aldi)',
    );
    final c = conflicts().single;
    expect(
      (c.collection, c.recordId, c.lostBy, c.keptBy),
      (Collections.tasks, 't1', mama, papa),
    );
    expect(c.lost['title'], 'Einkaufen gehen');
    expect(c.id.length, lessThanOrEqualTo(64));
    // Both of them see it.
    expect(conflicts(mama), hasLength(1));
    expect(conflicts(papa), hasLength(1));
  });

  test('the offline change loses: it is kept instead of vanishing', () {
    final r1 = push(mama, task('Einkaufen', at: 1));
    push(mama, task('Einkaufen gehen', at: 5, base: r1));
    final answer = records.sync(
      SyncRequest(
        since: 0,
        changes: [task('Einkaufen (Aldi)', at: 3, base: r1)],
      ),
      papa,
    );
    expect(answer.rejected.single.data['title'], 'Einkaufen gehen');
    final c = conflicts().single;
    expect(
      (c.lostBy, c.keptBy, c.lost['title']),
      (papa, mama, 'Einkaufen (Aldi)'),
    );
  });

  test('a deletion against a change is a conflict too', () {
    final r1 = push(mama, task('Einkaufen', at: 1));
    push(mama, task('Einkaufen gehen', at: 2, base: r1));
    push(
      papa,
      SyncRecord(
        collection: Collections.tasks,
        id: 't1',
        data: const {},
        deleted: true,
        updatedAt: 3,
        rev: r1,
      ),
    );
    final c = conflicts().single;
    expect(
      (c.lostBy, c.lost['title'], c.lostDeleted),
      (mama, 'Einkaufen gehen', false),
    );
  });

  test('no conflict when nothing was missed', () {
    final r1 = push(mama, task('Einkaufen', at: 1));
    // Papa saw Mama's version.
    final r2 = push(papa, task('Einkaufen gehen', at: 2, base: r1));
    // Mama edits twice in a row on one device, the second time before the
    // answer to the first arrived (her base is still r2) …
    push(mama, task('Einkaufen gehen!', at: 3, base: r2));
    push(mama, task('Einkaufen gehen!!', at: 4, base: r2));
    // … the same content from both …
    final r3 = records.get(Collections.tasks, 't1')!.rev;
    push(papa, task('Neu', at: 5, base: r3));
    push(mama, task('Neu', at: 6, base: r3));
    expect(conflicts(), isEmpty);
    // Ticked-off shopping items and read marks are no conflicts.
    final i1 = push(
      mama,
      const SyncRecord(
        collection: Collections.shoppingItems,
        id: 'i1',
        data: {'name': 'Milch'},
        updatedAt: 1,
      ),
    );
    push(
      mama,
      SyncRecord(
        collection: Collections.shoppingItems,
        id: 'i1',
        data: const {'name': 'Milch', 'checked': true},
        updatedAt: 2,
        rev: i1,
      ),
    );
    push(
      papa,
      SyncRecord(
        collection: Collections.shoppingItems,
        id: 'i1',
        data: const {'name': 'Milch', 'checked': false},
        updatedAt: 3,
        rev: i1,
      ),
    );
    expect(conflicts(), isEmpty);
  });

  test('the apps may only remove a conflict; undecided ones expire', () {
    final r1 = push(mama, task('Einkaufen', at: 1));
    push(mama, task('Einkaufen gehen', at: 2, base: r1));
    push(papa, task('Einkaufen (Aldi)', at: 3, base: r1));
    final stored = records.all(Collections.conflicts).single;
    // Changing it is undone.
    final answer = records.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.conflicts,
            id: stored.id,
            data: const {'collection': 'tasks'},
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            rev: stored.rev,
          ),
        ],
      ),
      papa,
    );
    expect(answer.rejected.single.id, stored.id);
    expect(conflicts(), hasLength(1));

    expect(
      records.expireConflicts(
        now: DateTime.now().add(const Duration(days: 30)),
      ),
      0,
    );
    // Decided: removed for both.
    push(
      papa,
      SyncRecord(
        collection: Collections.conflicts,
        id: stored.id,
        data: const {},
        deleted: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        rev: stored.rev,
      ),
    );
    expect(conflicts(), isEmpty);

    push(mama, task('Einkaufen jetzt', at: 10, base: 0));
    expect(conflicts(), hasLength(1));
    expect(
      records.expireConflicts(
        now: DateTime.now().add(const Duration(days: 61)),
      ),
      1,
    );
    expect(conflicts(), isEmpty);
  });
}
