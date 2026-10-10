import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String token;
  late String mama;
  late String papa;

  setUp(() async {
    app = FamioServerApp.inMemory();
    final setup = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/auth/setup'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'username': 'mama',
          'password': 'geheim123',
          'setupCode': app.setupCode,
        }),
      ),
    );
    token = (jsonDecode(await setup.readAsString()) as Map)['token'] as String;
    mama = app.accounts.members().single.id;
    papa = app.accounts
        .create(username: 'papa', displayName: 'Papa', passwordHash: 'x')
        .id;
  });

  tearDown(() => app.close());

  Future<Map<String, Object?>> overview({String? language}) async {
    final r = await app.handler(
      Request(
        'GET',
        Uri.parse('http://famio.test/api/overview'),
        headers: {
          'authorization': 'Bearer $token',
          'accept-language': ?language,
        },
      ),
    );
    expect(r.statusCode, 200);
    return (jsonDecode(await r.readAsString()) as Map).cast();
  }

  void write(String collection, String id, Map<String, Object?> data) => expect(
    app.records.writeAs(mama, [
      SyncRecord(
        collection: collection,
        id: id,
        data: data,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]),
    isEmpty,
  );

  test('today\'s chores with whose turn it is and what is done', () async {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    write(
      Collections.chores,
      'tisch',
      Chore(
        id: 'tisch',
        title: 'Tisch decken',
        emoji: '🍽️',
        memberIds: [mama, papa],
        rotate: true,
        start: start,
      ).toData(),
    );
    write(
      Collections.chores,
      'muell',
      Chore(
        id: 'muell',
        title: 'Müll',
        repeat: ChoreRepeat.weekly,
        start: start,
      ).toData(),
    );
    write(
      Collections.chores,
      'pause',
      Chore(id: 'pause', title: 'Fenster', start: start, paused: true).toData(),
    );
    final weekly = Chore(
      id: 'muell',
      title: 'Müll',
      repeat: ChoreRepeat.weekly,
      start: start,
    );
    write(
      Collections.pointEntries,
      weekly.completionId(start),
      PointEntry(
        id: weekly.completionId(start),
        memberId: papa,
        points: 1,
        title: 'Müll',
        kind: PointKind.chore,
        at: DateTime.now(),
        refId: 'muell',
      ).toData(),
    );

    final chores = (await overview())['chores'] as List;
    expect(chores.map((c) => (c as Map)['title']), ['Müll', 'Tisch decken']);
    final table = chores.last as Map;
    expect(table['assigneeId'], mama);
    expect(table['done'], isFalse);
    final bins = chores.first as Map;
    expect((bins['done'], bins['doneBy']), (true, papa));
  });

  test('next bin pickups with who puts them out, and countdowns', () async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime inDays(int n) => DateTime(today.year, today.month, today.day + n);
    write(
      Collections.wasteSettings,
      WasteSettings.recordId,
      WasteSettings(memberIds: [papa]).toData(),
    );
    for (final (id, title, day) in [
      ('w1', 'Gelber Sack', 2),
      ('w2', 'Altpapier', 2),
      ('w3', 'Restmüll', 9),
      ('x', 'Zahnarzt', 1),
    ]) {
      write(
        Collections.events,
        id,
        CalendarEvent(
          id: id,
          title: title,
          start: inDays(day),
          end: inDays(day + 1),
          allDay: title != 'Zahnarzt',
        ).toData(),
      );
    }
    write(
      Collections.events,
      'urlaub',
      CalendarEvent(
        id: 'urlaub',
        title: 'Ostsee',
        start: inDays(40),
        end: inDays(47),
        allDay: true,
        countdown: true,
      ).toData(),
    );

    final data = await overview(language: 'en');
    final waste = (data['waste'] as List).cast<Map>();
    expect(waste.map((w) => w['days']), [2, 9]);
    expect(waste.first['kinds'], ['paper', 'packaging']);
    expect(waste.first['labels'], ['Paper', 'Packaging']);
    expect(waste.first['memberIds'], [papa]);
    final countdowns = (data['countdowns'] as List).cast<Map>();
    expect(countdowns.single['title'], 'Ostsee');
    expect(countdowns.single['days'], 40);
    expect(countdowns.single['running'], isFalse);
  });

  test('without bin settings there are no pickups', () async {
    expect((await overview())['waste'], isEmpty);
  });
}
