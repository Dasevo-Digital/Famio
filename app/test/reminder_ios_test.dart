import 'package:famio/src/reminders/reminder_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'iOS initializes notifications and schedules with Darwin settings',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final calls = <MethodCall>[];
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = await ReminderService.create(
        await SharedPreferences.getInstance(),
      );
      expect(service, isNotNull);
      expect(calls.first.method, 'initialize');
      expect(calls.first.arguments['requestAlertPermission'], isTrue);
      expect(calls.first.arguments['requestSoundPermission'], isTrue);
      await service!.scheduleTimer(
        1,
        DateTime.now().add(const Duration(minutes: 1)),
        title: 'Timer',
        body: 'Finished',
      );
      final scheduled = calls.singleWhere((c) => c.method == 'zonedSchedule');
      expect(scheduled.arguments['platformSpecifics'], isA<Map>());
      expect(scheduled.arguments['title'], 'Timer');
    },
  );
}
