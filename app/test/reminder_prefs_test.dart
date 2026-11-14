import 'dart:convert';

import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

SyncEngine _engine() => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: 'm1',
);

/// The preferences are plain files that go into device backups: what the
/// reminders say (medications, children) stays out of them (#514).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test(
    'scheduled reminders keep only a hash in the preferences (#514)',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        return call.method == 'pendingNotificationRequests' ? [] : true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final prefs = await SharedPreferences.getInstance();
      final reminders = (await ReminderService.create(prefs))!;
      final engine = _engine();
      engine.saveMedication(
        Medication(
          id: 'med1',
          name: 'Methylphenidat',
          personName: 'Mia',
          dose: '10 mg',
          times: const ['08:00'],
          start: DateTime.now().subtract(const Duration(days: 1)),
          careIds: const ['m1'],
        ),
      );
      reminders.attach(engine);
      reminders.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      reminders.detach();
      final raw = prefs.getString('reminders.scheduled');
      final values = (jsonDecode(raw!) as Map).values.toList();
      expect(values, isNotEmpty);
      expect(raw, isNot(contains('Methylphenidat')));
      expect(raw, isNot(contains('Mia')));
      expect(raw, isNot(contains('10 mg')));
      for (final value in values) {
        expect(value, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    },
  );
}
