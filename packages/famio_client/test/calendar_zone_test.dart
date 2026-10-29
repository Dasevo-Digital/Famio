import 'dart:convert';
import 'dart:io';
import 'package:famio_client/famio_client.dart';
import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as zones;
import 'package:timezone/timezone.dart' as tz;

void main() {
  test(
    'synced family zone preserves DST occurrences and accepted replies across restart',
    () async {
      final app = FamioServerApp.inMemory();
      final member = app.accounts.create(
        username: 'member',
        displayName: 'Member',
      );
      final store = LocalStore.open(':memory:');
      final exchanges = <(String?, bool)>[];
      final api = FamioApiClient(
        'http://localhost',
        httpClient: MockClient((request) async {
          final sync = SyncRequest.fromJson(
            (jsonDecode(request.body) as Map).cast(),
          );
          final response = app.records.sync(sync, member.id);
          exchanges.add((sync.timeZoneKey, response.timeZoneRules != null));
          return http.Response(
            jsonEncode(response.toJson()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      var engine = SyncEngine(store: store, api: api, memberId: member.id);
      addTearDown(() async {
        await engine.dispose();
        store.close();
        api.close();
        await app.close();
        Directory(app.dataDir).deleteSync(recursive: true);
      });
      app.records.writeAs(member.id, [
        SyncRecord(
          collection: Collections.events,
          id: 'event',
          updatedAt: 1,
          data: CalendarEvent(
            id: 'event',
            title: 'Lift',
            start: DateTime.utc(2027, 3, 27, 9),
            end: DateTime.utc(2027, 3, 27, 10),
            recurrence: const Recurrence(RecurrenceFrequency.daily),
            bringerId: member.id,
            assignmentConfirmation: const AssignmentSettings(required: true),
          ).toData(),
        ),
      ]);
      await engine.sync();
      expect(engine.familyTimeZone, 'Europe/Berlin');
      expect(exchanges, [(null, true)]);
      await engine.dispose();
      // The app has no zone database of its own: only the rules it stored.
      tz.timeZoneDatabase.clear();
      addTearDown(zones.initializeTimeZones);
      engine = SyncEngine(store: store, api: api, memberId: member.id);
      final record = engine.record(Collections.events, 'event')!;
      final occurrence = CalendarEvent.fromRecord(record)
          .inTimeZone(engine.familyTimeZone)
          .occurrencesBetween(
            DateTime.utc(2027, 3, 28),
            DateTime.utc(2027, 3, 29),
          )
          .single;
      expect(occurrence.start.toUtc(), DateTime.utc(2027, 3, 28, 8));
      final request = assignmentRequests(
        record,
        occurrence: occurrence.start,
        timeZone: engine.familyTimeZone,
      ).single;
      engine.respondToAssignment(request, AssignmentDecision.accepted);
      await engine.sync();
      final key = calendarZoneRules(app.settings.location)['key'] as String;
      expect(exchanges.skip(1), everyElement((key, false)));
      expect(engine.assignmentDecision(request), AssignmentDecision.accepted);
      expect(
        app.records.get(Collections.assignmentResponses, request.id)!.deleted,
        isFalse,
      );
      expect(engine.status.state, SyncState.idle);
    },
  );
}
