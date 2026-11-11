import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

/// A revocation from the time a member was a guest stays after they become
/// an adult. Their full sync gets the revocation and the (now visible)
/// record at the same rev; a page never ends between the two (#399).
void main() {
  for (final filler in [494, 495, 496, 497, 498, 499, 500]) {
    test('upgraded guest gets the task in a full sync ($filler)', () async {
      final app = FamioServerApp.inMemory();
      addTearDown(() async {
        await app.close();
        Directory(app.dataDir).deleteSync(recursive: true);
      });
      final adult = app.accounts.create(
        username: 'mama',
        displayName: 'Mama',
        isAdmin: true,
      );
      final guest = app.accounts.create(
        username: 'oma',
        displayName: 'Oma',
        role: MemberRole.guest,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      app.records.sync(
        SyncRequest(
          since: 0,
          changes: [
            for (var i = 0; i < filler; i++)
              SyncRecord(
                collection: Collections.notes,
                id: 'note$i',
                data: {'title': 'n$i', 'text': ''},
                updatedAt: now,
              ),
          ],
        ),
        adult.id,
      );
      SyncRecord task(List<String> assignees, int at) => SyncRecord(
        collection: Collections.tasks,
        id: 't1',
        data: {
          'title': 'Einkaufen',
          'assigneeIds': assignees,
          if (assignees.isNotEmpty) 'assigneeId': assignees.first,
        },
        updatedAt: at,
      );
      app.records.sync(
        SyncRequest(
          since: 0,
          changes: [
            task([guest.id], now + 1),
          ],
        ),
        adult.id,
      );
      // Guest sees it, then it is taken away: a revocation at its rev.
      final seen = app.records.sync(const SyncRequest(since: 0), guest.id);
      var s = seen;
      var guestHad = false;
      var sinceG = 0;
      while (true) {
        guestHad |= s.changes.any((r) => r.id == 't1' && !r.deleted);
        sinceG = s.rev;
        if (!s.hasMore) break;
        s = app.records.sync(SyncRequest(since: sinceG), guest.id);
      }
      expect(guestHad, isTrue);
      app.records.sync(
        SyncRequest(
          since: 0,
          changes: [
            task([adult.id], now + 2),
          ],
        ),
        adult.id,
      );

      // The guest becomes an adult: their next sync is a full one.
      app.accounts.update(guest.id, role: MemberRole.adult);

      var since = 0;
      var live = false;
      for (var pages = 0; pages < 10; pages++) {
        final page = app.records.sync(SyncRequest(since: since), guest.id);
        for (final r in page.changes.where((r) => r.id == 't1')) {
          live = !r.deleted;
        }
        since = page.rev;
        if (!page.hasMore) break;
      }
      expect(live, isTrue, reason: 'the task is visible to the new adult');
    });
  }
}
