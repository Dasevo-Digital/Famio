import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String token;
  late String releaseKey;
  late SimpleKeyPair keyPair;
  late Map<String, List<int>> files;
  late String sums;
  late String signature;
  final asked = <String>[];

  /// What GitHub serves for the release of this server's version.
  final github = MockClient((request) async {
    asked.add(request.url.toString());
    expect(request.headers['user-agent'], startsWith('Famio-Server/'));
    if (request.url.host == 'api.github.com') {
      if (request.url.path !=
          '/repos/Dasevo-Digital/Famio/releases/tags/v$serverVersion') {
        return http.Response('not found', 404);
      }
      return http.Response(
        jsonEncode({
          'tag_name': 'v$serverVersion',
          'assets': [
            for (final name in [
              ...files.keys,
              'SHA256SUMS.txt',
              'SHA256SUMS.txt.sig',
            ])
              {
                'name': name,
                'browser_download_url': 'https://github.test/dl/$name',
              },
          ],
        }),
        200,
      );
    }
    final name = request.url.pathSegments.last;
    if (name == 'SHA256SUMS.txt') return http.Response(sums, 200);
    if (name == 'SHA256SUMS.txt.sig') return http.Response(signature, 200);
    final bytes = files[name];
    return bytes == null
        ? http.Response('not found', 404)
        : http.Response.bytes(bytes, 200);
  });

  Future<String> sign(String text, SimpleKeyPair pair) async => base64Encode(
    (await Ed25519().sign(utf8.encode(text), keyPair: pair)).bytes,
  );

  setUp(() async {
    asked.clear();
    keyPair = await Ed25519().newKeyPair();
    releaseKey = base64Encode((await keyPair.extractPublicKey()).bytes);
    files = {
      for (final platform in AppPlatform.values)
        platform.fileName(serverVersion): utf8.encode(
          'Paket für ${platform.name}',
        ),
    };
    sums = [
      for (final MapEntry(:key, :value) in files.entries)
        '${await sha256Hex(Stream.value(value))}  $key\n',
    ].join();
    signature = await sign(sums, keyPair);
    app = FamioServerApp.inMemory(httpClient: github, releaseKey: releaseKey);
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
        'authorization': ?(as == '' ? null : 'Bearer ${as ?? token}'),
        'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );

  Future<Map<String, Object?>> json(Response r) async =>
      (jsonDecode(await r.readAsString()) as Map).cast();

  test('off until an admin switches it on; nothing asked before', () async {
    expect(
      (await call('GET', 'api/app-update?platform=android')).statusCode,
      404,
    );
    final info = await json(await call('GET', 'api/admin/app-updates'));
    expect(info['enabled'], isFalse);
    expect(info['version'], serverVersion);
    expect(asked, isEmpty);
  });

  test('signed packages of its own version for every app', () async {
    final info = await json(
      await call('PUT', 'api/admin/app-updates', body: {'enabled': true}),
    );
    expect(info['error'], isNull);
    expect(
      (info['packages'] as Map).keys,
      containsAll(['android', 'windows', 'linux']),
    );

    final r = await call('GET', 'api/app-update?platform=android');
    expect(r.statusCode, 200);
    final update = await json(r);
    final name = AppPlatform.android.fileName(serverVersion);
    expect(update['version'], serverVersion);
    expect(update['file'], name);
    expect(update['sha256'], parseChecksums(sums)[name]);
    // The app checks the signed list itself.
    expect(
      await signedChecksum(
        update['sums'] as String,
        update['signature'] as String,
        name,
        publicKey: releaseKey,
      ),
      update['sha256'],
    );
    final download = await call(
      'GET',
      'api/app-update/download?platform=android',
    );
    expect(download.statusCode, 200);
    expect(download.headers['content-length'], '${files[name]!.length}');
    expect(await download.read().expand((c) => c).toList(), files[name]);

    expect((await call('GET', 'api/app-update?platform=ios')).statusCode, 404);
    expect(
      (await call('GET', 'api/app-update?platform=android', as: '')).statusCode,
      401,
    );
    // Fetched once: a second run keeps the checked files.
    final before = asked.length;
    await call('POST', 'api/admin/app-updates/refresh');
    expect(
      asked.where((u) => u.contains('/dl/Famio-')).length,
      files.length,
      reason: 'packages not downloaded again',
    );
    expect(asked.length, greaterThan(before));
  });

  test('a release signed with another key is not offered', () async {
    signature = await sign(sums, await Ed25519().newKeyPair());
    final info = await json(
      await call('PUT', 'api/admin/app-updates', body: {'enabled': true}),
    );
    expect(info['error'], 'Die Signatur des Releases passt nicht.');
    expect(info['packages'], isEmpty);
    expect(asked.where((u) => u.contains('/dl/Famio-')), isEmpty);
    expect(
      (await call('GET', 'api/app-update?platform=linux')).statusCode,
      404,
    );
  });

  test('a package that does not match its checksum is dropped', () async {
    final name = AppPlatform.windows.fileName(serverVersion);
    files[name] = utf8.encode('etwas anderes');
    final info = await json(
      await call('PUT', 'api/admin/app-updates', body: {'enabled': true}),
    );
    expect(info['error'], contains(name));
    expect(
      (await call('GET', 'api/app-update?platform=windows')).statusCode,
      404,
    );
  });

  test('switching off removes the packages', () async {
    await call('PUT', 'api/admin/app-updates', body: {'enabled': true});
    expect(
      (await call('GET', 'api/app-update?platform=linux')).statusCode,
      200,
    );
    final info = await json(
      await call('PUT', 'api/admin/app-updates', body: {'enabled': false}),
    );
    expect(info['enabled'], isFalse);
    expect(info['packages'], isEmpty);
    expect(
      (await call('GET', 'api/app-update?platform=linux')).statusCode,
      404,
    );
  });

  test('only admins switch it', () async {
    await call(
      'POST',
      'api/admin/users',
      body: {'username': 'ben', 'password': 'wolke-tisch-8', 'displayName': 'Ben'},
    );
    final login = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'username': 'ben', 'password': 'wolke-tisch-8'}),
      ),
    );
    final ben =
        (jsonDecode(await login.readAsString()) as Map)['token'] as String;
    expect(
      (await call(
        'PUT',
        'api/admin/app-updates',
        body: {'enabled': true},
        as: ben,
      )).statusCode,
      403,
    );
  });
}
