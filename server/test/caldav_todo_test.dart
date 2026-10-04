import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// A reminder as Apple Reminders writes it: due at a time of day, an alarm,
/// a priority and Apple's own sort order.
const appleReminder = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//iOS 26.0//EN
BEGIN:VTODO
UID:8F2A-REMINDER
DTSTAMP:20261003T080000Z
CREATED:20261003T080000Z
SUMMARY:Elternabend vorbereiten
DESCRIPTION:Fragen sammeln
DUE;TZID=Europe/Berlin:20261007T183000
PRIORITY:1
X-APPLE-SORT-ORDER:742991234
STATUS:NEEDS-ACTION
BEGIN:VALARM
ACTION:DISPLAY
DESCRIPTION:Reminder
TRIGGER;VALUE=DATE-TIME:20261007T153000Z
END:VALARM
END:VTODO
END:VCALENDAR
''';

String reminder(String uid, String summary, {String extra = ''}) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Apple Inc.//iOS 26.0//EN\r\n'
    'BEGIN:VTODO\r\nUID:$uid\r\nDTSTAMP:20261003T080000Z\r\n'
    'SUMMARY:$summary\r\n$extra'
    'END:VTODO\r\nEND:VCALENDAR\r\n';

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;
  late String token;
  late String secret;

  setUp(() async {
    app = FamioServerApp.inMemory();
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    final login = await http.post(
      base.resolve('api/auth/setup'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'username': 'mama',
        'password': 'geheim123',
        'setupCode': app.setupCode,
      }),
    );
    token = (jsonDecode(login.body) as Map)['token'] as String;
    final created = await http.post(
      base.resolve('api/me/app-passwords'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode({'name': 'iPhone'}),
    );
    secret = (jsonDecode(created.body) as Map)['secret'] as String;
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  Future<http.Response> dav(
    String method,
    String path, {
    String? body,
    Map<String, String> headers = const {},
  }) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] =
          'Basic ${base64.encode(utf8.encode('mama:$secret'))}'
      ..headers.addAll(headers);
    if (body != null) {
      request.headers['content-type'] = path.endsWith('.ics')
          ? 'text/calendar; charset=utf-8'
          : 'application/xml; charset=utf-8';
      request.body = body;
    }
    return http.Response.fromStream(await request.send());
  }

  Future<void> sync(List<SyncRecord> changes) async {
    final r = await http.post(
      base.resolve('api/sync'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode(SyncRequest(since: 0, changes: changes).toJson()),
    );
    expect(r.statusCode, 200);
  }

  SyncRecord record(String collection, String id, Map<String, Object?> data) =>
      SyncRecord(
        collection: collection,
        id: id,
        data: data,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  Future<void> shoppingList(String id, String name) => sync([
    record(Collections.shoppingLists, id, {'name': name}),
  ]);

  test('tasks and shopping lists appear as to-do lists', () async {
    await shoppingList('wocheneinkauf', 'Wocheneinkauf');
    final home = await dav('PROPFIND', 'dav/calendars/mama/');
    expect(home.statusCode, 207);
    expect(home.body, contains('/dav/calendars/mama/famio/'));
    expect(home.body, contains('/dav/calendars/mama/aufgaben/'));
    expect(home.body, contains('/dav/calendars/mama/einkauf-wocheneinkauf/'));
    expect(
      home.body,
      contains('<d:displayname>Famio-Aufgaben</d:displayname>'),
    );
    expect(home.body, contains('<d:displayname>Wocheneinkauf</d:displayname>'));
    expect(home.body, contains('<c:comp name="VTODO"/>'));
    expect(home.body, contains('<c:comp name="VEVENT"/>'));

    // A list that does not exist is not a collection.
    final missing = await dav(
      'PROPFIND',
      'dav/calendars/mama/einkauf-gibtsnicht/',
    );
    expect(missing.statusCode, 404);
  });

  test('a famio task is served as VTODO', () async {
    await sync([
      record(
        Collections.tasks,
        'muell',
        Task(
          id: 'muell',
          title: 'Müll rausbringen',
          notes: 'Gelbe Tonne',
          due: DateTime(2026, 10, 6),
          remindAt: DateTime.utc(2026, 10, 6, 5),
        ).toData(),
      ),
    ]);
    final list = await dav(
      'PROPFIND',
      'dav/calendars/mama/aufgaben/',
      headers: {'depth': '1'},
    );
    expect(list.body, contains('/dav/calendars/mama/aufgaben/muell.ics'));
    expect(list.body, contains('component=vtodo'));

    final get = await dav('GET', 'dav/calendars/mama/aufgaben/muell.ics');
    expect(get.statusCode, 200);
    expect(get.body, contains('BEGIN:VTODO'));
    expect(get.body, contains('SUMMARY:Müll rausbringen'));
    expect(get.body, contains('DESCRIPTION:Gelbe Tonne'));
    expect(get.body, contains('DUE;VALUE=DATE:20261006'));
    expect(get.body, contains('STATUS:NEEDS-ACTION'));
    expect(get.body, contains('TRIGGER;VALUE=DATE-TIME:20261006T050000Z'));

    // Events are not served from the task list and vice versa.
    final query = await dav(
      'REPORT',
      'dav/calendars/mama/aufgaben/',
      headers: {'depth': '1'},
      body:
          '<c:calendar-query xmlns:d="DAV:" '
          'xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/>'
          '</d:prop><c:filter><c:comp-filter name="VCALENDAR">'
          '<c:comp-filter name="VTODO"/></c:comp-filter></c:filter>'
          '</c:calendar-query>',
    );
    expect(query.body, contains('muell.ics'));
  });

  test(
    'a reminder from Apple Reminders becomes a task and keeps its extras',
    () async {
      final put = await dav(
        'PUT',
        'dav/calendars/mama/aufgaben/8F2A-REMINDER.ics',
        body: appleReminder,
        headers: {'if-none-match': '*'},
      );
      expect(put.statusCode, 201);
      final stored = app.records.get(Collections.tasks, '8F2A-REMINDER')!;
      final task = Task.fromRecord(stored);
      expect(task.title, 'Elternabend vorbereiten');
      expect(task.notes, 'Fragen sammeln');
      expect(task.due, DateTime(2026, 10, 7));
      expect(task.remindAt, DateTime.utc(2026, 10, 7, 15, 30).toLocal());
      expect(task.done, isFalse);

      // Famio has no priority or sort order, but writes them back, and the
      // due time while the day stays the same.
      final get = await dav(
        'GET',
        'dav/calendars/mama/aufgaben/8F2A-REMINDER.ics',
      );
      expect(get.body, contains('PRIORITY:1'));
      expect(get.body, contains('X-APPLE-SORT-ORDER:742991234'));
      expect(get.body, contains('DUE;TZID=Europe/Berlin:20261007T183000'));

      // Moved to another day in Famio: the old time no longer applies.
      final etag = get.headers['etag']!;
      await sync([
        record(
          Collections.tasks,
          '8F2A-REMINDER',
          SyncRecord.keepExternal(
            task.copyWith(due: DateTime(2026, 10, 8)).toData(),
            stored,
          ),
        ),
      ]);
      final moved = await dav(
        'GET',
        'dav/calendars/mama/aufgaben/8F2A-REMINDER.ics',
      );
      expect(moved.headers['etag'], isNot(etag));
      expect(moved.body, contains('DUE;VALUE=DATE:20261008'));
      expect(moved.body, contains('PRIORITY:1'));

      // Ticked off in Reminders.
      final done = await dav(
        'PUT',
        'dav/calendars/mama/aufgaben/8F2A-REMINDER.ics',
        body: appleReminder.replaceFirst(
          'STATUS:NEEDS-ACTION',
          'STATUS:COMPLETED\r\n'
              'COMPLETED:20261005T120000Z',
        ),
      );
      expect(done.statusCode, 204);
      final ticked = Task.fromRecord(
        app.records.get(Collections.tasks, '8F2A-REMINDER')!,
      );
      expect(ticked.done, isTrue);
      expect(ticked.completedAt, DateTime.utc(2026, 10, 5, 12));
    },
  );

  test('a repeating reminder repeats in Famio too', () async {
    final put = await dav(
      'PUT',
      'dav/calendars/mama/aufgaben/tonne.ics',
      body: reminder(
        'tonne',
        'Gelbe Tonne',
        extra: 'DUE;VALUE=DATE:20991006\r\nRRULE:FREQ=WEEKLY;INTERVAL=2\r\n',
      ),
    );
    expect(put.statusCode, 201);
    var task = Task.fromRecord(app.records.get(Collections.tasks, 'tonne')!);
    expect(task.repeat, TaskRepeat.weekly);
    expect(task.repeatEvery, 2);
    final get = await dav('GET', 'dav/calendars/mama/aufgaben/tonne.ics');
    expect(get.body, contains('RRULE:FREQ=WEEKLY;INTERVAL=2'));
    expect('RRULE'.allMatches(get.body), hasLength(1));

    // Ticked off in Reminders: open again, two weeks later.
    await dav(
      'PUT',
      'dav/calendars/mama/aufgaben/tonne.ics',
      body: reminder(
        'tonne',
        'Gelbe Tonne',
        extra:
            'DUE;VALUE=DATE:20991006\r\nRRULE:FREQ=WEEKLY;INTERVAL=2\r\n'
            'STATUS:COMPLETED\r\n',
      ),
    );
    task = Task.fromRecord(app.records.get(Collections.tasks, 'tonne')!);
    expect(task.done, isFalse);
    expect(task.due, DateTime(2099, 10, 20));

    // Ticked off through the app interface (e.g. Home Assistant).
    await sync([
      record(
        Collections.tasks,
        'tonne',
        task.copyWith(done: true, completedAt: DateTime.now()).toData(),
      ),
    ]);
    task = Task.fromRecord(app.records.get(Collections.tasks, 'tonne')!);
    expect(task.done, isFalse);
    expect(task.due, DateTime(2099, 11, 3));
  });

  test('a rule Famio cannot show is kept as it is', () async {
    await dav(
      'PUT',
      'dav/calendars/mama/aufgaben/sport.ics',
      body: reminder(
        'sport',
        'Sport',
        extra: 'RRULE:FREQ=WEEKLY;BYDAY=MO,TH\r\n',
      ),
    );
    final task = Task.fromRecord(app.records.get(Collections.tasks, 'sport')!);
    expect(task.repeat, isNull);
    final get = await dav('GET', 'dav/calendars/mama/aufgaben/sport.ics');
    expect(get.body, contains('RRULE:FREQ=WEEKLY;BYDAY=MO,TH'));
  });

  test(
    'assignee and visibility set in famio survive an edit in Reminders',
    () async {
      await sync([
        record(Collections.tasks, 'schuhe', {
          ...Task(
            id: 'schuhe',
            title: 'Schuhe kaufen',
            assigneeId: 'papa-id',
          ).toData(),
          SyncRecord.visibilityKey: null,
        }),
      ]);
      final put = await dav(
        'PUT',
        'dav/calendars/mama/aufgaben/schuhe.ics',
        body: reminder('schuhe', 'Winterschuhe kaufen'),
      );
      expect(put.statusCode, 204);
      final task = Task.fromRecord(
        app.records.get(Collections.tasks, 'schuhe')!,
      );
      expect(task.title, 'Winterschuhe kaufen');
      expect(task.assigneeId, 'papa-id');
    },
  );

  test(
    'shopping items: listed per list, added, ticked off and deleted',
    () async {
      await shoppingList('l1', 'Einkauf');
      await shoppingList('l2', 'Drogerie');
      await sync([
        record(
          Collections.shoppingItems,
          'milch',
          const ShoppingItem(
            id: 'milch',
            listId: 'l1',
            name: 'Milch',
            quantity: '2 l',
            category: 'Kühlregal',
          ).toData(),
        ),
        record(
          Collections.shoppingItems,
          'zahnpasta',
          const ShoppingItem(
            id: 'zahnpasta',
            listId: 'l2',
            name: 'Zahnpasta',
          ).toData(),
        ),
      ]);
      final list = await dav(
        'PROPFIND',
        'dav/calendars/mama/einkauf-l1/',
        headers: {'depth': '1'},
      );
      expect(list.body, contains('einkauf-l1/milch.ics'));
      expect(list.body, isNot(contains('zahnpasta')));
      final milk = await dav('GET', 'dav/calendars/mama/einkauf-l1/milch.ics');
      expect(milk.body, contains('SUMMARY:Milch'));
      expect(milk.body, contains('DESCRIPTION:2 l'));
      expect(milk.body, contains('CATEGORIES:Kühlregal'));
      // Not reachable through another list.
      expect(
        (await dav(
          'GET',
          'dav/calendars/mama/einkauf-l2/milch.ics',
        )).statusCode,
        404,
      );

      final added = await dav(
        'PUT',
        'dav/calendars/mama/einkauf-l1/BROT-1.ics',
        body: reminder('BROT-1', 'Brot', extra: 'DESCRIPTION:1 Laib\r\n'),
        headers: {'if-none-match': '*'},
      );
      expect(added.statusCode, 201);
      final bread = ShoppingItem.fromRecord(
        app.records.get(Collections.shoppingItems, 'BROT-1')!,
      );
      expect(bread.listId, 'l1');
      expect(bread.name, 'Brot');
      expect(bread.quantity, '1 Laib');

      final ticked = await dav(
        'PUT',
        'dav/calendars/mama/einkauf-l1/milch.ics',
        body: reminder('milch', 'Milch', extra: 'STATUS:COMPLETED\r\n'),
      );
      expect(ticked.statusCode, 204);
      final checked = ShoppingItem.fromRecord(
        app.records.get(Collections.shoppingItems, 'milch')!,
      );
      expect(checked.checked, isTrue);
      expect(checked.quantity, '');
      // The category set in Famio stays when Reminders sends none.
      expect(checked.category, 'Kühlregal');

      final deleted = await dav(
        'DELETE',
        'dav/calendars/mama/einkauf-l1/BROT-1.ics',
      );
      expect(deleted.statusCode, 204);
      expect(
        app.records.get(Collections.shoppingItems, 'BROT-1')!.deleted,
        isTrue,
      );
    },
  );

  test('to-do lists refuse events, the calendar refuses to-dos', () async {
    final event = await dav(
      'PUT',
      'dav/calendars/mama/aufgaben/termin.ics',
      body:
          'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:termin\r\n'
          'DTSTART:20261010T100000Z\r\nDTEND:20261010T110000Z\r\n'
          'SUMMARY:Termin\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n',
    );
    expect(event.statusCode, 403);
    expect(event.body, contains('nur Aufgaben'));
    final todo = await dav(
      'PUT',
      'dav/calendars/mama/famio/aufgabe.ics',
      body: reminder('aufgabe', 'Aufgabe'),
    );
    expect(todo.statusCode, 403);
    expect(app.records.get(Collections.tasks, 'aufgabe'), isNull);
  });

  test('sync-collection reports changed and deleted tasks', () async {
    await sync([
      record(
        Collections.tasks,
        't1',
        const Task(id: 't1', title: 'Eins').toData(),
      ),
    ]);
    final first = await dav(
      'REPORT',
      'dav/calendars/mama/aufgaben/',
      body:
          '<d:sync-collection xmlns:d="DAV:"><d:sync-token/>'
          '<d:prop><d:getetag/></d:prop></d:sync-collection>',
    );
    expect(first.body, contains('aufgaben/t1.ics'));
    final syncToken = RegExp(
      '<d:sync-token>([^<]+)</d:sync-token>',
    ).firstMatch(first.body)![1]!;

    await dav('DELETE', 'dav/calendars/mama/aufgaben/t1.ics');
    await sync([
      record(
        Collections.tasks,
        't2',
        const Task(id: 't2', title: 'Zwei').toData(),
      ),
    ]);
    final next = await dav(
      'REPORT',
      'dav/calendars/mama/aufgaben/',
      body:
          '<d:sync-collection xmlns:d="DAV:"><d:sync-token>$syncToken'
          '</d:sync-token><d:prop><d:getetag/></d:prop></d:sync-collection>',
    );
    expect(next.body, contains('aufgaben/t2.ics'));
    expect(
      next.body,
      contains(
        '<d:href>/dav/calendars/mama/aufgaben/t1.ics</d:href>'
        '<d:status>HTTP/1.1 404 Not Found</d:status>',
      ),
    );
  });
}
