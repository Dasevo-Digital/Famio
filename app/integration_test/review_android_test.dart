// Acceptance test of the Android-only features on an emulator against a
// throwaway server, one test per board card:
//
//   tool/android_review_tests.py emulator-5554 [--play-models]
//
// The script starts the server and answers the lines this test prints as
// `E2E-HOST …`: it grants the permissions Android asks a person for, moves
// the emulator (`adb emu geo fix`) and shares to Famio from outside the
// app: text like another app would (`am start -a …SEND`), photos and PDFs
// from the Files app (held, "Share", "Famio Dev"), and presses the back
// button. What
// Android shows is read back from its notification list. Only the camera
// is replaced at its plugin boundary: the test hands in a photographed
// receipt. With `--play-models` the app takes the text recognition from
// Google Play services instead of its own copy (the 64-bit release APK).
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/ocr.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/home_shell.dart';
import 'package:famio/src/security/app_lock.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import 'fresh_start.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');

/// `play` or `bundled`: where the text recognition must come from.
const _ocrModels = String.fromEnvironment('FAMIO_OCR_MODELS');

/// Home and a shop in Hamburg, a practice 6 km north of home.
const _home = (53.5753, 9.9950);
const _shop = (53.5833, 10.0120);
const _practice = (53.6290, 9.9950);

/// Stands in for the camera: the photo is [path].
class _FakeCamera extends ImagePickerPlatform {
  _FakeCamera(this.path);

  final String path;
  var shots = 0;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    shots++;
    return XFile(path);
  }
}

void main() {
  // The tests read German texts, whatever the device speaks.
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Asks the script around the test to do what only the host can.
  void host(String command) {
    // ignore: avoid_print
    print('E2E-HOST $command');
  }

  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    debugPrint('E2E wait ${finder.describeMatch(Plurality.many)}');
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isNotEmpty) return;
    }
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .join(' | ');
    // What Android shows, dialogs of the system included.
    host('shot');
    await tester.pump(const Duration(seconds: 3));
    throw TestFailure('Timed out waiting for $finder\nOn screen: $texts');
  }

  /// Pumps until [ok] holds.
  Future<void> until(
    WidgetTester tester,
    bool Function() ok,
    String what, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    debugPrint('E2E until $what');
    final end = DateTime.now().add(timeout);
    while (!ok()) {
      if (DateTime.now().isAfter(end)) {
        final texts = find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .whereType<String>()
            .join(' | ');
        throw TestFailure('Timed out: $what\nOn screen: $texts');
      }
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    debugPrint('E2E tap ${finder.describeMatch(Plurality.many)}');
    await waitFor(tester, finder);
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder.first);
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Types into [field]; the controller is taken first, so a finder by
  /// hint text still works once the hint is gone.
  Future<void> enter(WidgetTester tester, Finder field, String text) async {
    await waitFor(tester, field);
    final controller = tester.widget<TextField>(field.last).controller;
    await tester.tap(field.last);
    await tester.pump();
    await tester.enterText(field.last, text);
    await tester.pump();
    if (controller != null && controller.text != text) {
      controller.text = text;
      await tester.pump();
    }
  }

  /// Sections: on phones an icon in the bar (tooltip) or behind "Mehr".
  Future<void> openSection(WidgetTester tester, String label) async {
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == label) ||
            (w is Tooltip && (w.message == label || w.message == 'Mehr')),
      ),
    );
    if (find.byTooltip(label).evaluate().isNotEmpty) {
      await tap(tester, find.byTooltip(label).last);
    } else if (find.byTooltip('Mehr').evaluate().isNotEmpty) {
      await tap(tester, find.byTooltip('Mehr').last);
      await tap(tester, find.text(label).last);
    } else {
      await tap(tester, find.text(label).last);
    }
    // The first visit's tip; a person reads it and puts it away.
    await tester.pump(const Duration(milliseconds: 500));
    if (find.text('Verstanden').evaluate().isNotEmpty) {
      await tap(tester, find.text('Verstanden').last);
    }
  }

  /// Einstellungen → Push-Benachrichtigungen.
  Future<void> openPushSettings(WidgetTester tester) async {
    await openSection(tester, 'Einstellungen');
    await waitFor(tester, find.text('Server-Verwaltung'));
    // Further down the page, built once scrolled to.
    await tester.dragUntilVisible(
      find.text('Push-Benachrichtigungen'),
      find.byType(ListView).first,
      const Offset(0, -200),
    );
    await tap(tester, find.text('Push-Benachrichtigungen'));
    await waitFor(tester, find.text('Direkt über Famio'));
  }

  // --- What Android shows ---

  final android = FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Waits until Android shows a notification of Famio that [matches].
  Future<ActiveNotification> notification(
    WidgetTester tester,
    String what,
    bool Function(ActiveNotification n) matches, {
    Duration timeout = const Duration(minutes: 4),
  }) async {
    debugPrint('E2E notification $what');
    final end = DateTime.now().add(timeout);
    var shown = <ActiveNotification>[];
    while (DateTime.now().isBefore(end)) {
      shown = await android!.getActiveNotifications();
      for (final n in shown) {
        if (matches(n)) return n;
      }
      await tester.pump(const Duration(seconds: 2));
    }
    throw TestFailure(
      'No notification: $what\nShown: '
      '${shown.map((n) => '${n.title} / ${n.body}').join(' | ')}',
    );
  }

  // --- Server side: the admin's API session, other members, seed data ---

  FamioApiClient? adminApi;
  Future<FamioApiClient> admin() async {
    if (adminApi case final api?) return api;
    final api = FamioApiClient(_url);
    await api.login(username: _user, password: _password, device: 'e2e');
    return adminApi = api;
  }

  Future<FamilyMember> member(String username) async {
    final api = await admin();
    for (final u in await api.adminUsers()) {
      if (u.member.username == username) return u.member;
    }
    return api.createMember(
      username: username,
      displayName: 'E2E Papa',
      password: '$username-123',
      role: MemberRole.adult,
    );
  }

  Future<FamioApiClient> signInAs(String username) async {
    final api = FamioApiClient(_url);
    await api.login(
      username: username,
      password: '$username-123',
      device: 'e2e',
    );
    return api;
  }

  /// Writes [records] (collection, id, data) as [api] (the admin when
  /// null), as if built up in the app over time.
  Future<void> seed(
    List<(String, String, Map<String, Object?>)> records, {
    FamioApiClient? api,
  }) async {
    final client = api ?? await admin();
    final now = DateTime.now().millisecondsSinceEpoch;
    final response = await client.sync(
      SyncRequest(
        since: 0,
        changes: [
          for (final (collection, id, data) in records)
            SyncRecord(
              collection: collection,
              id: id,
              data: data,
              updatedAt: now,
            ),
        ],
      ),
    );
    expect(
      response.rejected.map((r) => r.id),
      isEmpty,
      reason: 'seed data refused',
    );
  }

  Future<void> unseed(List<(String, String)> records) async {
    final api = await admin();
    await api.sync(
      SyncRequest(
        since: 0,
        changes: [
          for (final (collection, id) in records)
            SyncRecord(
              collection: collection,
              id: id,
              data: const {},
              deleted: true,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
        ],
      ),
    );
  }

  /// What the admin gets from the server: the newest version of every
  /// record, deletions included.
  Future<Map<String, SyncRecord>> serverView() async {
    final api = await admin();
    final view = <String, SyncRecord>{};
    var since = 0;
    while (true) {
      final response = await api.sync(SyncRequest(since: since));
      for (final r in response.changes) {
        view['${r.collection}/${r.id}'] = r;
      }
      since = response.rev;
      if (!response.hasMore) return view;
    }
  }

  List<SyncRecord> live(Map<String, SyncRecord> view, String collection) => [
    for (final r in view.values)
      if (r.collection == collection && !r.deleted) r,
  ];

  /// Polls the server until [check] gives a result.
  Future<T> serverUntil<T>(
    WidgetTester tester,
    String what,
    T? Function(Map<String, SyncRecord> view) check, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    debugPrint('E2E server $what');
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (check(await serverView()) case final result?) return result;
      await tester.pump(const Duration(seconds: 2));
    }
    throw TestFailure('Server never showed: $what');
  }

  Map<String, Object?> place(
    String id,
    String name,
    (double, double) at, {
    bool shop = false,
  }) => Place(
    id: id,
    name: name,
    latitude: at.$1,
    longitude: at.$2,
    radius: 150,
    shop: shop,
  ).toData();

  // --- The app ---

  Future<AppState> start(WidgetTester tester) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    await initializeDateFormatting('de');
    await freshStart();
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    if (state.me == null) {
      await enter(
        tester,
        find.widgetWithText(TextField, 'Server-Adresse'),
        _url,
      );
      await tap(tester, find.text('Verbinden'));
      await enter(
        tester,
        find.widgetWithText(TextField, 'Benutzername'),
        _user,
      );
      await enter(
        tester,
        find.widgetWithText(TextField, 'Passwort'),
        _password,
      );
      await tap(tester, find.text('Anmelden'));
    }
    await until(
      tester,
      () => state.me != null && state.engine != null,
      'signed in',
    );
    await state.engine!.sync();
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == 'Start') ||
            (w is Tooltip && w.message == 'Start'),
      ),
    );
    // Android asks about notifications once; a person said yes.
    if (find.text('Später').evaluate().isNotEmpty) {
      await tap(tester, find.text('Später'));
    }
    return state;
  }

  /// Removes what the test left in [collections] and signs out, so the
  /// next test starts clean.
  Future<void> finish(
    WidgetTester tester,
    AppState state,
    Set<String> collections,
  ) async {
    try {
      final engine = state.engine;
      if (engine != null) {
        for (final c in collections) {
          for (final r in engine.records(c).toList()) {
            engine.delete(c, r.id);
          }
        }
        await engine.sync();
      }
      await state.signOut();
      await tester.pump(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('E2E clean-up failed: $e');
    }
  }

  testWidgets('the emulator allows what a person would allow', (tester) async {
    // Notifications, location (also in the background) and exact alarms:
    // Android asks a person in dialogs a test cannot tap.
    host('grant');
    final end = DateTime.now().add(const Duration(minutes: 1));
    while (await android!.areNotificationsEnabled() != true) {
      if (DateTime.now().isAfter(end)) fail('notifications not allowed');
      await tester.pump(const Duration(seconds: 1));
    }
    expect(await android.canScheduleExactNotifications(), isTrue);
  });

  testWidgets('#212 #180 Kassenbon fotografieren und lesen', (tester) async {
    // A receipt as the camera would see it.
    const lines = [
      'E2E MARKT',
      'Lindenallee 5',
      '20259 Hamburg',
      '',
      'Milch            1,29',
      'Brot             2,49',
      'Kaffee           8,99',
      'Kaese           10,70',
      '',
      'SUMME EUR       23,47',
      'Bar             30,00',
      'Rueckgeld        6,53',
    ];
    final photo = await tester.runAsync(() async {
      const width = 900.0;
      final height = 140.0 + lines.length * 70;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawRect(
          Rect.fromLTWH(0, 0, width, height),
          Paint()..color = Colors.white,
        );
      for (final (i, line) in lines.indexed) {
        TextPainter(
            text: TextSpan(
              text: line,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 44,
                fontFamily: 'monospace',
              ),
            ),
            textDirection: TextDirection.ltr,
          )
          ..layout(maxWidth: width - 120)
          ..paint(canvas, Offset(60, 70.0 + i * 70));
      }
      final image = await recorder.endRecording().toImage(
        width.toInt(),
        height.toInt(),
      );
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${(await getTemporaryDirectory()).path}/e2e-bon.png');
      await file.writeAsBytes(png!.buffer.asUint8List());
      return file;
    });
    final camera = _FakeCamera(photo!.path);
    ImagePickerPlatform.instance = camera;

    final models = await Ocr.models();
    debugPrint('E2E text recognition from: $models');
    if (_ocrModels.isNotEmpty) expect(models, _ocrModels);

    final state = await start(tester);
    try {
      final engine = state.engine!;
      await openSection(tester, 'Einkauf');
      await tap(tester, find.byTooltip('Neue Liste'));
      await enter(tester, find.widgetWithText(TextField, 'Name'), 'E2E Bon');
      await tap(tester, find.text('OK'));
      for (final item in ['Milch', 'Brot']) {
        await enter(tester, find.byType(TextField).first, item);
        await tap(tester, find.byTooltip('Hinzufügen'));
        await waitFor(tester, find.text(item));
      }
      await tap(tester, find.text('Milch'));
      await tap(tester, find.text('Brot'));
      await waitFor(tester, find.text('Im Wagen (2)'));
      await tap(tester, find.text('Bezahlt? Betrag ins Haushaltsbuch'));
      await waitFor(tester, find.text('Einkauf ins Haushaltsbuch'));

      final amount = find.widgetWithText(TextField, 'Betrag laut Kassenbon');
      String amountText() =>
          tester.widget<TextField>(amount).controller?.text ?? '';
      // From Google Play the model may still be on its way: Famio says so
      // and a person tries again a minute later.
      final end = DateTime.now().add(const Duration(minutes: 5));
      while (true) {
        await tap(tester, find.byTooltip('Kassenbon fotografieren'));
        await until(
          tester,
          () =>
              find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              (amountText().isNotEmpty ||
                  find.textContaining('Texterkennung').evaluate().isNotEmpty ||
                  find
                      .text('Auf dem Bon war kein Betrag zu erkennen.')
                      .evaluate()
                      .isNotEmpty),
          'receipt read',
          timeout: const Duration(minutes: 1),
        );
        if (amountText().isNotEmpty) break;
        expect(
          find.text('Auf dem Bon war kein Betrag zu erkennen.'),
          findsNothing,
          reason: 'the receipt was not read',
        );
        if (DateTime.now().isAfter(end)) fail('recognition never loaded');
        debugPrint('E2E recognition still loading, trying again');
        await tester.pump(const Duration(seconds: 20));
      }
      expect(camera.shots, greaterThanOrEqualTo(1));
      expect(amountText(), '23,47');
      expect(
        find.text('Vom Kassenbon gelesen – bitte prüfen.'),
        findsOneWidget,
      );
      final note = find.widgetWithText(TextField, 'Was oder wo (optional)');
      expect(
        tester.widget<TextField>(note).controller?.text.toUpperCase(),
        'E2E MARKT',
      );
      await tap(tester, find.text('Eintragen'));
      await waitFor(
        tester,
        find.textContaining('als Ausgabe für Lebensmittel eingetragen.'),
      );

      await engine.sync();
      final entries = live(
        await serverView(),
        Collections.budgetEntries,
      ).map(BudgetEntry.fromRecord).toList();
      expect(entries.map((e) => (e.cents, e.category)), [
        (2347, 'Lebensmittel'),
      ]);
    } finally {
      await finish(tester, state, {
        Collections.shoppingLists,
        Collections.shoppingItems,
        Collections.shoppingHistory,
        Collections.budgetEntries,
      });
    }
  });

  testWidgets('#188 Tagesüberblick zur gewählten Uhrzeit', (tester) async {
    final state = await start(tester);
    try {
      final me = state.me!.id;
      final now = DateTime.now();
      final eventId = newId();
      await seed([
        (
          Collections.events,
          eventId,
          CalendarEvent(
            id: eventId,
            title: 'E2E Zahnarzt',
            start: now.add(const Duration(hours: 3)),
            end: now.add(const Duration(hours: 4)),
            memberIds: [me],
          ).toData(),
        ),
      ]);
      await state.engine!.sync();

      await openPushSettings(tester);
      final card = find.widgetWithText(SwitchListTile, 'Tagesüberblick');
      await tester.dragUntilVisible(
        card,
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      if (!tester.widget<SwitchListTile>(card).value) await tap(tester, card);
      await until(tester, () => state.dayPreview != null, 'switched on');

      // Two minutes from now, typed into the clock's text mode.
      var at = DateTime.now().add(const Duration(minutes: 2));
      if (at.second > 45) at = at.add(const Duration(minutes: 1));
      if (at.day != now.day) {
        markTestSkipped('too close to midnight for today\'s overview');
        return;
      }
      await tap(tester, find.text('Uhrzeit ändern'));
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
      await tap(tester, find.text('OK'));
      await until(
        tester,
        () => state.dayPreview == at.hour * 60 + at.minute,
        'time set',
      );

      final shown = await notification(
        tester,
        'day overview',
        (n) => n.title?.contains('Dein Tag') ?? false,
      );
      expect(shown.body, contains('E2E Zahnarzt'));
      expect(
        DateTime.now().isAfter(at.subtract(const Duration(seconds: 59))),
        isTrue,
        reason: 'not before the chosen time',
      );
      await state.setDayPreview(null);
    } finally {
      await finish(tester, state, {Collections.events});
    }
  });

  testWidgets('#290 Zurück-Taste: erst die Seite, dann Start, dann raus', (
    tester,
  ) async {
    // The test binding forgets the app's lifecycle state after each test.
    // Without one, Flutter never tells Android that it handles back itself,
    // and Android closes Famio on every press: as Famio starts, resumed.
    tester.platformDispatcher.initialLifecycleStateTestValue = AppLifecycleState
        .resumed
        .toString();
    addTearDown(tester.platformDispatcher.resetInitialLifecycleState);
    tester.binding.readTestInitialLifecycleStateFromNativeWindow();

    // What Flutter tells Android: whether back goes to Famio (true) or
    // Android handles it, which leaves Famio (false). Passed on unchanged.
    bool? handlesBack;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMessageHandler(SystemChannels.platform.name, (data) {
      final call = SystemChannels.platform.codec.decodeMethodCall(data);
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        handlesBack = call.arguments as bool;
      }
      return messenger.delegate.send(SystemChannels.platform.name, data);
    });
    addTearDown(
      () => messenger.setMockMessageHandler(SystemChannels.platform.name, null),
    );

    /// The back button pressed on the device; true if Famio is still in
    /// front afterwards. Waits in real time: a pump needs frames, and Famio
    /// in the background has none.
    Future<bool> back() async {
      // Flutter tells Android whether it handles back after a frame; a
      // person is never faster than that.
      await tester.pumpAndSettle();
      expect(handlesBack, isTrue, reason: 'Android would handle back');
      host('back');
      await Future<void>.delayed(const Duration(seconds: 3));
      return WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed;
    }

    final state = await start(tester);
    try {
      // A page within the start section, as opened from one of its cards.
      final section = tester.element(
        find
            .descendant(
              of: find.byType(HomeShell),
              matching: find.byType(Scaffold),
            )
            .last,
      );
      unawaited(
        Navigator.of(section).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Center(child: Text('E2E Unterseite'))),
          ),
        ),
      );
      await waitFor(tester, find.text('E2E Unterseite'));
      expect(await back(), isTrue, reason: 'back on a page closed Famio');
      await until(
        tester,
        () => find.text('E2E Unterseite').evaluate().isEmpty,
        'page closed',
      );

      // From another section to the start page.
      await tap(tester, find.byTooltip('Einkauf'));
      await waitFor(tester, find.text('Was brauchen wir?'));
      expect(
        await back(),
        isTrue,
        reason: 'back in the shopping list closed Famio',
      );
      await until(
        tester,
        () => find.text('Was brauchen wir?').evaluate().isEmpty,
        'back on the start page',
      );

      // On the start page Android handles back and leaves Famio as usual.
      // Not pressed here: Android would end the test's activity with it.
      await tester.pumpAndSettle();
      expect(handlesBack, isFalse);
    } finally {
      await finish(tester, state, {});
    }
  });

  testWidgets('#302 App-Sperre mit dem echten Dialog von Android', (
    tester,
  ) async {
    // As in #290: without a lifecycle state nothing reaches the app lock.
    tester.platformDispatcher.initialLifecycleStateTestValue = AppLifecycleState
        .resumed
        .toString();
    addTearDown(tester.platformDispatcher.resetInitialLifecycleState);
    tester.binding.readTestInitialLifecycleStateFromNativeWindow();
    host('pin-set');
    await Future<void>.delayed(const Duration(seconds: 2));
    final state = await start(tester);
    try {
      expect(await state.lock.available, isTrue);
      // Android only shows its dialog over the app in front; the sharing
      // test may have left the Files app there.
      host('front');
      await Future<void>.delayed(const Duration(seconds: 3));
      final on = state.lock.setEnabled(true);
      await Future<void>.delayed(const Duration(seconds: 3));
      host('pin-enter');
      expect(await on, isTrue);
      await tester.pumpAndSettle();
      expect(state.lock.locked, isFalse);
      host('secure-on');
      await Future<void>.delayed(const Duration(seconds: 2));

      // Away for longer than the grace period: locked on return.
      host('home');
      await Future<void>.delayed(
        AppLock.defaultDelay + const Duration(seconds: 5),
      );
      host('front');
      await waitFor(tester, find.text('Famio ist gesperrt'));
      await Future<void>.delayed(const Duration(seconds: 3));
      host('pin-enter');
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (state.lock.locked && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(state.lock.locked, isFalse);
      await tester.pumpAndSettle();
      expect(find.text('Famio ist gesperrt'), findsNothing);

      // And off again, with the window flag.
      final off = state.lock.setEnabled(false);
      await Future<void>.delayed(const Duration(seconds: 3));
      host('pin-enter');
      expect(await off, isTrue);
      host('secure-off');
      await Future<void>.delayed(const Duration(seconds: 2));
    } finally {
      host('pin-clear');
      await Future<void>.delayed(const Duration(seconds: 2));
      await finish(tester, state, {});
    }
  });

  testWidgets('#393 Sofort sperren, die Dateiauswahl ausgenommen', (
    tester,
  ) async {
    tester.platformDispatcher.initialLifecycleStateTestValue = AppLifecycleState
        .resumed
        .toString();
    addTearDown(tester.platformDispatcher.resetInitialLifecycleState);
    tester.binding.readTestInitialLifecycleStateFromNativeWindow();
    host('pin-set');
    await Future<void>.delayed(const Duration(seconds: 2));
    final state = await start(tester);
    final seen = <AppLifecycleState>[];
    final listener = AppLifecycleListener(onStateChange: seen.add);
    // No pumping here: in the background Android draws no frames, and
    // pump() would wait for one forever.
    Future<void> background() async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!seen.contains(AppLifecycleState.paused)) {
        if (DateTime.now().isAfter(end)) {
          throw TestFailure('Famio did not go to the background: $seen');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    // Android's PIN screen can take a moment after another app closed.
    Future<void> unlock() async {
      await waitFor(tester, find.text('Famio ist gesperrt'));
      for (var attempt = 1; attempt <= 3 && state.lock.locked; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (state.lock.failed) {
          debugPrint('E2E unlock: asking again ($attempt)');
          await tester.tap(find.text('Entsperren'));
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        host('pin-enter');
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (state.lock.locked && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        if (state.lock.locked) {
          debugPrint('E2E unlock: still locked after attempt $attempt');
          host('shot');
        }
      }
      expect(state.lock.locked, isFalse);
      await tester.pumpAndSettle();
    }

    try {
      host('front');
      await Future<void>.delayed(const Duration(seconds: 3));
      final on = state.lock.setEnabled(true);
      await Future<void>.delayed(const Duration(seconds: 3));
      host('pin-enter');
      expect(await on, isTrue);
      await state.lock.setDelay(Duration.zero);
      await tester.pumpAndSettle();

      // At once: as soon as Android has sent Famio to the background. The
      // emulator takes its time with that, a phone does not.
      seen.clear();
      host('home');
      await background();
      host('front');
      await unlock();

      // Android's own file picker sends Famio to the background, yet coming
      // back from it needs no unlock.
      seen.clear();
      final picked = AppLock.picking(FilePicker.pickFiles);
      await background();
      await Future<void>.delayed(const Duration(seconds: 2));
      host('back');
      expect(await picked, isEmpty);
      await until(
        tester,
        () => seen.contains(AppLifecycleState.resumed),
        'back from the picker',
      );
      await tester.pump(const Duration(seconds: 2));
      expect(state.lock.locked, isFalse);
      expect(find.text('Famio ist gesperrt'), findsNothing);

      // Without announcing the picker the same trip locks.
      seen.clear();
      final plain = FilePicker.pickFiles();
      await background();
      await Future<void>.delayed(const Duration(seconds: 2));
      host('back');
      expect(await plain, isEmpty);
      await unlock();

      // Signed out, and on the way back in a trip to another app (password
      // manager, authenticator): the fresh sign-in is proof enough.
      await state.signOut();
      await tester.pumpAndSettle();
      seen.clear();
      host('home');
      await background();
      host('front');
      if (find.text('Verbinden').evaluate().isEmpty) {
        await waitFor(tester, find.widgetWithText(TextField, 'Benutzername'));
      } else {
        await enter(
          tester,
          find.widgetWithText(TextField, 'Server-Adresse'),
          _url,
        );
        await tap(tester, find.text('Verbinden'));
      }
      expect(state.lock.locked, isTrue, reason: 'the trip counted');
      await enter(
        tester,
        find.widgetWithText(TextField, 'Benutzername'),
        _user,
      );
      await enter(
        tester,
        find.widgetWithText(TextField, 'Passwort'),
        _password,
      );
      await tap(tester, find.text('Anmelden'));
      await until(tester, () => state.me != null, 'signed in again');
      await tester.pump(const Duration(seconds: 2));
      expect(state.lock.locked, isFalse);
      expect(find.text('Famio ist gesperrt'), findsNothing);
      if (find.text('Später').evaluate().isNotEmpty) {
        await tap(tester, find.text('Später'));
      }

      await state.lock.setDelay(AppLock.defaultDelay);
      final off = state.lock.setEnabled(false);
      await Future<void>.delayed(const Duration(seconds: 3));
      host('pin-enter');
      expect(await off, isTrue);
    } finally {
      listener.dispose();
      host('pin-clear');
      await Future<void>.delayed(const Duration(seconds: 2));
      await finish(tester, state, {});
    }
  });

  testWidgets('#199 Rechtzeitig losfahren zu einem Familienort', (
    tester,
  ) async {
    final homeId = newId();
    final practiceId = newId();
    await seed([
      (Collections.places, homeId, place(homeId, 'Zuhause', _home)),
      (
        Collections.places,
        practiceId,
        place(practiceId, 'E2E Praxis', _practice),
      ),
    ]);
    final state = await start(tester);
    try {
      expect(state.departureMode, TripMode.car);
      // 6 km by car: 16 minutes and 5 to spare. The appointment starts so
      // that it is time to leave in two minutes.
      final now = DateTime.now();
      final leave = DateTime(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute + 2,
      );
      final start = leave.add(const Duration(minutes: 21));
      final eventId = newId();
      await seed([
        (
          Collections.events,
          eventId,
          CalendarEvent(
            id: eventId,
            title: 'E2E Arzttermin',
            start: start,
            end: start.add(const Duration(hours: 1)),
            location: 'E2E Praxis, 2. Stock',
            memberIds: [state.me!.id],
          ).toData(),
        ),
      ]);
      await state.engine!.sync();

      final shown = await notification(
        tester,
        'departure',
        (n) => n.title?.contains('Losfahren: E2E Arzttermin') ?? false,
      );
      expect(shown.title, startsWith('🚗'));
      expect(shown.body, contains('E2E Praxis'));
      expect(shown.body, contains('16 Min.'));
      expect(
        DateTime.now().isAfter(leave.subtract(const Duration(seconds: 59))),
        isTrue,
        reason: 'not before it is time to leave',
      );
    } finally {
      await finish(tester, state, {Collections.events});
      await unseed([
        (Collections.places, homeId),
        (Collections.places, practiceId),
      ]);
    }
  });

  testWidgets('#183 Teilen an Famio aus einer anderen App', (tester) async {
    final listId = newId();
    await seed([
      (
        Collections.shoppingLists,
        listId,
        ShoppingList(id: listId, name: 'E2E Teilen').toData(),
      ),
    ]);
    final state = await start(tester);
    try {
      final engine = state.engine!;

      /// The script shares [what]; Famio offers where it goes.
      Future<void> share(String what, String target) async {
        host('share $what');
        await waitFor(
          tester,
          find.text('Teilen an Famio'),
          timeout: const Duration(minutes: 1),
        );
        await tap(tester, find.text(target));
      }

      // The editor's button: in its sheet, or on the page just opened
      // (other sections keep their pages, and buttons, built underneath).
      Future<void> save() async {
        await waitFor(tester, find.text('Speichern'));
        await tester.pump(const Duration(milliseconds: 500));
        var button = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Speichern'),
        );
        if (button.evaluate().isEmpty) {
          button = find.text('Speichern').hitTestable();
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

      // A list from a messenger: one item per line, bullets gone.
      await share('list', 'Auf die Einkaufsliste');
      if (find.text('Auf welche Liste?').evaluate().isNotEmpty) {
        await tap(tester, find.text('E2E Teilen').last);
      }
      await until(
        tester,
        () => engine
            .shoppingItems(listId)
            .map((i) => i.name)
            .toSet()
            .containsAll({'Milch', 'Brot', 'Eier'}),
        'three items on the list',
      );

      // A link from the browser, as a note.
      await share('link', 'Als Notiz auf die Pinnwand');
      await save();
      await until(
        tester,
        () => engine.notes.any(
          (n) =>
              n.title == 'E2E Rezept' &&
              n.text.contains('https://example.org/rezept'),
        ),
        'note with the link',
      );

      // A photo from the gallery, as a task.
      await share('photo', 'Als Aufgabe');
      await save();
      await until(
        tester,
        () => engine.tasks.any((t) => t.photos.length == 1),
        'task with the photo',
      );

      // A PDF from the mail, as a document.
      await share('pdf', 'Als Dokument speichern');
      await save();
      await until(
        tester,
        () => engine.documents.any((d) => d.file?.name == 'e2e-zeugnis.pdf'),
        'document with the PDF',
      );

      // The same PDF, into the family chat.
      await share('pdf', 'In den Familien-Chat');
      await waitFor(tester, find.text('In den Familien-Chat geschickt'));

      // Something to sort later, into the family inbox.
      await share('text', 'Im Familien-Eingang ablegen');
      await waitFor(tester, find.text('Im Familien-Eingang abgelegt.'));

      await engine.sync();
      final view = await serverView();
      final task = live(
        view,
        Collections.tasks,
      ).map(Task.fromRecord).singleWhere((t) => t.photos.isNotEmpty);
      expect(task.photos.single.mime, startsWith('image/'));
      final document = live(
        view,
        Collections.documents,
      ).map(FamilyDocument.fromRecord).single;
      expect(document.file?.mime, 'application/pdf');
      final chat = live(
        view,
        Collections.chatMessages,
      ).map(ChatMessage.fromRecord).toList();
      expect(chat, hasLength(1));
      expect(chat.single.attachment?.name, 'e2e-zeugnis.pdf');
      expect(chat.single.attachment?.mime, 'application/pdf');
      final inbox = live(
        view,
        Collections.inbox,
      ).map(InboxItem.fromRecord).toList();
      expect(inbox.map((i) => i.title), ['Elternabend am Donnerstag']);
    } finally {
      await finish(tester, state, {
        Collections.shoppingLists,
        Collections.shoppingItems,
        Collections.notes,
        Collections.tasks,
        Collections.documents,
        Collections.chatMessages,
        Collections.inbox,
      });
    }
  });

  testWidgets('#175 Bin unterwegs: Familie hört davon, eigene Fahrt', (
    tester,
  ) async {
    // The shop's arrival notice (#184) needs a second position after the
    // first, which the emulator's location service does not report
    // reliably: that is checked on a phone.
    final homeId = newId();
    final shopId = newId();
    final papa = await member('e2e-papa');
    await seed([
      (Collections.places, homeId, place(homeId, 'Zuhause', _home)),
      (
        Collections.places,
        shopId,
        place(shopId, 'E2E Markt', _shop, shop: true),
      ),
    ]);
    host('geo ${_home.$1} ${_home.$2}');
    final state = await start(tester);
    final me = state.me!.id;
    try {
      // Famio's own push on this phone: the server's notices arrive
      // without ntfy.
      await openPushSettings(tester);
      final phone = find.widgetWithText(SwitchListTile, 'Auf diesem Handy');
      await waitFor(tester, phone);
      if (!tester.widget<SwitchListTile>(phone).value) await tap(tester, phone);
      await until(
        tester,
        () => tester.widget<SwitchListTile>(phone).value,
        'own push on',
      );
      // Back to the start page: the app opened anew (still signed in).
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(FamioApp(state: state));
      await waitFor(tester, find.byTooltip('Mehr'));

      // Papa sets off home: this phone hears about it.
      final papaApi = await signInAs('e2e-papa');
      final now = DateTime.now();
      await seed([
        (
          Collections.trips,
          papa.id,
          Trip(
            memberId: papa.id,
            placeId: homeId,
            placeName: 'Zuhause',
            eta: now.add(const Duration(minutes: 20)),
            startedAt: now,
          ).toData(),
        ),
      ], api: papaApi);
      final onTheWay = await notification(
        tester,
        'papa on the way',
        (n) => n.body?.contains('E2E Papa ist unterwegs nach Zuhause') ?? false,
        timeout: const Duration(minutes: 2),
      );
      debugPrint('E2E trip notice: ${onTheWay.body}');

      // This phone's owner heads for the shop and tells the family.
      await openSection(tester, 'Standort');
      await tap(tester, find.text('Bin unterwegs'));
      await waitFor(tester, find.text('Wohin bist du unterwegs?'));
      // The shop as destination, picked in the menu (the map behind the
      // dialog shows the same name).
      final destination = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(DropdownButtonFormField<Place>),
      );
      await waitFor(tester, destination);
      if (find
          .descendant(of: destination, matching: find.text('E2E Markt'))
          .evaluate()
          .isEmpty) {
        await tap(tester, destination);
        await tester.pump(const Duration(seconds: 1));
        await tap(
          tester,
          find
              .descendant(
                of: find.byType(DropdownMenuItem<Place>),
                matching: find.text('E2E Markt'),
              )
              .last,
        );
      }
      await waitFor(tester, find.text('Wohin bist du unterwegs?'));
      await tap(tester, find.byTooltip('Zu Fuß'));
      await tap(tester, find.text('Familie Bescheid geben'));
      final trip = await serverUntil(
        tester,
        'own trip',
        (view) => switch (view['${Collections.trips}/$me']) {
          final r? when !r.deleted => Trip.fromRecord(r),
          _ => null,
        },
      );
      expect((trip.placeName, trip.mode), ('E2E Markt', TripMode.walk));

      // Sharing the location, then arriving at the shop.
      await tap(tester, find.text('Standort teilen'));
      await waitFor(
        tester,
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data == 'Später' || w.data == 'Du teilst deinen Standort'),
        ),
        timeout: const Duration(minutes: 1),
      );
      if (find.text('Später').evaluate().isNotEmpty) {
        await tap(tester, find.text('Später'));
      }
      await waitFor(tester, find.text('Du teilst deinen Standort'));
      await serverUntil(
        tester,
        'position at home',
        (view) => switch (view['${Collections.memberLocations}/$me']) {
          final r? when MemberLocation.fromRecord(r).placeId == homeId => true,
          _ => null,
        },
      );
      // Ending it on the phone needs the parents' code; signing out at the
      // end of the test ends it as well.
    } finally {
      await finish(tester, state, {
        Collections.trips,
        Collections.shoppingLists,
        Collections.shoppingItems,
        Collections.places,
      });
      await (await admin()).deleteMember(papa.id);
    }
  });
}
