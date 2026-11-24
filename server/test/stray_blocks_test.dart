import 'dart:async';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

/// Blocks without an upload (#493): an upload cut off by a stop of the
/// server left them behind for good.
void main() {
  late FamioServerApp app;
  late FamilyMember owner;
  setUp(() {
    app = FamioServerApp.inMemory();
    owner = app.accounts.create(username: 'owner', displayName: 'Owner');
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  int blocks(String id) =>
      app.files.blobs.select('SELECT COUNT(*) AS n FROM blobs WHERE id = ?', [
            id,
          ]).first['n']
          as int;

  for (final async in [false, true]) {
    test('the clean-up removes them, but not an upload still arriving '
        '(${async ? 'in batches' : 'at once'})', () async {
      // What a stopped server left: blocks, but no entry in `files`.
      app.files.blobs.execute(
        "INSERT INTO blobs (id, kind, seq, data) VALUES ('stray', 'f', 0, x'01')",
      );
      app.files.blobs.execute(
        "INSERT INTO blobs (id, kind, seq, data) VALUES ('stray', 'f', 1, x'02')",
      );
      final kept = await app.files.save(
        owner: owner.id,
        name: 'kept',
        mime: 'text/plain',
        body: Stream.value([1, 2, 3]),
      );
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.documents,
          id: 'd',
          updatedAt: 1,
          data: {
            'title': 'Attached',
            'file': FileRef(
              id: kept.id,
              name: kept.name,
              mime: kept.mime,
              size: kept.size,
            ).toJson(),
          },
        ),
      ]);
      // An upload that has sent one block and waits for the rest.
      final rest = StreamController<List<int>>();
      final arriving = app.files.save(
        owner: owner.id,
        name: 'arriving',
        mime: 'application/octet-stream',
        body: rest.stream,
      );
      rest.add(List.filled(1024 * 1024 + 1, 7));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final inFlight = [
        for (final row in app.files.blobs.select(
          "SELECT DISTINCT id FROM blobs WHERE id NOT IN ('stray', ?)",
          [kept.id],
        ))
          row['id'] as String,
      ];
      expect(inFlight, hasLength(1));

      if (async) {
        await app.files.collectGarbageAsync();
      } else {
        app.files.collectGarbage();
      }

      expect(blocks('stray'), 0);
      expect(blocks(kept.id), greaterThan(0));
      expect(blocks(inFlight.single), greaterThan(0));
      await rest.close();
      final done = await arriving;
      expect(done.id, inFlight.single);
      expect(done.size, 1024 * 1024 + 1);
    });
  }
}
