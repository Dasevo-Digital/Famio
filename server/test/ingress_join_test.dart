import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

// The fixed service gateway of Home Assistant ingress (synthetic).
class _IngressConnection implements HttpConnectionInfo {
  @override
  InternetAddress get remoteAddress => InternetAddress('172.30.32.2');
  @override
  int get remotePort => 40000;
  @override
  int get localPort => 8080;
}

/// Who opens Famio through Home Assistant for the first time joins as a
/// guest; the admins decide what they get (#508).
void main() {
  late FamioServerApp app;
  late Directory data;

  setUp(() {
    FamioServerApp.initTimeZones();
    data = Directory.systemTemp.createTempSync('famio_ingress_join_');
    app = FamioServerApp(
      db: openFamioDatabase(':memory:'),
      dataDir: data.path,
      location: tz.getLocation('Europe/Berlin'),
      ingressAuth: true,
    );
  });
  tearDown(() async {
    await app.close();
    data.deleteSync(recursive: true);
  });

  Future<Response> viaPanel(String haId, String name) async => app.handler(
    Request(
      'POST',
      Uri.parse('http://famio.test/api/sync'),
      context: {'shelf.io.connection_info': _IngressConnection()},
      headers: {
        'content-type': 'application/json',
        'x-remote-user-id': haId,
        'x-remote-user-name': name,
        'x-remote-user-display-name': name,
      },
      body: jsonEncode(const SyncRequest(since: 0).toJson()),
    ),
  );

  test('the first sets the server up, the next ones are guests', () async {
    expect((await viaPanel('fixture-ha-1', 'mama')).statusCode, 200);
    final mama = app.accounts.members().single;
    expect(mama.role, MemberRole.adult);
    expect(mama.isAdmin, isTrue);
    final now = DateTime.now().millisecondsSinceEpoch;
    app.records.writeAs(mama.id, [
      SyncRecord(
        collection: Collections.children,
        id: 'mia',
        data: {
          'name': 'Mia',
          'birthDate': '2025-01-01',
          'emergency': {'allergies': 'Erdnüsse'},
        },
        updatedAt: now,
      ),
      SyncRecord(
        collection: Collections.memberEmergency,
        id: mama.id,
        data: {
          'info': {'conditions': 'Epilepsie'},
        },
        updatedAt: now,
      ),
      SyncRecord(
        collection: Collections.medications,
        id: 'med',
        data: {'name': 'Plan', 'start': '2026-01-01'},
        updatedAt: now,
      ),
    ]);
    final r = await viaPanel('fixture-ha-2', 'besuch');
    expect(r.statusCode, 200);
    final joined = app.accounts.members().firstWhere(
      (m) => m.username == 'besuch',
    );
    expect(joined.role, MemberRole.guest);
    expect(joined.isAdmin, isFalse);
    final got = SyncResponse.fromJson(
      (jsonDecode(await r.readAsString()) as Map).cast(),
    );
    expect(
      [
        for (final c in got.changes)
          if (!c.deleted) c.collection,
      ],
      isNot(
        anyOf(
          contains(Collections.children),
          contains(Collections.memberEmergency),
          contains(Collections.medications),
        ),
      ),
    );
  });

  test('admins hear of who joined, once', () {
    final joined = <String>[];
    void open(String haId, String name) => app.accounts.fromHomeAssistant(
      haUserId: haId,
      haUsername: name,
      displayName: name,
      onJoined: (m) => joined.add(m.username),
    );
    open('fixture-ha-1', 'mama');
    open('fixture-ha-2', 'besuch');
    open('fixture-ha-2', 'besuch');
    expect(joined, ['besuch']);
  });
}
