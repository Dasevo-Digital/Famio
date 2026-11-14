import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

/// After "delete all data" the family starts over: what a device writes
/// once it has the deletion marks stays, also settings with their fixed
/// id and from a clock a little behind (#491). What it wrote before the
/// deletion goes.
void main() {
  late FamioServerApp app;
  late FamilyMember mama;
  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  SyncRecord waste(int hour, int at, {int rev = 0}) => SyncRecord(
    collection: Collections.wasteSettings,
    id: WasteSettings.recordId,
    data: {'reminderHour': hour},
    updatedAt: at,
    rev: rev,
  );

  SyncRecord? stored() =>
      app.records.get(Collections.wasteSettings, WasteSettings.recordId);

  test('settings saved right after the deletion stay', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    app.records.sync(SyncRequest(since: 0, changes: [waste(18, now)]), mama.id);
    for (final behind in [0, 1000]) {
      app.records.wipe();
      // The device fetches the marks, drops its copy and saves anew, also
      // with a clock a second behind.
      final pulled = app.records.sync(const SyncRequest(since: 0), mama.id);
      expect(stored()!.deleted, isTrue);
      final at = behind == 0
          ? DateTime.now().millisecondsSinceEpoch
          : app.records.resetAt - behind;
      final answer = app.records.sync(
        SyncRequest(since: pulled.rev, changes: [waste(19 + behind, at)]),
        mama.id,
      );
      expect(answer.rejected, isEmpty, reason: 'behind $behind ms');
      expect(stored()!.deleted, isFalse);
      expect(stored()!.data['reminderHour'], 19 + behind);
    }
  });

  test('what was written offline before the deletion goes', () {
    final before = DateTime.now().millisecondsSinceEpoch;
    final first = app.records.sync(
      SyncRequest(since: 0, changes: [waste(18, before)]),
      mama.id,
    );
    app.records.wipe();
    // A device that has not heard of the deletion yet.
    final answer = app.records.sync(
      SyncRequest(
        since: first.rev,
        changes: [waste(20, before + 1, rev: stored()!.rev)],
      ),
      mama.id,
    );
    expect(answer.rejected, isNotEmpty);
    expect(stored()!.deleted, isTrue);
  });

  SyncRecord note(String id, int at) => SyncRecord(
    collection: Collections.notes,
    id: id,
    data: {'title': 'offline $id'},
    updatedAt: at,
  );

  int live(String prefix) => [
    for (final r in app.records.all(Collections.notes))
      if (r.id.startsWith(prefix) && !r.deleted) r,
  ].length;

  test('offline notes from before the deletion stay gone in later batches', () {
    final papa = app.accounts.create(username: 'papa', displayName: 'Papa');
    final before = DateTime.now().millisecondsSinceEpoch - 60000;
    app.records.sync(
      SyncRequest(since: 0, changes: [note('family', before)]),
      mama.id,
    );
    var since = app.records.sync(const SyncRequest(since: 0), papa.id).rev;
    final dirty = [for (var i = 0; i < 600; i++) note('papa-$i', before + i)];
    app.records.wipe();
    // As the apps send them: 500 per request, each with the rev of the
    // answer before, so the second batch comes after the marks.
    while (dirty.isNotEmpty) {
      final batch = dirty.take(500).toList();
      final answer = app.records.sync(
        SyncRequest(since: since, changes: batch, resettable: true),
        papa.id,
      );
      expect(answer.rejected, hasLength(batch.length));
      dirty.removeRange(0, batch.length);
      since = answer.rev;
    }
    expect(live('papa-'), 0);
  });

  test('a device ahead of the server has not seen the deletion', () {
    final before = DateTime.now().millisecondsSinceEpoch - 60000;
    app.records.sync(
      SyncRequest(since: 0, changes: [note('family', before)]),
      mama.id,
    );
    app.records.wipe();
    final answer = app.records.sync(
      SyncRequest(
        since: app.records.currentRev + 5000,
        changes: [note('ahead', before)],
        resettable: true,
        scope: 'another-instance',
      ),
      mama.id,
    );
    expect(answer.rejected, hasLength(1));
    expect(live('ahead'), 0);
  });
}
