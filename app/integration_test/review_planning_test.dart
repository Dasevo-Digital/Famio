// End-to-end acceptance test of the planning features against a throwaway
// server, one test per feature:
//
//   tool/integration_tests.sh macos integration_test/review_planning_test.dart
//
// Tasks for several people and who sees them, the holiday mode, common free
// time, contracts, savings goals, the family inbox, substitutes during
// absences and overlapping absences, the first visit's tip, gift ideas, the
// school bag check, loans, the trash and confirmed responsibilities. Other
// members are created through the API; what they receive is checked with
// their own API session.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/deadlines.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/widgets/member_avatar.dart';
import 'package:famio/src/widgets/section_tips.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'fresh_start.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');
const _fingerprint = String.fromEnvironment('FAMIO_FINGERPRINT');
String? get _pin => _fingerprint.isEmpty ? null : _fingerprint;

/// Password of the members this test creates on the throwaway server.
const _memberPassword = 'e2e-member-123';

/// The display name of the server's first account (tool/integration_tests.sh).
const _adminName = 'Admin';

/// The family next to the admin: two adults, a guest and a child account.
class _Family {
  _Family(this.admin, this.bea, this.carl, this.guest, this.kid);

  final FamioApiClient admin;
  final FamilyMember bea, carl, guest, kid;
}

void main() {
  // The tests read German texts, whatever the device speaks.
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final de = lookupL10n(const Locale('de'));
  // Lazily: the locale data is loaded in startApp.
  late final day = DateFormat.yMd('de');

  Future<_Family>? family;
  final sessions = <String, FamioApiClient>{};

  Future<_Family> createFamily() async {
    final admin = FamioApiClient(_url, pinnedCertificate: _pin);
    await admin.login(username: _user, password: _password, device: 'e2e');
    Future<FamilyMember> member(String user, String name, MemberRole role) =>
        admin.createMember(
          username: user,
          displayName: name,
          password: _memberPassword,
          role: role,
        );
    return _Family(
      admin,
      await member('e2e-bea', 'E2E Bea', MemberRole.adult),
      await member('e2e-carl', 'E2E Carl', MemberRole.adult),
      await member('e2e-gast', 'E2E Gast', MemberRole.guest),
      await member('e2e-kind', 'E2E Kind', MemberRole.child),
    );
  }

  Future<_Family> theFamily() => family ??= createFamily();

  /// An API session of [m], to see what the server gives that member.
  Future<FamioApiClient> sessionOf(FamilyMember m) async {
    final known = sessions[m.id];
    if (known != null) return known;
    final api = FamioApiClient(_url, pinnedCertificate: _pin);
    await api.login(
      username: m.username,
      password: _memberPassword,
      device: 'e2e',
    );
    return sessions[m.id] = api;
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
      since = r.rev;
      if (!r.hasMore) return out;
    }
  }

  Future<Set<String>> titlesOf(FamioApiClient api, String collection) async =>
      {for (final r in (await pull(api, collection)).values) '${r.data['title']}'};

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

  /// Polls [check] (e.g. what another member gets from the server) while
  /// the app keeps running.
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

  /// Dialogs animate out; taps before that hit the fading barrier.
  Future<void> dialogClosed(WidgetTester tester) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (find.byType(Dialog).evaluate().isNotEmpty &&
        DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Lists build only what is near the screen: drags the page (right of
  /// the side rail) until [finder] exists, first down (or [up]), then the
  /// other way.
  Future<void> scrollTo(
    WidgetTester tester,
    Finder finder, {
    bool up = false,
  }) async {
    for (final towardsTop in [up, !up]) {
      for (var i = 0; i < 15 && finder.evaluate().isEmpty; i++) {
        await tester.dragFrom(
          const Offset(500, 380),
          Offset(0, towardsTop ? 220 : -220),
        );
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    await waitFor(tester, finder, timeout: const Duration(seconds: 3));
  }

  /// Some dialogs dispose their text fields as soon as they return; a field
  /// that still has the focus then rebuilds while the dialog fades out and
  /// trips a debug assertion that breaks the widget tree. Leaving the field
  /// first (as with Tab) keeps the test on the feature itself.
  Future<void> leaveField(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Sections in the side rail; on phones an icon in the bar (tooltip) or
  /// behind "Mehr". With [keepTip] the first visit's tip stays open.
  Future<void> openSection(
    WidgetTester tester,
    String label, {
    bool keepTip = false,
  }) async {
    // A snack bar (e.g. "… gelöscht") lies over the lower rail entries.
    if (find.byType(SnackBar).evaluate().isNotEmpty) {
      await waitGone(
        tester,
        find.byType(SnackBar),
        timeout: const Duration(seconds: 15),
      );
    }
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
    await tester.pump(const Duration(milliseconds: 500));
    if (!keepTip && find.text(de.tipGotIt).evaluate().isNotEmpty) {
      await tap(tester, find.text(de.tipGotIt).last);
    }
  }

  Future<void> back(WidgetTester tester) =>
      tap(tester, find.byTooltip(de.commonBack).last);

  /// The Material date picker, typed in instead of tapping a calendar.
  Future<void> pickDate(WidgetTester tester, DateTime date) async {
    await tap(tester, find.byTooltip('Zur Texteingabe wechseln'));
    await enter(
      tester,
      find.widgetWithText(TextField, 'Datum eingeben'),
      day.format(date),
    );
    await tap(tester, find.text('OK').last);
    await waitGone(tester, find.widgetWithText(TextField, 'Datum eingeben'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The Material date range picker, typed in.
  Future<void> pickRange(WidgetTester tester, DateTime from, DateTime to) async {
    await tap(tester, find.byTooltip('Zur Texteingabe wechseln'));
    await enter(
      tester,
      find.widgetWithText(TextField, 'Startdatum'),
      day.format(from),
    );
    await enter(
      tester,
      find.widgetWithText(TextField, 'Enddatum'),
      day.format(to),
    );
    await tap(tester, find.text('OK').last);
    // The app's own dialog follows.
    await tester.pump(const Duration(milliseconds: 800));
  }

  /// Opens the drop-down labelled [label] and picks [item].
  Future<void> choose(WidgetTester tester, String label, String item) async {
    await tap(
      tester,
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
      ),
    );
    await tap(tester, find.text(item).last);
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Starts the app signed out and signs in as the admin.
  Future<AppState> startApp(WidgetTester tester) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    await initializeDateFormatting('de');
    await freshStart();
    final state = AppState();
    await state.init();
    // Also when the test fails half-way: the next one starts signed out.
    addTearDown(state.signOut);
    await tester.pumpWidget(FamioApp(state: state));
    if (state.me == null) {
      await enter(
        tester,
        find.widgetWithText(TextField, 'Server-Adresse'),
        _url,
      );
      await tap(tester, find.text('Verbinden'));
      if (_fingerprint.isNotEmpty) {
        await waitFor(tester, find.text('Zertifikat des Servers prüfen'));
        await tap(tester, find.text('Stimmt überein'));
      }
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
    // The start page of a signed-in adult.
    await waitFor(tester, find.byTooltip(de.inboxTitle));
    return state;
  }

  Future<void> finish(WidgetTester tester, AppState state) async {
    await state.signOut();
    await tester.pump(const Duration(seconds: 1));
  }

  /// A new task through the editor; [audience] is a choice of "Wer darf es
  /// sehen?", [seers] the people picked for "Ich und …".
  Future<void> newTask(
    WidgetTester tester,
    String title, {
    List<String> assignees = const [],
    String? audience,
    List<String> seers = const [],
  }) async {
    await tap(tester, find.byTooltip(de.tasksCreateTaskDetails));
    final titleField = find.widgetWithText(TextField, de.commonTitle);
    await enter(tester, titleField, title);
    for (final name in assignees) {
      await tap(tester, find.widgetWithText(FilterChip, name).first);
    }
    if (audience != null) {
      await tap(tester, find.text(de.tasksMoreOptions));
      await tap(tester, find.text(audience));
      for (final name in seers) {
        await tap(tester, find.widgetWithText(FilterChip, name).last);
      }
    }
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, titleField);
    await waitFor(tester, find.text(title));
  }

  /// The card around [text] (task tile, trash entry …).
  Finder cardOf(String text) =>
      find.ancestor(of: find.text(text), matching: find.byType(SoftCard)).first;

  DateTime today() => DateUtils.dateOnly(DateTime.now());
  DateTime inDays(int n) => DateUtils.addDaysToDate(today(), n);

  testWidgets('#159 tasks: several people, who may see it, guests', (
    tester,
  ) async {
    final f = await theFamily();
    final state = await startApp(tester);
    await openSection(tester, 'Aufgaben');

    await newTask(
      tester,
      'E2E Garage aufräumen',
      assignees: [_adminName, f.bea.displayName],
    );
    await newTask(
      tester,
      'E2E Gastaufgabe',
      assignees: [f.guest.displayName],
    );
    await newTask(tester, 'E2E Nur für mich', audience: de.docsOnlyMe);
    await newTask(
      tester,
      'E2E Für den Gast',
      audience: de.docsMe,
      seers: [f.guest.displayName],
    );

    // Two people on one task; a lock on the restricted ones.
    expect(
      find.descendant(
        of: cardOf('E2E Garage aufräumen'),
        matching: find.byType(MemberAvatar),
      ),
      findsNWidgets(2),
    );
    for (final t in ['E2E Nur für mich', 'E2E Für den Gast']) {
      expect(
        find.descendant(of: cardOf(t), matching: find.byIcon(AppIcons.lockKey)),
        findsOneWidget,
        reason: t,
      );
    }
    final garage = state.engine!.tasks.singleWhere(
      (t) => t.title == 'E2E Garage aufräumen',
    );
    expect(garage.assigneeIds.toSet(), {state.me!.id, f.bea.id});
    expect(garage.visibleTo, isNull);
    final private = state.engine!.tasks.singleWhere(
      (t) => t.title == 'E2E Nur für mich',
    );
    expect(private.visibleTo, [state.me!.id]);

    // The guest gets only what is assigned or shown to them.
    final guest = await sessionOf(f.guest);
    late Set<String> guestTasks;
    await eventually(tester, 'guest receives the shared tasks', () async {
      guestTasks = await titlesOf(guest, Collections.tasks);
      return guestTasks.containsAll(['E2E Gastaufgabe', 'E2E Für den Gast']);
    });
    expect(guestTasks, isNot(contains('E2E Garage aufräumen')));
    expect(guestTasks, isNot(contains('E2E Nur für mich')));

    // Another adult sees the family's tasks, not the restricted ones.
    final bea = await sessionOf(f.bea);
    final beaTasks = await titlesOf(bea, Collections.tasks);
    expect(beaTasks, containsAll(['E2E Garage aufräumen', 'E2E Gastaufgabe']));
    expect(beaTasks, isNot(contains('E2E Nur für mich')));
    expect(beaTasks, isNot(contains('E2E Für den Gast')));

    for (final t in state.engine!.tasks.toList()) {
      if (t.title.startsWith('E2E')) state.engine!.deleteTask(t.id);
    }
    await finish(tester, state);
  });

  testWidgets('#174 holiday mode', (tester) async {
    final f = await theFamily();
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Ämter');

    // A chore for the child, due today.
    await tap(tester, find.byTooltip(de.choresCreateChore));
    final what = find.widgetWithText(TextField, de.choresWhatNeedsDoing);
    await enter(tester, what, 'E2E Blumen gießen');
    await tap(tester, find.text(f.kid.displayName).last);
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, what);
    await waitFor(tester, find.textContaining('E2E Blumen gießen'));

    // A holiday from today with paused pocket money.
    await tap(tester, find.byTooltip(de.vacationTitle));
    await waitFor(tester, find.text(de.vacationNone));
    await tap(tester, find.text(de.vacationAdd));
    final to = inDays(3);
    await pickRange(tester, today(), to);
    await enter(
      tester,
      find.widgetWithText(TextField, de.vacationName),
      'E2E Herbstferien',
    );
    await tap(tester, find.text(de.vacationPauseAllowance));
    await tap(tester, find.text(de.commonSave).last);
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Herbstferien'));
    await waitFor(tester, find.textContaining(de.vacationAllowancePaused));
    final holiday = engine.vacations.single;
    expect(holiday.from, today());
    expect(holiday.to, to);
    expect(holiday.allowance, isTrue);

    // Today the chore is not due; the banner says why.
    await back(tester);
    await waitFor(
      tester,
      find.text(de.vacationBanner(DateFormat.MMMEd('de').format(to))),
    );
    await waitGone(tester, find.textContaining('E2E Blumen gießen'));
    expect(find.text(de.kioskFreeToday), findsWidgets);

    // The server keeps it for everyone (and pauses the pocket money there).
    final bea = await sessionOf(f.bea);
    await eventually(tester, 'holiday on the server', () async {
      final v = await pull(bea, Collections.vacations);
      return v.values.any((r) => Vacation.fromRecord(r).allowance);
    });

    // Removed again: the chore is back.
    await tap(tester, find.byTooltip(de.vacationTitle));
    await tap(tester, find.byTooltip(de.commonDelete));
    await waitFor(tester, find.text(de.vacationNone));
    await back(tester);
    await waitFor(tester, find.textContaining('E2E Blumen gießen'));

    for (final c in engine.chores.toList()) {
      if (c.title.startsWith('E2E')) engine.deleteChore(c.id);
    }
    await finish(tester, state);
  });

  testWidgets('#187 when does everyone have time', (tester) async {
    final f = await theFamily();
    final now = DateTime.now();
    final tomorrow = inDays(1);
    // Bea is busy tomorrow morning (her own appointment).
    final bea = await sessionOf(f.bea);
    final busyId = 'e2e-busy-${now.millisecondsSinceEpoch}';
    await bea.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.events,
            id: busyId,
            data: CalendarEvent(
              id: busyId,
              title: 'E2E Termin Bea',
              start: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 8),
              end: DateTime(
                tomorrow.year,
                tomorrow.month,
                tomorrow.day,
                12,
                30,
              ),
              memberIds: [f.bea.id],
            ).toData(),
            updatedAt: now.millisecondsSinceEpoch,
          ),
        ],
      ),
    );

    final state = await startApp(tester);
    await openSection(tester, 'Kalender');
    await tap(tester, find.byTooltip(de.freeTimeTitle));
    await waitFor(tester, find.text(de.freeTimeWho));

    final heading = DateFormat.MMMMEEEEd('de').format(tomorrow);
    final slot = RegExp(r'^\d\d:\d\d – \d\d:\d\d$');
    String firstSlotTomorrow() {
      final texts = [
        for (final e in find.byType(Text).evaluate())
          ?(e.widget as Text).data,
      ];
      final i = texts.indexOf(heading);
      if (i < 0) return '';
      return texts.skip(i + 1).firstWhere(slot.hasMatch, orElse: () => '');
    }

    // Admin, Bea and Carl: tomorrow from 12:30 on.
    await waitFor(tester, find.widgetWithText(FilterChip, f.carl.displayName));
    await scrollTo(tester, find.text(heading));
    await eventually(
      tester,
      'free time after the appointment',
      () async => firstSlotTomorrow() == '12:30 – 13:30',
    );

    // Without Bea the morning is free.
    await scrollTo(
      tester,
      find.widgetWithText(FilterChip, f.bea.displayName),
      up: true,
    );
    await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
    await scrollTo(tester, find.text(heading));
    expect(firstSlotTomorrow(), '08:00 – 09:00');
    await scrollTo(
      tester,
      find.widgetWithText(FilterChip, f.bea.displayName),
      up: true,
    );
    await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
    await scrollTo(tester, find.text(heading));
    expect(firstSlotTomorrow(), '12:30 – 13:30');

    // A tap creates the appointment for these people.
    await tap(tester, find.text('12:30 – 13:30').first);
    final title = find.widgetWithText(TextField, de.commonTitle);
    await enter(tester, title, 'E2E Elternabend');
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, title);
    final event = state.engine!.events.singleWhere(
      (e) => e.title == 'E2E Elternabend',
    );
    expect(
      event.start.isAtSameMomentAs(
        DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 12, 30),
      ),
      isTrue,
      reason: '${event.start}',
    );
    expect(event.end.difference(event.start), const Duration(hours: 1));
    expect(event.memberIds.toSet(), {state.me!.id, f.bea.id, f.carl.id});
    // Now that time is taken as well.
    await scrollTo(tester, find.text(heading));
    await eventually(
      tester,
      'slot taken',
      () async => firstSlotTomorrow() == '13:30 – 14:30',
    );
    await eventually(
      tester,
      'Bea gets the appointment',
      () async =>
          (await titlesOf(bea, Collections.events)).contains('E2E Elternabend'),
    );

    state.engine!.deleteEvent(event.id);
    await finish(tester, state);
  });

  testWidgets('#200 contracts and notice periods', (tester) async {
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsDeadlines));
    await tap(tester, find.text(de.settingsDeadlines));
    await tap(tester, find.byTooltip(de.deadlinesAddDeadline));
    await tap(tester, find.text('📄 Verträge & Abos'));
    await waitFor(tester, find.text(de.contractEnd));
    await enter(
      tester,
      find.widgetWithText(TextField, de.wishesWhat),
      'E2E Handyvertrag',
    );
    // Ends in 30 days (the default), renews yearly, two weeks' notice.
    await tap(tester, find.text(de.contractNoticeNone));
    await tap(tester, find.text(de.contractNoticeWeeks(2)).last);
    await enter(
      tester,
      find.widgetWithText(TextField, de.contractMonthly),
      '19,99',
    );
    await tap(tester, find.text(de.contractInBudget));
    // Remind a month ahead, so it is on the start page right away.
    await tap(tester, find.text(de.deadlinesDaysDaysBefore(14)));
    await tap(tester, find.text(de.deadlinesDaysDaysBefore(30)).last);
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.deadlinesNewDeadline));

    final end = inDays(30);
    final cancelBy = DateTime(end.year, end.month, end.day - 14);
    await waitFor(tester, find.text('E2E Handyvertrag'));
    await waitFor(
      tester,
      find.textContaining(de.contractCancelBy(day.format(cancelBy))),
    );
    await waitFor(
      tester,
      find.textContaining(de.contractPerMonth(formatEuro(1999))),
    );
    final contract = engine.deadlines.singleWhere(
      (d) => d.title == 'E2E Handyvertrag',
    );
    expect(contract.isContract, isTrue);
    expect(contract.due, end);
    expect(contract.cancelBy, cancelBy);
    expect(contract.repeatMonths, 12);

    // The monthly amount in the household book.
    final entry = engine.record(
      Collections.budgetEntries,
      'contract-${contract.id}',
    );
    expect(entry, isNotNull);
    final budget = BudgetEntry.fromRecord(entry!);
    expect(budget.cents, 1999);
    expect(budget.monthly, isTrue);
    expect(budget.until, isNull);

    // On the start page, within the reminder lead.
    await openSection(tester, 'Start');
    await scrollTo(tester, find.text('📄 E2E Handyvertrag'));

    // Cancelled: ends with the term, also in the household book.
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsDeadlines));
    await tap(tester, find.text(de.settingsDeadlines));
    await tap(tester, find.byTooltip(de.commonDoneCap));
    await tap(tester, find.text(de.contractCancelled).last);
    await waitFor(
      tester,
      find.text(de.contractCancelledOn(day.format(today()), day.format(end))),
    );
    final until = BudgetEntry.fromRecord(
      engine.record(Collections.budgetEntries, 'contract-${contract.id}')!,
    ).until;
    expect(until, isNotNull);
    expect(DateUtils.dateOnly(until!), end);

    engine.deleteDeadline(contract.id);
    engine.deleteBudgetEntry('contract-${contract.id}');
    await finish(tester, state);
  });

  testWidgets('#201 savings goals for children', (tester) async {
    final f = await theFamily();
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Ämter');
    await tap(tester, find.text(de.settingsAccount));
    await tap(tester, find.text(f.kid.displayName).last);
    await waitFor(tester, find.text(de.savingsGoals));

    // Five euros a week, ten as a present.
    await tap(tester, find.text(de.choresSetPocketMoney));
    await enter(tester, find.widgetWithText(TextField, de.choresPerWeek), '5');
    await leaveField(tester);
    await tap(tester, find.text(de.commonSave).last);
    await dialogClosed(tester);
    Future<void> present(String euros) async {
      await tap(tester, find.text(de.conflictsBooking));
      // The kind in the dialog (the list below names booked kinds too).
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(MoneyKind.gift.label),
        ),
      );
      await enter(tester, find.widgetWithText(TextField, de.commonAmount), euros);
      await leaveField(tester);
      await tap(tester, find.text(de.choresBook).last);
      await dialogClosed(tester);
    }

    await present('10');
    await tap(tester, find.text(de.savingsGoalAdd));
    await enter(
      tester,
      find.widgetWithText(TextField, de.savingsGoalWhat),
      'E2E Fahrrad',
    );
    await enter(
      tester,
      find.widgetWithText(TextField, de.savingsGoalAmount),
      '50',
    );
    await tap(tester, find.text(de.commonSave).last);
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Fahrrad'));

    // Progress from the balance, the day it is enough from the weekly
    // amount (paid on Saturdays by default).
    final balance = engine.moneyBalance(f.kid.id);
    expect(balance, greaterThanOrEqualTo(1000));
    await waitFor(
      tester,
      find.text(
        de.savingsGoalProgress(formatEuro(balance), formatEuro(5000)),
      ),
    );
    final weeks = ((5000 - balance) / 500).ceil();
    var payday = inDays(1);
    while (payday.weekday != DateTime.saturday) {
      payday = DateUtils.addDaysToDate(payday, 1);
    }
    final reached = DateUtils.addDaysToDate(payday, 7 * (weeks - 1));
    await waitFor(
      tester,
      find.text(
        de.savingsGoalWhen(weeks, DateFormat.MMMd('de').format(reached)),
      ),
    );

    // The child may add its own goal, not one for somebody else.
    final kid = await sessionOf(f.kid);
    final ms = DateTime.now().millisecondsSinceEpoch;
    SyncRecord goal(String id, String memberId, String title) => SyncRecord(
      collection: Collections.savingsGoals,
      id: id,
      data: SavingsGoal(
        id: id,
        memberId: memberId,
        title: title,
        targetCents: 3000,
        emoji: '🧸',
      ).toData(),
      updatedAt: ms,
    );
    final reply = await kid.sync(
      SyncRequest(
        since: 0,
        changes: [
          goal('e2e-goal-own-$ms', f.kid.id, 'E2E Lego'),
          goal('e2e-goal-other-$ms', f.bea.id, 'E2E Fremdes Ziel'),
        ],
      ),
    );
    expect(reply.rejected.map((r) => r.id), contains('e2e-goal-other-$ms'));
    await engine.sync();
    await waitFor(tester, find.text('E2E Lego'), timeout: const Duration(seconds: 60));
    final serverGoals = await titlesOf(f.admin, Collections.savingsGoals);
    expect(serverGoals, contains('E2E Lego'));
    expect(serverGoals, isNot(contains('E2E Fremdes Ziel')));

    // Enough saved: bought, the amount is booked off.
    await present(formatEuro(5000 - balance).replaceAll(' €', ''));
    await scrollTo(tester, find.text(de.savingsGoalReached));
    final bike = find.ancestor(
      of: find.text('E2E Fahrrad'),
      matching: find.byType(SoftCard),
    );
    await tap(
      tester,
      find.descendant(of: bike.first, matching: find.text(de.savingsGoalBuy)),
    );
    await tap(tester, find.text(de.savingsGoalBuy).last);
    await dialogClosed(tester);
    await eventually(
      tester,
      'goal bought',
      () async =>
          !engine.savingsGoals(f.kid.id).any((g) => g.title == 'E2E Fahrrad'),
    );
    expect(engine.moneyBalance(f.kid.id), 0);

    for (final g in engine.savingsGoals(f.kid.id)) {
      engine.deleteSavingsGoal(g.id);
    }
    await finish(tester, state);
  });

  testWidgets('#237 family inbox: tile only with content, symbol on top', (
    tester,
  ) async {
    final state = await startApp(tester);
    // Empty: no tile on the start page, but the symbol at the top.
    await tester.pump(const Duration(seconds: 2));
    expect(state.engine!.inboxItems, isEmpty);
    expect(find.text(de.inboxTitle), findsNothing);
    await tap(tester, find.byTooltip(de.inboxTitle));
    await waitFor(tester, find.text(de.inboxEmpty));

    await tap(tester, find.byTooltip(de.inboxAdd));
    final title = find.widgetWithText(TextField, de.commonTitle);
    await enter(tester, title, 'E2E Zettel vom Kindergarten');
    await enter(
      tester,
      find.widgetWithText(TextField, de.commonNotes),
      'Bitte Gummistiefel mitgeben',
    );
    await leaveField(tester);
    await tap(tester, find.text(de.commonSave).last);
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Zettel vom Kindergarten'));

    // With something in it the start page has the tile.
    await back(tester);
    await waitFor(tester, find.text(de.inboxTitle));
    await tap(tester, find.text(de.inboxTitle));

    // Filed as a task: the inbox is empty again.
    await tap(tester, find.byTooltip(de.inboxFileAs));
    await tap(tester, find.text(de.commonTask).last);
    await waitFor(tester, find.text(de.inboxFiled));
    await waitFor(tester, find.text(de.inboxEmpty));
    final task = state.engine!.tasks.singleWhere(
      (t) => t.title == 'E2E Zettel vom Kindergarten',
    );
    expect(task.notes, 'Bitte Gummistiefel mitgeben');
    await back(tester);
    await waitGone(tester, find.text(de.inboxTitle));
    expect(find.byTooltip(de.inboxTitle), findsOneWidget);

    await openSection(tester, 'Aufgaben');
    await waitFor(tester, find.text('E2E Zettel vom Kindergarten'));
    await waitFor(tester, find.textContaining('Bitte Gummistiefel mitgeben'));

    state.engine!.deleteTask(task.id);
    await finish(tester, state);
  });

  testWidgets('#240 substitute sees restricted tasks during the absence', (
    tester,
  ) async {
    final f = await theFamily();
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Aufgaben');
    // Carl's task that only he (and I) may see.
    await newTask(
      tester,
      'E2E Carls Geheimsache',
      assignees: [f.carl.displayName],
      audience: de.docsOnlyMe,
    );
    final bea = await sessionOf(f.bea);
    await eventually(
      tester,
      'task on the server',
      () async => (await titlesOf(
        f.admin,
        Collections.tasks,
      )).contains('E2E Carls Geheimsache'),
    );
    expect(
      await titlesOf(bea, Collections.tasks),
      isNot(contains('E2E Carls Geheimsache')),
    );

    // Carl is away from today, Bea stands in.
    await openSection(tester, 'Ämter');
    await tap(tester, find.byTooltip(de.absenceTitle));
    await tap(tester, find.text(de.absenceAdd));
    await pickRange(tester, today(), inDays(2));
    await choose(tester, de.absencePerson, f.carl.displayName);
    await choose(tester, de.absenceSubstitute, f.bea.displayName);
    await tap(tester, find.text(de.commonSave).last);
    await dialogClosed(tester);
    await waitFor(
      tester,
      find.textContaining(de.absenceSubstituteName(f.bea.displayName)),
    );
    await eventually(
      tester,
      'Bea gets the restricted task',
      () async => (await titlesOf(
        bea,
        Collections.tasks,
      )).contains('E2E Carls Geheimsache'),
    );

    // Absence over (removed): the server takes her out again.
    await tap(tester, find.byTooltip(de.commonDelete));
    await waitFor(tester, find.text(de.absenceNone));
    await eventually(
      tester,
      'Bea loses the task again',
      () async => !(await titlesOf(
        bea,
        Collections.tasks,
      )).contains('E2E Carls Geheimsache'),
    );

    for (final t in engine.tasks.toList()) {
      if (t.title.startsWith('E2E')) engine.deleteTask(t.id);
    }
    await finish(tester, state);
  });

  testWidgets('#241 the first visit tip hides nothing', (tester) async {
    final state = await startApp(tester);

    // Chat: the newest message stays above the tip.
    await openSection(tester, 'Chat', keepTip: true);
    await waitFor(tester, find.text(de.tipChat));
    await tap(tester, find.text('Familie').first);
    for (var i = 1; i <= 3; i++) {
      await enter(
        tester,
        find.widgetWithText(TextField, de.chatMessage),
        'E2E Tipp $i',
      );
      await tap(tester, find.byTooltip(de.commonSend).last);
      await waitFor(tester, find.text('E2E Tipp $i'));
    }
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SectionTipCard), findsOneWidget);
    var tip = tester.getRect(find.byType(SectionTipCard));
    final newest = tester.getRect(find.text('E2E Tipp 3'));
    expect(
      newest.bottom,
      lessThanOrEqualTo(tip.top),
      reason: 'newest message $newest, tip $tip',
    );

    // Tasks: the end of a long list can be scrolled above the tip.
    await openSection(tester, 'Aufgaben', keepTip: true);
    await waitFor(tester, find.text(de.tipTasks));
    for (var i = 1; i <= 8; i++) {
      await enter(
        tester,
        find.widgetWithText(TextField, de.tasksNewTask),
        'E2E Tipp-Aufgabe $i',
      );
      await tap(tester, find.byTooltip(de.commonAdd).first);
      await waitFor(tester, find.text('E2E Tipp-Aufgabe $i'));
    }
    // Scrolled to the end, from the top of the list (the tip would catch
    // a drag that starts on it).
    final top = tester.getCenter(cardOf('E2E Tipp-Aufgabe 8'));
    for (var i = 0; i < 8; i++) {
      await tester.dragFrom(top, const Offset(0, -150));
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.pump(const Duration(seconds: 1));
    tip = tester.getRect(find.byType(SectionTipCard));
    final tiles = find.byWidgetPredicate((w) => w is SoftCard).evaluate().where(
      (e) => find
          .descendant(
            of: find.byType(SectionTipCard),
            matching: find.byWidget(e.widget),
          )
          .evaluate()
          .isEmpty,
    );
    final last = tiles
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        .reduce((a, b) => a.bottom > b.bottom ? a : b);
    expect(
      last.bottom,
      lessThanOrEqualTo(tip.top),
      reason: 'last task $last, tip $tip',
    );

    final engine = state.engine!;
    for (final t in engine.tasks.toList()) {
      if (t.title.startsWith('E2E')) engine.deleteTask(t.id);
    }
    await finish(tester, state);
  });

  testWidgets('#245 gift ideas hidden from that person', (tester) async {
    final f = await theFamily();
    final state = await startApp(tester);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.settingsWishes));
    await tap(tester, find.text(de.settingsWishes));
    await tap(tester, find.widgetWithText(ChoiceChip, f.bea.displayName));
    await waitFor(tester, find.text(de.wishesNoIdeasYet(f.bea.displayName)));

    await tap(tester, find.byTooltip(de.wishesAddIdea));
    await waitFor(tester, find.text(de.wishesNewIdea(f.bea.displayName)));
    await enter(
      tester,
      find.widgetWithText(TextField, de.wishesWhat),
      'E2E Kletterschuhe',
    );
    await tap(tester, find.text(de.commonSave).last);
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Kletterschuhe'));
    await waitFor(tester, find.text(de.wishesYourIdea));
    await waitFor(tester, find.text(de.wishesIdeasHidden(f.bea.displayName)));
    await tap(tester, find.text(de.wishesILlGet));
    await waitFor(tester, find.text(de.wishesYouReGetting));

    // Carl gets the idea, Bea never.
    final carl = await sessionOf(f.carl);
    await eventually(
      tester,
      'Carl gets the idea',
      () async =>
          (await titlesOf(carl, Collections.wishes)).contains('E2E Kletterschuhe'),
    );
    final bea = await sessionOf(f.bea);
    expect(
      await titlesOf(bea, Collections.wishes),
      isNot(contains('E2E Kletterschuhe')),
    );

    final engine = state.engine!;
    for (final r in engine.records(Collections.wishClaims).toList()) {
      engine.delete(Collections.wishClaims, r.id);
    }
    for (final r in engine.records(Collections.wishes).toList()) {
      engine.delete(Collections.wishes, r.id);
    }
    await finish(tester, state);
  });

  testWidgets('#246 school bag check the evening before', (tester) async {
    final tomorrow = inDays(1);
    expect(
      tomorrow.weekday,
      lessThanOrEqualTo(DateTime.friday),
      reason: 'needs a school day tomorrow (run Sunday to Thursday)',
    );
    final state = await startApp(tester);
    final engine = state.engine!;
    // A family holiday would hide the bag; none from the other tests.
    for (final v in engine.vacations) {
      engine.deleteVacation(v.id);
    }
    // Set-up: the child and a family appointment naming her.
    final ms = DateTime.now().millisecondsSinceEpoch;
    engine.saveChild(
      Child(id: 'e2e-child-$ms', name: 'Mia', birthDate: DateTime(2018, 5, 1)),
    );
    engine.saveEvent(
      CalendarEvent(
        id: 'e2e-trip-$ms',
        title: 'Wandertag Mia',
        start: tomorrow,
        end: DateUtils.addDaysToDate(tomorrow, 1),
        allDay: true,
      ),
    );

    await openSection(tester, 'Kinder');
    await tap(tester, find.text('Mia'));
    await tap(tester, find.text(de.commonTimetable));
    await waitFor(tester, find.byType(Table));
    final free = find.descendant(
      of: find.byType(Table),
      matching: find.byIcon(AppIcons.plus),
    );
    Future<void> lesson(Finder cell, String subject, [String? bring]) async {
      await tap(tester, cell);
      await enter(
        tester,
        find.widgetWithText(TextField, de.timetableSubject),
        subject,
      );
      if (bring != null) {
        await enter(
          tester,
          find.widgetWithText(TextField, de.timetableBring),
          bring,
        );
      }
      await tap(tester, find.text(de.commonSave).last);
      await dialogClosed(tester);
    }

    // Tomorrow: Sport first (with sports kit), then maths. In the first row
    // four free cells are left after the first lesson.
    await lesson(free.at(tomorrow.weekday - 1), 'Sport', 'Sportzeug');
    await lesson(free.at(tomorrow.weekday + 3), 'Mathe');

    final summary =
        'Sport, Mathe · ${de.schoolBagBring('Sportzeug')} · Wandertag Mia';
    await scrollTo(tester, find.text(de.timetableForTomorrow));
    await waitFor(tester, find.text(summary));

    // Switched on: reminds at the default time.
    await scrollTo(tester, find.text(de.timetableBagCheck));
    await tap(tester, find.text(de.timetableBagCheck));
    await waitFor(tester, find.text(de.timetableBagCheckOn('18:30')));

    // Not during a family holiday. The page does not listen to holidays,
    // so it is opened again.
    Future<void> reopen() async {
      await scrollTo(tester, find.text(de.kidsTabTimeline), up: true);
      await tap(tester, find.text(de.kidsTabTimeline));
      await tap(tester, find.text(de.commonTimetable));
      await waitFor(tester, find.byType(Table));
    }

    engine.saveVacation(
      Vacation(id: 'e2e-holiday-$ms', from: tomorrow, to: tomorrow),
    );
    await reopen();
    await scrollTo(tester, find.text(de.timetableBagCheck));
    expect(find.text(de.timetableForTomorrow), findsNothing);
    engine.deleteVacation('e2e-holiday-$ms');
    await reopen();
    await scrollTo(tester, find.text(summary));

    engine.deleteEvent('e2e-trip-$ms');
    engine.delete(Collections.timetables, 'e2e-child-$ms');
    engine.delete(Collections.children, 'e2e-child-$ms');
    await finish(tester, state);
  });

  testWidgets('#247 loans with a date to return', (tester) async {
    final state = await startApp(tester);
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.loansTitle));
    await tap(tester, find.text(de.loansTitle));
    await waitFor(tester, find.text(de.loansEmpty));
    await tap(tester, find.byTooltip(de.loansAdd));
    await enter(
      tester,
      find.widgetWithText(TextField, de.loansWhat),
      'E2E Bohrmaschine',
    );
    await enter(
      tester,
      find.widgetWithText(TextField, de.loansToWhom),
      'Nachbarn von nebenan',
    );
    // Should have come back yesterday.
    final due = inDays(-1);
    await tap(tester, find.text(de.loansDueBack));
    await pickDate(tester, due);
    await waitFor(tester, find.text(day.format(due)));
    await tap(tester, find.text(de.commonSave).last);
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Bohrmaschine'));
    await waitFor(tester, find.text(de.loansLentOut));
    await waitFor(
      tester,
      find.textContaining(de.loansLentTo('Nachbarn von nebenan')),
    );
    await waitFor(tester, find.text(de.loansOverdueSince(day.format(due))));

    // While something is out, the start page has a tile.
    await openSection(tester, 'Start');
    await scrollTo(tester, find.text(de.loansTitle));
    await waitFor(tester, find.text(de.loansOverdueCount(1)));
    await waitFor(tester, find.text(de.loansLentCount(1)));

    // Back: no tile any more.
    await tap(tester, find.text(de.loansTitle));
    await tap(tester, find.byTooltip(de.loansMarkReturned));
    await waitFor(tester, find.text(de.loansReturnedHeading));
    await openSection(tester, 'Start');
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 8; i++) {
      await tester.dragFrom(const Offset(500, 300), const Offset(0, 300));
      await tester.pump(const Duration(milliseconds: 200));
    }
    var tile = true;
    try {
      await scrollTo(tester, find.text(de.loansTitle));
    } on TestFailure {
      tile = false;
    }
    expect(tile, isFalse, reason: 'loans tile still on the start page');

    final engine = state.engine!;
    for (final r in engine.records(Collections.loans).toList()) {
      engine.delete(Collections.loans, r.id);
    }
    await finish(tester, state);
  });

  testWidgets('#256 overlapping absences give one substitute', (tester) async {
    final f = await theFamily();
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Aufgaben');
    await newTask(
      tester,
      'E2E Carls Wochenaufgabe',
      assignees: [f.carl.displayName],
      audience: de.docsOnlyMe,
    );

    // Carl is away four days, Bea stands in.
    await openSection(tester, 'Ämter');
    await tap(tester, find.byTooltip(de.absenceTitle));
    await tap(tester, find.text(de.absenceAdd));
    await pickRange(tester, today(), inDays(3));
    await choose(tester, de.absencePerson, f.carl.displayName);
    await choose(tester, de.absenceSubstitute, f.bea.displayName);
    await tap(tester, find.text(de.commonSave).last);
    await dialogClosed(tester);
    await waitFor(
      tester,
      find.textContaining(de.absenceSubstituteName(f.bea.displayName)),
    );
    final bea = await sessionOf(f.bea);
    await eventually(
      tester,
      'Bea stands in',
      () async => (await titlesOf(
        bea,
        Collections.tasks,
      )).contains('E2E Carls Wochenaufgabe'),
    );

    // A second, overlapping entry for Carl is refused.
    await tap(tester, find.text(de.absenceAdd));
    await pickRange(tester, inDays(1), inDays(5));
    await choose(tester, de.absencePerson, f.carl.displayName);
    await waitFor(tester, find.text(de.absenceOverlap));
    final save = find.widgetWithText(FilledButton, de.commonSave);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    // Somebody else in that time is fine.
    await choose(tester, de.absencePerson, f.guest.displayName);
    await waitGone(tester, find.text(de.absenceOverlap));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tap(tester, find.text(de.commonCancel).last);
    await dialogClosed(tester);

    // An overlap from another device (offline): same start, shorter, with
    // me standing in. The later or shorter entry decides, in the app and
    // on the server alike.
    final ms = DateTime.now().millisecondsSinceEpoch;
    final second = MemberAbsence(
      id: 'e2e-absence-$ms',
      memberId: f.carl.id,
      from: today(),
      to: inDays(1),
      substituteId: state.me!.id,
    );
    final reply = await f.admin.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.absences,
            id: second.id,
            data: second.toData(),
            updatedAt: ms,
          ),
        ],
      ),
    );
    expect(reply.rejected, isEmpty);
    await eventually(
      tester,
      'both absences in the app',
      () async => engine.absences.length == 2,
    );
    expect(
      absenceFor(engine.absences, f.carl.id, today())?.substituteId,
      state.me!.id,
    );
    // The app shows the task as mine today …
    await openSection(tester, 'Aufgaben');
    await tap(tester, find.text(de.tasksFilterMine));
    await waitFor(tester, find.text('E2E Carls Wochenaufgabe'));
    // … and the server no longer lets Bea see it.
    await eventually(
      tester,
      'Bea no longer sees the task',
      () async => !(await titlesOf(
        bea,
        Collections.tasks,
      )).contains('E2E Carls Wochenaufgabe'),
    );

    for (final a in engine.absences) {
      engine.deleteAbsence(a.id);
    }
    for (final t in engine.tasks.toList()) {
      if (t.title.startsWith('E2E')) engine.deleteTask(t.id);
    }
    await finish(tester, state);
  });

  testWidgets('#266 trash: delete, restore in the settings', (tester) async {
    final f = await theFamily();
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Aufgaben');
    await newTask(tester, 'E2E Papierkorb-Aufgabe');
    await newTask(tester, 'E2E Papierkorb privat', audience: de.docsOnlyMe);
    for (final title in ['E2E Papierkorb-Aufgabe', 'E2E Papierkorb privat']) {
      await tap(tester, find.text(title));
      await tap(tester, find.text(de.commonDelete).last);
      await waitFor(tester, find.text(de.undoWhatDeleted(title)));
      await waitGone(tester, find.text(title));
    }
    await engine.sync();

    // Bea finds the family's task in the trash, not my private one.
    final bea = await sessionOf(f.bea);
    final beaTrash = {for (final e in (await bea.trash()).items) e.title};
    expect(beaTrash, contains('E2E Papierkorb-Aufgabe'));
    expect(beaTrash, isNot(contains('E2E Papierkorb privat')));

    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.trashTitle));
    await tap(tester, find.text(de.trashTitle));
    await waitFor(tester, find.text('E2E Papierkorb-Aufgabe'));
    await waitFor(tester, find.text('E2E Papierkorb privat'));
    final kept = DateTime.now().add(const Duration(days: 30));
    expect(
      find.descendant(
        of: cardOf('E2E Papierkorb-Aufgabe'),
        matching: find.text(
          '${de.assignmentTask} · ${de.trashExpires(day.format(kept))}',
        ),
      ),
      findsOneWidget,
    );
    await tap(
      tester,
      find.descendant(
        of: cardOf('E2E Papierkorb-Aufgabe'),
        matching: find.text(de.trashRestore),
      ),
    );
    await waitFor(tester, find.text(de.trashRestored));
    await waitGone(tester, find.text('E2E Papierkorb-Aufgabe'));

    // Back in the tasks, also on Bea's devices.
    await openSection(tester, 'Aufgaben');
    await waitFor(tester, find.text('E2E Papierkorb-Aufgabe'));
    await eventually(
      tester,
      'Bea gets the task back',
      () async => (await titlesOf(
        bea,
        Collections.tasks,
      )).contains('E2E Papierkorb-Aufgabe'),
    );

    for (final t in engine.tasks.toList()) {
      if (t.title.startsWith('E2E')) engine.deleteTask(t.id);
    }
    await finish(tester, state);
  });

  testWidgets('#267 confirmed responsibilities', (tester) async {
    final f = await theFamily();
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Aufgaben');

    // Due tomorrow, for me and Bea, with confirmation and a reminder.
    await tap(tester, find.byTooltip(de.tasksCreateTaskDetails));
    final titleField = find.widgetWithText(TextField, de.commonTitle);
    await enter(tester, titleField, 'E2E Rasen mähen');
    await tap(tester, find.text(de.tasksDue));
    await pickDate(tester, inDays(1));
    await tap(tester, find.widgetWithText(FilterChip, _adminName).first);
    await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName).first);
    await tap(tester, find.text(de.assignmentRequire));
    await tap(tester, find.text(de.assignmentRemind));
    await waitFor(tester, find.text(de.event1DayBefore));
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, titleField);

    String chip(String who, String status) =>
        '$who · ${de.assignmentTask} · $status';
    await waitFor(tester, find.text(chip(_adminName, de.assignmentWaiting)));
    await waitFor(
      tester,
      find.text(chip(f.bea.displayName, de.assignmentWaiting)),
    );
    final record = engine.record(
      Collections.tasks,
      engine.tasks.singleWhere((t) => t.title == 'E2E Rasen mähen').id,
    )!;
    final settings = AssignmentSettings.fromData(record.data);
    expect(settings.required, isTrue);
    expect(settings.remindMinutes, 1440);

    // I take it.
    await tap(tester, find.text(chip(_adminName, de.assignmentWaiting)));
    await tap(tester, find.text(de.assignmentAccepted).last);
    await waitFor(tester, find.text(chip(_adminName, de.assignmentAccepted)));

    // Bea sees my answer and declines on her device.
    final bea = await sessionOf(f.bea);
    late SyncRecord task;
    await eventually(tester, 'Bea gets the task and my answer', () async {
      final tasks = (await pull(bea, Collections.tasks)).values.where(
        (r) => r.data['title'] == 'E2E Rasen mähen',
      );
      if (tasks.isEmpty) return false;
      task = tasks.first;
      final answers = await pull(bea, Collections.assignmentResponses);
      return answers.values.any(
        (r) =>
            r.data['memberId'] == state.me!.id &&
            r.data['decision'] == AssignmentDecision.accepted.name,
      );
    });
    final request = assignmentRequests(
      task,
      timeZone: 'Europe/Berlin',
    ).singleWhere((r) => r.memberId == f.bea.id);
    final reply = await bea.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.assignmentResponses,
            id: request.id,
            data: AssignmentResponse(
              targetCollection: Collections.tasks,
              targetId: task.id,
              memberId: f.bea.id,
              kind: request.kind,
              fingerprint: request.fingerprint,
              decision: AssignmentDecision.declined,
              occurrence: request.occurrence,
            ).toData(),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      ),
    );
    expect(reply.rejected, isEmpty);
    await engine.sync();
    await waitFor(
      tester,
      find.text(chip(f.bea.displayName, de.assignmentDeclined)),
      timeout: const Duration(seconds: 60),
    );
    expect(find.text(chip(_adminName, de.assignmentAccepted)), findsOneWidget);

    // Bea cannot answer for me.
    final forged = assignmentRequests(
      task,
      timeZone: 'Europe/Berlin',
    ).singleWhere((r) => r.memberId == state.me!.id);
    final forgedReply = await bea.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.assignmentResponses,
            id: forged.id,
            data: AssignmentResponse(
              targetCollection: Collections.tasks,
              targetId: task.id,
              memberId: state.me!.id,
              kind: forged.kind,
              fingerprint: forged.fingerprint,
              decision: AssignmentDecision.declined,
            ).toData(),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      ),
    );
    expect(forgedReply.rejected.map((r) => r.id), contains(forged.id));
    await engine.sync();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(chip(_adminName, de.assignmentAccepted)), findsOneWidget);

    // Withdrawn, then the content changes: a new answer is needed.
    await tap(tester, find.text(chip(_adminName, de.assignmentAccepted)));
    await tap(tester, find.text(de.assignmentWithdraw).last);
    await waitFor(tester, find.text(chip(_adminName, de.assignmentWaiting)));
    await tap(tester, find.text(chip(_adminName, de.assignmentWaiting)));
    await tap(tester, find.text(de.assignmentAccepted).last);
    await waitFor(tester, find.text(chip(_adminName, de.assignmentAccepted)));
    await tap(tester, find.text('E2E Rasen mähen'));
    await enter(tester, titleField, 'E2E Rasen mähen und kanten');
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, titleField);
    await waitFor(tester, find.text('E2E Rasen mähen und kanten'));
    await waitFor(tester, find.text(chip(_adminName, de.assignmentWaiting)));
    await waitFor(
      tester,
      find.text(chip(f.bea.displayName, de.assignmentWaiting)),
    );

    for (final t in engine.tasks.toList()) {
      if (t.title.startsWith('E2E')) engine.deleteTask(t.id);
    }
    await finish(tester, state);
  });
}
