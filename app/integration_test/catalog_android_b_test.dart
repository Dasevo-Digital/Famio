// Catalog entries added on 23.11.2026 that need Android: tapped
// notifications of the own push and of the reminders open what they are
// about (#385), famio:// links, the targets of "Teilen an Famio", signing out
// on the phone ends sharing there (#577), the schedule followed by the server
// (#576), an alarm ended at once (#536), "Erkennung ohne Google Play" and a
// shown reminder that stays. On an emulator against a throwaway server:
//
//   tool/android_review_tests.py emulator-5572 \
//     --file integration_test/catalog_android_b_test.dart [--name REGEX]
//
// The helpers for the host (`E2E-HOST …`), the notifications Android shows
// and the sections come from catalog_android_test.dart. Each test names the
// catalog entries it checks.
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/app_update.dart';
import 'package:famio/src/data/country.dart';
import 'package:famio/src/data/deadlines.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/loans.dart';
import 'package:famio/src/home_widget/widget_sync.dart';
import 'package:famio/src/design/palette.dart' show FamioSection;
import 'package:famio/src/screens/calendar_screen.dart';
import 'package:famio/src/screens/chat_screens.dart';
import 'package:famio/src/screens/chores_screens.dart';
import 'package:famio/src/screens/deadlines_screen.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio/src/l10n.dart' show deviceLanguage;
import 'package:famio/src/screens/kids_screens.dart'
    show ChildScreen, KidsScreen;
import 'package:famio/src/screens/loans_screen.dart';
import 'package:famio/src/screens/location_screens.dart';
import 'package:famio/src/screens/medication_screens.dart';
import 'package:famio/src/screens/pregnancy_screens.dart';
import 'package:famio/src/screens/settings_screen.dart';
import 'package:famio/src/screens/sos_alert_screen.dart';
import 'package:famio/src/screens/subscriptions_screen.dart';
import 'package:famio/src/screens/tasks_screen.dart';
import 'package:famio/src/location/location_sharing.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_widget/home_widget.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_android_test.dart'
    show
        androidTest,
        b64,
        clean,
        describe,
        fieldWith,
        host,
        hostOk,
        idle,
        lifecycleForLock,
        minuteAfter,
        note,
        notification,
        openAlertOf,
        phoneScroll,
        placeTodayWidget,
        quietSos,
        resolveAll,
        section,
        seed,
        shown,
        todayWidget,
        until,
        untilAsync,
        waitUi;
import 'catalog_kit.dart';

/// A park in Hamburg, a school 2 km away.
const _home = (53.5600, 9.9800);
const _school = (53.5750, 10.0050);

final _plugin = FlutterLocalNotificationsPlugin();

/// The app lock on or off as its switch leaves it once the device's
/// question was answered (that question is the GRU-110 test's).
Future<void> _lockPrefs(bool on) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('appLock.enabled', on);
}

/// Takes Famio's notifications off the screen (the own push's lasting one
/// stays), so a few at a time are shown: Android bundles four and more, and
/// a tap on the bundle opens only the app.
Future<void> clearShown() async {
  for (final n in await shown()) {
    if (n.id == null || n.channelId == 'famio_connection') continue;
    await _plugin.cancel(id: n.id!, tag: n.tag);
  }
}

/// Pages, sheets and dialogs closed, every section at its first page (not
/// the back button: on the start page it would leave Famio).
Future<void> resetPages(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    for (final e in find.byType(Navigator, skipOffstage: false).evaluate()) {
      final navigator = (e as StatefulElement).state as NavigatorState;
      if (navigator.mounted && navigator.canPop()) {
        navigator.popUntil((r) => r.isFirst);
      }
    }
    await idle(tester, const Duration(milliseconds: 600));
  }
}

/// Waits for Famio's notification with [text] in its title or body, then
/// taps it in the notification shade like a person. With [away] Famio is in
/// the background first (the home screen in front).
Future<ActiveNotification> tapNotice(
  WidgetTester tester,
  String what,
  String text, {
  bool away = false,
  Duration timeout = const Duration(minutes: 4),
}) async {
  final n = await notification(
    tester,
    what,
    (n) => '${n.title} ${n.body}'.contains(text),
    timeout: timeout,
  );
  note('$what: ${n.title} / ${n.body}');
  // Alone on the screen: two or more of Famio's are bundled, and a tap
  // on a bundled one may only open the bundle.
  for (final other in await shown()) {
    if (other.id == null ||
        other.id == n.id ||
        other.channelId == 'famio_connection') {
      continue;
    }
    await _plugin.cancel(id: other.id!, tag: other.tag);
  }
  if (away) {
    await hostOk('home');
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  await hostOk('tap-notification ${b64(text)} 30');
  return n;
}

/// [type] is the page on screen (other sections and covered pages are
/// offstage for the finder).
Future<void> opens(
  WidgetTester tester,
  Type type, {
  Duration timeout = const Duration(seconds: 40),
}) => waitUi(tester, find.byType(type), timeout: timeout);

/// The calendar shows [day] as its selected day.
Future<void> calendarOn(WidgetTester tester, DateTime day) => waitUi(
  tester,
  find.descendant(
    of: find.byType(CalendarScreen),
    matching: find.text(DateFormat.MMMMEEEEd('de').format(day)),
  ),
);

/// Own push on for this phone (Android asked before: granted by the host).
Future<void> ownPush(WidgetTester tester, AppState state) async {
  await state.ownPush!.setEnabled(true);
  await idle(tester, const Duration(seconds: 4));
}

Future<MemberLocation?> locationOf(FamioApiClient api, String id) async {
  final r = (await pull(api, Collections.memberLocations))[id];
  return r == null || r.deleted ? null : MemberLocation.fromRecord(r);
}

LocationFix fixAt((double, double) at, {int? battery}) => LocationFix(
  latitude: at.$1,
  longitude: at.$2,
  accuracy: 12,
  at: DateTime.now().toUtc(),
  battery: battery,
);

/// Settings → "Abmelden" on the child's phone: the questions one after the
/// other, as [answers] says ("cancel", "anyway", a code).
Finder _inDialog(String label) => find.descendant(
  of: find.byType(Dialog),
  matching: find.widgetWithText(FilledButton, label),
);

Finder _dialogText(String label) =>
    find.descendant(of: find.byType(Dialog), matching: find.text(label));

Future<void> tapSignOut(WidgetTester tester) async {
  await section(tester, de.sectionSettings);
  await phoneScroll(tester, find.text(de.settingsSignOut));
  await tap(tester, find.text(de.settingsSignOut));
}

/// Signs the child out on the phone with the parents' code (and "Trotzdem
/// abmelden" first if asked).
Future<void> signOutWithCode(
  WidgetTester tester,
  AppState state,
  String code,
) async {
  await tapSignOut(tester);
  await idle(tester, const Duration(seconds: 2));
  if (find.text(de.signOutUnsentTitle).evaluate().isNotEmpty) {
    await tap(tester, _dialogText(de.signOutAnyway));
    await idle(tester, const Duration(seconds: 1));
  }
  await until(
    tester,
    () =>
        state.me == null ||
        find.text(de.locationEndLocationSharing).evaluate().isNotEmpty,
    'the parents\' code asked',
  );
  if (state.me != null) {
    await enter(tester, field(de.adminParentsCode), code);
    await tap(tester, _inDialog(de.commonEnd2));
  } else {
    note('signed out without the parents\' code');
  }
  await until(tester, () => state.me == null, 'signed out');
}

/// A device of [api]'s member that only reports positions (as a phone's
/// location service does), to be signed out at the end.
Future<FamioApiClient> locationDevice(FamioApiClient api, String name) async =>
    FamioApiClient(kitUrl, token: await api.locationDeviceToken(name));

/// Ends a pause of [memberId]'s sharing, if there is one.
Future<void> _resume(FamioApiClient admin, String memberId) async {
  try {
    await admin.resumeLocation(memberId: memberId);
  } on ApiError {
    // Not paused.
  }
}

/// The child shares its location on this phone (Standort → "Standort
/// teilen").
Future<void> shareOnPhone(WidgetTester tester) async {
  await section(tester, de.sectionLocation);
  await tap(tester, find.text(de.locationShareLocation));
  await waitFor(
    tester,
    find.text(de.locationYouShareLocation),
    timeout: const Duration(seconds: 60),
  );
}

void main() {
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // --- what lies readable in the app's preferences -------------------------

  // Was a Befund (#607, #519): the rows of "Famio heute" (a sleeping child
  // among them) and the own push's server access lay in plain text in
  // Famio's preferences, the rows even without a widget.
  androidTest('#607 #519 the widget\'s rows and the own push\'s token are '
      'not readable on the phone', (tester) async {
    await hostOk('grant');
    Future<String> plain(String text) async =>
        (await hostOk('prefs-grep ${b64(text)}')).split('|').first;
    // As Famio 2.0.62 left them, through home_widget.
    await HomeWidget.saveWidgetData<String>('date', 'E2E Alter Tag');
    await HomeWidget.saveWidgetData<String>('text0', 'E2E Alter Klartext');
    expect(await plain('E2E Alter Klartext'), 'HomeWidgetPreferences.xml');
    final state = await startApp(tester);
    final engine = state.engine!;
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
      final child = Child(
        id: uid('child'),
        name: 'E2E Schlafkind',
        birthDate: DateTime(now.year - 1, 4, 4),
        guardianIds: [state.me!.id],
      );
      engine.saveChild(child);
      engine.saveChildLog(
        ChildLog(
          id: uid('log'),
          childId: child.id,
          kind: LogKind.sleep,
          start: now.subtract(const Duration(minutes: 25)),
        ),
      );
      await idle(tester, const Duration(seconds: 6));
      if (!await HomeWidgetSync.placed()) {
        final (date, rows) = await HomeWidgetSync.stored();
        note('#607 without a widget: $date $rows');
        expect(date, isNull, reason: 'nothing is kept without a widget');
      }
      expect(await plain('E2E Alter Klartext'), isEmpty);

      await placeTodayWidget();
      final rows = await untilAsync(tester, 'the widget filled', () async {
        final w = await todayWidget();
        return w.any((t) => (t ?? '').contains('E2E Schlafkind')) ? w : null;
      });
      note('#607 widget: $rows');
      final onHome = await hostOk('home-text ${b64('E2E Schlafkind')} 10');
      note('#607 on the home screen: "$onHome"');
      expect(onHome, contains('E2E Schlafkind'));
      await hostOk('front');
      await idle(tester, const Duration(seconds: 2));
      final files = await hostOk('prefs-grep ${b64('E2E Schlafkind')}');
      note('#607 plain text in shared_prefs: "$files"');
      // Not the widget's: the notification plugin keeps planned reminders
      // ("U6 für …") readable to plan them again after a restart (#609).
      expect(
        files.split('|').first.split(',').where((f) => f.isNotEmpty),
        everyElement('scheduled_notifications.xml'),
      );

      // #519: the own push's token, as the service uses it.
      await ownPush(tester, state);
      final token = await const MethodChannel(
        'famio/notify',
      ).invokeMethod<String>('token');
      expect(token, isNotEmpty);
      expect(await plain(token!), isEmpty);
      expect(
        await const MethodChannel(
          'famio/notify',
        ).invokeMapMethod<String, Object?>('status'),
        containsPair('enabled', true),
      );
    } finally {
      await state.ownPush?.setEnabled(false);
      await finish(tester, state);
    }
  });

  // --- the own push: what tapping its notifications opens ------------------

  androidTest('GRU-175 ALL-220 a task assigned by Bea: tapped in the '
      'background it opens, deleted only the tasks', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final state = await startApp(tester);
    final me = state.me!.id;
    final ids = <String>[];
    try {
      await ownPush(tester, state);
      await clearShown();
      // GRU-175: Bea gives me a task; Famio in the background, tapped.
      final id = uid('task');
      ids.add(id);
      await seed(bea, Collections.tasks, {
        id: Task(id: id, title: 'E2E Push Fahrrad', assigneeIds: [me]).toData(),
      });
      final n = await tapNotice(
        tester,
        'GRU-175 new task',
        'E2E Push Fahrrad',
        away: true,
      );
      expect(n.title, 'Neue Aufgabe für dich');
      await waitUi(
        tester,
        find.widgetWithText(TextField, 'E2E Push Fahrrad'),
        timeout: const Duration(seconds: 40),
      );
      await resetPages(tester);
      expect(find.byType(TasksScreen), findsOneWidget, reason: 'Aufgaben');

      // ALL-220: deleted meanwhile, only "Aufgaben" opens.
      await section(tester, de.sectionHome);
      await clearShown();
      final gone = uid('task');
      ids.add(gone);
      await seed(bea, Collections.tasks, {
        gone: Task(id: gone, title: 'E2E Push Weg', assigneeIds: [me]).toData(),
      });
      await notification(
        tester,
        'ALL-220 task to be deleted',
        (n) => (n.body ?? '').contains('E2E Push Weg'),
      );
      await remove(bea, Collections.tasks, [gone]);
      await state.engine!.sync();
      await until(
        tester,
        () => state.engine!.tasks.every((t) => t.id != gone),
        'the task gone on this phone',
      );
      await hostOk('home');
      await Future<void>.delayed(const Duration(seconds: 2));
      await hostOk('tap-notification ${b64('E2E Push Weg')} 30');
      await opens(tester, TasksScreen);
      await idle(tester, const Duration(seconds: 3));
      expect(find.widgetWithText(TextField, 'E2E Push Weg'), findsNothing);
      note('ALL-220 deleted task: only "Aufgaben" opened');
    } finally {
      await remove(bea, Collections.tasks, ids);
      await state.ownPush?.setEnabled(false);
      await finish(tester, state);
    }
  });

  androidTest('ALL-220 a task of the admin tapped by the guest opens to '
      'read', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final id = uid('task');
    final state = await startApp(tester, user: 'e2e-gast');
    try {
      await ownPush(tester, state);
      await clearShown();
      await seed(f.admin, Collections.tasks, {
        id: Task(
          id: id,
          title: 'E2E Gast Hund füttern',
          assigneeIds: [f.guest.id],
        ).toData(),
      });
      await tapNotice(
        tester,
        'ALL-220 guest',
        'E2E Gast Hund füttern',
        away: true,
      );
      await waitUi(
        tester,
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('E2E Gast Hund füttern'),
        ),
      );
      await idle(tester, const Duration(seconds: 2));
      // The reading view: no field to change the title.
      expect(
        find.widgetWithText(TextField, 'E2E Gast Hund füttern'),
        findsNothing,
      );
      expect(fieldWith('E2E Gast Hund füttern'), findsNothing);
    } finally {
      await remove(f.admin, Collections.tasks, [id]);
      await state.ownPush?.setEnabled(false);
      await finish(tester, state);
    }
  });

  androidTest('ALL-220 KAL-198 KIN-165 with the app lock the task opens '
      'only after unlocking', (tester) async {
    lifecycleForLock(tester);
    await hostOk('grant');
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    await hostOk('pin-set');
    await Future<void>.delayed(const Duration(seconds: 2));
    final state = await startApp(tester);
    final id = uid('task');
    try {
      await ownPush(tester, state);
      await clearShown();
      // The lock on, at once (as the settings leave it after the device's
      // question, which the GRU-110 test answers).
      await state.lock.setDelay(Duration.zero);
      await _lockPrefs(true);
      expect(state.lock.enabled, isTrue);
      await seed(bea, Collections.tasks, {
        id: Task(
          id: id,
          title: 'E2E Gesperrt Muell',
          assigneeIds: [state.me!.id],
        ).toData(),
      });
      await tapNotice(
        tester,
        'with the lock',
        'E2E Gesperrt Muell',
        away: true,
      );
      await until(tester, () => state.lock.locked, 'locked when back');
      // Android asks for the PIN by itself; meanwhile nothing opens.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(
        find.widgetWithText(TextField, 'E2E Gesperrt Muell').hitTestable(),
        findsNothing,
      );
      for (var i = 0; i < 3 && state.lock.locked; i++) {
        await hostOk('pin-enter');
        final watch = Stopwatch()..start();
        while (state.lock.locked &&
            watch.elapsed < const Duration(seconds: 10)) {
          await idle(tester, const Duration(milliseconds: 300));
        }
        if (state.lock.locked) {
          await tap(tester, find.text(de.appLockUnlock));
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      expect(state.lock.locked, isFalse);
      await waitUi(
        tester,
        find.widgetWithText(TextField, 'E2E Gesperrt Muell'),
        timeout: const Duration(seconds: 30),
      );
      note('ALL-220 with the lock: opened after unlocking');
    } finally {
      await _lockPrefs(false);
      state.lock.signedOut();
      await host('pin-clear');
      await remove(bea, Collections.tasks, [id]);
      await state.ownPush?.setEnabled(false);
      await finish(tester, state);
    }
  });

  androidTest('ALL-233 GRU-177 ALL-234 a direct message, a new sign-in, a '
      'request to confirm', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final kid = await sessionOf(f.kid);
    final state = await startApp(tester);
    final me = state.me!.id;
    final points = <String>[];
    try {
      await ownPush(tester, state);
      // ALL-233 / GRU-177 1: Bea writes me directly.
      await clearShown();
      final dm = ChatIds.direct(f.bea.id, me);
      final message = uid('chat');
      await seed(bea, Collections.chatMessages, {
        message: {
          ...ChatMessage(
            id: message,
            chatId: dm,
            authorId: f.bea.id,
            sentAt: DateTime.now().toUtc(),
            text: 'E2E Direkt von Bea',
          ).toData(),
          SyncRecord.visibilityKey: [f.bea.id, me],
        },
      });
      final n = await tapNotice(
        tester,
        'ALL-233 direct message',
        'E2E Direkt von Bea',
        away: true,
      );
      expect(n.title, 'E2E Bea');
      await opens(tester, ChatScreen);
      final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(chat.chatId, dm);
      expect(chat.title, 'E2E Bea');
      await resetPages(tester);

      // ALL-233: a chat of Bea and Carl does not open for me.
      await section(tester, de.sectionHome);
      final theirs = ChatIds.direct(f.bea.id, f.carl.id);
      await hostOk('view-link ${b64(NoticeTarget.chat(theirs).link)}');
      await idle(tester, const Duration(seconds: 5));
      expect(find.byType(ChatScreen), findsNothing);
      note('ALL-233 chat of others: no chat page');
      await resetPages(tester);

      // GRU-177 2: a new sign-in of my account elsewhere.
      await section(tester, de.sectionHome);
      await clearShown();
      final other = await kitAdminApi();
      await tapNotice(
        tester,
        'GRU-177 new sign-in',
        'Neue Anmeldung bei Famio',
        away: true,
      );
      await opens(tester, MyDevicesScreen);
      await other.logout();
      await resetPages(tester);

      // GRU-177 4, ALL-234 1: the child asks for points.
      await section(tester, de.sectionHome);
      await clearShown();
      final ask = uid('points');
      points.add(ask);
      await seed(kid, Collections.pointEntries, {
        ask: PointEntry(
          id: ask,
          memberId: f.kid.id,
          points: 5,
          title: 'E2E Zimmer aufgeraeumt',
          kind: PointKind.chore,
          at: DateTime.now(),
          status: PointStatus.pending,
        ).toData(),
      });
      final confirm = await tapNotice(
        tester,
        'ALL-234 please confirm',
        'E2E Zimmer aufgeraeumt',
        away: true,
      );
      expect(confirm.title, 'Bitte bestätigen');
      await opens(tester, ChoresScreen);
      await waitUi(tester, find.text(de.choresChoresPoints));
    } finally {
      await remove(f.admin, Collections.pointEntries, points);
      await state.ownPush?.setEnabled(false);
      await finish(tester, state);
    }
  });

  androidTest('ALL-234 GRU-177 with "Ämter" switched off no chores open', (
    tester,
  ) async {
    await hostOk('grant');
    final f = await theFamily();
    final kid = await sessionOf(f.kid);
    await f.admin.updateServerSettings({
      'hiddenModules': [FamioSection.chores.name],
    });
    final state = await startApp(tester);
    final ask = uid('points');
    try {
      await until(
        tester,
        () => state.hiddenModules.contains(FamioSection.chores.name),
        'Ämter switched off here',
      );
      await ownPush(tester, state);
      await clearShown();
      await seed(kid, Collections.pointEntries, {
        ask: PointEntry(
          id: ask,
          memberId: f.kid.id,
          points: 3,
          title: 'E2E Ausgeblendet Spuelen',
          kind: PointKind.chore,
          at: DateTime.now(),
          status: PointStatus.pending,
        ).toData(),
      });
      await tapNotice(
        tester,
        'ALL-234 hidden chores',
        'E2E Ausgeblendet Spuelen',
        away: true,
      );
      await idle(tester, const Duration(seconds: 6));
      expect(find.byType(ChoresScreen), findsNothing);
      expect(find.text(de.choresChoresPoints), findsNothing);
      note('ALL-234 hidden: no chores section opened');
    } finally {
      await f.admin.updateServerSettings({'hiddenModules': null});
      await remove(f.admin, Collections.pointEntries, [ask]);
      await state.ownPush?.setEnabled(false);
      await finish(tester, state);
    }
  });

  androidTest('SIC-183 SOS, "kommt", a check-in and a place notice open '
      'the alarm and "Standort"', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    await quietSos(f);
    await resolveAll(f.admin);
    final kid = await sessionOf(f.kid);
    final bea = await sessionOf(f.bea);
    final state = await startApp(tester);
    final me = state.me!.id;
    final placeId = uid('place');
    FamioApiClient? watch;
    try {
      await ownPush(tester, state);
      // From another section (Einkauf), the alarm opens over everything.
      await section(tester, de.sectionShopping);
      await clearShown();
      final alarm = await kid.raiseSos(
        latitude: _home.$1,
        longitude: _home.$2,
        accuracy: 15,
      );
      await tapNotice(tester, 'SIC-183 SOS', 'SOS von E2E Kind');
      await opens(tester, SosAlertScreen);
      expect(
        tester.widget<SosAlertScreen>(find.byType(SosAlertScreen)).alertId,
        alarm,
      );
      await resetPages(tester);

      // "<B> kommt".
      await section(tester, de.sectionShopping);
      await clearShown();
      await bea.sosComing(alarm);
      await tapNotice(tester, 'SIC-183 coming', 'E2E Bea kommt');
      await opens(tester, SosAlertScreen);
      await resetPages(tester);
      await resolveAll(f.admin);

      // A check-in: "Standort".
      await section(tester, de.sectionShopping);
      await clearShown();
      await kid.checkIn(
        'E2E bin beim Training',
        latitude: _school.$1,
        longitude: _school.$2,
      );
      await tapNotice(tester, 'SIC-183 check-in', 'E2E bin beim Training');
      await opens(tester, LocationScreen);
      await resetPages(tester);

      // A place notice (arriving at a family place): "Standort".
      await seed(f.admin, Collections.places, {
        placeId: Place(
          id: placeId,
          name: 'E2E Spielplatz',
          latitude: _home.$1,
          longitude: _home.$2,
          radius: 150,
          notifyMemberIds: [me],
        ).toData(),
      });
      await section(tester, de.sectionShopping);
      await clearShown();
      watch = await locationDevice(kid, 'E2E Uhr');
      await watch.reportLocation([fixAt(_school)], device: 'E2E Uhr');
      await Future<void>.delayed(const Duration(seconds: 2));
      await watch.reportLocation([fixAt(_home)], device: 'E2E Uhr');
      await tapNotice(tester, 'SIC-183 place', 'E2E Spielplatz');
      await opens(tester, LocationScreen);
    } finally {
      await resolveAll(f.admin);
      await remove(f.admin, Collections.places, [placeId]);
      await watch?.logout();
      await state.ownPush?.setEnabled(false);
      await finish(tester, state);
    }
  });

  // --- reminders on real time ------------------------------------------------

  androidTest('KAL-198 GRU-176 KIN-165 KIN-166 GRU-177 a later appointment of '
      'a series, a lift, a meal and a dose tapped', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final state = await startApp(tester);
    final engine = state.engine!;
    final me = state.me!.id;
    try {
      await clean(engine, {
        Collections.events,
        Collections.children,
        Collections.childLogs,
        Collections.medications,
        Collections.tasks,
      });
      await clearShown();

      // KAL-198 / GRU-176 1: a weekly series begun last week, its second
      // appointment today, reminded 15 minutes before.
      var at = minuteAfter(const Duration(seconds: 70));
      if (!DateUtils.isSameDay(at.add(const Duration(minutes: 40)), at)) {
        markTestSkipped('too close to midnight');
        return;
      }
      final firstStart = at
          .add(const Duration(minutes: 15))
          .subtract(const Duration(days: 7));
      final series = CalendarEvent(
        id: uid('ev'),
        title: 'E2E Serie Chor',
        start: firstStart,
        end: firstStart.add(const Duration(hours: 1)),
        memberIds: [me],
        reminderMinutes: 15,
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
      );
      engine.saveEvent(series);
      await engine.sync();
      await tapNotice(tester, 'KAL-198 series', 'E2E Serie Chor');
      await waitUi(tester, find.widgetWithText(TextField, 'E2E Serie Chor'));
      await resetPages(tester);
      await calendarOn(tester, at);
      note('KAL-198 the series opened on ${DateUtils.dateOnly(at)}');

      // KAL-198 2: "🚗 Bringen: …", 30 minutes before.
      await section(tester, de.sectionHome);
      await clearShown();
      at = minuteAfter(const Duration(seconds: 70));
      final lift = CalendarEvent(
        id: uid('ev'),
        title: 'E2E Bringen Turnen',
        start: at.add(const Duration(minutes: 30)),
        end: at.add(const Duration(minutes: 90)),
        memberIds: [f.kid.id],
        bringerId: me,
      );
      engine.saveEvent(lift);
      await engine.sync();
      final liftNote = await tapNotice(
        tester,
        'KAL-198 lift',
        'E2E Bringen Turnen',
      );
      expect(liftNote.title, startsWith('🚗'));
      await waitUi(
        tester,
        find.widgetWithText(TextField, 'E2E Bringen Turnen'),
      );
      await resetPages(tester);
      await calendarOn(tester, at);

      // KIN-165: "Erinnerung an die nächste Mahlzeit" opens the child.
      await section(tester, de.sectionHome);
      await clearShown();
      at = minuteAfter(const Duration(seconds: 70));
      final child = Child(
        id: uid('child'),
        name: 'E2E Lotta',
        birthDate: DateUtils.addDaysToDate(DateTime.now(), -120),
        guardianIds: [me],
      );
      engine.saveChild(child);
      engine.saveChildLog(
        ChildLog(
          id: uid('log'),
          childId: child.id,
          kind: LogKind.bottle,
          start: DateTime.now().subtract(const Duration(hours: 2)),
          amountMl: 120,
          remindAt: at,
        ),
      );
      await engine.sync();
      await tapNotice(
        tester,
        'KIN-165 next meal',
        de.remindersNextMealName('E2E Lotta'),
      );
      await opens(tester, ChildScreen);
      expect(
        tester.widget<ChildScreen>(find.byType(ChildScreen)).childId,
        child.id,
      );
      await resetPages(tester);

      // KIN-165: the child gone meanwhile: only "Kinder".
      await section(tester, de.sectionHome);
      await clearShown();
      at = minuteAfter(const Duration(seconds: 70));
      final gone = Child(
        id: uid('child'),
        name: 'E2E Weg Kind',
        birthDate: DateUtils.addDaysToDate(DateTime.now(), -200),
        guardianIds: [me],
      );
      engine.saveChild(gone);
      engine.saveChildLog(
        ChildLog(
          id: uid('log'),
          childId: gone.id,
          kind: LogKind.bottle,
          start: DateTime.now().subtract(const Duration(hours: 2)),
          amountMl: 90,
          remindAt: at,
        ),
      );
      await engine.sync();
      await notification(
        tester,
        'KIN-165 meal of a child to be removed',
        (n) => n.title == de.remindersNextMealName('E2E Weg Kind'),
      );
      engine.delete(Collections.children, gone.id);
      await engine.sync();
      await hostOk(
        'tap-notification ${b64(de.remindersNextMealName('E2E Weg Kind'))} 30',
      );
      await opens(tester, KidsScreen);
      await idle(tester, const Duration(seconds: 3));
      expect(find.byType(ChildScreen), findsNothing);
      note('KIN-165 removed child: only "Kinder"');
      await resetPages(tester);

      // KIN-166 2, GRU-177 5: a dose opens "Medizin".
      await section(tester, de.sectionHome);
      await clearShown();
      at = minuteAfter(const Duration(seconds: 70));
      engine.saveMedication(
        Medication(
          id: uid('med'),
          name: 'E2E Fiebersaft',
          personName: 'E2E Lotta',
          dose: '5 ml',
          times: [DateFormat.Hm('de').format(at)],
          start: DateUtils.dateOnly(at),
        ),
      );
      await engine.sync();
      await tapNotice(tester, 'KIN-166 dose', 'E2E Fiebersaft');
      await opens(tester, MedicationScreen);
    } finally {
      await finish(tester, state);
    }
  });

  androidTest('KAL-203 a shown reminder stays when Famio plans again, a '
      'dismissed one does not come back', (tester) async {
    await hostOk('grant');
    final state = await startApp(tester);
    final engine = state.engine!;
    try {
      await clean(engine, {Collections.events});
      await clearShown();
      final at = minuteAfter(const Duration(seconds: 60));
      engine.saveEvent(
        CalendarEvent(
          id: uid('ev'),
          title: 'E2E Bleibt stehen',
          start: at.add(const Duration(minutes: 15)),
          end: at.add(const Duration(minutes: 45)),
          memberIds: [state.me!.id],
          reminderMinutes: 15,
        ),
      );
      await engine.sync();
      bool ours(ActiveNotification n) => n.title == 'E2E Bleibt stehen';
      final n = await notification(tester, 'the reminder', ours);
      // Another appointment: Famio plans again.
      engine.saveEvent(
        CalendarEvent(
          id: uid('ev'),
          title: 'E2E Anderer Termin',
          start: DateTime.now().add(const Duration(days: 2)),
          end: DateTime.now().add(const Duration(days: 2, hours: 1)),
        ),
      );
      await engine.sync();
      await idle(tester, const Duration(seconds: 4));
      state.remindersChanged();
      await idle(tester, const Duration(seconds: 4));
      expect((await shown()).where(ours), isNotEmpty, reason: 'still shown');
      // Dismissed, then planned again: it stays away.
      await _plugin.cancel(id: n.id!, tag: n.tag);
      await idle(tester, const Duration(seconds: 2));
      state.remindersChanged();
      await idle(tester, const Duration(seconds: 6));
      final after = await shown();
      note('KAL-203 after dismissing and planning: ${describe(after)}');
      expect(after.where(ours), isEmpty);
    } finally {
      await finish(tester, state);
    }
  });

  // --- famio:// links ----------------------------------------------------------

  androidTest('GRU-181 famio:// links: a task, a date far off, an unknown '
      'kind', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final state = await startApp(tester);
    final id = uid('task');
    try {
      await seed(f.admin, Collections.tasks, {
        id: Task(
          id: id,
          title: 'E2E Link Garten',
          assigneeIds: [state.me!.id],
        ).toData(),
      });
      await until(
        tester,
        () => state.engine!.tasks.any((t) => t.id == id),
        'the task here',
      );
      await hostOk('view-link ${b64('famio://open?target=task:$id')}');
      await waitUi(tester, find.widgetWithText(TextField, 'E2E Link Garten'));
      await resetPages(tester);
      for (final link in [
        'famio://open?target=day:@+275760-09-13T00:00:00.000Z',
        'famio://open?target=foo:1',
      ]) {
        await hostOk('view-link ${b64(link)}');
        await idle(tester, const Duration(seconds: 5));
        expect(tester.takeException(), isNull, reason: link);
        final focus = await hostOk('focus');
        expect(focus, contains('famio'), reason: '$link: Famio in front');
        expect(find.textContaining('275760'), findsNothing);
        expect(state.me, isNotNull);
        note('GRU-181 $link: $focus');
        await resetPages(tester);
      }
    } finally {
      await remove(f.admin, Collections.tasks, [id]);
      await finish(tester, state);
    }
  });

  // --- "Teilen an Famio": which targets, in which order ----------------------

  androidTest('GRU-085 HAU-023 ALL-132 recipe links first, other links after '
      'the inbox, no recipe for files', (tester) async {
    await hostOk('grant');
    final state = await startApp(tester);
    try {
      Future<void> share(String text) async {
        await snackGone(tester);
        await hostOk('text-share ${b64(text)}');
        await waitFor(
          tester,
          find.text(de.shareTitle),
          timeout: const Duration(minutes: 1),
        );
      }

      double y(String label) => tester.getTopLeft(find.text(label)).dy;
      for (final (link, first) in [
        ('https://www.chefkoch.de/rezepte/1234/Carbonara.html', true),
        ('https://example.org/meine-rezepte/apfelkuchen', true),
        ('https://example.org/blog/neuigkeiten', false),
      ]) {
        await share('E2E Link $link');
        final recipe = y(de.shareAsRecipe);
        final inbox = y(de.shareToInbox);
        note('HAU-023 $link: recipe $recipe, inbox $inbox');
        expect(recipe < inbox, first, reason: link);
        if (first) {
          // Above everything else, too.
          for (final other in [
            de.shareToShopping,
            de.shareAsTask,
            de.shareAsNote,
          ]) {
            expect(recipe, lessThan(y(other)), reason: '$link / $other');
          }
        }
        await tester.tapAt(const Offset(200, 60));
        await idle(tester, const Duration(seconds: 1));
      }
      // HAU-023: a file is no recipe.
      await snackGone(tester);
      await hostOk('share photo');
      await waitFor(
        tester,
        find.text(de.shareTitle),
        timeout: const Duration(minutes: 1),
      );
      expect(find.text(de.shareAsRecipe), findsNothing);
      expect(find.text(de.shareAsDocument), findsOneWidget);
      await tester.tapAt(const Offset(200, 60));
    } finally {
      await finish(tester, state);
    }
  });

  androidTest('HAU-023 ALL-132 GRU-088 areas switched off are no target; '
      'the guest may still use the shopping list', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    await f.admin.updateServerSettings({
      'hiddenModules': [FamioSection.meals.name, FamioSection.shopping.name],
    });
    var state = await startApp(tester);
    try {
      await hostOk(
        'text-share ${b64('E2E Aus\nhttps://www.chefkoch.de/rezepte/9/x.html')}',
      );
      await waitFor(
        tester,
        find.text(de.shareTitle),
        timeout: const Duration(minutes: 1),
      );
      expect(find.text(de.shareAsRecipe), findsNothing, reason: 'Essen off');
      expect(
        find.text(de.shareToShopping),
        findsNothing,
        reason: 'Einkauf off',
      );
      expect(find.text(de.shareToInbox), findsOneWidget);
      await tester.tapAt(const Offset(200, 60));
      await finish(tester, state);
      await f.admin.updateServerSettings({'hiddenModules': null});

      // GRU-088: the guest, all areas on.
      state = await startApp(tester, user: 'e2e-gast');
      await hostOk(
        'text-share ${b64('- E2E Gast Milch\nhttps://www.chefkoch.de/rezepte/9/x.html')}',
      );
      await waitFor(
        tester,
        find.text(de.shareTitle),
        timeout: const Duration(minutes: 1),
      );
      for (final missing in [
        de.shareToInbox,
        de.shareAsRecipe,
        de.shareAsNote,
        de.shareAsDocument,
      ]) {
        expect(find.text(missing), findsNothing, reason: missing);
      }
      for (final offered in [
        de.shareAsTask,
        de.shareToShopping,
        de.shareToChat,
      ]) {
        expect(find.text(offered), findsOneWidget, reason: offered);
      }
      await tester.tapAt(const Offset(200, 60));
    } finally {
      await f.admin.updateServerSettings({'hiddenModules': null});
      await finish(tester, state);
    }
  });

  // --- location: the schedule on the server, signing out on the phone -------

  androidTest('SIC-053 the schedule ends: the family sees it within a minute '
      'although the phone says nothing', (tester) async {
    final f = await theFamily();
    final kid = await sessionOf(f.kid);
    await f.admin.setLocationCode('2468');
    final now = DateTime.now();
    final minute = now.hour * 60 + now.minute;
    if (minute < 60 || minute > 24 * 60 - 4) {
      markTestSkipped('too close to midnight for a window today');
      return;
    }
    // The family's zone is Europe/Berlin (an hour ahead of UTC in
    // November); the emulator's must be the same for the minutes below.
    note('SIC-053 emulator zone: ${now.timeZoneName} ${now.timeZoneOffset}');
    if (now.timeZoneOffset != const Duration(hours: 1)) {
      markTestSkipped('the emulator is not on Berlin time');
      return;
    }
    final watch = await locationDevice(kid, 'E2E Uhr');
    try {
      await watch.reportLocation([
        fixAt(_home, battery: 80),
      ], device: 'E2E Uhr');
      final end = minute + 2;
      await f.admin.setLocationSchedule(
        code: '2468',
        memberId: f.kid.id,
        schedule: LocationSchedule(
          weekdays: [now.weekday],
          startMinute: minute - 60,
          endMinute: end,
        ),
      );
      final before = await locationOf(f.admin, f.kid.id);
      expect(before?.state, SharingState.active);
      expect(before?.hasPosition, isTrue);
      final endsAt = DateTime(
        now.year,
        now.month,
        now.day,
      ).add(Duration(minutes: end));
      // Nothing from the phone from now on.
      final off = await untilAsync(
        tester,
        'off by schedule',
        () async => switch (await locationOf(f.admin, f.kid.id)) {
          final l? when l.state == SharingState.scheduled => l,
          _ => null,
        },
        timeout: const Duration(minutes: 4),
      );
      final late = DateTime.now().difference(endsAt);
      note('SIC-053 off ${late.inSeconds} s after the window ended');
      expect(late, lessThan(const Duration(seconds: 75)));
      expect(off.hasPosition, isFalse);
      expect(off.placeId, isNull);
      expect(off.battery, isNull);
      expect(sharingLabel(off, null), de.locationLocationSharingOffRight);
    } finally {
      await f.admin.setLocationSchedule(code: '2468', memberId: f.kid.id);
      await f.admin.setLocationCode(null);
      await watch.logout();
    }
  });

  androidTest('SIC-052 GRU-050 SIC-185 a waiting change and the parents\' '
      'code before signing out; afterwards no position; a computer\'s '
      'sign-out changes nothing', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final admin = f.admin;
    final kidId = f.kid.id;
    await admin.setLocationCode('2468');
    await _resume(admin, kidId);
    await hostOk('geo-long ${_school.$1} ${_school.$2} 600');
    final state = await startApp(tester, user: 'e2e-kind');
    try {
      await shareOnPhone(tester);
      await untilAsync(
        tester,
        'the family sees the phone',
        () async => (await locationOf(admin, kidId))?.hasPosition == true,
        timeout: const Duration(minutes: 2),
      );

      // SIC-185 4: signing out on a computer changes nothing.
      final laptop = FamioApiClient(kitUrl);
      await laptop.login(
        username: 'e2e-kind',
        password: kitMemberPassword,
        device: 'E2E Laptop',
      );
      await laptop.logout();
      await Future<void>.delayed(const Duration(seconds: 3));
      final still = await locationOf(admin, kidId);
      expect(still?.state, SharingState.active);
      expect(still?.hasPosition, isTrue);

      // SIC-052 / GRU-050: a change the server holds back (a file nobody
      // has) waits; signing out asks about it first.
      final engine = state.engine!;
      engine.saveTask(
        Task(
          id: uid('task'),
          title: 'E2E Wartet noch',
          photos: const [
            FileRef(
              id: 'e2e-no-such-file',
              name: 'weg.jpg',
              mime: 'image/jpeg',
              size: 10,
            ),
          ],
        ),
      );
      await engine.sync();
      await idle(tester, const Duration(seconds: 2));
      expect(engine.store.dirty, isNotEmpty, reason: 'held back');
      await tapSignOut(tester);
      await waitFor(tester, find.text(de.signOutUnsentTitle));
      expect(find.text(de.signOutUnsentBody(1)), findsOneWidget);
      await tap(tester, _dialogText(de.commonCancel));
      await dialogClosed(tester);
      expect(state.me, isNotNull);
      // Then the parents' code; cancelled, the child stays and shares.
      await tap(tester, find.text(de.settingsSignOut));
      await waitFor(tester, find.text(de.signOutUnsentTitle));
      await tap(tester, _dialogText(de.signOutAnyway));
      await waitFor(tester, find.text(de.locationEndLocationSharing));
      await tap(tester, _dialogText(de.commonCancel));
      await dialogClosed(tester);
      expect(state.me, isNotNull);
      expect((await LocationSharing.status()).enabled, isTrue);
      // With the code: signed out, sharing ends on this phone.
      await signOutWithCode(tester, state, '2468');
      expect((await LocationSharing.status()).enabled, isFalse);
      final after = await untilAsync(
        tester,
        'no position after signing out',
        () async => switch (await locationOf(admin, kidId)) {
          null => 'none',
          final l when !l.hasPosition => '${l.state} ${l.pausedUntil}',
          _ => null,
        },
      );
      note('SIC-052 SIC-185 the family sees after signing out: $after');
    } finally {
      await _resume(admin, kidId);
      await admin.setLocationCode(null);
      await finish(tester, state);
    }
  });

  androidTest('SIC-185 the other phone of the child goes on sharing after '
      'signing out on one', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final admin = f.admin;
    final kid = await sessionOf(f.kid);
    final kidId = f.kid.id;
    await admin.setLocationCode('2468');
    await _resume(admin, kidId);
    await hostOk('geo-long ${_school.$1} ${_school.$2} 600');
    // The child's tablet shares too, switched on before the phone.
    final tablet = await locationDevice(kid, 'E2E Tablet');
    await tablet.reportLocation([fixAt(_home)], device: 'E2E Tablet');
    final state = await startApp(tester, user: 'e2e-kind');
    try {
      await shareOnPhone(tester);
      final phone = await untilAsync(
        tester,
        'the family sees the phone',
        () async => switch (await locationOf(admin, kidId)) {
          final l?
              when l.hasPosition &&
                  l.device != 'E2E Tablet' &&
                  (l.latitude! - _school.$1).abs() < 0.01 =>
            l,
          _ => null,
        },
        timeout: const Duration(minutes: 2),
      );
      note('SIC-185 phone ${phone.device}, other ${phone.otherDevice}');
      expect(phone.otherDevice, 'E2E Tablet');
      await signOutWithCode(tester, state, '2468');
      final after = await untilAsync(
        tester,
        'the phone no longer counts',
        () async => switch (await locationOf(admin, kidId)) {
          final l? when l.otherDevice == null => l,
          _ => null,
        },
      );
      note(
        'SIC-185 after signing out on the phone: ${after.state} '
        'until ${after.pausedUntil}',
      );
      expect(after.state, SharingState.active);
      await tablet.reportLocation([fixAt(_home)], device: 'E2E Tablet');
      final tab = await locationOf(admin, kidId);
      note('SIC-185 the tablet: ${tab?.state} ${tab?.device} ${tab?.latitude}');
      expect(tab?.device, 'E2E Tablet');
      expect(tab?.hasPosition, isTrue);
    } finally {
      await tablet.logout();
      await _resume(admin, kidId);
      await admin.setLocationCode(null);
      await finish(tester, state);
    }
  });

  androidTest('SIC-185 a pause running stays when the child signs out on the '
      'phone', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    final admin = f.admin;
    final kidId = f.kid.id;
    await admin.setLocationCode('2468');
    await _resume(admin, kidId);
    await hostOk('geo-long ${_school.$1} ${_school.$2} 600');
    final state = await startApp(tester, user: 'e2e-kind');
    try {
      await shareOnPhone(tester);
      await untilAsync(
        tester,
        'the family sees the phone',
        () async => (await locationOf(admin, kidId))?.hasPosition == true,
        timeout: const Duration(minutes: 2),
      );
      await admin.pauseLocation(
        code: '2468',
        memberId: kidId,
        duration: const Duration(hours: 1),
      );
      await state.engine!.sync();
      await idle(tester, const Duration(seconds: 3));
      await signOutWithCode(tester, state, '2468');
      await Future<void>.delayed(const Duration(seconds: 3));
      final paused = await locationOf(admin, kidId);
      note(
        'SIC-185 paused, signed out: ${paused?.state} until '
        '${paused?.pausedUntil}',
      );
      expect(paused?.state, SharingState.paused);
      expect(paused?.hasPosition ?? false, isFalse);
    } finally {
      await _resume(admin, kidId);
      await admin.setLocationCode(null);
      await finish(tester, state);
    }
  });

  // --- the emergency ---------------------------------------------------------

  androidTest('SIC-193 an alarm ended at once: no crash, no service, no '
      'notice left', (tester) async {
    await hostOk('grant');
    final f = await theFamily();
    await quietSos(f);
    await resolveAll(f.admin);
    final state = await startApp(tester, user: 'e2e-kind');
    try {
      // The widget's intent with the secret (the quick settings tile is not
      // driven reliably on this emulator, #585).
      await hostOk('sos widget');
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
      await tap(tester, find.text(de.sosIAmSafeEnd));
      await untilAsync(
        tester,
        'alarm over',
        () async => await openAlertOf(f.admin, f.kid.id) == null,
      );
      // The time the service would have needed to start.
      await idle(tester, const Duration(seconds: 12));
      final focus = await hostOk('focus');
      final services = await hostOk('services');
      final left = (await shown())
          .where(
            (n) =>
                n.channelId != 'famio_connection' &&
                RegExp('Notruf|SOS|Alarm').hasMatch('${n.title} ${n.body}'),
          )
          .toList();
      note(
        'SIC-193 focus $focus; services "$services"; notices '
        '${describe(left)}',
      );
      expect(focus, contains('famio'));
      expect(services, isNot(contains('SosLocationService')));
      expect(left, isEmpty);
    } finally {
      await resolveAll(f.admin);
      await finish(tester, state);
    }
  });

  // --- this device -------------------------------------------------------------

  androidTest('GRU-195 "Erkennung ohne Google Play" on a phone with Play', (
    tester,
  ) async {
    await hostOk('grant');
    final state = await startApp(tester);
    try {
      await section(tester, de.sectionSettings);
      final tile = find.widgetWithText(
        SwitchListTile,
        de.settingsBuiltInModels,
      );
      await phoneScroll(tester, tile);
      await until(
        tester,
        () => state.playServices != null,
        'Play services known',
      );
      note('GRU-195 Play services: ${state.playServices}');
      expect(state.playServices, isTrue);
      // This test build has the recognition built in (FAMIO_OCR_MODELS).
      final sub = find.descendant(of: tile, matching: find.byType(Text));
      final texts = sub
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .whereType<String>()
          .toList();
      note('GRU-195 texts: $texts');
      expect(
        texts.any(
          (t) =>
              t == de.settingsBuiltInModelsBundled ||
              t == de.settingsBuiltInModelsPlay,
        ),
        isTrue,
      );
      expect(tester.widget<SwitchListTile>(tile).onChanged, isNotNull);
      final was = state.builtInModels;
      if (was) await tap(tester, tile);
      await until(tester, () => !state.builtInModels, 'off');
      final small = selfUpdatePlatform;
      await tap(tester, tile);
      await until(tester, () => state.builtInModels, 'on');
      final big = selfUpdatePlatform;
      note('GRU-195 package off: $small, on: $big');
      expect(big, AppPlatform.android);
      expect(small, AppPlatform.androidArm64);
      if (!was) await tap(tester, tile);
    } finally {
      await finish(tester, state);
    }
  });

  // --- reminders at nine and in the evening (the clock moved; last) ----------

  androidTest('KAL-200 HAU-180 HAU-181 ALL-234 GRU-177 KIN-166 the day '
      'overview, a birthday, a deadline, a loan, a subscription, a document, '
      'a pregnancy and the week tapped', (tester) async {
    await hostOk('grant');
    final state = await startApp(tester);
    final engine = state.engine!;
    final me = state.me!.id;
    DateTime on(DateTime d, int h, [int m = 0, int s = 0]) =>
        DateTime(d.year, d.month, d.day, h, m, s);
    DateTime plus(DateTime d, int days) =>
        DateTime(d.year, d.month, d.day + days);
    try {
      await clean(engine, {
        Collections.events,
        Collections.children,
        Collections.childLogs,
        Collections.medications,
        Collections.tasks,
        Collections.deadlines,
        Collections.loans,
        Collections.subscriptions,
        Collections.documents,
        Collections.pregnancies,
        Collections.contacts,
        Collections.wasteSettings,
      });
      await clearShown();
      final now = DateTime.now();
      final today = DateUtils.dateOnly(now);
      if (now.hour >= 23 || now.hour < 1) {
        markTestSkipped('too close to midnight');
        return;
      }
      // KAL-200: the day overview, at a time a minute ahead.
      final at = minuteAfter(const Duration(seconds: 75));
      engine.saveEvent(
        CalendarEvent(
          id: uid('ev'),
          title: 'E2E Heute Abend',
          start: on(today, 23, 30),
          end: on(today, 23, 50),
          memberIds: [me],
        ),
      );
      await engine.sync();
      await state.setDayPreview(at.hour * 60 + at.minute);
      state.remindersChanged();
      await tapNotice(tester, 'KAL-200 day overview', de.dayPreviewTitle);
      await calendarOn(tester, today);
      await state.setDayPreview(null);
      await resetPages(tester);
      await section(tester, de.sectionHome);
      await clearShown();

      // The evening of the birthday reminder, then one day after the other.
      final evening = now.isBefore(on(today, 17, 58)) ? today : plus(today, 1);
      final birthday = plus(evening, 1);
      final d = [for (var i = 1; i <= 5; i++) plus(evening, i)];
      var sunday = plus(d.last, (DateTime.sunday - d.last.weekday) % 7);
      if (!sunday.isAfter(d.last)) sunday = plus(sunday, 7);
      final monday = plus(sunday, 1);

      engine.saveContact(
        FamilyContact(
          id: uid('contact'),
          name: 'E2E Oma Gerda',
          birthday: Birthday(birthday.month, birthday.day, birthday.year - 70),
        ),
      );
      engine.saveDeadline(
        Deadline(
          id: uid('dl'),
          title: 'E2E Frist TUEV',
          due: d[0],
          leadDays: 0,
        ),
      );
      engine.saveLoan(
        Loan(
          id: uid('loan'),
          title: 'E2E Bohrmaschine',
          person: 'E2E Nachbar',
          due: d[1],
        ),
      );
      engine.saveSubscription(
        Subscription(
          id: uid('abo'),
          name: 'E2E Streaming',
          cents: 999,
          start: plus(d[2], 1),
          remindDays: 1,
        ),
      );
      engine.saveDocument(
        FamilyDocument(
          id: uid('doc'),
          title: 'E2E Reisepass',
          category: DocumentCategory.identity,
          file: null,
          expiresAt: plus(d[3], 7),
        ),
      );
      final task = localPregnancyTasks.firstWhere((t) => t.fromWeek >= 4);
      final pregnancy = Pregnancy(
        id: uid('preg'),
        dueDate: DateTime(
          d[4].year,
          d[4].month,
          d[4].day - task.fromWeek * 7 + 280,
        ),
        name: 'E2E Bauch',
      );
      engine.savePregnancy(pregnancy);
      engine.saveEvent(
        CalendarEvent(
          id: uid('ev'),
          title: 'E2E Wochenstart',
          start: on(monday, 10),
          end: on(monday, 11),
          memberIds: [me],
        ),
      );
      await engine.sync();
      await idle(tester, const Duration(seconds: 4));
      state.remindersChanged();
      await idle(tester, const Duration(seconds: 4));

      Future<void> jump(DateTime to) async {
        await clearShown();
        final set = await hostOk('clock ${to.millisecondsSinceEpoch}');
        debugPrint('E2E clock now ${DateTime.now()} ($set)');
      }

      // KAL-200: the evening before the birthday.
      await jump(on(evening, 17, 59, 30));
      await tapNotice(tester, 'KAL-200 birthday', 'E2E Oma Gerda');
      await calendarOn(tester, birthday);
      await resetPages(tester);
      await section(tester, de.sectionHome);

      // ALL-234 2, GRU-177 3: a deadline.
      await jump(on(d[0], 8, 59, 30));
      await tapNotice(tester, 'ALL-234 deadline', 'E2E Frist TUEV');
      await opens(tester, DeadlinesScreen);
      await resetPages(tester);
      await section(tester, de.sectionHome);

      // ALL-234 3: a loan.
      await jump(on(d[1], 8, 59, 30));
      await tapNotice(tester, 'ALL-234 loan', 'E2E Bohrmaschine');
      await opens(tester, LoansScreen);
      await resetPages(tester);
      await section(tester, de.sectionHome);

      // HAU-180: a subscription, the day before it is paid.
      await jump(on(d[2], 8, 59, 30));
      final abo = await tapNotice(
        tester,
        'HAU-180 subscription',
        'E2E Streaming',
      );
      expect(abo.title, de.remindersSubscription('E2E Streaming', 1));
      await opens(tester, SubscriptionsScreen);
      await resetPages(tester);
      await section(tester, de.sectionHome);

      // HAU-181: a document a week before it expires.
      await jump(on(d[3], 8, 59, 30));
      await tapNotice(tester, 'HAU-181 document', 'E2E Reisepass');
      await opens(tester, DocumentsScreen);
      await resetPages(tester);
      await section(tester, de.sectionHome);

      // KIN-166 1: the pregnancy's to-do.
      await jump(on(d[4], 8, 59, 30));
      await tapNotice(tester, 'KIN-166 pregnancy', 'E2E Bauch');
      await opens(tester, PregnancyScreen);
      expect(
        tester
            .widget<PregnancyScreen>(find.byType(PregnancyScreen))
            .pregnancyId,
        pregnancy.id,
      );
      await resetPages(tester);
      await section(tester, de.sectionHome);

      // KAL-200: the week ahead on Sunday evening opens its Monday.
      await jump(on(sunday, 17, 59, 30));
      await tapNotice(tester, 'KAL-200 week', 'Deine Woche');
      await calendarOn(tester, monday);
    } finally {
      await host('clock-reset');
      await state.setDayPreview(null);
      await finish(tester, state);
    }
  });
}
