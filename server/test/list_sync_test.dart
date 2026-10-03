import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/api_exception.dart';
import 'package:famio_server/src/lists/list_provider.dart';
import 'package:famio_server/src/lists/list_sync.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Another app's list kept in memory; counts the calls Famio makes.
class FakeProvider implements ListProvider {
  FakeProvider({this.kind = 'mstodo', this.oneEntryPerTitle = false});

  @override
  final String kind;
  @override
  final bool oneEntryPerTitle;
  @override
  bool get hasDueDates => !oneEntryPerTitle;
  @override
  Map<String, Object?> get credentials => const {'token': 'x'};

  final entries = <String, RemoteItem>{};
  var writes = 0;
  var _next = 0;

  RemoteItem add(String title, {String note = '', bool done = false}) {
    final id = oneEntryPerTitle ? title : 'r${_next++}';
    return entries[id] = RemoteItem(
      id: id,
      title: title,
      note: note,
      done: done,
      modified: oneEntryPerTitle ? null : DateTime.now(),
    );
  }

  @override
  Future<List<RemoteList>> lists() async => const [
    RemoteList(id: 'L', name: 'Liste'),
  ];

  @override
  Future<List<RemoteItem>> items(String listId) async => [...entries.values];

  @override
  Future<RemoteItem> create(String listId, ItemDraft item) async {
    writes++;
    final id = oneEntryPerTitle ? item.title : 'r${_next++}';
    return entries[id] = RemoteItem(
      id: id,
      title: item.title,
      note: item.note,
      done: item.done,
      due: item.due,
      modified: oneEntryPerTitle ? null : DateTime.now(),
    );
  }

  @override
  Future<void> update(
    String listId,
    RemoteItem previous,
    ItemDraft item,
  ) async {
    writes++;
    if (oneEntryPerTitle) entries.remove(previous.id);
    final id = oneEntryPerTitle ? item.title : previous.id;
    entries[id] = RemoteItem(
      id: id,
      title: item.title,
      note: item.note,
      done: item.done,
      due: item.due,
      modified: oneEntryPerTitle ? null : DateTime.now(),
    );
  }

  @override
  Future<void> delete(String listId, RemoteItem item) async {
    writes++;
    entries.remove(item.id);
  }
}

void main() {
  late FamioServerApp app;
  late String mama;
  late FakeProvider fake;
  late ListSync lists;
  var enabled = true;

  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts
        .create(
          username: 'mama',
          displayName: 'Mama',
          passwordHash: 'x',
          isAdmin: true,
        )
        .id;
    fake = FakeProvider();
    enabled = true;
    lists = ListSync(
      db: app.db,
      records: app.records,
      timeZone: () => 'Europe/Berlin',
      onChanged: () {},
      enabled: () => enabled,
      providerFor: (_, _) => fake,
    );
  });

  tearDown(() => app.close());

  String account({String provider = 'mstodo'}) {
    const id = 'acc';
    app.db.execute(
      'INSERT INTO list_accounts (id, user_id, provider, name, credentials,'
      ' created_at) VALUES (?, ?, ?, ?, ?, 0)',
      [id, mama, provider, 'Test', jsonEncode({})],
    );
    return id;
  }

  /// Like the app: always after the stored version.
  void write(String collection, String id, Map<String, Object?> data) {
    final previous = app.records.get(collection, id)?.updatedAt ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(
      app.records.writeAs(mama, [
        SyncRecord(
          collection: collection,
          id: id,
          data: data,
          updatedAt: now > previous ? now : previous + 1,
        ),
      ]),
      isEmpty,
    );
  }

  void delete(String collection, String id) {
    final r = app.records.get(collection, id)!;
    app.records.writeAs(mama, [
      SyncRecord(
        collection: collection,
        id: id,
        data: const {},
        deleted: true,
        updatedAt: r.updatedAt + 1,
      ),
    ]);
  }

  List<Task> tasks() => [
    for (final r in app.records.all(Collections.tasks)) Task.fromRecord(r),
  ];

  test('first sync brings both sides together, then stays quiet', () async {
    final id = account();
    write(
      Collections.tasks,
      't1',
      Task(id: 't1', title: 'Müll', due: DateTime(2026, 10, 6)).toData(),
    );
    fake.add('Arzt anrufen', note: 'vor 12 Uhr');
    lists.setLinks(id, mama, [
      {'famioList': 'tasks', 'remoteList': 'L', 'remoteName': 'Aufgaben'},
    ]);
    await lists.syncAccount(id);

    expect(fake.entries.values.map((i) => i.title), contains('Müll'));
    expect(
      fake.entries.values.firstWhere((i) => i.title == 'Müll').due,
      DateTime(2026, 10, 6),
    );
    final arzt = tasks().firstWhere((t) => t.title == 'Arzt anrufen');
    expect(arzt.notes, 'vor 12 Uhr');

    final writes = fake.writes;
    await lists.syncAccount(id);
    expect(fake.writes, writes, reason: 'no echo');
    expect(tasks(), hasLength(2));
    expect(lists.accounts(mama).single['lastError'], isNull);
  });

  test('changes and deletions travel in both directions', () async {
    final id = account();
    write(
      Collections.tasks,
      't1',
      const Task(id: 't1', title: 'Eins').toData(),
    );
    lists.setLinks(id, mama, [
      {'famioList': 'tasks', 'remoteList': 'L'},
    ]);
    await lists.syncAccount(id);
    final remoteId = fake.entries.keys.single;

    // Ticked off there.
    final there = fake.entries[remoteId]!;
    fake.entries[remoteId] = RemoteItem(
      id: remoteId,
      title: there.title,
      done: true,
      modified: DateTime.now().add(const Duration(seconds: 1)),
    );
    await lists.syncAccount(id);
    expect(tasks().single.done, isTrue);
    expect(tasks().single.completedAt, isNotNull);

    // Renamed in Famio.
    write(
      Collections.tasks,
      't1',
      Task.fromRecord(
        app.records.get(Collections.tasks, 't1')!,
      ).copyWith(title: 'Eins (neu)').toData(),
    );
    await lists.syncAccount(id);
    expect(fake.entries[remoteId]!.title, 'Eins (neu)');

    // Deleted in Famio.
    delete(Collections.tasks, 't1');
    await lists.syncAccount(id);
    expect(fake.entries, isEmpty);

    // Deleted there.
    write(
      Collections.tasks,
      't2',
      const Task(id: 't2', title: 'Zwei').toData(),
    );
    await lists.syncAccount(id);
    fake.entries.clear();
    await lists.syncAccount(id);
    expect(app.records.get(Collections.tasks, 't2')!.deleted, isTrue);
  });

  test('when both sides changed, the newer change wins', () async {
    final id = account();
    write(Collections.tasks, 't1', const Task(id: 't1', title: 'Alt').toData());
    lists.setLinks(id, mama, [
      {'famioList': 'tasks', 'remoteList': 'L'},
    ]);
    await lists.syncAccount(id);
    final remoteId = fake.entries.keys.single;

    write(
      Collections.tasks,
      't1',
      const Task(id: 't1', title: 'Famio').toData(),
    );
    fake.entries[remoteId] = RemoteItem(
      id: remoteId,
      title: 'Dort, später',
      modified: DateTime.now().add(const Duration(minutes: 1)),
    );
    await lists.syncAccount(id);
    expect(tasks().single.title, 'Dort, später');

    fake.entries[remoteId] = RemoteItem(
      id: remoteId,
      title: 'Dort, früher',
      modified: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    write(
      Collections.tasks,
      't1',
      const Task(id: 't1', title: 'Famio, später').toData(),
    );
    await lists.syncAccount(id);
    expect(tasks().single.title, 'Famio, später');
    expect(fake.entries[remoteId]!.title, 'Famio, später');
  });

  test('Bring!: one shopping list, same names are paired', () async {
    fake = FakeProvider(kind: 'bring', oneEntryPerTitle: true);
    final id = account(provider: 'bring');
    write(Collections.shoppingLists, 'l1', {'name': 'Einkauf'});
    write(Collections.shoppingLists, 'l2', {'name': 'Drogerie'});
    write(
      Collections.shoppingItems,
      'milch',
      const ShoppingItem(
        id: 'milch',
        listId: 'l1',
        name: 'Milch',
        quantity: '2 l',
      ).toData(),
    );
    write(
      Collections.shoppingItems,
      'seife',
      const ShoppingItem(id: 'seife', listId: 'l2', name: 'Seife').toData(),
    );
    fake.add('Milch', note: '1 l');
    fake.add('Brot');

    expect(
      () => lists.setLinks(id, mama, [
        {'famioList': 'tasks', 'remoteList': 'L'},
      ]),
      throwsA(isA<ApiException>()),
    );
    lists.setLinks(id, mama, [
      {'famioList': 'l1', 'remoteList': 'L'},
    ]);
    await lists.syncAccount(id);

    // One Milch, with Famio's quantity; Brot came over; Seife stays out.
    expect(fake.entries.keys, unorderedEquals(['Milch', 'Brot']));
    expect(fake.entries['Milch']!.note, '2 l');
    final items = [
      for (final r in app.records.all(Collections.shoppingItems))
        ShoppingItem.fromRecord(r),
    ];
    expect(items.where((i) => i.name == 'Milch'), hasLength(1));
    expect(items.firstWhere((i) => i.name == 'Brot').listId, 'l1');

    // Ticked off in Famio: moves to "recently" there.
    write(
      Collections.shoppingItems,
      'milch',
      const ShoppingItem(
        id: 'milch',
        listId: 'l1',
        name: 'Milch',
        quantity: '2 l',
        checked: true,
      ).toData(),
    );
    await lists.syncAccount(id);
    expect(fake.entries['Milch']!.done, isTrue);
  });

  test('switched off by the family: nothing happens', () async {
    final id = account();
    write(
      Collections.tasks,
      't1',
      const Task(id: 't1', title: 'Eins').toData(),
    );
    lists.setLinks(id, mama, [
      {'famioList': 'tasks', 'remoteList': 'L'},
    ]);
    enabled = false;
    await lists.syncAccount(id);
    expect(fake.entries, isEmpty);
    expect(
      () => lists.setLinks(id, mama, const []),
      throwsA(isA<ApiException>()),
    );
  });

  group('over the API with the real providers', () {
    late FamioServerApp server;
    late Handler handler;
    late String token;
    final bring = <String, Map<String, String>>{};
    final graph = <String, Map<String, Object?>>{};
    var graphPolls = 0;

    Future<Response> call(String method, String path, [Object? body]) async =>
        handler(
          Request(
            method,
            Uri.parse('http://famio.test/$path'),
            headers: {
              'authorization': 'Bearer $token',
              'content-type': 'application/json',
            },
            body: body == null ? null : jsonEncode(body),
          ),
        );

    setUp(() async {
      bring
        ..clear()
        ..['Brot'] = {'specification': '', 'list': 'purchase'};
      graph.clear();
      graphPolls = 0;
      final client = MockClient((request) async {
        final url = request.url;
        http.Response json(Object body, [int status = 200]) => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        );
        if (url.host == 'api.getbring.com') {
          expect(request.headers['X-BRING-API-KEY'], isNotEmpty);
          final path = url.path;
          if (path.endsWith('/bringauth')) {
            final form = Uri.splitQueryString(request.body);
            if (form['password'] != 'richtig') return json({}, 401);
            return json({
              'uuid': 'user-1',
              'access_token': 'tok',
              'refresh_token': 'ref',
              'expires_in': 3600,
            });
          }
          expect(request.headers['Authorization'], 'Bearer tok');
          if (path.endsWith('/bringusers/user-1/lists')) {
            return json({
              'lists': [
                {'listUuid': 'B1', 'name': 'Zuhause'},
              ],
            });
          }
          if (path.endsWith('/bringlists/B1') && request.method == 'GET') {
            List<Map<String, String>> of(String list) => [
              for (final e in bring.entries)
                if (e.value['list'] == list)
                  {'itemId': e.key, 'specification': e.value['specification']!},
            ];
            return json({
              'items': {'purchase': of('purchase'), 'recently': of('recently')},
            });
          }
          if (path.endsWith('/bringlists/B1/items')) {
            final changes =
                (jsonDecode(request.body) as Map)['changes'] as List;
            for (final c in changes.cast<Map>()) {
              final name = c['itemId'] as String;
              switch (c['operation']) {
                case 'REMOVE':
                  bring.remove(name);
                case 'TO_PURCHASE':
                  bring[name] = {
                    'specification': c['spec'],
                    'list': 'purchase',
                  };
                case 'TO_RECENTLY':
                  bring[name] = {
                    'specification': c['spec'],
                    'list': 'recently',
                  };
              }
            }
            return http.Response('', 204);
          }
        }
        if (url.host == 'login.microsoftonline.com') {
          final form = Uri.splitQueryString(request.body);
          if (url.path.endsWith('/devicecode')) {
            expect(form['scope'], contains('Tasks.ReadWrite'));
            return json({
              'device_code': 'dev',
              'user_code': 'ABCD-1234',
              'verification_uri': 'https://microsoft.com/devicelogin',
              'expires_in': 900,
              'interval': 5,
            });
          }
          if (form['grant_type']!.endsWith('device_code')) {
            if (graphPolls++ == 0) {
              return json({'error': 'authorization_pending'}, 400);
            }
            return json({
              'access_token': 'ms',
              'refresh_token': 'msref',
              'expires_in': 3600,
            });
          }
        }
        if (url.host == 'graph.microsoft.com') {
          expect(request.headers['authorization'], 'Bearer ms');
          final path = url.path.replaceFirst('/v1.0/', '');
          if (path == 'me/todo/lists') {
            return json({
              'value': [
                {'id': 'M1', 'displayName': 'Aufgaben'},
              ],
            });
          }
          if (path == 'me/todo/lists/M1/tasks' && request.method == 'GET') {
            // Two pages, as Graph sends long lists.
            final all = graph.entries.toList();
            final page = url.queryParameters[r'$skip'] == '1' ? 1 : 0;
            return json({
              'value': [
                for (final e in all.skip(page).take(1))
                  {'id': e.key, ...e.value},
              ],
              if (page == 0 && all.length > 1)
                '@odata.nextLink':
                    'https://graph.microsoft.com/v1.0/me/todo/lists/M1/tasks?\$skip=1',
            });
          }
          if (path == 'me/todo/lists/M1/tasks' && request.method == 'POST') {
            final id = 'g${graph.length}';
            final body = (jsonDecode(request.body) as Map)
                .cast<String, Object?>();
            graph[id] = {
              ...body,
              'lastModifiedDateTime': DateTime.now().toUtc().toIso8601String(),
            };
            return json({'id': id, ...graph[id]!}, 201);
          }
        }
        return http.Response('unexpected ${request.method} $url', 500);
      });
      server = FamioServerApp.inMemory(httpClient: client);
      handler = server.handler;
      final setup = await handler(
        Request(
          'POST',
          Uri.parse('http://famio.test/api/auth/setup'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'username': 'mama',
            'password': 'geheim123',
            'setupCode': server.setupCode,
          }),
        ),
      );
      token =
          (jsonDecode(await setup.readAsString()) as Map)['token'] as String;
    });

    tearDown(() => server.close());

    test('Bring!: sign in, link a list, sync both ways', () async {
      final wrong = await call('POST', 'api/lists/bring', {
        'email': 'mama@example.org',
        'password': 'falsch',
      });
      expect(wrong.statusCode, 400);

      final connected = await call('POST', 'api/lists/bring', {
        'email': 'mama@example.org',
        'password': 'richtig',
      });
      expect(connected.statusCode, 201);
      final account = jsonDecode(await connected.readAsString()) as Map;
      final id = account['id'] as String;
      // Only tokens are kept, never the password.
      final stored =
          server.db
                  .select('SELECT credentials FROM list_accounts')
                  .single['credentials']
              as String;
      expect(stored, isNot(contains('richtig')));

      final remote = await call('GET', 'api/lists/accounts/$id/remote');
      expect(await remote.readAsString(), contains('Zuhause'));

      server.records.writeAs(
        (account.isEmpty ? '' : server.accounts.members().single.id),
        [
          SyncRecord(
            collection: Collections.shoppingLists,
            id: 'l1',
            data: const {'name': 'Einkauf'},
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
          SyncRecord(
            collection: Collections.shoppingItems,
            id: 'milch',
            data: const ShoppingItem(
              id: 'milch',
              listId: 'l1',
              name: 'Milch',
              quantity: '2 l',
            ).toData(),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      );
      final linked = await call('PUT', 'api/lists/accounts/$id/links', {
        'links': [
          {'famioList': 'l1', 'remoteList': 'B1', 'remoteName': 'Zuhause'},
        ],
      });
      expect(linked.statusCode, 200);
      final body = jsonDecode(await linked.readAsString()) as Map;
      expect((body['account'] as Map)['lastError'], isNull);
      expect(bring['Milch'], {'specification': '2 l', 'list': 'purchase'});
      expect(
        server.records
            .all(Collections.shoppingItems)
            .map((r) => r.data['name']),
        contains('Brot'),
      );

      final gone = await call('DELETE', 'api/lists/accounts/$id');
      expect(gone.statusCode, 200);
      expect(server.db.select('SELECT * FROM list_items'), isEmpty);
    });

    test('Microsoft To Do: device code sign-in and paged lists', () async {
      final bad = await call('POST', 'api/lists/microsoft', {
        'clientId': 'keine-id',
      });
      expect(bad.statusCode, 400);

      final start = await call('POST', 'api/lists/microsoft', {
        'clientId': '11111111-2222-3333-4444-555555555555',
      });
      final flow = jsonDecode(await start.readAsString()) as Map;
      expect(flow['userCode'], 'ABCD-1234');

      final pending = await call('POST', 'api/lists/microsoft/poll', {
        'flow': flow['flow'],
      });
      expect(jsonDecode(await pending.readAsString()), {'status': 'pending'});
      final done =
          jsonDecode(
                await (await call('POST', 'api/lists/microsoft/poll', {
                  'flow': flow['flow'],
                })).readAsString(),
              )
              as Map;
      expect(done['status'], 'done');
      final id = (done['account'] as Map)['id'] as String;

      graph['a'] = {'title': 'Steuer', 'status': 'notStarted'};
      graph['b'] = {
        'title': 'Reifen wechseln',
        'status': 'completed',
        'dueDateTime': {
          'dateTime': '2026-10-20T00:00:00.0000000',
          'timeZone': 'UTC',
        },
      };
      server.records.writeAs(server.accounts.members().single.id, [
        SyncRecord(
          collection: Collections.tasks,
          id: 't1',
          data: Task(
            id: 't1',
            title: 'Kita-Anmeldung',
            due: DateTime(2026, 11, 2),
          ).toData(),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
      final linked = await call('PUT', 'api/lists/accounts/$id/links', {
        'links': [
          {'famioList': 'tasks', 'remoteList': 'M1'},
        ],
      });
      expect(
        ((jsonDecode(await linked.readAsString()) as Map)['account']
            as Map)['lastError'],
        isNull,
      );
      final tasks = [
        for (final r in server.records.all(Collections.tasks))
          Task.fromRecord(r),
      ];
      expect(
        tasks.map((t) => t.title),
        containsAll(['Steuer', 'Reifen wechseln']),
      );
      final tyres = tasks.firstWhere((t) => t.title == 'Reifen wechseln');
      expect(tyres.done, isTrue);
      expect(tyres.due, DateTime(2026, 10, 20));
      final sent = graph.values.firstWhere(
        (t) => t['title'] == 'Kita-Anmeldung',
      );
      expect((sent['dueDateTime'] as Map)['dateTime'], '2026-11-02T00:00:00');
      expect((sent['dueDateTime'] as Map)['timeZone'], 'Europe/Berlin');
    });
  });
}
