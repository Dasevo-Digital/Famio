import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String token;
  late List<Map<String, Object?>> documents;
  final asked = <String>[];

  /// Paperless-ngx as it answers (API version 10).
  final paperless = MockClient((request) async {
    asked.add('${request.method} ${request.url.path}');
    // No pinned API version, which Paperless-ngx refuses once it drops it.
    expect(request.headers['accept'], 'application/json');
    http.Response json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );
    if (request.headers['authorization'] != 'Token lesen') {
      return json({'detail': 'Invalid token.'}, 401);
    }
    Map<String, Object?> page(List<Object> results) => {
      'count': results.length,
      'next': null,
      'results': results,
    };
    switch (request.url.path) {
      case '/api/tags/':
        expect(request.url.queryParameters['name__iexact'], 'Familie');
        return json(
          page([
            {'id': 7, 'name': 'Familie'},
          ]),
        );
      case '/api/documents/':
        expect(request.url.queryParameters['tags__id__all'], '7');
        return json(page(documents));
      case '/api/correspondents/':
        return json(
          page([
            {'id': 3, 'name': 'HUK-Coburg'},
          ]),
        );
      case '/api/document_types/':
        return json(
          page([
            {'id': 4, 'name': 'Versicherungspolice'},
          ]),
        );
      case '/api/custom_fields/':
        return json(
          page([
            {'id': 1, 'name': 'Notiz', 'data_type': 'string'},
            {'id': 2, 'name': 'Ablaufdatum', 'data_type': 'date'},
          ]),
        );
      case '/api/documents/11/download/':
        return http.Response.bytes(
          utf8.encode('%PDF-1.7 Police'),
          200,
          headers: {'content-type': 'application/pdf'},
        );
    }
    return http.Response('unexpected ${request.url}', 500);
  });

  setUp(() async {
    asked.clear();
    documents = [
      {
        'id': 11,
        'title': 'Kfz-Versicherung',
        'correspondent': 3,
        'document_type': 4,
        'created': '2026-01-15',
        'modified': '2026-02-01T10:00:00Z',
        'original_file_name': 'scan.jpg',
        'archived_file_name': 'scan.pdf',
        'tags': [7],
        'custom_fields': [
          {'field': 1, 'value': 'Kündigungsfrist 3 Monate'},
          {'field': 2, 'value': '2027-01-31'},
        ],
      },
      {
        'id': 12,
        'title': 'Zeugnis Mia',
        // Before API version 9 `created` was a date and time.
        'created': '2026-07-20T09:30:00+02:00',
        'modified': '2026-07-20T10:00:00Z',
        'original_file_name': 'zeugnis.pdf',
        'mime_type': 'application/pdf',
        'tags': [7],
      },
    ];
    app = FamioServerApp.inMemory(httpClient: paperless);
    final setup = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/auth/setup'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'username': 'mama',
          'password': 'tulpe-regal-7',
          'setupCode': app.setupCode,
        }),
      ),
    );
    token = (jsonDecode(await setup.readAsString()) as Map)['token'] as String;
  });

  tearDown(() => app.close());

  Future<Response> call(
    String method,
    String path, {
    Object? body,
    String? as,
  }) async => app.handler(
    Request(
      method,
      Uri.parse('http://famio.test/$path'),
      headers: {
        'authorization': 'Bearer ${as ?? token}',
        'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );

  Future<String> login(String username) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'username': username, 'password': 'tulpe-regal-7'}),
      ),
    );
    return (jsonDecode(await r.readAsString()) as Map)['token'] as String;
  }

  test(
    'an admin connects Paperless-ngx; tagged documents appear for adults',
    () async {
      final papa = await call(
        'POST',
        'api/admin/users',
        body: {
          'username': 'papa',
          'displayName': 'Papa',
          'password': 'tulpe-regal-7',
        },
      );
      expect(papa.statusCode, anyOf(200, 201));
      final kid = await call(
        'POST',
        'api/admin/users',
        body: {
          'username': 'mia',
          'displayName': 'Mia',
          'password': 'tulpe-regal-7',
          'role': 'child',
        },
      );
      expect(kid.statusCode, anyOf(200, 201));

      final wrong = await call(
        'PUT',
        'api/admin/paperless',
        body: {'url': 'http://192.168.1.20:8000/', 'token': 'falsch'},
      );
      expect(wrong.statusCode, 400);
      expect(await wrong.readAsString(), contains('lehnt das Token ab'));

      final saved = await call(
        'PUT',
        'api/admin/paperless',
        body: {
          'url': 'http://192.168.1.20:8000/',
          'token': 'lesen',
          'dueField': 'ablaufdatum',
        },
      );
      expect(saved.statusCode, 200);
      final info = jsonDecode(await saved.readAsString()) as Map;
      expect(
        (info['connected'], info['url'], info['tag'], info['count']),
        (true, 'http://192.168.1.20:8000', 'Familie', 2),
      );
      expect(info['dueField'], 'ablaufdatum');
      expect(info.containsKey('token'), isFalse);

      final police = FamilyDocument.fromRecord(
        app.records.get(Collections.externalDocuments, 'pl-11')!,
      );
      expect(police.title, 'Kfz-Versicherung');
      expect(police.category, DocumentCategory.insurance);
      expect(police.expiresAt, DateTime(2027, 1, 31));
      expect(police.notes, 'HUK-Coburg · Versicherungspolice');
      expect(police.source, 'paperless');
      final zeugnis = FamilyDocument.fromRecord(
        app.records.get(Collections.externalDocuments, 'pl-12')!,
      );
      expect(zeugnis.expiresAt, isNull);
      expect(zeugnis.createdAt!.toUtc(), DateTime.utc(2026, 7, 20, 7, 30));
      expect(
        (police.file!.name, police.file!.mime),
        ('scan.pdf', 'application/pdf'),
      );
      final adults = [
        for (final m in app.accounts.members())
          if (m.isAdult) m.id,
      ];
      expect(police.visibleTo, unorderedEquals(adults));

      // The file comes from Paperless-ngx, only for those who see it.
      final file = await call('GET', 'api/files/${police.file!.id}');
      expect(file.statusCode, 200);
      expect(await file.readAsString(), '%PDF-1.7 Police');
      expect(file.headers['content-disposition'], contains('attachment'));
      final mia = await login('mia');
      expect(
        (await call('GET', 'api/files/${police.file!.id}', as: mia)).statusCode,
        404,
      );
      expect(
        (await call('GET', 'api/files/pl-11.1', as: token)).statusCode,
        404,
      );

      // Apps cannot change them.
      final write = await call(
        'POST',
        'api/sync',
        body: SyncRequest(
          since: 0,
          changes: [
            SyncRecord(
              collection: Collections.externalDocuments,
              id: 'pl-11',
              data: const {'title': 'geändert'},
              updatedAt: DateTime.now().millisecondsSinceEpoch + 100000,
            ),
          ],
        ).toJson(),
      );
      expect(
        ((jsonDecode(await write.readAsString()) as Map)['rejected'] as List),
        isNotEmpty,
      );

      // Untagged in Paperless-ngx: gone from Famio at the next sync.
      documents.removeLast();
      await call('POST', 'api/admin/paperless/sync');
      expect(
        app.records.get(Collections.externalDocuments, 'pl-12')!.deleted,
        isTrue,
      );

      await call('DELETE', 'api/admin/paperless');
      expect(
        app.records.get(Collections.externalDocuments, 'pl-11')!.deleted,
        isTrue,
      );
      expect(
        (jsonDecode(
              await (await call('GET', 'api/admin/paperless')).readAsString(),
            )
            as Map)['connected'],
        isFalse,
      );
    },
  );

  test('a missing tag is named', () async {
    final r = await call(
      'PUT',
      'api/admin/paperless',
      body: {'url': 'http://pb.local', 'token': 'lesen', 'tag': 'Haushalt'},
    );
    expect(r.statusCode, 400);
    expect(await r.readAsString(), contains('Haushalt'));
  });

  test('a date field that is missing or no date is named', () async {
    for (final field in ['Frist', 'Notiz']) {
      final r = await call(
        'PUT',
        'api/admin/paperless',
        body: {'url': 'http://pl.local', 'token': 'lesen', 'dueField': field},
      );
      expect(r.statusCode, 400);
      expect(await r.readAsString(), contains('Datumsfeld „$field“'));
    }
    expect(asked, isNot(contains('GET /api/documents/')));
  });

  test(
    'a PaperBuddy connection of 2.0.26 becomes the Paperless-ngx one',
    () async {
      app.db.execute(
        'INSERT INTO settings (key, value) VALUES (?, ?), (?, ?)',
        [
          'paperbuddy',
          jsonEncode({
            'url': 'http://192.168.1.20:8000',
            'token': 'lesen',
            'tag': 'Familie',
            'memberIds': <String>[],
          }),
          'paperbuddy.status',
          jsonEncode({'count': 1, 'lastError': 'PaperBuddy antwortet nicht.'}),
        ],
      );
      app.records.writeAsServer([
        SyncRecord(
          collection: Collections.externalDocuments,
          id: 'pb-11',
          data: const {'title': 'Kfz-Versicherung', 'category': 'insurance'},
          updatedAt: 0,
        ),
      ]);

      app.paperless.adoptPaperBuddy();
      final info = app.paperless.info();
      expect(
        (info['connected'], info['url'], info['dueField'], info['lastError']),
        (true, 'http://192.168.1.20:8000', '', null),
      );
      expect(
        app.db.select("SELECT key FROM settings WHERE key LIKE 'paperbuddy%'"),
        isEmpty,
      );
      // The old record goes; the next sync brings the documents back.
      expect(
        app.records.get(Collections.externalDocuments, 'pb-11')!.deleted,
        isTrue,
      );
      await app.paperless.sync();
      expect(
        app.records.get(Collections.externalDocuments, 'pl-11')!.deleted,
        isFalse,
      );
    },
  );

  test('without a connection nothing of PaperBuddy stays', () async {
    app.records.writeAsServer([
      SyncRecord(
        collection: Collections.externalDocuments,
        id: 'pb-12',
        data: const {'title': 'Zeugnis Mia', 'category': 'school'},
        updatedAt: 0,
      ),
    ]);
    app.paperless.adoptPaperBuddy();
    expect(app.paperless.info()['connected'], isFalse);
    expect(app.records.all(Collections.externalDocuments), isEmpty);
  });
}
