import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

/// A revocation shares the rev of its record and must not be lost where a
/// page of the sync ends.
void main() {
  for (final filler in [497, 498, 499, 500]) {
    test(
      'a revocation reaches the device at the end of a page ($filler)',
      () async {
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
        final child = app.accounts.create(
          username: 'kind',
          displayName: 'Kind',
          role: MemberRole.child,
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        SyncRecord event({required bool confidential, required int at}) =>
            SyncRecord(
              collection: Collections.events,
              id: 'ev1',
              data: {
                'title': 'Therapie',
                'start': DateTime.utc(2026, 12, 1, 10).toIso8601String(),
                'end': DateTime.utc(2026, 12, 1, 11).toIso8601String(),
                'memberIds': [adult.id],
                'confidential': confidential,
              },
              updatedAt: at,
            );
        app.records.sync(
          SyncRequest(since: 0, changes: [event(confidential: false, at: now)]),
          adult.id,
        );
        final first = app.records.sync(const SyncRequest(since: 0), child.id);
        expect(first.changes.any((r) => r.id == 'ev1' && !r.deleted), isTrue);
        app.records.sync(
          SyncRequest(
            since: 0,
            changes: [
              for (var i = 0; i < filler; i++)
                SyncRecord(
                  collection: Collections.notes,
                  id: 'note$i',
                  data: {'title': 'n$i', 'text': ''},
                  updatedAt: now + 1,
                ),
            ],
          ),
          adult.id,
        );
        app.records.sync(
          SyncRequest(
            since: 0,
            changes: [event(confidential: true, at: now + 2)],
          ),
          adult.id,
        );

        var since = first.rev;
        var revoked = false;
        var notes = 0;
        for (var pages = 0; pages < 5; pages++) {
          final page = app.records.sync(SyncRequest(since: since), child.id);
          revoked |= page.changes.any((r) => r.id == 'ev1' && r.deleted);
          notes += page.changes
              .where((r) => r.collection == Collections.notes)
              .length;
          since = page.rev;
          if (!page.hasMore) break;
        }
        expect(revoked, isTrue);
        expect(notes, filler);
      },
    );
  }
}
