import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// End-to-end: two "devices" sync through a real in-process server.
void main() {
  late HttpServer server;
  late String url;
  late String token;
  late String memberId;
  final engines = <SyncEngine>[];

  setUp(() async {
    final app = FamioServerApp.inMemory();
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    url = 'localhost:${server.port}';
    final login = await FamioApiClient(
      url,
    ).setup(username: 'papa', displayName: 'Papa', password: 'geheim123');
    token = login.token;
    memberId = login.member.id;
  });

  tearDown(() async {
    for (final e in engines) {
      await e.dispose();
    }
    engines.clear();
    await server.close(force: true);
  });

  SyncEngine device() {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient(url, token: token),
      memberId: memberId,
    );
    engines.add(engine);
    return engine;
  }

  test('changes travel between devices, including deletes', () async {
    final a = device(), b = device();
    a.put(Collections.shoppingItems, 'milk', {'name': 'Milch'});
    await a.sync();
    expect(a.store.dirty, isEmpty);

    await b.sync();
    expect(b.record(Collections.shoppingItems, 'milk')?.data['name'], 'Milch');

    b.delete(Collections.shoppingItems, 'milk');
    await b.sync();
    await a.sync();
    expect(a.records(Collections.shoppingItems), isEmpty);
  });

  test('offline edits merge with last writer wins', () async {
    final a = device(), b = device();
    a.put(Collections.tasks, 't1', {'title': 'alt'});
    await a.sync();
    await b.sync();

    // Both edit while "offline"; B edits later and should win everywhere.
    a.put(Collections.tasks, 't1', {'title': 'von A'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    b.put(Collections.tasks, 't1', {'title': 'von B'});
    await b.sync();
    await a.sync();
    await b.sync();

    expect(a.record(Collections.tasks, 't1')?.data['title'], 'von B');
    expect(b.record(Collections.tasks, 't1')?.data['title'], 'von B');
    expect(a.store.dirty, isEmpty);
  });

  test('pulls more than one page', () async {
    final a = device(), b = device();
    for (var i = 0; i < RecordStore.pageSize + 20; i++) {
      a.put(Collections.shoppingItems, 'i$i', {'name': 'Item $i'});
    }
    await a.sync();
    await b.sync();
    expect(
      b.records(Collections.shoppingItems).length,
      RecordStore.pageSize + 20,
    );
  });

  test('websocket hint makes the other device sync by itself', () async {
    final a = device(), b = device();
    b.start();
    await b.statusChanges.firstWhere((s) => s.state == SyncState.idle);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final arrived = b.changes.firstWhere((c) => c.contains(Collections.tasks));
    a.put(Collections.tasks, 'live', {'title': 'Live'});
    await a.sync();
    await arrived.timeout(const Duration(seconds: 5));
    expect(b.record(Collections.tasks, 'live')?.data['title'], 'Live');
  });

  test('invalid token reports unauthorized', () async {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient(url, token: 'falsch'),
      memberId: memberId,
    );
    engines.add(engine);
    await engine.sync();
    expect(engine.status.state, SyncState.unauthorized);
  });

  test('records of collections unknown to the server stay local', () async {
    final a = device();
    a.put('future_module', 'x', {'v': 1});
    a.put(Collections.tasks, 't', {'title': 'normal'});
    await a.sync().timeout(const Duration(seconds: 5));
    expect(a.status.state, SyncState.idle);
    expect(
      [for (final r in a.store.dirty) r.record.collection],
      ['future_module'],
    );
  });

  test('records of collections unknown to the server stay local', () async {
    final a = device();
    a.put('future_module', 'x', {'v': 1});
    a.put(Collections.tasks, 't', {'title': 'normal'});
    await a.sync().timeout(const Duration(seconds: 5));
    expect(a.status.state, SyncState.idle);
    expect(
      [for (final r in a.store.dirty) r.record.collection],
      ['future_module'],
    );
  });

  test('direct messages with photos reach only the two members', () async {
    final admin = FamioApiClient(url, token: token);
    await admin.createMember(
      username: 'partner',
      displayName: 'Partner',
      password: 'geheim123',
    );
    await admin.createMember(
      username: 'kind',
      displayName: 'Kind',
      password: 'geheim123',
    );
    Future<SyncEngine> login(String name) async {
      final r = await FamioApiClient(
        url,
      ).login(username: name, password: 'geheim123');
      final e = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: FamioApiClient(url, token: r.token),
        memberId: r.member.id,
      );
      engines.add(e);
      return e;
    }

    final mama = device();
    final papa = await login('partner');
    final kind = await login('kind');

    final photo = await mama.api.uploadFile(
      bytes: [1, 2, 3, 4],
      name: 'geschenk.jpg',
      mime: 'image/jpeg',
    );
    final chat = ChatIds.direct(memberId, papa.memberId);
    final message = ChatMessage(
      id: newId(),
      chatId: chat,
      authorId: memberId,
      sentAt: DateTime.now(),
      text: 'Idee für Geburtstag',
      attachment: photo,
      visibleTo: [memberId, papa.memberId],
    );
    mama.put(Collections.chatMessages, message.id, message.toData());
    await mama.sync();
    await papa.sync();
    await kind.sync();

    expect(papa.records(Collections.chatMessages), hasLength(1));
    expect(kind.records(Collections.chatMessages), isEmpty);

    final dir = Directory.systemTemp.createTempSync('famio_cache_');
    final key = '1f' * 32;
    final cache = FileCache.open(
      '${dir.path}/cache.db',
      papa.api,
      hexKey: key,
      tempDir: Directory('${dir.path}/tmp'),
    );
    expect(await cache.bytes(photo), [1, 2, 3, 4]);
    // Offline copy is encrypted on disk.
    cache.put(photo, 'Arztbrief-Klartext'.codeUnits);
    cache.close();
    final raw = [
      for (final f in dir.listSync().whereType<File>()) ...f.readAsBytesSync(),
    ];
    expect(String.fromCharCodes(raw), isNot(contains('Arztbrief-Klartext')));
    final reopened = FileCache.open(
      '${dir.path}/cache.db',
      papa.api,
      hexKey: key,
      tempDir: Directory('${dir.path}/tmp'),
    );
    final copy = await reopened.openable(photo);
    expect(await copy.readAsString(), 'Arztbrief-Klartext');
    reopened.clearTemp();
    expect(copy.existsSync(), isFalse);

    await expectLater(
      FileCache.open(':memory:', kind.api, tempDir: dir).bytes(photo),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 404)),
    );
  });

  test('url normalisation', () {
    expect(
      FamioApiClient.normalizeUrl('homeassistant.local').toString(),
      'http://homeassistant.local:8765/',
    );
    expect(
      FamioApiClient.normalizeUrl('https://famio.example.org/').toString(),
      'https://famio.example.org/',
    );
  });
}
