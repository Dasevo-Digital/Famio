import 'dart:async';

import 'package:famio/src/design/theme.dart';
import 'package:famio/src/security/app_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Device implements DeviceUnlock {
  var works = true;
  var exists = true;
  var asked = 0;

  /// What the system's dialog does to the app while it is open.
  void Function()? during;

  @override
  Future<bool> get available async => exists;

  @override
  Future<bool> unlock(String reason) async {
    asked++;
    during?.call();
    return works;
  }
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late DateTime now;
  late _Device device;

  Future<AppLock> lock({
    bool enabled = true,
    TargetPlatform platform = TargetPlatform.android,
    int? delaySeconds,
  }) async {
    now = DateTime(2026, 11, 5, 12);
    device = _Device();
    SharedPreferences.setMockInitialValues({
      'appLock.enabled': enabled,
      'appLock.delay': ?delaySeconds,
    });
    final result = AppLock(
      await SharedPreferences.getInstance(),
      device: device,
      now: () => now,
      platform: platform,
    );
    addTearDown(result.dispose);
    return result;
  }

  void away(AppLock l, Duration time) {
    l.didChangeAppLifecycleState(AppLifecycleState.inactive);
    l.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(time);
    l.didChangeAppLifecycleState(AppLifecycleState.resumed);
  }

  test('off by default', () async {
    final l = await lock(enabled: false);
    expect(l.locked, isFalse);
    away(l, const Duration(days: 1));
    expect(l.locked, isFalse);
  });

  test('locked from the start once it is on', () async {
    expect((await lock()).locked, isTrue);
  });

  test('a short trip to the camera needs no second unlock', () async {
    final l = await lock();
    await l.unlock();
    away(l, const Duration(seconds: 59));
    expect(l.locked, isFalse);
    away(l, AppLock.defaultDelay);
    expect(l.locked, isTrue);
  });

  test('the chosen time decides', () async {
    final now0 = await lock(delaySeconds: 0);
    await now0.unlock();
    away(now0, Duration.zero);
    expect(now0.locked, isTrue);

    final five = await lock(delaySeconds: 300);
    expect(five.delay, const Duration(minutes: 5));
    await five.unlock();
    away(five, const Duration(minutes: 4, seconds: 59));
    expect(five.locked, isFalse);
    away(five, const Duration(minutes: 5));
    expect(five.locked, isTrue);
  });

  test('a minute until somebody chooses, and only offered times', () async {
    final l = await lock();
    expect(l.delay, AppLock.defaultDelay);
    final odd = await lock(delaySeconds: 42);
    expect(odd.delay, AppLock.defaultDelay);
    expect(
      () => odd.setDelay(const Duration(seconds: 42)),
      throwsArgumentError,
    );
    await odd.setDelay(const Duration(minutes: 15));
    expect(odd.delay, const Duration(minutes: 15));
    expect(
      (await SharedPreferences.getInstance()).getInt('appLock.delay'),
      900,
    );
  });

  test(
    'at once: no unlock after the camera, the file picker or the scanner',
    () async {
      final l = await lock(delaySeconds: 0);
      await l.unlock();
      final answer = Completer<String?>();
      final picked = AppLock.picking(() => answer.future);
      l.didChangeAppLifecycleState(AppLifecycleState.inactive);
      l.didChangeAppLifecycleState(AppLifecycleState.hidden);
      l.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 50));
      // The picker's answer arrives before Famio hears it is back.
      answer.complete('photo.jpg');
      expect(await picked, 'photo.jpg');
      l.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(l.locked, isFalse);

      // Longer than a minute in the camera: locked again.
      final slow = AppLock.picking(() async {
        away(l, AppLock.pickerDelay);
        return null;
      });
      await slow;
      expect(l.locked, isTrue);
      await l.unlock();

      // Leaving any other way locks at once.
      away(l, const Duration(seconds: 1));
      expect(l.locked, isTrue);
    },
  );

  test('a longer chosen time also counts for the camera', () async {
    final l = await lock(delaySeconds: 900);
    await l.unlock();
    await AppLock.picking(() async {
      away(l, const Duration(minutes: 10));
    });
    expect(l.locked, isFalse);
  });

  test('a fresh sign-in is proof enough', () async {
    final l = await lock(delaySeconds: 0);
    // Signed out, and on the way back in a trip to the password manager.
    l.signedOut();
    away(l, const Duration(seconds: 30));
    expect(l.locked, isTrue);
    l.signedIn();
    expect(l.locked, isFalse);
    // After that the chosen time applies again.
    away(l, Duration.zero);
    expect(l.locked, isTrue);
  });

  test('the system dialog itself does not lock again', () async {
    final l = await lock();
    device.during = () {
      l.didChangeAppLifecycleState(AppLifecycleState.inactive);
      now = now.add(const Duration(minutes: 5));
      l.didChangeAppLifecycleState(AppLifecycleState.resumed);
    };
    expect(await l.unlock(), isTrue);
    expect(l.locked, isFalse);
  });

  test('a failed attempt stays locked and offers a way out', () async {
    final l = await lock();
    device.works = false;
    expect(await l.unlock(), isFalse);
    expect(l.locked, isTrue);
    expect(l.failed, isTrue);
    l.signedOut();
    expect(l.locked, isFalse);
  });

  test('switching needs the device, and a device that can', () async {
    final l = await lock(enabled: false);
    device.works = false;
    expect(await l.setEnabled(true), isFalse);
    expect(l.enabled, isFalse);
    device.works = true;
    expect(await l.setEnabled(true), isTrue);
    expect(l.enabled, isTrue);
    // No sudden lock right after switching it on.
    expect(l.locked, isFalse);

    final none = await lock(enabled: false);
    device.exists = false;
    final other = AppLock(
      await SharedPreferences.getInstance(),
      device: device,
    );
    addTearDown(other.dispose);
    expect(await other.setEnabled(true), isFalse);
    expect(none.enabled, isFalse);
  });

  test('only the iPhone covers itself in the background', () async {
    final phone = await lock(platform: TargetPlatform.iOS);
    phone.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(phone.covered, isTrue);
    phone.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(phone.covered, isFalse);

    final android = await lock();
    android.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(android.covered, isFalse);
  });

  testWidgets(
    'settings: the time is chosen in a dialog, also with large text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final l = (await tester.runAsync(lock))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: famioTheme(Brightness.light),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: l,
              builder: (_, _) =>
                  ListView(children: [AppLockDelayTile(lock: l)]),
            ),
          ),
        ),
      );
      expect(find.text('Nach 1 Minute'), findsOneWidget);
      await tester.tap(find.text('Sperren'));
      await tester.pumpAndSettle();
      for (final text in [
        'Sofort',
        'Nach 1 Minute',
        'Nach 5 Minuten',
        'Nach 15 Minuten',
      ]) {
        expect(
          find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.text(text),
          ),
          findsOneWidget,
        );
      }
      await tester.tap(find.text('Sofort'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(l.delay, Duration.zero);
      expect(
        find.text(
          'Sofort\nKamera, Dateiauswahl und Scanner: nach einer Minute',
        ),
        findsOneWidget,
      );
    },
  );

  group('the gate', () {
    Widget gate(AppLock l, {bool active = true, VoidCallback? signOut}) =>
        MaterialApp(
          builder: (_, child) => AppLockGate(
            lock: l,
            active: active,
            onSignOut: signOut ?? () {},
            child: child!,
          ),
          home: const Text('Medikamente'),
        );

    testWidgets('hides everything and asks once by itself', (tester) async {
      final l = await tester.runAsync(lock);
      device.works = false;
      await tester.pumpWidget(gate(l!));
      await tester.pumpAndSettle();
      expect(device.asked, 1);
      expect(find.text('Famio ist gesperrt'), findsOneWidget);
      expect(find.text('Medikamente').hitTestable(), findsNothing);
      expect(tester.getSemantics(find.text('Famio ist gesperrt')), isNotNull);
    });

    testWidgets('opens after unlocking, the page is still there', (
      tester,
    ) async {
      final l = await tester.runAsync(lock);
      await tester.pumpWidget(gate(l!));
      await tester.pumpAndSettle();
      expect(l.locked, isFalse);
      expect(find.text('Famio ist gesperrt'), findsNothing);
      expect(find.text('Medikamente').hitTestable(), findsOneWidget);
    });

    testWidgets('asks again when it locks again', (tester) async {
      final l = await tester.runAsync(lock);
      await tester.pumpWidget(gate(l!));
      await tester.pumpAndSettle();
      expect(device.asked, 1);
      away(l, AppLock.defaultDelay);
      await tester.pumpAndSettle();
      expect(device.asked, 2);
      expect(l.locked, isFalse);
    });

    testWidgets('signing out is offered after a failed attempt', (
      tester,
    ) async {
      final l = await tester.runAsync(lock);
      device.works = false;
      var out = false;
      await tester.pumpWidget(gate(l!, signOut: () => out = true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abmelden'));
      expect(out, isTrue);
    });

    testWidgets('nobody signed in: nothing to hide', (tester) async {
      final l = await tester.runAsync(lock);
      await tester.pumpWidget(gate(l!, active: false));
      await tester.pumpAndSettle();
      expect(device.asked, 0);
      expect(find.text('Medikamente').hitTestable(), findsOneWidget);
    });
  });
}
