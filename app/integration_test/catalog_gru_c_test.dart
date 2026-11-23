// e2e-server: FAMIO_ALLOW_PRIVATE_CALENDAR_HOSTS=true
//
// Catalog GRU, entries of 23.11.2026: changes kept after a sign-out from
// elsewhere and discarded (GRU-171), an account the server removed
// (GRU-173), a guest's calendar file (GRU-185), filing the family inbox
// with its audience (GRU-187, GRU-188), a change the server refuses
// (GRU-189), subscribed appointments and birthdays in the search (GRU-191),
// the wall display of a service account (GRU-198) – against a throwaway
// server:
//
//   tool/integration_tests.sh macos integration_test/catalog_gru_c_test.dart
//
// Each test signs in through the app's own pages; other members and devices
// are API sessions. A TCP gate in front of the server stands in for a lost
// connection. A small calendar server inside the test hands out an .ics
// file; the throwaway server may fetch it from 127.0.0.1 because the first
// line above starts it with FAMIO_ALLOW_PRIVATE_CALENDAR_HOSTS. Drag and
// drop and the system's browser are replaced at their plugin interfaces.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/waiting_changes.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/ics_import_screen.dart';
import 'package:famio/src/screens/kiosk_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';

final _pdf = utf8.encode(
  '%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
  '2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\n'
  'trailer << /Root 1 0 R >>\n%%EOF\n',
);

// --- members and data --------------------------------------------------------

/// A member made anew for one test (it goes, or changes its password).
Future<FamilyMember> freshMember(
  String username,
  String name, {
  MemberRole role = MemberRole.adult,
}) async {
  final f = await theFamily();
  for (final u in await f.admin.adminUsers()) {
    if (u.member.username == username) await f.admin.deleteMember(u.member.id);
  }
  final m = await f.admin.createMember(
    username: username,
    displayName: name,
    password: kitMemberPassword,
    role: role,
  );
  addTearDown(() async {
    try {
      await f.admin.deleteMember(m.id);
    } on ApiError {
      // Gone already.
    }
  });
  return m;
}

/// Another device of [m]: a fresh API session (not the shared one).
Future<FamioApiClient> deviceOf(
  FamilyMember m, {
  String password = kitMemberPassword,
}) async {
  final api = FamioApiClient(kitUrl);
  await api.login(
    username: m.username,
    password: password,
    device: 'e2e Zweitgerät',
  );
  return api;
}

Future<void> seed(
  FamioApiClient api,
  String collection,
  Map<String, Map<String, Object?>> records,
) async {
  final r = await put(api, collection, records);
  expect(
    r.rejected.map((x) => x.id),
    isEmpty,
    reason: 'the server takes $collection',
  );
}

/// Writes over the record's current revision (no conflict copy), like a
/// device that is up to date.
Future<void> putLatest(
  FamioApiClient api,
  String collection,
  String id,
  Map<String, Object?> data,
) async {
  final current = (await pull(api, collection))[id];
  final answer = await api.sync(
    SyncRequest(
      since: 0,
      changes: [
        SyncRecord(
          collection: collection,
          id: id,
          data: data,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          rev: current?.rev ?? 0,
        ),
      ],
    ),
  );
  expect(answer.rejected.map((r) => r.id), isNot(contains(id)));
}

Future<FileRef> uploadAs(FamioApiClient api, String name, List<int> bytes) =>
    api.uploadFile(
      bytes: Uint8List.fromList(bytes),
      name: name,
      mime: 'application/pdf',
    );

/// The app's support folder (its databases).
Future<String> supportDir() async =>
    (await getApplicationSupportDirectory()).path;

Future<File> tempFile(String name, List<int> bytes) async {
  final dir = Directory(
    p.join((await getTemporaryDirectory()).path, 'famio-e2e-gru-c'),
  )..createSync(recursive: true);
  return File(p.join(dir.path, name))..writeAsBytesSync(bytes);
}

// --- connections -------------------------------------------------------------

/// Passes TCP between the app and the server; [cut] makes the server
/// unreachable (as with no network) until [restore].
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

Future<Gate> openGate() async {
  final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
  await gate.start();
  addTearDown(gate.close);
  return gate;
}

/// Hands out [feeds] (name → .ics file) at `/<name>.ics`.
class CalendarServer {
  late final HttpServer _server;
  final feeds = <String, String>{};

  String url(String name) => 'http://127.0.0.1:${_server.port}/$name.ics';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final last = request.uri.pathSegments.isEmpty
          ? ''
          : request.uri.pathSegments.last;
      final body = feeds[last.replaceAll('.ics', '')];
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

  Future<void> close() => _server.close(force: true);
}

String _icsDate(DateTime d) => DateFormat('yyyyMMdd').format(d);

/// A calendar file with one appointment on [day] from [hour] for an hour.
String ics(String name, String title, DateTime day, int hour) => [
  'BEGIN:VCALENDAR',
  'VERSION:2.0',
  'PRODID:-//Famio E2E//Katalog//DE',
  'X-WR-CALNAME:$name',
  'BEGIN:VEVENT',
  'UID:${uid('ics')}@example.com',
  'DTSTAMP:20260101T000000Z',
  'DTSTART:${_icsDate(day)}T${'$hour'.padLeft(2, '0')}0000',
  'DTEND:${_icsDate(day)}T${'${hour + 1}'.padLeft(2, '0')}0000',
  'SUMMARY:$title',
  'END:VEVENT',
  'END:VCALENDAR',
  '',
].join('\r\n');

// --- the app -----------------------------------------------------------------

class _FakeLauncher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

final _launcher = _FakeLauncher();

var _formatted = false;

Future<void> _dates() async {
  if (_formatted) return;
  await initializeDateFormatting('de');
  await initializeDateFormatting('en');
  await initializeDateFormatting('es');
  _formatted = true;
}

/// A window as high as a big screen: lists build what is on it.
void tall(WidgetTester tester, {double width = 800, double height = 1600}) {
  tester.view.physicalSize = Size(width, height) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}

/// Starts the app signed out and signs in as [user] through its own pages,
/// at [url] (the server unless given).
Future<AppState> start(
  WidgetTester tester, {
  String? user,
  String? password,
  String url = kitUrl,
}) async {
  expect(kitUrl, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
  await _dates();
  UrlLauncherPlatform.instance = _launcher;
  await freshStart();
  final state = AppState();
  await state.init();
  addTearDown(() async {
    if (state.me != null) await state.signOut();
  });
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(FamioApp(state: state));
  await connect(tester, url);
  await signInHere(
    tester,
    user ?? kitUser,
    password: password ?? (user == null ? kitPassword : kitMemberPassword),
  );
  await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
  await laterIfAsked(tester);
  await dismissTip(tester);
  return state;
}

Future<void> connect(WidgetTester tester, String url) async {
  await enter(tester, field(de.connectServerAddress), url);
  await tap(tester, find.text(de.commonConnect));
  await waitFor(tester, field(de.commonUsername));
}

Future<void> signInHere(
  WidgetTester tester,
  String user, {
  String password = kitMemberPassword,
}) async {
  await enter(tester, field(de.commonUsername), user);
  await enter(tester, field(de.commonPassword), password);
  await tap(tester, find.text(de.commonSignIn));
}

Future<void> laterIfAsked(WidgetTester tester) async {
  if (find.text(de.commonLater).evaluate().isNotEmpty) {
    await tap(tester, find.text(de.commonLater).last);
  }
}

Finder inDialog(Finder f) =>
    find.descendant(of: find.byType(Dialog), matching: f);

/// Where to drag a page's list: right of the side rail.
const _listPoint = Offset(600, 420);

Future<void> openSettingsItem(WidgetTester tester, String title) async {
  await openSection(tester, 'Einstellungen');
  await scrollTo(tester, find.text(title), at: _listPoint);
  await tap(tester, find.text(title));
}

/// The app learns the end of its session with its next sync: made at once,
/// as a phone does when it is online again.
void nudge(AppState state) {
  unawaited(state.engine?.sync().catchError((Object _) {}));
}

/// The window's drop target, as the system calls it for files dragged from
/// the Finder.
Future<void> dropFiles(WidgetTester tester, List<File> files) async {
  tester.widget<DropTarget>(find.byType(DropTarget).first).onDragDone!(
    DropDoneDetails(
      files: [
        for (final f in files) DropItemFile(f.path, name: p.basename(f.path)),
      ],
      localPosition: const Offset(300, 300),
      globalPosition: const Offset(300, 300),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

/// Opens "Aufgaben" and adds [title] through the field at the top.
Future<void> addTask(WidgetTester tester, String title) async {
  await openSection(tester, 'Aufgaben');
  await enter(tester, field(de.tasksNewTask), title);
  await tap(tester, find.byTooltip(de.commonAdd));
  await waitFor(tester, find.text(title));
}

// --- the family inbox --------------------------------------------------------

Future<void> openInbox(WidgetTester tester) async {
  await openSection(tester, 'Start');
  await tap(tester, find.byTooltip(de.inboxTitle));
  await waitFor(tester, find.byTooltip(de.inboxAdd));
}

final _menuItems = find.byWidgetPredicate((w) => w is PopupMenuItem);

Future<void> fileAs(WidgetTester tester, String title, String target) async {
  await snackGone(tester);
  await tap(
    tester,
    find.descendant(
      of: find
          .ancestor(of: find.text(title), matching: find.byType(ListTile))
          .first,
      matching: find.byTooltip(de.inboxFileAs),
    ),
  );
  await tester.pump(const Duration(milliseconds: 600));
  await tap(
    tester,
    find.descendant(of: _menuItems, matching: find.text(target)),
  );
}

Future<void> clearInbox(SyncEngine engine) async {
  for (final i in engine.inboxItems) {
    engine.deleteInboxItem(i.id);
  }
  await engine.sync();
}

InboxItem inboxItem(
  String by,
  String title, {
  String? id,
  List<FileRef> files = const [],
  bool forChildren = false,
}) => InboxItem(
  id: id ?? newId(),
  title: title,
  files: files,
  createdAt: DateTime.now(),
  createdBy: by,
  forChildren: forChildren,
);

/// The audience chosen in "Als Dokument ablegen": the title of the radio
/// tile whose value the group holds.
String chosenAudience(WidgetTester tester) {
  final group =
      tester.widget(inDialog(find.byWidgetPredicate((w) => w is RadioGroup)))
          as dynamic;
  for (final e in inDialog(
    find.byWidgetPredicate((w) => w is RadioListTile),
  ).evaluate()) {
    final t = e.widget as dynamic;
    if (t.value == group.groupValue) return (t.title as Text).data!;
  }
  throw TestFailure('no audience chosen');
}

RadioListTile<Object?> audienceTile(WidgetTester tester, String title) =>
    tester.widget(
          inDialog(
            find.byWidgetPredicate(
              (w) =>
                  w is RadioListTile &&
                  w.title is Text &&
                  (w.title! as Text).data == title,
            ),
          ),
        )
        as RadioListTile<Object?>;

bool chipSelected(WidgetTester tester, String label) => tester
    .widget<ChoiceChip>(inDialog(find.widgetWithText(ChoiceChip, label)))
    .selected;

// --- search ------------------------------------------------------------------

final searchInput = find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      w.decoration?.hintText == de.searchEventTaskRecipeContact,
);

Future<void> search(WidgetTester tester, String text) async {
  await openSection(tester, 'Start');
  // Still open from before (the area keeps its page), else from the start
  // page.
  if (searchInput.evaluate().isEmpty) {
    await tap(tester, find.byTooltip(de.commonSearch));
  }
  await waitFor(tester, searchInput);
  await tester.tap(searchInput, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.enterText(searchInput, text);
  await tester.pump(const Duration(milliseconds: 800));
}

Finder heading(String text) =>
    find.byWidgetPredicate((w) => w is ListHeading && w.text == text);

String? subtitleOf(WidgetTester tester, Finder titleText) {
  final t = tester.widget<ListTile>(
    find.ancestor(of: titleText, matching: find.byType(ListTile)).first,
  );
  return t.subtitle is Text ? (t.subtitle! as Text).data : null;
}

Future<void> closeSheet(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 700));
  if (find.byType(BottomSheet).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(30, 30));
    await tester.pump(const Duration(milliseconds: 700));
  }
}

Finder roundCheck(String label) =>
    find.byWidgetPredicate((w) => w is RoundCheck && w.label == label);

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // === Abmelden und wartende Änderungen ======================================

  testWidgets(
    'GRU-171 discarding changes kept after a sign-out from elsewhere',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      final m = await freshMember('e2e-gru-verwerf', 'E2E Verwerfer');
      final other = await deviceOf(m);
      final gate = await openGate();
      final state = await start(tester, user: m.username, url: gate.url);
      final memberId = state.me!.id;

      // Offline a task; meanwhile a new password on the other device.
      await openSection(tester, 'Aufgaben');
      gate.cut();
      await addTask(tester, 'E2E Verworfen');
      const password = 'Wolke-Regal-Tulpe-71';
      await other.changePassword(
        currentPassword: kitMemberPassword,
        newPassword: password,
      );
      gate.restore();
      final hint = uid('task');
      await seed(f.admin, Collections.tasks, {
        hint: Task(id: hint, title: 'E2E Anstoß').toData(),
      });
      addTearDown(() => remove(f.admin, Collections.tasks, [hint]));
      await tester.pump(const Duration(seconds: 3));
      nudge(state);
      await waitFor(
        tester,
        field(de.connectServerAddress),
        timeout: const Duration(seconds: 120),
      );
      await waitFor(tester, find.text(de.connectWaitingChanges(1)));
      final database = File(
        p.join(await supportDir(), WaitingChanges.databaseName(memberId)),
      );
      expect(database.existsSync(), isTrue, reason: 'kept for a while');

      // "Verwerfen", then "Abbrechen": the hint stays.
      await tap(
        tester,
        find.widgetWithText(TextButton, de.connectDiscardWaiting),
      );
      await waitFor(tester, inDialog(find.text(de.connectDiscardWaitingTitle)));
      expect(
        inDialog(find.text(de.connectDiscardWaitingBody(1))),
        findsOneWidget,
      );
      expect(
        de.connectDiscardWaitingBody(1),
        'Die Änderung wird von diesem Gerät gelöscht und kann nicht mehr '
        'übertragen werden.',
      );
      await tap(tester, inDialog(find.text(de.commonCancel)));
      await dialogClosed(tester);
      expect(find.text(de.connectWaitingChanges(1)), findsOneWidget);
      expect(state.waitingChanges?.count, 1);
      expect(database.existsSync(), isTrue);

      // Again, and "Verwerfen" in the dialog: gone.
      await tap(
        tester,
        find.widgetWithText(TextButton, de.connectDiscardWaiting),
      );
      await waitFor(tester, inDialog(find.text(de.connectDiscardWaitingTitle)));
      await tap(
        tester,
        inDialog(find.widgetWithText(TextButton, de.connectDiscardWaiting)),
      );
      await dialogClosed(tester);
      await waitGone(tester, find.text(de.connectWaitingChanges(1)));
      expect(state.waitingChanges, isNull);
      expect(database.existsSync(), isFalse);

      // Signed in again: the task does not come.
      await connect(tester, gate.url);
      await signInHere(tester, m.username, password: password);
      await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
      await laterIfAsked(tester);
      await state.engine!.sync();
      await tester.pump(const Duration(seconds: 3));
      expect(
        state.engine!.tasks.where((t) => t.title == 'E2E Verworfen'),
        isEmpty,
      );
      final after = await deviceOf(m, password: password);
      expect(
        await titlesOf(after, Collections.tasks),
        isNot(contains('E2E Verworfen')),
      );
      expect(
        await titlesOf(f.admin, Collections.tasks),
        isNot(contains('E2E Verworfen')),
      );
      await finish(tester, state);
    },
  );

  testWidgets('GRU-173 an account the server removed keeps nothing here', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final support = await supportDir();

    Future<void> removedWhileOffline(
      FamilyMember m,
      String title,
      Future<void> Function() removeIt,
    ) async {
      final gate = await openGate();
      final state = await start(tester, user: m.username, url: gate.url);
      final id = state.me!.id;
      gate.cut();
      await addTask(tester, title);
      expect(
        state.engine!.store.dirty.any((r) => r.record.data['title'] == title),
        isTrue,
        reason: 'the task waits on this device',
      );
      await removeIt();
      gate.restore();
      await tester.pump(const Duration(seconds: 3));
      nudge(state);
      await waitFor(
        tester,
        find.text(de.appAccountRemoved),
        timeout: const Duration(seconds: 120),
      );
      expect(field(de.connectServerAddress), findsOneWidget);
      expect(
        de.appAccountRemoved,
        'Dein Konto wurde vom Server entfernt. Famio hat seine Daten auf '
        'diesem Gerät gelöscht.',
      );
      // No hint about waiting changes, nothing of the account left.
      expect(find.text(de.connectWaitingChanges(1)), findsNothing);
      expect(find.text(de.connectDiscardWaiting), findsNothing);
      expect(state.waitingChanges, isNull);
      expect(state.me, isNull);
      for (final name in [WaitingChanges.databaseName(id), 'files_$id.db']) {
        expect(File(p.join(support, name)).existsSync(), isFalse, reason: name);
      }
      expect(
        Directory(support)
            .listSync()
            .map((e) => p.basename(e.path))
            .where((n) => n.contains(id)),
        isEmpty,
      );
      expect(
        await titlesOf(f.admin, Collections.tasks),
        isNot(contains(title)),
      );
      await finish(tester, state);
    }

    // A child an admin removes in the administration.
    final kid = await freshMember(
      'e2e-gru-kindweg',
      'E2E Kind weg',
      role: MemberRole.child,
    );
    await removedWhileOffline(
      kid,
      'E2E Aufgabe vom Kind',
      () => f.admin.deleteMember(kid.id),
    );
    // An account its owner deleted on another device.
    final self = await freshMember('e2e-gru-selbstweg', 'E2E Selbst weg');
    final other = await deviceOf(self);
    await removedWhileOffline(
      self,
      'E2E Aufgabe vor dem Löschen',
      () => other.deleteMyAccount(password: kitMemberPassword),
    );
  });

  // === Kalenderdatei als Gast ================================================

  testWidgets('GRU-185 a guest drops a calendar file onto the window', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final state = await start(tester, user: f.guest.username);
    final engine = state.engine!;
    final before = engine.events.length;
    final file = await tempFile(
      'e2e-gast-termin.ics',
      utf8.encode(ics('E2E Gast', 'E2E Gast-Import', inDays(4), 10)),
    );
    await openSection(tester, 'Kalender');
    await dropFiles(tester, [file]);
    await waitFor(tester, find.text(de.eventGuestReadOnly));
    expect(
      de.eventGuestReadOnly,
      'Als Gast kannst du Termine ansehen und kommentieren, aber nicht '
      'ändern.',
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(IcsImportScreen), findsNothing);
    expect(find.text('E2E Gast-Import'), findsNothing);
    expect(engine.events.length, before);
    expect(
      engine.store.dirty.where(
        (r) => r.record.collection == Collections.events,
      ),
      isEmpty,
    );
    expect(
      await titlesOf(f.admin, Collections.events),
      isNot(contains('E2E Gast-Import')),
    );
    await finish(tester, state);
  });

  // === Familien-Eingang: Einschränkung beim Einsortieren ====================

  testWidgets('GRU-187 filed from the inbox, its audience stays', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final kid = await sessionOf(f.kid);
    final bea = await sessionOf(f.bea);
    final guest = await sessionOf(f.guest);
    final state = await start(tester);
    final engine = state.engine!;
    await clearInbox(engine);
    final me = state.me!.id;
    // The child's own entry, not shared with anyone in particular.
    final byKid = newId();
    await seed(kid, Collections.inbox, {
      byKid: inboxItem(f.kid.id, 'E2E Vom Kind abgelegt', id: byKid).toData(),
    });
    engine
      ..saveInboxItem(inboxItem(me, 'E2E Brief Aufgabe'))
      ..saveInboxItem(inboxItem(me, 'E2E Brief Notiz'))
      ..saveInboxItem(inboxItem(me, 'E2E Brief Termin'))
      ..saveInboxItem(inboxItem(me, 'E2E Ausflug Aufgabe', forChildren: true));
    await engine.sync();
    await openInbox(tester);
    for (final t in [
      'E2E Brief Aufgabe',
      'E2E Brief Notiz',
      'E2E Brief Termin',
      'E2E Ausflug Aufgabe',
      'E2E Vom Kind abgelegt',
    ]) {
      await waitFor(tester, find.text(t));
    }

    await fileAs(tester, 'E2E Brief Aufgabe', de.commonTask);
    await waitFor(tester, find.text(de.inboxFiled));
    await fileAs(tester, 'E2E Brief Notiz', de.commonNote);
    await waitFor(tester, find.text(de.inboxFiled));
    final day = inDays(6);
    await fileAs(tester, 'E2E Brief Termin', de.commonEvent);
    await waitFor(tester, find.text(de.inboxEventDate));
    await pickDate(tester, day);
    await waitFor(tester, find.text(de.inboxFiled));
    await fileAs(tester, 'E2E Ausflug Aufgabe', de.commonTask);
    await waitFor(tester, find.text(de.inboxFiled));
    await fileAs(tester, 'E2E Vom Kind abgelegt', de.commonTask);
    await waitFor(tester, find.text(de.inboxEmpty));
    await engine.sync();

    // On this device: the task and note for the adults, the appointment
    // confidential.
    final hidden = engine.tasks.singleWhere(
      (t) => t.title == 'E2E Brief Aufgabe',
    );
    expect(hidden.visibleTo, containsAll([me, f.bea.id, f.carl.id]));
    expect(hidden.visibleTo, isNot(contains(f.kid.id)));
    expect(hidden.visibleTo, isNot(contains(f.guest.id)));
    final note = engine.notes.singleWhere((n) => n.title == 'E2E Brief Notiz');
    expect(note.visibleTo, isNot(contains(f.kid.id)));
    final event = engine.events.singleWhere(
      (e) => e.title == 'E2E Brief Termin',
    );
    expect(event.confidential, isTrue);
    expect(DateUtils.isSameDay(event.start, day), isTrue);
    expect(
      engine.tasks
          .singleWhere((t) => t.title == 'E2E Ausflug Aufgabe')
          .visibleTo,
      isNull,
    );

    // What the others get from the server.
    await eventually(tester, 'Bea gets task, note and appointment', () async {
      return (await titlesOf(
            bea,
            Collections.tasks,
          )).containsAll({'E2E Brief Aufgabe', 'E2E Ausflug Aufgabe'}) &&
          (await titlesOf(
            bea,
            Collections.notes,
          )).contains('E2E Brief Notiz') &&
          (await titlesOf(
            bea,
            Collections.events,
          )).contains('E2E Brief Termin');
    });
    final kidTasks = await titlesOf(kid, Collections.tasks);
    expect(kidTasks, contains('E2E Ausflug Aufgabe'));
    expect(kidTasks, contains('E2E Vom Kind abgelegt'));
    expect(kidTasks, isNot(contains('E2E Brief Aufgabe')));
    expect(
      await titlesOf(kid, Collections.notes),
      isNot(contains('E2E Brief Notiz')),
    );
    expect(
      await titlesOf(guest, Collections.notes),
      isNot(contains('E2E Brief Notiz')),
    );
    // The confidential appointment: the child gets it not at all (neither
    // title nor time, as KAL-037), not even as "Belegt".
    final kidEvents = await pull(kid, Collections.events);
    expect(kidEvents.containsKey(event.id), isFalse);
    expect(
      kidEvents.values.map((r) => '${r.data['title']}'),
      isNot(contains('E2E Brief Termin')),
    );
    debugPrint(
      'E2E-INFO GRU-187: the child receives the confidential appointment: '
      '${kidEvents.containsKey(event.id)}',
    );

    for (final t in engine.tasks.where(
      (t) =>
          t.title == 'E2E Brief Aufgabe' ||
          t.title == 'E2E Ausflug Aufgabe' ||
          t.title == 'E2E Vom Kind abgelegt',
    )) {
      engine.deleteTask(t.id);
    }
    engine
      ..deleteNote(note.id)
      ..deleteEvent(event.id);
    await engine.sync();
    await finish(tester, state);
  });

  testWidgets('GRU-188 GRU-079 filed as a document: category and audience', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final kid = await sessionOf(f.kid);
    var state = await start(tester);
    var engine = state.engine!;
    await clearInbox(engine);
    final me = state.me!.id;
    final letter = await uploadAs(engine.api, 'e2e-arztbrief.pdf', _pdf);
    final shared = await uploadAs(engine.api, 'e2e-elternbrief.pdf', _pdf);
    engine
      ..saveInboxItem(inboxItem(me, 'E2E Arztbrief', files: [letter]))
      ..saveInboxItem(
        inboxItem(me, 'E2E Elternbrief', files: [shared], forChildren: true),
      );
    await engine.sync();
    await openInbox(tester);
    await waitFor(tester, find.text('E2E Arztbrief'));
    await waitFor(tester, find.text('E2E Elternbrief'));

    // Not shared with the children: all categories, "Sonstiges", the adults.
    await fileAs(tester, 'E2E Arztbrief', de.commonDocument);
    await waitFor(tester, inDialog(find.text(de.inboxDocumentTitle)));
    expect(inDialog(find.text(de.commonCategory)), findsOneWidget);
    expect(inDialog(find.text(de.commonWhoMaySee)), findsOneWidget);
    for (final c in DocumentCategory.values) {
      expect(
        inDialog(find.widgetWithText(ChoiceChip, c.label)),
        findsOneWidget,
        reason: c.label,
      );
    }
    expect(chipSelected(tester, DocumentCategory.other.label), isTrue);
    for (final a in [
      de.commonWholeFamily,
      de.inboxDocumentAdults,
      de.docsOnlyMe,
    ]) {
      expect(audienceTile(tester, a).enabled ?? true, isTrue, reason: a);
    }
    expect(chosenAudience(tester), de.inboxDocumentAdults);
    // "Gesundheit": "Nur ich", as long as nothing was chosen.
    await tap(tester, inDialog(find.text(DocumentCategory.health.label)));
    expect(chipSelected(tester, DocumentCategory.health.label), isTrue);
    expect(chosenAudience(tester), de.docsOnlyMe);
    await tap(tester, inDialog(find.text(de.inboxDocumentAdults)));
    expect(chosenAudience(tester), de.inboxDocumentAdults);
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonSave)),
    );
    await dialogClosed(tester);
    await waitFor(tester, find.text(de.inboxFiled));
    final doc = engine.documents.singleWhere((d) => d.title == 'E2E Arztbrief');
    expect(doc.category, DocumentCategory.health);
    expect(doc.file?.id, letter.id);
    expect(doc.visibleTo, containsAll([me, f.bea.id, f.carl.id]));
    expect(doc.visibleTo, isNot(contains(f.kid.id)));
    expect(find.text('E2E Arztbrief'), findsNothing, reason: 'filed');

    // Shared with the children: the whole family first; "Abbrechen" keeps
    // the entry.
    await fileAs(tester, 'E2E Elternbrief', de.commonDocument);
    await waitFor(tester, inDialog(find.text(de.inboxDocumentTitle)));
    expect(chosenAudience(tester), de.commonWholeFamily);
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    expect(find.text('E2E Elternbrief'), findsOneWidget);
    expect(
      engine.documents.where((d) => d.title == 'E2E Elternbrief'),
      isEmpty,
    );
    expect(engine.inboxItems.map((i) => i.title), contains('E2E Elternbrief'));
    await engine.sync();
    await eventually(
      tester,
      'Bea gets the health letter, the child not',
      () async => (await titlesOf(
        await sessionOf(f.bea),
        Collections.documents,
      )).contains('E2E Arztbrief'),
    );
    expect(
      await titlesOf(kid, Collections.documents),
      isNot(contains('E2E Arztbrief')),
    );
    engine.delete(Collections.documents, doc.id);
    await clearInbox(engine);
    await finish(tester, state);

    // A child files its own entry with "Gesundheit": "Ganze Familie" is off.
    final own = await uploadAs(kid, 'e2e-kind-befund.pdf', _pdf);
    final ownId = newId();
    await seed(kid, Collections.inbox, {
      ownId: InboxItem(
        id: ownId,
        title: 'E2E Befund vom Kind',
        files: [own],
        createdAt: DateTime.now(),
        createdBy: f.kid.id,
      ).toData(),
    });
    state = await start(tester, user: f.kid.username);
    engine = state.engine!;
    await openInbox(tester);
    await waitFor(tester, find.text('E2E Befund vom Kind'));
    await fileAs(tester, 'E2E Befund vom Kind', de.commonDocument);
    await waitFor(tester, inDialog(find.text(de.inboxDocumentTitle)));
    expect(audienceTile(tester, de.commonWholeFamily).enabled ?? true, isTrue);
    await tap(tester, inDialog(find.text(DocumentCategory.health.label)));
    expect(audienceTile(tester, de.commonWholeFamily).enabled, isFalse);
    expect(chosenAudience(tester), de.docsOnlyMe);
    // Tapped anyway: it stays "Nur ich".
    await tap(tester, inDialog(find.text(de.commonWholeFamily)));
    expect(chosenAudience(tester), de.docsOnlyMe);
    await tap(
      tester,
      inDialog(find.widgetWithText(FilledButton, de.commonSave)),
    );
    await dialogClosed(tester);
    await waitFor(tester, find.text(de.inboxFiled));
    final kidDoc = engine.documents.singleWhere(
      (d) => d.title == 'E2E Befund vom Kind',
    );
    expect(kidDoc.category, DocumentCategory.health);
    expect(kidDoc.visibleTo, [f.kid.id]);
    await engine.sync();
    await eventually(
      tester,
      'the child\'s health document on the server',
      () async => (await titlesOf(
        kid,
        Collections.documents,
      )).contains('E2E Befund vom Kind'),
    );
    engine.delete(Collections.documents, kidDoc.id);
    await engine.sync();
    await finish(tester, state);
  });

  // === Abgelehnte Änderung ===================================================

  testWidgets('GRU-189 a change the server refuses is told once', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final b = await freshMember('e2e-gru-rolle', 'E2E Rollenwechsel');
    final id = uid('note');
    await seed(f.admin, Collections.notes, {
      id: FamilyNote(
        id: id,
        title: 'E2E Familiennotiz Rolle',
        text: 'Stand des Servers',
      ).toData(),
    });
    addTearDown(() => remove(f.admin, Collections.notes, [id]));
    final gate = await openGate();
    final state = await start(tester, user: b.username, url: gate.url);
    final engine = state.engine!;
    await eventually(
      tester,
      'the note on this device',
      () async => engine.notes.any((n) => n.id == id),
    );

    // Changed offline; meanwhile an admin makes B a guest.
    gate.cut();
    engine.saveNote(
      FamilyNote(id: id, title: 'E2E Familiennotiz Rolle', text: 'Von B'),
    );
    await tester.pump(const Duration(seconds: 1));
    await f.admin.updateUser(b.id, role: MemberRole.guest);
    gate.restore();
    await tester.pump(const Duration(seconds: 2));
    nudge(state);
    final told = find.text(de.syncChangesRefused(1));
    await waitFor(tester, told, timeout: const Duration(seconds: 90));
    expect(
      de.syncChangesRefused(1),
      'Eine Änderung ist für dein Konto nicht erlaubt und wurde '
      'zurückgenommen.',
    );
    final shownAt = DateTime.now();
    await waitGone(tester, told, timeout: const Duration(seconds: 20));
    final shownFor = DateTime.now().difference(shownAt);
    debugPrint('E2E-INFO GRU-189: the notice stood for $shownFor');
    expect(shownFor.inSeconds, inInclusiveRange(5, 12));
    // Once: nothing more after further syncs.
    for (var i = 0; i < 3; i++) {
      await engine.sync().catchError((Object _) {});
      await tester.pump(const Duration(seconds: 3));
      expect(told, findsNothing);
    }
    // The note as the server has it, here and there.
    expect(
      engine.notes.singleWhere((n) => n.id == id).text,
      'Stand des Servers',
    );
    expect(
      (await pull(f.admin, Collections.notes))[id]?.data['text'],
      'Stand des Servers',
    );
    await finish(tester, state);
  });

  // === Suche: Abos und Geburtstage ===========================================

  testWidgets('GRU-191 subscribed appointments and birthdays in the search', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    final calendars = CalendarServer();
    await calendars.start();
    addTearDown(calendars.close);
    final day = inDays(3);
    calendars.feeds['schule'] = ics(
      'E2E Schulkalender',
      'E2E Elternsprechtag',
      day,
      17,
    );
    final sub = uid('sub');
    await seed(f.admin, Collections.calendarSubscriptions, {
      sub: CalendarSubscription(
        id: sub,
        name: 'E2E Schulkalender',
        url: calendars.url('schule'),
        color: 0xFF2A9D6E,
        ownerId: f.adminMember.id,
      ).toData(),
    });
    addTearDown(
      () => remove(f.admin, Collections.calendarSubscriptions, [sub]),
    );
    final ottilie = await freshMember('e2e-gru-geb', 'E2E Ottilie');
    final birthday = inDays(10);
    await f.admin.updateUser(
      ottilie.id,
      birthday: Birthday(birthday.month, birthday.day, 1990),
    );
    try {
      debugPrint(
        'E2E-INFO subscription: ${(await f.admin.refreshSubscription(sub)).eventCount}',
      );
    } on ApiError catch (e) {
      debugPrint('E2E-INFO refreshing the subscription: $e');
    }

    final state = await start(tester);
    final engine = state.engine!;
    await eventually(
      tester,
      'the subscribed appointment on this device',
      () async {
        if (!engine.externalEvents.any(
          (e) => e.title == 'E2E Elternsprechtag',
        )) {
          try {
            await f.admin.refreshSubscription(sub);
          } on ApiError catch (e) {
            debugPrint('E2E-INFO refreshing the subscription: $e');
          }
          await engine.sync().catchError((Object _) {});
          return false;
        }
        return true;
      },
      timeout: const Duration(seconds: 90),
    );
    await eventually(
      tester,
      'the birthday here',
      () async =>
          engine.members.any((m) => m.id == ottilie.id && m.birthday != null),
    );

    // The subscribed one: under "Termine", only to read; then its day.
    await search(tester, 'Elternsprechtag');
    final hit = find.text('E2E Elternsprechtag');
    await waitFor(tester, hit);
    expect(heading(de.commonEvents), findsOneWidget);
    expect(
      tester.getTopLeft(heading(de.commonEvents)).dy,
      lessThan(tester.getTopLeft(hit).dy),
    );
    await tap(tester, hit);
    final sheet = find.byType(BottomSheet);
    await waitFor(tester, sheet);
    expect(
      find.descendant(
        of: sheet,
        matching: find.text(de.calendarSourceReadOnlyMake('E2E Schulkalender')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text(de.commonSave)),
      findsNothing,
    );
    await closeSheet(tester);
    await waitGone(tester, sheet);
    await openSection(tester, 'Kalender');
    await waitFor(tester, find.text(DateFormat.MMMMEEEEd('de').format(day)));
    await waitFor(tester, find.text('E2E Elternsprechtag'));

    // The birthday: under "Termine" with "Geburtstag".
    await search(tester, 'Ottilie');
    final cake = find.text('🎂 E2E Ottilie');
    await waitFor(tester, cake);
    expect(heading(de.commonEvents), findsOneWidget);
    expect(subtitleOf(tester, cake), startsWith(de.commonBirthday));
    await tap(tester, cake);
    await waitFor(tester, sheet);
    expect(
      find.descendant(of: sheet, matching: find.text('🎂 E2E Ottilie')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text(de.commonSave)),
      findsNothing,
    );
    await closeSheet(tester);
    await waitGone(tester, sheet);
    await openSection(tester, 'Kalender');
    await waitFor(
      tester,
      find.text(DateFormat.MMMMEEEEd('de').format(birthday)),
    );
    await finish(tester, state);
  });

  // === Wandanzeige eines Dienstkontos ========================================

  testWidgets('GRU-198 the wall display of a service account ticks off', (
    tester,
  ) async {
    tall(tester, width: 1300, height: 1600);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final wall = await freshMember(
      'e2e-gru-wand',
      'E2E Wandtablet',
      role: MemberRole.service,
    );
    await f.admin.updateUser(wall.id, serviceAccess: ServiceAccess.everyday);
    final id = uid('task');
    final task = Task(
      id: id,
      title: 'E2E Altpapier',
      due: today(),
      repeat: TaskRepeat.weekly,
    );
    await seed(f.admin, Collections.tasks, {id: task.toData()});
    addTearDown(() => remove(f.admin, Collections.tasks, [id]));
    final gate = await openGate();
    final state = await start(tester, user: wall.username, url: gate.url);
    await eventually(
      tester,
      'the task on the tablet',
      () async => state.engine!.tasks.any((t) => t.id == id),
    );
    await openSettingsItem(tester, de.settingsOpenKiosk);
    await waitFor(tester, find.byType(KioskScreen));
    await tap(tester, find.byTooltip(de.kioskShowPerson));
    await waitFor(tester, find.byTooltip(de.kioskShowTopic));
    final check = roundCheck('E2E Altpapier');
    await waitFor(tester, check);

    // Ticked off while the tablet is away; at the same time A writes a
    // note to the task.
    gate.cut();
    await tap(tester, check);
    await tester.pump(const Duration(seconds: 1));
    final current = (await pull(bea, Collections.tasks))[id]!;
    await putLatest(bea, Collections.tasks, id, {
      ...current.data,
      'notes': 'E2E Bündeln nicht vergessen',
    });
    gate.restore();
    await tester.pump(const Duration(seconds: 2));
    nudge(state);
    await eventually(tester, 'the tick on the server, the note kept', () async {
      final r = (await pull(bea, Collections.tasks))[id];
      if (r == null) return false;
      final t = Task.fromRecord(r);
      return t.due != null &&
          DateUtils.isSameDay(t.due!.toLocal(), inDays(7)) &&
          t.notes == 'E2E Bündeln nicht vergessen';
    }, timeout: const Duration(seconds: 90));
    final onBea = Task.fromRecord((await pull(bea, Collections.tasks))[id]!);
    expect(onBea.done, isFalse, reason: 'a weekly task moves on');
    expect(onBea.title, 'E2E Altpapier');
    expect(
      (await pull(
        f.admin,
        Collections.conflicts,
      )).values.where((r) => r.data['recordId'] == id),
      isEmpty,
      reason: 'no conflict copy',
    );
    // The wall display shows no error.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text(de.syncChangesRefused(1)), findsNothing);
      expect(find.text(de.syncChangesPartlyKept(1)), findsNothing);
    }
    expect(
      state.engine!.tasks.singleWhere((t) => t.id == id).notes,
      'E2E Bündeln nicht vergessen',
    );
    await tap(tester, find.byTooltip(de.kioskCloseWallDisplay));
    await finish(tester, state);
  });
}
