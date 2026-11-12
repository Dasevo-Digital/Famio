// Paperless documents and their files follow the same rules as the
// family's own documents: audience and role. A service account gets no
// health documents, a guest no documents at all.
import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  final paperless = MockClient((request) async {
    http.Response json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );
    Map<String, Object?> page(List<Object> results) => {
      'count': results.length,
      'next': null,
      'results': results,
    };
    switch (request.url.path) {
      case '/api/tags/':
        return json(
          page([
            {'id': 7, 'name': 'Familie'},
          ]),
        );
      case '/api/documents/':
        return json(
          page([
            {
              'id': 11,
              'title': 'Befund Kardiologie',
              'document_type': 4,
              'created': '2026-01-15',
              'modified': '2026-02-01T10:00:00Z',
              'original_file_name': 'befund.pdf',
              'mime_type': 'application/pdf',
              'tags': [7],
            },
          ]),
        );
      case '/api/correspondents/':
        return json(page([]));
      case '/api/document_types/':
        return json(
          page([
            {'id': 4, 'name': 'Arztbefund'},
          ]),
        );
      case '/api/custom_fields/':
        return json(page([]));
      case '/api/documents/11/download/':
        return http.Response.bytes(
          utf8.encode('%PDF secret befund'),
          200,
          headers: {'content-type': 'application/pdf'},
        );
    }
    return http.Response('unexpected ${request.url}', 500);
  });

  late FamioServerApp app;
  late String admin;
  Future<Response> call(
    String method,
    String path, {
    Object? body,
    required String as,
  }) async => app.handler(
    Request(
      method,
      Uri.parse('http://famio.test/$path'),
      headers: {
        'authorization': 'Bearer $as',
        'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );
  Future<String> login(String u) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'username': u, 'password': 'tulpe-regal-7'}),
      ),
    );
    return (jsonDecode(await r.readAsString()) as Map)['token'] as String;
  }

  setUp(() async {
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
    admin = (jsonDecode(await setup.readAsString()) as Map)['token'] as String;
  });
  tearDown(() => app.close());

  Future<String> member(String name, String role) async {
    final r = await call(
      'POST',
      'api/admin/users',
      as: admin,
      body: {
        'username': name,
        'displayName': name,
        'password': 'tulpe-regal-7',
        'role': role,
      },
    );
    return (jsonDecode(await r.readAsString()) as Map)['id'] as String;
  }

  Future<List<SyncRecord>> pull(String token) async {
    final r = await call(
      'POST',
      'api/sync',
      as: token,
      body: SyncRequest(since: 0).toJson(),
    );
    return SyncResponse.fromJson(
      (jsonDecode(await r.readAsString()) as Map).cast(),
    ).changes;
  }

  test(
    'a service account named for Paperless gets no health document',
    () async {
      final haId = await member('ha', 'service');
      final ha = await login('ha');
      final saved = await call(
        'PUT',
        'api/admin/paperless',
        as: admin,
        body: {
          'url': 'http://192.168.1.20:8000/',
          'token': 'x',
          'memberIds': [haId],
        },
      );
      expect(saved.statusCode, 200);
      final stored = app.records
          .all(Collections.externalDocuments)
          .where((r) => !r.deleted)
          .single;
      expect(stored.data['category'], 'health');
      expect(
        (await pull(
          ha,
        )).where((r) => r.collection == Collections.externalDocuments),
        isEmpty,
      );
      final fileId = (stored.data['file'] as Map)['id'];
      expect((await call('GET', 'api/files/$fileId', as: ha)).statusCode, 404);
    },
  );

  test(
    'a member demoted to guest no longer downloads Paperless files',
    () async {
      final papaId = await member('papa', 'adult');
      final papa = await login('papa');
      await call(
        'PUT',
        'api/admin/paperless',
        as: admin,
        body: {'url': 'http://192.168.1.20:8000/', 'token': 'x'},
      );
      final doc = (await pull(
        papa,
      )).where((r) => r.collection == Collections.externalDocuments).single;
      final fileId = (doc.data['file'] as Map)['id'];
      expect(
        (await call('GET', 'api/files/$fileId', as: papa)).statusCode,
        200,
      );
      final demote = await call(
        'PATCH',
        'api/admin/users/$papaId',
        as: admin,
        body: {'role': 'guest'},
      );
      expect(demote.statusCode, 200);
      expect(
        (await call('GET', 'api/files/$fileId', as: papa)).statusCode,
        404,
      );
      // Not even when the admin names the guest for Paperless.
      await call(
        'PUT',
        'api/admin/paperless',
        as: admin,
        body: {
          'url': 'http://192.168.1.20:8000/',
          'token': 'x',
          'memberIds': [papaId],
        },
      );
      await call('POST', 'api/admin/paperless/sync', as: admin);
      expect(
        (await call('GET', 'api/files/$fileId', as: papa)).statusCode,
        404,
      );
    },
  );
}
