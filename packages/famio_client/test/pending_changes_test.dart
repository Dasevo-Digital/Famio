import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// Changes that wait for a later push batch, and two devices of the same
/// member (#492, #493). From the probes S1, S2 and S5 after 2.0.53.
void main() {
  late HttpServer server;
  late String url;
  late String papaToken;
  late String papaId;
  late String mamaToken;
  late String mamaId;
  late FamioServerApp app;
  final engines = <SyncEngine>[];

  setUp(() async {
    app = FamioServerApp.inMemory();
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    url = 'localhost:${server.port}';
    final login = await FamioApiClient(url).setup(
      username: 'papa',
      displayName: 'Papa',
      password: 'tulpe-regal-7',
      setupCode: app.setupCode,
    );
    papaToken = login.token;
    papaId = login.member.id;
    final mama = await FamioApiClient(url, token: papaToken).createMember(
      username: 'mama',
      displayName: 'Mama',
      password: 'tulpe-regal-7',
      role: MemberRole.adult,
    );
    mamaId = mama.id;
    mamaToken = (await FamioApiClient(
      url,
    ).login(username: 'mama', password: 'tulpe-regal-7', device: 'p')).token;
  });

  tearDown(() async {
    for (final e in engines) {
      await e.dispose();
    }
    engines.clear();
    await server.close(force: true);
  });

  SyncEngine device(String token, String member) {
    final e = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient(url, token: token),
      memberId: member,
    );
    engines.add(e);
    return e;
  }

  Future<void> later(SyncEngine b, int than) async {
    while (b.now <= than) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  // More than one push batch (500): the note goes in the second one, and
  // the answer to the first brought Papa's newer version of it. That
  // version replaced the waiting edit, which was then never sent, and
  // nobody learned of it (0 conflicts instead of 1).
  for (final bulk in [0, 600]) {
    test('an offline edit waiting behind $bulk others still makes a '
        'conflict', () async {
      final papa = device(papaToken, papaId);
      final mama = device(mamaToken, mamaId);
      // Mama's cache knows contacts before notes (insertion order), and
      // both go out at the same level: the note comes after the contacts.
      mama.put(Collections.contacts, 'seed', {'name': 'Seed'});
      await mama.sync();
      papa.put(Collections.notes, 'x', {'title': 'Original', 'text': 'v0'});
      await papa.sync();
      await mama.sync();

      for (var i = 0; i < bulk; i++) {
        mama.put(Collections.contacts, 'c$i', {'name': 'Kontakt $i'});
      }
      mama.put(Collections.notes, 'x', {'title': 'Mama', 'text': 'mama'});
      final order = [for (final r in mama.pushOrder) r.id];
      expect(order.indexOf('x'), bulk == 0 ? 0 : greaterThan(499));
      final mamaEdit = mama.store.get(Collections.notes, 'x')!.record.updatedAt;
      await later(papa, mamaEdit);
      papa.put(Collections.notes, 'x', {'title': 'Papa', 'text': 'papa'});
      await papa.sync();
      await mama.sync();

      expect(app.records.get(Collections.notes, 'x')!.data['title'], 'Papa');
      expect(mama.record(Collections.notes, 'x')!.data['title'], 'Papa');
      final conflicts = app.records.all(Collections.conflicts).toList();
      expect(conflicts, hasLength(1));
      expect(SyncConflict.fromRecord(conflicts.single).lost['title'], 'Mama');
      expect(mama.store.dirty, isEmpty);
    });

    test('an offline deletion waiting behind $bulk others still makes a '
        'conflict', () async {
      final papa = device(papaToken, papaId);
      final mama = device(mamaToken, mamaId);
      mama.put(Collections.contacts, 'seed', {'name': 'Seed'});
      await mama.sync();
      papa.put(Collections.notes, 'x', {'title': 'Original', 'text': 'v0'});
      await papa.sync();
      await mama.sync();

      for (var i = 0; i < bulk; i++) {
        mama.put(Collections.contacts, 'c$i', {'name': 'Kontakt $i'});
      }
      mama.delete(Collections.notes, 'x');
      final order = [for (final r in mama.pushOrder) r.id];
      expect(order.indexOf('x'), bulk == 0 ? 0 : greaterThan(499));
      final mamaEdit = mama.store.get(Collections.notes, 'x')!.record.updatedAt;
      await later(papa, mamaEdit);
      papa.put(Collections.notes, 'x', {'title': 'Papa', 'text': 'papa'});
      await papa.sync();
      await mama.sync();

      expect(mama.record(Collections.notes, 'x')!.data['title'], 'Papa');
      final conflicts = app.records.all(Collections.conflicts).toList();
      expect(conflicts, hasLength(1));
      expect(SyncConflict.fromRecord(conflicts.single).lostDeleted, isTrue);
    });
  }

  // Parents first: an item, comment or log whose list, appointment or
  // child waits in a later batch was refused there.
  test('what hangs on a record is sent after it', () async {
    final mama = device(mamaToken, mamaId);
    // The items' collection is known first, so it came first.
    mama.put(Collections.shoppingItems, 'seed', {'name': 'Seed'});
    await mama.sync();
    for (var i = 0; i < 600; i++) {
      mama.put(Collections.shoppingItems, 'i$i', {
        'name': 'Item $i',
        'listId': 'l',
      });
    }
    mama.put(Collections.shoppingLists, 'l', {'name': 'Urlaub'});
    mama.put(Collections.children, 'c', {'name': 'Kind'});
    mama.put(Collections.childLogs, 'log', {
      'childId': 'c',
      'kind': 'diaper',
      'at': '2026-11-01T10:00:00Z',
    });
    final order = [for (final r in mama.pushOrder) (r.collection, r.id)];
    expect(
      order.indexOf((Collections.shoppingLists, 'l')),
      lessThan(order.indexOf((Collections.shoppingItems, 'i0'))),
    );
    expect(
      order.indexOf((Collections.children, 'c')),
      lessThan(order.indexOf((Collections.childLogs, 'log'))),
    );
    await mama.sync();
    expect(mama.store.dirty, isEmpty);
    expect(app.records.get(Collections.childLogs, 'log'), isNotNull);
    expect(app.records.get(Collections.shoppingItems, 'i599'), isNotNull);
  });

  // Two devices of the same member, both offline: the older edit lost
  // without a trace, because conflicts were only kept between members.
  test('two devices of one member: the losing edit is kept', () async {
    final phone = device(papaToken, papaId);
    final laptopToken = (await FamioApiClient(url).login(
      username: 'papa',
      password: 'tulpe-regal-7',
      device: 'laptop',
    )).token;
    final laptop = device(laptopToken, papaId);
    phone.put(Collections.notes, 'n', {'title': 'Einkauf', 'text': 'v0'});
    await phone.sync();
    await laptop.sync();
    phone.put(Collections.notes, 'n', {'title': 'Einkauf', 'text': 'phone'});
    final t = phone.store.get(Collections.notes, 'n')!.record.updatedAt;
    await later(laptop, t);
    laptop.put(Collections.notes, 'n', {'title': 'Einkauf', 'text': 'laptop'});
    await laptop.sync();
    await phone.sync();

    expect(phone.record(Collections.notes, 'n')!.data['text'], 'laptop');
    final conflicts = app.records.all(Collections.conflicts).toList();
    expect(conflicts, hasLength(1));
    final conflict = SyncConflict.fromRecord(conflicts.single);
    expect(conflict.lost['text'], 'phone');
    expect(conflict.lostBy, papaId);
    // And it reaches the devices, so it can be decided there.
    await laptop.sync();
    expect(laptop.store.all(Collections.conflicts), hasLength(1));
  });

  // A device sending the same edit again (the answer got lost) is no
  // conflict with itself.
  test('the same edit sent twice is no conflict', () async {
    final phone = device(papaToken, papaId);
    phone.put(Collections.notes, 'n', {'title': 'Einkauf', 'text': 'v0'});
    await phone.sync();
    final sent = phone.store.get(Collections.notes, 'n')!.record;
    final api = FamioApiClient(url, token: papaToken);
    await api.sync(SyncRequest(since: 0, changes: [sent.copyWith(rev: 0)]));
    expect(app.records.all(Collections.conflicts), isEmpty);
  });
}
