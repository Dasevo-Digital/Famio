// Catalog KAL-001 … KAL-064 (calendar view, appointments, series,
// notifications, confidential appointments and rights, lifts) against a
// throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_kal_a_test.dart
//
// Each test signs in through the app's own pages; other members are checked
// with their own API sessions (what the server gives them) or signed in to
// the app themselves (child, guest, a driver).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/calendar_screen.dart';
import 'package:famio/src/widgets/data_builder.dart';
import 'package:famio/src/widgets/member_avatar.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';

// --- family and data ---------------------------------------------------------

Future<FamilyMember>? _service;

/// A service account (Home Assistant) next to the family.
Future<FamilyMember> theService() => _service ??= () async {
  final f = await theFamily();
  for (final u in await f.admin.adminUsers()) {
    if (u.member.username == 'e2e-ha') return u.member;
  }
  return f.admin.createMember(
    username: 'e2e-ha',
    displayName: 'E2E HA',
    password: kitMemberPassword,
    role: MemberRole.service,
  );
}();

/// The family, the service account and no appointments of earlier tests.
/// [tall]: a window as high as a big screen, so that the day list and the
/// editor show everything at once (lists only build what is on screen).
Future<KitFamily> setUpFamily(WidgetTester tester, {bool tall = true}) async {
  if (tall) {
    tester.view.physicalSize =
        const Size(800, 1600) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
  }
  await initializeDateFormatting('de');
  final f = await theFamily();
  await theService();
  await cleanEvents();
  addTearDown(cleanEvents);
  return f;
}

/// Removes what the tests of this file wrote (titles with "E2E").
Future<void> cleanEvents() async {
  final f = await theFamily();
  for (final collection in [
    Collections.events,
    Collections.eventComments,
    Collections.calendarSubscriptions,
  ]) {
    final ids = [
      for (final r in (await pull(f.admin, collection)).values)
        if ('${r.data['title'] ?? r.data['name'] ?? r.data['text']}'.startsWith(
          'E2E',
        ))
          r.id,
    ];
    if (ids.isNotEmpty) await remove(f.admin, collection, ids);
  }
}

/// An appointment written by [api]'s member (another device); its id.
Future<String> addEvent(
  FamioApiClient api,
  String title,
  DateTime start, {
  DateTime? end,
  bool allDay = false,
  List<String> members = const [],
  Recurrence? recurrence,
  Set<DateTime> exceptions = const {},
  int? reminder,
  bool confidential = false,
  String location = '',
  String notes = '',
  String? bringer,
  String? picker,
  bool countdown = false,
  AssignmentSettings confirm = const AssignmentSettings(),
  List<FileRef> files = const [],
  String? sourceId,
}) async {
  final id = uid('event');
  final r = await put(api, Collections.events, {
    id: CalendarEvent(
      id: id,
      title: title,
      start: start,
      end:
          end ??
          (allDay
              ? DateUtils.addDaysToDate(start, 1)
              : start.add(const Duration(hours: 1))),
      allDay: allDay,
      location: location,
      notes: notes,
      memberIds: members,
      recurrence: recurrence,
      exceptions: exceptions,
      reminderMinutes: reminder,
      confidential: confidential,
      bringerId: bringer,
      pickerId: picker,
      countdown: countdown,
      assignmentConfirmation: confirm,
      files: files,
      sourceId: sourceId,
    ).toData(),
  });
  expect(
    r.rejected.where((x) => x.id == id),
    isEmpty,
    reason: 'the server takes $title',
  );
  return id;
}

/// The appointment [id] as the server gives it to [api]'s member.
Future<SyncRecord?> eventOf(FamioApiClient api, String id) async =>
    (await pull(api, Collections.events))[id];

/// Changes appointment [id] like another device of [api]'s member.
Future<void> editEvent(
  FamioApiClient api,
  String id,
  Map<String, Object?> Function(Map<String, Object?> data) change,
) async {
  final record = (await eventOf(api, id))!;
  final r = await put(api, Collections.events, {
    id: change({...record.data}),
  });
  expect(r.rejected.where((x) => x.id == id), isEmpty);
}

/// The latest revision the server has for [api]'s member.
Future<int> revOf(FamioApiClient api) async {
  var since = 0;
  while (true) {
    final r = await api.sync(SyncRequest(since: since));
    if (!r.hasMore || r.rev <= since) return r.rev;
    since = r.rev;
  }
}

/// What a device of [api]'s member that synced up to [since] gets now.
Future<List<SyncRecord>> changesAfter(FamioApiClient api, int since) async {
  final out = <SyncRecord>[];
  while (true) {
    final r = await api.sync(SyncRequest(since: since));
    out.addAll(r.changes);
    if (!r.hasMore || r.rev <= since) return out;
    since = r.rev;
  }
}

/// [who]'s answer to their lift of appointment [eventId], sent like their
/// own device does.
Future<SyncResponse> answer(
  FamioApiClient api,
  FamilyMember who,
  String eventId,
  AssignmentKind kind,
  AssignmentDecision decision, {
  DateTime? occurrence,
}) async {
  final record = (await eventOf(api, eventId))!;
  final request = assignmentRequests(
    record,
    occurrence: occurrence,
    timeZone: 'Europe/Berlin',
  ).singleWhere((r) => r.memberId == who.id && r.kind == kind);
  return api.sync(
    SyncRequest(
      since: 0,
      changes: [
        SyncRecord(
          collection: Collections.assignmentResponses,
          id: request.id,
          data: AssignmentResponse(
            targetCollection: Collections.events,
            targetId: eventId,
            memberId: who.id,
            kind: kind,
            fingerprint: request.fingerprint,
            decision: decision,
            occurrence: request.occurrence,
          ).toData(),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
    ),
  );
}

/// The decision [who] gave on the server for appointment [eventId].
Future<String?> decisionOf(
  FamioApiClient api,
  FamilyMember who,
  String eventId,
  AssignmentKind kind,
) async {
  final record = await eventOf(api, eventId);
  if (record == null) return null;
  final requests = assignmentRequests(record, timeZone: 'Europe/Berlin');
  final answers = await pull(api, Collections.assignmentResponses);
  for (final request in requests) {
    if (request.memberId != who.id || request.kind != kind) continue;
    final reply = answers[request.id];
    if (reply != null && reply.data['fingerprint'] == request.fingerprint) {
      return reply.data['decision'] as String?;
    }
  }
  return null;
}

DateTime nextWeekday(DateTime from, int weekday) =>
    DateUtils.addDaysToDate(from, (weekday - from.weekday) % 7);

DateTime at(DateTime day, int hour, [int minute = 0]) =>
    DateTime(day.year, day.month, day.day, hour, minute);

/// Calendar days from [a] to [b] (no daylight saving in between).
int utcDays(DateTime a, DateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

String dayHeading(DateTime d) => DateFormat.MMMMEEEEd('de').format(d);
String monthHeading(DateTime d) => DateFormat.yMMMM('de').format(d);
String clock(DateTime t) => DateFormat.jm('de').format(t);
String buttonDate(DateTime d) => DateFormat.yMMMEd('de').format(d);

/// Notifications of [api]'s member: where they stand now …
Future<int> noticeMark(FamioApiClient api) async => (await api.notices()).last;

/// … and what came after.
Future<List<Notice>> noticesAfter(FamioApiClient api, int mark) async =>
    (await api.notices(after: mark)).notices;

// --- the calendar on screen --------------------------------------------------

bool _is(Widget w, String type) => w.runtimeType.toString() == type;

/// The month grid's cell of [day].
Finder dayCell(DateTime day) => find.byWidgetPredicate(
  (w) =>
      _is(w, '_DayCell') &&
      DateUtils.isSameDay((w as dynamic).day as DateTime, day),
);

final monthGrid = find.byWidgetPredicate((w) => _is(w, '_MonthGrid'));
final agendaTiles = find.byWidgetPredicate((w) => _is(w, '_OccurrenceTile'));

/// Titles in the day list, top to bottom.
List<String> agenda() => [
  for (final e in agendaTiles.evaluate())
    ((e.widget as dynamic).occurrence as Occurrence).event.title,
];

Finder tileOf(String title) =>
    find.ancestor(of: find.text(title), matching: agendaTiles).first;

/// The time column of [title]'s tile ("10:00\n11:00", "ganztägig" …).
String timeOf(WidgetTester tester, String title) => tester
    .widget<Text>(
      find.descendant(of: tileOf(title), matching: find.byType(Text)).first,
    )
    .data!;

/// The second line of [title]'s tile (lifts, place, first line of notes).
String detailsOf(WidgetTester tester, String title) => tester
    .widget<Text>(
      find.descendant(of: tileOf(title), matching: find.byType(Text)).at(2),
    )
    .data!;

bool tileHasIcon(String title, IconData icon) => find
    .descendant(of: tileOf(title), matching: find.byIcon(icon))
    .evaluate()
    .isNotEmpty;

Future<void> openCalendar(WidgetTester tester) async {
  await openSection(tester, 'Kalender');
  await waitFor(tester, monthGrid);
}

/// Picks [date] in the month grid: back to today, the arrows to its month,
/// then its cell.
Future<void> selectDay(
  WidgetTester tester,
  AppState state,
  DateTime date,
) async {
  await snackGone(tester);
  await tap(tester, find.byTooltip(de.commonToday));
  final now = state.engine!.calendar.today();
  var months = (date.year - now.year) * 12 + date.month - now.month;
  for (; months > 0; months--) {
    await tap(tester, find.byTooltip(de.budgetNextMonth));
  }
  for (; months < 0; months++) {
    await tap(tester, find.byTooltip(de.budgetPreviousMonth));
  }
  await tap(
    tester,
    find.descendant(of: dayCell(date), matching: find.byType(InkWell)),
  );
  await waitFor(tester, find.text(dayHeading(date)));
}

// --- the event editor --------------------------------------------------------

Finder rowButtons(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
  matching: find.byType(TextButton),
);

String textIn(WidgetTester tester, Finder f) => tester
    .widget<Text>(find.descendant(of: f, matching: find.byType(Text)).first)
    .data!;

/// Start and end as the editor shows them: (date, time) each.
(String, String?) shown(WidgetTester tester, String row) {
  final buttons = rowButtons(row);
  final n = buttons.evaluate().length;
  return (
    textIn(tester, buttons.first),
    n > 1 ? textIn(tester, buttons.last) : null,
  );
}

/// Types [hour]:[minute] into the clock of the row [row] ("Beginn"/"Ende").
Future<void> setTime(
  WidgetTester tester,
  String row,
  int hour,
  int minute,
) async {
  await tap(tester, rowButtons(row).last);
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
  await tester.enterText(fields.at(0), hour.toString().padLeft(2, '0'));
  await tester.pump();
  await tester.enterText(fields.at(1), minute.toString().padLeft(2, '0'));
  await tester.pump();
  await tap(tester, find.text('OK').last);
  await dialogClosed(tester);
}

Future<void> setDate(WidgetTester tester, String row, DateTime day) async {
  await tap(tester, rowButtons(row).first);
  await pickDate(tester, day);
  await dialogClosed(tester);
}

Finder dropdownOf(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
);

/// What the drop-down [label] has selected (its form field's value).
Object? valueOf(WidgetTester tester, String label) =>
    (tester.state(dropdownOf(label)) as FormFieldState).value;

/// Opens the drop-down [label]; the texts of its menu.
Future<List<String>> openMenu(WidgetTester tester, String label) async {
  await tap(tester, dropdownOf(label));
  await tester.pump(const Duration(milliseconds: 600));
  return [
    for (final e
        in find
            .descendant(
              of: find.byWidgetPredicate(
                (w) => w.runtimeType.toString().startsWith(
                  '_DropdownMenuItemButton',
                ),
              ),
              matching: find.byType(Text),
            )
            .evaluate())
      (e.widget as Text).data ?? '',
  ];
}

SwitchListTile switchOf(WidgetTester tester, String title) =>
    tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title));

Future<void> flip(WidgetTester tester, String title) async {
  await scrollTo(tester, find.widgetWithText(SwitchListTile, title));
  await tap(tester, find.widgetWithText(SwitchListTile, title));
}

FilterChip person(WidgetTester tester, String name) =>
    tester.widget<FilterChip>(find.widgetWithText(FilterChip, name));

ChoiceChip wholeFamily(WidgetTester tester) => tester.widget<ChoiceChip>(
  find.widgetWithText(ChoiceChip, de.commonWholeFamily),
);

final titleField = field(de.commonTitle);

/// The editor's page title ("Neuer Termin", "Termin bearbeiten"): there
/// while the editor is open, wherever its list is scrolled.
final editorOpen = find.byWidgetPredicate(
  (w) =>
      w is Text && (w.data == de.eventNewEvent || w.data == de.eventEditEvent),
);

Future<void> newEvent(WidgetTester tester, String title) async {
  await snackGone(tester);
  await tap(tester, find.byTooltip(de.eventNewEvent));
  await waitFor(tester, editorOpen);
  await enter(tester, titleField, title);
}

/// Saves the editor; for a series [scope] answers "Änderung speichern".
Future<void> save(WidgetTester tester, {String? scope}) async {
  await leaveField(tester);
  await tap(tester, find.text(de.commonSave).last);
  if (scope != null) {
    await waitFor(tester, find.text(de.eventSaveChange));
    await tap(tester, find.text(scope).last);
  }
  await waitGone(tester, editorOpen);
}

Future<void> openEvent(WidgetTester tester, String title) async {
  await snackGone(tester);
  await tap(tester, find.text(title).last);
  await waitFor(tester, editorOpen);
}

Future<void> closeEditor(WidgetTester tester) async {
  await leaveField(tester);
  await back(tester);
  await waitGone(tester, editorOpen);
}

// --- another way in: a gate that can cut the connection ----------------------

/// Passes TCP between the app and the server; [cut] makes the server
/// unreachable for the app (as with no network) until [restore].
class Gate {
  Gate(this._upstream);

  final Uri _upstream;
  late final ServerSocket _server;
  final _open = <Socket>{};
  var _up = true;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_accept);
  }

  Future<void> _accept(Socket client) async {
    unawaited(client.done.catchError((Object _) {}));
    if (!_up) {
      client.destroy();
      return;
    }
    final Socket server;
    try {
      server = await Socket.connect(_upstream.host, _upstream.port);
    } catch (_) {
      client.destroy();
      return;
    }
    unawaited(server.done.catchError((Object _) {}));
    if (!_up) {
      client.destroy();
      server.destroy();
      return;
    }
    _open
      ..add(client)
      ..add(server);
    void close() {
      client.destroy();
      server.destroy();
      _open
        ..remove(client)
        ..remove(server);
    }

    void pass(Socket to, List<int> data) {
      try {
        to.add(data);
      } catch (_) {
        close();
      }
    }

    client.listen(
      (d) => pass(server, d),
      onDone: close,
      onError: (Object _) => close(),
      cancelOnError: true,
    );
    server.listen(
      (d) => pass(client, d),
      onDone: close,
      onError: (Object _) => close(),
      cancelOnError: true,
    );
  }

  void cut() {
    _up = false;
    for (final s in [..._open]) {
      s.destroy();
    }
    _open.clear();
  }

  void restore() => _up = true;

  Future<void> close() async {
    cut();
    await _server.close();
  }
}

/// Like [startApp], but through [url] (e.g. a [Gate]).
Future<AppState> startVia(WidgetTester tester, String url, String user) async {
  await initializeDateFormatting('de');
  await freshStart();
  final state = AppState();
  await state.init();
  addTearDown(() async {
    if (state.me != null) await state.signOut();
  });
  await tester.pumpWidget(FamioApp(state: state));
  await enter(tester, field('Server-Adresse'), url);
  await tap(tester, find.text('Verbinden'));
  await enter(tester, field('Benutzername'), user);
  await enter(tester, field('Passwort'), kitMemberPassword);
  await tap(tester, find.text('Anmelden'));
  await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
  if (find.text(de.commonLater).evaluate().isNotEmpty) {
    await tap(tester, find.text(de.commonLater).last);
  }
  return state;
}

/// Quits the app (without signing out) and starts it again.
Future<AppState> restart(WidgetTester tester, AppState old) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
  final engine = old.engine!;
  old
    ..engine = null
    ..me = null;
  await engine.dispose();
  engine.store.close();
  old.files?.close();
  old.files = null;
  final state = AppState();
  await state.init();
  addTearDown(() async {
    if (state.me != null) await state.signOut();
  });
  await tester.pumpWidget(FamioApp(state: state));
  await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
  return state;
}

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // --- Kalenderansicht --------------------------------------------------------

  testWidgets(
    'KAL-001 KAL-002 KAL-003 KAL-004 KAL-005 KAL-006 KAL-007 month grid and day list',
    (tester) async {
      final f = await setUpFamily(tester, tall: false);
      final now = today();
      const red = 0xFFE53935, blue = 0xFF1E88E5;
      await f.admin.updateUser(f.bea.id, color: red);
      await f.admin.updateUser(f.carl.id, color: blue);
      // KAL-001: today all day and at 10:00; KAL-003: the day after
      // tomorrow, nothing tomorrow.
      await addEvent(f.admin, 'E2E Ganztag', now, allDay: true);
      await addEvent(f.admin, 'E2E Zehn Uhr', at(now, 10));
      await addEvent(f.admin, 'E2E Übermorgen', at(inDays(2), 15));
      // KAL-005: two people with their colors; four appointments, three dots.
      final dots = inDays(3), many = inDays(4);
      await addEvent(
        f.admin,
        'E2E Punkt Bea',
        at(dots, 9),
        members: [f.bea.id],
      );
      await addEvent(
        f.admin,
        'E2E Punkt Carl',
        at(dots, 11),
        members: [f.carl.id],
      );
      for (var i = 1; i <= 4; i++) {
        await addEvent(f.admin, 'E2E Vier $i', at(many, 8 + i));
      }
      // KAL-007: a weekly appointment with everything, one for the family.
      final rich = inDays(5);
      await addEvent(
        f.admin,
        'E2E Turnen',
        at(rich, 16),
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
        reminder: 15,
        location: 'Turnhalle',
        notes: 'Sportzeug mitbringen\nund Wasser',
        members: [f.kid.id],
        bringer: f.bea.id,
        picker: f.carl.id,
      );
      await addEvent(f.admin, 'E2E Familienabend', at(rich, 19));
      // KAL-004: five on one day.
      final five = inDays(6);
      for (var i = 1; i <= 5; i++) {
        await addEvent(f.admin, 'E2E Fünf $i', at(five, 8 + i));
      }
      // KAL-006: Monday 20:00 to Wednesday 10:00.
      final monday = nextWeekday(inDays(13), DateTime.monday);
      await addEvent(
        f.admin,
        'E2E Mehrtägig',
        at(monday, 20),
        end: at(DateUtils.addDaysToDate(monday, 2), 10),
      );

      final state = await startApp(tester);
      debugPrint(
        'E2E window ${tester.view.physicalSize / tester.view.devicePixelRatio}',
      );
      await openCalendar(tester);

      // KAL-001
      await waitFor(tester, find.text('E2E Zehn Uhr'));
      expect(find.text(monthHeading(now)), findsOneWidget);
      expect(
        find.descendant(
          of: dayCell(now),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.child is Text &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).shape == BoxShape.circle,
          ),
        ),
        findsOneWidget,
        reason: 'today is a filled circle',
      );
      expect(find.text(dayHeading(now)), findsNWidgets(2));
      expect(agenda(), ['E2E Ganztag', 'E2E Zehn Uhr']);
      expect(timeOf(tester, 'E2E Ganztag'), de.commonAllDayLower);
      expect(timeOf(tester, 'E2E Zehn Uhr'), '10:00\n11:00');
      final bodyWidth = tester
          .getSize(
            find
                .descendant(
                  of: find.byType(CalendarScreen),
                  matching: find.byType(DataBuilder),
                )
                .first,
          )
          .width;
      final heading = find
          .descendant(
            of: find.byType(ListView),
            matching: find.text(dayHeading(now)),
          )
          .first;
      if (bodyWidth < 840) {
        expect(
          tester.getTopLeft(heading).dy,
          greaterThan(tester.getBottomLeft(monthGrid).dy - 1),
          reason: 'narrow: the day list below the grid',
        );
      } else {
        expect(
          tester.getTopLeft(heading).dx,
          greaterThan(tester.getTopRight(monthGrid).dx),
        );
      }

      // KAL-003
      await tap(
        tester,
        find.descendant(of: dayCell(inDays(1)), matching: find.byType(InkWell)),
      );
      await waitFor(tester, find.text(dayHeading(inDays(1))));
      expect(find.text(de.calendarNoEvents), findsOneWidget);
      expect(agenda(), isEmpty);
      expect(find.text(dayHeading(inDays(1))), findsNWidgets(2));
      await selectDay(tester, state, inDays(2));
      expect(agenda(), ['E2E Übermorgen']);
      expect(find.text(dayHeading(inDays(2))), findsNWidgets(2));

      // KAL-002
      await tap(tester, find.byTooltip(de.commonToday));
      await tap(tester, find.byTooltip(de.budgetNextMonth));
      final next = DateTime(now.year, now.month + 1);
      int clampDay(DateTime m, int d) =>
          d.clamp(1, DateUtils.getDaysInMonth(m.year, m.month));
      expect(find.text(monthHeading(next)), findsOneWidget);
      expect(
        find.text(
          dayHeading(DateTime(next.year, next.month, clampDay(next, now.day))),
        ),
        findsWidgets,
      );
      await tap(tester, find.byTooltip(de.budgetPreviousMonth));
      await tap(tester, find.byTooltip(de.budgetPreviousMonth));
      final previous = DateTime(now.year, now.month - 1);
      expect(find.text(monthHeading(previous)), findsOneWidget);
      expect(
        find.text(
          dayHeading(
            DateTime(
              previous.year,
              previous.month,
              clampDay(previous, now.day),
            ),
          ),
        ),
        findsWidgets,
      );
      // The last day of that month, then on: the shorter month's last day.
      final last = DateTime(
        previous.year,
        previous.month,
        DateUtils.getDaysInMonth(previous.year, previous.month),
      );
      await tap(
        tester,
        find.descendant(of: dayCell(last), matching: find.byType(InkWell)),
      );
      await tap(tester, find.byTooltip(de.budgetNextMonth));
      expect(
        find.text(
          dayHeading(DateTime(now.year, now.month, clampDay(now, last.day))),
        ),
        findsWidgets,
      );
      // A swipe to the left: the next month.
      await tester.flingFrom(
        tester.getCenter(monthGrid),
        const Offset(-300, 0),
        1500,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(monthHeading(next)), findsOneWidget);
      await tap(tester, find.byTooltip(de.commonToday));
      expect(find.text(monthHeading(now)), findsOneWidget);
      expect(find.text(dayHeading(now)), findsNWidgets(2));

      // KAL-006
      await selectDay(tester, state, monday);
      await waitFor(tester, find.text('E2E Mehrtägig'));
      expect(timeOf(tester, 'E2E Mehrtägig'), '20:00\n…');
      await selectDay(tester, state, DateUtils.addDaysToDate(monday, 1));
      expect(timeOf(tester, 'E2E Mehrtägig'), '…\n…');
      await selectDay(tester, state, DateUtils.addDaysToDate(monday, 2));
      expect(timeOf(tester, 'E2E Mehrtägig'), '…\n10:00');

      // KAL-007
      await selectDay(tester, state, rich);
      await waitFor(tester, find.text('E2E Turnen'));
      expect(tileHasIcon('E2E Turnen', AppIcons.repeat), isTrue);
      expect(tileHasIcon('E2E Turnen', AppIcons.bell), isTrue);
      expect(
        detailsOf(tester, 'E2E Turnen'),
        '🚗 ${de.familyNameDropsOff(f.bea.displayName)} · '
        '${de.familyNamePicksUp(f.carl.displayName)} · Turnhalle · '
        'Sportzeug mitbringen',
      );
      expect(
        tester
            .widgetList<MemberAvatar>(
              find.descendant(
                of: tileOf('E2E Turnen'),
                matching: find.byType(MemberAvatar),
              ),
            )
            .map((a) => a.member.id),
        [f.kid.id],
      );
      expect(
        find.descendant(
          of: tileOf('E2E Familienabend'),
          matching: find.byTooltip(de.commonWholeFamily),
        ),
        findsOneWidget,
      );

      // KAL-005 (narrow: dots in the first person's color, at most three)
      if (bodyWidth < 840) {
        await selectDay(tester, state, dots);
        Iterable<int?> dotColors(DateTime d) => tester
            .widgetList<Container>(
              find.descendant(
                of: dayCell(d),
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Container &&
                      w.decoration is BoxDecoration &&
                      (w.decoration as BoxDecoration).shape ==
                          BoxShape.circle &&
                      w.child == null,
                ),
              ),
            )
            .map((c) => (c.decoration as BoxDecoration).color?.toARGB32());
        await eventually(
          tester,
          'members have their colors',
          () async => dotColors(dots).toSet().containsAll({red, blue}),
        );
        expect(dotColors(dots), hasLength(2));
        expect(dotColors(many), hasLength(3));
        expect(
          find.byWidgetPredicate((w) => _is(w, '_CellLabel')),
          findsNothing,
        );
      }

      // KAL-004 (a wide window): titles in the cell, "+2", the list beside.
      final dpr = tester.view.devicePixelRatio;
      tester.view.physicalSize = const Size(1400, 900) * dpr;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pump(const Duration(seconds: 1));
      await selectDay(tester, state, five);
      final labels = find.descendant(
        of: dayCell(five),
        matching: find.byWidgetPredicate((w) => _is(w, '_CellLabel')),
      );
      expect(labels, findsNWidgets(3));
      for (var i = 1; i <= 3; i++) {
        expect(
          find.descendant(
            of: dayCell(five),
            matching: find.text('${clock(at(five, 8 + i))} E2E Fünf $i'),
          ),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(of: dayCell(five), matching: find.text('+2')),
        findsOneWidget,
      );
      expect(agenda(), [for (var i = 1; i <= 5; i++) 'E2E Fünf $i']);
      final wideHeading = find
          .descendant(
            of: find.byType(ListView),
            matching: find.text(dayHeading(five)),
          )
          .first;
      expect(
        tester.getTopLeft(wideHeading).dx,
        greaterThan(tester.getTopRight(monthGrid).dx),
        reason: 'wide: the day list right of the grid (KAL-001)',
      );
      tester.view.resetPhysicalSize();
      await tester.pump(const Duration(seconds: 1));
      await finish(tester, state);
    },
  );

  testWidgets('KAL-008 the family time zone decides the day', (tester) async {
    final f = await setUpFamily(tester);
    addTearDown(() async {
      await f.admin.updateServerSettings({'timeZone': null});
    });
    // 00:30 in Tokyo on [day] is the afternoon before in Berlin.
    final day = inDays(5);
    final instant = DateTime.utc(
      day.year,
      day.month,
      day.day,
    ).add(const Duration(minutes: 30)).subtract(const Duration(hours: 9));
    await addEvent(f.admin, 'E2E Tokio', instant.toLocal());
    final before = DateUtils.addDaysToDate(day, -1);
    final state = await startApp(tester);
    await openCalendar(tester);
    await selectDay(tester, state, before);
    await waitFor(tester, find.text('E2E Tokio'));
    final berlin = instant.toLocal();
    expect(
      timeOf(tester, 'E2E Tokio'),
      '${clock(berlin)}\n${clock(berlin.add(const Duration(hours: 1)))}',
    );

    await openAdmin(tester, 'Einstellungen');
    final zone = find.widgetWithText(TextField, 'Zeitzone');
    await scrollTo(tester, zone);
    await enter(tester, zone, 'Tokyo');
    await tap(tester, find.text('Asia/Tokyo').last);
    await scrollTo(tester, find.text('Speichern'));
    await tap(tester, find.text('Speichern'));
    await waitFor(tester, find.text('Servereinstellungen gespeichert'));
    await back(tester);

    // Without a restart the calendar counts in Tokyo's days.
    await openCalendar(tester);
    await eventually(
      tester,
      'the app knows the zone',
      () async => state.engine!.familyTimeZone == 'Asia/Tokyo',
    );
    await selectDay(tester, state, before);
    await tester.pump(const Duration(seconds: 1));
    expect(agenda(), isNot(contains('E2E Tokio')));
    await selectDay(tester, state, day);
    await waitFor(tester, find.text('E2E Tokio'));
    expect(timeOf(tester, 'E2E Tokio'), '00:30\n01:30');
    await finish(tester, state);
  });

  // Was a Befund: the filled circle of "heute" followed the device's date
  // while "Heute", the selection and the day list follow the family's. Now
  // it marks the family's today as well.
  testWidgets('KAL-008 today circle and the family today agree', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    addTearDown(() async {
      await f.admin.updateServerSettings({'timeZone': null});
    });
    // A zone whose date is not the device's right now.
    final zone = DateTime.now().hour >= 11
        ? 'Pacific/Kiritimati'
        : 'Pacific/Pago_Pago';
    await f.admin.updateServerSettings({'timeZone': zone});
    final state = await startApp(tester);
    await eventually(
      tester,
      'the app knows the zone',
      () async => state.engine!.familyTimeZone == zone,
    );
    await openCalendar(tester);
    await tap(tester, find.byTooltip(de.commonToday));
    final familyToday = DateUtils.dateOnly(state.engine!.calendar.today());
    expect(DateUtils.isSameDay(familyToday, DateTime.now()), isFalse);
    expect(find.text(dayHeading(familyToday)), findsNWidgets(2));
    final bold = find.byWidgetPredicate(
      (w) => w is Text && w.style?.fontWeight == FontWeight.bold,
    );
    expect(
      find.descendant(of: dayCell(familyToday), matching: bold),
      findsOneWidget,
      reason: 'the circle marks the family\'s today, as "Heute" does',
    );
    await finish(tester, state);
  });

  testWidgets('KAL-009 hide the calendar for everyone and back', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    addTearDown(() async {
      await f.admin.updateServerSettings({'hiddenModules': <String>[]});
    });
    final state = await startApp(tester);
    final calendarNav = find.byWidgetPredicate(
      (w) =>
          (w is Text && w.data == 'Kalender') ||
          (w is Tooltip && w.message == 'Kalender'),
    );
    await waitFor(tester, calendarNav);
    final bea = await sessionOf(f.bea);

    Future<void> toggleCalendar() async {
      await openAdmin(tester, 'Einstellungen');
      await scrollTo(tester, find.text(de.adminShowHideAreas));
      await tap(
        tester,
        find.descendant(
          of: find.widgetWithText(ListTile, de.adminShowHideAreas),
          matching: find.text(de.commonChange),
        ),
      );
      await waitFor(tester, find.byType(AlertDialog));
      final calendarSwitch = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(SwitchListTile, 'Kalender'),
      );
      await tap(tester, calendarSwitch.first);
      await tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(de.commonSave),
        ),
      );
      await waitFor(tester, find.text(de.adminAreasSaved));
      await dialogClosed(tester);
      await back(tester);
      await openSection(tester, 'Start');
    }

    await toggleCalendar();
    await waitGone(tester, calendarNav);
    expect(
      (await bea.config())['hiddenModules'],
      contains('calendar'),
      reason: 'the other members get it too',
    );
    await toggleCalendar();
    await waitFor(tester, calendarNav);
    expect((await bea.config())['hiddenModules'], isNot(contains('calendar')));
    await finish(tester, state);
  });

  // --- Termine anlegen und bearbeiten ------------------------------------------

  testWidgets(
    'KAL-010 KAL-011 KAL-012 KAL-018 KAL-020 new appointments, title required, countdown',
    (tester) async {
      final f = await setUpFamily(tester);
      final state = await startApp(tester);
      final engine = state.engine!;
      await openCalendar(tester);

      // KAL-010: today, the next full hour.
      final nowTime = DateTime.now();
      final hour = (nowTime.hour + 1).clamp(0, 23);
      final start = at(today(), hour);
      await tap(tester, find.byTooltip(de.eventNewEvent));
      await waitFor(tester, titleField);
      expect(find.text(de.eventNewEvent), findsOneWidget);

      // KAL-012: without a title the page stays, nothing is saved.
      final count = engine.events.length;
      await leaveField(tester);
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, find.text(de.commonEnterTitle));
      expect(titleField, findsOneWidget);
      expect(find.text(de.eventNewEvent), findsOneWidget);
      expect(engine.events.length, count);
      await snackGone(tester);

      expect(shown(tester, de.commonStart), (buttonDate(start), clock(start)));
      final end = start.add(const Duration(hours: 1));
      expect(shown(tester, de.commonEnd), (buttonDate(end), clock(end)));
      await scrollTo(tester, dropdownOf(de.commonReminder));
      expect(valueOf(tester, de.commonReminder), 15);
      expect(
        find.descendant(
          of: dropdownOf(de.commonReminder),
          matching: find.text(de.event15MinutesBefore),
        ),
        findsWidgets,
      );
      await scrollTo(tester, find.text(de.eventWhoTakingPart));
      expect(wholeFamily(tester).selected, isTrue);
      await scrollTo(tester, titleField, up: true);

      // KAL-010 / KAL-018: saved with a place, Bea gets it.
      await enter(tester, titleField, 'E2E Zahnarzt');
      await scrollTo(tester, field(de.commonPlace));
      await enter(tester, field(de.commonPlace), 'Praxis Süd');
      await save(tester);
      await waitFor(tester, find.text('E2E Zahnarzt'));
      expect(agenda(), contains('E2E Zahnarzt'));
      final bea = await sessionOf(f.bea);
      late SyncRecord got;
      await eventually(tester, 'Bea gets the appointment', () async {
        final r = (await pull(
          bea,
          Collections.events,
        )).values.where((r) => r.data['title'] == 'E2E Zahnarzt');
        if (r.isEmpty) return false;
        got = r.first;
        return true;
      });
      final seen = CalendarEvent.fromRecord(got);
      expect(seen.start.isAtSameMomentAs(start), isTrue);
      expect(seen.end.isAtSameMomentAs(end), isTrue);
      expect(seen.location, 'Praxis Süd');
      expect(DateUtils.isSameDay(seen.start.toLocal(), start), isTrue);

      // KAL-011: another day starts at 9:00.
      final nextWeek = inDays(7);
      await selectDay(tester, state, nextWeek);
      await tap(tester, find.byTooltip(de.eventNewEvent));
      await waitFor(tester, titleField);
      expect(shown(tester, de.commonStart), (
        buttonDate(nextWeek),
        clock(at(nextWeek, 9)),
      ));
      expect(shown(tester, de.commonEnd), (
        buttonDate(nextWeek),
        clock(at(nextWeek, 10)),
      ));
      await closeEditor(tester);

      // KAL-020: a countdown on the start page.
      final holiday = inDays(12);
      await selectDay(tester, state, holiday);
      await newEvent(tester, 'E2E Urlaub');
      await flip(tester, de.homeCountdown);
      expect(switchOf(tester, de.homeCountdown).value, isTrue);
      await save(tester);
      await openSection(tester, 'Start');
      await scrollTo(tester, find.text(de.homeDaysUntilTitle('E2E Urlaub')));
      final tile = find
          .ancestor(
            of: find.text(de.homeDaysUntilTitle('E2E Urlaub')),
            matching: find.byWidgetPredicate((w) => _is(w, '_Tile')),
          )
          .first;
      expect(
        find.descendant(of: tile, matching: find.text('12')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tile, matching: find.text(de.homeCountdown)),
        findsOneWidget,
      );
      // A running holiday counts as 0 days, a yearly one comes next year.
      await addEvent(
        f.admin,
        'E2E Ferienwoche',
        inDays(-1),
        end: inDays(3),
        allDay: true,
        countdown: true,
      );
      final anchor = inDays(-10);
      await addEvent(
        f.admin,
        'E2E Jahrestag',
        DateTime(anchor.year - 1, anchor.month, anchor.day, 10),
        recurrence: const Recurrence(RecurrenceFrequency.yearly),
        countdown: true,
      );
      final nextYear = DateTime.utc(anchor.year + 1, anchor.month, anchor.day);
      final days = nextYear
          .difference(DateTime.utc(today().year, today().month, today().day))
          .inDays;
      await waitFor(
        tester,
        find.text('E2E Ferienwoche: ${de.pregnancyRunning}! 🎉'),
      );
      final running = find
          .ancestor(
            of: find.text('E2E Ferienwoche: ${de.pregnancyRunning}! 🎉'),
            matching: find.byWidgetPredicate((w) => _is(w, '_Tile')),
          )
          .first;
      expect(
        find.descendant(of: running, matching: find.text('E2E Urlaub')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: running,
          matching: find.text(de.commonDaysLeft(12)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: running, matching: find.text('E2E Jahrestag')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: running,
          matching: find.text(de.commonDaysLeft(days)),
        ),
        findsOneWidget,
      );
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-013 KAL-014 KAL-015 times keep the length, all day, several days',
    (tester) async {
      await setUpFamily(tester);
      final state = await startApp(tester);
      await openCalendar(tester);
      final day = inDays(3);
      await selectDay(tester, state, day);

      // KAL-013: 10:00–11:30, then the start to 14:00, the end before it.
      await newEvent(tester, 'E2E Uhrzeiten');
      await setTime(tester, de.commonStart, 10, 0);
      await setTime(tester, de.commonEnd, 11, 30);
      expect(shown(tester, de.commonStart).$2, clock(at(day, 10)));
      expect(shown(tester, de.commonEnd).$2, clock(at(day, 11, 30)));
      await setTime(tester, de.commonStart, 14, 0);
      expect(shown(tester, de.commonEnd).$2, clock(at(day, 15, 30)));
      await setTime(tester, de.commonEnd, 13, 0);
      expect(shown(tester, de.commonEnd).$2, clock(at(day, 15)));
      expect(shown(tester, de.commonStart).$2, clock(at(day, 14)));
      await closeEditor(tester);

      // KAL-014: all day on and off.
      await newEvent(tester, 'E2E Ganztägig');
      await scrollTo(tester, dropdownOf(de.commonReminder));
      expect(valueOf(tester, de.commonReminder), 15);
      await flip(tester, de.commonAllDay);
      await scrollTo(tester, find.text(de.commonStart), up: true);
      expect(shown(tester, de.commonStart).$2, isNull);
      expect(shown(tester, de.commonEnd).$2, isNull);
      await scrollTo(tester, find.text(de.eventWhoTakingPart));
      expect(find.text(de.eventWhoDrives), findsNothing);
      await scrollTo(tester, dropdownOf(de.commonReminder), up: true);
      expect(valueOf(tester, de.commonReminder), 360);
      final items = await openMenu(tester, de.commonReminder);
      expect(
        items,
        containsAll([
          de.eventDay8M,
          de.eventDayBefore6P,
          de.event2DaysBefore6,
          de.event1WeekBefore8,
        ]),
      );
      expect(items, isNot(contains(de.event15MinutesBefore)));
      await tap(tester, find.text(de.eventDayBefore6P).last);
      await flip(tester, de.commonAllDay);
      await scrollTo(tester, find.text(de.commonStart), up: true);
      expect(shown(tester, de.commonStart), (
        buttonDate(day),
        clock(at(day, 9)),
      ));
      expect(shown(tester, de.commonEnd), (
        buttonDate(day),
        clock(at(day, 10)),
      ));
      await scrollTo(tester, dropdownOf(de.commonReminder));
      expect(valueOf(tester, de.commonReminder), 15);
      await closeEditor(tester);

      // KAL-015: Friday to Sunday, all day.
      final friday = nextWeekday(inDays(2), DateTime.friday);
      final sunday = DateUtils.addDaysToDate(friday, 2);
      await selectDay(tester, state, today());
      await newEvent(tester, 'E2E Wochenende');
      await flip(tester, de.commonAllDay);
      await scrollTo(tester, find.text(de.commonStart), up: true);
      await setDate(tester, de.commonStart, friday);
      await setDate(tester, de.commonEnd, sunday);
      expect(shown(tester, de.commonStart).$1, buttonDate(friday));
      expect(shown(tester, de.commonEnd).$1, buttonDate(sunday));
      await save(tester);
      for (var i = 0; i < 4; i++) {
        final d = DateUtils.addDaysToDate(friday, i);
        await selectDay(tester, state, d);
        await tester.pump(const Duration(milliseconds: 500));
        if (i < 3) {
          await waitFor(tester, find.text('E2E Wochenende'));
          expect(timeOf(tester, 'E2E Wochenende'), de.commonAllDayLower);
        } else {
          expect(agenda(), isNot(contains('E2E Wochenende')), reason: '$d');
        }
      }
      await selectDay(tester, state, friday);
      await openEvent(tester, 'E2E Wochenende');
      expect(shown(tester, de.commonEnd).$1, buttonDate(sunday));
      await closeEditor(tester);
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-016 KAL-017 an edit keeps the other device, delete with undo',
    (tester) async {
      final f = await setUpFamily(tester);
      final bea = await sessionOf(f.bea);
      final day = inDays(4);
      final meeting = await addEvent(
        f.admin,
        'E2E Besprechung',
        at(day, 18),
        location: 'Halle 1',
      );
      final evening = await addEvent(f.admin, 'E2E Elternabend', at(day, 20));
      final state = await startApp(tester);
      final engine = state.engine!;
      await openCalendar(tester);
      await selectDay(tester, state, day);

      // KAL-016: Bea changes the place while the editor is open.
      await waitFor(tester, find.text('E2E Besprechung'));
      await openEvent(tester, 'E2E Besprechung');
      await editEvent(bea, meeting, (d) => d..['location'] = 'Halle 2');
      await eventually(
        tester,
        'the app has Bea\'s change',
        () async => engine.event(meeting)?.location == 'Halle 2',
      );
      await enter(tester, titleField, 'E2E Besprechung neu');
      await save(tester);
      await engine.sync();
      await eventually(tester, 'both changes on the server', () async {
        final r = await eventOf(bea, meeting);
        return r?.data['title'] == 'E2E Besprechung neu' &&
            r?.data['location'] == 'Halle 2';
      });

      // KAL-017: delete, undo, delete again.
      await openEvent(tester, 'E2E Elternabend');
      await scrollTo(tester, find.text(de.eventDelete));
      await tap(tester, find.text(de.eventDelete));
      await waitFor(tester, find.text(de.undoWhatDeleted('E2E Elternabend')));
      expect(agenda(), isNot(contains('E2E Elternabend')));
      await tap(tester, find.text(de.commonUndo));
      await waitFor(tester, find.text('E2E Elternabend'));
      await engine.sync();
      await eventually(
        tester,
        'back on the server',
        () async => (await eventOf(bea, evening)) != null,
      );
      await snackGone(tester);
      await openEvent(tester, 'E2E Elternabend');
      await scrollTo(tester, find.text(de.eventDelete));
      await tap(tester, find.text(de.eventDelete));
      await waitFor(tester, find.text(de.undoWhatDeleted('E2E Elternabend')));
      await snackGone(tester);
      expect(agenda(), isNot(contains('E2E Elternabend')));
      await engine.sync();
      await eventually(
        tester,
        'gone for Bea',
        () async => (await eventOf(bea, evening)) == null,
      );
      expect({
        for (final e in (await bea.trash()).items) e.title,
      }, contains('E2E Elternabend'));
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, find.text(de.trashTitle));
      await tap(tester, find.text(de.trashTitle));
      await waitFor(tester, find.text('E2E Elternabend'));
      final kept = DateTime.now().add(const Duration(days: 30));
      expect(
        find.text(
          '${de.commonEvent} · '
          '${de.trashExpires(DateFormat.yMd('de').format(kept))}',
        ),
        findsWidgets,
      );
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-019 KAL-053 KAL-055 KAL-056 who takes part, who drives, answers of others',
    (tester) async {
      final f = await setUpFamily(tester);
      final ha = await theService();
      final state = await startApp(tester);
      await openCalendar(tester);
      final day = inDays(3);
      await selectDay(tester, state, day);
      await newEvent(tester, 'E2E Schwimmen');

      // KAL-019
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.kid.displayName),
      );
      expect(wholeFamily(tester).selected, isTrue);
      expect(find.widgetWithText(FilterChip, ha.displayName), findsNothing);
      await tap(tester, find.widgetWithText(FilterChip, f.kid.displayName));
      await tap(tester, find.widgetWithText(FilterChip, f.guest.displayName));
      expect(wholeFamily(tester).selected, isFalse);
      expect(person(tester, f.kid.displayName).selected, isTrue);
      expect(person(tester, f.guest.displayName).selected, isTrue);
      await tap(tester, find.widgetWithText(ChoiceChip, de.commonWholeFamily));
      expect(wholeFamily(tester).selected, isTrue);
      expect(person(tester, f.kid.displayName).selected, isFalse);
      expect(person(tester, f.guest.displayName).selected, isFalse);
      await tap(tester, find.widgetWithText(FilterChip, f.kid.displayName));

      // KAL-055: the confirmation only with a driver, not all day.
      expect(find.text(de.assignmentRequire), findsNothing);
      // KAL-053: who may drive.
      await scrollTo(tester, dropdownOf(de.eventDropsOff), up: true);
      final drivers = await openMenu(tester, de.eventDropsOff);
      expect(
        drivers,
        containsAll([
          de.eventNobodyAssigned,
          kitAdminName,
          f.bea.displayName,
          f.carl.displayName,
          f.guest.displayName,
        ]),
      );
      expect(drivers, isNot(contains(f.kid.displayName)));
      expect(drivers, isNot(contains(ha.displayName)));
      await tap(tester, find.text(kitAdminName).last);
      await tester.pump(const Duration(milliseconds: 500));
      await scrollTo(tester, find.text(de.assignmentRequire));
      expect(find.text(de.assignmentRequire), findsOneWidget);
      await flip(tester, de.commonAllDay);
      await scrollTo(tester, find.text(de.eventWhoTakingPart));
      expect(find.text(de.assignmentRequire), findsNothing);
      expect(find.text(de.eventWhoDrives), findsNothing);
      await flip(tester, de.commonAllDay);
      await scrollTo(tester, find.text(de.assignmentRequire));
      expect(find.text(de.assignmentRequire), findsOneWidget);
      await scrollTo(tester, dropdownOf(de.eventPicksUp), up: true);
      await choose(tester, de.eventPicksUp, f.bea.displayName);
      await save(tester);
      await waitFor(tester, find.text('E2E Schwimmen'));
      expect(
        detailsOf(tester, 'E2E Schwimmen'),
        '🚗 ${de.familyNameDropsOff(kitAdminName)} · '
        '${de.familyNamePicksUp(f.bea.displayName)}',
      );
      expect(
        tester
            .widgetList<MemberAvatar>(
              find.descendant(
                of: tileOf('E2E Schwimmen'),
                matching: find.byType(MemberAvatar),
              ),
            )
            .map((a) => a.member.id),
        [f.kid.id],
      );

      // KAL-056 (the others' view): Bea's answer, a chip I cannot tap.
      await openEvent(tester, 'E2E Schwimmen');
      await flip(tester, de.assignmentRequire);
      await save(tester);
      String chip(String who, String kind, String status) =>
          '$who · $kind · $status';
      await waitFor(
        tester,
        find.text(
          chip(f.bea.displayName, de.eventPicksUp, de.assignmentWaiting),
        ),
      );
      expect(
        find.ancestor(
          of: find.text(
            chip(kitAdminName, de.eventDropsOff, de.assignmentWaiting),
          ),
          matching: find.byType(ActionChip),
        ),
        findsOneWidget,
      );
      final id = state.engine!.events
          .singleWhere((e) => e.title == 'E2E Schwimmen')
          .id;
      await state.engine!.sync();
      final bea = await sessionOf(f.bea);
      await eventually(
        tester,
        'Bea gets it',
        () async =>
            (await eventOf(bea, id))?.data['assignmentConfirmation'] != null,
      );
      final reply = await answer(
        bea,
        f.bea,
        id,
        AssignmentKind.pick,
        AssignmentDecision.accepted,
      );
      expect(reply.rejected, isEmpty);
      final accepted = find.text(
        chip(f.bea.displayName, de.eventPicksUp, de.assignmentAccepted),
      );
      await waitFor(tester, accepted, timeout: const Duration(seconds: 45));
      expect(
        find.ancestor(of: accepted, matching: find.byType(Chip)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: accepted, matching: find.byType(ActionChip)),
        findsNothing,
      );

      // KAL-053: the same person both ways.
      await openEvent(tester, 'E2E Schwimmen');
      await scrollTo(tester, dropdownOf(de.eventPicksUp));
      await choose(tester, de.eventPicksUp, kitAdminName);
      await save(tester);
      await waitFor(
        tester,
        find.text(de.familyNameDropsOffPicks(kitAdminName)),
      );
      expect(
        detailsOf(tester, 'E2E Schwimmen'),
        de.familyNameDropsOffPicks(kitAdminName),
      );
      await finish(tester, state);
    },
  );

  // --- Wiederholungen und Serien ----------------------------------------------

  testWidgets('KAL-021 KAL-022 KAL-023 kinds of series, weekdays, an end', (
    tester,
  ) async {
    await setUpFamily(tester);
    final state = await startApp(tester);
    await openCalendar(tester);
    final start = inDays(2);
    const kinds = {
      'E2E Täglich': 'Täglich',
      'E2E Wöchentlich': 'Wöchentlich',
      'E2E Zweiwöchentlich': 'Alle 2 Wochen',
      'E2E Monatlich': 'Monatlich',
      'E2E Jährlich': 'Jährlich',
    };
    for (final MapEntry(key: title, value: repeat) in kinds.entries) {
      await selectDay(tester, state, start);
      await newEvent(tester, title);
      await scrollTo(tester, dropdownOf(de.eventRepeat));
      await choose(tester, de.eventRepeat, repeat);
      await save(tester);
    }

    Future<void> expectOn(DateTime day, Set<String> titles) async {
      await selectDay(tester, state, day);
      await tester.pump(const Duration(milliseconds: 600));
      final shownTitles = agenda().where(kinds.containsKey).toSet();
      expect(shownTitles, titles, reason: '$day');
      for (final t in titles) {
        expect(timeOf(tester, t), '09:00\n10:00', reason: '$t on $day');
        expect(tileHasIcon(t, AppIcons.repeat), isTrue, reason: t);
      }
    }

    await waitFor(tester, find.text('E2E Täglich'));
    await expectOn(DateUtils.addDaysToDate(start, -1), {});
    await expectOn(start, kinds.keys.toSet());
    await expectOn(DateUtils.addDaysToDate(start, 1), {'E2E Täglich'});
    await expectOn(DateUtils.addDaysToDate(start, 7), {
      'E2E Täglich',
      'E2E Wöchentlich',
    });
    await expectOn(DateUtils.addDaysToDate(start, 14), {
      'E2E Täglich',
      'E2E Wöchentlich',
      'E2E Zweiwöchentlich',
    });
    final inAMonth = DateTime(start.year, start.month + 1, start.day);
    final monthly = {'E2E Täglich', 'E2E Monatlich'};
    final delta = utcDays(start, inAMonth);
    if (delta % 7 == 0) monthly.add('E2E Wöchentlich');
    if (delta % 14 == 0) monthly.add('E2E Zweiwöchentlich');
    await expectOn(inAMonth, monthly);
    final inAYear = DateTime(start.year + 1, start.month, start.day);
    final yearly = {'E2E Täglich', 'E2E Monatlich', 'E2E Jährlich'};
    final yearDelta = utcDays(start, inAYear);
    if (yearDelta % 7 == 0) yearly.add('E2E Wöchentlich');
    if (yearDelta % 14 == 0) yearly.add('E2E Zweiwöchentlich');
    await expectOn(inAYear, yearly);
    await cleanEvents();

    // KAL-022: Tuesday and Thursday.
    final tuesday = nextWeekday(inDays(2), DateTime.tuesday);
    await selectDay(tester, state, tuesday);
    await newEvent(tester, 'E2E Di Do');
    await scrollTo(tester, dropdownOf(de.eventRepeat));
    await choose(tester, de.eventRepeat, 'Wöchentlich');
    await waitFor(tester, find.widgetWithText(FilterChip, 'Di'));
    expect(person(tester, 'Di').selected, isTrue);
    expect(person(tester, 'Do').selected, isFalse);
    await tap(tester, find.widgetWithText(FilterChip, 'Do'));
    expect(person(tester, 'Do').selected, isTrue);
    await save(tester);
    for (final (offset, there) in [
      (-5, false),
      (0, true),
      (1, false),
      (2, true),
      (7, true),
      (8, false),
      (9, true),
    ]) {
      final d = DateUtils.addDaysToDate(tuesday, offset);
      await selectDay(tester, state, d);
      await tester.pump(const Duration(milliseconds: 600));
      expect(agenda().contains('E2E Di Do'), there, reason: '$d');
    }

    // KAL-023: ends in three weeks (inclusive), then not any more.
    final s = inDays(2);
    final until = DateUtils.addDaysToDate(s, 21);
    await selectDay(tester, state, s);
    await newEvent(tester, 'E2E Bis Datum');
    await scrollTo(tester, dropdownOf(de.eventRepeat));
    await choose(tester, de.eventRepeat, 'Wöchentlich');
    await scrollTo(tester, find.widgetWithText(InputChip, de.eventRepeatNever));
    await tap(tester, find.widgetWithText(InputChip, de.eventRepeatNever));
    await pickDate(tester, until);
    await dialogClosed(tester);
    expect(
      find.widgetWithText(InputChip, de.eventDate(buttonDate(until))),
      findsOneWidget,
    );
    await save(tester);
    Future<bool> onDay(DateTime d) async {
      await selectDay(tester, state, d);
      await tester.pump(const Duration(milliseconds: 600));
      return agenda().contains('E2E Bis Datum');
    }

    expect(await onDay(until), isTrue);
    expect(await onDay(DateUtils.addDaysToDate(until, 7)), isFalse);
    // ✕ on the chip: no end any more.
    await selectDay(tester, state, s);
    await openEvent(tester, 'E2E Bis Datum');
    await scrollTo(tester, find.byType(InputChip));
    await tap(
      tester,
      find.descendant(
        of: find.byType(InputChip),
        matching: find.byTooltip('Löschen'),
      ),
    );
    expect(find.widgetWithText(InputChip, de.eventRepeatNever), findsOneWidget);
    await save(tester, scope: de.eventAllEventsSeries);
    expect(await onDay(DateUtils.addDaysToDate(until, 7)), isTrue);
    await finish(tester, state);
  });

  testWidgets('KAL-026 KAL-027 KAL-029 change one date, all, delete a series', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final bea = await sessionOf(f.bea);
    final s = inDays(2);
    const weekly = Recurrence(RecurrenceFrequency.weekly);
    final single = await addEvent(
      f.admin,
      'E2E Serie Einzel',
      at(s, 9),
      recurrence: weekly,
    );
    final monday = nextWeekday(inDays(2), DateTime.monday);
    final skipped = DateUtils.addDaysToDate(monday, 14);
    final moved = await addEvent(
      f.admin,
      'E2E Serie Montag',
      at(monday, 17),
      recurrence: weekly,
      exceptions: {skipped},
    );
    final gone = nextWeekday(inDays(3), DateTime.wednesday);
    final goneSkip = DateUtils.addDaysToDate(gone, 7);
    final deleted = await addEvent(
      f.admin,
      'E2E Serie Löschen',
      at(gone, 12),
      recurrence: weekly,
      exceptions: {goneSkip},
    );
    final state = await startApp(tester);
    final engine = state.engine!;
    await openCalendar(tester);

    // KAL-026: only this date at 11:00.
    final second = DateUtils.addDaysToDate(s, 7);
    await selectDay(tester, state, second);
    await waitFor(tester, find.text('E2E Serie Einzel'));
    await openEvent(tester, 'E2E Serie Einzel');
    await setTime(tester, de.commonStart, 11, 0);
    await save(tester, scope: de.eventOnlyEvent);
    await waitFor(tester, find.text('11:00\n12:00'));
    expect(agenda().where((t) => t == 'E2E Serie Einzel'), hasLength(1));
    expect(timeOf(tester, 'E2E Serie Einzel'), '11:00\n12:00');
    expect(tileHasIcon('E2E Serie Einzel', AppIcons.repeat), isFalse);
    for (final d in [s, DateUtils.addDaysToDate(s, 14)]) {
      await selectDay(tester, state, d);
      await waitFor(tester, find.text('E2E Serie Einzel'));
      expect(timeOf(tester, 'E2E Serie Einzel'), '09:00\n10:00');
      expect(tileHasIcon('E2E Serie Einzel', AppIcons.repeat), isTrue);
    }
    expect(
      engine
          .event(single)!
          .exceptions
          .any((x) => DateUtils.isSameDay(x, second)),
      isTrue,
    );

    // KAL-027: the whole series one hour later, also earlier dates.
    await selectDay(tester, state, DateUtils.addDaysToDate(monday, 7));
    await waitFor(tester, find.text('E2E Serie Montag'));
    await openEvent(tester, 'E2E Serie Montag');
    await setTime(tester, de.commonStart, 18, 0);
    await save(tester, scope: de.eventAllEventsSeries);
    for (final (offset, time) in [
      (0, '18:00\n19:00'),
      (7, '18:00\n19:00'),
      (14, null),
      (21, '18:00\n19:00'),
    ]) {
      final d = DateUtils.addDaysToDate(monday, offset);
      await selectDay(tester, state, d);
      await tester.pump(const Duration(milliseconds: 600));
      if (time == null) {
        expect(agenda(), isNot(contains('E2E Serie Montag')), reason: '$d');
      } else {
        await waitFor(tester, find.text('E2E Serie Montag'));
        expect(timeOf(tester, 'E2E Serie Montag'), time, reason: '$d');
      }
    }
    await engine.sync();
    await eventually(tester, 'the server has the move', () async {
      final r = await eventOf(bea, moved);
      if (r == null) return false;
      final e = CalendarEvent.fromRecord(r);
      return e.start.toLocal().hour == 18 &&
          e.end.difference(e.start) == const Duration(hours: 1) &&
          e.exceptions.any((x) => DateUtils.isSameDay(x, skipped));
    });

    // KAL-029: all dates go, "Rückgängig" brings them with the exception.
    await selectDay(tester, state, gone);
    await waitFor(tester, find.text('E2E Serie Löschen'));
    await openEvent(tester, 'E2E Serie Löschen');
    await scrollTo(tester, find.text(de.eventDelete));
    await tap(tester, find.text(de.eventDelete).last);
    await waitFor(tester, find.text(de.eventAllEventsSeries));
    await tap(tester, find.text(de.eventAllEventsSeries).last);
    await waitFor(tester, find.text(de.undoWhatDeleted('E2E Serie Löschen')));
    expect(engine.event(deleted), isNull);
    expect(agenda(), isNot(contains('E2E Serie Löschen')));
    await tap(tester, find.text(de.commonUndo));
    await waitFor(tester, find.text('E2E Serie Löschen'));
    expect(
      engine
          .event(deleted)!
          .exceptions
          .any((x) => DateUtils.isSameDay(x, goneSkip)),
      isTrue,
    );
    await engine.sync();
    await eventually(tester, 'the series is back for Bea', () async {
      final r = await eventOf(bea, deleted);
      return r != null &&
          CalendarEvent.fromRecord(
            r,
          ).exceptions.any((x) => DateUtils.isSameDay(x, goneSkip));
    });
    await finish(tester, state);
  });

  testWidgets('KAL-031 a reminder of its own stays', (tester) async {
    final f = await setUpFamily(tester);
    final day = inDays(3);
    final id = await addEvent(
      f.admin,
      'E2E Zehn Minuten',
      at(day, 15),
      reminder: 10,
    );
    final state = await startApp(tester);
    await openCalendar(tester);
    await selectDay(tester, state, day);
    await waitFor(tester, find.text('E2E Zehn Minuten'));
    await openEvent(tester, 'E2E Zehn Minuten');
    await scrollTo(tester, dropdownOf(de.commonReminder));
    expect(valueOf(tester, de.commonReminder), 10);
    expect(
      find.descendant(
        of: dropdownOf(de.commonReminder),
        matching: find.text(de.eventMinutesMinutesBefore(10)),
      ),
      findsWidgets,
    );
    await save(tester);
    await state.engine!.sync();
    await tester.pump(const Duration(seconds: 2));
    expect((await eventOf(f.admin, id))!.data['reminderMinutes'], 10);
    await finish(tester, state);
  });

  // Was a Befund: an interval the editor had no choice for (every 3 weeks
  // from an .ics file or a calendar app) showed as "Wöchentlich" and was
  // saved with interval 1. Now the editor offers "Alle 3 Wochen" and keeps
  // it.
  testWidgets('KAL-030 a series every three weeks keeps its interval', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final s = inDays(2);
    final id = await addEvent(
      f.admin,
      'E2E Drei Wochen',
      at(s, 10),
      recurrence: const Recurrence(RecurrenceFrequency.weekly, interval: 3),
    );
    final state = await startApp(tester);
    await openCalendar(tester);
    await selectDay(tester, state, s);
    await waitFor(tester, find.text('E2E Drei Wochen'));
    await openEvent(tester, 'E2E Drei Wochen');
    await scrollTo(tester, dropdownOf(de.eventRepeat));
    expect(
      find.descendant(
        of: dropdownOf(de.eventRepeat),
        matching: find.text(de.eventRepeatEveryWeeks(3)),
      ),
      findsWidgets,
      reason: 'offered as it is, not as "Wöchentlich"',
    );
    await scrollTo(tester, titleField, up: true);
    await enter(tester, titleField, 'E2E Drei Wochen neu');
    await save(tester, scope: de.eventAllEventsSeries);
    await state.engine!.sync();
    await eventually(
      tester,
      'the new title on the server',
      () async =>
          (await eventOf(f.admin, id))?.data['title'] == 'E2E Drei Wochen neu',
    );
    final stored = CalendarEvent.fromRecord((await eventOf(f.admin, id))!);
    expect(stored.recurrence?.interval, 3, reason: 'still every 3 weeks');
    await selectDay(tester, state, DateUtils.addDaysToDate(s, 7));
    await tester.pump(const Duration(milliseconds: 600));
    expect(agenda(), isNot(contains('E2E Drei Wochen neu')));
    await selectDay(tester, state, DateUtils.addDaysToDate(s, 21));
    await waitFor(tester, find.text('E2E Drei Wochen neu'));
    await finish(tester, state);
  });

  // --- Erinnerungen und Mitteilungen -------------------------------------------

  testWidgets(
    'KAL-034 KAL-035 KAL-061 KAL-062 notices: new appointment, open answer, answer',
    (tester) async {
      final f = await setUpFamily(tester);
      final kid = await sessionOf(f.kid);
      final bea = await sessionOf(f.bea);
      final admin = f.admin;
      final kidMark = await noticeMark(kid);
      final beaMark = await noticeMark(bea);
      final adminMark = await noticeMark(admin);
      final state = await startApp(tester);
      final engine = state.engine!;
      await openCalendar(tester);
      final day = inDays(3);
      await selectDay(tester, state, day);

      // KAL-034: the child is named, it hears; Bea and I do not.
      await newEvent(tester, 'E2E Kinderturnen');
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.kid.displayName),
      );
      await tap(tester, find.widgetWithText(FilterChip, f.kid.displayName));
      await save(tester);
      await engine.sync();
      late Notice forKid;
      await eventually(tester, 'the child hears of it', () async {
        final n = (await noticesAfter(
          kid,
          kidMark,
        )).where((n) => n.title == 'Neuer Termin: E2E Kinderturnen');
        if (n.isEmpty) return false;
        forKid = n.first;
        return true;
      });
      expect(forKid.body, contains('Uhr'));
      expect(
        forKid.body,
        contains(
          '${day.day.toString().padLeft(2, '0')}.'
          '${day.month.toString().padLeft(2, '0')}.',
        ),
      );
      // The whole family, and an imported appointment: no such notice.
      await newEvent(tester, 'E2E Familie neu');
      await save(tester);
      await addEvent(
        admin,
        'E2E Importiert',
        at(day, 18),
        members: [f.kid.id],
        sourceId: 'e2e-feed',
      );
      await engine.sync();

      // KAL-035: confidential, with Bea: no title in the notice.
      await newEvent(tester, 'E2E Geheimtermin');
      await flip(tester, de.commonPrivate);
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.bea.displayName),
      );
      await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
      await save(tester);
      await engine.sync();
      late Notice secret;
      await eventually(tester, 'Bea hears of it', () async {
        final n = (await noticesAfter(
          bea,
          beaMark,
        )).where((n) => n.title == 'Neuer Termin für dich');
        if (n.isEmpty) return false;
        secret = n.first;
        return true;
      });
      expect(secret.body, isNot(contains('E2E Geheimtermin')));
      expect(secret.brief, isNot(contains('E2E Geheimtermin')));
      await tester.pump(const Duration(seconds: 3));
      final kidTitles = [
        for (final n in await noticesAfter(kid, kidMark)) n.title,
      ];
      expect(kidTitles, isNot(contains('Neuer Termin: E2E Familie neu')));
      expect(kidTitles, isNot(contains('Neuer Termin: E2E Importiert')));
      expect(
        [
          for (final n in await noticesAfter(bea, beaMark))
            if (n.title.startsWith('Neuer Termin')) n.title,
        ],
        ['Neuer Termin für dich'],
        reason: 'Bea is not named in the child\'s appointment',
      );
      expect(
        [
          for (final n in await noticesAfter(admin, adminMark))
            if (n.title.startsWith('Neuer Termin')) n.title,
        ],
        isEmpty,
        reason: 'not for the one who entered it',
      );

      // KAL-061: Bea drives in 50 minutes, reminded an hour before.
      final in50 = DateTime.now().add(const Duration(minutes: 50));
      // Whole minutes, as the clock sets them.
      final soon = DateTime(
        in50.year,
        in50.month,
        in50.day,
        in50.hour,
        in50.minute,
      );
      if (!DateUtils.isSameDay(soon, DateTime.now())) {
        markTestSkipped('too close to midnight for a lift today');
        await finish(tester, state);
        return;
      }
      await selectDay(tester, state, today());
      await newEvent(tester, 'E2E Fahrt bald');
      await setTime(tester, de.commonStart, soon.hour, soon.minute);
      await scrollTo(tester, dropdownOf(de.eventDropsOff));
      await choose(tester, de.eventDropsOff, f.bea.displayName);
      await flip(tester, de.assignmentRequire);
      await flip(tester, de.assignmentRemind);
      await scrollTo(tester, dropdownOf(de.assignmentReminderLead));
      await choose(tester, de.assignmentReminderLead, de.event1HourBefore);
      await save(tester);
      final lift = engine.events.singleWhere(
        (e) => e.title == 'E2E Fahrt bald',
      );
      expect(lift.assignmentConfirmation.required, isTrue);
      expect(lift.assignmentConfirmation.remindMinutes, 60);
      final secretLift = await addEvent(
        admin,
        'E2E Fahrt geheim',
        soon,
        confidential: true,
        members: [f.bea.id],
        bringer: f.bea.id,
        confirm: const AssignmentSettings(required: true, remindMinutes: 60),
      );
      await engine.sync();
      List<Notice> open(List<Notice> all) => [
        for (final n in all)
          if (n.title == 'Zusage noch offen') n,
      ];
      await eventually(
        tester,
        'Bea is reminded of both lifts',
        () async => open(await noticesAfter(bea, beaMark)).length >= 2,
        timeout: const Duration(minutes: 3),
      );
      final reminded = open(await noticesAfter(bea, beaMark));
      expect(reminded.map((n) => n.body).toSet(), {
        'Bitte die Zuständigkeit bestätigen: E2E Fahrt bald',
        'Eine Zuständigkeit wartet auf deine Rückmeldung',
      });

      // KAL-062: what Bea answers, I hear.
      final afterReminders = await noticeMark(admin);
      Future<String> nextAnswer(int mark) async {
        late String body;
        await eventually(tester, 'I hear of Bea\'s answer', () async {
          final n = (await noticesAfter(
            admin,
            mark,
          )).where((n) => n.title == 'Rückmeldung zur Zuständigkeit');
          if (n.isEmpty) return false;
          body = n.last.body;
          return true;
        });
        return body;
      }

      expect(
        (await answer(
          bea,
          f.bea,
          lift.id,
          AssignmentKind.bring,
          AssignmentDecision.declined,
        )).rejected,
        isEmpty,
      );
      expect(
        await nextAnswer(afterReminders),
        '${f.bea.displayName} kann nicht: E2E Fahrt bald',
      );
      final afterDecline = await noticeMark(admin);
      expect(
        (await answer(
          bea,
          f.bea,
          lift.id,
          AssignmentKind.bring,
          AssignmentDecision.accepted,
        )).rejected,
        isEmpty,
      );
      expect(
        await nextAnswer(afterDecline),
        '${f.bea.displayName} übernimmt: E2E Fahrt bald',
      );
      final afterAccept = await noticeMark(admin);
      final secretReply = await answer(
        bea,
        f.bea,
        secretLift,
        AssignmentKind.bring,
        AssignmentDecision.accepted,
      );
      expect(secretReply.rejected, isEmpty);
      expect(await nextAnswer(afterAccept), 'Neue Rückmeldung');

      // No further reminder after the answers.
      final settled = await noticeMark(bea);
      await tester.pump(const Duration(seconds: 75));
      expect(open(await noticesAfter(bea, settled)), isEmpty);
      await finish(tester, state);
    },
  );

  // --- Vertraulich und Rechte --------------------------------------------------

  testWidgets(
    'KAL-036 KAL-038 KAL-039 KAL-040 KAL-041 who gets confidential appointments',
    (tester) async {
      final f = await setUpFamily(tester);
      final ha = await theService();
      final bea = await sessionOf(f.bea);
      final kid = await sessionOf(f.kid);
      final guest = await sessionOf(f.guest);
      final service = await sessionOf(ha);
      final day = inDays(4);
      // KAL-040: a family appointment with a comment, seen by child and guest.
      final party = await addEvent(f.admin, 'E2E Familienfest', at(day, 15));
      final commentId = uid('comment');
      await put(f.admin, Collections.eventComments, {
        commentId: EventComment(
          id: commentId,
          eventId: party,
          authorId: f.adminMember.id,
          at: DateTime.now(),
          text: 'E2E Kommentar zum Fest',
        ).toData(),
      });
      // KAL-041: confidential with place, notes and a file.
      final file = await f.admin.uploadFile(
        bytes: utf8.encode('E2E Befund'),
        name: 'befund.txt',
        mime: 'text/plain',
      );
      final hidden = await addEvent(
        f.admin,
        'E2E Geheim HA',
        at(day, 8),
        confidential: true,
        location: 'Praxis Süd',
        notes: 'Befund mitbringen',
        files: [file],
      );
      final state = await startApp(tester);
      final engine = state.engine!;
      await openCalendar(tester);
      await selectDay(tester, state, day);

      // KAL-036: only for me, confidential; Bea gets it with its title.
      await newEvent(tester, 'E2E Psychotherapie');
      await flip(tester, de.commonPrivate);
      await scrollTo(tester, find.widgetWithText(FilterChip, kitAdminName));
      await tap(tester, find.widgetWithText(FilterChip, kitAdminName));
      await save(tester);
      // KAL-039: confidential for the whole family.
      await newEvent(tester, 'E2E Vertraulich Familie');
      await flip(tester, de.commonPrivate);
      await save(tester);
      // KAL-038: confidential, the guest not yet in it.
      await newEvent(tester, 'E2E Abholung');
      await flip(tester, de.commonPrivate);
      await scrollTo(tester, find.widgetWithText(FilterChip, kitAdminName));
      await tap(tester, find.widgetWithText(FilterChip, kitAdminName));
      await save(tester);
      await engine.sync();
      await eventually(tester, 'Bea gets the confidential ones', () async {
        final titles = await titlesOf(bea, Collections.events);
        return titles.containsAll({
          'E2E Psychotherapie',
          'E2E Vertraulich Familie',
          'E2E Abholung',
        });
      });
      final beaTherapy = (await pull(
        bea,
        Collections.events,
      )).values.singleWhere((r) => r.data['title'] == 'E2E Psychotherapie');
      expect(beaTherapy.data['confidential'], isTrue);
      final kidTitles = await titlesOf(kid, Collections.events);
      final guestTitles = await titlesOf(guest, Collections.events);
      for (final t in [
        'E2E Psychotherapie',
        'E2E Vertraulich Familie',
        'E2E Abholung',
      ]) {
        expect(kidTitles, isNot(contains(t)), reason: 'child: $t');
        expect(guestTitles, isNot(contains(t)), reason: 'guest: $t');
      }
      // KAL-038: as the one who picks up, the guest sees it.
      await openEvent(tester, 'E2E Abholung');
      await scrollTo(tester, dropdownOf(de.eventPicksUp));
      await choose(tester, de.eventPicksUp, f.guest.displayName);
      await save(tester);
      await engine.sync();
      await eventually(
        tester,
        'the guest gets it with its title',
        () async => (await titlesOf(
          guest,
          Collections.events,
        )).contains('E2E Abholung'),
      );

      // KAL-040: made confidential later, it leaves child and guest.
      expect((await pull(kid, Collections.events)).containsKey(party), isTrue);
      expect(
        (await pull(guest, Collections.eventComments)).containsKey(commentId),
        isTrue,
      );
      expect(
        (await pull(kid, Collections.eventComments)).containsKey(commentId),
        isTrue,
      );
      final kidRev = await revOf(kid);
      final guestRev = await revOf(guest);
      await waitFor(tester, find.text('E2E Familienfest'));
      await openEvent(tester, 'E2E Familienfest');
      await flip(tester, de.commonPrivate);
      expect(switchOf(tester, de.commonPrivate).value, isTrue);
      await save(tester);
      await engine.sync();
      for (final (name, api, rev) in [
        ('child', kid, kidRev),
        ('guest', guest, guestRev),
      ]) {
        await eventually(
          tester,
          '$name loses appointment and comment',
          () async {
            final changes = await changesAfter(api, rev);
            bool revoked(String id) =>
                changes.any((c) => c.id == id && c.deleted);
            return revoked(party) && revoked(commentId);
          },
        );
        expect(
          (await pull(api, Collections.events)).containsKey(party),
          isFalse,
        );
        expect(
          (await pull(api, Collections.eventComments)).containsKey(commentId),
          isFalse,
        );
      }

      // KAL-041: the service account gets only the busy time.
      final mine = (await eventOf(f.admin, hidden))!;
      final masked = (await eventOf(service, hidden))!;
      expect(masked.data['confidential'], isTrue);
      expect(masked.data['title'], '');
      expect(masked.data['location'], '');
      expect(masked.data['notes'], '');
      expect(masked.data['files'], anyOf(isNull, isEmpty));
      expect(masked.data['start'], mine.data['start']);
      expect(masked.data['end'], mine.data['end']);
      await expectLater(
        service.downloadFile(file.id),
        throwsA(isA<ApiError>()),
      );
      final serviceTitles = await titlesOf(service, Collections.events);
      expect(serviceTitles, isNot(contains('E2E Psychotherapie')));
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-037 KAL-039 KAL-045 KAL-047 KAL-048 KAL-049 the child and other people\'s appointments',
    (tester) async {
      final f = await setUpFamily(tester);
      final bea = await sessionOf(f.bea);
      final kidApi = await sessionOf(f.kid);
      final d1 = inDays(3), d2 = inDays(4), d3 = inDays(5), d4 = inDays(6);
      final doctor = await addEvent(
        f.admin,
        'E2E Kinderarzt',
        at(d1, 10),
        confidential: true,
        members: [f.adminMember.id, f.kid.id],
      );
      await addEvent(
        f.admin,
        'E2E Therapie',
        at(d1, 14),
        confidential: true,
        members: [f.adminMember.id],
      );
      await addEvent(
        f.admin,
        'E2E Vertraulich alle',
        at(d1, 16),
        confidential: true,
      );
      final open = await addEvent(f.admin, 'E2E Familie offen', at(d2, 10));
      final withAll = await addEvent(
        f.admin,
        'E2E Termin A',
        at(d2, 15),
        members: [f.adminMember.id, f.bea.id, f.kid.id],
      );
      final series = await addEvent(
        f.admin,
        'E2E Serie A',
        at(d3, 17),
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
      );
      final family = await addEvent(f.admin, 'E2E Kind löscht', at(d4, 11));

      final state = await startApp(tester, user: 'e2e-kind');
      final engine = state.engine!;
      await openCalendar(tester);

      // KAL-037 / KAL-039: only the doctor's appointment the child is in.
      await selectDay(tester, state, d1);
      await waitFor(tester, find.text('E2E Kinderarzt'));
      await tester.pump(const Duration(seconds: 1));
      expect(agenda(), ['E2E Kinderarzt']);
      expect(find.text(de.eventBusy), findsNothing);
      final kidTitles = await titlesOf(kidApi, Collections.events);
      expect(kidTitles, contains('E2E Kinderarzt'));
      expect(kidTitles, isNot(contains('E2E Therapie')));
      expect(kidTitles, isNot(contains('E2E Vertraulich alle')));
      expect(
        await titlesOf(bea, Collections.events),
        contains('E2E Vertraulich alle'),
      );

      // KAL-045: "Vertraulich" is not the child's to change.
      await openEvent(tester, 'E2E Kinderarzt');
      await scrollTo(
        tester,
        find.widgetWithText(SwitchListTile, de.commonPrivate),
      );
      expect(switchOf(tester, de.commonPrivate).onChanged, isNull);
      expect(switchOf(tester, de.commonPrivate).value, isTrue);
      expect(find.text(de.commonAudienceSetByAdults), findsOneWidget);
      await closeEditor(tester);
      await selectDay(tester, state, d2);
      await openEvent(tester, 'E2E Familie offen');
      await scrollTo(
        tester,
        find.widgetWithText(SwitchListTile, de.commonPrivate),
      );
      expect(switchOf(tester, de.commonPrivate).onChanged, isNull);
      expect(switchOf(tester, de.commonPrivate).value, isFalse);
      expect(find.text(de.commonAudienceSetByAdults), findsOneWidget);
      await closeEditor(tester);
      // Sent anyway (another app): the server keeps both as they are.
      await editEvent(
        kidApi,
        doctor,
        (d) => d
          ..['confidential'] = false
          ..['memberIds'] = [...d['memberIds'] as List, f.guest.id],
      );
      await editEvent(kidApi, open, (d) => d..['confidential'] = true);
      final doctorNow = (await eventOf(f.admin, doctor))!;
      expect(doctorNow.data['confidential'], isTrue);
      expect(doctorNow.data['memberIds'], isNot(contains(f.guest.id)));
      expect((await eventOf(f.admin, open))!.data['confidential'], isNot(true));

      // KAL-047: in A's appointment the child takes only itself out.
      await openEvent(tester, 'E2E Termin A');
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.kid.displayName),
      );
      expect(person(tester, kitAdminName).onSelected, isNull);
      expect(person(tester, f.bea.displayName).onSelected, isNull);
      expect(wholeFamily(tester).onSelected, isNull);
      expect(person(tester, f.kid.displayName).onSelected, isNotNull);
      await tap(tester, find.widgetWithText(FilterChip, f.kid.displayName));
      await save(tester);
      await engine.sync();
      await eventually(tester, 'the child is out, the others stay', () async {
        final ids =
            (await eventOf(f.admin, withAll))?.data['memberIds'] as List?;
        return ids != null &&
            !ids.contains(f.kid.id) &&
            ids.toSet().containsAll({f.adminMember.id, f.bea.id});
      });
      // In its own appointment the child removes Bea.
      await newEvent(tester, 'E2E Kind mit Bea');
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.kid.displayName),
      );
      await tap(tester, find.widgetWithText(FilterChip, f.kid.displayName));
      await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
      await save(tester);
      await engine.sync();
      await waitFor(tester, find.text('E2E Kind mit Bea'));
      await openEvent(tester, 'E2E Kind mit Bea');
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.bea.displayName),
      );
      expect(person(tester, f.bea.displayName).onSelected, isNotNull);
      await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
      await save(tester);
      await engine.sync();
      await eventually(tester, 'Bea is out of the child\'s own', () async {
        final r = (await pull(
          f.admin,
          Collections.events,
        )).values.where((r) => r.data['title'] == 'E2E Kind mit Bea');
        return r.isNotEmpty &&
            jsonEncode(r.first.data['memberIds']) == jsonEncode([f.kid.id]);
      });

      // KAL-048: no single dates of A's series.
      await selectDay(tester, state, d3);
      await waitFor(tester, find.text('E2E Serie A'));
      await openEvent(tester, 'E2E Serie A');
      await setTime(tester, de.commonStart, 18, 0);
      await leaveField(tester);
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, find.text(de.eventSaveChange));
      expect(find.text(de.eventOnlyEvent), findsNothing);
      expect(find.text(de.eventAllEventsSeries), findsOneWidget);
      expect(find.text(de.eventSingleDatesByCreator), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await dialogClosed(tester);
      await closeEditor(tester);
      await editEvent(
        kidApi,
        series,
        (d) => d..['exceptions'] = [DateFormat('yyyy-MM-dd').format(d3)],
      );
      expect(
        (await eventOf(f.admin, series))!.data['exceptions'],
        anyOf(isNull, isEmpty),
      );
      // Hint: deleting leaves the child only "the whole series".
      await openEvent(tester, 'E2E Serie A');
      await scrollTo(tester, find.text(de.eventDelete));
      await tap(tester, find.text(de.eventDelete).last);
      await waitFor(tester, find.text(de.eventSingleDatesByCreator));
      expect(find.text(de.eventOnlyEvent), findsNothing);
      await tap(tester, find.text(de.eventAllEventsSeries).last);
      await waitGone(tester, editorOpen);
      await engine.sync();
      await eventually(
        tester,
        'the parents\' whole series is gone',
        () async => (await eventOf(bea, series)) == null,
      );
      await snackGone(tester);

      // KAL-049: the child deletes a family appointment; A restores it.
      await selectDay(tester, state, d4);
      await waitFor(tester, find.text('E2E Kind löscht'));
      await openEvent(tester, 'E2E Kind löscht');
      await scrollTo(tester, find.text(de.eventDelete));
      await tap(tester, find.text(de.eventDelete).last);
      await waitGone(tester, editorOpen);
      await engine.sync();
      await eventually(
        tester,
        'gone for everyone',
        () async => (await eventOf(bea, family)) == null,
      );
      final bin = (await f.admin.trash()).items.where(
        (e) => e.record.id == family,
      );
      expect(bin, hasLength(1));
      expect(bin.single.canRestore, isTrue);
      await f.admin.restoreTrash(bin.single.id);
      await eventually(
        tester,
        'back after A restored it',
        () async => (await eventOf(bea, family)) != null,
      );
      await waitFor(tester, find.text('E2E Kind löscht'));
      final restoreSeries = (await f.admin.trash()).items.where(
        (e) => e.record.id == series,
      );
      if (restoreSeries.isNotEmpty) {
        await f.admin.restoreTrash(restoreSeries.first.id);
      }
      await finish(tester, state);
    },
  );

  /// The child enters an appointment only for itself and marks it
  /// confidential; returns its id.
  Future<String> ownSecret(
    WidgetTester tester,
    KitFamily f,
    AppState state,
    String title,
  ) async {
    final engine = state.engine!;
    await openCalendar(tester);
    await selectDay(tester, state, inDays(3));
    await newEvent(tester, title);
    await scrollTo(tester, find.widgetWithText(FilterChip, f.kid.displayName));
    await tap(tester, find.widgetWithText(FilterChip, f.kid.displayName));
    await scrollTo(
      tester,
      find.widgetWithText(SwitchListTile, de.commonPrivate),
    );
    expect(switchOf(tester, de.commonPrivate).onChanged, isNotNull);
    await flip(tester, de.commonPrivate);
    await save(tester);
    await engine.sync();
    final id = engine.events.singleWhere((e) => e.title == title).id;
    await eventually(
      tester,
      'confidential on the server',
      () async => (await eventOf(f.admin, id))?.data['confidential'] == true,
    );
    return id;
  }

  testWidgets('KAL-046 the child makes its own appointment confidential', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final guest = await sessionOf(f.guest);
    final state = await startApp(tester, user: 'e2e-kind');
    await ownSecret(tester, f, state, 'E2E Mein Geheimnis');
    expect(
      await titlesOf(guest, Collections.events),
      isNot(contains('E2E Mein Geheimnis')),
    );
    // Still its own: the switch stays usable.
    await openEvent(tester, 'E2E Mein Geheimnis');
    await scrollTo(
      tester,
      find.widgetWithText(SwitchListTile, de.commonPrivate),
    );
    expect(switchOf(tester, de.commonPrivate).onChanged, isNotNull);
    expect(switchOf(tester, de.commonPrivate).value, isTrue);
    await closeEditor(tester);
    await finish(tester, state);
  });

  // A person the child adds to its own confidential appointment stays in
  // it (RecordStore._childAudience keeps the reach only of appointments
  // somebody else entered), and with somebody else in it the switch locks.
  testWidgets('KAL-046 with somebody else in it the switch is locked', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final state = await startApp(tester, user: 'e2e-kind');
    final engine = state.engine!;
    final id = await ownSecret(tester, f, state, 'E2E Geheimnis mit Bea');
    await openEvent(tester, 'E2E Geheimnis mit Bea');
    await scrollTo(tester, find.widgetWithText(FilterChip, f.bea.displayName));
    await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
    expect(person(tester, f.bea.displayName).selected, isTrue);
    expect(person(tester, f.kid.displayName).selected, isTrue);
    await save(tester);
    await engine.sync();
    await tester.pump(const Duration(seconds: 2));
    await eventually(
      tester,
      'Bea is in the child\'s own confidential appointment',
      () async =>
          ((await eventOf(f.admin, id))?.data['memberIds'] as List? ?? const [])
              .contains(f.bea.id),
      timeout: const Duration(seconds: 20),
    );
    await openEvent(tester, 'E2E Geheimnis mit Bea');
    await scrollTo(
      tester,
      find.widgetWithText(SwitchListTile, de.commonPrivate),
    );
    expect(switchOf(tester, de.commonPrivate).onChanged, isNull);
    await closeEditor(tester);
    await finish(tester, state);
  });

  testWidgets(
    'KAL-050 KAL-051 the guest changes no appointments, sees no subscriptions',
    (tester) async {
      final f = await setUpFamily(tester);
      final bea = await sessionOf(f.bea);
      final kid = await sessionOf(f.kid);
      final guestApi = await sessionOf(f.guest);
      final day = inDays(3);
      final family = await addEvent(f.admin, 'E2E Gastfamilie', at(day, 15));
      await addEvent(
        f.admin,
        'E2E Vertraulich Gast',
        at(day, 17),
        confidential: true,
      );
      // KAL-051: a subscription of the family (its address goes nowhere: a
      // local one the server does not fetch).
      final feed = uid('feed');
      await put(f.admin, Collections.calendarSubscriptions, {
        feed: CalendarSubscription(
          id: feed,
          name: 'E2E Abo',
          url: 'https://127.0.0.1:9/e2e.ics',
          ownerId: f.adminMember.id,
        ).toData(),
      });
      final state = await startApp(tester, user: 'e2e-gast');
      final engine = state.engine!;
      await openCalendar(tester);
      await selectDay(tester, state, day);
      await waitFor(tester, find.text('E2E Gastfamilie'));
      await tester.pump(const Duration(seconds: 1));
      expect(agenda(), ['E2E Gastfamilie'], reason: 'KAL-039 for the guest');

      // KAL-050: no new appointment …
      expect(find.byTooltip(de.eventNewEvent), findsNothing);
      // … the appointment opens for reading, without saving or deleting …
      await snackGone(tester);
      await tap(tester, find.text('E2E Gastfamilie').last);
      await waitFor(tester, find.text(de.eventGuestReadOnly));
      expect(editorOpen, findsNothing);
      expect(find.text(de.commonSave), findsNothing);
      expect(find.text(de.eventDelete), findsNothing);
      // … and a comment is the guest's to write.
      await enter(tester, find.byType(TextField).last, 'E2E Gast kommt mit');
      await tap(tester, find.byTooltip(de.commonSend).last);
      await engine.sync();
      await tester.tapAt(const Offset(20, 20));
      await waitGone(tester, find.text(de.eventGuestReadOnly));
      expect(engine.events.map((e) => e.title), contains('E2E Gastfamilie'));
      final forBea = await pull(bea, Collections.events);
      expect(forBea[family]?.data['title'], 'E2E Gastfamilie');
      await eventually(
        tester,
        'the guest\'s comment reaches the others',
        () async => (await pull(
          bea,
          Collections.eventComments,
        )).values.any((r) => r.data['text'] == 'E2E Gast kommt mit'),
      );

      // KAL-051
      expect(await pull(guestApi, Collections.calendarSubscriptions), isEmpty);
      expect(await pull(guestApi, Collections.externalEvents), isEmpty);
      expect(
        (await pull(kid, Collections.calendarSubscriptions)).containsKey(feed),
        isTrue,
      );
      await finish(tester, state);
    },
  );

  // --- Fahrten und Zuständigkeiten ---------------------------------------------

  testWidgets(
    'KAL-056 KAL-057 KAL-058 KAL-059 KAL-060 the driver answers, also offline',
    (tester) async {
      final f = await setUpFamily(tester);
      final day = inDays(4);
      const need = AssignmentSettings(required: true);
      final lift = await addEvent(
        f.admin,
        'E2E Fahrt Turnen',
        at(day, 17),
        bringer: f.bea.id,
        confirm: need,
      );
      final monday = nextWeekday(inDays(2), DateTime.monday);
      await addEvent(
        f.admin,
        'E2E Serienfahrt',
        at(monday, 16),
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
        bringer: f.bea.id,
        picker: f.bea.id,
        confirm: need,
      );
      final gate = Gate(Uri.parse(kitUrl));
      await gate.start();
      addTearDown(gate.close);
      var state = await startVia(tester, gate.url, 'e2e-bea');
      await openCalendar(tester);
      await selectDay(tester, state, day);
      String chip(String status, [String? kind]) =>
          '${f.bea.displayName} · ${kind ?? de.eventDropsOff} · $status';
      final waiting = find.text(chip(de.assignmentWaiting));
      final accepted = find.text(chip(de.assignmentAccepted));
      final declined = find.text(chip(de.assignmentDeclined));
      Future<void> respond(String option) async {
        await snackGone(tester);
        await tap(
          tester,
          find.textContaining('${f.bea.displayName} · ${de.eventDropsOff} ·'),
        );
        await waitFor(tester, find.text(de.assignmentYourResponse));
        await tap(tester, find.text(option).last);
        await dialogClosed(tester);
      }

      Future<String?> onServer() =>
          decisionOf(f.admin, f.bea, lift, AssignmentKind.bring);

      // KAL-056
      await waitFor(tester, waiting);
      expect(
        find.ancestor(of: waiting, matching: find.byType(ActionChip)),
        findsOneWidget,
      );
      await tap(tester, waiting);
      await waitFor(tester, find.text(de.assignmentYourResponse));
      expect(find.text(de.assignmentAccepted), findsOneWidget);
      expect(find.text(de.assignmentDeclined), findsOneWidget);
      expect(find.text(de.assignmentWithdraw), findsNothing);
      await tap(tester, find.text(de.assignmentAccepted).last);
      await dialogClosed(tester);
      await waitFor(tester, accepted);
      await eventually(
        tester,
        'the answer on the server',
        () async => await onServer() == AssignmentDecision.accepted.name,
      );

      // KAL-057
      await respond(de.assignmentDeclined);
      await waitFor(tester, declined);
      await respond(de.assignmentWithdraw);
      await waitFor(tester, waiting);
      await eventually(
        tester,
        'withdrawn on the server',
        () async => await onServer() == null,
      );

      // KAL-058: offline the answer waits, then goes; it stays after a restart.
      gate.cut();
      await respond(de.assignmentAccepted);
      await waitFor(
        tester,
        find.text(
          '${chip(de.assignmentAccepted)} · ${de.assignmentPendingSync}',
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(await onServer(), isNull);
      gate.restore();
      unawaited(state.engine!.sync());
      await waitFor(tester, accepted, timeout: const Duration(seconds: 60));
      await eventually(
        tester,
        'the answer arrives',
        () async => await onServer() == AssignmentDecision.accepted.name,
      );
      state = await restart(tester, state);
      await openCalendar(tester);
      await selectDay(tester, state, day);
      await waitFor(tester, accepted);

      // KAL-059: what changes the lift asks again, reminder and confidential
      // do not.
      await editEvent(f.admin, lift, (d) {
        final e = CalendarEvent.fromRecord(
          SyncRecord(
            collection: Collections.events,
            id: lift,
            data: d,
            updatedAt: 0,
          ),
        );
        return {
          ...d,
          ...e
              .copyWith(
                start: e.start.add(const Duration(hours: 1)),
                end: e.end.add(const Duration(hours: 1)),
              )
              .toData(),
        };
      });
      await waitFor(tester, waiting);
      await respond(de.assignmentAccepted);
      await waitFor(tester, accepted);
      await eventually(
        tester,
        'accepted again',
        () async => await onServer() == AssignmentDecision.accepted.name,
      );
      await editEvent(
        f.admin,
        lift,
        (d) => d
          ..['reminderMinutes'] = 30
          ..['confidential'] = true,
      );
      await eventually(
        tester,
        'the app has the change',
        () async => state.engine!.event(lift)?.confidential ?? false,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(accepted, findsOneWidget);
      expect(await onServer(), AssignmentDecision.accepted.name);
      final changes = <String, void Function(Map<String, Object?>)>{
        'title': (d) => d['title'] = 'E2E Fahrt Turnen 2',
        'place': (d) => d['location'] = 'Halle 3',
        'notes': (d) => d['notes'] = 'Turnbeutel',
        'people': (d) => d['memberIds'] = [f.kid.id],
        'driver': (d) => d['pickerId'] = f.carl.id,
        'repetition': (d) => d['recurrence'] = const Recurrence(
          RecurrenceFrequency.weekly,
        ).toJson(),
      };
      for (final MapEntry(key: what, value: change) in changes.entries) {
        await editEvent(f.admin, lift, (d) {
          change(d);
          return d;
        });
        await waitFor(tester, waiting, timeout: const Duration(seconds: 30));
        debugPrint('E2E new answer needed after a change of $what');
        await respond(de.assignmentAccepted);
        await waitFor(tester, accepted);
        await eventually(
          tester,
          'accepted after $what',
          () async => await onServer() == AssignmentDecision.accepted.name,
        );
      }
      // An answer kept offline for the old version is dropped.
      gate.cut();
      await editEvent(
        f.admin,
        lift,
        (d) => d..['title'] = 'E2E Fahrt Turnen 3',
      );
      await respond(de.assignmentAccepted);
      await waitFor(
        tester,
        find.text(
          '${chip(de.assignmentAccepted)} · ${de.assignmentPendingSync}',
        ),
      );
      gate.restore();
      unawaited(state.engine!.sync());
      await waitFor(tester, waiting, timeout: const Duration(seconds: 60));
      expect(find.textContaining(de.assignmentPendingSync), findsNothing);
      expect(await onServer(), isNull);
      await remove(f.admin, Collections.events, [lift]);

      // KAL-060: each date of a series on its own.
      await selectDay(tester, state, monday);
      final bringOpen = find.text(chip(de.assignmentWaiting));
      final pickOpen = find.text(chip(de.assignmentWaiting, de.eventPicksUp));
      await waitFor(tester, bringOpen);
      await waitFor(tester, pickOpen);
      await tap(tester, bringOpen);
      await waitFor(tester, find.text(de.assignmentYourResponse));
      await tap(tester, find.text(de.assignmentAccepted).last);
      await dialogClosed(tester);
      await waitFor(tester, find.text(chip(de.assignmentAccepted)));
      expect(pickOpen, findsOneWidget);
      await selectDay(tester, state, DateUtils.addDaysToDate(monday, 7));
      await waitFor(tester, find.text('E2E Serienfahrt'));
      await waitFor(tester, bringOpen);
      expect(pickOpen, findsOneWidget);
      expect(find.text(chip(de.assignmentAccepted)), findsNothing);
      await selectDay(tester, state, monday);
      await waitFor(tester, find.text(chip(de.assignmentAccepted)));
      expect(pickOpen, findsOneWidget);
      await finish(tester, state);
    },
  );
}
