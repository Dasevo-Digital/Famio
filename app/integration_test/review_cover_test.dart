// The iPhone's cover with the app lock on (#512, catalog GRU-115): in the
// app switcher Famio is covered, and after coming back locked the preview
// of a document iOS showed over Famio is closed, so only the lock screen is
// left. Runs in an iOS simulator through tool/ios_review_tests.py, which
// sends Famio away (another app in front) and brings it back, and keeps
// the picture iOS took for the app switcher.
//
//   tool/ios_review_tests.py <simulator id>
//     --file integration_test/review_cover_test.dart
//
// The lock is switched on as setEnabled leaves it, without Face ID: the
// simulator's question whether Famio may use Face ID needs a tap.
import 'dart:io';

import 'package:famio/src/app_state.dart';
import 'package:famio/src/security/app_lock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_kit.dart';
import 'review_open_test.dart' show hostOk;

const _privacy = MethodChannel('famio/privacy');

Future<Map<String, Object?>> _native() async =>
    Map<String, Object?>.from(await _privacy.invokeMethod('debugState') as Map);

Future<void> _lock(AppState state, bool on, {int delaySeconds = 0}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('appLock.enabled', on);
  await prefs.setInt('appLock.delay', delaySeconds);
  await _privacy.invokeMethod('setSecure', on);
  if (!on) state.lock.signedOut();
}

/// Waits without drawing: while iOS's preview lies over Flutter's view,
/// Flutter draws nothing, and a pump would wait for good.
Future<void> _until(String what, Future<bool> Function() check) async {
  debugPrint('E2E until $what');
  final end = DateTime.now().add(const Duration(seconds: 30));
  while (!await check()) {
    if (DateTime.now().isAfter(end)) throw TestFailure('Not reached: $what');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GRU-115 the cover over a document in iOS preview (#512)', (
    tester,
  ) async {
    final state = await startApp(tester);
    addTearDown(() => _lock(state, false));
    await tester.pump(const Duration(seconds: 2));
    await hostOk('screenshot signed-in');
    // First: back within the delay, the preview stays and nothing locks.
    await _lock(state, true, delaySeconds: 60);

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/E2E-Befund.txt')
      ..writeAsStringSync('E2E Befund: nur zum Testen der Abdeckung.\n');
    // As the app opens documents; iOS's preview answers only once it is
    // closed again.
    final opened = AppLock.previewing(
      () => OpenFilex.open(file.path, type: 'text/plain'),
    );
    await _until(
      'the preview over Famio',
      () async => (await _native())['presented'] == true,
    );

    final short = await hostOk('away 3');
    // ignore: avoid_print
    print('E2E app switcher picture: $short');
    await _until('the cover down again', () async {
      final now = await _native();
      return now['covered'] == false;
    });
    expect((await _native())['presented'], isTrue);
    expect(state.lock.locked, isFalse);
    await hostOk('screenshot back-within-delay');

    // Then "Sofort": back locked, the preview closes, the lock screen stays.
    await _lock(state, true);
    final long = await hostOk('away 3');
    // ignore: avoid_print
    print('E2E app switcher picture: $long');
    await _until('the preview closed and the cover down', () async {
      final now = await _native();
      return now['presented'] == false && now['covered'] == false;
    });
    expect(state.lock.locked, isTrue);
    final ended = await opened.timeout(const Duration(seconds: 30));
    expect(ended.type, ResultType.done, reason: ended.message);
    await waitFor(tester, find.text(de.appLockLocked));
    await tester.pump(const Duration(seconds: 2));
    await hostOk('screenshot locked');
    await finish(tester, state);
  }, skip: defaultTargetPlatform != TargetPlatform.iOS);
}
