// e2e-server: FAMIO_ALLOW_PRIVATE_CALENDAR_HOSTS=true
//
// Catalog KAL: calendar subscriptions the server really fetches (KAL-051,
// KAL-122, KAL-126, KAL-127, KAL-129, KAL-154, KAL-155, KAL-166) – against a
// throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_kal_c_test.dart
//
// A small calendar server inside the test hands out .ics files whose
// appointments lie a few days from today. The throwaway server may fetch
// them from 127.0.0.1 because the first line above starts it with
// FAMIO_ALLOW_PRIVATE_CALENDAR_HOSTS (tool/integration_tests.sh reads it);
// nothing goes out to the internet. What other members get is checked with
// their own API sessions.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/waste.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/format.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'catalog_kit.dart';

// --- the calendar server -----------------------------------------------------

/// One appointment of a feed: all day, or from [hour] for two hours (in the
/// family's zone, as the feed gives no zone).
class Appointment {
  const Appointment(this.uid, this.title, this.day, {this.hour});

  final String uid;
  final String title;
  final DateTime day;
  final int? hour;
}

String _date(DateTime d) => DateFormat('yyyyMMdd').format(d);

/// A calendar file as schools and waste collectors publish them.
String ics(String name, List<Appointment> appointments) => [
  'BEGIN:VCALENDAR',
  'VERSION:2.0',
  'PRODID:-//Famio E2E//Katalog//DE',
  'X-WR-CALNAME:$name',
  for (final a in appointments) ...[
    'BEGIN:VEVENT',
    'UID:${a.uid}@example.com',
    'DTSTAMP:20260101T000000Z',
    if (a.hour case final h?) ...[
      'DTSTART:${_date(a.day)}T${'$h'.padLeft(2, '0')}0000',
      'DTEND:${_date(a.day)}T${'${h + 2}'.padLeft(2, '0')}0000',
    ] else ...[
      'DTSTART;VALUE=DATE:${_date(a.day)}',
      'DTEND;VALUE=DATE:${_date(DateUtils.addDaysToDate(a.day, 1))}',
    ],
    'SUMMARY:${a.title}',
    'END:VEVENT',
  ],
  'END:VCALENDAR',
  '',
].join('\r\n');

/// Hands out [feeds] (name → file) at `/<name>.ics`; unknown names get 404.
/// [hold] keeps the answers for a feed back until [release].
class CalendarServer {
  late final HttpServer _server;
  final feeds = <String, String>{};
  final fetched = <String, int>{};
  final _held = <String, Completer<void>>{};

  String url(String name) => 'http://127.0.0.1:${_server.port}/$name.ics';

  void hold(String name) => _held[name] = Completer<void>();

  void release(String name) {
    final c = _held.remove(name);
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final last = request.uri.pathSegments.isEmpty
          ? ''
          : request.uri.pathSegments.last;
      final name = last.endsWith('.ics')
          ? last.substring(0, last.length - 4)
          : last;
      fetched[name] = (fetched[name] ?? 0) + 1;
      debugPrint('E2E-INFO calendar server: GET ${request.uri.path}');
      await _held[name]?.future;
      final body = feeds[name];
      try {
        if (body == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = ContentType(
            'text',
            'calendar',
            charset: 'utf-8',
          );
          request.response.write(body);
        }
        await request.response.close();
      } catch (_) {}
    });
  }

  Future<void> close() async {
    for (final c in _held.values) {
      if (!c.isCompleted) c.complete();
    }
    await _server.close(force: true);
  }
}

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

/// Removes what the tests of this file wrote: subscriptions (the server
/// then removes their appointments), appointments and the bin settings.
Future<void> wipe() async {
  final f = await theFamily();
  for (final c in [
    Collections.calendarSubscriptions,
    Collections.events,
    Collections.wasteSettings,
  ]) {
    final ids = (await pull(f.admin, c)).keys.toList();
    if (ids.isNotEmpty) await remove(f.admin, c, ids);
  }
}

/// The family and a calendar server, nothing of earlier tests.
Future<(KitFamily, CalendarServer)> prepare(WidgetTester tester) async {
  tester.view.physicalSize =
      const Size(800, 1600) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  await initializeDateFormatting('de');
  final f = await theFamily();
  await theService();
  await wipe();
  addTearDown(wipe);
  final calendars = CalendarServer();
  await calendars.start();
  addTearDown(calendars.close);
  return (f, calendars);
}

/// A subscription written by another device of [api]'s member.
Future<String> addSubscription(
  FamioApiClient api,
  String name,
  String url, {
  required String owner,
  CalendarSharing sharing = const CalendarSharing.family(),
}) async {
  final id = uid('sub');
  final r = await put(api, Collections.calendarSubscriptions, {
    id: CalendarSubscription(
      id: id,
      name: name,
      url: url,
      color: 0xFF2A9D6E,
      ownerId: owner,
      sharing: sharing,
    ).toData(),
  });
  expect(r.rejected.where((x) => x.id == id), isEmpty, reason: name);
  return id;
}

/// An appointment of [api]'s member (another device).
Future<String> addEvent(FamioApiClient api, String title, DateTime day) async {
  final id = uid('event');
  final r = await put(api, Collections.events, {
    id: CalendarEvent(
      id: id,
      title: title,
      start: day,
      end: DateUtils.addDaysToDate(day, 1),
      allDay: true,
    ).toData(),
  });
  expect(r.rejected.where((x) => x.id == id), isEmpty, reason: title);
  return id;
}

/// The titles of the imported appointments of [source] that [api]'s member
/// gets from the server.
Future<Set<String>> importedFor(FamioApiClient api, String source) async => {
  for (final r in (await pull(api, Collections.externalEvents)).values)
    if (r.data['sourceId'] == source) '${r.data['title']}',
};

/// All imported appointments [api]'s member gets, whatever their source.
Future<Set<String>> allImported(FamioApiClient api) async => {
  for (final r in (await pull(api, Collections.externalEvents)).values)
    '${r.data['title']}',
};

Future<Set<String>> subscriptionNames(FamioApiClient api) async => {
  for (final r in (await pull(api, Collections.calendarSubscriptions)).values)
    '${r.data['name']}',
};

Future<(int, String)> fetch(
  String url, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    headers.forEach(request.headers.set);
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  } finally {
    client.close();
  }
}

String dayHeading(DateTime d) => DateFormat.MMMMEEEEd('de').format(d);

// --- the calendar on screen --------------------------------------------------

bool _is(Widget w, String type) => w.runtimeType.toString() == type;

Finder byTypeName(String type) => find.byWidgetPredicate((w) => _is(w, type));

Finder dayCell(DateTime day) => find.byWidgetPredicate(
  (w) =>
      _is(w, '_DayCell') &&
      DateUtils.isSameDay((w as dynamic).day as DateTime, day),
);

final monthGrid = byTypeName('_MonthGrid');
final agendaTiles = byTypeName('_OccurrenceTile');

Finder tileOf(String title) =>
    find.ancestor(of: find.text(title), matching: agendaTiles).first;

/// The colour bar of [title]'s tile.
Color? barOf(WidgetTester tester, String title) {
  for (final c in tester.widgetList<Container>(
    find.descendant(of: tileOf(title), matching: find.byType(Container)),
  )) {
    final d = c.decoration;
    if (d is BoxDecoration && d.color != null && c.constraints != null) {
      return d.color;
    }
  }
  return null;
}

/// The titles in the day list.
List<String> agenda() => [
  for (final e in agendaTiles.evaluate())
    ((e.widget as dynamic).occurrence as Occurrence).event.title,
];

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

/// The bottom sheet away (a tap on the barrier).
Future<void> closeSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(30, 30));
  await tester.pump(const Duration(milliseconds: 700));
}

Finder inDialog(Finder f) => find.descendant(
  of: find.byWidgetPredicate((w) => w is Dialog || w is AlertDialog),
  matching: f,
);

final editorOpen = find.byWidgetPredicate(
  (w) =>
      w is Text && (w.data == de.eventNewEvent || w.data == de.eventEditEvent),
);

/// Kalender → "Mit Google/Apple Kalender verbinden".
Future<void> openConnect(WidgetTester tester) async {
  await openCalendar(tester);
  await tap(tester, find.byTooltip(de.calendarConnectGoogleAppleCalendar));
  await waitFor(tester, find.text(de.calendarConnectCalendarAppsDirectly));
  await dismissTip(tester);
}

Finder listTile(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ListTile)).first;

/// The text under a subscription's name: its state, then who sees it.
String subtitleOf(WidgetTester tester, String name) {
  final tile = tester.widget<ListTile>(listTile(name));
  return (tile.subtitle! as Text).data!;
}

/// "Kalender abonnieren", filled in and saved.
Future<void> subscribe(
  WidgetTester tester,
  String name,
  String url, {
  int? colour,
  String? who,
  Set<String>? only,
}) async {
  await snackGone(tester);
  await scrollTo(tester, find.text(de.calendarSubscribeCalendar));
  await tap(tester, find.text(de.calendarSubscribeCalendar));
  await waitFor(tester, find.text(de.calendarWhoSeesEvents));
  await enter(tester, field(de.commonName), name);
  await enter(tester, field(de.calendarIcsAddress), url);
  await leaveField(tester);
  if (colour != null) {
    await tap(
      tester,
      inDialog(
        find.byWidgetPredicate(
          (w) => w is CircleAvatar && w.backgroundColor == Color(colour),
        ),
      ),
    );
  }
  if (who != null) await tap(tester, inDialog(find.text(who)));
  if (only != null) {
    for (final chip
        in tester
            .widgetList<FilterChip>(inDialog(find.byType(FilterChip)))
            .toList()) {
      final label = (chip.label as Text).data!;
      if (chip.selected != only.contains(label)) {
        await tap(tester, inDialog(find.widgetWithText(FilterChip, label)));
      }
    }
  }
  await tap(tester, inDialog(find.text(de.commonSave)));
  await dialogClosed(tester);
}

/// The snack bar's text, after it showed.
Future<String> snackText(WidgetTester tester) async {
  final told = find.descendant(
    of: find.byType(SnackBar),
    matching: find.byType(Text),
  );
  await waitFor(tester, told);
  return tester.widget<Text>(told.first).data!;
}

/// Einstellungen → Abfallkalender.
Future<void> openWaste(WidgetTester tester) async {
  await openSection(tester, 'Einstellungen');
  await scrollTo(tester, find.text(de.settingsWaste));
  await tap(tester, find.text(de.settingsWaste));
  await waitFor(tester, find.text(de.wasteCollectionDates));
  await dismissTip(tester);
}

String? groupValue(WidgetTester tester) => tester
    .widget<RadioGroup<String?>>(find.byType(RadioGroup<String?>))
    .groupValue;

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  testWidgets(
    'KAL-122 KAL-126 a subscription fetched for real, then fetched again now',
    (tester) async {
      final (f, calendars) = await prepare(tester);
      final bea = await sessionOf(f.bea);
      calendars.feeds['schule'] = ics('Schule', [
        Appointment('elternabend', 'E2E Abo Elternabend', inDays(3), hour: 19),
        Appointment('sportfest', 'E2E Abo Sportfest', inDays(5)),
        Appointment('konferenz', 'E2E Abo Konferenz', inDays(12)),
      ]);
      // The first fetch waits until the app showed the new subscription.
      calendars.hold('schule');
      final state = await startApp(tester);
      final engine = state.engine!;
      await openConnect(tester);

      // KAL-122
      final colour = famioPalette[2];
      await subscribe(
        tester,
        'E2E Schule',
        calendars.url('schule'),
        colour: colour,
      );
      final school = engine.calendarSubscriptions.singleWhere(
        (s) => s.name == 'E2E Schule',
      );
      expect(school.url, calendars.url('schule'));
      expect(school.color, colour);
      expect(school.ownerId, f.adminMember.id);
      expect(school.sharing.family, isTrue);
      await waitFor(tester, find.text('E2E Schule'));
      expect(
        subtitleOf(tester, 'E2E Schule'),
        '${de.calendarWillLoadedNextSync}\n'
        '${de.calendarOwnerVisibleWho(de.calendarYou, de.commonWholeFamily)}',
      );
      // The server asks the calendar server …
      await eventually(
        tester,
        'the server fetches the feed',
        () async => (calendars.fetched['schule'] ?? 0) > 0,
      );
      expect(engine.subscriptionStatus(school.id), isNull);
      calendars.release('schule');
      // … and the app shows what came.
      await eventually(
        tester,
        'three appointments loaded',
        () async => engine.subscriptionStatus(school.id)?.eventCount == 3,
      );
      final status = engine.subscriptionStatus(school.id)!;
      expect(status.error, isNull);
      await tester.pump(const Duration(seconds: 1));
      final shown = subtitleOf(tester, 'E2E Schule');
      debugPrint('E2E-INFO fetched subscription: $shown');
      expect(
        shown,
        '${de.calendarCountEventsUpdatedWhen(3, dateTimeLabel(status.lastSync!))}\n'
        '${de.calendarOwnerVisibleWho(de.calendarYou, de.commonWholeFamily)}',
      );
      expect(
        {
          for (final e in engine.externalEvents)
            if (e.sourceId == school.id) e.title,
        },
        {'E2E Abo Elternabend', 'E2E Abo Sportfest', 'E2E Abo Konferenz'},
      );
      // The family's subscription reaches Bea's devices as well.
      await eventually(
        tester,
        'Bea gets the appointments',
        () async => (await importedFor(bea, school.id)).length == 3,
      );

      // Its appointments in its colour, read-only.
      await back(tester);
      final evening = inDays(3);
      await selectDay(tester, state, evening);
      await waitFor(tester, find.text('E2E Abo Elternabend'));
      expect(barOf(tester, 'E2E Abo Elternabend'), Color(colour));
      final occurrence = engine
          .occurrencesForDays(evening, DateUtils.addDaysToDate(evening, 1))
          .singleWhere((o) => o.event.title == 'E2E Abo Elternabend');
      expect(
        engine.calendar.local(occurrence.start).hour,
        19,
        reason: 'floating time in the family\'s zone',
      );
      expect(occurrence.event.allDay, isFalse);
      await tap(tester, find.text('E2E Abo Elternabend'));
      await waitFor(
        tester,
        find.text(de.calendarSourceReadOnlyMake('E2E Schule')),
      );
      expect(editorOpen, findsNothing);
      await closeSheet(tester);

      // KAL-126: the feed got a fourth appointment.
      calendars.feeds['schule'] = ics('Schule', [
        Appointment('elternabend', 'E2E Abo Elternabend', inDays(3), hour: 19),
        Appointment('sportfest', 'E2E Abo Sportfest', inDays(5)),
        Appointment('konferenz', 'E2E Abo Konferenz', inDays(12)),
        Appointment('laterne', 'E2E Abo Laternenumzug', inDays(7)),
      ]);
      final asked = calendars.fetched['schule']!;
      await openConnect(tester);
      await scrollTo(tester, find.text('E2E Schule'));
      await tap(
        tester,
        find.descendant(
          of: listTile('E2E Schule'),
          matching: find.byTooltip(de.calendarFetchNow),
        ),
      );
      final said = await snackText(tester);
      debugPrint('E2E-INFO fetched now: $said');
      expect(said, de.calendarNameCountEventsLoaded('E2E Schule', 4));
      expect(calendars.fetched['schule'], greaterThan(asked));
      await eventually(
        tester,
        'the fourth in the app',
        () async => engine.externalEvents.any(
          (e) => e.title == 'E2E Abo Laternenumzug',
        ),
      );
      await snackGone(tester);
      expect(
        subtitleOf(tester, 'E2E Schule').split('\n').first,
        startsWith(de.calendarCountEventsUpdatedWhen(4, '').split('·').first),
      );

      // … and the error of a fetch: no calendar at that address.
      await subscribe(tester, 'E2E Fehlt', calendars.url('fehlt'));
      final missing = engine.calendarSubscriptions.singleWhere(
        (s) => s.name == 'E2E Fehlt',
      );
      await eventually(
        tester,
        'the fetch failed',
        () async => engine.subscriptionStatus(missing.id)?.error != null,
      );
      await scrollTo(tester, find.text('E2E Fehlt'));
      await tap(
        tester,
        find.descendant(
          of: listTile('E2E Fehlt'),
          matching: find.byTooltip(de.calendarFetchNow),
        ),
      );
      final error = await snackText(tester);
      debugPrint('E2E-INFO fetch of a missing calendar: $error');
      expect(error, 'Kalender nicht gefunden (HTTP 404)');
      expect(
        subtitleOf(tester, 'E2E Fehlt').split('\n').first,
        'Kalender nicht gefunden (HTTP 404)',
      );
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-051 KAL-166 a family subscription: the guest sees none of it, the '
    'child and Home Assistant do',
    (tester) async {
      final (f, calendars) = await prepare(tester);
      final guest = await sessionOf(f.guest);
      final kid = await sessionOf(f.kid);
      final ha = await sessionOf(await theService());
      final day = inDays(2);
      calendars.feeds['verein'] = ics('Verein', [
        Appointment('turnier', 'E2E Vereinsturnier', day, hour: 10),
        Appointment('feier', 'E2E Vereinsfeier', inDays(9)),
      ]);
      final club = await addSubscription(
        f.admin,
        'E2E Verein',
        calendars.url('verein'),
        owner: f.adminMember.id,
      );
      // An own appointment of the family the same day: the guest's control.
      await addEvent(f.admin, 'E2E Familientermin', day);
      await eventually(
        tester,
        'the server imported the feed',
        () async => (await importedFor(f.admin, club)).length == 2,
      );

      // KAL-051: the child gets subscription and appointments …
      expect(await subscriptionNames(kid), contains('E2E Verein'));
      expect(await importedFor(kid, club), {
        'E2E Vereinsturnier',
        'E2E Vereinsfeier',
      });
      // … the guest neither.
      expect(await subscriptionNames(guest), isNot(contains('E2E Verein')));
      expect(await allImported(guest), isEmpty);
      expect(
        (await pull(guest, Collections.calendarSyncStatus)).keys,
        isNot(contains(club)),
      );

      var state = await startApp(tester, user: 'e2e-gast');
      await openCalendar(tester);
      await selectDay(tester, state, day);
      await waitFor(tester, find.text('E2E Familientermin'));
      await tester.pump(const Duration(seconds: 2));
      debugPrint('E2E-INFO the guest\'s day: ${agenda()}');
      expect(agenda(), contains('E2E Familientermin'));
      expect(agenda(), isNot(contains('E2E Vereinsturnier')));
      expect(state.engine!.externalEvents, isEmpty);
      await finish(tester, state);

      state = await startApp(tester, user: 'e2e-kind');
      await openCalendar(tester);
      await selectDay(tester, state, day);
      await waitFor(tester, find.text('E2E Vereinsturnier'));
      debugPrint('E2E-INFO the child\'s day: ${agenda()}');
      expect(
        agenda(),
        containsAll(['E2E Familientermin', 'E2E Vereinsturnier']),
      );
      await finish(tester, state);

      // KAL-166: the fetched appointment through the calendar API.
      final from = dayKey(today()), to = dayKey(inDays(30));
      final (status, body) = await fetch(
        Uri.parse(
          kitUrl,
        ).resolve('api/calendar/occurrences?from=$from&to=$to').toString(),
        headers: ha.authHeaders,
      );
      expect(status, 200, reason: body);
      final occurrences = [
        for (final o in (jsonDecode(body) as Map)['occurrences'] as List)
          (o as Map).cast<String, Object?>(),
      ];
      final tournament = occurrences.singleWhere(
        (o) => o['title'] == 'E2E Vereinsturnier',
      );
      debugPrint('E2E-INFO occurrence of the subscription: $tournament');
      expect(tournament['readOnly'], isTrue);
      expect(tournament['calendar'], 'E2E Verein');
      expect(tournament['allDay'], isFalse);
      expect(
        occurrences.where((o) => o['title'] == 'E2E Vereinsfeier'),
        hasLength(1),
      );
      final own = occurrences.singleWhere(
        (o) => o['title'] == 'E2E Familientermin',
      );
      expect(own['readOnly'], isNot(isTrue));
    },
  );

  testWidgets(
    'KAL-127 a subscription only for me, one for Bea: who gets the appointments',
    (tester) async {
      final (f, calendars) = await prepare(tester);
      final bea = await sessionOf(f.bea);
      final carl = await sessionOf(f.carl);
      final kid = await sessionOf(f.kid);
      final day = inDays(4);
      calendars.feeds['privat'] = ics('Privat', [
        Appointment('privat', 'E2E Privatabo Termin', day),
      ]);
      calendars.feeds['bea'] = ics('Bea', [
        Appointment('bea', 'E2E Beaabo Termin', day),
      ]);
      final state = await startApp(tester);
      final engine = state.engine!;
      await openConnect(tester);
      await subscribe(
        tester,
        'E2E Nur ich',
        calendars.url('privat'),
        who: de.docsOnlyMe,
      );
      await subscribe(
        tester,
        'E2E Fuer Bea',
        calendars.url('bea'),
        who: de.sharingSelected,
        only: {f.bea.displayName},
      );
      final onlyMe = engine.calendarSubscriptions.singleWhere(
        (s) => s.name == 'E2E Nur ich',
      );
      final forBea = engine.calendarSubscriptions.singleWhere(
        (s) => s.name == 'E2E Fuer Bea',
      );
      expect(onlyMe.sharing.private, isTrue);
      expect(forBea.sharing.members, [f.bea.id]);
      await eventually(
        tester,
        'both fetched',
        () async =>
            engine.subscriptionStatus(onlyMe.id)?.eventCount == 1 &&
            engine.subscriptionStatus(forBea.id)?.eventCount == 1,
      );
      // The admin has both in the calendar.
      await back(tester);
      await selectDay(tester, state, day);
      await waitFor(tester, find.text('E2E Privatabo Termin'));
      await waitFor(tester, find.text('E2E Beaabo Termin'));

      // Bea gets the one shared with her, nothing of the private one.
      await eventually(
        tester,
        'Bea gets hers',
        () async => (await importedFor(bea, forBea.id)).isNotEmpty,
      );
      expect(await allImported(bea), {'E2E Beaabo Termin'});
      expect(await subscriptionNames(bea), {'E2E Fuer Bea'});
      // The child and Carl get neither subscriptions nor appointments.
      for (final (who, api) in [('kid', kid), ('Carl', carl)]) {
        expect(await allImported(api), isEmpty, reason: who);
        final names = await subscriptionNames(api);
        expect(names, isNot(contains('E2E Nur ich')), reason: who);
        expect(names, isNot(contains('E2E Fuer Bea')), reason: who);
        final status = (await pull(api, Collections.calendarSyncStatus)).keys;
        expect(status, isNot(contains(onlyMe.id)), reason: who);
        expect(status, isNot(contains(forBea.id)), reason: who);
      }
      expect(await importedFor(f.admin, onlyMe.id), {'E2E Privatabo Termin'});
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-129 removing a subscription: undone, then its appointments are gone '
    'for everyone',
    (tester) async {
      final (f, calendars) = await prepare(tester);
      final bea = await sessionOf(f.bea);
      final kid = await sessionOf(f.kid);
      final day = inDays(6);
      calendars.feeds['musik'] = ics('Musikschule', [
        Appointment('vorspiel', 'E2E Vorspiel', day, hour: 16),
        Appointment('probe', 'E2E Probe', inDays(8), hour: 17),
      ]);
      final music = await addSubscription(
        f.admin,
        'E2E Musikschule',
        calendars.url('musik'),
        owner: f.adminMember.id,
      );
      await eventually(
        tester,
        'imported for Bea and the child',
        () async =>
            (await importedFor(bea, music)).length == 2 &&
            (await importedFor(kid, music)).length == 2,
      );
      final state = await startApp(tester);
      final engine = state.engine!;
      await eventually(
        tester,
        'in the app',
        () async =>
            engine.externalEvents.where((e) => e.sourceId == music).length == 2,
      );
      await openCalendar(tester);
      await selectDay(tester, state, day);
      await waitFor(tester, find.text('E2E Vorspiel'));

      Future<void> removeIt() async {
        await openConnect(tester);
        await scrollTo(tester, find.text('E2E Musikschule'));
        await tap(
          tester,
          find.descendant(
            of: listTile('E2E Musikschule'),
            matching: find.byTooltip(de.commonRemove),
          ),
        );
        await waitFor(
          tester,
          find.text(de.commonRemoveName('E2E Musikschule')),
        );
        expect(
          find.text(de.calendarImportedEventsDisappearEveryone),
          findsOneWidget,
        );
        await tap(tester, find.widgetWithText(FilledButton, de.commonRemove));
        await dialogClosed(tester);
        await waitGone(tester, find.text('E2E Musikschule'));
      }

      // Removed and undone: the subscription is back, with its appointments.
      await removeIt();
      await tap(tester, find.text(de.commonUndo));
      await waitFor(tester, find.text('E2E Musikschule'));
      await snackGone(tester);
      await engine.sync();
      expect(await subscriptionNames(bea), contains('E2E Musikschule'));
      await eventually(
        tester,
        'the appointments back for Bea',
        () async => (await importedFor(bea, music)).length == 2,
      );
      await eventually(
        tester,
        'and in the app',
        () async =>
            engine.externalEvents.where((e) => e.sourceId == music).length == 2,
      );

      // Removed for good.
      await removeIt();
      await snackGone(tester);
      await engine.sync();
      await eventually(
        tester,
        'gone for Bea and the child',
        () async =>
            (await importedFor(bea, music)).isEmpty &&
            (await importedFor(kid, music)).isEmpty &&
            !(await subscriptionNames(bea)).contains('E2E Musikschule'),
      );
      expect(await importedFor(f.admin, music), isEmpty);
      await eventually(
        tester,
        'gone in the app',
        () async => engine
            .records(Collections.externalEvents)
            .every((r) => r.data['sourceId'] != music),
      );
      await back(tester);
      await selectDay(tester, state, day);
      await tester.pump(const Duration(seconds: 1));
      expect(agenda(), isNot(contains('E2E Vorspiel')));
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-154 KAL-155 the bins from a chosen calendar, then from a subscribed '
    'waste calendar',
    (tester) async {
      final (f, calendars) = await prepare(tester);
      final date = DateFormat.MMMEd('de');
      final tour3 = inDays(3), yellow = inDays(4), rest = inDays(5);
      final tour7 = inDays(6);
      calendars.feeds['entsorger'] = ics('Entsorger', [
        Appointment('tour3', 'Tour 3', tour3),
        Appointment('gelb', 'Gelbe Tonne', yellow),
      ]);
      calendars.feeds['abfall'] = ics('Abfall', [
        Appointment('tour7', 'Tour 7', tour7),
      ]);
      final collector = await addSubscription(
        f.admin,
        'E2E Entsorger',
        calendars.url('entsorger'),
        owner: f.adminMember.id,
      );
      // An own appointment of the family that reads like a pickup.
      await addEvent(f.admin, 'Restmüll', rest);
      await eventually(
        tester,
        'the server imported the feed',
        () async => (await importedFor(f.admin, collector)).length == 2,
      );
      final state = await startApp(tester);
      final engine = state.engine!;
      await eventually(
        tester,
        'the appointments in the app',
        () async =>
            engine.externalEvents
                .where((e) => e.sourceId == collector)
                .length ==
            2,
      );
      await openWaste(tester);
      // Recognised by the title: the own "Restmüll" and the yellow bin.
      expect(groupValue(tester), isNull, reason: '"Automatisch erkennen"');
      await scrollTo(tester, find.text('⚫ Restmüll'));
      expect(
        find.descendant(
          of: listTile('⚫ Restmüll'),
          matching: find.text(date.format(rest)),
        ),
        findsOneWidget,
      );
      expect(find.text('🗑️ Abholung'), findsNothing, reason: '"Tour 3"');

      // KAL-154: only the collector's calendar counts, "Tour 3" too.
      final choice = find.widgetWithText(
        RadioListTile<String?>,
        'E2E Entsorger',
      );
      await scrollTo(tester, choice, up: true);
      await tap(tester, choice);
      await eventually(
        tester,
        'chosen',
        () async => engine.wasteSettings.sourceId == collector,
      );
      await scrollTo(tester, find.text('🗑️ Abholung'));
      expect(
        find.descendant(
          of: listTile('🗑️ Abholung'),
          matching: find.text(date.format(tour3)),
        ),
        findsOneWidget,
      );
      await scrollTo(tester, find.text('🟡 Gelbe Tonne'));
      expect(
        find.descendant(
          of: listTile('🟡 Gelbe Tonne'),
          matching: find.text(date.format(yellow)),
        ),
        findsOneWidget,
      );
      expect(find.text('⚫ Restmüll'), findsNothing);

      // KAL-155: a waste calendar subscribed here, its pickups after the
      // fetch.
      await scrollTo(tester, find.text(de.wasteSubscribe), up: true);
      await tap(tester, find.text(de.wasteSubscribe));
      await enter(
        tester,
        field(de.wasteCalendarAddressIcs),
        calendars.url('abfall'),
      );
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.wasteSubscribe2)));
      await dialogClosed(tester);
      final added = engine.calendarSubscriptions.singleWhere(
        (s) => s.name == de.settingsWaste,
      );
      expect(added.url, calendars.url('abfall'));
      await eventually(
        tester,
        'the new one is chosen',
        () async => engine.wasteSettings.sourceId == added.id,
      );
      expect(groupValue(tester), added.id);
      await eventually(
        tester,
        'fetched',
        () async => engine.subscriptionStatus(added.id)?.eventCount == 1,
      );
      expect((calendars.fetched['abfall'] ?? 0), greaterThan(0));
      await scrollTo(tester, find.text('🗑️ Abholung'));
      expect(
        find.descendant(
          of: listTile('🗑️ Abholung'),
          matching: find.text(date.format(tour7)),
        ),
        findsOneWidget,
      );
      // The collector's appointments count no more.
      expect(find.text(date.format(tour3)), findsNothing);
      expect(find.text('🟡 Gelbe Tonne'), findsNothing);
      expect(find.text('⚫ Restmüll'), findsNothing);
      await finish(tester, state);
    },
  );
}
