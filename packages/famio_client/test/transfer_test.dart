import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

class BodyClient extends http.BaseClient {
  BodyClient({this.length, this.failure});
  final int? length;
  final Object? failure;
  var cancelled = false, aborted = false;
  late final body = StreamController<List<int>>(
    onCancel: () {
      cancelled = true;
    },
  );
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (failure case final error?) throw error;
    (request as http.AbortableRequest).abortTrigger?.then(
      (_) => aborted = true,
    );
    return http.StreamedResponse(body.stream, 200, contentLength: length);
  }
}

void main() {
  for (final operation in ['export', 'download']) {
    test('$operation deadline cancels a body that never finishes', () async {
      late BodyClient client;
      late FamioApiClient api;
      late Future<void> observed;
      Object? error;
      late FakeAsync clock;
      fakeAsync((time) {
        clock = time;
        client = BodyClient();
        api = FamioApiClient('http://localhost', httpClient: client);
        final transfer = operation == 'export'
            ? api.exportData(password: 'fixture')
            : api.downloadFile('fixture');
        observed = transfer.then<void>(
          (_) => fail('Hanging transfer completed'),
          onError: (Object e) {
            error = e;
          },
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(minutes: 11));
        clock.flushMicrotasks();
      });
      // Stream cancellation may complete via the SDK's shared root-zone future.
      await Future<void>.delayed(Duration.zero);
      clock.flushMicrotasks();
      await observed.timeout(const Duration(seconds: 2));
      expect(error, isA<ApiError>().having((e) => e.code, 'code', 'network'));
      expect(client.cancelled, isTrue);
      expect(client.aborted, isTrue);
      api.close();
    });
  }
  test('download normalizes transport exceptions', () async {
    final api = FamioApiClient(
      'http://localhost',
      httpClient: BodyClient(failure: http.ClientException('fixture')),
    );
    addTearDown(api.close);
    await expectLater(
      api.downloadFile('fixture'),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'network')),
    );
  });
  test('export cancellation aborts request and body subscription', () async {
    final client = BodyClient();
    final api = FamioApiClient('http://localhost', httpClient: client);
    final cancellation = TransferCancellation();
    final transfer = api.exportData(
      password: 'fixture',
      cancellation: cancellation,
    );
    final failed = expectLater(
      transfer,
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'cancelled')),
    );
    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();
    await failed;
    expect(client.cancelled, isTrue);
    expect(client.aborted, isTrue);
    api.close();
  });
  test(
    'bounded export rejects misleading lengths and reports streaming progress',
    () async {
      final client = BodyClient();
      final api = FamioApiClient('http://localhost', httpClient: client);
      final progress = <int>[];
      final sink = StreamController<List<int>>();
      final received = <int>[];
      final output = sink.stream.listen(received.addAll);
      final transfer = api.exportDataToSink(
        sink,
        password: 'fixture',
        maxBytes: 3,
        onProgress: (count, _) => progress.add(count),
      );
      final failed = expectLater(
        transfer,
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 413)),
      );
      client.body.add([1, 2]);
      client.body.add([3, 4]);
      await failed;
      await sink.close();
      await output.cancel();
      expect(received, [1, 2]);
      expect(progress, [2]);
      expect(client.cancelled, isTrue);
      api.close();
    },
  );
}
