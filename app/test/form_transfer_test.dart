import 'dart:async';
import 'dart:io';
import 'package:famio/src/widgets/form_dialog.dart';
import 'package:famio/src/platform/export_file_io.dart';
import 'package:famio/src/platform/upload_bytes.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class StreamingExportClient extends http.BaseClient {
  final body = StreamController<List<int>>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body.stream, 200);
}

void main() {
  testWidgets(
    'busy form prevents barrier dismissal until the request finishes',
    (tester) async {
      final completed = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => FormDialog(
                  title: 'Fixture',
                  fields: const [],
                  submitLabel: 'Submit',
                  onSubmit: () => completed.future,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      await tester.pump();
      await tester.tapAt(const Offset(3, 3));
      await tester.pumpAndSettle();
      expect(find.text('Fixture'), findsOneWidget);
      completed.completeError(
        const ApiError(503, 'fixture', 'Synthetic error'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic error'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'cancelling an active native export unbinds and removes its file',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'famio-export-cancel-',
      );
      final client = StreamingExportClient();
      final api = FamioApiClient('http://localhost', httpClient: client);
      final cancellation = TransferCancellation();
      final file = File('${directory.path}/partial.zip');
      addTearDown(() {
        api.close();
        directory.deleteSync(recursive: true);
      });
      final transfer = writeExportFile(
        file,
        (sink) => api.exportDataToSink(
          sink,
          password: 'fixture',
          cancellation: cancellation,
        ),
      );
      final failed = expectLater(
        transfer,
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'cancelled')),
      );
      client.body.add([1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      cancellation.cancel();
      await failed.timeout(const Duration(seconds: 2));
      expect(file.existsSync(), isFalse);
    },
  );
  testWidgets('late API failure after forced form removal is harmless', (
    tester,
  ) async {
    final completed = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: FormDialog(
          title: 'Fixture',
          fields: const [],
          submitLabel: 'Submit',
          onSubmit: () => completed.future,
        ),
      ),
    );
    await tester.tap(find.text('Submit'));
    await tester.pumpWidget(const SizedBox.shrink());
    completed.completeError(const ApiError(503, 'fixture', 'Synthetic error'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('cancellable busy form aborts when removed', (tester) async {
    final completed = Completer<void>();
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: FormDialog(
          title: 'Fixture',
          fields: const [],
          submitLabel: 'Submit',
          onCancel: () {
            cancelled = true;
          },
          onSubmit: () => completed.future,
        ),
      ),
    );
    await tester.tap(find.text('Submit'));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(cancelled, isTrue);
    completed.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  test('partial exports are deleted; existing files are preserved', () async {
    final directory = Directory.systemTemp.createTempSync('famio-export-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/export.zip');
    await expectLater(
      writeExportFile(file, (sink) async {
        sink.add([1, 2]);
        throw const ApiError(499, 'cancelled', 'Cancelled');
      }),
      throwsA(isA<ApiError>()),
    );
    expect(file.existsSync(), isFalse);
    await writeExportFile(file, (sink) async {
      await sink.addStream(
        Stream.fromIterable([
          [1],
          [2, 3],
        ]),
      );
    });
    expect(file.readAsBytesSync(), [1, 2, 3]);
    await expectLater(
      writeExportFile(file, (_) async {}),
      throwsA(isA<FileSystemException>()),
    );
    expect(file.readAsBytesSync(), [1, 2, 3]);
  });
  test(
    'oversized picker metadata is rejected before opening contents',
    () async {
      var opened = false;
      await expectLater(
        readUploadBytes(
          length: () async => maxLocalUploadBytes + 1,
          openRead: () {
            opened = true;
            return const Stream.empty();
          },
        ),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 413)),
      );
      expect(opened, isFalse);
    },
  );
}
