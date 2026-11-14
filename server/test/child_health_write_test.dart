import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

/// Children log and tick off health data only for a child or plan they are
/// named for, in their own name, and leave what others entered as it is
/// (#505).
void main() {
  late FamioServerApp app;
  late FamilyMember mama, papa, kid;
  var clock = DateTime.now().millisecondsSinceEpoch - 100000;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    papa = app.accounts.create(username: 'papa', displayName: 'Papa');
    kid = app.accounts.create(
      username: 'kid',
      displayName: 'Kid',
      role: MemberRole.child,
    );
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  SyncRecord record(
    String collection,
    String id,
    Map<String, Object?> data, {
    List<String>? audience,
    bool deleted = false,
    int rev = 0,
  }) => SyncRecord(
    collection: collection,
    id: id,
    data: {...data, SyncRecord.visibilityKey: ?audience},
    updatedAt: clock += 1000,
    deleted: deleted,
    rev: rev,
  );

  SyncResponse sync(FamilyMember who, [List<SyncRecord> changes = const []]) =>
      app.records.sync(SyncRequest(since: 0, changes: changes), who.id);

  void setUpFamily() => sync(mama, [
    // Mia is kept to the parents; Ben (the kid's own record) names the kid.
    record(
      Collections.children,
      'mia',
      {'name': 'Mia', 'birthDate': '2025-01-01'},
      audience: [mama.id, papa.id],
    ),
    record(
      Collections.children,
      'ben',
      {'name': 'Ben', 'birthDate': '2012-01-01'},
      audience: [mama.id, papa.id, kid.id],
    ),
    record(
      Collections.medications,
      'mama-med',
      {
        'name': 'Plan Mama',
        'start': '2026-01-01',
        'careIds': [mama.id],
      },
      audience: [mama.id],
    ),
    record(
      Collections.medications,
      'ben-med',
      {
        'name': 'Plan Ben',
        'start': '2026-01-01',
        'careIds': [kid.id, mama.id],
      },
      audience: [kid.id, mama.id],
    ),
    for (final dose in ['mmrv_1', 'mmrv_2'])
      record(
        Collections.childEntries,
        'v-$dose',
        {
          'childId': 'ben',
          'kind': 'vaccination',
          'date': '2014-01-01',
          'refId': dose,
        },
        audience: [mama.id, papa.id, kid.id],
      ),
  ]);

  test('nothing for a child or plan the kid is not named for', () {
    setUpFamily();
    final answer = sync(kid, [
      record(
        Collections.childEntries,
        'fake-vacc',
        {'childId': 'mia', 'kind': 'vaccination', 'refId': 'mmrv_1'},
        audience: [kid.id, mama.id, papa.id],
      ),
      record(
        Collections.childLogs,
        'fake-fever',
        {'childId': 'mia', 'kind': 'temperature', 'temperatureC': 41.5},
        audience: [kid.id, mama.id],
      ),
      record(
        Collections.medicationIntakes,
        'fake-intake',
        {'medicationId': 'mama-med', 'byId': mama.id},
        audience: [kid.id, mama.id],
      ),
      record(
        Collections.childLogs,
        'no-child',
        {'childId': 'nobody', 'kind': 'note'},
        audience: [kid.id, mama.id],
      ),
    ]);
    expect(
      {for (final r in answer.rejected) r.id},
      {'fake-vacc', 'fake-fever', 'fake-intake', 'no-child'},
    );
    for (final (c, id) in [
      (Collections.childEntries, 'fake-vacc'),
      (Collections.childLogs, 'fake-fever'),
      (Collections.medicationIntakes, 'fake-intake'),
    ]) {
      expect(app.records.get(c, id), isNull, reason: id);
    }
  });

  test('what others entered stays', () {
    setUpFamily();
    final revs = {for (final r in sync(kid).changes) r.id: r.rev};
    final answer = sync(kid, [
      record(
        Collections.childEntries,
        'v-mmrv_1',
        const {},
        deleted: true,
        rev: revs['v-mmrv_1']!,
      ),
      record(
        Collections.childEntries,
        'v-mmrv_2',
        {'childId': 'ben', 'kind': 'vaccination', 'refId': 'tdap_1'},
        audience: [mama.id, papa.id, kid.id],
        rev: revs['v-mmrv_2']!,
      ),
    ]);
    expect({for (final r in answer.rejected) r.id}, {'v-mmrv_1', 'v-mmrv_2'});
    final first = app.records.get(Collections.childEntries, 'v-mmrv_1')!;
    expect(first.deleted, isFalse);
    expect(
      app.records.get(Collections.childEntries, 'v-mmrv_2')!.data['refId'],
      'mmrv_2',
    );
  });

  test('the kid logs and ticks off for itself, in its own name', () {
    setUpFamily();
    final answer = sync(kid, [
      record(
        Collections.childLogs,
        'ben-fever',
        {'childId': 'ben', 'kind': 'temperature', 'temperatureC': 38.2},
        // An older app's audience: the child's goes instead.
        audience: [kid.id, mama.id],
      ),
      record(
        Collections.medicationIntakes,
        'ben-dose',
        {'medicationId': 'ben-med', 'byId': mama.id},
        audience: [kid.id, mama.id],
      ),
    ]);
    expect(answer.rejected, isEmpty);
    final log = app.records.get(Collections.childLogs, 'ben-fever')!;
    expect(log.visibleTo, [mama.id, papa.id, kid.id]);
    expect(
      app.records.get(Collections.medicationIntakes, 'ben-dose')!.data['byId'],
      kid.id,
    );
    // What it entered itself it may take back.
    final removed = sync(kid, [
      record(
        Collections.childLogs,
        'ben-fever',
        const {},
        deleted: true,
        rev: log.rev,
      ),
    ]);
    expect(removed.rejected, isEmpty);
    expect(
      app.records.get(Collections.childLogs, 'ben-fever')!.deleted,
      isTrue,
    );
  });
}
