// Other calendar apps know nothing of Famio's confirmations: saving an
// appointment there must not switch them off or drop the replies.
import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late FamilyMember mama, oma;
  late Map<String, String> tokens;
  var clock = DateTime.now().millisecondsSinceEpoch - 100000;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    oma = app.accounts.create(
      username: 'oma',
      displayName: 'Oma',
      role: MemberRole.guest,
    );
    tokens = {
      for (final m in [mama, oma]) m.id: app.accounts.createSession(m.id),
    };
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<Response> call(
    FamilyMember who,
    String method,
    String path, {
    Object? body,
  }) async => app.handler(
    Request(
      method,
      Uri.parse('http://famio.test/$path'),
      headers: {
        'authorization': 'Bearer ${tokens[who.id]}',
        if (body != null) 'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );

  Future<void> sync(FamilyMember who, List<SyncRecord> changes) async {
    final r = await call(
      who,
      'POST',
      'api/sync',
      body: SyncRequest(since: 0, changes: changes).toJson(),
    );
    expect(r.statusCode, 200, reason: await r.readAsString());
  }

  Future<String> davAuth(FamilyMember who) async {
    final made = await call(
      who,
      'POST',
      'api/me/app-passwords',
      body: {'name': 'Kalender', 'includeConfidential': false},
    );
    final secret =
        (jsonDecode(await made.readAsString()) as Map)['secret'] as String;
    return 'Basic ${base64.encode(utf8.encode('${who.username}:$secret'))}';
  }

  Future<Response> dav(
    FamilyMember who,
    String auth,
    String method,
    String path, {
    String? body,
    Map<String, String> headers = const {},
  }) async => app.handler(
    Request(
      method,
      Uri.parse('http://famio.test/dav/calendars/${who.username}/$path'),
      headers: {'authorization': auth, ...headers},
      body: body,
    ),
  );

  test('saving through CalDAV keeps asking for confirmations', () async {
    await sync(mama, [
      SyncRecord(
        collection: Collections.events,
        id: 'ev1',
        // As the app writes it: every field, empty ones included.
        data: CalendarEvent(
          id: 'ev1',
          title: 'Fussball',
          start: DateTime.utc(2026, 12, 1, 15),
          end: DateTime.utc(2026, 12, 1, 16),
          memberIds: [mama.id],
          bringerId: mama.id,
          assignmentConfirmation: const AssignmentSettings(
            required: true,
            remindMinutes: 60,
          ),
        ).toData(),
        updatedAt: clock += 1000,
      ),
    ]);
    final request = app.records
        .assignmentRequestsFor(app.records.get(Collections.events, 'ev1')!)
        .first;
    final rejected = app.records.writeAs(mama.id, [
      SyncRecord(
        collection: Collections.assignmentResponses,
        id: request.id,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        data: AssignmentResponse(
          targetCollection: request.target.collection,
          targetId: request.target.id,
          memberId: request.memberId,
          kind: request.kind,
          fingerprint: request.fingerprint,
          decision: AssignmentDecision.accepted,
          occurrence: request.occurrence,
        ).toData(),
      ),
    ]);
    expect(rejected, isEmpty);
    expect(app.records.all(Collections.assignmentResponses), hasLength(1));
    final auth = await davAuth(mama);
    final got = await dav(mama, auth, 'GET', 'famio/ev1.ics');
    final ics = await got.readAsString();
    final put = await dav(
      mama,
      auth,
      'PUT',
      'famio/ev1.ics',
      body: ics,
      headers: {'content-type': 'text/calendar'},
    );
    final after = app.records.get(Collections.events, 'ev1')!.data;

    expect(put.statusCode, 204);
    expect((after['assignmentConfirmation'] as Map)['required'], isTrue);
    expect(after['bringerId'], mama.id);
    final replies = app.records
        .all(Collections.assignmentResponses)
        .where((r) => !r.deleted);
    expect(replies, hasLength(1));
  });
}
