import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/lists/list_sync.dart';
import 'package:famio_server/src/lists/provider_http.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderHttpClient', () {
    test('a hanging request is aborted and its connection closed', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = <Socket>[];
      final closed = Completer<void>();
      server.listen((socket) {
        accepted.add(socket);
        // Reads the request and never answers.
        socket.listen((_) {}, onDone: closed.complete, onError: (_) {});
      });
      final client = ProviderHttpClient(
        ProviderHttpClient.connecting(const Duration(seconds: 5)),
        timeout: const Duration(milliseconds: 300),
        retryDelay: Duration.zero,
      );
      addTearDown(client.close);

      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:${server.port}/lists')),
        throwsA(isA<TimeoutException>()),
      );
      // The connection is gone, not left open behind an abandoned future.
      await closed.future.timeout(const Duration(seconds: 5));
      // An answer that did not come in time is not asked for again.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(accepted, hasLength(1));
    });

    test(
      'a reading request is repeated once after a connection failure',
      () async {
        var calls = 0;
        final client = ProviderHttpClient(
          MockClient((request) async {
            if (calls++ == 0) {
              throw http.ClientException(
                'Connection reset by peer',
                request.url,
              );
            }
            return http.Response('{"lists": []}', 200);
          }),
          timeout: const Duration(seconds: 5),
          retryDelay: Duration.zero,
        );
        final response = await client.get(
          Uri.parse('https://bring.test/lists'),
        );
        expect(response.statusCode, 200);
        expect(response.body, '{"lists": []}');
        expect(calls, 2);
      },
    );

    test('a second connection failure is reported', () async {
      var calls = 0;
      final client = ProviderHttpClient(
        MockClient((request) async {
          calls++;
          throw http.ClientException('Network is unreachable', request.url);
        }),
        timeout: const Duration(seconds: 5),
        retryDelay: Duration.zero,
      );
      await expectLater(
        client.put(Uri.parse('https://bring.test/items'), body: '{}'),
        throwsA(isA<http.ClientException>()),
      );
      expect(calls, 2);
    });

    test('sign-ins and new entries are never sent twice', () async {
      var calls = 0;
      final client = ProviderHttpClient(
        MockClient((request) async {
          calls++;
          throw http.ClientException('Connection reset by peer', request.url);
        }),
        timeout: const Duration(seconds: 5),
        retryDelay: Duration.zero,
      );
      await expectLater(
        client.post(Uri.parse('https://bring.test/auth'), body: {'a': 'b'}),
        throwsA(isA<http.ClientException>()),
      );
      expect(calls, 1);
    });

    test('the request arrives unchanged', () async {
      late http.Request seen;
      final client = ProviderHttpClient(
        MockClient((request) async {
          seen = request;
          return http.Response('', 204);
        }),
        timeout: const Duration(seconds: 5),
      );
      await client.post(
        Uri.parse('https://bring.test/auth'),
        headers: {'X-BRING-CLIENT': 'webApp'},
        body: {'email': 'a@example.org'},
      );
      expect(seen.method, 'POST');
      expect(seen.headers['X-BRING-CLIENT'], 'webApp');
      expect(seen.headers['content-type'], contains('form-urlencoded'));
      expect(seen.body, 'email=a%40example.org');
    });

    test('an answer over the limit is refused', () async {
      final client = ProviderHttpClient(
        MockClient((request) async => http.Response('x' * 2048, 200)),
        timeout: const Duration(seconds: 5),
        maxResponseBytes: 1024,
      );
      await expectLater(
        client.get(Uri.parse('https://bring.test/lists')),
        throwsA(isA<TransferTooLarge>()),
      );
    });
  });

  group('list sync over HTTP', () {
    late FamioServerApp app;
    late String mama;
    final log = <String>[];

    setUp(() {
      log.clear();
      app = FamioServerApp.inMemory();
      mama = app.accounts.create(username: 'mama', displayName: 'Mama').id;
      app.records.writeAs(mama, [
        SyncRecord(
          collection: Collections.shoppingLists,
          id: 'l1',
          data: const {'name': 'Einkauf'},
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
    });
    tearDown(() => app.close());

    ListSync bringSync(
      Future<http.Response> Function(http.Request) answer, {
      Duration requestTimeout = const Duration(seconds: 5),
    }) {
      final lists = ListSync(
        db: app.db,
        records: app.records,
        timeZone: () => 'Europe/Berlin',
        onChanged: () {},
        enabled: () => true,
        client: MockClient(answer),
        requestTimeout: requestTimeout,
        retryDelay: Duration.zero,
        log: log.add,
      );
      app.db.execute(
        'INSERT INTO list_accounts (id, user_id, provider, name, credentials,'
        ' created_at) VALUES (?, ?, ?, ?, ?, 0)',
        [
          'acc',
          mama,
          'bring',
          'Bring!',
          jsonEncode({
            'user': 'user-1',
            'token': 'tok',
            'refresh': 'ref',
            'expires': DateTime.now()
                .add(const Duration(days: 1))
                .millisecondsSinceEpoch,
          }),
        ],
      );
      lists.setLinks('acc', mama, [
        {'famioList': 'l1', 'remoteList': 'B1', 'remoteName': 'Zuhause'},
      ]);
      return lists;
    }

    http.Response bread() => http.Response(
      jsonEncode({
        'items': {
          'purchase': [
            {'itemId': 'Brot', 'specification': ''},
          ],
          'recently': [],
        },
      }),
      200,
    );

    test('a dropped connection to Bring! is tried again', () async {
      var reads = 0;
      final lists = bringSync((request) async {
        if (request.method != 'GET') return http.Response('', 204);
        if (reads++ == 0) {
          throw http.ClientException('Connection reset by peer', request.url);
        }
        return bread();
      });

      await lists.syncAccount('acc');

      expect(reads, 2);
      expect(lists.accounts(mama).single['lastError'], isNull);
      expect(
        app.records.all(Collections.shoppingItems).map((r) => r.data['name']),
        ['Brot'],
      );
    });

    test('Bring! out of reach is no connection, not a slow answer', () async {
      var reads = 0;
      final lists = bringSync((request) async {
        reads++;
        throw http.ClientException('Network is unreachable', request.url);
      });

      await lists.syncAccount('acc');

      expect(reads, 2);
      expect(
        lists.accounts(mama).single['lastError'],
        'Keine Verbindung zu Bring!.',
      );
      // The cause stays in the server log.
      expect(
        log.single,
        contains('Keine Verbindung zu Bring!. (Network is unreachable)'),
      );
    });

    test('an answer that does not come is reported as such', () async {
      var reads = 0;
      final lists = bringSync((request) {
        reads++;
        return Completer<http.Response>().future;
      }, requestTimeout: const Duration(milliseconds: 100));

      await lists.syncAccount('acc');

      expect(reads, 1);
      expect(
        lists.accounts(mama).single['lastError'],
        'Bring! antwortet nicht rechtzeitig.',
      );
    });

    test('connecting a Microsoft account survives a network failure', () async {
      var polls = 0;
      final lists = ListSync(
        db: app.db,
        records: app.records,
        timeZone: () => 'Europe/Berlin',
        onChanged: () {},
        enabled: () => true,
        retryDelay: Duration.zero,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/devicecode')) {
            return http.Response(
              jsonEncode({'device_code': 'dev', 'user_code': 'AB-12'}),
              200,
            );
          }
          if (polls++ == 0) {
            throw http.ClientException('Network is unreachable', request.url);
          }
          return http.Response(
            jsonEncode({
              'access_token': 'ms',
              'refresh_token': 'msref',
              'expires_in': 3600,
            }),
            200,
          );
        }),
      );
      final flow =
          (await lists.startMicrosoft(
                mama,
                clientId: '11111111-2222-3333-4444-555555555555',
              ))['flow']
              as String;
      await expectLater(
        lists.pollMicrosoft(mama, flow),
        throwsA(
          isA<Object>().having(
            (e) => '$e',
            'error',
            contains('Keine Verbindung zu Microsoft To Do.'),
          ),
        ),
      );
      // The member's app asks again and the sign-in completes.
      expect((await lists.pollMicrosoft(mama, flow))['status'], 'done');
    });
  });
}
