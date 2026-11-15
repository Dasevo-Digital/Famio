// Catalog entries that need Android: shares from other apps, Android's
// permission dialogs and settings, notifications, the home screen widget,
// the emergency tile and shortcut, the app lock with the device PIN, the
// location service and the device clock. On an emulator against a
// throwaway server:
//
//   tool/android_review_tests.py emulator-5572 \
//     --file integration_test/catalog_android_test.dart [--name REGEX]
//
// The script answers the `E2E-HOST …` lines (see there); with `@id=` it also
// tells the test the result (FAMIO_E2E_HOST_PORT). What it changes on the
// emulator (clock, font size, quick settings tile) goes back at its end.
// Each test names the catalog entries it checks.
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/data/birthdays.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/ocr.dart' show Ocr;
import 'package:famio/src/data/waste.dart';
import 'package:famio/src/data/week_preview.dart';
import 'package:famio/src/design/palette.dart' show FamioSection;
import 'package:famio/src/environment.dart';
import 'package:famio/src/format.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/location/location_sharing.dart';
import 'package:famio/src/screens/location/labels.dart';
import 'package:famio/src/screens/pantry_screens.dart' show PantryCard;
import 'package:famio/src/security/app_lock.dart' show AppLock;
import 'package:famio/src/widgets/famio_tour.dart' show TourTargets;
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_widget/home_widget.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/intl.dart';

import 'catalog_kit.dart';

const _hostPort = String.fromEnvironment('FAMIO_E2E_HOST_PORT');

const _short = Duration(seconds: 3);

/// Where the drags of [scrollTo] start on a phone (logical pixels).
const _phone = Offset(200, 460);

/// A school in Hamburg, a shop 2 km away, and far from both.
const _school = (53.5600, 9.9800);
const _shop = (53.5750, 10.0050);
const _bakery = (53.5950, 10.0400);
const _away = (53.5300, 9.9300);

var _seq = 0;

String b64(String text) => base64Url.encode(utf8.encode(text));

/// Something only the host can do (see tool/android_review_tests.py); the
/// script tells whether it worked and what it found.
Future<({bool ok, String out})> host(
  String command, {
  Duration timeout = const Duration(minutes: 3),
}) async {
  final id = 'h${_seq++}';
  // ignore: avoid_print
  print('E2E-HOST $command @id=$id');
  if (_hostPort.isEmpty) {
    await Future<void>.delayed(const Duration(seconds: 3));
    return (ok: true, out: '');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final watch = Stopwatch()..start();
  try {
    while (watch.elapsed < timeout) {
      try {
        final request = await client.getUrl(
          Uri.parse('http://10.0.2.2:$_hostPort/r/$id'),
        );
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 200) {
          final json = jsonDecode(body) as Map<String, Object?>;
          final result = (ok: json['ok'] == true, out: '${json['out'] ?? ''}');
          debugPrint('E2E host $command → ${result.ok} ${result.out}');
          return result;
        }
      } on IOException {
        // Not up yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  } finally {
    client.close(force: true);
  }
  throw TestFailure('The host did not answer: $command');
}

Future<String> hostOk(String command, {Duration? timeout}) async {
  final r = await host(command, timeout: timeout ?? const Duration(minutes: 3));
  if (!r.ok) throw TestFailure('host $command failed: ${r.out}');
  return r.out;
}

/// What the test found beyond pass/fail, for the results file.
void note(String text) => debugPrint('E2E-RESULT $text');

/// Pumps while Famio is visible; in the background Android draws no frames
/// and a pump would wait for one forever.
Future<void> idle(WidgetTester tester, Duration d) async {
  final s = WidgetsBinding.instance.lifecycleState;
  if (s == null ||
      s == AppLifecycleState.resumed ||
      s == AppLifecycleState.inactive) {
    await tester.pump(d);
  } else {
    await Future<void>.delayed(d);
  }
}

/// Waits on a stopwatch, not the wall clock: one test moves the clock.
Future<void> until(
  WidgetTester tester,
  bool Function() ok,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  debugPrint('E2E until $what');
  final watch = Stopwatch()..start();
  while (!ok()) {
    if (watch.elapsed > timeout) {
      throw TestFailure('Timed out: $what\nOn screen: ${onScreen()}');
    }
    await idle(tester, const Duration(milliseconds: 250));
  }
}

Future<T> untilAsync<T>(
  WidgetTester tester,
  String what,
  Future<T?> Function() check, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  debugPrint('E2E until $what');
  final watch = Stopwatch()..start();
  while (true) {
    final result = await check();
    if (result != null && result != false) return result;
    if (watch.elapsed > timeout) throw TestFailure('Timed out: $what');
    await idle(tester, const Duration(seconds: 1));
  }
}

Future<void> waitUi(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) => until(
  tester,
  () => finder.evaluate().isNotEmpty,
  finder.describeMatch(Plurality.many),
  timeout: timeout,
);

/// Whether [finder] shows up within [timeout].
Future<bool> appears(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    if (finder.evaluate().isNotEmpty) return true;
    await idle(tester, const Duration(milliseconds: 250));
  }
  return finder.evaluate().isNotEmpty;
}

/// A text field showing [text].
Finder fieldWith(String text) => find.byWidgetPredicate(
  (w) => w is EditableText && w.controller.text == text,
);

/// Sections: on phones an icon in the bar (tooltip) or behind "Mehr".
Future<void> section(WidgetTester tester, String label) async {
  await snackGone(tester);
  // "Mehr" in the phone bar: labelled with the section shown, if that is
  // one of the others.
  final more = find.byKey(TourTargets.more);
  final inBar = find.descendant(
    of: find.byType(Scaffold).first,
    matching: find.byTooltip(label),
  );
  final bar = find.byWidgetPredicate(
    (w) => (w is Tooltip && w.message == label) || w.key == TourTargets.more,
  );
  // A page opened over the bar: back first, as a person would.
  for (var i = 0; i < 4 && !await appears(tester, bar, timeout: _short); i++) {
    if (find.byTooltip(de.commonBack).evaluate().isEmpty) break;
    await back(tester);
  }
  await waitFor(tester, bar);
  final here = find.descendant(of: more, matching: find.byTooltip(label));
  if (here.evaluate().isNotEmpty) {
    // Already there; back to its first page.
    for (
      var i = 0;
      i < 4 && find.byTooltip(de.commonBack).evaluate().isNotEmpty;
      i++
    ) {
      await back(tester);
    }
  } else if (inBar.evaluate().isNotEmpty) {
    await tap(tester, inBar.last);
  } else {
    await tap(tester, more);
    await tap(tester, find.text(label).last);
  }
  await dismissTip(tester);
}

/// The page's own vertical list, where it can be touched.
final _list = find
    .byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .hitTestable();

Future<void> phoneScroll(
  WidgetTester tester,
  Finder finder, {
  bool up = false,
}) async {
  for (final delta in up ? [-250.0, 250.0] : [250.0, -250.0]) {
    if (finder.evaluate().isNotEmpty || _list.evaluate().isEmpty) break;
    try {
      await tester.scrollUntilVisible(
        finder,
        delta,
        scrollable: _list.first,
        maxScrolls: 40,
      );
    } catch (_) {
      // Not that way: the other.
    }
  }
  if (finder.evaluate().isEmpty) {
    await scrollTo(tester, finder, up: up, at: _phone);
  }
  await tester.ensureVisible(finder.first);
  await tester.pump(const Duration(milliseconds: 300));
}

/// Drags the page's list by [dy].
Future<void> dragList(WidgetTester tester, double dy) async {
  if (_list.evaluate().isEmpty) return;
  await tester.drag(_list.first, Offset(0, dy));
  await tester.pump(const Duration(milliseconds: 200));
}

/// Einstellungen → Push-Benachrichtigungen.
Future<void> pushSettings(WidgetTester tester) async {
  await section(tester, de.sectionSettings);
  await phoneScroll(tester, find.text('Push-Benachrichtigungen'));
  await tap(tester, find.text('Push-Benachrichtigungen'));
  await waitFor(tester, find.text(de.pushDirectlyThroughFamio));
}

/// "Direkt über Famio" → "Auf diesem Handy" on.
Future<void> ownPushOn(WidgetTester tester) async {
  final sw = find.widgetWithText(SwitchListTile, de.pushPhone);
  await waitFor(tester, sw);
  for (var i = 0; i < 5 && !tester.widget<SwitchListTile>(sw).value; i++) {
    if (tester.widget<SwitchListTile>(sw).onChanged != null) {
      await tap(tester, sw);
      // Android may ask; on this emulator it was answered before.
      await host('permissions allow 4');
    }
    await idle(tester, const Duration(seconds: 2));
  }
  await until(
    tester,
    () => tester.widget<SwitchListTile>(sw).value,
    'own push on',
  );
}

/// The editor's "Speichern": in its sheet, or on the page just opened.
Future<void> save(WidgetTester tester) async {
  await waitFor(tester, find.text(de.commonSave));
  await tester.pump(const Duration(milliseconds: 500));
  var button = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.text(de.commonSave),
  );
  if (button.evaluate().isEmpty) {
    button = find.text(de.commonSave).hitTestable();
    for (var i = 0; i < 10 && button.evaluate().isEmpty; i++) {
      await tester.drag(
        find.byType(Scrollable).hitTestable().first,
        const Offset(0, -300),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }
  await tap(tester, button);
  await tester.pump(const Duration(seconds: 1));
}

/// The Material time picker, typed in.
Future<void> pickTime(WidgetTester tester, DateTime at) async {
  await waitFor(tester, find.byType(Dialog));
  await tap(
    tester,
    find.descendant(
      of: find.byType(Dialog),
      matching: find.byIcon(Icons.keyboard_outlined),
    ),
  );
  final fields = find.descendant(
    of: find.byType(Dialog),
    matching: find.byType(TextField),
  );
  await waitFor(tester, fields);
  await tester.enterText(fields.at(0), '${at.hour}');
  await tester.pump();
  await tester.enterText(fields.at(1), '${at.minute}');
  await tester.pump();
  await tap(tester, find.text('OK').last);
  await dialogClosed(tester);
}

/// The Material time picker opened from within another dialog, typed in.
Future<void> pickTimeInDialog(WidgetTester tester, DateTime at) async {
  final picker = find.byType(TimePickerDialog);
  await waitFor(tester, picker);
  await tap(
    tester,
    find.descendant(of: picker, matching: find.byIcon(Icons.keyboard_outlined)),
  );
  final fields = find.descendant(of: picker, matching: find.byType(TextField));
  await waitFor(tester, fields);
  await tester.enterText(fields.at(0), '${at.hour}');
  await tester.pump();
  await tester.enterText(fields.at(1), '${at.minute}');
  await tester.pump();
  await tap(tester, find.descendant(of: picker, matching: find.text('OK')));
  await waitGone(tester, picker);
  await tester.pump(const Duration(milliseconds: 400));
}

String hm(DateTime t) => DateFormat.Hm('de').format(t);

/// A calendar file with one appointment next year.
String _oneEvent(String title) => [
  'BEGIN:VCALENDAR',
  'VERSION:2.0',
  'PRODID:-//E2E//DE',
  'BEGIN:VEVENT',
  'UID:${title.hashCode}@e2e',
  'DTSTAMP:20261101T120000Z',
  'DTSTART:${DateTime.now().year + 1}0301T100000Z',
  'DTEND:${DateTime.now().year + 1}0301T110000Z',
  'SUMMARY:$title',
  'END:VEVENT',
  'END:VCALENDAR',
  '',
].join('\r\n');

/// The next whole minute at least [ahead] from now.
DateTime minuteAfter(Duration ahead) {
  final t = DateTime.now().add(ahead);
  return DateTime(t.year, t.month, t.day, t.hour, t.minute + 1);
}

// --- what Android shows ----------------------------------------------------

final _android = FlutterLocalNotificationsPlugin()
    .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin
    >()!;

Future<List<ActiveNotification>> shown() => _android.getActiveNotifications();

String describe(List<ActiveNotification> list) =>
    list.map((n) => '${n.title} / ${n.body}').join(' | ');

Future<ActiveNotification> notification(
  WidgetTester tester,
  String what,
  bool Function(ActiveNotification n) matches, {
  Duration timeout = const Duration(minutes: 4),
}) async {
  debugPrint('E2E notification $what');
  final watch = Stopwatch()..start();
  var list = <ActiveNotification>[];
  while (watch.elapsed < timeout) {
    list = await shown();
    for (final n in list) {
      if (matches(n)) return n;
    }
    await idle(tester, const Duration(seconds: 2));
  }
  throw TestFailure('No notification: $what\nShown: ${describe(list)}');
}

// --- server side ---------------------------------------------------------------

/// Writes records like another device of [api]'s member and expects the
/// server to take them.
Future<void> seed(
  FamioApiClient api,
  String collection,
  Map<String, Map<String, Object?>> records,
) async {
  final r = await put(api, collection, records);
  expect(r.rejected.map((x) => x.id), isEmpty, reason: 'seed refused');
}

Future<SosAlert?> openAlertOf(FamioApiClient api, String memberId) async {
  for (final r in (await pull(api, Collections.sosAlerts)).values) {
    final a = SosAlert.fromRecord(r);
    if (a.memberId == memberId && a.open) return a;
  }
  return null;
}

Future<void> resolveAll(FamioApiClient api) async {
  for (final r in (await pull(api, Collections.sosAlerts)).values) {
    final a = SosAlert.fromRecord(r);
    if (a.open) {
      try {
        await api.sosResolve(a.id);
      } on ApiError {
        // Already over.
      }
    }
  }
}

/// Android's service for the alarm's positions (SosLocationService) runs
/// in the foreground. Ending an alarm before that crashed Famio until #536
/// (see the test "SIC-021 hint"); the other tests still wait for it like a
/// person who needs a few seconds to read the screen.
Future<void> liveServiceRunning(WidgetTester tester) async {
  await untilAsync(tester, 'the alarm\'s position service', () async {
    final services = await hostOk('services');
    return services
        .split('* ServiceRecord')
        .any(
          (s) =>
              s.contains('SosLocationService') &&
              s.contains('isForeground=true'),
        );
  }, timeout: const Duration(seconds: 40));
}

/// No siren on the host's speakers, no text messages, nobody called.
Future<void> quietSos(KitFamily f) => seed(f.admin, Collections.sosSettings, {
  SosSettings.recordId: const SosSettings(siren: false, sms: false).toData(),
});

Map<String, Object?> place(
  String id,
  String name,
  (double, double) at, {
  bool shop = false,
  List<String> notify = const [],
}) => Place(
  id: id,
  name: name,
  latitude: at.$1,
  longitude: at.$2,
  radius: 150,
  shop: shop,
  notifyMemberIds: notify,
).toData();

LocationFix fix((double, double) at, {double accuracy = 12}) => LocationFix(
  latitude: at.$1,
  longitude: at.$2,
  accuracy: accuracy,
  at: DateTime.now().toUtc(),
);

/// Removes everything of [collections] this member's app has (so one test's
/// appointments do not show in the next one's overview).
Future<void> clean(SyncEngine engine, Set<String> collections) async {
  // What the server has must be here first.
  await engine.sync();
  for (final c in collections) {
    for (final r in engine.records(c).toList()) {
      engine.delete(c, r.id);
    }
  }
  await engine.sync();
}

/// Lifecycle states reach the app lock only with an initial one (see #290).
void lifecycleForLock(WidgetTester tester) {
  tester.platformDispatcher.initialLifecycleStateTestValue = AppLifecycleState
      .resumed
      .toString();
  addTearDown(tester.platformDispatcher.resetInitialLifecycleState);
  tester.binding.readTestInitialLifecycleStateFromNativeWindow();
}

/// Map tiles come from the internet (OpenStreetMap). Without it the
/// image loader reports every tile as an error, whichever test is running
/// then; those say nothing about Famio and are left out, all other errors
/// still fail the test.
void _quietMapTiles(
  FlutterErrorDetails details,
  void Function(FlutterErrorDetails)? next,
) {
  final what = '${details.exception}';
  if (details.library == 'image resource service' &&
      what.contains('tile.openstreetmap.org')) {
    debugPrint('E2E map tile not loaded (no internet on the emulator)');
    return;
  }
  next?.call(details);
}

/// [testWidgets] with [_quietMapTiles] for the time of the test.
void androidTest(
  String description,
  WidgetTesterCallback callback, {
  bool? skip,
}) => testWidgets(description, (tester) async {
  final next = FlutterError.onError;
  FlutterError.onError = (details) => _quietMapTiles(details, next);
  try {
    await callback(tester);
  } finally {
    FlutterError.onError = next;
  }
}, skip: skip);

void main() {
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // --- before anything is allowed: what a person says no to ---------------

  androidTest('SIC-036 SIC-037 SIC-035 location access denied, '
      'then approximate only', (tester) async {
    await theFamily();
    final state = await startApp(tester, user: 'e2e-kind');
    try {
      // Android asks about notifications (the reminders): no.
      await host('permissions deny 8');
      await section(tester, de.sectionLocation);
      await waitFor(tester, find.text(de.locationShareMyLocation));

      // SIC-036: no location access, no sharing.
      await tap(tester, find.text(de.locationShareLocation));
      final denied = await hostOk('permissions deny 15');
      note('SIC-036 dialogs denied: $denied');
      await waitFor(tester, find.text(de.locationWithoutLocationAccessFamio));
      expect(find.text(de.locationShareMyLocation), findsOneWidget);
      expect((await LocationSharing.status()).enabled, isFalse);
      await snackGone(tester);

      // SIC-037: only the approximate location (and no notifications, the
      // battery optimisation still on).
      await hostOk('grant-coarse');
      await tap(tester, find.text(de.locationShareLocation));
      await host('permissions deny 10');
      // SIC-035: "while the app is open" only: Famio offers "all the time".
      await waitFor(
        tester,
        find.text(de.locationShareLocationBackgroundToo),
        timeout: const Duration(seconds: 40),
      );
      expect(find.text(de.commonLater), findsOneWidget);
      expect(find.text(de.locationTurnSharing), findsOneWidget);
      await tap(tester, find.text(de.commonLater));
      await dialogClosed(tester);
      await waitFor(tester, find.text(de.locationDiagnostics));
      final status = await LocationSharing.status();
      expect(status.enabled, isTrue);
      expect(status.precise, isFalse);
      for (final hint in [
        de.locationOnlyApproximateLocationAllowed,
        de.locationBatteryOptimizationCanStop,
        de.locationNotificationsOff,
      ]) {
        await phoneScroll(tester, find.text(hint));
      }
      expect(
        find.textContaining(de.locationApproximateOnly.trim()),
        findsWidgets,
        reason: 'the diagnosis names the permission',
      );

      // A hint opens the right page of the system: the battery one
      // Android's dialog, the approximate one Famio's app settings.
      await tap(tester, find.text(de.locationBatteryOptimizationCanStop));
      await hostOk('tap-text ${b64('Allow|Zulassen')} 15');
      await idle(tester, const Duration(seconds: 3));
      await until(
        tester,
        () =>
            find.text(de.locationBatteryOptimizationCanStop).evaluate().isEmpty,
        'battery hint gone after allowing',
      );
      await tap(tester, find.text(de.locationOnlyApproximateLocationAllowed));
      await Future<void>.delayed(const Duration(seconds: 3));
      final focus = await hostOk('focus');
      expect(focus, contains('com.android.settings'), reason: focus);
      await hostOk('back');
      await Future<void>.delayed(const Duration(seconds: 2));
      await hostOk('front');
      await idle(tester, const Duration(seconds: 2));
    } finally {
      await finish(tester, state);
    }
  });

  androidTest('GRU-121 SIC-074 HAU-065 hints without notification '
      'permission, camera refused', (tester) async {
    // The first test let Famio off the battery optimisation.
    await hostOk('battery restrict');
    final state = await startApp(tester);
    try {
      await host('permissions deny 8');

      // HAU-065: the camera refused while scanning a barcode.
      await section(tester, de.sectionShopping);
      await phoneScroll(tester, find.byType(PantryCard));
      await tap(tester, find.byType(PantryCard));
      await tap(tester, find.byTooltip(de.pantryScanBarcode));
      await host('permissions deny 12');
      await waitFor(tester, find.text(de.pantryCameraNotAvailablePlease));
      // The hint about Google Play only with the small package (the
      // recognition from Play; tool/android_review_tests.py --play-models).
      final models = await Ocr.models();
      await idle(tester, const Duration(seconds: 1));
      final playHint = find
          .text(de.pantryScannerFirstUse)
          .evaluate()
          .isNotEmpty;
      note('HAU-065 models: $models, Play hint shown: $playHint');
      expect(playHint, models == 'play');
      expect(
        tester
            .widget<Scaffold>(
              find
                  .ancestor(
                    of: find.text(de.pantryCameraNotAvailablePlease),
                    matching: find.byType(Scaffold),
                  )
                  .first,
            )
            .backgroundColor,
        Colors.black,
        reason: 'on a black ground',
      );
      await back(tester);
      await back(tester);

      // GRU-121 / SIC-074: notifications refused, battery optimisation on.
      await pushSettings(tester);
      final sw = find.widgetWithText(SwitchListTile, de.pushPhone);
      await waitFor(tester, sw);
      await until(
        tester,
        () => tester.widget<SwitchListTile>(sw).onChanged != null,
        'switch ready',
      );
      await tap(tester, sw);
      await host('permissions deny 8');
      await until(
        tester,
        () => tester.widget<SwitchListTile>(sw).value,
        'own push on',
      );
      await waitFor(tester, find.text(de.pushAndroidDoesNotAllow));
      await waitFor(tester, find.text(de.pushBatteryOptimizationAndroidMay));

      // "Ausnehmen": Android's battery dialog; allowed, the hint goes.
      await tap(tester, find.widgetWithText(TextButton, de.pushExempt));
      await hostOk('tap-text ${b64('Allow|Zulassen')} 15');
      await idle(tester, const Duration(seconds: 3));
      await until(
        tester,
        () =>
            find.text(de.pushBatteryOptimizationAndroidMay).evaluate().isEmpty,
        'battery hint gone',
      );
      expect(find.text(de.pushAndroidDoesNotAllow), findsOneWidget);

      // "Einstellungen": Famio's page in Android's settings; allowed
      // there, the hint goes on return.
      await tap(
        tester,
        find.widgetWithText(TextButton, de.sectionSettings).last,
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      final focus = await hostOk('focus');
      expect(focus, contains('com.android.settings'), reason: focus);
      // What a person switches on there (and the other permissions).
      await hostOk('grant');
      await hostOk('back');
      await Future<void>.delayed(const Duration(seconds: 2));
      await hostOk('front');
      await idle(tester, const Duration(seconds: 2));
      await until(
        tester,
        () => find.text(de.pushAndroidDoesNotAllow).evaluate().isEmpty,
        'notification hint gone',
      );
    } finally {
      await hostOk('grant');
      await finish(tester, state);
    }
  });

  // --- from here on everything is allowed -----------------------------------

  androidTest('GRU-109 HAU-107 large system font on the main pages, '
      'adding a document', (tester) async {
    await hostOk('grant');
    final problems = <String>[];
    void check(String page) {
      final e = tester.takeException();
      if (e != null) problems.add('$page: $e');
    }

    // Signed in at the normal size (the sign-in page is not one of the
    // pages of the entry), then the system font at its largest.
    final state = await startApp(tester);
    await hostOk('font-scale 2.0');
    try {
      await idle(tester, const Duration(seconds: 2));
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(Scaffold).first),
        ).scale(10),
        greaterThan(18),
        reason: 'system font size reached Famio',
      );
      check('Start');
      await section(tester, de.sectionSettings);
      for (var i = 0; i < 30; i++) {
        await dragList(tester, -300);
        check('Einstellungen');
      }
      await phoneScroll(tester, find.text(de.trashTitle), up: true);
      await tap(tester, find.text(de.trashTitle));
      await idle(tester, const Duration(seconds: 2));
      check('Papierkorb');
      await back(tester);
      await section(tester, de.sectionHome);
      await tap(tester, find.byTooltip(de.inboxTitle));
      await idle(tester, const Duration(seconds: 2));
      check('Familien-Eingang');
      await back(tester);
      await tap(tester, find.byTooltip(de.commonSearch));
      await idle(tester, const Duration(seconds: 2));
      await tester.enterText(find.byType(TextField).first, 'E2E');
      await idle(tester, const Duration(seconds: 2));
      check('Suchen');
      await back(tester);
      note('GRU-109 problems: $problems');
      expect(problems, isEmpty);
    } finally {
      await hostOk('font-scale 1.0');
    }
    try {
      // HAU-107: the sheet on a phone.
      await idle(tester, const Duration(seconds: 2));
      await section(tester, de.sectionDocuments);
      final add = find.byWidgetPredicate(
        (w) =>
            (w is Tooltip && w.message == de.docsAdd) ||
            (w is Text &&
                (w.data == de.docsAdd || w.data == de.docsAddFirstDocument)),
      );
      await tap(tester, add);
      await waitFor(tester, find.text(de.filesChooseFilePhoto));
      expect(find.textContaining('pro Datei'), findsOneWidget);
      expect(find.text(de.importTakePhoto), findsOneWidget);
      expect(find.text(de.filesScanDocument), findsOneWidget);
      expect(find.text(de.filesScanDocumentHint), findsOneWidget);
      await tester.tapAt(const Offset(200, 80));
      await idle(tester, const Duration(seconds: 1));
    } finally {
      await finish(tester, state);
    }
  });

  // Befund (HAU-121, #484): the sheet of a document is a plain Column
  // (documents_screen.dart:254-267, a Column in the bottom sheet): with
  // 45 lines of notes it overflows by 303 px already at normal size, "Öffnen",
  // "Bearbeiten" and "Löschen" end up below the screen and cannot be
  // reached.
  androidTest('HAU-121 long notes in the document sheet', (tester) async {
    await hostOk('grant');
    final state = await startApp(tester);
    final engine = state.engine!;
    final id = uid('doc');
    try {
      engine.saveDocument(
        FamilyDocument(
          id: id,
          title: 'E2E Lange Notiz',
          category: DocumentCategory.other,
          file: null,
          notes: [
            for (var i = 1; i <= 45; i++) 'Zeile $i der Notiz',
          ].join('\n'),
        ),
      );
      await engine.sync();
      for (final scale in [1.0, 2.0]) {
        await hostOk('font-scale $scale');
        await idle(tester, const Duration(seconds: 2));
        await section(tester, de.sectionDocuments);
        await phoneScroll(tester, find.text('E2E Lange Notiz'));
        await tap(tester, find.text('E2E Lange Notiz'));
        await waitFor(tester, find.textContaining('Zeile 1 der Notiz'));
        final overflow = tester.takeException();
        // As a person would: drag the sheet's content up to the buttons.
        for (var i = 0; i < 8; i++) {
          if (find.text(de.commonDelete).hitTestable().evaluate().isNotEmpty) {
            break;
          }
          await tester.dragFrom(const Offset(200, 700), const Offset(0, -300));
          await tester.pump(const Duration(milliseconds: 300));
        }
        final reachable = [
          for (final label in [de.commonEdit, de.commonDelete])
            find.text(label).hitTestable().evaluate().isNotEmpty,
        ];
        note('HAU-121 scale $scale overflow=$overflow reachable=$reachable');
        tester.takeException();
        await tester.tapAt(const Offset(200, 40));
        await idle(tester, const Duration(seconds: 1));
        expect(overflow, isNull, reason: 'overflow at $scale');
        expect(reachable, everyElement(isTrue), reason: 'buttons at $scale');
      }
    } finally {
      await hostOk('font-scale 1.0');
      engine.delete(Collections.documents, id);
      await finish(tester, state);
    }
  }, skip: true);

  // --- "Teilen an Famio" -----------------------------------------------------

  androidTest('GRU-085 ALL-157 GRU-086 ALL-132 HAU-023 GRU-089 text and '
      'links shared to Famio', (tester) async {
    await hostOk('grant');
    // A recipe page, as the browser had it (Famio on a phone fetches it
    // itself).
    final page = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    page.listen((request) {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<html><head><title>E2E Apfelkuchen</title>'
        '<script type="application/ld+json">${jsonEncode({
          '@context': 'https://schema.org',
          '@type': 'Recipe',
          'name': 'E2E Apfelkuchen',
          'recipeYield': '8',
          'recipeIngredient': ['500 g Äpfel', '200 g Mehl', '3 Eier'],
          'recipeInstructions': ['Äpfel schneiden.', '40 Minuten backen.'],
        })}</script></head><body>Kuchen</body></html>',
      );
      request.response.close();
    });
    final state = await startApp(tester);
    final engine = state.engine!;
    try {
      Future<void> share(String text, {String subject = ''}) async {
        await snackGone(tester);
        await hostOk(
          'text-share ${b64(text)}${subject.isEmpty ? '' : ' ${b64(subject)}'}',
        );
        await waitFor(
          tester,
          find.text(de.shareTitle),
          timeout: const Duration(minutes: 1),
        );
      }

      bool offered(String target) => find.text(target).evaluate().isNotEmpty;

      // ALL-132: without a shopping list Famio makes "Einkauf".
      await clean(engine, {
        Collections.shoppingLists,
        Collections.shoppingItems,
      });
      await share('- Milch\n2. Brot\n[ ] Eier');
      expect(find.text(de.shareItems(3)), findsOneWidget);
      await tap(tester, find.text(de.shareToShopping));
      await waitFor(
        tester,
        find.text(de.shareAddedToList(3, de.sectionShopping)),
      );
      final first = engine.shoppingLists.single;
      expect(first.name, de.sectionShopping);
      expect(engine.shoppingItems(first.id).map((i) => i.name).toSet(), {
        'Milch',
        'Brot',
        'Eier',
      });
      // Shared again: all open on the list already, and the notice says so.
      await snackGone(tester);
      await share('- Milch\n2. Brot\n[ ] Eier');
      await tap(tester, find.text(de.shareToShopping));
      await waitFor(
        tester,
        find.text(de.shareAllOnListAlready(de.sectionShopping)),
      );
      final milk = engine
          .shoppingItems(first.id)
          .where((i) => i.name == 'Milch' && !i.checked)
          .length;
      expect(milk, 1, reason: 'ALL-132: not twice on the list');

      // GRU-086: with two lists Famio asks which one, then shows it.
      final b = ShoppingList(id: uid('list'), name: 'E2E Liste B');
      engine.saveShoppingList(b);
      await engine.sync();
      await share('- Milch\n2. Brot\n[ ] Eier');
      await tap(tester, find.text(de.shareToShopping));
      await waitFor(tester, find.text(de.shareWhichList));
      await tap(tester, find.text('E2E Liste B').last);
      await waitFor(tester, find.text(de.shareAddedToList(3, 'E2E Liste B')));
      expect(engine.shoppingItems(b.id).map((i) => i.name).toList()..sort(), [
        'Brot',
        'Eier',
        'Milch',
      ]);
      // The shopping section is open, with the list.
      await waitFor(tester, find.text('E2E Liste B'));
      expect(find.textContaining('- Milch'), findsNothing);

      // GRU-085: the sheet for a text, "Als Aufgabe".
      await snackGone(tester);
      await share('E2E Rasen maehen\nVor dem Regen am Samstag');
      expect(find.textContaining('E2E Rasen maehen'), findsWidgets);
      expect(offered(de.shareToInbox), isTrue);
      expect(offered(de.shareToShopping), isTrue);
      expect(find.text(de.shareItems(2)), findsOneWidget);
      expect(offered(de.shareAsTask), isTrue);
      expect(offered(de.shareAsNote), isTrue);
      expect(offered(de.shareToChat), isTrue);
      expect(offered(de.shareAsRecipe), isFalse, reason: 'no link');
      expect(offered(de.shareAsDocument), isFalse, reason: 'no file');
      await tap(tester, find.text(de.shareAsTask));
      await waitFor(tester, fieldWith('E2E Rasen maehen'));
      expect(fieldWith('Vor dem Regen am Samstag'), findsOneWidget);
      await save(tester);
      await until(
        tester,
        () => engine.tasks.any(
          (t) =>
              t.title == 'E2E Rasen maehen' &&
              t.notes == 'Vor dem Regen am Samstag',
        ),
        'task saved',
      );

      // ALL-157: as a note, first line the title.
      await share('E2E Notiz vom Handy\nZeile zwei\nZeile drei');
      await tap(tester, find.text(de.shareAsNote));
      await waitFor(tester, fieldWith('E2E Notiz vom Handy'));
      expect(fieldWith('Zeile zwei\nZeile drei'), findsOneWidget);
      await save(tester);
      await until(
        tester,
        () => engine.notes.any(
          (n) =>
              n.title == 'E2E Notiz vom Handy' &&
              n.text == 'Zeile zwei\nZeile drei',
        ),
        'note saved',
      );

      // GRU-085 with a link, HAU-023: "Als Rezept importieren".
      final link = 'http://127.0.0.1:${page.port}/apfelkuchen';
      await share('Schau mal: $link', subject: 'E2E Rezept');
      expect(offered(de.shareAsRecipe), isTrue);
      await tap(tester, find.text(de.shareAsRecipe));
      await waitFor(
        tester,
        fieldWith('E2E Apfelkuchen'),
        timeout: const Duration(seconds: 40),
      );
      expect(fieldWith(link), findsOneWidget);
      await save(tester);
      await until(
        tester,
        () => engine.recipes.any((r) => r.title == 'E2E Apfelkuchen'),
        'recipe saved',
      );
      // Famio went to "Essen".
      await waitFor(tester, find.text(de.sectionMeals).hitTestable());
      await dismissTip(tester);

      // GRU-089: all of it went to the running Famio, no second one.
      final tasks = await hostOk('tasks');
      note('GRU-089 tasks/activities: $tasks');
      expect(tasks, '1 1');
    } finally {
      await page.close(force: true);
      await finish(tester, state);
    }
  });

  androidTest('GRU-087 ALL-173 GRU-089 two pictures shared from the files '
      'app', (tester) async {
    await hostOk('grant');
    await hostOk('file e2e-bild-1.png png 2600 2600 noise');
    await hostOk('file e2e-bild-2.png png 2600 2600 noise');
    final state = await startApp(tester);
    final engine = state.engine!;
    try {
      Future<void> share() async {
        await snackGone(tester);
        await hostOk('share-files e2e-bild-1.png e2e-bild-2.png');
        await waitFor(
          tester,
          find.text(de.shareTitle),
          timeout: const Duration(minutes: 1),
        );
      }

      final before = engine.documents.length;
      await share();
      expect(find.text(de.shareToShopping), findsNothing);
      expect(find.text(de.shareAsNote), findsNothing);
      expect(find.text(de.shareFiles(2)), findsOneWidget);
      await tap(tester, find.text(de.shareAsDocument));
      // One editor after the other.
      for (var i = 0; i < 2; i++) {
        await save(tester);
        await until(
          tester,
          () => engine.documents.length == before + i + 1,
          'document ${i + 1}',
          timeout: const Duration(seconds: 60),
        );
      }
      expect(
        engine.documents.map((d) => d.file?.name).whereType<String>(),
        containsAll(['e2e-bild-1.png', 'e2e-bild-2.png']),
      );

      // ALL-173: the same pictures into the family chat.
      await share();
      await tap(tester, find.text(de.shareToChat));
      var uploading = false;
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 60) &&
          find.text(de.shareSent).evaluate().isEmpty) {
        if (find.text(de.shareUploading).evaluate().isNotEmpty) {
          uploading = true;
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      note('GRU-087 "Wird hochgeladen" seen: $uploading');
      expect(find.text(de.shareSent), findsOneWidget);
      await engine.sync();
      final sent = [
        for (final r in engine.records(Collections.chatMessages))
          ChatMessage.fromRecord(r),
      ].where((m) => m.attachment?.name.startsWith('e2e-bild-') ?? false);
      expect(sent.map((m) => m.attachment!.name).toSet(), {
        'e2e-bild-1.png',
        'e2e-bild-2.png',
      });
      expect(sent.every((m) => m.chatId == ChatIds.family), isTrue);
      expect(sent.first.attachment!.mime, startsWith('image/'));

      // GRU-089: shared while Famio was in the background: still one.
      final tasks = await hostOk('tasks');
      note('GRU-089 after files: $tasks');
      expect(tasks, '1 1');
    } finally {
      await finish(tester, state);
    }
  });

  androidTest('GRU-088 HAU-023 sharing as a guest', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    // An area switched off is not offered (was a hint).
    await f.admin.updateServerSettings({
      'hiddenModules': [FamioSection.shopping.name],
    });
    final state = await startApp(tester, user: 'e2e-gast');
    try {
      await hostOk(
        'text-share ${b64('E2E Gast teilt\nhttp://127.0.0.1:9/kuchen')}',
      );
      await waitFor(
        tester,
        find.text(de.shareTitle),
        timeout: const Duration(minutes: 1),
      );
      bool offered(String t) => find.text(t).evaluate().isNotEmpty;
      expect(offered(de.shareToInbox), isFalse);
      expect(offered(de.shareAsRecipe), isFalse);
      expect(offered(de.shareAsDocument), isFalse);
      expect(offered(de.shareAsTask), isTrue);
      expect(offered(de.shareToChat), isTrue);
      // Was a hint: the shopping list with the area off, and a note, which
      // guests may not write.
      expect(offered(de.shareToShopping), isFalse);
      expect(offered(de.shareAsNote), isFalse);
      await tester.tapAt(const Offset(200, 60));
    } finally {
      await f.admin.updateServerSettings({'hiddenModules': null});
      await finish(tester, state);
    }
  });

  androidTest('KAL-095 SIC-023 calendar file opened with Famio, an '
      'emergency intent of another app', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final year = DateTime.now().year + 1;
    final ics = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//E2E//DE',
      'BEGIN:VEVENT',
      'UID:e2e-sommerfest@e2e',
      'DTSTAMP:20261101T120000Z',
      'DTSTART:${year}0604T150000Z',
      'DTEND:${year}0604T180000Z',
      'SUMMARY:E2E Sommerfest',
      'END:VEVENT',
      'BEGIN:VEVENT',
      'UID:e2e-laterne@e2e',
      'DTSTAMP:20261101T120000Z',
      'DTSTART;VALUE=DATE:${year}1111',
      'DTEND;VALUE=DATE:${year}1112',
      'SUMMARY:E2E Laternenumzug',
      'END:VEVENT',
      'END:VCALENDAR',
      '',
    ].join('\r\n');
    await hostOk('file e2e-termine.ics ${b64(ics)}');
    final state = await startApp(tester);
    try {
      await hostOk('open-file e2e-termine.ics');
      await waitFor(
        tester,
        find.text(de.importIcsFile),
        timeout: const Duration(minutes: 1),
      );
      await waitFor(tester, find.textContaining('E2E Sommerfest'));
      expect(find.textContaining('E2E Laternenumzug'), findsWidgets);
      // In the calendar: its item in the bar is the selected one.
      expect(
        find.descendant(
          of: find.byType(Scaffold).first,
          matching: find.text(de.sectionCalendar),
        ),
        findsWidgets,
        reason: 'Famio switched to the calendar',
      );
      // Android no longer hands the file's address to Flutter as a deep
      // link (was a hint).
      await idle(tester, const Duration(seconds: 2));
      final deepLink = tester.takeException();
      note('KAL-095 deep link: $deepLink');
      expect(deepLink, isNull);
      expect((await hostOk('tasks')), '1 1');
      await tester.tapAt(const Offset(200, 60));
      await idle(tester, const Duration(seconds: 1));

      // SIC-023: started by another app (no secret, a wrong one).
      await hostOk('sos foreign');
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 9)) {
        expect(find.text(de.sosEmergencyCall), findsNothing);
        await idle(tester, const Duration(milliseconds: 300));
      }
      expect(find.text(de.sosAlarmSent), findsNothing);
      expect(await openAlertOf(f.admin, state.me!.id), isNull);
    } finally {
      await finish(tester, state);
    }
  });

  // --- what the catalog's hints suspected ------------------------------------

  // Was a Befund (ALL-132): shared again, nothing was added and Famio still
  // reported three. Now it says everything is on the list already.
  androidTest('ALL-132 hint: lines already on the list count as added', (
    tester,
  ) async {
    await hostOk('grant');
    final state = await startApp(tester);
    final engine = state.engine!;
    try {
      await clean(engine, {
        Collections.shoppingLists,
        Collections.shoppingItems,
      });
      final list = ShoppingList(id: uid('list'), name: 'E2E Hinweis');
      engine.saveShoppingList(list);
      for (final name in ['Milch', 'Brot', 'Eier']) {
        engine.saveShoppingItem(
          ShoppingItem(id: uid('item'), listId: list.id, name: name),
        );
      }
      await engine.sync();
      await hostOk('text-share ${b64('- Milch\n2. Brot\n[ ] Eier')}');
      await waitFor(
        tester,
        find.text(de.shareTitle),
        timeout: const Duration(minutes: 1),
      );
      await tap(tester, find.text(de.shareToShopping));
      await waitFor(tester, find.text(de.shareAllOnListAlready('E2E Hinweis')));
      final said = de.shareAllOnListAlready('E2E Hinweis');
      final open = engine
          .shoppingItems(list.id)
          .where((i) => !i.checked)
          .map((i) => '${i.name} ${i.quantity}'.trim())
          .toList();
      note('ALL-132 hint: notice "$said", open items now $open');
      expect(open, hasLength(3), reason: 'nothing new on the list');
      expect(
        said,
        isNot(de.shareAddedToList(3, 'E2E Hinweis')),
        reason: 'three items said to be added, none were',
      );
    } finally {
      await finish(tester, state);
    }
  });

  // Was a Befund (GRU-088): "Als Notiz auf die Pinnwand" was offered to
  // guests, and the note they saved vanished without a word (guests may not
  // write notes). Now it is not offered.
  androidTest('GRU-088 hint: a guest\'s shared text as a note', (tester) async {
    await hostOk('grant');
    final state = await startApp(tester, user: 'e2e-gast');
    try {
      await hostOk('text-share ${b64('E2E Gast Notiz\nZweite Zeile')}');
      await waitFor(
        tester,
        find.text(de.shareTitle),
        timeout: const Duration(minutes: 1),
      );
      expect(find.text(de.shareAsNote), findsNothing);
      expect(find.text(de.shareAsTask), findsOneWidget);
      await tester.tapAt(const Offset(200, 60));
    } finally {
      await finish(tester, state);
    }
  });

  // Was a Befund (KAL-095): a calendar file opened with Famio also reached
  // Flutter as a deep link and threw "Could not find a generator for
  // route". Deep linking is off now, and an unknown route is dropped.
  androidTest('KAL-095 hint: opening a file is no deep link', (tester) async {
    await hostOk('grant');
    await hostOk('file e2e-link.ics ${b64(_oneEvent('E2E Tiefer Link'))}');
    final state = await startApp(tester);
    try {
      await hostOk('open-file e2e-link.ics');
      await waitFor(
        tester,
        find.textContaining('E2E Tiefer Link'),
        timeout: const Duration(minutes: 1),
      );
      await idle(tester, const Duration(seconds: 2));
      final error = tester.takeException();
      note('KAL-095 hint: $error');
      expect(error, isNull);
    } finally {
      await finish(tester, state);
    }
  });

  // --- the home screen widget -------------------------------------------------

  androidTest('GRU-149 GRU-150 GRU-151 widget: lines, confidential, '
      'placing, signing out', (tester) async {
    await hostOk('grant');
    final state = await startApp(tester);
    final engine = state.engine!;
    final me = state.me!.id;
    try {
      await clean(engine, {
        Collections.events,
        Collections.children,
        Collections.childLogs,
        Collections.mealPlan,
        Collections.tasks,
        Collections.shoppingLists,
        Collections.shoppingItems,
      });
      final now = DateTime.now();
      final day = DateUtils.dateOnly(now);
      if (now.hour >= 22) {
        markTestSkipped('too late in the day for today\'s widget');
        return;
      }
      final at = now.add(const Duration(minutes: 30));
      engine.saveEvent(
        CalendarEvent(
          id: uid('ev'),
          title: 'E2E Psychotherapie',
          start: at,
          end: at.add(const Duration(minutes: 50)),
          confidential: true,
          memberIds: [me],
        ),
      );
      final mine = CalendarEvent(
        id: uid('ev'),
        title: 'E2E Nur ich Termin',
        start: at.add(const Duration(minutes: 10)),
        end: at.add(const Duration(minutes: 70)),
      );
      engine.put(Collections.events, mine.id, {
        ...mine.toData(),
        SyncRecord.visibilityKey: [me],
      });
      engine.saveMeal(
        PlannedMeal(
          id: uid('meal'),
          date: day,
          slot: MealSlot.dinner,
          title: 'E2E Pfannkuchen',
        ),
      );
      engine.saveTask(Task(id: uid('task'), title: 'E2E Wäsche', due: day));
      final list = ShoppingList(id: uid('list'), name: 'E2E Widget');
      engine.saveShoppingList(list);
      for (final name in ['E2E Milch', 'E2E Brot']) {
        engine.saveShoppingItem(
          ShoppingItem(id: uid('item'), listId: list.id, name: name),
        );
      }
      final child = Child(
        id: uid('child'),
        name: 'E2E Baby',
        birthDate: DateTime(now.year - 1, 3, 3),
        guardianIds: [me],
      );
      engine.saveChild(child);
      final asleep = now.subtract(const Duration(minutes: 40));
      engine.saveChildLog(
        ChildLog(
          id: uid('log'),
          childId: child.id,
          kind: LogKind.sleep,
          start: asleep,
        ),
      );
      await engine.sync();

      Future<List<String?>> widget() async => [
        await HomeWidget.getWidgetData<String>('date'),
        for (var i = 0; i < 5; i++)
          await HomeWidget.getWidgetData<String>('text$i'),
      ];
      final date = DateFormat.MMMEd('de').format(now);
      final lines = await untilAsync(tester, 'widget filled', () async {
        final w = await widget();
        return w.first == date && w.contains('E2E Pfannkuchen') ? w : null;
      });
      note('GRU-149 widget: $lines');
      // Two appointments, the meal, the tasks, the shopping: five rows.
      expect(lines.skip(1), everyElement(isNotNull));
      expect(lines[1], de.eventBusy, reason: 'confidential first (GRU-150)');
      // Was a hint: "Nur ich" showed its title, now it is busy as well.
      expect(lines[2], de.eventBusy, reason: '"Nur ich" (GRU-150)');
      expect(lines.contains('E2E Nur ich Termin'), isFalse);
      expect(lines, contains(de.widgetTasksToday(1)));
      expect(lines, contains(de.widgetThingsToBuy(2)));
      expect(lines.contains('E2E Psychotherapie'), isFalse);
      // A packing list is nothing to buy (the shop's notice leaves it out
      // too), and the widget does not count it (was a hint).
      final packing = ShoppingList(
        id: uid('list'),
        name: 'E2E Packliste',
        packing: true,
      );
      engine.saveShoppingList(packing);
      for (final name in ['E2E Zelt', 'E2E Schlafsack', 'E2E Taschenlampe']) {
        engine.saveShoppingItem(
          ShoppingItem(id: uid('item'), listId: packing.id, name: name),
        );
      }
      await idle(tester, const Duration(seconds: 5));
      final withPacking = await widget();
      note('GRU-149 with a packing list of 3: $withPacking');
      expect(withPacking, contains(de.widgetThingsToBuy(2)));
      for (final i in engine.shoppingItems(packing.id)) {
        engine.delete(Collections.shoppingItems, i.id);
      }
      engine.delete(Collections.shoppingLists, packing.id);
      // Nothing left to buy: room for the sleeping baby.
      for (final i in engine.shoppingItems(list.id)) {
        engine.delete(Collections.shoppingItems, i.id);
      }
      final asleepLine = de.widgetNameAsleepSinceTime(
        'E2E Baby',
        DateFormat.jm('de').format(asleep),
      );
      final withBaby = await untilAsync(tester, 'the sleeping baby', () async {
        final w = await widget();
        return w.contains(asleepLine) ? w : null;
      }, timeout: const Duration(seconds: 20));
      note('GRU-149 with the baby: $withBaby');

      // A new task: the widget follows within seconds.
      engine.saveTask(Task(id: uid('task'), title: 'E2E Bügeln', due: day));
      final watch = Stopwatch()..start();
      await untilAsync(
        tester,
        'widget updated',
        () async => (await widget()).contains(de.widgetTasksToday(2)),
        timeout: const Duration(seconds: 20),
      );
      note('GRU-149 updated after ${watch.elapsed.inMilliseconds} ms');

      // Placing it: the launcher's dialog, then the home screen.
      await section(tester, de.sectionSettings);
      await phoneScroll(tester, find.text(de.settingsWidget));
      await tap(tester, find.text(de.settingsWidget));
      final pin = await host(
        'tap-text ${b64('Add automatically|Add to home screen|Add|Hinzufügen')} 15',
      );
      note('GRU-149 pin dialog: ${pin.ok} ${pin.out}');
      await Future<void>.delayed(const Duration(seconds: 3));
      await hostOk('home');
      await Future<void>.delayed(const Duration(seconds: 3));
      final onHome = await hostOk(
        'find-text ${b64('E2E Pfannkuchen|$date')} 8',
      );
      note('GRU-149 on the home screen: "$onHome"');
      await hostOk('front');
      await idle(tester, const Duration(seconds: 2));

      // GRU-151: signed out, the widget is empty.
      await state.signOut();
      await idle(tester, const Duration(seconds: 2));
      final empty = await widget();
      note('GRU-151 after sign-out: $empty');
      expect(empty.first, '');
      expect(empty.skip(1), everyElement(isNull));
      if (onHome.isNotEmpty) {
        await hostOk('home');
        await Future<void>.delayed(const Duration(seconds: 3));
        final still = await hostOk('find-text ${b64('E2E Pfannkuchen')} 4');
        note('GRU-151 home screen after sign-out: "$still"');
        expect(still, isEmpty);
        await hostOk('front');
      }
    } finally {
      await finish(tester, state);
    }
  });

  // --- notifications -------------------------------------------------------------

  // Was a Befund (GRU-150): an appointment only some members see ("Nur
  // ich", a private calendar) showed its title on the home screen widget.
  // Now it says "Belegt", as the wall display does.
  androidTest('GRU-150 hint: restricted appointments in the widget', (
    tester,
  ) async {
    await hostOk('grant');
    final state = await startApp(tester);
    final engine = state.engine!;
    final me = state.me!.id;
    try {
      await clean(engine, {Collections.events});
      final at = DateTime.now().add(const Duration(minutes: 20));
      final mine = CalendarEvent(
        id: uid('ev'),
        title: 'E2E Geschenk kaufen',
        start: at,
        end: at.add(const Duration(minutes: 30)),
      );
      engine.put(Collections.events, mine.id, {
        ...mine.toData(),
        SyncRecord.visibilityKey: [me],
      });
      final shown = await untilAsync(
        tester,
        'widget filled',
        () => HomeWidget.getWidgetData<String>('text0'),
      );
      note('GRU-150 hint: "$shown"');
      expect(shown, de.eventBusy);
    } finally {
      await finish(tester, state);
    }
  });

  androidTest('GRU-119 SIC-071 KAL-032 KAL-033 KAL-054 GRU-120 SIC-073 own '
      'push, reminders, contents on and off', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final state = await startApp(tester);
    final engine = state.engine!;
    final me = state.me!.id;
    try {
      await clean(engine, {Collections.events, Collections.medications});

      // GRU-119 / SIC-071: own push and its test message.
      await pushSettings(tester);
      await ownPushOn(tester);
      await tap(tester, find.text(de.pushSendTest));
      await waitFor(tester, find.text(de.pushTestMessageItsWay));
      await notification(
        tester,
        'test message',
        (n) => n.body == 'Benachrichtigungen funktionieren 🎉',
        timeout: const Duration(minutes: 1),
      );
      // Round 1, contents shown: all due at [t1].
      final t1 = minuteAfter(const Duration(seconds: 110));
      CalendarEvent event(
        String title,
        DateTime start, {
        List<String> who = const [],
        bool confidential = false,
        String location = '',
        int? remind = 15,
        String? bringer,
        String? picker,
        Duration length = const Duration(hours: 1),
        bool allDay = false,
      }) => CalendarEvent(
        id: uid('ev'),
        title: title,
        start: start,
        end: start.add(length),
        memberIds: who,
        confidential: confidential,
        location: location,
        reminderMinutes: remind,
        bringerId: bringer,
        pickerId: picker,
        allDay: allDay,
      );
      final soon = t1.add(const Duration(minutes: 15));
      final talk = event(
        'E2E Elternsprechtag',
        soon,
        who: [me],
        location: 'Schule Raum 3',
      );
      final secret = event(
        'E2E Therapie',
        soon,
        who: [me],
        confidential: true,
        location: 'Praxis Mitte',
      );
      for (final e in [
        talk,
        secret,
        event('E2E Nur Bea', soon, who: [f.bea.id]),
        event('E2E Familienfest', soon),
        // KAL-054: 30 minutes before the start for the one who brings,
        // 15 before the end for the one who picks up.
        event(
          'E2E Training',
          t1.add(const Duration(minutes: 30)),
          who: [f.kid.id],
          remind: null,
          bringer: me,
        ),
        event(
          'E2E Schwimmen',
          t1.subtract(const Duration(minutes: 30)),
          who: [f.kid.id],
          remind: null,
          picker: me,
          length: const Duration(minutes: 45),
        ),
        event(
          'E2E Bea faehrt',
          t1.add(const Duration(minutes: 30)),
          who: [f.kid.id],
          remind: null,
          bringer: f.bea.id,
        ),
        event(
          'E2E Ganztags',
          DateUtils.dateOnly(t1).add(const Duration(days: 1)),
          remind: null,
          bringer: me,
          allDay: true,
          length: const Duration(days: 1),
        ),
      ]) {
        engine.saveEvent(e);
      }
      engine.saveMedication(
        Medication(
          id: uid('med'),
          name: 'E2E Ibuprofen',
          personName: 'E2E Lena',
          dose: '1 Tablette',
          times: [hm(t1)],
          start: DateUtils.dateOnly(t1),
        ),
      );
      await engine.sync();
      final hello = uid('chat');
      await seed(bea, Collections.chatMessages, {
        hello: ChatMessage(
          id: hello,
          chatId: ChatIds.family,
          authorId: f.bea.id,
          sentAt: DateTime.now().toUtc(),
          text: 'E2E Hallo von Bea',
        ).toData(),
      });

      final chat = await notification(
        tester,
        'chat with contents',
        (n) => n.body == 'E2E Hallo von Bea',
        timeout: const Duration(minutes: 1),
      );
      expect(chat.title, 'E2E Bea · Familie');

      final reminders = {
        'KAL-032 participant': (ActiveNotification n) =>
            n.title == 'E2E Elternsprechtag' &&
            n.body == '${dateTimeLabel(talk.start)} · Schule Raum 3',
        'KAL-032 whole family': (ActiveNotification n) =>
            n.title == 'E2E Familienfest',
        'KAL-033 confidential': (ActiveNotification n) =>
            n.title == de.commonEvent && n.body == dateTimeLabel(secret.start),
        'KAL-054 bring': (ActiveNotification n) =>
            n.title == '🚗 Bringen: E2E Training',
        'KAL-054 pick up': (ActiveNotification n) =>
            n.title == '🚗 Abholen: E2E Schwimmen',
        'GRU-120 medication': (ActiveNotification n) =>
            n.title == 'E2E Ibuprofen für E2E Lena' && n.body == '1 Tablette',
      };
      for (final MapEntry(key: what, value: matches) in reminders.entries) {
        await notification(tester, what, matches);
      }
      final late = DateTime.now().difference(t1);
      note('KAL-032 reminders shown ${late.inSeconds} s after their time');
      expect(late, lessThan(const Duration(seconds: 90)));
      await idle(tester, const Duration(seconds: 10));
      final all = await shown();
      note('round 1: ${describe(all)}');
      for (final title in [
        'E2E Nur Bea',
        '🚗 Bringen: E2E Bea faehrt',
        '🚗 Bringen: E2E Ganztags',
        'E2E Therapie',
      ]) {
        expect(all.where((n) => n.title == title), isEmpty, reason: title);
      }
      expect(
        all.where((n) => '${n.title} ${n.body}'.contains('Praxis Mitte')),
        isEmpty,
      );
      // Lock screen: never the contents.
      note('lock screen: ${await hostOk('notifications-private')}');

      // Round 2: "Inhalte anzeigen" off.
      final contents = find.widgetWithText(SwitchListTile, de.pushShowContents);
      await phoneScroll(tester, contents, up: true);
      await tap(tester, contents);
      await until(
        tester,
        () => !tester.widget<SwitchListTile>(contents).value,
        'contents off',
      );
      final t2 = minuteAfter(const Duration(seconds: 75));
      final secret2 = event(
        'E2E Therapie Zwei',
        t2.add(const Duration(minutes: 15)),
        who: [me],
        confidential: true,
        location: 'Praxis Nord',
      );
      engine.saveEvent(secret2);
      engine.saveMedication(
        Medication(
          id: uid('med'),
          name: 'E2E Penicillin',
          personName: 'E2E Lena',
          dose: '5 ml',
          times: [hm(t2)],
          start: DateUtils.dateOnly(t2),
        ),
      );
      await engine.sync();
      await idle(tester, const Duration(seconds: 4));
      final hidden = uid('chat');
      await seed(bea, Collections.chatMessages, {
        hidden: ChatMessage(
          id: hidden,
          chatId: ChatIds.family,
          authorId: f.bea.id,
          sentAt: DateTime.now().toUtc(),
          text: 'E2E Geheim von Bea',
        ).toData(),
      });
      await notification(
        tester,
        'chat without contents',
        (n) => n.title == 'Famio' && n.body == 'Neue Nachricht',
        timeout: const Duration(minutes: 1),
      );
      final watch = Stopwatch()..start();
      await untilAsync(
        tester,
        'two neutral reminders',
        () async =>
            (await shown())
                .where(
                  (n) =>
                      n.title == AppEnv.appName &&
                      n.body == de.remindersOpenFamioDetails,
                )
                .length >=
            2,
        timeout: const Duration(minutes: 4),
      );
      note('round 2 after ${watch.elapsed.inSeconds} s');
      await idle(tester, const Duration(seconds: 5));
      final neutral = await shown();
      note('round 2: ${describe(neutral)}');
      for (final word in ['Penicillin', 'E2E Lena', 'Geheim', 'Bea', 'Nord']) {
        expect(
          neutral.where(
            (n) =>
                '${n.title} ${n.body}'.contains(word) &&
                !(n.body ?? '').contains('E2E Hallo von Bea') &&
                n.title != 'E2E Ibuprofen für E2E Lena',
          ),
          isEmpty,
          reason: word,
        );
      }
      note('lock screen: ${await hostOk('notifications-private')}');

      // KAL-054 in English: "Drop off" (was a hint: still "Bringen").
      await state.setLanguage('en');
      final english = upcomingReminders(
        events: [
          event(
            'E2E Lift',
            DateTime.now().add(const Duration(hours: 1)),
            bringer: me,
            remind: null,
          ),
        ],
        tasks: const [],
        memberId: me,
        from: DateTime.now(),
        to: DateTime.now().add(const Duration(hours: 2)),
      );
      note('KAL-054 English title: ${english.map((r) => r.title).toList()}');
      expect(english.map((r) => r.title), ['🚗 Drop off: E2E Lift']);
      await state.setLanguage('de');
      await tap(tester, contents);
    } finally {
      await state.setLanguage('de');
      await finish(tester, state);
    }
  });

  androidTest('GRU-119 SIC-071 the lasting notice "Famio ist bereit"', (
    tester,
  ) async {
    await hostOk('grant');
    final state = await startApp(tester);
    try {
      await pushSettings(tester);
      await ownPushOn(tester);
      // The service starts its notice a moment after the switch.
      var ready = <ActiveNotification>[];
      var listed = '';
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 40)) {
        await idle(tester, const Duration(seconds: 3));
        ready = (await shown())
            .where(
              (n) =>
                  n.title == 'Famio ist bereit' || n.title == 'Famio is ready',
            )
            .toList();
        // What Android itself lists (also notifications of the service).
        listed = await hostOk('notifications-private');
        if (ready.isNotEmpty || listed.contains('famio_connection')) break;
      }
      final services = await hostOk('services');
      note(
        'GRU-119 lasting notice: ${ready.map((n) => n.title).toList()}, '
        'Android lists: $listed; services: $services',
      );
      expect(
        ready.isNotEmpty || listed.contains('famio_connection'),
        isTrue,
        reason: 'no lasting notice of the connection',
      );
      // Lasting: a foreground service with that notice, not to be swiped.
      expect(services, contains('isForeground=true'));
      expect(services, contains('channel=famio_connection'));
      expect(services, contains('NO_CLEAR'));
    } finally {
      await finish(tester, state);
    }
  });

  androidTest('SIC-059 SIC-061 SIC-030 arrival and leaving, the shop, a '
      'check-in for the adults', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final kid = await sessionOf(f.kid);
    final bea = await sessionOf(f.bea);
    final me = f.adminMember.id;
    final schoolId = uid('place');
    final shopId = uid('place');
    final bakeryId = uid('place');
    await seed(f.admin, Collections.places, {
      schoolId: place(schoolId, 'E2E Schule', _school, notify: [me]),
      shopId: place(shopId, 'E2E Supermarkt', _shop, shop: true),
      bakeryId: place(bakeryId, 'E2E Baecker', _bakery, shop: true),
    });
    final beaFrom = (await bea.notices()).last;
    final kidFrom = (await kid.notices()).last;
    final state = await startApp(tester);
    try {
      // Seven open things on one list (only this one), and a packing list.
      final engine = state.engine!;
      await clean(engine, {
        Collections.shoppingLists,
        Collections.shoppingItems,
      });
      final list = ShoppingList(id: uid('list'), name: 'E2E Wocheneinkauf');
      final packing = ShoppingList(
        id: uid('list'),
        name: 'E2E Packliste',
        packing: true,
      );
      engine
        ..saveShoppingList(list)
        ..saveShoppingList(packing)
        ..saveShoppingItem(
          ShoppingItem(id: uid('item'), listId: packing.id, name: 'E2E Zelt'),
        );
      for (final name in [
        'Milch',
        'Brot',
        'Eier',
        'Kaese',
        'Aepfel',
        'Butter',
        'Reis',
      ]) {
        engine.saveShoppingItem(
          ShoppingItem(id: uid('item'), listId: list.id, name: 'E2E $name'),
        );
      }
      await engine.sync();
      await pushSettings(tester);
      await ownPushOn(tester);
      await section(tester, de.sectionHome);

      // SIC-059: the child arrives at school (the child's phone).
      await kid.reportLocation([fix(_away)]);
      await Future<void>.delayed(const Duration(seconds: 2));
      await kid.reportLocation([fix(_school)]);
      await notification(
        tester,
        'arrival',
        (n) => n.body == 'E2E Kind ist bei „E2E Schule“ angekommen',
        timeout: const Duration(minutes: 1),
      );
      await section(tester, de.sectionLocation);
      await waitFor(
        tester,
        find.textContaining('Bei „E2E Schule“ seit'),
        timeout: const Duration(seconds: 40),
      );
      await kid.reportLocation([fix(_away)]);
      await notification(
        tester,
        'leaving',
        (n) => n.body == 'E2E Kind hat „E2E Schule“ verlassen',
        timeout: const Duration(minutes: 1),
      );

      // SIC-061: arriving at the shop (another device of this adult).
      final mine = await kitAdminApi();
      await mine.reportLocation([fix(_away)]);
      await Future<void>.delayed(const Duration(seconds: 2));
      await mine.reportLocation([fix(_shop)]);
      final shop = await notification(
        tester,
        'shop',
        (n) => n.title == 'Einkauf bei E2E Supermarkt',
        timeout: const Duration(minutes: 1),
      );
      note('SIC-061: ${shop.body}');
      expect(shop.body, startsWith('7 offen: E2E '));
      expect(shop.body, endsWith('…'));
      expect(shop.body, isNot(contains('Zelt')));
      // Back within three hours: quiet.
      await mine.reportLocation([fix(_away)]);
      await Future<void>.delayed(const Duration(seconds: 2));
      await mine.reportLocation([fix(_shop)]);
      await idle(tester, const Duration(seconds: 20));
      expect(
        (await shown()).where((n) => n.title == 'Einkauf bei E2E Supermarkt'),
        hasLength(1),
      );
      // Nothing open (the packing list does not count): another shop
      // stays quiet; with one thing on the list again it speaks.
      for (final i in engine.shoppingItems(list.id)) {
        engine.delete(Collections.shoppingItems, i.id);
      }
      await engine.sync();
      await mine.reportLocation([fix(_away)]);
      await Future<void>.delayed(const Duration(seconds: 2));
      await mine.reportLocation([fix(_bakery)]);
      await idle(tester, const Duration(seconds: 20));
      bool bakery(ActiveNotification n) => n.title == 'Einkauf bei E2E Baecker';
      expect((await shown()).where(bakery), isEmpty, reason: 'nothing open');
      engine.saveShoppingItem(
        ShoppingItem(id: uid('item'), listId: list.id, name: 'E2E Brezeln'),
      );
      await engine.sync();
      await mine.reportLocation([fix(_away)]);
      await Future<void>.delayed(const Duration(seconds: 2));
      await mine.reportLocation([fix(_bakery)]);
      final baker = await notification(
        tester,
        'the bakery with one open thing',
        bakery,
        timeout: const Duration(minutes: 1),
      );
      expect(baker.body, '1 offen: E2E Brezeln');

      // SIC-030 (the adults' side): a check-in at school.
      await kid.reportLocation([fix(_school)]);
      await kid.checkIn(
        'E2E Bin am Tor',
        latitude: _school.$1,
        longitude: _school.$2,
      );
      const text = 'E2E Kind: E2E Bin am Tor (bei „E2E Schule“)';
      await notification(
        tester,
        'check-in',
        (n) => n.body == text,
        timeout: const Duration(minutes: 1),
      );
      await state.engine!.sync();
      await phoneScroll(tester, find.text(text));
      final maps = find.descendant(
        of: find.ancestor(of: find.text(text), matching: find.byType(ListTile)),
        matching: find.byTooltip(de.sosOpenInMaps),
      );
      expect(maps, findsOneWidget);
      await tap(tester, maps);
      await Future<void>.delayed(const Duration(seconds: 4));
      final focus = await hostOk('focus');
      note('SIC-030 maps opened in: $focus');
      expect(focus, isNot(contains(AppEnv.isDev ? 'famio.dev' : 'famio')));
      await hostOk('front');
      await idle(tester, const Duration(seconds: 2));

      // Others heard nothing of school and shop.
      final toBea = (await bea.notices(after: beaFrom)).notices;
      final toKid = (await kid.notices(after: kidFrom)).notices;
      note(
        'notices to Bea: ${toBea.map((n) => n.body).toList()}, '
        'to the child: ${toKid.map((n) => n.body).toList()}',
      );
      for (final n in [...toBea, ...toKid]) {
        expect(
          '${n.title} ${n.body}',
          isNot(contains('E2E Schule“ angekommen')),
        );
        expect('${n.title} ${n.body}', isNot(contains('verlassen')));
        expect(n.title, isNot(contains('Supermarkt')));
      }
    } finally {
      await remove(f.admin, Collections.places, [schoolId, shopId, bakeryId]);
      await finish(tester, state);
    }
  });

  androidTest('KAL-159 KAL-151 day overview and school bag at a chosen '
      'time', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final state = await startApp(tester);
    final engine = state.engine!;
    final me = state.me!.id;
    try {
      await clean(engine, {
        Collections.events,
        Collections.children,
        Collections.timetables,
        Collections.mealPlan,
        Collections.tasks,
        Collections.wasteSettings,
        Collections.vacations,
      });
      final at = minuteAfter(const Duration(seconds: 150));
      final day = DateUtils.dateOnly(DateTime.now());
      if (!DateUtils.isSameDay(at, day) || at.hour >= 23) {
        markTestSkipped('too close to midnight');
        return;
      }
      final tomorrow = DateUtils.addDaysToDate(day, 1);
      final schoolTomorrow = tomorrow.weekday <= DateTime.friday;
      engine
        ..saveEvent(
          CalendarEvent(
            id: uid('ev'),
            title: 'E2E Zahnarzt',
            start: at.add(const Duration(minutes: 40)),
            end: at.add(const Duration(minutes: 70)),
            memberIds: [me],
          ),
        )
        ..saveEvent(
          CalendarEvent(
            id: uid('ev'),
            title: 'E2E Schwimmkurs',
            start: at.add(const Duration(minutes: 50)),
            end: at.add(const Duration(minutes: 100)),
            memberIds: [f.kid.id],
            bringerId: me,
          ),
        )
        ..saveEvent(
          CalendarEvent(
            id: uid('ev'),
            title: 'E2E Bea Yoga',
            start: at.add(const Duration(minutes: 60)),
            end: at.add(const Duration(minutes: 90)),
            memberIds: [f.bea.id],
          ),
        )
        ..saveEvent(
          CalendarEvent(
            id: uid('ev'),
            title: 'Restmüll',
            start: day,
            end: tomorrow,
            allDay: true,
          ),
        )
        ..saveWasteSettings(const WasteSettings())
        ..saveTask(Task(id: uid('task'), title: 'E2E Steuer', due: day))
        ..saveMeal(
          PlannedMeal(
            id: uid('meal'),
            date: day,
            slot: MealSlot.dinner,
            title: 'E2E Linsensuppe',
          ),
        )
        ..saveChild(
          Child(
            id: uid('child'),
            name: 'E2E Lea',
            birthDate: DateTime(day.year - 5, day.month, day.day),
            guardianIds: [me],
          ),
        );
      final ida = Child(
        id: uid('child'),
        name: 'E2E Ida',
        birthDate: DateTime(2017, 2, 2),
        guardianIds: [me],
      );
      engine.saveChild(ida);
      engine.saveTimetable(
        Timetable(
          childId: ida.id,
          lessons: [
            Lesson(weekday: tomorrow.weekday, period: 1, subject: 'Mathe'),
            Lesson(weekday: tomorrow.weekday, period: 2, subject: 'Sport'),
          ],
          bring: const {'Sport': 'Turnbeutel'},
        ),
      );
      await engine.sync();

      // KAL-159: Tagesüberblick on, at [at].
      await pushSettings(tester);
      final card = find.widgetWithText(SwitchListTile, de.pushDayPreview);
      await phoneScroll(tester, card);
      if (!tester.widget<SwitchListTile>(card).value) await tap(tester, card);
      await until(tester, () => state.dayPreview != null, 'switched on');
      await tap(tester, find.text(de.pushDayPreviewTime));
      await pickTime(tester, at);
      await until(
        tester,
        () => state.dayPreview == at.hour * 60 + at.minute,
        'time set',
      );
      await waitFor(tester, find.text(de.pushDayPreviewSubtitle(hm(at))));

      // KAL-151: the school bag check, at the same time.
      if (schoolTomorrow) {
        await section(tester, de.sectionKids);
        await tap(tester, find.text('E2E Ida'));
        await tap(tester, find.text(de.commonTimetable));
        await phoneScroll(tester, find.text(de.timetableBagCheck));
        await tap(tester, find.text(de.timetableBagCheck));
        await phoneScroll(
          tester,
          find.text(de.timetableBagCheckOn(Timetable.defaultBagCheck)),
        );
        await tap(tester, find.text(de.timetableBagCheckTime));
        await pickTime(tester, at);
        await phoneScroll(tester, find.text(de.timetableBagCheckOn(hm(at))));
      }

      final overview = await notification(
        tester,
        'day overview',
        (n) => n.title?.startsWith(de.dayPreviewTitle) ?? false,
      );
      final lines = (overview.body ?? '').split('\n');
      note('KAL-159 ${overview.title}: $lines');
      final time = DateFormat.jm('de');
      expect(
        lines,
        contains(
          '${time.format(at.add(const Duration(minutes: 40)))} E2E Zahnarzt',
        ),
      );
      expect(
        lines,
        contains(
          '${time.format(at.add(const Duration(minutes: 50)))} '
          '${de.weekPreviewDropOffTitle('E2E Schwimmkurs')}',
        ),
      );
      expect(lines, contains(de.dayPreviewBirthday('E2E Lea')));
      expect(
        lines.any((l) => l.startsWith('🗑') && l.contains('Restmüll')),
        isTrue,
      );
      expect(lines, contains(de.dayPreviewMeal('E2E Linsensuppe')));
      expect(lines, contains(de.dayPreviewTasks(1, 'E2E Steuer')));
      expect(lines.any((l) => l.contains('E2E Bea Yoga')), isFalse);
      expect(lines.length, lessThanOrEqualTo(8));
      // Was a hint: birthday and bin twice, and counted as appointments.
      expect(lines.where((l) => l.contains('E2E Lea')), hasLength(1));
      expect(lines.where((l) => l.contains('Restmüll')), hasLength(1));
      // Zahnarzt and Schwimmkurs (and a public holiday, if today is one).
      final holidays = engine
          .occurrencesOn(day)
          .where((o) => (o.event.sourceId ?? '').startsWith('holiday:'))
          .length;
      expect(
        overview.title,
        '${de.dayPreviewTitle} · ${de.dayPreviewEvents(2 + holidays)}',
      );
      expect(
        DateTime.now().isAfter(at.subtract(const Duration(seconds: 59))),
        isTrue,
      );

      if (schoolTomorrow) {
        final bag = await notification(
          tester,
          'school bag',
          (n) => n.title == de.schoolBagTitle('E2E Ida'),
        );
        note('KAL-151: ${bag.body}');
        expect(bag.body, contains('Mathe'));
        expect(bag.body, contains('Turnbeutel'));
      } else {
        note('KAL-151 skipped: no school day tomorrow');
      }
      await state.setDayPreview(null);
    } finally {
      await finish(tester, state);
    }
  });

  // --- location sharing on the child's phone ---------------------------------

  androidTest('SIC-035 SIC-045 SIC-046 SIC-053 SIC-054 SIC-030 SIC-051 '
      'SIC-052 GRU-050 sharing, pause, schedule, check-in, end', (
    tester,
  ) async {
    await hostOk('grant');
    final f = await theFamily();
    final admin = f.admin;
    final kidId = f.kid.id;
    await admin.setLocationCode(null);
    final schoolId = uid('place');
    await seed(admin, Collections.places, {
      schoolId: place(schoolId, 'E2E Schule', _school),
    });
    await hostOk('geo-long ${_school.$1} ${_school.$2} 600');
    final state = await startApp(tester, user: 'e2e-kind');

    Future<MemberLocation?> seen() async {
      final r = (await pull(admin, Collections.memberLocations))[kidId];
      return r == null ? null : MemberLocation.fromRecord(r);
    }

    Finder inDialog(String label) => find.descendant(
      of: find.byType(Dialog),
      matching: find.widgetWithText(FilledButton, label),
    );
    Finder dialogText(String label) =>
        find.descendant(of: find.byType(Dialog), matching: find.text(label));

    try {
      // SIC-035: on.
      await section(tester, de.sectionLocation);
      await tap(tester, find.text(de.locationShareLocation));
      await waitFor(
        tester,
        find.text(de.locationYouShareLocation),
        timeout: const Duration(seconds: 60),
      );
      expect(
        find.text(de.locationScheduleSchedule(de.locationAlwaysShare)),
        findsOneWidget,
      );
      // From this phone (the child's other device reported elsewhere
      // before).
      final first = await untilAsync(
        tester,
        'the adults see the child at school',
        () async => switch (await seen()) {
          final l?
              when l.hasPosition &&
                  l.state == SharingState.active &&
                  (l.latitude! - _school.$1).abs() < 0.01 =>
            l,
          _ => null,
        },
        timeout: const Duration(minutes: 2),
      );
      note('SIC-035 family sees: ${sharingLabel(first, null)}');

      // SIC-045: no parents' code yet.
      await tap(tester, find.text(de.locationPause));
      await waitFor(
        tester,
        find.text(de.locationPauseNameSLocation('E2E Kind')),
      );
      await enter(tester, field(de.adminParentsCode), '1357');
      await tap(tester, inDialog(de.locationPause));
      await waitFor(tester, find.textContaining('noch kein Eltern-Code'));
      note(
        'SIC-045 text: ${find.textContaining('noch kein Eltern-Code').evaluate().map((e) => (e.widget as Text).data).join()}',
      );
      await leaveField(tester);
      await tap(tester, dialogText(de.commonCancel));
      await dialogClosed(tester);
      expect(find.text(de.locationYouShareLocation), findsOneWidget);

      // SIC-046: pausing with the code.
      await admin.setLocationCode('2468');
      await tap(tester, find.text(de.locationPause));
      for (final choice in [
        de.location1Hour,
        de.location3Hours,
        de.locationUntilTomorrowMorning,
        de.locationUntilResumed,
      ]) {
        await waitFor(tester, find.text(choice));
      }
      await tap(tester, find.text(de.location1Hour));
      await enter(tester, field(de.adminParentsCode), '0000');
      await tap(tester, inDialog(de.locationPause));
      await waitFor(tester, find.text('Der Eltern-Code stimmt nicht'));
      expect(find.text(de.locationSharingPaused), findsNothing);
      await enter(tester, field(de.adminParentsCode), '2468');
      await tap(tester, inDialog(de.locationPause));
      await dialogClosed(tester);
      await waitFor(tester, find.text(de.locationSharingPaused));
      expect(find.text(de.locationResume), findsOneWidget);
      final paused = await untilAsync(
        tester,
        'paused for the family',
        () async => switch (await seen()) {
          final l? when l.state == SharingState.paused => l,
          _ => null,
        },
      );
      final label = sharingLabel(paused, null);
      note('SIC-046 family sees: $label');
      expect(
        label,
        de.locationPausedUntil(DateFormat.jm('de').format(paused.pausedUntil!)),
      );
      expect(
        paused.pausedUntil!.difference(DateTime.now()).inMinutes,
        inInclusiveRange(55, 61),
      );
      await tap(tester, find.text(de.locationResume));
      await waitFor(tester, find.text(de.locationYouShareLocation));

      // SIC-053: a schedule that leaves out today.
      final today = DateTime.now().weekday;
      final days = [today % 7 + 1, (today + 1) % 7 + 1]..sort();
      final names = weekdaysShort();
      await tap(tester, find.text(de.locationSchedule));
      await waitFor(tester, find.text(de.locationLocationSchedule));
      expect(find.text(de.locationChooseLeastOneDay), findsOneWidget);
      expect(
        tester.widget<FilledButton>(inDialog(de.commonSave)).onPressed,
        isNull,
      );
      for (final d in days) {
        await tap(
          tester,
          find.descendant(
            of: find.byType(FilterChip),
            matching: find.text(names[d - 1]),
          ),
        );
      }
      expect(find.text(de.locationChooseLeastOneDay), findsNothing);
      await enter(tester, field(de.adminParentsCode), '2468');
      await leaveField(tester);
      await tap(tester, inDialog(de.commonSave));
      await dialogClosed(tester);
      final schedule = LocationSchedule(
        weekdays: days,
        startMinute: 7 * 60,
        endMinute: 18 * 60,
      );
      await waitFor(
        tester,
        find.text(de.locationScheduleSchedule(scheduleLabel(schedule))),
      );
      note(
        'SIC-053 card: ${de.locationScheduleSchedule(scheduleLabel(schedule))}',
      );
      final off = await untilAsync(
        tester,
        'off by schedule for the family',
        () async => switch (await seen()) {
          final l? when l.state == SharingState.scheduled => l,
          _ => null,
        },
      );
      expect(sharingLabel(off, null), de.locationLocationSharingOffRight);
      expect(off.hasPosition, isFalse);
      await waitFor(tester, find.text(de.locationSharingOffSchedule));
      // The same time for start and end: not to be saved.
      await tap(tester, find.text(de.locationSchedule));
      await waitFor(tester, find.text(de.locationLocationSchedule));
      expect(find.text(de.locationChooseLeastOneDay), findsNothing);
      await tap(tester, find.text(de.locationUntilTime('18:00')));
      await pickTimeInDialog(tester, DateTime(2000, 1, 1, 7));
      await waitFor(tester, find.text(de.locationUntilTime('07:00')));
      expect(find.text(de.locationChooseLeastOneDay), findsOneWidget);
      expect(
        tester.widget<FilledButton>(inDialog(de.commonSave)).onPressed,
        isNull,
      );
      // No day: not to be saved either.
      for (final d in days) {
        await tap(
          tester,
          find.descendant(
            of: find.byType(FilterChip),
            matching: find.text(names[d - 1]),
          ),
        );
      }
      expect(find.text(de.locationChooseLeastOneDay), findsOneWidget);
      expect(
        tester.widget<FilledButton>(inDialog(de.commonSave)).onPressed,
        isNull,
      );

      // SIC-054: removed, first with a wrong code.
      await enter(tester, field(de.adminParentsCode), '0000');
      await leaveField(tester);
      await tap(tester, dialogText(de.locationRemoveSchedule));
      await waitFor(tester, find.text('Der Eltern-Code stimmt nicht'));
      expect(find.text(de.locationLocationSchedule), findsOneWidget);
      await enter(tester, field(de.adminParentsCode), '2468');
      await leaveField(tester);
      await tap(tester, dialogText(de.locationRemoveSchedule));
      await dialogClosed(tester);
      await waitFor(
        tester,
        find.text(de.locationScheduleSchedule(de.locationAlwaysShare)),
      );
      final back = await untilAsync(
        tester,
        'normal status again',
        () async => switch (await seen()) {
          final l? when l.state == SharingState.active => l,
          _ => null,
        },
        timeout: const Duration(seconds: 30),
      );
      note('SIC-054 family sees: ${sharingLabel(back, null)}');

      // SIC-030: a check-in names the place.
      await tap(tester, find.byTooltip(de.locationSendCheck));
      await tap(tester, find.text('Bin angekommen'));
      await waitFor(
        tester,
        find.text(de.sosCheckSentLocation),
        timeout: const Duration(seconds: 30),
      );
      final alert = await untilAsync(
        tester,
        'check-in for the adults',
        () async {
          for (final r in (await pull(
            admin,
            Collections.locationAlerts,
          )).values) {
            final a = LocationAlert.fromRecord(r);
            if (a.memberId == kidId && a.checkIn == 'Bin angekommen') return a;
          }
          return null;
        },
      );
      expect(
        alert.text('E2E Kind'),
        'E2E Kind: Bin angekommen (bei „E2E Schule“)',
      );
      await snackGone(tester);

      // SIC-051: ending needs the code.
      await tap(tester, find.text(de.commonEnd2));
      await waitFor(tester, find.text(de.locationEndLocationSharing));
      await tap(tester, inDialog(de.commonEnd2));
      await idle(tester, const Duration(seconds: 2));
      expect(find.text(de.locationEndLocationSharing), findsOneWidget);
      expect((await LocationSharing.status()).enabled, isTrue);
      await enter(tester, field(de.adminParentsCode), '2468');
      await tap(tester, inDialog(de.commonEnd2));
      await dialogClosed(tester);
      await waitFor(tester, find.text(de.locationShareMyLocation));
      expect(find.text(de.locationShareLocation), findsOneWidget);
      expect((await LocationSharing.status()).enabled, isFalse);

      // SIC-052 / GRU-050: signing out while sharing.
      await tap(tester, find.text(de.locationShareLocation));
      await waitFor(
        tester,
        find.text(de.locationYouShareLocation),
        timeout: const Duration(seconds: 60),
      );
      await section(tester, de.sectionSettings);
      await phoneScroll(tester, find.text(de.settingsSignOut));
      await tap(tester, find.text(de.settingsSignOut));
      await waitFor(tester, find.text(de.locationEndLocationSharing));
      await tap(tester, dialogText(de.commonCancel));
      await dialogClosed(tester);
      expect(state.me, isNotNull);
      expect((await LocationSharing.status()).enabled, isTrue);
      await tap(tester, find.text(de.settingsSignOut));
      await waitFor(tester, find.text(de.locationEndLocationSharing));
      await enter(tester, field(de.adminParentsCode), '2468');
      await tap(tester, inDialog(de.commonEnd2));
      await until(tester, () => state.me == null, 'signed out');
      await waitFor(
        tester,
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.labelText == 'Server-Adresse' ||
                  w.decoration?.labelText == 'Benutzername'),
        ),
      );
      expect((await LocationSharing.status()).enabled, isFalse);
    } finally {
      await admin.setLocationCode(null);
      await remove(admin, Collections.places, [schoolId]);
      await finish(tester, state);
    }
  });

  // --- the emergency button from outside Famio --------------------------------

  androidTest('SIC-021 SIC-016 emergency from the widget, the tile and the '
      'shortcut; positions with the screen off; the adults\' page', (
    tester,
  ) async {
    await hostOk('grant');
    final f = await theFamily();
    await quietSos(f);
    await resolveAll(f.admin);
    final kidId = f.kid.id;
    await hostOk('geo-long ${_school.$1} ${_school.$2} 900');
    var state = await startApp(tester, user: 'e2e-kind');
    try {
      // The widget "Famio Notruf", placed on the home screen and tapped
      // there: counts down, "Abbrechen" ends it without an alarm.
      await HomeWidget.requestPinWidget(
        qualifiedAndroidName: 'de.status403.famio.SosWidgetProvider',
      );
      final placed = await host(
        'tap-text ${b64('Add to home screen|Add automatically|Add|Hinzufügen')} 15',
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      final tapped = await host(
        'home-tap ${b64('Trigger Famio emergency call|Famio Notruf auslösen')} 10',
      );
      note(
        'SIC-021 widget placed: ${placed.ok} ${placed.out}, tapped on the '
        'home screen: ${tapped.ok} ${tapped.out}',
      );
      if (!tapped.ok) {
        // Its intent, with the secret, as the widget sends it.
        await hostOk('front');
        await hostOk('sos widget');
      }
      await waitFor(
        tester,
        find.text(de.sosEmergencyCall),
        timeout: const Duration(seconds: 20),
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.style?.fontSize == 120 &&
              RegExp(r'^[1-5]$').hasMatch(w.data ?? ''),
        ),
        findsOneWidget,
        reason: 'counting down',
      );
      await tap(tester, find.text(de.commonCancel).hitTestable());
      await waitGone(tester, find.text(de.sosEmergencyCall));
      await idle(tester, const Duration(seconds: 7));
      expect(await openAlertOf(f.admin, kidId), isNull);

      // The quick settings tile: after 5 seconds the alarm.
      await hostOk('sos tile');
      await waitFor(
        tester,
        find.text(de.sosEmergencyCall),
        timeout: const Duration(seconds: 20),
      );
      await waitFor(
        tester,
        find.text(de.sosAlarmSent),
        timeout: const Duration(seconds: 30),
      );
      final byTile = await untilAsync(
        tester,
        'alarm from the tile',
        () => openAlertOf(f.admin, kidId),
      );
      await liveServiceRunning(tester);
      await tap(tester, find.text(de.sosIAmSafeEnd));
      await untilAsync(
        tester,
        'tile alarm over',
        () async => await openAlertOf(f.admin, kidId) == null,
      );
      note('SIC-021 tile alarm ${byTile.id}');
      // SIC-016: ended, the phone stops sending (the service goes).
      await untilAsync(
        tester,
        'the position service stopped',
        () async => !(await hostOk('services')).contains('SosLocationService'),
        timeout: const Duration(seconds: 30),
      );
      await idle(tester, const Duration(seconds: 2));
      if (find.text(de.sosBackFamioAlarmKeeps).evaluate().isNotEmpty) {
        await tap(tester, find.text(de.sosBackFamioAlarmKeeps));
      }

      // The launcher's shortcut (a long press on the app's icon,
      // "Famio-Notruf auslösen"), then "Sofort auslösen" in its countdown.
      final shortcuts = await hostOk('shortcuts');
      note('SIC-021 Famio\'s shortcuts: $shortcuts');
      final viaLauncher = await host('sos shortcut');
      note(
        'SIC-021 shortcut from the launcher\'s menu: ${viaLauncher.ok} '
        '${viaLauncher.out}',
      );
      if (!viaLauncher.ok) {
        // The menu could not be driven: the shortcut's own intent (the
        // same as the widget's, with the secret).
        await hostOk('front');
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(
          shortcuts,
          contains('de.status403.famio.SOS'),
          reason: 'no emergency shortcut registered',
        );
        await hostOk('sos widget');
      }
      await waitFor(
        tester,
        find.text(de.sosEmergencyCall),
        timeout: const Duration(seconds: 20),
      );
      await tap(tester, find.text(de.sosTriggerNow));
      await waitFor(
        tester,
        find.text(de.sosAlarmSent),
        timeout: const Duration(seconds: 30),
      );
      final alarm = await untilAsync(
        tester,
        'alarm with a position',
        () async => switch (await openAlertOf(f.admin, kidId)) {
          final a? when a.hasPosition => a,
          _ => null,
        },
      );
      note(
        'SIC-016 live until: '
        '${alarm.liveUntil?.difference(alarm.startedAt).inMinutes} min',
      );
      if (alarm.liveUntil != null) {
        expect(
          alarm.liveUntil!.difference(alarm.startedAt).inMinutes,
          inInclusiveRange(29, 31),
          reason: 'positions for half an hour',
        );
      }

      // SIC-016: the screen off, positions keep coming.
      await hostOk('screen off');
      final times = <DateTime>{};
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 110)) {
        final a = await openAlertOf(f.admin, kidId);
        if (a?.positionAt case final at?) times.add(at);
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      await hostOk('screen on');
      await hostOk('front');
      await idle(tester, const Duration(seconds: 2));
      note('SIC-016 positions with the screen off: ${times.length} $times');
      expect(times.length, greaterThanOrEqualTo(4));
      await finish(tester, state);

      // The adults' page of the alarm: "Standort von … Uhr", updated.
      state = await startApp(tester);
      final kid = await sessionOf(f.kid);
      await waitFor(
        tester,
        find.textContaining('E2E Kind'),
        timeout: const Duration(seconds: 30),
      );
      await tap(tester, find.text(de.sosFrom('E2E Kind')).first);
      await waitFor(tester, find.textContaining('Standort von'));
      final before = find
          .textContaining('Standort von')
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .join();
      await kid.sosPosition(
        alarm.id,
        latitude: _school.$1 + 0.001,
        longitude: _school.$2,
        accuracy: 77,
      );
      await state.engine!.sync();
      await until(
        tester,
        () =>
            find
                .textContaining('Standort von')
                .evaluate()
                .map((e) => (e.widget as Text).data)
                .join() !=
            before,
        'position updated on the page',
        timeout: const Duration(seconds: 40),
      );
      note(
        'SIC-016 adults see: $before → ${find.textContaining('Standort von').evaluate().map((e) => (e.widget as Text).data).join()}',
      );
      await tap(tester, find.text(de.sosEndEmergency));
      if (find.text(de.sosEndEmergency).evaluate().length > 1) {
        await tap(tester, find.text(de.sosEndEmergency).last);
      }
      await untilAsync(
        tester,
        'alarm ended',
        () async => await openAlertOf(f.admin, kidId) == null,
      );
      // Over: the phone stops sending.
      final ended = (await pull(f.admin, Collections.sosAlerts))[alarm.id];
      final last = SosAlert.fromRecord(ended!).positionAt;
      await idle(tester, const Duration(seconds: 45));
      final later = SosAlert.fromRecord(
        (await pull(f.admin, Collections.sosAlerts))[alarm.id]!,
      ).positionAt;
      expect(later, last);
    } finally {
      await resolveAll(f.admin);
      await finish(tester, state);
    }
  });

  // An alarm ended within its first seconds ("Ich bin sicher – Alarm
  // beenden" right after "Alarm gesendet") crashed Famio about three seconds
  // later (ForegroundServiceDidNotStartInTimeException of SosLocationService:
  // STOP came before the service was in the foreground). Now no service
  // starts for an alarm that is over, a STOP is only sent to a service that
  // runs, and a STOP before startForeground calls it first (#536).
  androidTest('SIC-021 hint: an alarm ended at once', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    await quietSos(f);
    await resolveAll(f.admin);
    final state = await startApp(tester, user: 'e2e-kind');
    try {
      await hostOk('sos tile');
      await waitFor(
        tester,
        find.text(de.sosAlarmSent),
        timeout: const Duration(seconds: 30),
      );
      await tap(tester, find.text(de.sosIAmSafeEnd));
      await untilAsync(
        tester,
        'alarm over',
        () async => await openAlertOf(f.admin, f.kid.id) == null,
      );
      // Still there after the service's time to start.
      await idle(tester, const Duration(seconds: 12));
      final focus = await hostOk('focus');
      note('SIC-021 hint: after ending at once: $focus');
      expect(focus, contains(AppEnv.isDev ? 'famio.dev' : 'famio'));
    } finally {
      await resolveAll(f.admin);
      await finish(tester, state);
    }
  });

  // --- the app lock ---------------------------------------------------------------

  androidTest('GRU-110 switching the lock on without a screen lock', (
    tester,
  ) async {
    await hostOk('grant');
    final state = await startApp(tester, user: 'e2e-kind');
    try {
      final available = await state.lock.available;
      note('GRU-110 without a PIN: lock offered $available');
      await section(tester, de.sectionSettings);
      if (available) {
        final sw = find.widgetWithText(SwitchListTile, de.appLockTitle);
        await phoneScroll(tester, sw);
        await tap(tester, sw);
        await waitFor(
          tester,
          find.text(de.appLockNotChanged),
          timeout: const Duration(seconds: 30),
        );
        expect(tester.widget<SwitchListTile>(sw).value, isFalse);
      } else {
        for (var i = 0; i < 30; i++) {
          await dragList(tester, -300);
        }
        expect(find.text(de.appLockTitle), findsNothing);
      }
    } finally {
      await finish(tester, state);
    }
  });

  androidTest('GRU-110 GRU-111 GRU-112 GRU-114 GRU-116 SIC-022 the lock with '
      'the device PIN, screenshots, an emergency over it', (tester) async {
    lifecycleForLock(tester);
    await hostOk('grant');
    final f = await theFamily();
    await quietSos(f);
    await resolveAll(f.admin);
    await hostOk('pin-set');
    await Future<void>.delayed(const Duration(seconds: 2));
    final state = await startApp(tester, user: 'e2e-kind');
    final seen = <AppLifecycleState>[];
    final listener = AppLifecycleListener(onStateChange: seen.add);

    Future<void> background() async {
      final watch = Stopwatch()..start();
      while (!seen.contains(AppLifecycleState.paused)) {
        if (watch.elapsed > const Duration(seconds: 30)) {
          throw TestFailure('Famio did not go to the background: $seen');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    /// Android's question (it comes by itself on the lock screen),
    /// cancelled with the back button, as a person might.
    Future<void> cancelPrompt({bool required = true}) async {
      final prompt = await host(
        'find-text ${b64('${de.appLockReason}|PIN|Use PIN')} 10',
      );
      note('Android asks by itself: "${prompt.out}"');
      if (prompt.out.isEmpty) {
        // Without Android's question "back" would leave Famio.
        if (required) throw TestFailure('Android did not ask by itself');
        await waitFor(tester, find.text(de.appLockUnlock));
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      await hostOk('back');
      await until(tester, () => state.lock.failed, 'cancelled');
      await waitFor(tester, find.text(de.appLockUnlock));
      await waitFor(
        tester,
        find.widgetWithText(TextButton, de.settingsSignOut),
      );
    }

    /// Away and back: locked, Android's question comes by itself and is
    /// cancelled, as a person might.
    /// Colours in the middle of Famio's card in Android's recent apps.
    var recentsWithLock = '';

    Future<void> lockAndCancel({bool viaRecents = false}) async {
      seen.clear();
      if (viaRecents) {
        // GRU-114: the card in the recent apps, then home.
        recentsWithLock = await hostOk('recents lock');
        note('GRU-114 recent apps with the lock: $recentsWithLock');
      }
      await hostOk('home');
      await background();
      await hostOk('front');
      await waitFor(tester, find.text(de.appLockLocked));
      await cancelPrompt();
    }

    Future<void> unlock() async {
      await tap(tester, find.text(de.appLockUnlock));
      for (var attempt = 1; attempt <= 3 && state.lock.locked; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 3));
        await hostOk('pin-enter');
        final watch = Stopwatch()..start();
        while (state.lock.locked &&
            watch.elapsed < const Duration(seconds: 10)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        if (state.lock.locked && state.lock.failed) {
          await tester.tap(find.text(de.appLockUnlock));
        }
      }
      expect(state.lock.locked, isFalse);
      await tester.pumpAndSettle();
    }

    try {
      // GRU-110: on, with the device's own question.
      await hostOk('front');
      await section(tester, de.sectionSettings);
      final sw = find.widgetWithText(SwitchListTile, de.appLockTitle);
      await phoneScroll(tester, sw);
      await tap(tester, sw);
      await Future<void>.delayed(const Duration(seconds: 3));
      await hostOk('pin-enter');
      await until(tester, () => state.lock.enabled, 'lock on');
      await waitFor(tester, find.text(de.appLockDelay));
      expect(find.textContaining(de.appLockAfterMinutes(1)), findsWidgets);
      expect(tester.widget<SwitchListTile>(sw).value, isTrue);

      // GRU-111: the time, with large text too.
      await hostOk('font-scale 2.0');
      await idle(tester, const Duration(seconds: 2));
      await phoneScroll(tester, find.text(de.appLockDelay));
      await tap(tester, find.text(de.appLockDelay));
      await waitFor(tester, find.byType(SimpleDialog));
      for (final label in [
        de.appLockImmediately,
        de.appLockAfterMinutes(1),
        de.appLockAfterMinutes(5),
        de.appLockAfterMinutes(15),
      ]) {
        expect(
          find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: label,
        );
      }
      expect(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(de.appLockPickerNote),
        ),
        findsOneWidget,
      );
      final large = tester.takeException();
      note('GRU-111 large text: $large');
      expect(large, isNull);
      await tap(
        tester,
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(de.appLockImmediately),
        ),
      );
      await dialogClosed(tester);
      await hostOk('font-scale 1.0');
      await idle(tester, const Duration(seconds: 2));
      expect(state.lock.delay, Duration.zero);
      await phoneScroll(
        tester,
        find.text('${de.appLockImmediately}\n${de.appLockPickerNote}'),
      );

      // GRU-114: no screenshots, the window flag.
      await hostOk('secure-on');
      final dark = double.parse(await hostOk('screen-dark'));
      note('GRU-114 lit share with the lock: $dark');
      expect(dark, lessThan(0.02));

      // GRU-112: a page open, away, locked, cancelled, unlocked.
      await phoneScroll(tester, find.text('Push-Benachrichtigungen'), up: true);
      await tap(tester, find.text('Push-Benachrichtigungen'));
      await waitFor(tester, find.text(de.pushDirectlyThroughFamio));
      await lockAndCancel(viaRecents: true);
      expect(
        find.text(de.pushDirectlyThroughFamio).hitTestable(),
        findsNothing,
      );
      await unlock();
      expect(
        find.text(de.pushDirectlyThroughFamio).hitTestable(),
        findsOneWidget,
      );

      // GRU-116 / SIC-022: the emergency over the lock.
      await lockAndCancel();
      await hostOk('sos tile');
      await waitFor(
        tester,
        find.text(de.sosEmergencyCall),
        timeout: const Duration(seconds: 20),
      );
      expect(state.lock.locked, isTrue);
      expect(find.text(de.appLockLocked), findsNothing);
      await tap(tester, find.text(de.commonCancel).hitTestable());
      await waitGone(tester, find.text(de.sosEmergencyCall));
      await waitFor(tester, find.text(de.appLockLocked));
      expect(state.lock.locked, isTrue);
      expect(await openAlertOf(f.admin, f.kid.id), isNull);
      // The lock screen asks again: cancelled once more.
      await cancelPrompt(required: false);
      await idle(tester, const Duration(seconds: 3));
      expect(await openAlertOf(f.admin, f.kid.id), isNull);
      await hostOk('sos tile');
      await waitFor(
        tester,
        find.text(de.sosEmergencyCall),
        timeout: const Duration(seconds: 20),
      );
      await waitFor(
        tester,
        find.text(de.sosAlarmSent),
        timeout: const Duration(seconds: 30),
      );
      expect(state.lock.locked, isTrue);
      expect(find.text(de.appLockLocked), findsNothing);
      await untilAsync(
        tester,
        'alarm raised',
        () => openAlertOf(f.admin, f.kid.id),
      );
      await liveServiceRunning(tester);
      await tap(tester, find.text(de.sosIAmSafeEnd));
      await untilAsync(
        tester,
        'alarm ended over the lock',
        () async => await openAlertOf(f.admin, f.kid.id) == null,
      );
      await waitFor(tester, find.text(de.appLockLocked));
      expect(state.lock.locked, isTrue);
      await cancelPrompt(required: false);
      await unlock();

      // Off again: the flag goes.
      await section(tester, de.sectionSettings);
      await phoneScroll(tester, sw);
      await tap(tester, sw);
      await Future<void>.delayed(const Duration(seconds: 3));
      await hostOk('pin-enter');
      await until(tester, () => !state.lock.enabled, 'lock off');
      await idle(tester, const Duration(seconds: 1));
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);
      expect(find.text(de.appLockDelay), findsNothing);
      await hostOk('secure-off');
      final lit = double.parse(await hostOk('screen-dark'));
      note('GRU-114 lit share without the lock: $lit');
      expect(lit, greaterThan(0.2));
      final recentsWithout = await hostOk('recents nolock');
      note('GRU-114 recent apps without the lock: $recentsWithout');
      await hostOk('home');
      await Future<void>.delayed(const Duration(seconds: 2));
      await hostOk('front');
      await idle(tester, const Duration(seconds: 2));
      // A blank card with the lock, the page without (pictures in
      // pruefkatalog/logs/shots).
      int colours(String r) => int.parse(r.split(' ').first);
      expect(
        colours(recentsWithLock),
        lessThan(colours(recentsWithout) ~/ 2),
        reason: 'recent apps: $recentsWithLock / $recentsWithout',
      );
    } finally {
      listener.dispose();
      await host('font-scale 1.0');
      await host('pin-clear');
      await Future<void>.delayed(const Duration(seconds: 2));
      await resolveAll(f.admin);
      await finish(tester, state);
    }
  });

  androidTest('GRU-113 a file picked in the family inbox locks nothing, '
      'another app does', (tester) async {
    lifecycleForLock(tester);
    await hostOk('grant');
    await hostOk('file e2e-anhang.png png 320 240');
    await hostOk('pin-set');
    await Future<void>.delayed(const Duration(seconds: 2));
    final state = await startApp(tester);
    final seen = <AppLifecycleState>[];
    final listener = AppLifecycleListener(onStateChange: seen.add);

    Future<void> was(AppLifecycleState s) async {
      final watch = Stopwatch()..start();
      while (!seen.contains(s)) {
        if (watch.elapsed > const Duration(seconds: 30)) {
          throw TestFailure('Famio did not get $s: $seen');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    try {
      // The lock on with the device PIN, "Sofort".
      await hostOk('front');
      await Future<void>.delayed(const Duration(seconds: 2));
      final on = state.lock.setEnabled(true);
      await Future<void>.delayed(const Duration(seconds: 3));
      await hostOk('pin-enter');
      expect(await on, isTrue);
      await state.lock.setDelay(Duration.zero);
      await idle(tester, const Duration(seconds: 2));

      // Familien-Eingang → "Etwas ablegen" → "Datei oder Foto auswählen".
      await section(tester, de.sectionHome);
      await tap(tester, find.byTooltip(de.inboxTitle));
      await waitFor(tester, find.text(de.inboxTitle));
      await tap(
        tester,
        find.byWidgetPredicate(
          (w) =>
              (w is Tooltip && w.message == de.inboxAdd) ||
              (w is Text && w.data == de.inboxAdd),
        ),
      );
      await waitFor(tester, find.byType(AlertDialog));
      await leaveField(tester);
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(de.filesChooseFilePhoto),
        ),
      );
      // On a phone a sheet first (camera, scanner, file).
      final inSheet = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(de.filesChooseFilePhoto),
      );
      await waitFor(tester, inSheet);
      await tester.pump(const Duration(milliseconds: 600));
      seen.clear();
      // No pump after it: behind the picker Android draws no frames.
      await tester.tap(inSheet.first, warnIfMissed: false);
      // Android's file picker: Famio in the background meanwhile.
      await was(AppLifecycleState.paused);
      var picked = await host('tap-text ${b64('e2e-anhang.png')} 6');
      if (!picked.ok) {
        // Not among the recent files: the picker's list of places, then
        // "Downloads", as a person would.
        final roots = await host(
          'tap-text ${b64('Show roots|Open navigation drawer')} 6',
        );
        if (roots.ok) {
          await host('tap-text ${b64('Downloads|Download')} 6');
          picked = await host('tap-text ${b64('e2e-anhang.png')} 8');
        }
      }
      note('GRU-113 file picked in Android\'s picker: ${picked.ok}');
      if (!picked.ok) await hostOk('back');
      await was(AppLifecycleState.resumed);
      await idle(tester, const Duration(seconds: 2));
      expect(state.lock.locked, isFalse, reason: 'back from the file picker');
      expect(find.text(de.appLockLocked), findsNothing);
      if (picked.ok) {
        await waitFor(
          tester,
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('e2e-anhang.png'),
          ),
        );
      }
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(de.commonCancel),
        ),
      );
      await dialogClosed(tester);

      // Another app: locked at once.
      seen.clear();
      await hostOk('home');
      await was(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(seconds: 2));
      await hostOk('front');
      await waitFor(tester, find.text(de.appLockLocked));
      expect(state.lock.locked, isTrue);
      for (var attempt = 1; attempt <= 3 && state.lock.locked; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (state.lock.failed) {
          await tester.tap(find.text(de.appLockUnlock));
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        await hostOk('pin-enter');
        final watch = Stopwatch()..start();
        while (state.lock.locked &&
            watch.elapsed < const Duration(seconds: 10)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
      }
      expect(state.lock.locked, isFalse);
      await idle(tester, const Duration(seconds: 1));

      await state.lock.setDelay(AppLock.defaultDelay);
      final off = state.lock.setEnabled(false);
      await Future<void>.delayed(const Duration(seconds: 3));
      await hostOk('pin-enter');
      expect(await off, isTrue);
    } finally {
      listener.dispose();
      await host('pin-clear');
      await Future<void>.delayed(const Duration(seconds: 2));
      await finish(tester, state);
    }
  });

  // --- with the device clock moved (last: everything else on real time) -----

  androidTest('KAL-161 KAL-074 KAL-136 KAL-157 GRU-151 Sunday evening, '
      'the evening before, midnight and the morning', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final state = await startApp(tester);
    final engine = state.engine!;
    final me = state.me!.id;
    try {
      await clean(engine, {
        Collections.events,
        Collections.children,
        Collections.timetables,
        Collections.mealPlan,
        Collections.tasks,
        Collections.shoppingLists,
        Collections.shoppingItems,
        Collections.wasteSettings,
        Collections.vacations,
        Collections.medications,
      });
      final now = DateTime.now();
      // The Sunday evening ahead and the day after it.
      var sunday = DateTime(
        now.year,
        now.month,
        now.day + (DateTime.sunday - now.weekday) % 7,
      );
      if (now.isAfter(
        DateTime(sunday.year, sunday.month, sunday.day, 17, 50),
      )) {
        sunday = DateTime(sunday.year, sunday.month, sunday.day + 7);
      }
      final next = DateTime(sunday.year, sunday.month, sunday.day + 1);
      DateTime on(DateTime d, int h, [int m = 0, int s = 0]) =>
          DateTime(d.year, d.month, d.day, h, m, s);

      // KAL-161: the week after it; a lift and somebody else's.
      CalendarEvent at(
        String title,
        DateTime start, {
        List<String>? who,
        String? bringer,
        bool allDay = false,
        bool confidential = false,
      }) => CalendarEvent(
        id: uid('ev'),
        title: title,
        start: start,
        end: allDay
            ? DateTime(start.year, start.month, start.day + 1)
            : start.add(const Duration(hours: 1)),
        allDay: allDay,
        memberIds: who ?? [me],
        bringerId: bringer,
        confidential: confidential,
      );
      final week = [
        at('E2E Elternabend', on(next, 19)),
        at('E2E Zahnarzt', on(next.add(const Duration(days: 1)), 10)),
        at('E2E Ausflug', next.add(const Duration(days: 2)), allDay: true),
        at(
          'E2E Fussball',
          // Early, so the lift is among the eight lines after the day's
          // all-day entries.
          on(next, 8),
          who: [f.kid.id],
          bringer: me,
        ),
        at(
          'E2E Bea Yoga',
          on(next.add(const Duration(days: 4)), 18),
          who: [f.bea.id],
        ),
        // A ninth line: the eighth says how many more.
        at('E2E Klavier', on(next.add(const Duration(days: 4)), 16)),
        // The week after: only to show that "off" stays quiet.
        at('E2E Naechste Woche', on(next.add(const Duration(days: 8)), 11)),
      ];
      // KAL-074: three trips the day after with packing lists.
      final camping = at('E2E Zelten', next, allDay: true);
      final hidden = at('E2E Klinik', next, allDay: true, confidential: true);
      final beas = at('E2E Bea Reise', next, allDay: true, who: [f.bea.id]);
      // GRU-151: something tonight, so the widget changes at midnight.
      final tonight = at('E2E Spaet heute', on(sunday, 23, 0));
      for (final e in [...week, camping, hidden, beas, tonight]) {
        engine.saveEvent(e);
      }
      for (final (trip, owner, count) in [
        (camping, me, 3),
        (hidden, me, 1),
        (beas, f.bea.id, 2),
      ]) {
        final list = ShoppingList(
          id: uid('pack'),
          name: 'Packliste ${trip.title}',
          packing: true,
          eventId: trip.id,
        );
        engine.saveShoppingList(list);
        for (var i = 0; i < count; i++) {
          engine.saveShoppingItem(
            ShoppingItem(
              id: uid('item'),
              listId: list.id,
              name: 'E2E Sache $i',
              memberId: owner,
            ),
          );
        }
      }
      // KAL-136: a birthday the day after.
      engine.saveChild(
        Child(
          id: uid('child'),
          name: 'E2E Mia',
          birthDate: DateTime(next.year - 8, next.month, next.day),
          guardianIds: [me],
        ),
      );
      // KAL-157: the yellow bin the day after, my turn, at 19:00.
      engine.saveEvent(at('Gelbe Tonne', next, allDay: true, who: const []));
      engine.saveWasteSettings(WasteSettings(memberIds: [me], remindHour: 19));
      await engine.sync();
      await idle(tester, const Duration(seconds: 5));
      final preview = buildWeekPreview(engine, next);
      note('KAL-161 expected: ${preview?.title} / ${preview?.lines}');

      /// Moves the device's clock to [to] and waits for [what] (at most
      /// [wait] after the jump).
      Future<List<ActiveNotification>> jump(DateTime to, Duration wait) async {
        final set = await hostOk('clock ${to.millisecondsSinceEpoch}');
        debugPrint('E2E clock now ${DateTime.now()} ($set)');
        await idle(tester, wait);
        return shown();
      }

      // Sunday 18:00.
      var list = await jump(
        on(sunday, 17, 59, 30),
        const Duration(seconds: 70),
      );
      note('18:00: ${describe(list)}');
      final weekNote = list
          .where((n) => n.title?.startsWith('Deine Woche') ?? false)
          .toList();
      expect(weekNote, hasLength(1), reason: describe(list));
      expect(weekNote.single.title, preview!.title);
      expect(weekNote.single.title, contains(de.weekPreviewLifts(1)));
      final weekLines = (weekNote.single.body ?? '').split('\n');
      expect(weekLines, contains('Mo 19:00 E2E Elternabend'));
      expect(
        weekLines.any(
          (l) => l.endsWith(de.weekPreviewDropOffTitle('E2E Fussball')),
        ),
        isTrue,
      );
      expect(weekLines.any((l) => l.contains('Bea')), isFalse);
      expect(weekLines.length, 8);
      // Nine for me: seven lines and "… und 2 weitere".
      expect(weekNote.single.title, startsWith(de.weekPreviewTitle(9)));
      expect(weekLines.last, de.kioskCountMore2(2));
      expect(weekLines, isNot(contains(contains('E2E Klavier'))));
      // KAL-074.
      expect(
        list.where(
          (n) =>
              n.title == de.remindersTomorrowTrip('E2E Zelten') &&
              n.body == de.remindersLeftThingsLeftPack(3),
        ),
        hasLength(1),
      );
      expect(
        list.where((n) => n.title == de.remindersTomorrowTrip(de.eventBusy)),
        hasLength(1),
      );
      expect(list.where((n) => '${n.title}'.contains('Bea Reise')), isEmpty);
      expect(list.where((n) => '${n.title}'.contains('Klinik')), isEmpty);
      // KAL-136, the evening before.
      expect(
        list.where(
          (n) =>
              n.title == de.remindersTomorrowWhat('E2E Mia wird 8') &&
              n.body == de.remindersDonTForgetPresent,
        ),
        hasLength(1),
      );

      // KAL-157: 19:00.
      list = await jump(on(sunday, 18, 59, 30), const Duration(seconds: 70));
      final bin = list
          .where((n) => n.title?.startsWith('Morgen: ') ?? false)
          .where((n) => n.title!.contains('Gelb'))
          .toList();
      note('19:00: ${describe(bin)}');
      expect(bin, hasLength(1));
      expect(bin.single.body, de.remindersTurnPleasePutOut);

      // GRU-151: shortly after midnight the widget shows the new day.
      await jump(on(sunday, 23, 59, 15), const Duration(seconds: 2));
      engine.saveTask(Task(id: uid('task'), title: 'E2E Mitternacht'));
      await idle(tester, const Duration(seconds: 5));
      final evening = await HomeWidget.getWidgetData<String>('date');
      final eveningLines = [
        for (var i = 0; i < 5; i++)
          await HomeWidget.getWidgetData<String>('text$i'),
      ];
      note('GRU-151 23:59: $evening $eveningLines');
      expect(evening, DateFormat.MMMEd('de').format(sunday));
      expect(eveningLines, contains('E2E Spaet heute'));
      final newDay = DateFormat.MMMEd('de').format(next);
      await untilAsync(
        tester,
        'widget on the new day',
        () async => await HomeWidget.getWidgetData<String>('date') == newDay,
        timeout: const Duration(minutes: 3),
      );
      final morningLines = [
        for (var i = 0; i < 5; i++)
          await HomeWidget.getWidgetData<String>('text$i'),
      ];
      note('GRU-151 after midnight at ${DateTime.now()}: $morningLines');
      expect(morningLines, isNot(contains('E2E Spaet heute')));
      expect(
        morningLines.any(
          (l) =>
              l != null &&
              [
                'E2E Zelten',
                de.eventBusy,
                'E2E Bea Reise',
                'Gelbe Tonne',
                'E2E Mia',
              ].any(l.contains),
        ),
        isTrue,
        reason: 'the new day\'s entries',
      );

      // KAL-136: 8:00 on the day.
      list = await jump(on(next, 7, 59, 30), const Duration(seconds: 70));
      final today = list.where(
        (n) => n.title == de.remindersTodayWhat('E2E Mia wird 8'),
      );
      note('8:00: ${describe(today.toList())}');
      expect(today, hasLength(1));

      // KAL-157 also: Bea's turn (Monday evening: nothing for me), nobody
      // chosen (Tuesday evening: every adult, me too), the family on
      // holiday (Wednesday evening: nobody).
      final tue = DateTime(next.year, next.month, next.day + 1);
      final wed = DateTime(next.year, next.month, next.day + 2);
      final thu = DateTime(next.year, next.month, next.day + 3);
      engine
        ..saveEvent(at('Papiertonne', tue, allDay: true, who: const []))
        ..saveEvent(at('Biotonne', wed, allDay: true, who: const []))
        ..saveEvent(at('Glas', thu, allDay: true, who: const []))
        ..saveWasteSettings(
          WasteSettings(memberIds: [f.bea.id], remindHour: 19),
        );
      await engine.sync();
      await idle(tester, const Duration(seconds: 4));
      bool binNote(ActiveNotification n, String what) =>
          (n.title?.startsWith('Morgen: ') ?? false) && n.title!.contains(what);
      list = await jump(on(next, 18, 59, 30), const Duration(seconds: 70));
      note(
        'KAL-157 Bea\'s turn: ${describe(list.where((n) => binNote(n, '')).toList())}',
      );
      expect(list.where((n) => binNote(n, 'Papier')), isEmpty);
      engine.saveWasteSettings(const WasteSettings(remindHour: 19));
      await engine.sync();
      await idle(tester, const Duration(seconds: 4));
      list = await jump(on(tue, 18, 59, 30), const Duration(seconds: 70));
      final organic = list.where((n) => binNote(n, 'Biotonne')).toList();
      note('KAL-157 nobody chosen: ${describe(organic)}');
      expect(organic, hasLength(1));
      expect(organic.single.body, de.remindersTurnPleasePutOut);
      engine.saveVacation(
        Vacation(id: uid('vac'), from: thu, to: thu, title: 'E2E Urlaub'),
      );
      await engine.sync();
      await idle(tester, const Duration(seconds: 4));
      list = await jump(on(wed, 18, 59, 30), const Duration(seconds: 70));
      note(
        'KAL-157 holiday: ${describe(list.where((n) => binNote(n, 'Glas')).toList())}',
      );
      expect(list.where((n) => binNote(n, 'Glas')), isEmpty);

      // KAL-161: switched off, the next Sunday stays quiet.
      await pushSettings(tester);
      final weekSwitch = find.widgetWithText(
        SwitchListTile,
        de.pushWeekPreview,
      );
      await phoneScroll(tester, weekSwitch);
      await tap(tester, weekSwitch);
      await until(tester, () => !state.weekPreview, 'week preview off');
      await idle(tester, const Duration(seconds: 4));
      bool weekly(ActiveNotification n) =>
          n.title?.startsWith('Deine Woche') ?? false;
      // The first Sunday's may still be shown (or be taken back now).
      final before = (await shown()).where(weekly).length;
      final nextSunday = DateTime(sunday.year, sunday.month, sunday.day + 7);
      list = await jump(
        on(nextSunday, 17, 59, 40),
        const Duration(seconds: 60),
      );
      note('KAL-161 off: before $before, after ${list.where(weekly).length}');
      expect(
        list.where(weekly).length,
        lessThanOrEqualTo(before),
        reason: 'switched off, the next Sunday stays quiet',
      );
      // That one would list the week after (also when it replaced the old).
      expect(
        list.where(
          (n) => weekly(n) && (n.body ?? '').contains('E2E Naechste Woche'),
        ),
        isEmpty,
      );

      // KAL-136 in English: the headline too (was a hint: stayed German).
      await state.setLanguage('en');
      final english = familyBirthdays(
        engine,
      ).where((b) => b.name == 'E2E Mia').map((b) => b.headline(next)).toList();
      note('KAL-136 English: $english');
      expect(english, ['E2E Mia turns 8']);
      await state.setLanguage('de');
      await tap(tester, weekSwitch);
    } finally {
      await host('clock-reset');
      await state.setLanguage('de');
      await state.setWeekPreview(true);
      await finish(tester, state);
    }
  });
}
