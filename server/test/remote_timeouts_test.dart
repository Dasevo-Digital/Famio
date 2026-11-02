import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/api_exception.dart';
import 'package:famio_server/src/dav/dav_client.dart';
import 'package:famio_server/src/documents/paperless.dart';
import 'package:famio_server/src/remote_stream.dart';
import 'package:famio_server/src/updates/app_updates.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Requests to other services end even when the other side stops answering.
void main() {
  const short = Duration(milliseconds: 100);

  group('getStreamed', () {
    test('no headers: gives up after the answer time', () async {
      final client = MockClient.streaming(
        (_, _) => Completer<http.StreamedResponse>().future,
      );
      final watch = Stopwatch()..start();
      await expectLater(
        getStreamed(client, Uri.parse('https://x.test/a'), answer: short),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a body that stops: ends with an error after the pause', () async {
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final client = MockClient.streaming((_, _) async {
        body.add([1, 2]);
        return http.StreamedResponse(body.stream, 200);
      });
      final response = await getStreamed(
        client,
        Uri.parse('https://x.test/a'),
        pause: short,
      );
      await expectLater(
        response.stream.toList(),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  test('a calendar server that stops sending: a timeout, not a hang', () async {
    final body = StreamController<List<int>>();
    addTearDown(body.close);
    String? method;
    String? sent;
    final client = MockClient.streaming((request, bytes) async {
      method = request.method;
      sent = await bytes.bytesToString();
      body.add(utf8.encode('<?xml version="1.0"?><d:multistatus'));
      return http.StreamedResponse(body.stream, 207);
    });
    final dav = DavClient(client, username: 'u', password: 'p', timeout: short);
    await expectLater(
      dav
          .send(
            'PROPFIND',
            Uri.parse('https://cal.test/'),
            body: '<propfind/>',
            depth: '0',
          )
          .timeout(const Duration(seconds: 10)),
      throwsA(
        isA<DavException>().having(
          (e) => e.message,
          'message',
          contains('Zeitüberschreitung bei cal.test'),
        ),
      ),
    );
    expect((method, sent), ('PROPFIND', '<propfind/>'));
  });

  test('a package download that hangs does not block later attempts', () async {
    const version = '9.9.9';
    final pair = await Ed25519().newKeyPair();
    final key = base64Encode((await pair.extractPublicKey()).bytes);
    final files = {
      for (final p in AppPlatform.values)
        p.fileName(version): utf8.encode('Paket ${p.name}'),
    };
    final sums = [
      for (final e in files.entries)
        '${await sha256Hex(Stream.value(e.value))}  ${e.key}\n',
    ].join();
    final signature = base64Encode(
      (await Ed25519().sign(utf8.encode(sums), keyPair: pair)).bytes,
    );
    var hanging = true;
    final client = MockClient.streaming((request, _) async {
      http.StreamedResponse ok(List<int> body) =>
          http.StreamedResponse(Stream.value(body), 200);
      if (request.url.host == 'api.github.com') {
        return ok(
          utf8.encode(
            jsonEncode({
              'assets': [
                for (final name in [
                  ...files.keys,
                  'SHA256SUMS.txt',
                  'SHA256SUMS.txt.sig',
                ])
                  {
                    'name': name,
                    'browser_download_url': 'https://dl.test/$name',
                  },
              ],
            }),
          ),
        );
      }
      final name = request.url.pathSegments.last;
      if (name == 'SHA256SUMS.txt') return ok(utf8.encode(sums));
      if (name == 'SHA256SUMS.txt.sig') return ok(utf8.encode(signature));
      // A connection that never answers, as during an outage.
      if (hanging) return Completer<http.StreamedResponse>().future;
      return ok(files[name]!);
    });
    final db = sqlite3.openInMemory()
      ..execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)');
    final dir = Directory.systemTemp.createTempSync('famio_updates_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final updates = AppUpdates(
      db: db,
      dir: dir.path,
      version: version,
      client: client,
      publicKey: key,
      retrySoon: const Duration(hours: 1),
      answerTimeout: short,
    );
    addTearDown(updates.stop);

    final info = await updates
        .configure(enabled: true)
        .timeout(const Duration(seconds: 10));
    expect(info['error'], contains('TimeoutException'));

    hanging = false;
    await updates.prepare().timeout(const Duration(seconds: 10));
    for (final p in AppPlatform.values) {
      expect(updates.package(p), isNotNull, reason: p.name);
    }
  });

  group('Paperless-ngx', () {
    late FamioServerApp app;
    setUp(() => app = FamioServerApp.inMemory());
    tearDown(() => app.close());

    http.Response json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );

    PaperlessLink link(http.Client client) => PaperlessLink(
      db: app.db,
      records: app.records,
      accounts: app.accounts,
      onChanged: () {},
      client: client,
      answerTimeout: short,
      pauseTimeout: short,
    );

    void connectAs(PaperlessLink paperless) => app.db
        .execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', [
          'paperless',
          jsonEncode(
            const PaperlessConfig(url: 'http://paperless.test', token: 't'),
          ),
        ]);

    test('a list that does not answer ends the sync with a hint', () async {
      final paperless = link(
        MockClient.streaming(
          (_, _) => Completer<http.StreamedResponse>().future,
        ),
      );
      connectAs(paperless);
      await paperless.sync().timeout(const Duration(seconds: 10));
      expect(
        paperless.info()['lastError'],
        contains('Keine Verbindung zu Paperless-ngx'),
      );
    });

    test('more than 50 pages: the newest are shown, with a hint', () async {
      var page = 0;
      final paperless = link(
        MockClient((request) async {
          switch (request.url.path) {
            case '/api/tags/':
              return json({
                'next': null,
                'results': [
                  {'id': 7, 'name': 'Familie'},
                ],
              });
            case '/api/documents/':
              page++;
              return json({
                'next': 'http://paperless.test/api/documents/?page=${page + 1}',
                'results': [
                  {
                    'id': page,
                    'title': 'Dokument $page',
                    'created': '2026-01-01',
                    'modified': '2026-01-01T00:00:00Z',
                    'original_file_name': 'd.pdf',
                    'mime_type': 'application/pdf',
                  },
                ],
              });
          }
          return json({'next': null, 'results': <Object>[]});
        }),
      );
      connectAs(paperless);
      await paperless.sync();
      final info = paperless.info();
      expect((info['count'], info['limited']), (50, true));
      expect(page, 50);
    });

    test('a file that does not come: 502 instead of waiting', () async {
      final mama = app.accounts.create(username: 'mama', displayName: 'Mama');
      var hang = false;
      final paperless = link(
        MockClient.streaming((request, _) async {
          if (hang) return Completer<http.StreamedResponse>().future;
          final body = switch (request.url.path) {
            '/api/tags/' => {
              'next': null,
              'results': [
                {'id': 7, 'name': 'Familie'},
              ],
            },
            '/api/documents/' => {
              'next': null,
              'results': [
                {
                  'id': 11,
                  'title': 'Police',
                  'created': '2026-01-15',
                  'modified': '2026-02-01T10:00:00Z',
                  'original_file_name': 'police.pdf',
                  'mime_type': 'application/pdf',
                },
              ],
            },
            _ => {'next': null, 'results': <Object>[]},
          };
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(body))),
            200,
          );
        }),
      );
      connectAs(paperless);
      await paperless.sync();
      final file = FileRef.fromJson(
        app.records.get(Collections.externalDocuments, 'pl-11')!.data['file'],
      )!;
      hang = true;
      await expectLater(
        paperless
            .download(file.id, mama.id)
            .timeout(const Duration(seconds: 10)),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 502)),
      );
    });
  });
}
