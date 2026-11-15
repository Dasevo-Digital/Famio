import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// The family inbox holds scanned letters before anyone files them, often
/// about health or money: children receive an entry only when the one who
/// filed it shared it with them, and always what they filed themselves.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, papa, kid, sister;
  late Map<String, String> tokens;
  var clock = 1000;

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
    sister = app.accounts.create(
      username: 'sister',
      displayName: 'Sister',
      role: MemberRole.child,
    );
    tokens = {
      for (final m in [mama, papa, kid, sister])
        m.id: app.accounts.createSession(m.id),
    };
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<SyncResponse> sync(
    FamilyMember who, {
    List<SyncRecord> changes = const [],
    int since = 0,
    String? scope,
  }) async {
    final response = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer ${tokens[who.id]}',
          'content-type': 'application/json',
        },
        body: jsonEncode(
          SyncRequest(
            since: since,
            changes: changes,
            scope: scope,
            resettable: scope != null,
          ).toJson(),
        ),
      ),
    );
    expect(response.statusCode, 200);
    return SyncResponse.fromJson(
      (jsonDecode(await response.readAsString()) as Map).cast(),
    );
  }

  SyncRecord entry(InboxItem item, {bool deleted = false}) => SyncRecord(
    collection: Collections.inbox,
    id: item.id,
    data: deleted ? const {} : item.toData(),
    deleted: deleted,
    updatedAt: clock += 1000,
  );

  Future<Set<String>> sees(FamilyMember who) async => {
    for (final r in (await sync(who)).changes)
      if (!r.deleted && r.collection == Collections.inbox) r.id,
  };

  test('children get only what was shared with them or is theirs', () async {
    await sync(
      mama,
      changes: [
        entry(
          InboxItem(id: 'arztbrief', title: 'Arztbrief', createdBy: mama.id),
        ),
        entry(
          InboxItem(
            id: 'ausflug',
            title: 'Ausflug',
            createdBy: mama.id,
            forChildren: true,
          ),
        ),
      ],
    );
    await sync(
      kid,
      changes: [
        entry(InboxItem(id: 'zettel', title: 'Zettel', createdBy: kid.id)),
      ],
    );
    expect(await sees(mama), {'arztbrief', 'ausflug', 'zettel'});
    expect(await sees(papa), {'arztbrief', 'ausflug', 'zettel'});
    expect(await sees(kid), {'ausflug', 'zettel'});
    // Another child's own entry is not shared with the sister.
    expect(await sees(sister), {'ausflug'});
  });

  test('a child cannot open or change an entry not shared with it', () async {
    await sync(
      mama,
      changes: [
        entry(
          InboxItem(id: 'arztbrief', title: 'Arztbrief', createdBy: mama.id),
        ),
      ],
    );
    final answer = await sync(
      kid,
      changes: [
        entry(
          InboxItem(
            id: 'arztbrief',
            title: 'Meins',
            createdBy: kid.id,
            forChildren: true,
          ),
        ),
      ],
    );
    // Only a revocation of the key it sent, no contents.
    expect(answer.rejected.single.deleted, isTrue);
    expect(answer.rejected.single.data, isEmpty);
    final stored = (await sync(
      mama,
    )).changes.firstWhere((r) => r.id == 'arztbrief');
    expect(stored.data['title'], 'Arztbrief');
    expect(stored.data[InboxItem.forChildrenKey], isNull);
  });

  test('taking the sharing back takes the entry off the children', () async {
    final shared = InboxItem(
      id: 'ausflug',
      title: 'Ausflug',
      createdBy: mama.id,
      forChildren: true,
    );
    await sync(mama, changes: [entry(shared)]);
    final before = await sync(kid);
    expect(before.changes.map((r) => r.id), contains('ausflug'));
    await sync(
      mama,
      changes: [
        entry(InboxItem(id: 'ausflug', title: 'Ausflug', createdBy: mama.id)),
      ],
    );
    final after = await sync(kid, since: before.rev);
    final revoked = after.changes.where((r) => r.id == 'ausflug');
    expect(revoked, hasLength(1));
    expect(revoked.single.deleted, isTrue);
    expect(revoked.single.data, isEmpty);
  });

  test('devices of children with older rules sync everything again', () async {
    await sync(
      mama,
      changes: [
        entry(
          InboxItem(id: 'arztbrief', title: 'Arztbrief', createdBy: mama.id),
        ),
      ],
    );
    final adult = await sync(mama);
    final child = await sync(kid);
    // A child's scope changed with the rule; an adult's did not.
    expect(child.scope, isNot(endsWith(':6')));
    final again = await sync(
      kid,
      since: child.rev,
      scope: '${child.scope!.substring(0, child.scope!.lastIndexOf(':'))}:6',
    );
    expect(again.reset, isTrue);
    expect(again.changes.map((r) => r.id), isNot(contains('arztbrief')));
    final adultAgain = await sync(mama, since: adult.rev, scope: adult.scope);
    expect(adultAgain.reset, isFalse);
  });
}
