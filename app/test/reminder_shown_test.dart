import 'dart:convert';

import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members = '[{"id":"m1","username":"mama","displayName":"Mama"}]';

/// A reminder Android shows is no longer due: planning again (any change
/// to tasks or appointments, every six hours, the next start) left it out
/// and its cancel took the notification off the screen (found while
/// checking GRU-048 on the emulator). It stays until the person dismisses
/// it, and signing out still removes it.
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('a shown reminder stays when Famio plans again', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});

    // What the plugin is asked; [shown]: what Android shows.
    final cancelled = <int>[];
    final scheduled = <int>[];
    final shown = <int>{};
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'cancel':
          final id = (call.arguments as Map)['id'] as int;
          cancelled.add(id);
          shown.remove(id);
          return null;
        case 'zonedSchedule':
          scheduled.add((call.arguments as Map)['id'] as int);
          return null;
        case 'getActiveNotifications':
          return [
            for (final id in shown) {'id': id, 'channelId': 'reminders'},
          ];
        case 'pendingNotificationRequests':
          return [];
        default:
          return true;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final prefs = await SharedPreferences.getInstance();
    final reminders = (await ReminderService.create(prefs))!;
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final at = DateTime.now().add(const Duration(milliseconds: 700));
    engine.saveTask(Task(id: 't1', title: 'Zahnarzt anrufen', remindAt: at));
    Map<String, Object?> planned() =>
        jsonDecode(prefs.getString('reminders.scheduled') ?? '{}')
            as Map<String, Object?>;
    Future<void> plan() async {
      reminders.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    reminders.attach(engine);
    await plan();
    final id = scheduled.single;
    expect(planned().keys, ['$id']);

    // Its time came: Android shows it.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    shown.add(id);
    // Something else changes, Famio plans again: the notification stays.
    await plan();
    expect(cancelled, isEmpty, reason: 'still on the screen');
    expect(planned().keys, ['$id'], reason: 'kept for signing out');

    // Signing out takes it away all the same (GRU-048).
    await reminders.clear();
    expect(cancelled, [id]);
    expect(prefs.getString('reminders.scheduled'), isNull);
  });

  test('a dismissed one drops out of the list', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final shown = <int>{};
    final scheduled = <int>[];
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'zonedSchedule':
          scheduled.add((call.arguments as Map)['id'] as int);
          return null;
        case 'cancel':
          return null;
        case 'getActiveNotifications':
          return [
            for (final id in shown) {'id': id},
          ];
        case 'pendingNotificationRequests':
          return [];
        default:
          return true;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final prefs = await SharedPreferences.getInstance();
    final reminders = (await ReminderService.create(prefs))!;
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    engine.saveTask(
      Task(
        id: 't1',
        title: 'Müll rausbringen',
        remindAt: DateTime.now().add(const Duration(milliseconds: 700)),
      ),
    );
    reminders.attach(engine);
    reminders.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final id = scheduled.single;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    shown.add(id);
    reminders.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(prefs.getString('reminders.scheduled'), contains('$id'));
    // Swiped away: the next planning forgets it.
    shown.remove(id);
    reminders.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(prefs.getString('reminders.scheduled'), '{}');
    reminders.detach();
  });
}
