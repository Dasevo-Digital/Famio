import 'dart:io';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/io_client.dart';
import 'package:test/test.dart';

void main() {
  test('rejecting headers releases the only native connection slot', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = IOClient(HttpClient()..maxConnectionsPerHost = 1);
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    var health = 0;
    server.listen((request) async {
      if (request.uri.path == '/oversized') {
        request.response.contentLength = 1024;
        request.response.done.then<void>((_) {}, onError: (Object _) {});
        request.response.add([1]);
        await request.response.flush();
      } else {
        health++;
        request.response.write('ok');
        await request.response.close();
      }
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    await expectLater(
      httpTransfer<void>(
        client: client,
        method: 'GET',
        url: base.resolve('/oversized'),
        consume: (response, body) async {
          if (response.contentLength! > 1) throw TransferTooLarge();
          await readTransferBytes(body, maxBytes: 1);
        },
      ),
      throwsA(isA<TransferTooLarge>()),
    );
    final response = await client
        .get(base.resolve('/health'))
        .timeout(const Duration(seconds: 2));
    expect(response.body, 'ok');
    expect(health, 1);
  });
}
