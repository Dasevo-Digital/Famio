// Shared helpers of the catalog tests (integration_test/catalog_*_test.dart):
// the app against a throwaway server, as tool/integration_tests.sh starts it.
//
//   tool/integration_tests.sh macos integration_test/catalog_<area>_test.dart
//
// Each test starts signed out and signs in through the app's own pages.
// Other members are created through the API; what they get from the server
// is checked with their own API session, what another device writes is
// written through the API.
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:integration_test/integration_test.dart';

import 'fresh_start.dart';

/// The binding of a catalog file. On a Mac in use, a covered test window
/// counts as hidden for macOS, and a hidden app draws no frames: every pump
/// then waits for good (a full-screen window in front was enough). On the
/// Mac the catalog keeps the app resumed for the system; tests that check
/// the lifecycle drive it themselves.
void catalogBinding() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isMacOS) return;
  SystemChannels.lifecycle.setMessageHandler((message) async {
    for (final state in const [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
    ]) {
      if (message == state.toString()) {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(state);
      }
    }
    return null;
  });
  final now = WidgetsBinding.instance.lifecycleState;
  if (now == AppLifecycleState.hidden || now == AppLifecycleState.paused) {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  }
}

const kitUrl = String.fromEnvironment('FAMIO_URL');
const kitUser = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const kitPassword = String.fromEnvironment('FAMIO_PASSWORD');

/// Password of the members the tests create on the throwaway server.
const kitMemberPassword = 'e2e-member-123';

/// The display name of the server's first account (tool/integration_tests.sh).
const kitAdminName = 'Admin';

/// The German texts of the app; the tests read German whatever the device
/// speaks (`deviceLanguage = () => 'de'` in main).
final de = lookupL10n(const Locale('de'));

/// The family next to the admin: two adults, a guest and a child account,
/// created once per test file.
class KitFamily {
  KitFamily(
    this.admin,
    this.adminMember,
    this.bea,
    this.carl,
    this.guest,
    this.kid,
  );

  /// An API session of the admin (another device of the admin).
  final FamioApiClient admin;
  final FamilyMember adminMember, bea, carl, guest, kid;
}

Future<KitFamily>? _family;
final _sessions = <String, FamioApiClient>{};

Future<FamioApiClient> kitAdminApi() async {
  final api = FamioApiClient(kitUrl);
  await api.login(username: kitUser, password: kitPassword, device: 'e2e-api');
  return api;
}

/// The members, created on first use. Usernames: e2e-bea, e2e-carl,
/// e2e-gast, e2e-kind; all with [kitMemberPassword].
Future<KitFamily> theFamily() => _family ??= () async {
  final admin = await kitAdminApi();
  Future<FamilyMember> member(String user, String name, MemberRole role) async {
    for (final u in await admin.adminUsers()) {
      if (u.member.username == user) return u.member;
    }
    return admin.createMember(
      username: user,
      displayName: name,
      password: kitMemberPassword,
      role: role,
    );
  }

  return KitFamily(
    admin,
    await admin.me(),
    await member('e2e-bea', 'E2E Bea', MemberRole.adult),
    await member('e2e-carl', 'E2E Carl', MemberRole.adult),
    await member('e2e-gast', 'E2E Gast', MemberRole.guest),
    await member('e2e-kind', 'E2E Kind', MemberRole.child),
  );
}();

/// An API session of [m], to see what the server gives that member.
Future<FamioApiClient> sessionOf(FamilyMember m) async {
  final known = _sessions[m.id];
  if (known != null) return known;
  final api = FamioApiClient(kitUrl);
  await api.login(
    username: m.username,
    password: kitMemberPassword,
    device: 'e2e',
  );
  return _sessions[m.id] = api;
}

/// Everything of [collection] the server currently gives [api]'s member.
Future<Map<String, SyncRecord>> pull(
  FamioApiClient api,
  String collection,
) async {
  final out = <String, SyncRecord>{};
  var since = 0;
  while (true) {
    final r = await api.sync(SyncRequest(since: since));
    for (final c in r.changes) {
      if (c.collection != collection) continue;
      if (c.deleted) {
        out.remove(c.id);
      } else {
        out[c.id] = c;
      }
    }
    if (!r.hasMore || r.rev <= since) return out;
    since = r.rev;
  }
}

Future<Set<String>> titlesOf(FamioApiClient api, String collection) async => {
  for (final r in (await pull(api, collection)).values) '${r.data['title']}',
};

/// Writes records like another device of [api]'s member; returns the
/// server's answer (look at `rejected` for what it turned down).
Future<SyncResponse> put(
  FamioApiClient api,
  String collection,
  Map<String, Map<String, Object?>> records,
) => api.sync(
  SyncRequest(
    since: 0,
    changes: [
      for (final MapEntry(key: id, value: data) in records.entries)
        SyncRecord(
          collection: collection,
          id: id,
          data: data,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
    ],
  ),
);

/// Deletes records like another device of [api]'s member.
Future<SyncResponse> remove(
  FamioApiClient api,
  String collection,
  Iterable<String> ids,
) => api.sync(
  SyncRequest(
    since: 0,
    changes: [
      for (final id in ids)
        SyncRecord(
          collection: collection,
          id: id,
          data: const {},
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          deleted: true,
        ),
    ],
  ),
);

var _uidCount = 0;

/// A unique id for records the test writes (the counter keeps two calls in
/// the same microsecond apart).
String uid(String what) =>
    'e2e-$what-${DateTime.now().microsecondsSinceEpoch}-${_uidCount++}';

DateTime today() => DateUtils.dateOnly(DateTime.now());
DateTime inDays(int n) => DateUtils.addDaysToDate(today(), n);

// --- the app ---------------------------------------------------------------

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
  throw TestFailure('Timed out waiting for $finder\nOn screen: ${onScreen()}');
}

/// The texts on screen, for failure messages.
String onScreen() => find
    .byType(Text)
    .evaluate()
    .map(
      (e) =>
          (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText(),
    )
    .whereType<String>()
    .join(' | ');

Future<void> waitGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isEmpty) return;
  }
  throw TestFailure('Still there after $timeout: $finder');
}

/// Polls [check] (e.g. what another member gets from the server) while the
/// app keeps running.
Future<void> eventually(
  WidgetTester tester,
  String what,
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  debugPrint('E2E eventually $what');
  final end = DateTime.now().add(timeout);
  while (true) {
    if (await check()) return;
    if (DateTime.now().isAfter(end)) throw TestFailure('Timed out: $what');
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  debugPrint('E2E tap ${finder.describeMatch(Plurality.many)}');
  await waitFor(tester, finder);
  await tester.ensureVisible(finder.first);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder.first, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> enter(WidgetTester tester, Finder field, String text) async {
  await waitFor(tester, field);
  await tester.ensureVisible(field.last);
  await tester.tap(field.last, warnIfMissed: false);
  await tester.pump();
  await tester.enterText(field.last, text);
  await tester.pump();
  final widget = tester.widget(field.last);
  final controller = widget is TextField
      ? widget.controller
      : widget is TextFormField
      ? widget.controller
      : null;
  if (controller != null && controller.text != text) {
    controller.text = text;
    await tester.pump();
  }
}

/// A text field by its label (or hint).
Finder field(String label) => find.widgetWithText(TextField, label);

/// Dialogs animate out; taps before that hit the fading barrier.
Future<void> dialogClosed(WidgetTester tester) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (find.byType(Dialog).evaluate().isNotEmpty &&
      DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

/// Some dialogs dispose their text fields as soon as they return; leaving
/// the field first (as with Tab) avoids a debug assertion.
Future<void> leaveField(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Lists build only what is near the screen: drags the page (right of the
/// side rail) until [finder] exists, first down (or [up]), then the other
/// way.
Future<void> scrollTo(
  WidgetTester tester,
  Finder finder, {
  bool up = false,
  Offset at = const Offset(600, 420),
}) async {
  for (final towardsTop in [up, !up]) {
    for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
      await tester.dragFrom(at, Offset(0, towardsTop ? 220 : -220));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }
  await waitFor(tester, finder, timeout: const Duration(seconds: 3));
  await tester.ensureVisible(finder.first);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> snackGone(WidgetTester tester) async {
  if (find.byType(SnackBar).evaluate().isNotEmpty) {
    await waitGone(
      tester,
      find.byType(SnackBar),
      timeout: const Duration(seconds: 15),
    );
  }
}

/// Puts the first visit's tip of a section away.
Future<void> dismissTip(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  if (find.text(de.tipGotIt).evaluate().isNotEmpty) {
    await tap(tester, find.text(de.tipGotIt).last);
  }
}

/// Sections in the side rail; on phones an icon in the bar (tooltip) or
/// behind "Mehr". With [keepTip] the first visit's tip stays open.
Future<void> openSection(
  WidgetTester tester,
  String label, {
  bool keepTip = false,
}) async {
  await snackGone(tester);
  await waitFor(
    tester,
    find.byWidgetPredicate(
      (w) =>
          (w is Text && w.data == label) ||
          (w is Tooltip && (w.message == label || w.message == 'Mehr')),
    ),
  );
  if (find.text(label).evaluate().isNotEmpty) {
    await tap(tester, find.text(label).last);
  } else if (find.byTooltip(label).evaluate().isNotEmpty) {
    await tap(tester, find.byTooltip(label).last);
  } else {
    await tap(tester, find.byTooltip('Mehr').last);
    await tap(tester, find.text(label).last);
  }
  if (!keepTip) await dismissTip(tester);
}

Future<void> back(WidgetTester tester) async {
  await tap(tester, find.byTooltip(de.commonBack).last);
  await tester.pump(const Duration(milliseconds: 500));
}

/// Einstellungen → Server-Verwaltung → [tab].
Future<void> openAdmin(WidgetTester tester, String tab) async {
  await openSection(tester, 'Einstellungen');
  await scrollTo(tester, find.text('Server-Verwaltung'));
  await tap(tester, find.text('Server-Verwaltung'));
  await waitFor(tester, find.text('Benutzer'));
  await tap(tester, find.text(tab).last);
}

/// Opens the drop-down labelled [label] and picks [item].
Future<void> choose(WidgetTester tester, String label, String item) async {
  await tap(
    tester,
    find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate(
        (w) => w is DropdownButtonFormField || w is DropdownButton,
      ),
    ),
  );
  await tap(tester, find.text(item).last);
  await tester.pump(const Duration(milliseconds: 500));
}

/// The Material date picker, typed in instead of tapping a calendar.
Future<void> pickDate(WidgetTester tester, DateTime date) async {
  await tap(tester, find.byTooltip('Zur Texteingabe wechseln'));
  await enter(
    tester,
    find.widgetWithText(TextField, 'Datum eingeben'),
    DateFormat.yMd('de').format(date),
  );
  await tap(tester, find.text('OK').last);
  await waitGone(tester, find.widgetWithText(TextField, 'Datum eingeben'));
  await tester.pump(const Duration(milliseconds: 400));
}

/// The card around [text] (task tile, list entry …).
Finder cardOf(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(SoftCard)).first;

/// Something of the signed-in member's start page or rail.
final signedInMark = find.byWidgetPredicate(
  (w) =>
      (w is Text && w.data == 'Einstellungen') ||
      (w is Tooltip && (w.message == 'Mehr' || w.message == 'Einstellungen')),
);

var _formatted = false;

/// Starts the app signed out and signs in as [user] (the admin unless
/// given) through the app's own pages.
Future<AppState> startApp(
  WidgetTester tester, {
  String? user,
  String? password,
}) async {
  expect(kitUrl, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
  if (!_formatted) {
    await initializeDateFormatting('de');
    await initializeDateFormatting('en');
    await initializeDateFormatting('es');
    _formatted = true;
  }
  await freshStart();
  final state = AppState();
  await state.init();
  // Also when the test fails half-way: the next one starts signed out.
  addTearDown(() async {
    if (state.me != null) await state.signOut();
  });
  await tester.pumpWidget(FamioApp(state: state));
  if (state.me == null) {
    await enter(tester, field('Server-Adresse'), kitUrl);
    await tap(tester, find.text('Verbinden'));
    await enter(tester, field('Benutzername'), user ?? kitUser);
    await enter(
      tester,
      field('Passwort'),
      password ?? (user == null ? kitPassword : kitMemberPassword),
    );
    await tap(tester, find.text('Anmelden'));
  }
  await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
  // A first sign-in may offer the tour; the tests go straight to work.
  if (find.text(de.commonLater).evaluate().isNotEmpty) {
    await tap(tester, find.text(de.commonLater).last);
  }
  return state;
}

Future<void> finish(WidgetTester tester, AppState state) async {
  if (state.me != null) await state.signOut();
  await tester.pump(const Duration(seconds: 1));
}
