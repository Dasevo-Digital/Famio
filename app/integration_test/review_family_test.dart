// Acceptance test of reviewed features (children, health, settings,
// security, administration) in the real app against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/review_family_test.dart
//
// One test per board card ("#NNN …"). Each starts signed out, signs in,
// uses the feature like a person would and signs out again. What other
// people or a second device do comes from the API. Tests that change
// server-wide settings run last and set them back.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/kids_log_screens.dart';
import 'package:famio/src/screens/kids_screens.dart';
import 'package:famio/src/widgets/account_widgets.dart';
import 'package:famio/src/widgets/setup_checklist.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fresh_start.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _newUrl = String.fromEnvironment('FAMIO_NEW_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');

/// For the members the tests add: random words, no names (the server
/// turns easy passwords down, see #178).
const _memberPassword = 'Kiesel-Fahne-Mond-42';

/// RFC 6238 code like an authenticator app, [offset] steps from now.
String totp(String secret, {int offset = 0}) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final bytes = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final char in secret.toUpperCase().split('')) {
    buffer = (buffer << 5) | alphabet.indexOf(char);
    bits += 5;
    if (bits >= 8) {
      bytes.add((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  final step = DateTime.now().millisecondsSinceEpoch ~/ 30000 + offset;
  final counter = ByteData(8)..setUint64(0, step);
  final hash = Hmac(sha1, bytes).convert(counter.buffer.asUint8List()).bytes;
  final o = hash.last & 0x0f;
  final value =
      ((hash[o] & 0x7f) << 24) |
      (hash[o + 1] << 16) |
      (hash[o + 2] << 8) |
      hash[o + 3];
  return (value % pow(10, 6)).toString().padLeft(6, '0');
}

/// Central European time of [utc] (last Sunday of March to the last Sunday
/// of October at 1:00 UTC is summer time), as "HH:00".
String berlinHour(DateTime utc) {
  DateTime lastSunday(int month) {
    var d = DateTime.utc(utc.year, month + 1, 0, 1);
    while (d.weekday != DateTime.sunday) {
      d = d.subtract(const Duration(days: 1));
    }
    return d;
  }

  final summer = !utc.isBefore(lastSunday(3)) && utc.isBefore(lastSunday(10));
  final hour = utc.add(Duration(hours: summer ? 2 : 1)).hour;
  return '${hour.toString().padLeft(2, '0')}:00';
}

void main() {
  // The tests read German texts, whatever the device speaks.
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // --- finding and tapping ------------------------------------------------

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
    throw TestFailure('Timed out waiting for $finder\nOn screen: $texts');
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    debugPrint('E2E tap ${finder.describeMatch(Plurality.many)}');
    await waitFor(tester, finder);
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder.first);
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> enter(WidgetTester tester, Finder field, String text) async {
    await waitFor(tester, field);
    await tester.ensureVisible(field.last);
    await tester.tap(field.last);
    await tester.pump();
    await tester.enterText(field.last, text);
    await tester.pump();
    final controller = tester.widget<TextField>(field.last).controller;
    if (controller != null && controller.text != text) {
      controller.text = text;
      await tester.pump();
    }
  }

  Future<void> dialogClosed(WidgetTester tester) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (find.byType(Dialog).evaluate().isNotEmpty &&
        DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Lists build lazily: scrolls [within] (the last vertical list by
  /// default) until [finder] shows, first down, then up.
  Future<void> scrollTo(
    WidgetTester tester,
    Finder finder, {
    Finder? within,
  }) async {
    final list =
        within ??
        find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        );
    for (final dy in [-250.0, 250.0]) {
      for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
        await tester.drag(list.last, Offset(0, dy), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 250));
      }
    }
    await waitFor(tester, finder, timeout: const Duration(seconds: 5));
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Scrolls [within] to its end.
  Future<void> scrollToEnd(WidgetTester tester, {Finder? within}) async {
    final list =
        within ??
        find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        );
    for (var i = 0; i < 25; i++) {
      await tester.drag(list.last, const Offset(0, -400), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// The vertical list inside [of].
  Finder listIn(Finder of) => find
      .descendant(
        of: of,
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      )
      .first;

  /// Sections in the side rail; on phones an icon in the bar (tooltip) or
  /// behind "Mehr".
  Future<void> openSection(
    WidgetTester tester,
    String label, {
    String more = 'Mehr',
    String understood = 'Verstanden',
  }) async {
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == label) ||
            (w is Tooltip && (w.message == label || w.message == more)),
      ),
    );
    if (find.text(label).evaluate().isNotEmpty) {
      await tap(tester, find.text(label).last);
    } else if (find.byTooltip(label).evaluate().isNotEmpty) {
      await tap(tester, find.byTooltip(label).last);
    } else {
      await tap(tester, find.byTooltip(more).last);
      await tap(tester, find.text(label).last);
    }
    // The first visit's tip; a person reads it and puts it away.
    await tester.pump(const Duration(milliseconds: 500));
    if (find.text(understood).evaluate().isNotEmpty) {
      await tap(tester, find.text(understood).last);
    }
  }

  Future<void> back(WidgetTester tester) async {
    await tap(tester, find.byTooltip('Zurück').last);
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openAdmin(WidgetTester tester, String tab) async {
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text('Server-Verwaltung'));
    await tap(tester, find.text('Server-Verwaltung'));
    await waitFor(tester, find.text('Benutzer'));
    await tap(tester, find.text(tab).last);
  }

  // --- signing in -----------------------------------------------------------

  final home = find.byWidgetPredicate(
    (w) =>
        (w is Text && w.data == 'Einstellungen') ||
        (w is Tooltip && (w.message == 'Mehr' || w.message == 'Einstellungen')),
  );

  Future<void> signIn(WidgetTester tester, {String url = _url}) async {
    await enter(tester, find.widgetWithText(TextField, 'Server-Adresse'), url);
    await tap(tester, find.text('Verbinden'));
    if (url.startsWith('https')) {
      // The throwaway server's own certificate: confirmed once.
      await waitFor(tester, find.text('Zertifikat des Servers prüfen'));
      await tap(tester, find.text('Stimmt überein'));
    }
    await enter(tester, find.widgetWithText(TextField, 'Benutzername'), _user);
    await enter(tester, find.widgetWithText(TextField, 'Passwort'), _password);
    await tap(tester, find.text('Anmelden'));
    await waitFor(tester, home);
  }

  var formatted = false;
  Future<AppState> start(WidgetTester tester, {String url = _url}) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    if (!formatted) {
      await initializeDateFormatting('de');
      await initializeDateFormatting('en');
      await initializeDateFormatting('es');
      formatted = true;
    }
    await freshStart();
    final state = AppState();
    await state.init();
    addTearDown(() async {
      if (state.me != null) await state.signOut();
    });
    await tester.pumpWidget(FamioApp(state: state));
    if (state.me == null) await signIn(tester, url: url);
    await waitFor(tester, home);
    return state;
  }

  Future<void> finish(WidgetTester tester, AppState state) async {
    if (state.me != null) await state.signOut();
    await tester.pump(const Duration(seconds: 1));
  }

  // --- the server, for what other people and devices do -------------------

  FamioApiClient? setup;
  Future<FamioApiClient> admin() async {
    if (setup case final api?) return api;
    final api = FamioApiClient(_url);
    await api.login(username: _user, password: _password, device: 'e2e-setup');
    return setup = api;
  }

  Future<String> adminId() async => (await (await admin()).me()).id;

  Future<FamilyMember> addMember(
    String username,
    String name, {
    MemberRole role = MemberRole.adult,
    bool isAdmin = false,
  }) async {
    final api = await admin();
    for (final u in await api.adminUsers()) {
      if (u.member.username == username) await api.deleteMember(u.member.id);
    }
    final member = await api.createMember(
      username: username,
      displayName: name,
      password: _memberPassword,
      role: role,
      isAdmin: isAdmin,
    );
    addTearDown(() async {
      try {
        await (await admin()).deleteMember(member.id);
      } on ApiError {
        // Gone already.
      }
    });
    return member;
  }

  Future<FamioApiClient> signedIn(String username, {String? device}) async {
    final api = FamioApiClient(_url);
    await api.login(
      username: username,
      password: _memberPassword,
      device: device ?? 'e2e',
    );
    return api;
  }

  /// Writes records like another device; none may be turned down.
  Future<void> put(
    FamioApiClient api,
    String collection,
    Map<String, Map<String, Object?>> records, {
    int rev = 0,
  }) async {
    final answer = await api.sync(
      SyncRequest(
        since: 0,
        changes: [
          for (final MapEntry(key: id, value: data) in records.entries)
            SyncRecord(
              collection: collection,
              id: id,
              data: data,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
              rev: rev,
            ),
        ],
      ),
    );
    expect(answer.rejected.map((r) => r.id), isEmpty);
  }

  Future<void> remove(
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

  /// What the server gives [api] of [collection].
  Future<List<SyncRecord>> fetch(FamioApiClient api, String collection) async {
    final all = <String, SyncRecord>{};
    var since = 0;
    while (true) {
      final r = await api.sync(SyncRequest(since: since));
      for (final c in r.changes) {
        if (c.collection == collection) all[c.id] = c;
      }
      if (!r.hasMore || r.rev <= since) break;
      since = r.rev;
    }
    return [
      for (final r in all.values)
        if (!r.deleted) r,
    ];
  }

  String uid(String what) =>
      'e2e-$what-${DateTime.now().microsecondsSinceEpoch}';

  /// A child of the signed-in admin, as another device of the admin writes
  /// it; removed after the test.
  Future<String> addChild(String name, DateTime birth, {ChildSex? sex}) async {
    final api = await admin();
    final id = uid('child');
    await put(api, Collections.children, {
      id: Child(
        id: id,
        name: name,
        birthDate: birth,
        guardianIds: [await adminId()],
        sex: sex,
      ).toData(),
    });
    addTearDown(() async => remove(await admin(), Collections.children, [id]));
    return id;
  }

  Finder iconButton(String tooltip) =>
      find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip);

  // --- children -------------------------------------------------------------

  testWidgets('#151 new child: all adults preselected, hint for the others', (
    tester,
  ) async {
    final papa = await addMember('e2e-papa', 'E2E Papa');
    await addMember('e2e-tante', 'E2E Tante');
    await addMember('e2e-schulkind', 'E2E Schulkind', role: MemberRole.child);
    final state = await start(tester);
    final me = state.me!;

    await openSection(tester, 'Kinder');
    // Other adults: the page says why a child may be missing.
    await waitFor(
      tester,
      find.textContaining('Fehlt ein Kind? Ein Kind sehen nur seine'),
    );
    await tap(tester, find.byTooltip('Kind oder Schwangerschaft hinzufügen'));
    await tap(tester, find.text('Kind hinzufügen').last);
    await waitFor(tester, find.text('Sorgeberechtigte'));
    bool chosen(String name) => tester
        .widget<FilterChip>(find.widgetWithText(FilterChip, name))
        .selected;
    expect(chosen(me.displayName), isTrue);
    expect(chosen('E2E Papa'), isTrue);
    expect(chosen('E2E Tante'), isTrue);
    expect(chosen('E2E Schulkind'), isFalse);
    await scrollTo(
      tester,
      find.textContaining('Alle anderen sehen es gar nicht'),
    );

    // The aunt is no guardian here.
    await tap(tester, find.widgetWithText(FilterChip, 'E2E Tante'));
    expect(chosen('E2E Tante'), isFalse);
    await enter(tester, find.widgetWithText(TextField, 'Name'), 'E2E Baby');
    await tap(tester, find.text('Datum wählen'));
    await tap(tester, find.text('OK'));
    await dialogClosed(tester);
    await tap(tester, find.text('Speichern').last);

    // The card tells who sees the child.
    await waitFor(tester, find.text('E2E Baby'));
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data?.startsWith('Nur ') ?? false) &&
            w.data!.contains(me.displayName) &&
            w.data!.contains('E2E Papa') &&
            !w.data!.contains('Tante'),
      ),
    );

    await state.engine!.sync();
    final record = state.engine!
        .records(Collections.children)
        .firstWhere((r) => r.data['name'] == 'E2E Baby');
    addTearDown(
      () async => remove(await admin(), Collections.children, [record.id]),
    );
    expect(
      record.data['guardianIds'] as List,
      unorderedEquals([me.id, papa.id]),
    );
    // The father gets the child, the aunt does not.
    final papaApi = await signedIn('e2e-papa');
    expect(
      (await fetch(papaApi, Collections.children)).map((r) => r.data['name']),
      contains('E2E Baby'),
    );
    final auntApi = await signedIn('e2e-tante');
    expect(
      (await fetch(auntApi, Collections.children)).map((r) => r.data['name']),
      isNot(contains('E2E Baby')),
    );
    await finish(tester, state);
  });

  testWidgets('#153 child log: day, week, month and back in time', (
    tester,
  ) async {
    final now = DateTime.now();
    final birth = DateTime(now.year, now.month - 1, 10);
    final childId = await addChild('E2E Protokoll', birth);
    final me = await adminId();
    ChildLog diaper(DateTime at, String note) => ChildLog(
      id: uid('log'),
      childId: childId,
      kind: LogKind.diaper,
      start: at,
      diaper: DiaperKind.wet,
      note: note,
      by: me,
    );
    final today = now.subtract(const Duration(minutes: 2));
    final logs = [
      diaper(
        today.day == now.day ? today : DateTime(now.year, now.month, now.day),
        'E2E heute',
      ),
      diaper(DateTime(now.year, now.month, now.day - 1, 12), 'E2E gestern'),
      diaper(DateTime(now.year, now.month - 1, 20, 9), 'E2E Vormonat'),
    ];
    await put(await admin(), Collections.childLogs, {
      for (final l in logs) l.id: l.toData(),
    });
    addTearDown(
      () async => remove(await admin(), Collections.childLogs, [
        for (final l in logs) l.id,
      ]),
    );
    final state = await start(tester);

    await openSection(tester, 'Kinder');
    await tap(tester, find.text('E2E Protokoll'));
    // Babies open on their log.
    await waitFor(tester, find.byType(ChildLogView));
    final list = listIn(find.byType(ChildLogView));
    Future<void> period(Finder control) async {
      await scrollTo(tester, control, within: list);
      await tap(tester, control);
    }

    Future<bool> enabled(String tooltip) async {
      await scrollTo(tester, iconButton(tooltip), within: list);
      return tester.widget<IconButton>(iconButton(tooltip)).onPressed != null;
    }

    Finder segment(String label) => find.descendant(
      of: find.byWidgetPredicate((w) => w is SegmentedButton),
      matching: find.text(label),
    );

    // Day: today, a day back, and "Heute" again.
    await scrollTo(tester, find.text('E2E heute'), within: list);
    expect(find.text('E2E gestern'), findsNothing);
    expect(await enabled('Später'), isFalse);
    await period(iconButton('Früher'));
    await scrollTo(tester, find.text('E2E gestern'), within: list);
    expect(find.text('E2E heute'), findsNothing);
    await period(find.widgetWithText(TextButton, 'Heute'));
    await scrollTo(tester, find.text('E2E heute'), within: list);

    // Week.
    await period(segment('Woche'));
    await scrollTo(tester, find.text('Diese Woche'), within: list);
    await period(iconButton('Früher'));
    await scrollTo(tester, find.text('Letzte Woche'), within: list);
    await period(find.widgetWithText(TextButton, 'Heute'));
    await scrollTo(tester, find.text('Diese Woche'), within: list);

    // Month: this one, then the month of birth, which is as far back as
    // it goes.
    final month = DateFormat.yMMMM('de');
    await period(segment('Monat'));
    await scrollTo(tester, find.text(month.format(now)), within: list);
    await scrollTo(tester, find.text('E2E heute'), within: list);
    await scrollToEnd(tester, within: list);
    expect(find.text('E2E Vormonat'), findsNothing);
    await period(iconButton('Früher'));
    await scrollTo(
      tester,
      find.text(month.format(DateTime(now.year, now.month - 1))),
      within: list,
    );
    await scrollTo(tester, find.text('E2E Vormonat'), within: list);
    expect(await enabled('Früher'), isFalse);
    await period(iconButton('Später'));
    await scrollTo(tester, find.text(month.format(now)), within: list);
    expect(await enabled('Später'), isFalse);
    await finish(tester, state);
  });

  testWidgets('#143 milestones: senses, development phases, puberty', (
    tester,
  ) async {
    final now = DateTime.now();
    await addChild(
      'E2E Neugeboren',
      DateTime(now.year, now.month, now.day - 10),
    );
    await addChild(
      'E2E Mädchen',
      DateTime(now.year - 11, now.month - 3, now.day),
      sex: ChildSex.female,
    );
    await addChild(
      'E2E Junge',
      DateTime(now.year - 12, now.month - 2, now.day),
      sex: ChildSex.male,
    );
    final state = await start(tester);
    Finder tab() => listIn(find.byType(ChildScreen));

    Future<void> open(String child) async {
      await openSection(tester, 'Kinder');
      await scrollTo(tester, find.text(child));
      await tap(tester, find.text(child));
      await tap(tester, find.text('Meilensteine'));
      await waitFor(tester, find.text('Entwicklungsphasen'));
    }

    // A newborn: what it sees and hears, as phases and as milestones.
    await open('E2E Neugeboren');
    await waitFor(tester, find.text('Sehen: Gesichter auf Armlänge'));
    await scrollTo(tester, find.text('Hören: von Anfang an'), within: tab());
    await scrollTo(tester, find.text('Sehen & Hören'), within: tab());
    await scrollTo(
      tester,
      find.text('Schaut Gesichter aufmerksam an'),
      within: tab(),
    );
    await scrollToEnd(tester, within: tab());
    expect(find.text('Pubertät'), findsNothing);
    // The timeline shows the next phase.
    await tap(tester, find.text('Zeitstrahl'));
    await scrollTo(
      tester,
      find.text('Sehen: Farben, Bewegung, Tiefe'),
      within: tab(),
    );
    expect(find.textContaining('Entwicklungsphase ·'), findsWidgets);
    await back(tester);

    // A girl of eleven: puberty for girls.
    await open('E2E Mädchen');
    await waitFor(tester, find.text('Pubertät: Beginn'));
    await scrollTo(tester, find.text('Pubertät'), within: tab());
    await scrollTo(
      tester,
      find.text('Die Brust beginnt zu wachsen'),
      within: tab(),
    );
    await scrollTo(tester, find.text('Erste Periode'), within: tab());
    await scrollToEnd(tester, within: tab());
    expect(find.text('Stimmbruch'), findsNothing);
    expect(find.text('Erster Bartflaum'), findsNothing);
    await back(tester);

    // A boy of twelve: puberty for boys.
    await open('E2E Junge');
    await waitFor(tester, find.text('Pubertät: Beginn'));
    await scrollTo(tester, find.text('Stimmbruch'), within: tab());
    await scrollTo(tester, find.text('Erster Bartflaum'), within: tab());
    await scrollToEnd(tester, within: tab());
    expect(find.text('Erste Periode'), findsNothing);
    expect(find.text('Die Brust beginnt zu wachsen'), findsNothing);
    await back(tester);
    await finish(tester, state);
  });

  // --- health ---------------------------------------------------------------

  testWidgets('#264 MenACWY, ultrasound windows, fever under two', (
    tester,
  ) async {
    final now = DateTime.now();
    final me = await adminId();
    await addChild(
      'E2E Zwölf',
      DateTime(now.year - 12, now.month, now.day - 5),
      sex: ChildSex.male,
    );
    final toddler = await addChild(
      'E2E Kleinkind',
      DateTime(now.year - 1, now.month, now.day - 10),
    );
    // A parent measured 38.6 °C yesterday morning, more than a day ago.
    final earlier = ChildLog(
      id: uid('log'),
      childId: toddler,
      kind: LogKind.temperature,
      start: now.subtract(const Duration(hours: 30)),
      temperatureC: 38.6,
      note: 'E2E gestern gemessen',
      by: me,
    );
    await put(await admin(), Collections.childLogs, {
      earlier.id: earlier.toData(),
    });
    final pregnancyId = uid('pregnancy');
    await put(await admin(), Collections.pregnancies, {
      pregnancyId: Pregnancy(
        id: pregnancyId,
        // 8+0 today.
        dueDate: DateTime(now.year, now.month, now.day + 32 * 7),
        name: 'E2E Bauch',
        guardianIds: [me],
      ).toData(),
    });
    addTearDown(() async {
      final api = await admin();
      await remove(api, Collections.pregnancies, [pregnancyId]);
      final logs = await fetch(api, Collections.childLogs);
      await remove(api, Collections.childLogs, [
        for (final l in logs)
          if (l.data['childId'] == toddler) l.id,
      ]);
    });
    final state = await start(tester);
    Finder tab() => listIn(find.byType(ChildScreen));
    Future<void> open(String child) async {
      await openSection(tester, 'Kinder');
      await scrollTo(tester, find.text(child));
      await tap(tester, find.text(child));
      await waitFor(tester, find.byType(ChildScreen));
    }

    // Twelve years: MenACWY is due now.
    await open('E2E Zwölf');
    await tap(tester, find.text('Impfungen'));
    final menAcwy = find.text('Meningokokken A, C, W, Y – einmalig');
    await scrollTo(tester, menAcwy, within: tab());
    expect(
      find.descendant(
        of: find.ancestor(of: menAcwy, matching: find.byType(Row)).first,
        matching: find.text('jetzt fällig'),
      ),
      findsOneWidget,
    );
    await scrollToEnd(tester, within: tab());
    expect(find.textContaining('Meningokokken C'), findsNothing);
    await back(tester);

    // One year: no MenC at twelve months any more (MenB is still there).
    await open('E2E Kleinkind');
    await tap(tester, find.text('Impfungen'));
    await scrollTo(
      tester,
      find.text('Meningokokken B – 3. Dosis'),
      within: tab(),
    );
    await scrollToEnd(tester, within: tab());
    expect(find.textContaining('Meningokokken C'), findsNothing);
    expect(find.textContaining('Meningokokken A, C, W, Y'), findsNothing);

    // Fever again a day later in a child under two: see a doctor.
    await tap(tester, find.text('Protokoll'));
    await waitFor(tester, find.byType(ChildLogView));
    await scrollTo(
      tester,
      find.text('Temperatur'),
      within: listIn(find.byType(ChildLogView)),
    );
    await tap(tester, find.text('Temperatur').first);
    await enter(
      tester,
      find.widgetWithText(TextField, 'Temperatur (°C)'),
      '38,7',
    );
    const underTwo =
        'Bei Kindern bis zwei Jahre: Fieber länger als einen Tag bitte beim '
        'Kinderarzt abklären lassen.';
    await waitFor(tester, find.textContaining(underTwo));
    await tap(tester, find.text('Speichern').last);
    await waitFor(tester, find.byType(AlertDialog));
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining(underTwo),
      ),
      findsOneWidget,
    );
    await tap(tester, find.text('Verstanden').last);
    await dialogClosed(tester);
    await back(tester);

    // Pregnancy at 8+0: the first screening is due now; all three windows
    // a week earlier than before.
    await openSection(tester, 'Kinder');
    await tap(tester, find.text('E2E Bauch'));
    await waitFor(tester, find.text('SSW 8+0'));
    final first = find.text('1. Ultraschall-Screening');
    await scrollTo(tester, first);
    expect(find.text('Mutterpass: 8+0 bis 11+6.'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(of: first, matching: find.byType(Row)).first,
        matching: find.text('jetzt'),
      ),
      findsOneWidget,
    );
    await tap(tester, find.text('Termine'));
    await scrollTo(tester, find.text('Mutterpass: 8+0 bis 11+6.'));
    await scrollTo(tester, find.text('Mutterpass: 18+0 bis 21+6.'));
    await scrollTo(tester, find.text('Mutterpass: 28+0 bis 31+6.'));
    await back(tester);
    await finish(tester, state);
  });

  testWidgets('#198 emergency info for adults, shown with an SOS alarm', (
    tester,
  ) async {
    final papa = await addMember('e2e-papa', 'E2E Papa');
    await addMember('e2e-kind', 'E2E Kind', role: MemberRole.child);
    final state = await start(tester);
    final me = state.me!;

    // Own emergency info in the settings.
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text('Meine Notfall-Infos'));
    await tap(tester, find.text('Meine Notfall-Infos'));
    await tap(tester, find.text('Notfall-Infos eintragen'));
    await enter(
      tester,
      find.widgetWithText(TextField, 'Allergien'),
      'E2E Erdnüsse',
    );
    await enter(
      tester,
      find.widgetWithText(TextField, 'Blutgruppe'),
      'E2E 0 negativ',
    );
    await scrollTo(
      tester,
      find.widgetWithText(TextField, 'Vollmacht und Patientenverfügung'),
    );
    await enter(
      tester,
      find.widgetWithText(TextField, 'Vollmacht und Patientenverfügung'),
      'E2E Ordner im Flur',
    );
    await tap(tester, find.text('Speichern').last);
    await waitFor(tester, find.text('E2E Erdnüsse'));
    await scrollTo(tester, find.text('E2E Ordner im Flur'));
    await scrollTo(
      tester,
      find.textContaining('Das sehen alle Erwachsenen der Familie'),
    );
    await state.engine!.sync();

    // Adults get it, children do not.
    final papaApi = await signedIn('e2e-papa');
    final seen = await fetch(papaApi, Collections.memberEmergency);
    final mine = seen.where((r) => r.id == me.id).single;
    expect(MemberEmergency.fromRecord(mine).info.allergies, 'E2E Erdnüsse');
    final kidApi = await signedIn('e2e-kind');
    expect(await fetch(kidApi, Collections.memberEmergency), isEmpty);

    // The father has his own and raises an alarm: his info is one tap away.
    await put(papaApi, Collections.memberEmergency, {
      papa.id: MemberEmergency(
        memberId: papa.id,
        info: const EmergencyInfo(allergies: 'E2E Penicillin'),
      ).toData(),
    });
    final alarm = await papaApi.raiseSos();
    var resolved = false;
    addTearDown(() async {
      if (!resolved) await papaApi.sosResolve(alarm);
    });
    await back(tester);
    await openSection(tester, 'Start');
    await tap(tester, find.text('SOS von E2E Papa'));
    await tap(tester, find.text('Notfall-Infos von E2E Papa'));
    await waitFor(tester, find.text('E2E Penicillin'));
    await back(tester);
    await papaApi.sosResolve(alarm);
    resolved = true;
    await back(tester);
    await finish(tester, state);
  });

  // --- this device ----------------------------------------------------------

  testWidgets('#231 appearance per device: system, light, dark', (
    tester,
  ) async {
    final state = await start(tester);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text('Darstellung'));
    // Whatever is on screen of the settings page.
    Brightness brightness() =>
        Theme.of(tester.element(find.byType(ListTile).last)).brightness;
    Future<void> choose(String label) async {
      await scrollTo(tester, find.byType(DropdownButton<ThemeMode>));
      await tap(tester, find.byType(DropdownButton<ThemeMode>));
      await tap(tester, find.text(label).last);
      await tester.pump(const Duration(seconds: 1));
    }

    final prefs = await SharedPreferences.getInstance();
    await choose('Dunkel');
    expect(brightness(), Brightness.dark);
    expect(prefs.getString('themeMode'), 'dark');
    // Together with high contrast.
    await scrollTo(tester, find.text('Hoher Kontrast'));
    await tap(tester, find.text('Hoher Kontrast'));
    await tester.pump(const Duration(seconds: 1));
    expect(state.highContrast.value, isTrue);
    expect(brightness(), Brightness.dark);
    await tap(tester, find.text('Hoher Kontrast'));
    await tester.pump(const Duration(seconds: 1));
    expect(state.highContrast.value, isFalse);

    await choose('Hell');
    expect(brightness(), Brightness.light);
    expect(prefs.getString('themeMode'), 'light');

    await choose('Wie das System');
    expect(brightness(), tester.platformDispatcher.platformBrightness);
    expect(prefs.getString('themeMode'), 'system');
    await finish(tester, state);
  });

  /// Switches the app to [language] in the settings and checks a few
  /// screens and a message of the server, then back to the device's.
  Future<void> otherLanguage(
    WidgetTester tester, {
    required String code,
    required String language,
    required Map<String, String> t,
  }) async {
    final state = await start(tester);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text('Sprache'));
    await tap(tester, find.byType(DropdownButton<String>));
    await tap(tester, find.text(language).last);
    await tester.pump(const Duration(seconds: 1));
    expect(state.language.value, code);
    expect(FamioApiClient.language, code);
    // The app starts over on its start page, in the new language.
    await openSection(
      tester,
      t['home']!,
      more: t['more']!,
      understood: t['understood']!,
    );
    // The greeting depends on the time of day.
    await waitFor(tester, find.textContaining(RegExp('^(${t['hello']}), ')));
    await openSection(
      tester,
      t['settings']!,
      more: t['more']!,
      understood: t['understood']!,
    );
    await scrollTo(tester, find.text(t['language']!));
    await scrollTo(tester, find.text(t['appearance']!));
    await scrollTo(tester, find.text(t['account']!));

    // Tasks.
    await openSection(
      tester,
      t['tasks']!,
      more: t['more']!,
      understood: t['understood']!,
    );
    await waitFor(tester, find.text(t['newTask']!));

    // The server answers in the language too.
    await openSection(
      tester,
      t['settings']!,
      more: t['more']!,
      understood: t['understood']!,
    );
    await scrollTo(tester, find.text(t['changePassword']!));
    await tap(tester, find.text(t['changePassword']!));
    await enter(
      tester,
      find.widgetWithText(TextField, t['current']!),
      _password,
    );
    await enter(
      tester,
      find.widgetWithText(TextField, t['newPassword']!),
      'password123',
    );
    await tap(tester, find.text(t['save']!).last);
    await waitFor(tester, find.textContaining(t['weak']!));
    await tap(tester, find.text(t['cancel']!).last);
    await dialogClosed(tester);

    // Back to the device's language (German in the tests).
    await scrollTo(tester, find.text(t['language']!));
    await tap(tester, find.byType(DropdownButton<String>));
    await tap(tester, find.text(t['likeDevice']!).last);
    await tester.pump(const Duration(seconds: 1));
    await openSection(tester, 'Start');
    await waitFor(
      tester,
      find.textContaining(
        RegExp('^(Guten Morgen|Hallo|Guten Abend|Gute Nacht), '),
      ),
    );
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text('Sprache'));
    expect(state.language.value, 'system');
    expect(FamioApiClient.language, 'de');
    await finish(tester, state);
  }

  testWidgets('#114 English user interface', (tester) async {
    await otherLanguage(
      tester,
      code: 'en',
      language: 'English',
      t: {
        'settings': 'Settings',
        'home': 'Home',
        'hello': 'Good morning|Hello|Good evening|Good night',
        'language': 'Language',
        'appearance': 'Appearance',
        'account': 'Account',
        'tasks': 'Tasks',
        'newTask': 'New task …',
        'more': 'More',
        'understood': 'Got it',
        'changePassword': 'Change password',
        'current': 'Current password',
        'newPassword': 'New password (min. 8 characters)',
        'save': 'Save',
        'cancel': 'Cancel',
        'weak': 'This password is too easy to guess.',
        'likeDevice': 'Like the device',
      },
    );
  });

  testWidgets('#135 Spanish user interface', (tester) async {
    await otherLanguage(
      tester,
      code: 'es',
      language: 'Español',
      t: {
        'settings': 'Ajustes',
        'home': 'Inicio',
        'hello': 'Buenos días|Hola|Buenas tardes|Buenas noches',
        'language': 'Idioma',
        'appearance': 'Apariencia',
        'account': 'Cuenta',
        'tasks': 'Tareas',
        'newTask': 'Nueva tarea …',
        'more': 'Más',
        'understood': 'Entendido',
        'changePassword': 'Cambiar contraseña',
        'current': 'Contraseña actual',
        'newPassword': 'Nueva contraseña (mín. 8 caracteres)',
        'save': 'Guardar',
        'cancel': 'Cancelar',
        'weak': 'Esta contraseña es demasiado fácil de adivinar.',
        'likeDevice': 'Como el dispositivo',
      },
    );
  });

  // --- security -------------------------------------------------------------

  testWidgets('#178 common and obvious passwords are turned down', (
    tester,
  ) async {
    addTearDown(() async {
      final api = await admin();
      for (final u in await api.adminUsers()) {
        if (u.member.username == 'e2e-erika') {
          await api.deleteMember(u.member.id);
        }
      }
    });
    final state = await start(tester);
    await openAdmin(tester, 'Benutzer');
    await tap(tester, find.byTooltip('Mitglied hinzufügen'));
    await tap(tester, find.text('Direkt anlegen'));
    await enter(tester, find.widgetWithText(TextField, 'Name'), 'E2E Erika');
    await enter(
      tester,
      find.widgetWithText(TextField, 'Benutzername (für die Anmeldung)'),
      'e2e-erika',
    );
    final password = find.widgetWithText(
      TextField,
      'Startpasswort (min. 8 Zeichen)',
    );
    // A common word, the new member's name, a keyboard row, another
    // member's name, a short number.
    for (final weak in [
      'Passwort123',
      'Erika2026!',
      'qwertz123',
      'Admin2026!',
      '19840512',
    ]) {
      await enter(tester, password, weak);
      await tap(tester, find.text('Speichern').last);
      await waitFor(tester, find.textContaining('zu leicht zu erraten'));
      expect(find.byType(Dialog), findsOneWidget, reason: weak);
    }
    expect(
      (await (await admin()).adminUsers()).map((u) => u.member.username),
      isNot(contains('e2e-erika')),
    );
    // Random words are fine.
    await enter(tester, password, _memberPassword);
    await tap(tester, find.text('Speichern').last);
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Erika'));

    // Changing one's own password: the same rules.
    await back(tester);
    await scrollTo(tester, find.text('Passwort ändern'));
    await tap(tester, find.text('Passwort ändern'));
    await enter(
      tester,
      find.widgetWithText(TextField, 'Aktuelles Passwort'),
      _password,
    );
    await enter(
      tester,
      find.widgetWithText(TextField, 'Neues Passwort (min. 8 Zeichen)'),
      'P@ssw0rt2026',
    );
    await tap(tester, find.text('Speichern').last);
    await waitFor(tester, find.textContaining('zu leicht zu erraten'));
    await tap(tester, find.text('Abbrechen').last);
    await dialogClosed(tester);
    // Still the old one.
    final check = FamioApiClient(_url);
    addTearDown(check.close);
    await check.login(username: _user, password: _password, device: 'e2e');
    await check.logout();
    await finish(tester, state);
  });

  /// A device of the signed-in member in "Meine Geräte".
  Finder deviceTile(bool Function(DeviceSession s) which) =>
      find.byWidgetPredicate((w) => w is DeviceTile && which(w.session));

  testWidgets('#168 sign-in on another device: "Das war ich nicht"', (
    tester,
  ) async {
    const temporary = 'Wolke-Regal-Tulpe-17';
    addTearDown(() async {
      // Back to the test password, whichever step failed.
      final api = FamioApiClient(_url);
      try {
        await api.login(username: _user, password: temporary, device: 'e2e');
        await api.changePassword(
          currentPassword: temporary,
          newPassword: _password,
        );
      } on ApiError {
        // Not changed (or set back already).
      }
      // The old setup session ends with a new password.
      setup = null;
    });
    final state = await start(tester);
    // Where the member's notifications stand now.
    final mailbox = await admin();
    final cursor = (await mailbox.notices()).last;

    // Someone signs in to the same account elsewhere.
    final other = FamioApiClient(_url);
    await other.login(
      username: _user,
      password: _password,
      device: 'E2E Zweitgerät',
    );
    await other.members();
    // The member's devices are told, with the device's name and the way out.
    final notice = (await mailbox.notices(
      after: cursor,
    )).notices.lastWhere((n) => n.title == 'Neue Anmeldung bei Famio');
    expect(notice.body, contains('E2E Zweitgerät'));
    expect(notice.body, contains('„Das war ich nicht“'));

    // "Meine Geräte": the new sign-in is marked, this device is not.
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text('Meine Geräte'));
    await tap(tester, find.text('Meine Geräte'));
    final intruder = deviceTile((s) => s.device == 'E2E Zweitgerät');
    await waitFor(tester, intruder);
    expect(
      find.descendant(
        of: intruder,
        matching: find.textContaining('neu angemeldet'),
      ),
      findsOneWidget,
    );
    final here = deviceTile((s) => s.current);
    expect(
      find.descendant(of: here, matching: find.textContaining('Dieses Gerät')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: here, matching: find.text('Das war ich nicht')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: here,
        matching: find.textContaining('neu angemeldet'),
      ),
      findsNothing,
    );

    // "Das war ich nicht": confirm, that device is signed out.
    await tap(
      tester,
      find.descendant(of: intruder, matching: find.text('Das war ich nicht')),
    );
    await waitFor(tester, find.text('Unbekannte Anmeldung'));
    expect(
      find.textContaining('E2E Zweitgerät wird abgemeldet.'),
      findsOneWidget,
    );
    await tap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Abmelden'),
      ),
    );
    await waitFor(tester, find.text('E2E Zweitgerät ist abgemeldet.'));
    await expectLater(
      other.members(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );

    // Then the app asks for a new password.
    await waitFor(tester, find.widgetWithText(TextField, 'Aktuelles Passwort'));
    expect(find.text('Passwort ändern'), findsWidgets);
    await enter(
      tester,
      find.widgetWithText(TextField, 'Aktuelles Passwort'),
      _password,
    );
    await enter(
      tester,
      find.widgetWithText(TextField, 'Neues Passwort (min. 8 Zeichen)'),
      temporary,
    );
    await tap(tester, find.text('Speichern').last);
    await dialogClosed(tester);
    expect(find.widgetWithText(TextField, 'Aktuelles Passwort'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(intruder, findsNothing);

    // The new password works, every other session is gone, this device
    // stays signed in.
    await expectLater(
      mailbox.members(),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    final check = FamioApiClient(_url);
    await check.login(username: _user, password: temporary, device: 'e2e');
    await state.engine!.api.members();
    expect(state.me, isNotNull);
    // Sessions older than a week ("Das war ich nicht" only for new ones)
    // cannot be made on a fresh server.
    await back(tester);
    await finish(tester, state);
    await check.changePassword(
      currentPassword: temporary,
      newPassword: _password,
    );
    setup = null;
  });

  testWidgets('#172 outdated app: version in "Meine Geräte", notice', (
    tester,
  ) async {
    final state = await start(tester);
    final mailbox = await admin();
    final cursor = (await mailbox.notices()).last;
    final server = (await mailbox.health()).version;

    // An old Android phone of the same member: it sends its app version
    // with every request (x-famio-app), like the app does.
    final phone = FamioApiClient(_url);
    final login = await phone.login(
      username: _user,
      password: _password,
      device: 'android (E2E Altes Handy)',
    );
    addTearDown(() async {
      try {
        await FamioApiClient(_url, token: login.token).logout();
      } on ApiError {
        // Signed out already.
      }
    });
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(Uri.parse(_url).resolve('api/me'));
    request.headers
      ..set('authorization', 'Bearer ${login.token}')
      ..set('x-famio-app', '2.0.0 android');
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 200);

    // "Meine Geräte" shows the version and that it is behind.
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text('Meine Geräte'));
    await tap(tester, find.text('Meine Geräte'));
    final old = deviceTile((s) => s.device == 'android (E2E Altes Handy)');
    await waitFor(tester, old);
    expect(
      find.descendant(
        of: old,
        matching: find.textContaining('Android · E2E Altes Handy'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: old, matching: find.textContaining('Famio 2.0.0')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: old,
        matching: find.textContaining('älter als der Server'),
      ),
      findsOneWidget,
    );
    final here = deviceTile((s) => s.current);
    expect(
      find.descendant(
        of: here,
        matching: find.textContaining('älter als der Server'),
      ),
      findsNothing,
    );
    await back(tester);

    // The server administration lists it under Status.
    await openAdmin(tester, 'Status');
    await scrollTo(tester, find.text('Apps älter als der Server'));
    await scrollTo(
      tester,
      find.text('${state.me!.displayName} · Android · E2E Altes Handy'),
    );
    expect(find.text('2.0.0'), findsWidgets);
    await back(tester);

    // The notice "Famio <version> ist da" goes out only once the server has
    // every package of its version (app updates switched on, packages
    // fetched from GitHub); a throwaway server has none.
    expect((await mailbox.appUpdates())['enabled'], isNot(true));
    final notices = (await mailbox.notices(after: cursor)).notices;
    expect(notices.where((n) => n.title == 'Famio $server ist da'), isEmpty);
    await finish(tester, state);
  });

  testWidgets('#120 crossed changes are kept and shown', (tester) async {
    await addMember('e2e-papa', 'E2E Papa');
    final state = await start(tester);
    final engine = state.engine!;

    // A task, created in the app.
    await openSection(tester, 'Aufgaben');
    await enter(
      tester,
      find.widgetWithText(TextField, 'Neue Aufgabe …'),
      'E2E Konflikt',
    );
    await tap(tester, find.byTooltip('Hinzufügen'));
    await waitFor(tester, find.text('E2E Konflikt'));
    await engine.sync();
    final id = engine
        .records(Collections.tasks)
        .firstWhere((r) => r.data['title'] == 'E2E Konflikt')
        .id;
    addTearDown(() async => remove(await admin(), Collections.tasks, [id]));

    // The father's phone has it and goes offline.
    final papaApi = await signedIn('e2e-papa');
    final offline = (await fetch(
      papaApi,
      Collections.tasks,
    )).firstWhere((r) => r.id == id);

    // Changed in the app meanwhile …
    await tap(tester, find.text('E2E Konflikt'));
    await waitFor(tester, find.text('Aufgabe bearbeiten'));
    await enter(
      tester,
      find.widgetWithText(TextField, 'Titel'),
      'E2E Konflikt (Admin)',
    );
    await tap(tester, find.text('Speichern').last);
    await waitFor(tester, find.text('E2E Konflikt (Admin)'));
    await engine.sync();
    await tester.pump(const Duration(seconds: 1));

    // … and on the father's phone, from the old version, a bit later.
    await put(papaApi, Collections.tasks, {
      id: {...offline.data, 'title': 'E2E Konflikt (Papa)'},
    }, rev: offline.rev);
    await waitFor(tester, find.text('E2E Konflikt (Papa)'));

    // The start page points to it; the app's version comes back.
    await openSection(tester, 'Start');
    await scrollTo(
      tester,
      find.text('Eine Änderung hat sich überschnitten – bitte ansehen'),
    );
    await tap(
      tester,
      find.text('Eine Änderung hat sich überschnitten – bitte ansehen'),
    );
    await waitFor(tester, find.text('Aufgabe: E2E Konflikt (Papa)'));
    await waitFor(
      tester,
      find.textContaining('Behalten: die Fassung von E2E Papa'),
    );
    await tap(tester, find.text('Fassung von dir zurückholen'));
    await waitFor(tester, find.text('Nichts zu entscheiden.'));
    await engine.sync();
    final now = (await fetch(
      papaApi,
      Collections.tasks,
    )).firstWhere((r) => r.id == id);
    expect(now.data['title'], 'E2E Konflikt (Admin)');
    expect(await fetch(papaApi, Collections.conflicts), isEmpty);
    await back(tester);
    await finish(tester, state);
  });

  testWidgets('#195 CalDAV keeps what a calendar app sets by PROPPATCH', (
    tester,
  ) async {
    final state = await start(tester);
    await openSection(tester, 'Kalender');
    await tap(tester, find.byTooltip('Mit Google/Apple Kalender verbinden'));
    await scrollTo(tester, find.text('App-Passwort erstellen'));
    final user = tester
        .widget<SelectableText>(
          find
              .descendant(
                of: find.widgetWithText(ListTile, 'Benutzername'),
                matching: find.byType(SelectableText),
              )
              .first,
        )
        .data!;
    await tap(tester, find.text('App-Passwort erstellen'));
    await enter(
      tester,
      find.widgetWithText(TextField, 'Für welches Gerät?'),
      'E2E Kalender',
    );
    await tap(tester, find.text('Erstellen').last);
    // A calendar password keeps access: the account password comes first.
    await enter(tester, find.widgetWithText(TextField, 'Passwort'), _password);
    await tap(tester, find.text('Bestätigen'));
    await waitFor(tester, find.text('Dein App-Passwort'));
    final secret = tester
        .widget<SelectableText>(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(SelectableText),
          ),
        )
        .data!
        .trim();
    await tap(tester, find.text('Fertig'));
    await dialogClosed(tester);
    addTearDown(() async {
      final api = state.engine?.api ?? await admin();
      for (final p in await api.appPasswords()) {
        if (p.name == 'E2E Kalender') await api.deleteAppPassword(p.id);
      }
    });

    final client = HttpClient();
    addTearDown(client.close);
    Future<(int, String)> dav(String method, String body) async {
      final request = await client.openUrl(
        method,
        Uri.parse(_url).resolve('dav/calendars/$user/famio/'),
      );
      request.headers
        ..set(
          'authorization',
          'Basic ${base64.encode(utf8.encode('$user:$secret'))}',
        )
        ..set('content-type', 'application/xml; charset=utf-8');
      if (method == 'PROPFIND') request.headers.set('depth', '0');
      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      return (
        response.statusCode,
        await response.transform(utf8.decoder).join(),
      );
    }

    String update(String set, [String remove = '']) =>
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propertyupdate xmlns:d="DAV:" xmlns:a="http://apple.com/ns/ical/">'
        '${set.isEmpty ? '' : '<d:set><d:prop>$set</d:prop></d:set>'}'
        '${remove.isEmpty ? '' : '<d:remove><d:prop>$remove</d:prop></d:remove>'}'
        '</d:propertyupdate>';
    const ask =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:" xmlns:a="http://apple.com/ns/ical/"><d:prop>'
        '<d:displayname/><a:calendar-color/><a:calendar-order/>'
        '</d:prop></d:propfind>';

    final (before, beforeBody) = await dav('PROPFIND', ask);
    expect(before, 207, reason: beforeBody);
    expect(beforeBody, isNot(contains('E2E Familie')));
    final (patched, patchBody) = await dav(
      'PROPPATCH',
      update(
        '<a:calendar-color>#FF2968FF</a:calendar-color>'
        '<a:calendar-order>3</a:calendar-order>'
        '<d:displayname>E2E Familie</d:displayname>',
      ),
    );
    expect(patched, 207, reason: patchBody);
    expect(patchBody, contains('200 OK'));
    final (_, after) = await dav('PROPFIND', ask);
    expect(after, contains('#FF2968FF'));
    expect(after, contains('>3</'));
    expect(after, contains('<d:displayname>E2E Familie</d:displayname>'));
    // Removed again: the order goes, the name stays.
    await dav('PROPPATCH', update('', '<a:calendar-order/>'));
    final (_, removed) = await dav('PROPFIND', ask);
    expect(removed, isNot(contains('>3</')));
    expect(removed, contains('E2E Familie'));
    await back(tester);
    await finish(tester, state);
  });

  // --- administration -------------------------------------------------------

  testWidgets('#155 integrations show their state ("Einrichten")', (
    tester,
  ) async {
    final state = await start(tester);
    final api = state.engine!.api;
    await openAdmin(tester, 'Einstellungen');
    await waitFor(tester, find.text('Öffentliche Adresse'));
    for (final (title, subtitle) in [
      (
        'Single Sign-On (OpenID Connect)',
        'Anmelden mit Authentik, Keycloak, Authelia, Google, Microsoft …',
      ),
      ('Paperless-ngx', 'Familiendokumente aus Paperless-ngx anzeigen'),
      (
        'PhotoVault',
        'Fotos für Erinnerungen und Wandanzeige, Chat-Fotos als Beiträge, '
            'Geburtstage aus dem Stammbaum',
      ),
      (
        'App-Updates über den Server',
        'Android, Windows und Linux holen neue Versionen vom Famio-Server',
      ),
    ]) {
      await scrollTo(tester, find.text(title));
      final tile = find.ancestor(
        of: find.text(title),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: tile, matching: find.text(subtitle)),
        findsOneWidget,
        reason: title,
      );
      expect(
        find.descendant(
          of: tile,
          matching: find.widgetWithText(TextButton, 'Einrichten'),
        ),
        findsOneWidget,
        reason: title,
      );
    }
    // The same as the server says: nothing set up.
    expect((await api.ssoConfig())['configured'], isNot(true));
    expect((await api.paperless())['connected'], isNot(true));
    expect((await api.photoVault())['connected'], isNot(true));
    expect((await api.appUpdates())['enabled'], isNot(true));
    await back(tester);
    await finish(tester, state);
  });

  testWidgets('#149 #125 setup checklist checks the address, no false alarms', (
    tester,
  ) async {
    await addMember('e2e-ohneapp', 'E2E Ohne App');
    addTearDown(
      () async => (await admin()).updateServerSettings({
        'publicUrl': null,
        'holidayRegion': null,
      }),
    );
    var state = await start(tester);

    // The public address and the state for holidays.
    await openAdmin(tester, 'Einstellungen');
    await enter(
      tester,
      find.widgetWithText(TextField, 'Öffentliche Adresse'),
      _newUrl,
    );
    await scrollTo(tester, find.text('Keine Feiertage'));
    await tap(tester, find.text('Keine Feiertage'));
    await tap(tester, find.text('Berlin').last);
    await scrollTo(tester, find.text('Speichern'));
    await tap(tester, find.text('Speichern'));
    await waitFor(tester, find.text('Servereinstellungen gespeichert'));

    Finder checklist(String text) => find.descendant(
      of: find.byType(SetupChecklist),
      matching: find.text(text),
    );
    Future<String> detail(String step) async {
      await scrollTo(tester, checklist(step));
      final row = find.ancestor(
        of: checklist(step),
        matching: find.byType(Row),
      );
      return [
        for (final e
            in find
                .descendant(of: row.first, matching: find.byType(Text))
                .evaluate())
          (e.widget as Text).data ?? '',
      ].join(' ');
    }

    // Signed in over the home network: the address leads back to this
    // machine, and the checklist says so instead of "does not answer".
    await tap(tester, find.text('Status').last);
    await waitFor(tester, find.textContaining(' erledigt'));
    final address = await detail('Öffentliche Adresse');
    expect(address, contains('zu ihm selbst'));
    expect(address, isNot(contains('antwortet dem Server nicht')));
    expect(
      await detail('Bundesland für Feiertage'),
      contains('Feiertage und Schulferien erscheinen im Kalender.'),
    );
    expect(await detail('Familie eingeladen'), contains('Mitglieder.'));
    // A member without the app is no gap in the notifications.
    final push = await detail('Benachrichtigungen erreichen alle');
    expect(push, contains('Ohne Famio-App:'));
    expect(push, contains('E2E Ohne App'));
    expect(
      RegExp('Noch nicht erreichbar: [^.]*E2E Ohne App').hasMatch(push),
      isFalse,
      reason: push,
    );
    // Leave a step as it is, and show it again.
    const step = 'Zwei-Faktor für dich';
    await scrollTo(tester, checklist(step));
    await tap(
      tester,
      find.descendant(
        of: find
            .ancestor(of: checklist(step), matching: find.byType(Row))
            .first,
        matching: find.text('Ignorieren'),
      ),
    );
    await scrollTo(tester, checklist('$step · Ignoriert'));
    await tap(tester, checklist('Wieder anzeigen'));
    await scrollTo(tester, checklist(step));
    expect(checklist('$step · Ignoriert'), findsNothing);
    await back(tester);
    await finish(tester, state);

    // Signed in through that address: the app confirms it from here.
    state = await start(tester, url: _newUrl);
    await openAdmin(tester, 'Status');
    await waitFor(tester, find.textContaining(' erledigt'));
    final confirmed = await detail('Öffentliche Adresse');
    expect(confirmed, contains('Von diesem Gerät aus ist'));
    expect(confirmed, contains('über HTTPS erreichbar.'));
    await back(tester);
    await finish(tester, state);
  });

  testWidgets('#269 time zone of the family: Africa/Accra and back', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final start14 = DateTime.utc(now.year, now.month, now.day, 14);
    final eventId = uid('event');
    await put(await admin(), Collections.events, {
      eventId: CalendarEvent(
        id: eventId,
        title: 'E2E Zeitzone',
        start: start14,
        end: start14.add(const Duration(hours: 1)),
      ).toData(),
    });
    addTearDown(() async {
      final api = await admin();
      await api.updateServerSettings({'timeZone': null});
      await remove(api, Collections.events, [eventId]);
    });
    final state = await start(tester);
    Finder at(String time) => find.byWidgetPredicate(
      (w) =>
          w is Text &&
          (w.data == '$time E2E Zeitzone' ||
              (w.data?.startsWith('$time\n') ?? false)),
    );
    final berlin = berlinHour(start14);

    await openSection(tester, 'Kalender');
    await waitFor(tester, find.text('E2E Zeitzone'));
    await waitFor(tester, at(berlin));

    Future<void> zone(String typed, String pick) async {
      await openAdmin(tester, 'Einstellungen');
      final field = find.widgetWithText(TextField, 'Zeitzone');
      await scrollTo(tester, field);
      await enter(tester, field, typed);
      // The list of zones comes from the server.
      await tap(tester, find.text(pick).last);
      await scrollTo(tester, find.text('Speichern'));
      await tap(tester, find.text('Speichern'));
      await waitFor(tester, find.text('Servereinstellungen gespeichert'));
      await back(tester);
    }

    Future<void> calendar() async {
      await openSection(tester, 'Kalender');
      await waitFor(tester, find.text('E2E Zeitzone'));
    }

    // Accra: no daylight saving, UTC all year.
    await zone('Accra', 'Africa/Accra');
    expect(
      (await state.engine!.api.adminOverview()).settings.timeZone,
      'Africa/Accra',
    );
    // The server tells the apps; the calendar follows by itself.
    await calendar();
    await waitFor(tester, at('14:00'), timeout: const Duration(seconds: 15));
    expect(at(berlin), findsNothing);

    // And back.
    await zone('Berlin', 'Europe/Berlin');
    await calendar();
    await waitFor(tester, at(berlin), timeout: const Duration(seconds: 15));
    expect(at('14:00'), findsNothing);
    await finish(tester, state);
  });

  testWidgets('#177 two-factor login required for admins or all adults', (
    tester,
  ) async {
    await addMember('e2e-erwachsen', 'E2E Erwachsen');
    await addMember('e2e-kind', 'E2E Kind', role: MemberRole.child);
    // A second admin with an authenticator, to set it back afterwards.
    final admin2 = await addMember(
      'e2e-admin2',
      'E2E Admin Zwei',
      isAdmin: true,
    );
    final admin2Api = await signedIn('e2e-admin2');
    final (:secret, uri: _) = await admin2Api.beginTotp(
      password: _memberPassword,
    );
    final codes = await admin2Api.confirmTotp(totp(secret));
    final strong = FamioApiClient(_url);
    try {
      await strong.login(username: 'e2e-admin2', password: _memberPassword);
      fail('two-factor login expected');
    } on TwoFactorRequired catch (challenge) {
      await strong.loginTwoFactor(
        challenge: challenge.challenge,
        code: codes.first,
      );
    }
    addTearDown(() async {
      // Back to no policy first, so that the members can be removed.
      await strong.updateServerSettings({'twoFactorRequired': null});
      try {
        await (await admin()).deleteMember(admin2.id);
      } on ApiError {
        // Gone already.
      }
    });
    final state = await start(tester);
    final adultApi = await signedIn('e2e-erwachsen');
    final childApi = await signedIn('e2e-kind');

    // Required for administrators.
    await openAdmin(tester, 'Einstellungen');
    await waitFor(tester, find.text('Öffentliche Adresse'));
    await scrollTo(tester, find.text('Nicht verlangt'));
    await tap(tester, find.text('Nicht verlangt'));
    await tap(tester, find.text('Für Administratoren').last);
    await scrollTo(tester, find.text('Speichern'));
    await tap(tester, find.text('Speichern'));
    await waitFor(tester, find.text('Servereinstellungen gespeichert'));
    expect(
      (await strong.adminOverview()).settings.twoFactorRequired,
      TwoFactorPolicy.admins,
    );
    // Adults and children carry on.
    await adultApi.members();
    await childApi.members();

    // The admin without a second factor has to set it up now: saving
    // makes the apps sync, and the app shows nothing but the setup.
    await waitFor(
      tester,
      find.textContaining(
        'Ein Administrator hat die Zwei-Faktor-Anmeldung für dein Konto '
        'eingeschaltet. Richte sie jetzt ein',
      ),
    );
    await waitFor(tester, find.text('Zwei-Faktor-Anmeldung'));

    // For all adults (set by the other admin): the adult has to as well,
    // the child does not.
    await strong.updateServerSettings({'twoFactorRequired': 'adults'});
    await expectLater(
      adultApi.members(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'code',
          'two_factor_setup_required',
        ),
      ),
    );
    await childApi.members();

    // Signing out is still possible on the gate.
    await tap(tester, find.byTooltip('Abmelden'));
    await waitFor(tester, find.text('Verbinden'));
    await strong.updateServerSettings({'twoFactorRequired': null});
    await adultApi.members();
    await finish(tester, state);
  });
}
