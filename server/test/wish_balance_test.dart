import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Open wishes keep the points they ask for: a child cannot wish for more
/// than is left of its points after the wishes still waiting (#377).
void main() {
  late FamioServerApp app;
  late FamilyMember mama, kid;
  late Map<String, String> tokens;
  var clock = DateTime.now().millisecondsSinceEpoch - 100000;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    kid = app.accounts.create(
      username: 'kid',
      displayName: 'Kid',
      role: MemberRole.child,
    );
    tokens = {
      for (final m in [mama, kid]) m.id: app.accounts.createSession(m.id),
    };
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<SyncResponse> sync(
    FamilyMember who, {
    List<SyncRecord> changes = const [],
  }) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer ${tokens[who.id]}',
          'content-type': 'application/json',
        },
        body: jsonEncode(SyncRequest(since: 0, changes: changes).toJson()),
      ),
    );
    expect(r.statusCode, 200);
    return SyncResponse.fromJson(
      (jsonDecode(await r.readAsString()) as Map).cast(),
    );
  }

  SyncRecord entry(
    String id,
    int points, {
    PointKind kind = PointKind.reward,
    PointStatus status = PointStatus.pending,
    String title = '🍦 Eis',
  }) => SyncRecord(
    collection: Collections.pointEntries,
    id: id,
    data: PointEntry(
      id: id,
      memberId: kid.id,
      points: points,
      title: title,
      kind: kind,
      at: DateTime.fromMillisecondsSinceEpoch(clock),
      status: status,
    ).toData(),
    updatedAt: clock += 1000,
    rev: app.records.get(Collections.pointEntries, id)?.rev ?? 0,
  );

  /// Points Mama booked for the child.
  Future<void> earn(int points) => sync(
    mama,
    changes: [
      entry(
        'bonus-${clock + 1000}',
        points,
        kind: PointKind.bonus,
        status: PointStatus.approved,
      ),
    ],
  );

  PointEntry? stored(String id) {
    final r = app.records.get(Collections.pointEntries, id);
    return r == null || r.deleted ? null : PointEntry.fromRecord(r);
  }

  Future<void> decide(String id, PointStatus status) => sync(
    mama,
    changes: [
      SyncRecord(
        collection: Collections.pointEntries,
        id: id,
        data: stored(id)!.decide(status, mama.id).toData(),
        updatedAt: clock += 1000,
        rev: app.records.get(Collections.pointEntries, id)!.rev,
      ),
    ],
  );

  int balance() => PointEntry.available(
    [
      for (final r in app.records.all(Collections.pointEntries))
        PointEntry.fromRecord(r),
    ].where((e) => e.counts),
    kid.id,
  );

  test('three wishes of 20 with 20 points: one is sent', () async {
    await earn(20);
    final answer = await sync(
      kid,
      changes: [entry('w1', -20), entry('w2', -20), entry('w3', -20)],
    );
    expect(stored('w1'), isNotNull);
    expect(stored('w2'), isNull);
    expect(stored('w3'), isNull);
    expect(
      answer.refused.map((i) => (i.id, i.code)),
      unorderedEquals([('w2', 'not_allowed'), ('w3', 'not_allowed')]),
    );
    // The device drops them again.
    for (final id in ['w2', 'w3']) {
      expect(answer.rejected.singleWhere((r) => r.id == id).deleted, isTrue);
    }
    await decide('w1', PointStatus.approved);
    expect(balance(), 0);
  });

  test('a later wish counts what is still open', () async {
    await earn(20);
    await sync(kid, changes: [entry('w1', -15)]);
    final second = await sync(kid, changes: [entry('w2', -10)]);
    expect(stored('w2'), isNull);
    expect(second.refused.single.code, 'not_allowed');
    // Within what is left it goes through.
    await sync(kid, changes: [entry('w3', -5)]);
    expect(stored('w3'), isNotNull);
    // Declined, the points are free again.
    await decide('w1', PointStatus.rejected);
    await sync(kid, changes: [entry('w4', -10)]);
    expect(stored('w4'), isNotNull);
    await decide('w3', PointStatus.approved);
    await decide('w4', PointStatus.approved);
    expect(balance(), 5);
  });

  test(
    'an open wish stays when it is sent again, not when it costs more',
    () async {
      await earn(20);
      await sync(kid, changes: [entry('w1', -20)]);
      // Mama paid out points meanwhile.
      await sync(
        mama,
        changes: [
          entry(
            'payout',
            -10,
            kind: PointKind.payout,
            status: PointStatus.approved,
          ),
        ],
      );
      final again = await sync(
        kid,
        changes: [entry('w1', -20, title: '🍦 Großes Eis')],
      );
      expect(again.refused, isEmpty);
      expect(stored('w1')!.title, '🍦 Großes Eis');
      final more = await sync(kid, changes: [entry('w1', -25)]);
      expect(more.refused.single.code, 'not_allowed');
      expect(stored('w1')!.points, -20);
    },
  );

  test('done chores still ask for points, adults decide freely', () async {
    final done = await sync(
      kid,
      changes: [entry('c1', 3, kind: PointKind.chore, title: 'Tisch')],
    );
    expect(done.refused, isEmpty);
    expect(stored('c1'), isNotNull);
    // An adult's own booking is not limited by the server.
    final direct = await sync(
      mama,
      changes: [entry('r1', -10, status: PointStatus.approved)],
    );
    expect(direct.refused, isEmpty);
    expect(stored('r1'), isNotNull);
  });
}
