import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// One family member talking to the server.
class _Member {
  _Member(this.base, this.token, this.id);

  final Uri base;
  final String token;
  final String id;
  int rev = 0;
  final seen = <String, SyncRecord>{};

  Future<Map<String, Object?>> call(
    String method,
    String path, [
    Object? body,
  ]) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['content-type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await request.send());
    final decoded = jsonDecode(response.body);
    return {
      '_status': response.statusCode,
      if (decoded is Map) ...decoded.cast(),
    };
  }

  Future<SyncResponse> sync([List<SyncRecord> changes = const []]) async {
    final response = SyncResponse.fromJson(
      await call(
        'POST',
        'api/sync',
        SyncRequest(since: rev, changes: changes).toJson(),
      ),
    );
    for (final r in [...response.changes, ...response.rejected]) {
      r.deleted
          ? seen.remove('${r.collection}/${r.id}')
          : seen['${r.collection}/${r.id}'] = r;
    }
    rev = response.rev;
    return response;
  }
}

SyncRecord _record(
  String collection,
  String id,
  Map<String, Object?> data, {
  int? at,
}) => SyncRecord(
  collection: collection,
  id: id,
  data: data,
  updatedAt: at ?? DateTime.now().millisecondsSinceEpoch,
);

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;
  late _Member mama; // admin
  late _Member papa;

  Future<_Member> login(String username) async {
    final response = await http.post(
      base.resolve('api/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': username, 'password': 'geheim123'}),
    );
    final body = jsonDecode(response.body) as Map;
    return _Member(
      base,
      body['token'] as String,
      (body['member'] as Map)['id'] as String,
    );
  }

  setUp(() async {
    app = FamioServerApp.inMemory();
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    await http.post(
      base.resolve('api/auth/setup'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'username': 'mama',
        'password': 'geheim123',
        'setupCode': app.setupCode,
      }),
    );
    mama = await login('mama');
    await mama.call('POST', 'api/admin/users', {
      'username': 'papa',
      'displayName': 'Papa',
      'password': 'geheim123',
    });
    papa = await login('papa');
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  test(
    'settings go back to their defaults, the parents\' code stays',
    () async {
      await mama.call('PATCH', 'api/admin/settings', {
        'publicUrl': 'https://famio.example.org',
        'maxUploadMb': 7,
        'timeZone': 'America/New_York',
      });
      await mama.call('PUT', 'api/admin/location-code', {'code': 'geheim'});
      expect(
        (await papa.call('POST', 'api/admin/settings/reset'))['_status'],
        403,
      );

      final overview = ServerOverview.fromJson(
        await mama.call('POST', 'api/admin/settings/reset'),
      );
      expect(overview.settings.publicUrl, isNull);
      expect(overview.settings.maxUploadMb, isNull);
      expect(overview.effective.maxUploadMb, 100);
      expect(overview.effective.timeZone, 'Europe/Berlin');
      expect(overview.locationCodeSet, isTrue);
    },
  );

  group('deleting all data', () {
    Future<Map<String, Object?>> wipe(
      _Member who, {
      String password = 'geheim123',
      String confirm = 'LÖSCHEN',
      bool removeMembers = false,
    }) => who.call('POST', 'api/admin/wipe', {
      'password': password,
      'confirm': confirm,
      'removeMembers': removeMembers,
    });

    test('needs an admin, the password and the confirmation', () async {
      expect((await wipe(papa))['_status'], 403);
      expect((await wipe(mama, password: 'falsch'))['_status'], 403);
      final unconfirmed = await wipe(mama, confirm: 'ja');
      expect(unconfirmed['_status'], 400);
      expect(unconfirmed['message'], contains('„LÖSCHEN“'));
    });

    test('removes content everywhere, keeps the accounts', () async {
      await mama.sync([
        _record(Collections.events, 'e1', {'title': 'Fest'}),
        _record(Collections.shoppingItems, 's1', {'name': 'Milch'}),
        _record(Collections.documents, 'd1', {
          'title': 'Pass',
          SyncRecord.visibilityKey: [mama.id],
        }),
      ]);
      await papa.sync();
      expect(papa.seen.keys, hasLength(2));
      final file = await app.files.save(
        owner: mama.id,
        name: 'foto.jpg',
        mime: 'image/jpeg',
        body: Stream.value([1, 2, 3]),
      );
      final revBefore = app.records.currentRev;

      final result = await wipe(mama);
      expect(result['_status'], 200);
      expect(result['records'], 3);
      expect(result['files'], 1);
      expect(result['members'], 0);

      // Apps receive tombstones and delete their copies.
      await papa.sync();
      expect(papa.seen, isEmpty);
      await mama.sync();
      expect(mama.seen, isEmpty);
      expect(app.records.currentRev, greaterThan(revBefore));
      expect(app.records.counts(), isEmpty);
      expect(app.files.get(file.id), isNull);
      // A tombstone keeps nothing of the content.
      expect(app.records.get(Collections.events, 'e1')!.data, isEmpty);

      // Everybody can still sign in and start over.
      expect((await login('papa')).token, isNotEmpty);
      await papa.sync([
        _record(Collections.events, 'e2', {'title': 'Neu'}),
      ]);
      await mama.sync();
      expect(mama.seen.keys, ['${Collections.events}/e2']);
    });

    test('drops changes made offline before', () async {
      await mama.sync([
        _record(Collections.events, 'e1', {'title': 'Fest'}),
      ]);
      await papa.sync();
      final before = DateTime.now().millisecondsSinceEpoch - 1000;
      await wipe(mama);

      // Papa was offline: an edit, a new item and a deletion, all older.
      final response = await papa.sync([
        _record(Collections.events, 'e1', {'title': 'Fest!'}, at: before),
        _record(Collections.shoppingItems, 's1', {'name': 'Brot'}, at: before),
      ]);
      expect(response.rejected.every((r) => r.deleted), isTrue);
      expect(papa.seen, isEmpty);
      expect(app.records.counts(), isEmpty);
    });

    test('can remove all other members', () async {
      final result = await wipe(mama, removeMembers: true);
      expect(result['members'], 1);
      expect([for (final m in app.accounts.members()) m.username], ['mama']);
      expect(
        (await papa.call('POST', 'api/sync', {'since': 0}))['_status'],
        401,
      );
    });
  });
}
