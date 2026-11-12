import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Children do not decide who sees something: what exists keeps its
/// audience when they change it, only their own private things they share.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, papa, kid;
  late Map<String, String> tokens;

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
    tokens = {
      for (final m in [mama, papa, kid]) m.id: app.accounts.createSession(m.id),
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
  }) async {
    final response = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer ${tokens[who.id]}',
          'content-type': 'application/json',
        },
        body: jsonEncode(SyncRequest(since: since, changes: changes).toJson()),
      ),
    );
    return SyncResponse.fromJson(
      (jsonDecode(await response.readAsString()) as Map).cast(),
    );
  }

  SyncRecord document(
    String id,
    String title, {
    List<String>? visibleTo,
    required int updatedAt,
    int rev = 0,
  }) => SyncRecord(
    collection: Collections.documents,
    id: id,
    data: {
      'title': title,
      'category': 'identity',
      SyncRecord.visibilityKey: ?visibleTo,
    },
    updatedAt: updatedAt,
    rev: rev,
  );

  test('a child cannot hide a family record from the parents', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(mama, changes: [document('pass', 'Reisepass', updatedAt: now)]);
    final rev = (await sync(papa)).rev;
    final stored = app.records.get(Collections.documents, 'pass')!;
    await sync(
      kid,
      changes: [
        document(
          'pass',
          'Reisepass (neu)',
          visibleTo: [kid.id],
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    final after = app.records.get(Collections.documents, 'pass')!;
    // The edit itself counts, the audience stays the family's.
    expect(after.data['title'], 'Reisepass (neu)');
    expect(after.visibleTo, isNull);
    final papaSees = (await sync(papa, since: rev)).changes.single;
    expect(papaSees.deleted, isFalse);
    expect(papaSees.data['title'], 'Reisepass (neu)');
  });

  test('a narrowed audience among adults stays as it was', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(
      mama,
      changes: [
        document(
          'zeugnis',
          'Zeugnis',
          visibleTo: [mama.id, papa.id, kid.id],
          updatedAt: now,
        ),
      ],
    );
    final stored = app.records.get(Collections.documents, 'zeugnis')!;
    await sync(
      kid,
      changes: [
        document(
          'zeugnis',
          'Zeugnis',
          visibleTo: [kid.id, papa.id],
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    expect(app.records.get(Collections.documents, 'zeugnis')!.visibleTo, [
      mama.id,
      papa.id,
      kid.id,
    ]);
  });

  test('what only the child sees, the child may share', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(
      kid,
      changes: [
        document('tagebuch', 'Notiz', visibleTo: [kid.id], updatedAt: now),
      ],
    );
    final stored = app.records.get(Collections.documents, 'tagebuch')!;
    await sync(
      kid,
      changes: [
        document(
          'tagebuch',
          'Notiz',
          visibleTo: [kid.id, mama.id],
          updatedAt: now + 1000,
          rev: stored.rev,
        ),
      ],
    );
    expect(app.records.get(Collections.documents, 'tagebuch')!.visibleTo, [
      kid.id,
      mama.id,
    ]);
    expect((await sync(mama)).changes.any((r) => r.id == 'tagebuch'), isTrue);
  });
}
