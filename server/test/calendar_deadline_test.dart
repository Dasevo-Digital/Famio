import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

class HangingFeeds extends http.BaseClient {
  var requests = 0, cancelled = false;
  late final body = StreamController<List<int>>(
    onCancel: () {
      cancelled = true;
    },
  );
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (++requests == 1) return http.StreamedResponse(body.stream, 200);
    return http.StreamedResponse(
      Stream.value(
        utf8.encode('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n'),
      ),
      200,
    );
  }
}

void main() {
  test(
    'a hanging calendar body times out and the next subscription imports',
    () async {
      final app = FamioServerApp.inMemory();
      addTearDown(() async {
        await app.close();
        Directory(app.dataDir).deleteSync(recursive: true);
      });
      app.records.writeAsServer([
        for (final id in ['a', 'b'])
          SyncRecord(
            collection: Collections.calendarSubscriptions,
            id: id,
            updatedAt: 1,
            data: CalendarSubscription(
              id: id,
              name: id,
              url: 'http://127.0.0.1/$id',
            ).toData(),
          ),
      ]);
      final client = HangingFeeds();
      final importer = CalendarImporter(
        records: app.records,
        location: () => app.location,
        onChanged: () {},
        client: client,
        fetchTimeout: const Duration(milliseconds: 20),
        urlPolicy: const RemoteUrlPolicy(allowPrivateNetwork: true),
      );
      await importer.refreshAll().timeout(const Duration(seconds: 2));
      expect(client.requests, 2);
      expect(client.cancelled, isTrue);
      expect(
        app.records.get(Collections.calendarSyncStatus, 'a')!.data['error'],
        isNotNull,
      );
      expect(
        app.records.get(Collections.calendarSyncStatus, 'b')!.data['error'],
        isNull,
      );
      importer.stop();
    },
  );

  test('a refused address reads like one (KAL-125)', () async {
    final app = FamioServerApp.inMemory();
    addTearDown(() async {
      await app.close();
      Directory(app.dataDir).deleteSync(recursive: true);
    });
    app.records.writeAsServer([
      SyncRecord(
        collection: Collections.calendarSubscriptions,
        id: 'lan',
        updatedAt: 1,
        data: const CalendarSubscription(
          id: 'lan',
          name: 'LAN',
          url: 'http://192.168.1.50/kal.ics',
        ).toData(),
      ),
    ]);
    final importer = CalendarImporter(
      records: app.records,
      location: () => app.location,
      onChanged: () {},
      client: HangingFeeds(),
    );
    await importer.refreshAll().timeout(const Duration(seconds: 5));
    final error =
        app.records.get(Collections.calendarSyncStatus, 'lan')!.data['error']
            as String;
    expect(error, isNot(contains('ApiException')));
    expect(error, isNot(contains('Import fehlgeschlagen')));
    expect(error, contains('HTTPS'));
    importer.stop();
  });
}
