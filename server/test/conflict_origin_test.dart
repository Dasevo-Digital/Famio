import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

/// Which unseen changes make a conflict (#493): a rewrite by the server is
/// none, another device of the same member is one.
void main() {
  late FamioServerApp app;
  late FamilyMember mama;
  late FamilyMember papa;
  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    papa = app.accounts.create(username: 'papa', displayName: 'Papa');
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  String day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  void write(String userId, SyncRecord r, {String? session}) => app.records
      .sync(SyncRequest(since: 0, changes: [r]), userId, session: session);

  // SP4 after 2.0.53: an absence gives the substitute the task, which
  // raises its revision. Mama then fixed a typo from the version she had,
  // and Papa's version (unchanged but for the substitute) was kept as a
  // conflict.
  test('a rewrite by the server is no change anybody missed', () {
    final oma = app.accounts.create(username: 'oma', displayName: 'Oma');
    final kid = app.accounts.create(
      username: 'kind',
      displayName: 'Kind',
      role: MemberRole.child,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    write(
      papa.id,
      SyncRecord(
        collection: Collections.tasks,
        id: 't',
        data: {
          'title': 'Turnbeutel packen',
          'assigneeId': kid.id,
          'assigneeIds': [kid.id],
          'visibleTo': [papa.id, mama.id, kid.id],
        },
        updatedAt: now,
      ),
    );
    final seen = app.records.get(Collections.tasks, 't')!;
    final today = DateTime.now();
    write(
      mama.id,
      SyncRecord(
        collection: Collections.absences,
        id: 'a',
        data: {
          'memberId': kid.id,
          'from': day(today),
          'to': day(today),
          'substituteId': oma.id,
        },
        updatedAt: now + 1,
      ),
    );
    final rewritten = app.records.get(Collections.tasks, 't')!;
    expect(rewritten.rev, greaterThan(seen.rev));
    expect(rewritten.visibleTo, contains(oma.id));

    write(
      mama.id,
      SyncRecord(
        collection: Collections.tasks,
        id: 't',
        data: {...seen.data, 'title': 'Turnbeutel packen!'},
        updatedAt: now + 5000,
        rev: seen.rev,
      ),
    );
    expect(app.records.all(Collections.conflicts), isEmpty);
    final task = app.records.get(Collections.tasks, 't')!;
    expect(task.data['title'], 'Turnbeutel packen!');
    // The substitute keeps the task while the absence lasts.
    expect(task.visibleTo, contains(oma.id));

    // A real change Mama had not seen still counts.
    write(
      papa.id,
      SyncRecord(
        collection: Collections.tasks,
        id: 't',
        data: {...task.data, 'title': 'Turnbeutel und Trinkflasche'},
        updatedAt: now + 6000,
        rev: task.rev,
      ),
    );
    write(
      mama.id,
      SyncRecord(
        collection: Collections.tasks,
        id: 't',
        data: {...task.data, 'title': 'Turnbeutel packen!!'},
        updatedAt: now + 7000,
        rev: task.rev,
      ),
    );
    final conflicts = app.records.all(Collections.conflicts).toList();
    expect(conflicts, hasLength(1));
    expect(
      SyncConflict.fromRecord(conflicts.single).lost['title'],
      'Turnbeutel und Trinkflasche',
    );
  });

  SyncRecord note(String text, int at, {int rev = 0}) => SyncRecord(
    collection: Collections.notes,
    id: 'n',
    data: {'title': 'Einkauf', 'text': text},
    updatedAt: at,
    rev: rev,
  );

  // S5 after 2.0.53: phone and laptop of the same member, both offline.
  test('another device of the same member makes a conflict', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    write(papa.id, note('v0', now), session: 'phone');
    final base = app.records.get(Collections.notes, 'n')!.rev;
    write(papa.id, note('laptop', now + 20, rev: base), session: 'laptop');
    // The phone's edit is older and loses.
    write(papa.id, note('phone', now + 10, rev: base), session: 'phone');

    expect(app.records.get(Collections.notes, 'n')!.data['text'], 'laptop');
    final conflicts = app.records.all(Collections.conflicts).toList();
    expect(conflicts, hasLength(1));
    final conflict = SyncConflict.fromRecord(conflicts.single);
    expect(conflict.lost['text'], 'phone');
    expect(conflict.lostBy, papa.id);
    expect(conflict.keptBy, papa.id);
  });

  test('the newer edit of another device keeps the older one too', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    write(papa.id, note('v0', now), session: 'phone');
    final base = app.records.get(Collections.notes, 'n')!.rev;
    write(papa.id, note('phone', now + 10, rev: base), session: 'phone');
    // The laptop had not seen it and wins with its later edit.
    write(papa.id, note('laptop', now + 20, rev: base), session: 'laptop');

    final conflicts = app.records.all(Collections.conflicts).toList();
    expect(conflicts, hasLength(1));
    expect(SyncConflict.fromRecord(conflicts.single).lost['text'], 'phone');
  });

  // The answer to a push got lost, so the device's revision is old; its
  // next edit is no conflict with its own previous one.
  test('the same device building on its own unconfirmed edit', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    write(papa.id, note('v0', now), session: 'phone');
    final base = app.records.get(Collections.notes, 'n')!.rev;
    write(papa.id, note('v1', now + 10, rev: base), session: 'phone');
    write(papa.id, note('v2', now + 20, rev: base), session: 'phone');
    expect(app.records.all(Collections.conflicts), isEmpty);
    expect(app.records.get(Collections.notes, 'n')!.data['text'], 'v2');
  });

  // Without a known session (older rows, writes without a token) the same
  // member is the same device, as before.
  test('without sessions the same member makes no conflict', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    write(papa.id, note('v0', now));
    final base = app.records.get(Collections.notes, 'n')!.rev;
    write(papa.id, note('laptop', now + 20, rev: base));
    write(papa.id, note('phone', now + 10, rev: base), session: 'phone');
    expect(app.records.all(Collections.conflicts), isEmpty);
  });
}
