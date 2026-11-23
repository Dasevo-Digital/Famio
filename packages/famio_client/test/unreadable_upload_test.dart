import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A file that cannot be read while it is sent is told as such, not as a
/// network failure (#588).
void main() {
  Stream<List<int>> unreadable() async* {
    yield List.filled(1024, 1);
    throw const FileSystemException('Operation not permitted', '/gone.pdf');
  }

  Future<void> expectUnreadable(FamioApiClient api) => expectLater(
    api.uploadFileStream(
      stream: unreadable(),
      name: 'gone.pdf',
      mime: 'application/pdf',
      maxBytes: 1 << 20,
      length: 4096,
    ),
    throwsA(
      isA<ApiError>()
          .having((e) => e.code, 'code', 'file_unreadable')
          .having((e) => e.message, 'message', ClientTexts.fileUnreadable)
          .having((e) => e.isNetwork, 'isNetwork', isFalse),
    ),
  );

  test('a read error of the file while sending (mock client)', () async {
    final api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient.streaming((request, body) async {
        await body.drain<void>();
        return http.StreamedResponse(Stream.value('{}'.codeUnits), 201);
      }),
    );
    addTearDown(api.close);
    await expectUnreadable(api);
  });

  test('a read error of the file while sending (real connection)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      try {
        await request.drain<void>();
      } catch (_) {}
      request.response.statusCode = 201;
      await request.response.close();
    });
    final api = FamioApiClient('http://127.0.0.1:${server.port}');
    addTearDown(api.close);
    await expectUnreadable(api);
  });

  test('the server out of reach stays a network failure', () async {
    final api = FamioApiClient(
      'http://localhost',
      httpClient: MockClient.streaming((request, body) async {
        await body.drain<void>();
        throw http.ClientException('Connection refused');
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.uploadFileStream(
        stream: Stream.value(List.filled(1024, 1)),
        name: 'ok.pdf',
        mime: 'application/pdf',
        maxBytes: 1 << 20,
        length: 1024,
      ),
      throwsA(isA<ApiError>().having((e) => e.isNetwork, 'isNetwork', isTrue)),
    );
  });
}
