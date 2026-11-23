// Catalog ALL, entries added on 23.11.2026 (ALL-206 … ALL-236) and the
// changed ALL-009, in the real app against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_all_c_test.dart
//
// Guests and their own tasks, ticks written offline, declined requests,
// routines of siblings, wishes from a second device, pocket money over a
// deleted holiday, savings goals, packing lists of someone who left, a
// large file in the chat, wishes and gift ideas. What a person does goes
// through the app's own pages; what another device, member or account does
// goes through the API. The helpers are those of catalog_all_a_test.dart.
//
// ALL-227 needs the server restarted (it books pocket money when it
// starts): tool/integration_tests.sh runs it through tool/e2e_server.py,
// which puts a backup taken just before back and starts it again.
// e2e-control: restore
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/chores_screens.dart';
import 'package:famio/src/screens/kiosk_screen.dart';
import 'package:famio/src/widgets/member_avatar.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';

// --- family and data ---------------------------------------------------------

Future<FamilyMember>? _kid2;

/// A second child next to the kit's family (rotations, siblings).
Future<FamilyMember> secondKid() => _kid2 ??= () async {
  final f = await theFamily();
  for (final u in await f.admin.adminUsers()) {
    if (u.member.username == 'e2e-kind2') return u.member;
  }
  return f.admin.createMember(
    username: 'e2e-kind2',
    displayName: 'E2E Fips',
    password: kitMemberPassword,
    role: MemberRole.child,
  );
}();

Future<FamioApiClient> apiOf(FamilyMember m) async {
  final f = await theFamily();
  return m.id == f.adminMember.id ? f.admin : sessionOf(m);
}

/// Writes [records] like [api]'s member; the server must take them.
Future<void> seed(
  FamioApiClient api,
  String collection,
  Map<String, Map<String, Object?>> records,
) async {
  final r = await put(api, collection, records);
  expect(r.rejected.map((x) => x.id), isEmpty, reason: 'seed of $collection');
}

/// Whether the server turns down [data] as [id] from [api]'s member.
Future<bool> refused(
  FamioApiClient api,
  String collection,
  String id,
  Map<String, Object?> data,
) async {
  final r = await put(api, collection, {id: data});
  return r.rejected.any((x) => x.id == id);
}

/// Removes the tasks of earlier tests ("E2E …"), seen by any member.
Future<void> resetTasks() async {
  final f = await theFamily();
  for (final m in [f.adminMember, f.bea, f.carl, f.kid]) {
    final api = await apiOf(m);
    final ids = [
      for (final r in (await pull(api, Collections.tasks)).values)
        if ('${r.data['title']}'.startsWith('E2E')) r.id,
    ];
    if (ids.isNotEmpty) await remove(api, Collections.tasks, ids);
  }
}

const _choreCollections = [
  Collections.chores,
  Collections.routines,
  Collections.routineRuns,
  Collections.rewards,
  Collections.pointEntries,
  Collections.allowances,
  Collections.moneyEntries,
  Collections.savingsGoals,
  Collections.vacations,
  Collections.absences,
];

/// No chores, routines, rewards, points, money, goals, holidays or
/// absences: each test of those starts empty.
Future<void> resetChores() async {
  final f = await theFamily();
  await secondKid();
  for (final c in _choreCollections) {
    final ids = (await pull(f.admin, c)).keys.toList();
    if (ids.isNotEmpty) await remove(f.admin, c, ids);
  }
}

/// A task written by [api]'s member (another device); its id.
Future<String> addTask(
  FamioApiClient api,
  String title, {
  DateTime? due,
  List<String> assignees = const [],
  List<String>? visibleTo,
  TaskRepeat? repeat,
  DateTime? remindAt,
  List<TaskStep> checklist = const [],
  List<FileRef> photos = const [],
  String notes = '',
  bool confirm = false,
}) async {
  final id = uid('task');
  await seed(api, Collections.tasks, {
    id: Task(
      id: id,
      title: title,
      notes: notes,
      due: due,
      assigneeIds: assignees,
      visibleTo: visibleTo,
      repeat: repeat,
      remindAt: remindAt,
      checklist: checklist,
      photos: photos,
      createdAt: DateTime.now(),
      assignmentConfirmation: AssignmentSettings(required: confirm),
    ).toData(),
  });
  return id;
}

Future<SyncRecord?> taskNamed(FamioApiClient api, String title) async =>
    (await pull(
      api,
      Collections.tasks,
    )).values.where((r) => r.data['title'] == title).firstOrNull;

/// The decision [who] gave on the server for record [id] of [collection].
Future<String?> decisionOf(
  FamioApiClient api,
  FamilyMember who,
  String collection,
  String id,
) async {
  final record = (await pull(api, collection))[id];
  if (record == null) return null;
  final answers = await pull(api, Collections.assignmentResponses);
  for (final request in assignmentRequests(record, timeZone: 'Europe/Berlin')) {
    if (request.memberId != who.id) continue;
    final reply = answers[request.id];
    if (reply != null && reply.data['fingerprint'] == request.fingerprint) {
      return reply.data['decision'] as String?;
    }
  }
  return null;
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

Future<String> addChore(
  String title, {
  List<String> members = const [],
  bool rotate = false,
  ChoreRepeat repeat = ChoreRepeat.daily,
  int points = 2,
  DateTime? start,
  String emoji = '🧹',
  bool paused = false,
}) async {
  final f = await theFamily();
  final id = uid('chore');
  await seed(f.admin, Collections.chores, {
    id: Chore(
      id: id,
      title: title,
      emoji: emoji,
      points: points,
      memberIds: members,
      rotate: rotate,
      repeat: repeat,
      start: start ?? today(),
      paused: paused,
    ).toData(),
  });
  return id;
}

Future<String> addRoutine(
  String title, {
  String? member,
  int points = 2,
  Set<int> weekdays = const {},
  List<(String, String)> steps = const [('🪥', 'E2E Putzen')],
  String emoji = '🪥',
}) async {
  final f = await theFamily();
  final id = uid('routine');
  await seed(f.admin, Collections.routines, {
    id: Routine(
      id: id,
      title: title,
      emoji: emoji,
      memberId: member,
      weekdays: weekdays,
      points: points,
      steps: [
        for (final (i, (e, t)) in steps.indexed)
          RoutineStep(id: 'step$i', title: t, emoji: e),
      ],
    ).toData(),
  });
  return id;
}

Future<String> addReward(String title, int cost, {String emoji = '🎁'}) async {
  final f = await theFamily();
  final id = uid('reward');
  await seed(f.admin, Collections.rewards, {
    id: Reward(id: id, title: title, emoji: emoji, cost: cost).toData(),
  });
  return id;
}

/// Points the admin booked for [m] (approved).
Future<String> addPoints(
  FamilyMember m,
  int points, {
  String title = 'E2E Startpunkte',
}) async {
  final f = await theFamily();
  final id = uid('points');
  await seed(f.admin, Collections.pointEntries, {
    id: PointEntry(
      id: id,
      memberId: m.id,
      points: points,
      title: title,
      kind: PointKind.bonus,
      at: DateTime.now(),
      decidedBy: f.adminMember.id,
    ).toData(),
  });
  return id;
}

Future<void> addMoney(FamilyMember m, int cents, {String note = ''}) async {
  final f = await theFamily();
  final id = uid('money');
  await seed(f.admin, Collections.moneyEntries, {
    id: MoneyEntry(
      id: id,
      memberId: m.id,
      cents: cents,
      at: DateTime.now(),
      kind: MoneyKind.gift,
      note: note,
    ).toData(),
  });
}

/// Pocket money paid on a day that is not today (no booking meanwhile).
Future<Allowance> addAllowance(
  FamilyMember m, {
  int weekly = 500,
  int perPoint = 0,
}) async {
  final f = await theFamily();
  final a = Allowance(
    memberId: m.id,
    weeklyCents: weekly,
    payday: today().weekday % 7 + 1,
    since: today(),
    centsPerPoint: perPoint,
  );
  await seed(f.admin, Collections.allowances, {m.id: a.toData()});
  return a;
}

Future<String> addAbsence(
  FamilyMember who,
  DateTime from,
  DateTime to, {
  FamilyMember? substitute,
  String title = '',
  String? id,
}) async {
  final f = await theFamily();
  final key = id ?? uid('absence');
  await seed(f.admin, Collections.absences, {
    key: MemberAbsence(
      id: key,
      memberId: who.id,
      from: from,
      to: to,
      substituteId: substitute?.id,
      title: title,
    ).toData(),
  });
  return key;
}

// --- files ---------------------------------------------------------------------

/// A file on disk as the file picker hands it over.
final class _DiskFile extends PlatformFile {
  _DiskFile(this.file);

  final File file;

  @override
  String get name => file.uri.pathSegments.last;

  @override
  Uri get uri => file.uri;

  @override
  get xFile => throw UnimplementedError('not used by the app');

  @override
  int? lengthSync() => file.lengthSync();

  @override
  Future<int?> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

/// Stands in for the native open panel: returns the files queued in
/// [picks].
class FakePicker extends FilePickerPlatform {
  final picks = <File>[];

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => picks.isEmpty ? [] : [_DiskFile(picks.removeAt(0))];
}

FakePicker fakePicker() {
  final before = FilePickerPlatform.instance;
  final fake = FakePicker();
  FilePickerPlatform.instance = fake;
  addTearDown(() => FilePickerPlatform.instance = before);
  return fake;
}

Future<Directory> _tempDir() async =>
    Directory('${(await getTemporaryDirectory()).path}/famio-e2e-all')
      ..createSync(recursive: true);

/// A PNG; [big] ones (noise, about 9 MB) take a while to upload.
Future<Uint8List> pngBytes({bool big = false}) async {
  final ui.Image image;
  if (big) {
    const side = 1500;
    final random = math.Random(7);
    final pixels = Uint8List(side * side * 4);
    for (var i = 0; i < pixels.length; i++) {
      pixels[i] = i % 4 == 3 ? 255 : random.nextInt(256);
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      side,
      side,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    image = await done.future;
  } else {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 64, 64),
      Paint()..color = const Color(0xFF3D8BD1),
    );
    image = await recorder.endRecording().toImage(64, 64);
  }
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<File> diskFile(String name, List<int> bytes) async =>
    File('${(await _tempDir()).path}/$name')..writeAsBytesSync(bytes);

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
  tall(tester);
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

// --- the app -------------------------------------------------------------------

/// A window as high as a big screen: lists and sheets build everything at
/// once (lists only build what is near the screen).
void tall(WidgetTester tester) {
  tester.view.physicalSize =
      const Size(800, 1600) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}

Future<AppState> start(WidgetTester tester, {String? user}) async {
  tall(tester);
  await secondKid();
  return startApp(tester, user: user);
}

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
      throw TestFailure('Timed out: $what\nOn screen: ${onScreen()}');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Waits for what another device wrote.
Future<void> arrives(
  WidgetTester tester,
  AppState state,
  bool Function(SyncEngine engine) ok,
  String what,
) async {
  debugPrint('E2E arrives $what');
  final end = DateTime.now().add(const Duration(seconds: 45));
  while (!ok(state.engine!)) {
    if (DateTime.now().isAfter(end)) throw TestFailure('Timed out: $what');
    try {
      await state.engine!.sync();
    } catch (_) {}
    await tester.pump(const Duration(milliseconds: 500));
  }
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> synced(WidgetTester tester, AppState state) async {
  await state.engine!.sync();
  await tester.pump(const Duration(milliseconds: 500));
}

Finder byTypeName(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

final pillTabs = find.byWidgetPredicate(
  (w) => w.runtimeType.toString().startsWith('PillTabs<'),
);

List<String> tabLabels(WidgetTester tester) {
  final w = tester.widget(pillTabs.first) as dynamic;
  return [for (final v in w.values as List) w.label(v) as String];
}

Future<void> tab(WidgetTester tester, String label) async {
  await snackGone(tester);
  await tap(
    tester,
    find.descendant(of: pillTabs.first, matching: find.text(label)),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

Finder sheet() => find.byType(BottomSheet);
Finder inSheet(Finder f) => find.descendant(of: sheet(), matching: f);
Finder dialog() => find.byWidgetPredicate((w) => w is Dialog);
Finder inDialog(Finder f) => find.descendant(of: dialog(), matching: f);

/// Closes the open sheet and waits until it is gone.
Future<void> closeSheet(WidgetTester tester) async {
  await leaveField(tester);
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pump(const Duration(milliseconds: 300));
  await waitGone(tester, sheet(), timeout: const Duration(seconds: 10));
  await tester.pump(const Duration(milliseconds: 300));
}

/// "Speichern" of the open sheet; waits until the sheet is gone.
Future<void> saveSheet(WidgetTester tester) async {
  await leaveField(tester);
  await tap(tester, inSheet(find.text(de.commonSave)));
  await waitGone(tester, sheet(), timeout: const Duration(seconds: 10));
  await tester.pump(const Duration(milliseconds: 300));
}

Finder snackText(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

Future<void> undo(WidgetTester tester) => tap(
  tester,
  find.descendant(
    of: find.byType(SnackBar),
    matching: find.text(de.commonUndo),
  ),
);

/// Taps [finder] [times] times quickly (steppers).
Future<void> press(WidgetTester tester, Finder finder, int times) async {
  await waitFor(tester, finder);
  for (var i = 0; i < times; i++) {
    await tester.tap(finder.first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> enterAt(
  WidgetTester tester,
  Finder fields,
  int i,
  String text,
) async {
  final f = fields.at(i);
  await waitFor(tester, f);
  await tester.ensureVisible(f);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(f, warnIfMissed: false);
  await tester.pump();
  await tester.enterText(f, text);
  await tester.pump();
}

bool enabledButton(WidgetTester tester, Finder button) =>
    (tester.widget(button.first) as dynamic).onPressed != null;

Finder colorButton(String label) =>
    find.byWidgetPredicate((w) => w is ColorButton && w.label == label);

/// The texts inside [f] (top to bottom as built).
List<String> textsIn(Finder f) => [
  for (final e
      in find.descendant(of: f, matching: find.byType(Text)).evaluate())
    ?((e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText()),
];

double _top(Element e) =>
    (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;

/// The list heading ("Heute", "Ohne Datum", "Für alle" …) [text] stands
/// under.
String? headingOf(WidgetTester tester, String text) {
  final y = _top(find.text(text).evaluate().first);
  String? best;
  var bestY = double.negativeInfinity;
  for (final e in find.byType(ListHeading).evaluate()) {
    final hy = _top(e);
    if (hy < y && hy > bestY) {
      best = (e.widget as ListHeading).text;
      bestY = hy;
    }
  }
  return best;
}

/// Whether [a] is shown above [b].
bool above(String a, String b) =>
    _top(find.text(a).evaluate().first) < _top(find.text(b).evaluate().first);

/// The Material date picker: [date] typed in; whether it was accepted.
Future<bool> typeDate(WidgetTester tester, DateTime date) async {
  final input = find.widgetWithText(TextField, 'Datum eingeben');
  if (input.evaluate().isEmpty) {
    await tap(tester, find.byTooltip('Zur Texteingabe wechseln'));
  }
  await enter(tester, input, DateFormat.yMd('de').format(date));
  await tester.tap(find.text('OK').last, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 900));
  return input.evaluate().isEmpty;
}

/// The Material date range picker, typed in; the app's own dialog follows.
Future<void> pickRange(WidgetTester tester, DateTime from, DateTime to) async {
  await tap(tester, find.byTooltip('Zur Texteingabe wechseln'));
  await enter(
    tester,
    find.widgetWithText(TextField, 'Startdatum'),
    DateFormat.yMd('de').format(from),
  );
  await enter(
    tester,
    find.widgetWithText(TextField, 'Enddatum'),
    DateFormat.yMd('de').format(to),
  );
  await tap(tester, find.text('OK').last);
  await tester.pump(const Duration(milliseconds: 800));
}

/// The Material time picker, typed in (24 hours).
Future<void> pickTime(WidgetTester tester, int hour, int minute) async {
  await waitFor(tester, dialog());
  final keyboard = inDialog(find.byIcon(Icons.keyboard_outlined));
  if (keyboard.evaluate().isNotEmpty) await tap(tester, keyboard);
  final fields = inDialog(find.byType(TextField));
  await waitFor(tester, fields);
  await tester.enterText(fields.at(0), '$hour');
  await tester.pump();
  await tester.enterText(fields.at(1), minute.toString().padLeft(2, '0'));
  await tester.pump();
  await tester.tap(find.text('OK').last, warnIfMissed: false);
  await dialogClosed(tester);
}

/// Opens the drop-down labelled [label]; the texts of its menu.
Future<List<String>> openMenu(WidgetTester tester, String label) async {
  await tap(
    tester,
    find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
    ),
  );
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

// --- tasks on screen -----------------------------------------------------------

final quickField = field(de.tasksNewTask);
final titleField = field(de.commonTitle);

Future<void> openTasks(WidgetTester tester) async {
  await openSection(tester, 'Aufgaben');
  await waitFor(tester, pillTabs);
}

/// [text] on a card (not in a field still being typed into).
Finder onCard(String text) =>
    find.descendant(of: find.byType(SoftCard), matching: find.text(text));

Future<void> quickAdd(WidgetTester tester, String title) async {
  await enter(tester, quickField, title);
  await tap(tester, find.byTooltip(de.commonAdd));
  await waitFor(tester, onCard(title));
}

Future<void> newTaskSheet(WidgetTester tester) async {
  await snackGone(tester);
  await tap(tester, find.byTooltip(de.tasksCreateTaskDetails));
  await waitFor(tester, inSheet(titleField));
}

Future<void> openTask(WidgetTester tester, String title) async {
  await snackGone(tester);
  await waitFor(tester, find.text(title));
  await tap(tester, find.text(title).first);
  await waitFor(tester, sheet());
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> moreOptions(WidgetTester tester) async {
  if (inSheet(find.text(de.tasksMoreOptions)).evaluate().isNotEmpty) {
    await tap(tester, inSheet(find.text(de.tasksMoreOptions)));
  }
}

Future<void> chooseAssignee(WidgetTester tester, String name) =>
    tap(tester, inSheet(find.widgetWithText(FilterChip, name)).first);

Future<void> setDue(WidgetTester tester, DateTime day) async {
  await tap(tester, inSheet(find.text(de.tasksDue)));
  expect(await typeDate(tester, day), isTrue, reason: 'due date accepted');
  await dialogClosed(tester);
}

/// A new task through the editor.
Future<void> newTask(
  WidgetTester tester,
  String title, {
  String notes = '',
  DateTime? due,
  List<String> assignees = const [],
  String? audience,
}) async {
  await newTaskSheet(tester);
  await enter(tester, inSheet(titleField), title);
  if (notes.isNotEmpty) {
    await enter(tester, inSheet(field(de.commonNotes)), notes);
  }
  if (due != null) await setDue(tester, due);
  for (final name in assignees) {
    await chooseAssignee(tester, name);
  }
  if (audience != null) {
    await moreOptions(tester);
    await tap(tester, inSheet(find.text(audience)));
  }
  await saveSheet(tester);
  await waitFor(tester, find.text(title));
}

Finder taskCheck(String title) =>
    find.descendant(of: cardOf(title), matching: find.byType(RoundCheck));

/// The second line of a task in the list (date, repetition, steps …).
String subtitleOf(String title) =>
    textsIn(cardOf(title)).where((t) => t != title).firstOrNull ?? '';

Task taskOf(AppState state, String title) =>
    state.engine!.tasks.singleWhere((t) => t.title == title);

String assignment(String who, String status) =>
    '$who · ${de.assignmentTask} · $status';

// --- chores on screen ----------------------------------------------------------

Future<void> openChores(WidgetTester tester) async {
  await openSection(tester, 'Ämter');
  await waitFor(tester, find.text(de.choresChoresPoints));
}

Finder personBlock(String memberId) => find.byWidgetPredicate(
  (w) =>
      w.runtimeType.toString() == '_PersonToday' &&
      (w as dynamic).person.id == memberId,
);

Finder inPerson(String memberId, Finder f) =>
    find.descendant(of: personBlock(memberId), matching: f);

Finder choreTile(String title) => find.byWidgetPredicate(
  (w) =>
      w.runtimeType.toString() == '_ChoreTile' &&
      (w as dynamic).chore.title == title,
);

Finder routineTile(String title) => find.byWidgetPredicate(
  (w) =>
      w.runtimeType.toString() == '_RoutineTile' &&
      (w as dynamic).routine.title == title,
);

/// "+3 ⭐ · erledigt" of a chore on "Heute".
String choreStatus(String title) =>
    textsIn(choreTile(title)).firstWhere((t) => t.startsWith('+'));

Finder choreCheck(String title) =>
    find.descendant(of: choreTile(title), matching: find.byType(RoundCheck));

/// The points shown next to [memberId] on "Heute".
int shownPoints(WidgetTester tester, String memberId) =>
    (tester.widget(inPerson(memberId, byTypeName('_PointsChip')).first)
                as dynamic)
            .points
        as int;

/// The line under a chore of the tab "Ämter".
String choreLine(String title) =>
    textsIn(cardOf(title)).firstWhere((t) => t.contains(' · '));

Future<void> newChoreSheet(WidgetTester tester) async {
  await snackGone(tester);
  await tap(tester, find.byTooltip(de.choresCreateChore));
  await waitFor(tester, inSheet(find.text(de.choresNewChore)));
}

/// "+"/"−" of the open stepper (sheet or dialog).
Finder stepperButton(String tooltip) => find.ancestor(
  of: find.descendant(
    of: byTypeName('_Stepper'),
    matching: find.byTooltip(tooltip),
  ),
  matching: find.byType(IconButton),
);

dynamic stepper(WidgetTester tester) =>
    tester.widget(byTypeName('_Stepper').last) as dynamic;

Future<void> openAccount(WidgetTester tester, String name) async {
  await tab(tester, de.settingsAccount);
  await tap(tester, find.text(name).last);
  await waitFor(tester, find.text(de.choresPocketMoney));
}

/// The row of a points or money entry in the account (its title).
Finder accountRow(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ListTile)).first;

/// "+3", "−3,50 €" … on the right of an account row.
Text trailingOf(WidgetTester tester, String title) =>
    tester.widget<ListTile>(accountRow(title)).trailing! as Text;

// --- more of this file ----------------------------------------------------------

/// Removes what the admin gets of [collections], so a test starts empty.
Future<void> clean(Iterable<String> collections) async {
  final f = await theFamily();
  for (final c in collections) {
    final ids = (await pull(f.admin, c)).keys.toList();
    if (ids.isNotEmpty) await remove(f.admin, c, ids);
  }
}

Future<void> openSettingsEntry(WidgetTester tester, String entry) async {
  await openSection(tester, 'Einstellungen');
  await scrollTo(tester, find.text(entry));
  await tap(tester, find.text(entry));
  await dismissTip(tester);
}

/// The name of an item (or wish …) in its card.
Finder itemName(String name) =>
    find.descendant(of: find.byType(SoftCard), matching: find.text(name));

/// A heading of a packing list (person or "Für alle").
Finder packingHeading(String label) => find.byWidgetPredicate(
  (w) =>
      w.runtimeType.toString() == '_AisleHeading' &&
      (w as dynamic).label == label,
);

/// The texts of an open drop-down menu.
List<String> openMenuTexts() => [
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

/// The texts of the snack bars on screen (also inside a sheet).
List<String> snackTexts() => [
  for (final e
      in find
          .descendant(of: find.byType(SnackBar), matching: find.byType(Text))
          .evaluate())
    ?((e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText()),
];

/// A picked file that cannot be read (moved away, no permission …): its
/// stream fails at once.
final class _UnreadableFile extends PlatformFile {
  _UnreadableFile(this._name, this._length);

  final String _name;
  final int _length;

  @override
  String get name => _name;

  @override
  Uri get uri => Uri.file('/nicht/mehr/da/$_name');

  @override
  get xFile => throw UnimplementedError('not used by the app');

  @override
  int? lengthSync() => _length;

  @override
  Future<int?> length() async => _length;

  @override
  Future<Uint8List> readAsBytes() =>
      Future.error(const FileSystemException('E2E nicht lesbar'));

  @override
  Stream<Uint8List> readAsByteStream() =>
      Stream.error(const FileSystemException('E2E nicht lesbar'));
}

/// Like [FakePicker], but hands over [PlatformFile]s as they are.
class FakeFilePicker extends FilePickerPlatform {
  final picks = <PlatformFile>[];

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => picks.isEmpty ? [] : [picks.removeAt(0)];
}

FakeFilePicker fakeFilePicker() {
  final before = FilePickerPlatform.instance;
  final fake = FakeFilePicker();
  FilePickerPlatform.instance = fake;
  addTearDown(() => FilePickerPlatform.instance = before);
  return fake;
}

/// A file on disk as the picker hands it over.
PlatformFile pickedDisk(File file) => _DiskFile(file);

/// Stands in for the browser and "open with the system's app".
class FakeLauncher extends UrlLauncherPlatform {
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

FakeLauncher fakeLauncher() {
  final before = UrlLauncherPlatform.instance;
  final fake = FakeLauncher();
  UrlLauncherPlatform.instance = fake;
  addTearDown(() => UrlLauncherPlatform.instance = before);
  return fake;
}

/// A PDF over 8 MiB: the app streams files of that size to the server.
List<int> bigPdf() => [
  ...'%PDF-1.4\n%E2E\n'.codeUnits,
  ...List.filled(9 * 1024 * 1024, 0x20),
  ...'\n%%EOF\n'.codeUnits,
];

// --- restarting the server ---------------------------------------------------------

const _control = String.fromEnvironment('FAMIO_E2E_CONTROL');

/// Starts the server again with the data it has: a backup now, put back
/// right away (tool/e2e_server.py stops, restores and starts it). The
/// server books pocket money when it starts.
Future<void> restartServer() async {
  expect(_control, isNotEmpty, reason: 'FAMIO_E2E_CONTROL (e2e-control)');
  final f = await theFamily();
  await f.admin.backupNow();
  final status = await f.admin.backupStatus();
  final newest = (status['backups'] as List).first['name'] as String;
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('$_control/restore').replace(queryParameters: {'name': newest}),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200, reason: body);
    final answer = jsonDecode(body) as Map<String, Object?>;
    expect(answer['ok'], isTrue, reason: '${answer['output']}');
  } finally {
    client.close(force: true);
  }
}

// --- chores of today --------------------------------------------------------------

/// A request of [m] for [choreId] today, as an adult decided it.
Future<String> addDecided(
  String choreId,
  String title,
  FamilyMember m, {
  required PointStatus status,
  int points = 2,
}) async {
  final f = await theFamily();
  final key = Chore(
    id: choreId,
    title: '',
    start: today(),
  ).completionId(today());
  await seed(f.admin, Collections.pointEntries, {
    key: PointEntry(
      id: key,
      memberId: m.id,
      points: points,
      title: title,
      kind: PointKind.chore,
      at: DateTime.now(),
      refId: choreId,
      status: status,
      decidedBy: f.adminMember.id,
    ).toData(),
  });
  return key;
}

Future<SyncRecord?> pointEntry(String id) async {
  final f = await theFamily();
  return (await pull(f.admin, Collections.pointEntries))[id];
}

/// A wish of [m] for [rewardId], as the child's app sends it.
Map<String, Object?> wishData(
  FamilyMember m,
  String rewardId,
  String title,
  int cost,
) => PointEntry(
  id: '',
  memberId: m.id,
  points: -cost,
  title: title,
  kind: PointKind.reward,
  at: DateTime.now(),
  refId: rewardId,
  status: PointStatus.pending,
).toData();

/// Swipes the task with [id] to the left, as to delete it.
Future<void> swipeTask(WidgetTester tester, String id) async {
  await snackGone(tester);
  await tester.drag(find.byKey(ValueKey(id)), const Offset(-600, 0));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

DismissDirection swipeOf(WidgetTester tester, String title) => tester
    .widget<Dismissible>(
      find
          .ancestor(of: find.text(title), matching: find.byType(Dismissible))
          .first,
    )
    .direction;

/// Writes [data] over [stored] like a device of [api]'s member that has
/// that version (its revision goes along, as the app sends it).
Future<SyncResponse> putOver(
  FamioApiClient api,
  SyncRecord stored,
  Map<String, Object?> data,
) => api.sync(
  SyncRequest(
    since: 0,
    changes: [
      SyncRecord(
        collection: stored.collection,
        id: stored.id,
        data: data,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        rev: stored.rev,
      ),
    ],
  ),
);

/// The conflicts the server keeps for [recordId] (seen by the admin).
Future<List<SyncConflict>> conflictsOf(String recordId) async {
  final f = await theFamily();
  return [
    for (final r in (await pull(f.admin, Collections.conflicts)).values)
      if (r.data['recordId'] == recordId) SyncConflict.fromRecord(r),
  ];
}

/// No message about refused or partly kept changes for a while, syncing.
Future<void> noRefusalTold(WidgetTester tester, AppState state) async {
  final end = DateTime.now().add(const Duration(seconds: 6));
  while (DateTime.now().isBefore(end)) {
    unawaited(state.engine!.sync().catchError((Object _) {}));
    await tester.pump(const Duration(milliseconds: 300));
    final told = snackTexts().where(
      (t) =>
          t.contains(de.syncChangesPartlyKept(1)) ||
          t.contains(de.syncChangesRefused(1)),
    );
    expect(told, isEmpty, reason: 'no message: $told');
  }
}

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // =========================================================================
  // Aufgaben (geändert: ALL-009)
  // =========================================================================

  // The reminder moves on by days and keeps its time, also over the change
  // to summer time (#581): from Thursday 25 March 2027 (winter time) to
  // Thursday 1 April (summer time), 18:00 stays 18:00.
  testWidgets('ALL-009 the reminder keeps its time over the clock change', (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    final due = DateTime(2027, 3, 25);
    final remind = DateTime(2027, 3, 25, 18);
    await addTask(
      f.admin,
      'E2E Zeitumstellung',
      due: due,
      repeat: TaskRepeat.weekly,
      remindAt: remind,
    );
    final state = await start(tester);
    await openTasks(tester);
    await scrollTo(tester, find.text('E2E Zeitumstellung'));
    await tap(tester, taskCheck('E2E Zeitumstellung'));
    final next = DateTime(2027, 4, 1);
    await waitFor(
      tester,
      snackText(
        de.tasksTitleDoneDueAgain(
          'E2E Zeitumstellung',
          DateFormat.MMMMEEEEd('de').format(next),
        ),
      ),
    );
    final moved = taskOf(state, 'E2E Zeitumstellung');
    expect(DateUtils.dateOnly(moved.due!), next);
    final at = moved.remindAt!.toLocal();
    debugPrint('E2E-INFO ALL-009 reminder now $at (was $remind)');
    expect(
      (at.year, at.month, at.day, at.hour, at.minute),
      (2027, 4, 1, 18, 0),
      reason: 'the same time a week later, though summer time began',
    );
    await synced(tester, state);
    await eventually(tester, 'on the server too', () async {
      final r = await taskNamed(f.admin, 'E2E Zeitumstellung');
      final t = r == null ? null : Task.fromRecord(r);
      return t != null && t.remindAt!.toLocal() == DateTime(2027, 4, 1, 18);
    });
    await finish(tester, state);
  });

  // =========================================================================
  // Aufgaben – Gäste
  // =========================================================================

  testWidgets('ALL-206 ALL-207 a guest changes and deletes an own task', (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    final state = await start(tester, user: f.guest.username);
    await openTasks(tester);
    await quickAdd(tester, 'E2E Gast angelegt');
    final id = taskOf(state, 'E2E Gast angelegt').id;
    await synced(tester, state);
    // ALL-206: the normal editor, title and who takes care changed.
    await openTask(tester, 'E2E Gast angelegt');
    expect(inSheet(titleField), findsOneWidget, reason: 'the editor');
    expect(inSheet(find.text(de.commonSave)), findsWidgets);
    expect(inSheet(find.text(de.commonClose)), findsNothing);
    await enter(tester, inSheet(titleField), 'E2E Gast geändert');
    await chooseAssignee(tester, f.bea.displayName);
    await saveSheet(tester);
    await waitFor(tester, find.text('E2E Gast geändert'));
    await synced(tester, state);
    await eventually(tester, 'A gets the change', () async {
      final r = (await pull(f.admin, Collections.tasks))[id];
      if (r == null) return false;
      final t = Task.fromRecord(r);
      return t.title == 'E2E Gast geändert' && t.assigneeIds.contains(f.bea.id);
    });
    final changed = (await pull(f.admin, Collections.tasks))[id]!;
    expect(changed.data[Task.createdByKey], f.guest.id, reason: 'creator');
    final guest = await sessionOf(f.guest);
    expect((await pull(guest, Collections.tasks))[id], isNotNull);

    // ALL-207: swiping and "Rückgängig" …
    expect(swipeOf(tester, 'E2E Gast geändert'), DismissDirection.endToStart);
    await swipeTask(tester, id);
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Gast geändert')));
    await state.engine!.sync();
    final goneForA = (await pull(f.admin, Collections.tasks))[id] == null;
    debugPrint('E2E-INFO ALL-207 deleted for A before the undo: $goneForA');
    await undo(tester);
    await waitFor(tester, find.text('E2E Gast geändert'));
    await synced(tester, state);
    await eventually(
      tester,
      'back for A',
      () async => (await pull(f.admin, Collections.tasks))[id] != null,
    );
    expect(goneForA, isTrue, reason: 'the server took the deletion');
    final back = Task.fromRecord((await pull(f.admin, Collections.tasks))[id]!);
    expect(back.title, 'E2E Gast geändert');
    // … and "Löschen" in the editor.
    await openTask(tester, 'E2E Gast geändert');
    await tap(tester, inSheet(find.text(de.commonDelete)));
    await waitGone(tester, sheet());
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Gast geändert')));
    await synced(tester, state);
    await eventually(
      tester,
      'gone for A',
      () async => (await pull(f.admin, Collections.tasks))[id] == null,
    );
    expect((await pull(guest, Collections.tasks))[id], isNull);
    await finish(tester, state);
  });

  // A task of the family assigned to the guest stays for reading. A task of
  // the guest from before the creator was noted (2.0.54) cannot be made on
  // this server: it notes the creator of every new task
  // (server/lib/src/record_store.dart _withCreator), and its database is
  // encrypted; that part is not checked here.
  testWidgets(
    'ALL-208 ALL-049 the family\'s task stays for reading; the server keeps '
    'it',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final id = await addTask(
        f.admin,
        'E2E Von A für den Gast',
        assignees: [f.guest.id],
        notes: 'E2E Notiz von A',
      );
      final state = await start(tester, user: f.guest.username);
      await openTasks(tester);
      await waitFor(tester, find.text('E2E Von A für den Gast'));
      expect(swipeOf(tester, 'E2E Von A für den Gast'), DismissDirection.none);
      await tester.drag(find.byKey(ValueKey(id)), const Offset(-600, 0));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('E2E Von A für den Gast'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await openTask(tester, 'E2E Von A für den Gast');
      expect(inSheet(find.text(de.commonClose)), findsOneWidget);
      expect(inSheet(find.text(de.commonSave)), findsNothing);
      expect(inSheet(titleField), findsNothing);
      await tap(tester, inSheet(find.text(de.commonClose)));
      await waitGone(tester, sheet());
      // Through the API: of a new title only nothing, the deletion refused.
      final guest = await sessionOf(f.guest);
      final current = (await pull(guest, Collections.tasks))[id]!;
      final renamed = await put(guest, Collections.tasks, {
        id: {...current.data, 'title': 'E2E Gast benennt um'},
      });
      debugPrint(
        'E2E-INFO ALL-208 renamed: refused '
        '${renamed.refused.map((i) => i.code).toList()}',
      );
      final deleted = await remove(guest, Collections.tasks, [id]);
      expect(deleted.refused.where((i) => i.id == id).map((i) => i.code), [
        'not_allowed',
      ]);
      final answer = deleted.rejected.where((r) => r.id == id);
      expect(answer, isNotEmpty, reason: 'answered with the task');
      expect(answer.first.deleted, isFalse);
      final kept = Task.fromRecord(
        (await pull(f.admin, Collections.tasks))[id]!,
      );
      expect(kept.title, 'E2E Von A für den Gast');
      expect(kept.notes, 'E2E Notiz von A');
      expect((await pull(guest, Collections.tasks))[id], isNotNull);
      await synced(tester, state);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('E2E Von A für den Gast'), findsOneWidget);
      expect(find.text('E2E Gast benennt um'), findsNothing);
      await finish(tester, state);
    },
  );

  // ALL-211, and the end of ALL-216: written on an older version, no
  // message.
  testWidgets('ALL-211 ALL-216 a guest ticks offline while A renames: done, '
      'renamed, no conflict, no message', (tester) async {
    await resetTasks();
    final f = await theFamily();
    final id = await addTask(
      f.admin,
      'E2E Offline abhaken',
      assignees: [f.guest.id],
    );
    final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
    await gate.start();
    addTearDown(gate.close);
    final state = await startVia(tester, gate.url, f.guest.username);
    await openTasks(tester);
    await waitFor(tester, find.text('E2E Offline abhaken'));
    await synced(tester, state);
    gate.cut();
    await tester.pump(const Duration(seconds: 1));
    await tap(tester, taskCheck('E2E Offline abhaken'));
    await waitGone(tester, find.text('E2E Offline abhaken'));
    await tester.pump(const Duration(seconds: 1));
    // Meanwhile A changes the title.
    final current = (await pull(f.admin, Collections.tasks))[id]!;
    await putOver(f.admin, current, {
      ...current.data,
      'title': 'E2E Von A umbenannt',
    });
    gate.restore();
    final guest = await sessionOf(f.guest);
    await eventually(tester, 'done and renamed for everyone', () async {
      unawaited(state.engine!.sync().catchError((Object _) {}));
      for (final api in [f.admin, guest]) {
        final r = (await pull(api, Collections.tasks))[id];
        if (r == null) return false;
        final t = Task.fromRecord(r);
        if (!t.done || t.title != 'E2E Von A umbenannt') return false;
      }
      return true;
    }, timeout: const Duration(seconds: 90));
    await noRefusalTold(tester, state);
    await arrives(
      tester,
      state,
      (e) => e.tasks.any((t) => t.id == id && t.title == 'E2E Von A umbenannt'),
      'the new title on the device',
    );
    expect(taskOf(state, 'E2E Von A umbenannt').done, isTrue);
    expect(await conflictsOf(id), isEmpty, reason: 'no conflict copy');
    await finish(tester, state);
  });

  testWidgets('ALL-216 a new title from a guest is left out, told once', (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    final guest = await sessionOf(f.guest);
    // Through the API, on the stored version: the answer says it.
    final first = await addTask(
      f.admin,
      'E2E Gast schickt Titel',
      assignees: [f.guest.id],
    );
    final current = (await pull(guest, Collections.tasks))[first]!;
    final answer = await put(guest, Collections.tasks, {
      first: {...current.data, 'title': 'E2E Neuer Gasttitel', 'done': true},
    });
    expect(answer.refused.where((i) => i.id == first).map((i) => i.code), [
      'partly_kept',
    ]);
    final stored = Task.fromRecord(
      (await pull(f.admin, Collections.tasks))[first]!,
    );
    expect(stored.done, isTrue, reason: 'the tick is kept');
    expect(stored.title, 'E2E Gast schickt Titel', reason: 'not the title');
    // In the guest's app (as an older app would send it): told once.
    final second = await addTask(
      f.admin,
      'E2E Gast App Titel',
      assignees: [f.guest.id],
      checklist: const [TaskStep(id: 'a', text: 'E2E Schritt')],
    );
    final state = await start(tester, user: f.guest.username);
    await openTasks(tester);
    await waitFor(tester, find.text('E2E Gast App Titel'));
    final engine = state.engine!;
    final mine = engine.record(Collections.tasks, second)!;
    engine.put(Collections.tasks, second, {
      ...mine.data,
      'title': 'E2E App Gasttitel',
      'checklist': const [
        {'id': 'a', 'text': 'E2E Schritt', 'done': true},
      ],
    });
    unawaited(engine.sync().catchError((Object _) {}));
    await waitFor(
      tester,
      find.textContaining(de.syncChangesPartlyKept(1)),
      timeout: const Duration(seconds: 45),
    );
    await arrives(
      tester,
      state,
      (e) => e.tasks.any(
        (t) =>
            t.id == second &&
            t.title == 'E2E Gast App Titel' &&
            t.checklist.single.done,
      ),
      'the stored title back, the step ticked',
    );
    await snackGone(tester);
    // Once: further syncs tell nothing more.
    await noRefusalTold(tester, state);
    final server = Task.fromRecord(
      (await pull(f.admin, Collections.tasks))[second]!,
    );
    expect(server.title, 'E2E Gast App Titel');
    expect(server.checklist.single.done, isTrue);
    await finish(tester, state);
  });

  testWidgets('ALL-215 a guest\'s own task: the newer change wins, the '
      'guest\'s is kept as a conflict', (tester) async {
    await resetTasks();
    final f = await theFamily();
    final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
    await gate.start();
    addTearDown(gate.close);
    final state = await startVia(tester, gate.url, f.guest.username);
    await openTasks(tester);
    await quickAdd(tester, 'E2E Gast eigene Fassung');
    final id = taskOf(state, 'E2E Gast eigene Fassung').id;
    await synced(tester, state);
    await eventually(
      tester,
      'A sees it',
      () async => (await pull(f.admin, Collections.tasks))[id] != null,
    );
    gate.cut();
    await tester.pump(const Duration(seconds: 1));
    await openTask(tester, 'E2E Gast eigene Fassung');
    await enter(tester, inSheet(titleField), 'E2E Gast offline geändert');
    await saveSheet(tester);
    await waitFor(tester, find.text('E2E Gast offline geändert'));
    await tester.pump(const Duration(seconds: 2));
    // Later, online: A changes it (A's device has the stored version).
    final current = (await pull(f.admin, Collections.tasks))[id]!;
    final byA = await putOver(f.admin, current, {
      ...current.data,
      'title': 'E2E A später geändert',
    });
    expect(byA.rejected.where((r) => r.id == id), isEmpty);
    gate.restore();
    await eventually(tester, 'the conflict kept', () async {
      unawaited(state.engine!.sync().catchError((Object _) {}));
      return (await conflictsOf(id)).isNotEmpty;
    }, timeout: const Duration(seconds: 90));
    final stored = Task.fromRecord(
      (await pull(f.admin, Collections.tasks))[id]!,
    );
    expect(stored.title, 'E2E A später geändert', reason: 'the newer one');
    final conflicts = await conflictsOf(id);
    debugPrint(
      'E2E-INFO ALL-215 conflicts: ${[for (final c in conflicts) '${c.lost['title']} by ${c.lostBy}, kept by ${c.keptBy}']}',
    );
    expect(
      conflicts.where(
        (c) =>
            c.lost['title'] == 'E2E Gast offline geändert' &&
            c.lostBy == f.guest.id,
      ),
      hasLength(1),
      reason: "the guest's version kept once",
    );
    await arrives(
      tester,
      state,
      (e) =>
          e.tasks.any((t) => t.id == id && t.title == 'E2E A später geändert'),
      'A\'s version on the device',
    );
    await finish(tester, state);
  });

  // =========================================================================
  // Aufgaben – Anhänge
  // =========================================================================

  testWidgets('ALL-219 a failed upload shows over the task editor', (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    final picker = fakeFilePicker();
    final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
    await gate.start();
    addTearDown(gate.close);
    final state = await startVia(tester, gate.url, f.bea.username);
    await openTasks(tester);
    await newTaskSheet(tester);
    await enter(tester, inSheet(titleField), 'E2E Anhang scheitert');
    await moreOptions(tester);
    final attach = inSheet(find.byTooltip(de.tasksAddPhoto));
    Future<String> attachFails() async {
      await tap(tester, attach);
      await waitFor(
        tester,
        inSheet(find.byType(SnackBar)),
        timeout: const Duration(seconds: 60),
      );
      final text = snackTexts().join(' ');
      // Shown in the sheet's own messenger, over it.
      expect(sheet(), findsOneWidget, reason: 'the editor stays open');
      expect(
        find.descendant(of: sheet(), matching: find.byType(SnackBar)),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsOneWidget, reason: 'not behind');
      return text;
    }

    // A file that cannot be read (large, so it is streamed).
    picker.picks.add(_UnreadableFile('e2e-weg.pdf', 9 * 1024 * 1024));
    final unreadable = await attachFails();
    debugPrint('E2E-INFO ALL-219 unreadable file: $unreadable');
    expect(unreadable.trim(), isNotEmpty);
    await waitGone(
      tester,
      find.byType(SnackBar),
      timeout: const Duration(seconds: 15),
    );
    // The server out of reach.
    picker.picks.add(
      pickedDisk(await diskFile('e2e-anhang.png', await pngBytes())),
    );
    gate.cut();
    final offline = await attachFails();
    debugPrint('E2E-INFO ALL-219 server gone: $offline');
    expect(offline.trim(), isNotEmpty);
    // The editor goes on: still typed in, saved.
    expect(
      tester.widget<TextField>(inSheet(titleField)).controller?.text,
      'E2E Anhang scheitert',
    );
    await enter(tester, inSheet(titleField), 'E2E Anhang gescheitert');
    await saveSheet(tester);
    await waitFor(tester, find.text('E2E Anhang gescheitert'));
    expect(taskOf(state, 'E2E Anhang gescheitert').photos, isEmpty);
    gate.restore();
    await tester.pump(const Duration(seconds: 1));
    await state.engine!.sync().catchError((Object _) {});
    await finish(tester, state);
  });

  // =========================================================================
  // Ämter & Punkte
  // =========================================================================

  testWidgets('ALL-221 ALL-222 declined requests: asked again by its own '
      'child, not by a sibling', (tester) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    final own = await addChore(
      'E2E Abgelehnt eigen',
      members: [f.kid.id],
      points: 2,
    );
    final shared = await addChore(
      'E2E Abgelehnt Geschwister',
      members: [f.kid.id, fips.id],
      points: 3,
    );
    final ownId = await addDecided(
      own,
      'E2E Abgelehnt eigen',
      f.kid,
      status: PointStatus.rejected,
    );
    final sharedId = await addDecided(
      shared,
      'E2E Abgelehnt Geschwister',
      fips,
      status: PointStatus.rejected,
      points: 3,
    );
    var state = await start(tester, user: f.kid.username);
    await openChores(tester);
    await waitFor(tester, choreTile('E2E Abgelehnt eigen'));
    expect(choreStatus('E2E Abgelehnt eigen'), '+2 ⭐ · ${de.choresDeclined}');
    expect(
      choreStatus('E2E Abgelehnt Geschwister'),
      '+3 ⭐ · ${de.choresDeclined}',
    );
    // ALL-222: the sibling's declined one cannot be tapped.
    expect(
      tester
          .widget<RoundCheck>(choreCheck('E2E Abgelehnt Geschwister'))
          .onChanged,
      isNull,
    );
    await tester.tap(
      choreCheck('E2E Abgelehnt Geschwister'),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(
      choreStatus('E2E Abgelehnt Geschwister'),
      '+3 ⭐ · ${de.choresDeclined}',
    );
    // ALL-221: its own one asks again.
    await tap(tester, choreCheck('E2E Abgelehnt eigen'));
    await until(
      tester,
      () =>
          choreStatus('E2E Abgelehnt eigen') ==
          '+2 ⭐ · ${de.choresWaitingConfirmation2}',
      'waiting again',
    );
    await synced(tester, state);
    await eventually(
      tester,
      'a request again on the server',
      () async =>
          (await pointEntry(ownId))?.data['status'] == PointStatus.pending.name,
    );
    await finish(tester, state);
    // The adults see it under "Wartet auf deine Bestätigung".
    state = await start(tester);
    await openChores(tester);
    await waitFor(tester, find.text(de.choresWaitingConfirmation));
    await waitFor(
      tester,
      find.text('${f.kid.displayName}: E2E Abgelehnt eigen'),
    );
    await finish(tester, state);
    // Confirming it itself is turned down; taking it back is the child's.
    final kid = await sessionOf(f.kid);
    final pending = (await pointEntry(ownId))!;
    final self = await put(kid, Collections.pointEntries, {
      ownId: {
        ...pending.data,
        'status': PointStatus.approved.name,
        'decidedBy': f.kid.id,
      },
    });
    expect(self.refused.where((i) => i.id == ownId), isNotEmpty);
    expect((await pointEntry(ownId))!.data['status'], PointStatus.pending.name);
    final back = await remove(kid, Collections.pointEntries, [ownId]);
    expect(back.refused.where((i) => i.id == ownId), isEmpty);
    expect(await pointEntry(ownId), isNull, reason: 'taken back');
    // ALL-222: the sibling's request neither asked again nor taken back.
    final again = await put(kid, Collections.pointEntries, {
      sharedId: PointEntry(
        id: sharedId,
        memberId: f.kid.id,
        points: 3,
        title: 'E2E Abgelehnt Geschwister',
        kind: PointKind.chore,
        at: DateTime.now(),
        refId: shared,
        status: PointStatus.pending,
      ).toData(),
    });
    final gone = await remove(kid, Collections.pointEntries, [sharedId]);
    expect(again.refused.where((i) => i.id == sharedId), isNotEmpty);
    expect(gone.refused.where((i) => i.id == sharedId), isNotEmpty);
    final stays = PointEntry.fromRecord((await pointEntry(sharedId))!);
    expect(stays.status, PointStatus.rejected);
    expect(stays.memberId, fips.id);
  });

  testWidgets('ALL-223 a child ticks off only its own routines', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    final mine = await addRoutine(
      'E2E Routine Kind',
      member: f.kid.id,
      steps: const [('🪥', 'E2E Kind putzt')],
    );
    final theirs = await addRoutine(
      'E2E Routine Fips',
      member: fips.id,
      steps: const [('🧦', 'E2E Fips zieht an')],
    );
    final state = await start(tester, user: f.kid.username);
    await openChores(tester);
    await tab(tester, de.choresTabRoutines);
    bool struckText(String t) =>
        tester.widget<Text>(find.text(t)).style?.decoration ==
        TextDecoration.lineThrough;
    // The sibling's routine: its steps do not tick.
    await tap(tester, find.text('E2E Routine Fips'));
    await waitFor(tester, find.byType(RoutineRunScreen));
    expect(
      tester.widget<RoutineRunScreen>(find.byType(RoutineRunScreen)).memberId,
      fips.id,
    );
    await tap(tester, find.text('E2E Fips zieht an'));
    await tester.pump(const Duration(seconds: 1));
    expect(struckText('E2E Fips zieht an'), isFalse);
    expect(
      state.engine!
          .records(Collections.routineRuns)
          .where((r) => r.data['routineId'] == theirs),
      isEmpty,
    );
    await back(tester);
    // Through the API: the server turns the sibling's progress down.
    final kid = await sessionOf(f.kid);
    final run = RoutineRun(
      id: Routine(id: theirs, title: '').runId(today(), fips.id),
      routineId: theirs,
      memberId: fips.id,
      day: today(),
      done: const {'step0'},
    );
    final answer = await put(kid, Collections.routineRuns, {
      run.id: run.toData(),
    });
    expect(answer.refused.where((i) => i.id == run.id), isNotEmpty);
    expect((await pull(f.admin, Collections.routineRuns))[run.id], isNull);
    // Its own routine it ticks off.
    await tab(tester, de.choresTabRoutines);
    await tap(tester, find.text('E2E Routine Kind'));
    await waitFor(tester, find.byType(RoutineRunScreen));
    await tap(tester, find.text('E2E Kind putzt'));
    await until(tester, () => struckText('E2E Kind putzt'), 'ticked');
    await synced(tester, state);
    final ownRun = Routine(id: mine, title: '').runId(today(), f.kid.id);
    await eventually(
      tester,
      'its run on the server',
      () async => RoutineRun.fromRecord(
        (await pull(f.admin, Collections.routineRuns))[ownRun] ??
            SyncRecord(
              collection: Collections.routineRuns,
              id: ownRun,
              data: const {},
              updatedAt: 0,
            ),
      ).done.contains('step0'),
    );
    await back(tester);
    await finish(tester, state);
  });

  // Hint from the catalog review: guests may write routineRuns at all
  // (Collections.guestWritable), and the server checks no more for them
  // (server/lib/src/record_store.dart:360). What the server does with a
  // guest's progress of a child's routine.
  testWidgets('ALL-223 hint: a guest writes the progress of a child\'s '
      'routine', (tester) async {
    await resetChores();
    final f = await theFamily();
    final routine = await addRoutine(
      'E2E Routine Gastprobe',
      member: f.kid.id,
      points: 2,
      steps: const [('🪥', 'E2E Putzen')],
    );
    final guest = await sessionOf(f.guest);
    final run = RoutineRun(
      id: Routine(id: routine, title: '').runId(today(), f.kid.id),
      routineId: routine,
      memberId: f.kid.id,
      day: today(),
      done: const {'step0'},
    );
    final answer = await put(guest, Collections.routineRuns, {
      run.id: run.toData(),
    });
    final stored = (await pull(f.admin, Collections.routineRuns))[run.id];
    debugPrint(
      'E2E-INFO ALL-223 hint: refused ${answer.refused.map((i) => i.code)}, '
      'rejected ${answer.rejected.map((r) => r.id)}, stored by '
      '${stored?.updatedBy}: ${stored?.data}',
    );
    // Observed: the server takes it, the child's routine counts as done.
    expect(answer.refused, isEmpty);
    expect(stored, isNotNull);
    expect(stored!.updatedBy, f.guest.id);
    expect(RoutineRun.fromRecord(stored).done, {'step0'});
    final kid = await sessionOf(f.kid);
    expect((await pull(kid, Collections.routineRuns))[run.id], isNotNull);
    await remove(f.admin, Collections.routineRuns, [run.id]);
  });

  testWidgets('ALL-225 a wish from a second device over the set aside '
      'points', (tester) async {
    await resetChores();
    final f = await theFamily();
    final reward = await addReward('E2E Zweitgerät', 20, emoji: '🎮');
    await addPoints(f.kid, 20);
    final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
    await gate.start();
    addTearDown(gate.close);
    final state = await startVia(tester, gate.url, f.kid.username);
    final engine = state.engine!;
    await openChores(tester);
    await tab(tester, de.choresTabRewards);
    await waitFor(tester, find.text('E2E Zweitgerät'));
    await synced(tester, state);
    expect(engine.pointBalance(f.kid.id), 20);
    gate.cut();
    await tester.pump(const Duration(seconds: 1));
    // Device 1 wishes first.
    final kid = await sessionOf(f.kid);
    final first = uid('wish');
    final answer = await put(kid, Collections.pointEntries, {
      first: wishData(f.kid, reward, '🎮 E2E Zweitgerät', 20),
    });
    expect(answer.rejected.where((r) => r.id == first), isEmpty);
    // Device 2 (offline) does not know it yet and wishes too.
    await tap(
      tester,
      find.descendant(
        of: cardOf('E2E Zweitgerät'),
        matching: find.text(de.rewardsRedeem),
      ),
    );
    await tap(tester, find.text(de.rewardsWish));
    await dialogClosed(tester);
    await waitFor(tester, snackText(de.rewardsWishSent));
    final second = engine.pendingPoints.single.id;
    expect(second, isNot(first));
    await snackGone(tester);
    gate.restore();
    final end = DateTime.now().add(const Duration(seconds: 90));
    while (snackText(de.syncChangesRefused(1)).evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) {
        throw TestFailure('no refusal told\nOn screen: ${onScreen()}');
      }
      unawaited(engine.sync().catchError((Object _) {}));
      await tester.pump(const Duration(milliseconds: 500));
    }
    await arrives(
      tester,
      state,
      (e) => e.pendingPoints.length == 1 && e.pendingPoints.single.id == first,
      'only the first wish',
    );
    final onServer = await pull(f.admin, Collections.pointEntries);
    expect(onServer.containsKey(first), isTrue);
    expect(onServer.containsKey(second), isFalse, reason: 'not taken');
    // Confirmed: 0, not below.
    final wish = PointEntry.fromRecord(onServer[first]!);
    await seed(f.admin, Collections.pointEntries, {
      first: wish.decide(PointStatus.approved, f.adminMember.id).toData(),
    });
    await arrives(tester, state, (e) => e.pendingPoints.isEmpty, 'confirmed');
    expect(engine.pointBalance(f.kid.id), 0);
    await finish(tester, state);
  });

  // Hint from the catalog review (rewards.dart:59): adults who redeem for a
  // child are checked against the confirmed balance only, not against what
  // the child's open wishes set aside. What happens.
  testWidgets('ALL-225 hint: adults redeem for a child past its open wishes', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final reward = await addReward('E2E Für das Kind', 20, emoji: '🚲');
    await addPoints(f.kid, 20);
    final kid = await sessionOf(f.kid);
    final wish = uid('wish');
    await seed(kid, Collections.pointEntries, {
      wish: wishData(f.kid, reward, '🚲 E2E Für das Kind', 20),
    });
    final state = await start(tester);
    final engine = state.engine!;
    await openChores(tester);
    await tab(tester, de.choresTabRewards);
    await waitFor(tester, find.text('E2E Für das Kind'));
    await arrives(
      tester,
      state,
      (e) => e.pendingPoints.any((p) => p.id == wish),
      'the open wish',
    );
    await tap(
      tester,
      find.descendant(
        of: cardOf('E2E Für das Kind'),
        matching: find.text(de.rewardsRedeem),
      ),
    );
    await waitFor(tester, find.text(de.rewardsWhoRedeems));
    await tap(
      tester,
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text(f.kid.displayName),
      ),
    );
    await dialogClosed(tester);
    await tester.pump(const Duration(seconds: 1));
    final told = snackTexts();
    debugPrint('E2E-INFO ALL-225 hint: the adult is told $told');
    final redeemed = told.contains(de.rewardsTitleRedeemed('E2E Für das Kind'));
    // The open wish is confirmed afterwards.
    await synced(tester, state);
    final open = PointEntry.fromRecord(
      (await pull(f.admin, Collections.pointEntries))[wish]!,
    );
    await seed(f.admin, Collections.pointEntries, {
      wish: open.decide(PointStatus.approved, f.adminMember.id).toData(),
    });
    await arrives(tester, state, (e) => e.pendingPoints.isEmpty, 'confirmed');
    final balance = engine.pointBalance(f.kid.id);
    debugPrint(
      'E2E-INFO ALL-225 hint: redeemed $redeemed, balance afterwards $balance',
    );
    // Observed: the app redeems, the child ends below zero.
    expect(redeemed, isTrue);
    expect(balance, -20);
    await finish(tester, state);
  });

  // =========================================================================
  // Ämter – Taschengeld & Sparziele
  // =========================================================================

  testWidgets('ALL-230 savings goals changed and deleted, by adults and the '
      'child', (tester) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    await addMoney(f.kid, 300);
    final goal = uid('goal');
    await seed(f.admin, Collections.savingsGoals, {
      goal: SavingsGoal(
        id: goal,
        memberId: f.kid.id,
        title: 'E2E Roller',
        targetCents: 800,
        emoji: '🛴',
      ).toData(),
    });
    Future<void> changeAmount(String amount) async {
      await tap(tester, find.text('E2E Roller'));
      await waitFor(tester, find.text(de.savingsGoalEdit));
      await enter(tester, inDialog(field(de.savingsGoalAmount)), amount);
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
    }

    Future<void> deleteAndBack() async {
      await snackGone(tester);
      await tester.longPress(find.text('E2E Roller'));
      await tester.pump(const Duration(milliseconds: 500));
      await waitFor(tester, snackText(de.undoWhatDeleted('E2E Roller')));
      expect(find.text('E2E Roller'), findsNothing);
      await undo(tester);
      await waitFor(tester, find.text('E2E Roller'));
    }

    Future<int> target() async => SavingsGoal.fromRecord(
      (await pull(f.admin, Collections.savingsGoals))[goal]!,
    ).targetCents;

    // An adult.
    var state = await start(tester);
    await openChores(tester);
    await openAccount(tester, f.kid.displayName);
    await scrollTo(tester, find.text('E2E Roller'));
    await changeAmount('12');
    await waitFor(
      tester,
      find.text(de.savingsGoalProgress(formatEuro(300), formatEuro(1200))),
    );
    await deleteAndBack();
    await synced(tester, state);
    await eventually(tester, 'changed and back', () async {
      final r = (await pull(f.admin, Collections.savingsGoals))[goal];
      return r != null && await target() == 1200;
    });
    await finish(tester, state);
    // The child, its own goal.
    state = await start(tester, user: f.kid.username);
    await openChores(tester);
    await tab(tester, de.settingsAccount);
    await waitFor(tester, find.text(f.kid.displayName));
    expect(find.text(fips.displayName), findsNothing, reason: 'not its own');
    await tap(tester, find.text(f.kid.displayName).last);
    await waitFor(tester, find.text(de.choresPocketMoney));
    await scrollTo(tester, find.text('E2E Roller'));
    await changeAmount('15');
    await waitFor(
      tester,
      find.text(de.savingsGoalProgress(formatEuro(300), formatEuro(1500))),
    );
    await deleteAndBack();
    await synced(tester, state);
    await eventually(tester, 'the child\'s change on the server', () async {
      final r = (await pull(f.admin, Collections.savingsGoals))[goal];
      return r != null && await target() == 1500;
    });
    await finish(tester, state);
  });

  // =========================================================================
  // Einkauf – Packlisten
  // =========================================================================

  testWidgets('ALL-231 a packing list keeps the things of someone who left', (
    tester,
  ) async {
    final f = await theFamily();
    await clean(const [Collections.shoppingItems, Collections.shoppingLists]);
    final left = await f.admin.createMember(
      username: 'e2e-weg${DateTime.now().millisecondsSinceEpoch % 100000}',
      displayName: 'E2E Ehemals',
      password: kitMemberPassword,
    );
    final list = uid('list');
    await seed(f.admin, Collections.shoppingLists, {
      list: ShoppingList(id: list, name: '🧳 E2E Weg', packing: true).toData(),
    });
    final items = <String, ShoppingItem>{};
    for (final (name, who) in [
      ('E2E Zelt', left.id),
      ('E2E Wanderschuhe', left.id),
      ('E2E Pass', f.adminMember.id),
      ('E2E Karte', null),
    ]) {
      final id = uid('item');
      items[name] = ShoppingItem(
        id: id,
        listId: list,
        name: name,
        memberId: who,
      );
    }
    await seed(f.admin, Collections.shoppingItems, {
      for (final i in items.values) i.id: i.toData(),
    });
    await f.admin.deleteMember(left.id);
    final state = await start(tester);
    final engine = state.engine!;
    await openSection(tester, 'Einkauf');
    await tap(tester, find.text('🧳 E2E Weg'));
    await waitFor(tester, find.widgetWithText(ChoiceChip, de.commonEveryone));
    await tap(tester, find.widgetWithText(ChoiceChip, de.commonEveryone));
    await tester.pump(const Duration(milliseconds: 600));
    for (final name in ['E2E Zelt', 'E2E Wanderschuhe', 'E2E Karte']) {
      await scrollTo(tester, itemName(name));
      expect(
        _packingHeadingAbove(tester, name),
        de.shoppingEveryone,
        reason: '$name under "Für alle"',
      );
    }
    expect(packingHeading('E2E Ehemals'), findsNothing);
    expect(engine.shoppingItems(list), hasLength(4), reason: 'nothing gone');
    await scrollTo(tester, itemName('E2E Zelt'));
    await tap(tester, itemName('E2E Zelt'));
    await until(
      tester,
      () => engine
          .shoppingItems(list)
          .any((i) => i.name == 'E2E Zelt' && i.checked),
      'ticked',
    );
    await synced(tester, state);
    await eventually(tester, 'ticked on the server', () async {
      final r = (await pull(
        f.admin,
        Collections.shoppingItems,
      ))[items['E2E Zelt']!.id];
      return r?.data['checked'] == true;
    });
    await finish(tester, state);
    await clean(const [Collections.shoppingItems, Collections.shoppingLists]);
  });

  // =========================================================================
  // Chat
  // =========================================================================

  testWidgets('ALL-232 a file over 8 MiB in the chat; the others open it', (
    tester,
  ) async {
    final f = await theFamily();
    await clean(const [Collections.chatMessages]);
    final picker = fakeFilePicker();
    final bytes = bigPdf();
    picker.picks.add(pickedDisk(await diskFile('E2E-Chat-Gross.pdf', bytes)));
    final state = await start(tester);
    final engine = state.engine!;
    await openSection(tester, 'Chat');
    await tap(tester, find.text(de.settingsFamily));
    await waitFor(tester, find.text(de.chatEveryoneFamily));
    await tap(tester, find.byTooltip(de.chatSendPhotoFile));
    var told = <String>[];
    final end = DateTime.now().add(const Duration(seconds: 90));
    while (engine.chatMessages(ChatIds.family).isEmpty) {
      if (DateTime.now().isAfter(end)) throw TestFailure('not sent');
      told = [...told, ...snackTexts()];
      await tester.pump(const Duration(milliseconds: 200));
    }
    await waitFor(tester, find.text('E2E-Chat-Gross.pdf'));
    expect(told, isEmpty, reason: 'no message: $told');
    await synced(tester, state);
    final bea = await sessionOf(f.bea);
    FileRef? file;
    await eventually(tester, 'Bea gets the message', () async {
      for (final r in (await pull(bea, Collections.chatMessages)).values) {
        final m = ChatMessage.fromRecord(r);
        if (m.attachment?.name == 'E2E-Chat-Gross.pdf') file = m.attachment;
      }
      return file != null;
    });
    final got = await bea.downloadFile(file!.id);
    expect(got.length, bytes.length, reason: 'Bea opens all of it');
    await finish(tester, state);
    await clean(const [Collections.chatMessages]);
  });

  // =========================================================================
  // Wunschzettel & Geschenkideen
  // =========================================================================

  testWidgets('ALL-235 an own wish changed, deleted and back; others\' '
      'wishes open no editor', (tester) async {
    final f = await theFamily();
    await clean(const [Collections.wishes, Collections.wishClaims]);
    final bea = await sessionOf(f.bea);
    await seed(f.admin, Collections.wishes, {
      'e2e-wish-own': Wish(
        id: 'e2e-wish-own',
        ownerId: f.adminMember.id,
        title: 'E2E Eigener Wunsch',
        price: '10 €',
        createdAt: DateTime.now(),
      ).toData(),
    });
    await seed(bea, Collections.wishes, {
      'e2e-wish-bea': Wish(
        id: 'e2e-wish-bea',
        ownerId: f.bea.id,
        title: 'E2E Beas Wunsch',
        createdAt: DateTime.now(),
      ).toData(),
    });
    final state = await start(tester);
    await openSettingsEntry(tester, de.settingsWishes);
    await waitFor(tester, find.text('E2E Eigener Wunsch'));
    await tap(tester, find.text('E2E Eigener Wunsch'));
    await waitFor(tester, find.text(de.wishesEditWish));
    await enter(tester, inDialog(field(de.wishesPriceOptional)), '12 €');
    await leaveField(tester);
    await tap(tester, inDialog(find.text(de.commonSave)));
    await dialogClosed(tester);
    await waitFor(
      tester,
      find.descendant(
        of: cardOf('E2E Eigener Wunsch'),
        matching: find.text('12 €'),
      ),
    );
    await tap(tester, find.text('E2E Eigener Wunsch'));
    await waitFor(tester, find.text(de.wishesEditWish));
    await tap(tester, inDialog(find.text(de.commonDelete)));
    await dialogClosed(tester);
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Eigener Wunsch')));
    expect(find.text('E2E Eigener Wunsch'), findsNothing);
    await undo(tester);
    await waitFor(tester, find.text('E2E Eigener Wunsch'));
    await synced(tester, state);
    await eventually(tester, 'Bea sees it changed and back', () async {
      final r = (await pull(bea, Collections.wishes))['e2e-wish-own'];
      return r != null && r.data['price'] == '12 €';
    });
    // Bea's wish opens no editor.
    await tap(tester, find.widgetWithText(ChoiceChip, f.bea.displayName));
    await waitFor(tester, find.text('E2E Beas Wunsch'));
    await tap(tester, find.text('E2E Beas Wunsch'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(de.wishesEditWish), findsNothing);
    expect(dialog(), findsNothing);
    await finish(tester, state);
    await clean(const [Collections.wishes, Collections.wishClaims]);
    await remove(bea, Collections.wishes, ['e2e-wish-bea']);
  });

  // Hint from the catalog review (wishes_screen.dart:340): a link with
  // "://" is opened as it is, everything else with "https://" put before it.
  testWidgets('ALL-235 hint: what the link of a wish opens', (tester) async {
    final f = await theFamily();
    await clean(const [Collections.wishes, Collections.wishClaims]);
    final launcher = fakeLauncher();
    for (final (id, title, link) in [
      ('e2e-link-web', 'E2E Link Web', 'example.org/lego'),
      ('e2e-link-app', 'E2E Link App', 'famio://open?target=chat:family'),
      ('e2e-link-file', 'E2E Link Datei', 'file:///etc/hosts'),
      ('e2e-link-port', 'E2E Link Doppelpunkt', 'shop.example:Größe 128'),
    ]) {
      await seed(f.admin, Collections.wishes, {
        id: Wish(
          id: id,
          ownerId: f.adminMember.id,
          title: title,
          link: link,
          createdAt: DateTime.now(),
        ).toData(),
      });
    }
    final state = await start(tester);
    await openSettingsEntry(tester, de.settingsWishes);
    Future<void> open(String title) async {
      await scrollTo(tester, find.text(title));
      await tester.tap(
        find.descendant(
          of: cardOf(title),
          matching: find.byTooltip(de.wishesOpenLink),
        ),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 600));
    }

    await open('E2E Link Web');
    await open('E2E Link App');
    await open('E2E Link Datei');
    await open('E2E Link Doppelpunkt');
    final error = tester.takeException();
    debugPrint(
      'E2E-INFO ALL-235 hint: opened ${launcher.opened}, error $error',
    );
    expect(launcher.opened, [
      'https://example.org/lego',
      'famio://open?target=chat:family',
      'file:///etc/hosts',
    ]);
    expect(error, isA<FormatException>(), reason: 'no message, an error');
    await finish(tester, state);
    await clean(const [Collections.wishes, Collections.wishClaims]);
  });

  testWidgets('ALL-236 a gift idea changed, deleted and back, also by B', (
    tester,
  ) async {
    final f = await theFamily();
    await clean(const [Collections.wishes, Collections.wishClaims]);
    final bea = await sessionOf(f.bea);
    final kid = await sessionOf(f.kid);
    await seed(f.admin, Collections.wishes, {
      'e2e-idea': Wish(
        id: 'e2e-idea',
        ownerId: f.kid.id,
        title: 'E2E Idee Roller',
        ideaBy: f.adminMember.id,
        createdAt: DateTime.now(),
      ).toData(),
    });
    Future<Wish?> idea(FamioApiClient api) async {
      final r = (await pull(api, Collections.wishes))['e2e-idea'];
      return r == null ? null : Wish.fromRecord(r);
    }

    Future<void> openIdea(String title) async {
      await openSettingsEntry(tester, de.settingsWishes);
      await tap(tester, find.widgetWithText(ChoiceChip, f.kid.displayName));
      await waitFor(tester, find.text(de.wishesGiftIdeas));
      await tap(tester, find.text(title));
      await waitFor(tester, find.text(de.wishesEditIdea));
    }

    var state = await start(tester);
    await openIdea('E2E Idee Roller');
    await enter(tester, inDialog(field(de.wishesWhat)), 'E2E Idee Laufrad');
    await leaveField(tester);
    await tap(tester, inDialog(find.text(de.commonSave)));
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Idee Laufrad'));
    await tap(tester, find.text('E2E Idee Laufrad'));
    await waitFor(tester, find.text(de.wishesEditIdea));
    await tap(tester, inDialog(find.text(de.commonDelete)));
    await dialogClosed(tester);
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Idee Laufrad')));
    await undo(tester);
    await waitFor(tester, find.text('E2E Idee Laufrad'));
    await synced(tester, state);
    await eventually(
      tester,
      'Bea gets the changed idea',
      () async => (await idea(bea))?.title == 'E2E Idee Laufrad',
    );
    expect(await idea(kid), isNull, reason: 'the child never gets it');
    await finish(tester, state);
    // B opens the idea of A: the editor (wishes_screen.dart:320).
    state = await start(tester, user: f.bea.username);
    await openIdea('E2E Idee Laufrad');
    await enter(tester, inDialog(field(de.wishesPriceOptional)), '40 €');
    await leaveField(tester);
    await tap(tester, inDialog(find.text(de.commonSave)));
    await dialogClosed(tester);
    await synced(tester, state);
    await eventually(
      tester,
      'A gets B\'s change',
      () async => (await idea(f.admin))?.price == '40 €',
    );
    final changed = (await idea(f.admin))!;
    debugPrint(
      'E2E-INFO ALL-236 B changed A\'s idea: ${changed.title}, '
      '${changed.price}, idea by ${changed.ideaBy}',
    );
    expect(changed.ideaBy, f.adminMember.id, reason: 'still A\'s idea');
    expect(await idea(kid), isNull);
    await finish(tester, state);
    await clean(const [Collections.wishes, Collections.wishClaims]);
  });

  // =========================================================================
  // Geänderte Einträge: was die Tests in catalog_all_a/b nicht prüfen
  // =========================================================================

  // ALL-075 (#545): also "Heute" and the tile of the start page show a
  // guest no points.
  testWidgets('ALL-075 "Heute" and the start page show a guest no points', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    await addChore('E2E Gast Punkte', members: [f.kid.id]);
    await addPoints(f.kid, 7);
    final state = await start(tester, user: f.guest.username);
    await openChores(tester);
    await waitFor(tester, personBlock(f.kid.id));
    expect(byTypeName('_PointsChip'), findsNothing, reason: '"Heute"');
    expect(find.textContaining('⭐ 7'), findsNothing);
    await openSection(tester, 'Start');
    await waitFor(
      tester,
      find.textContaining('${f.kid.displayName}: 🧹 E2E Gast Punkte'),
    );
    expect(find.textContaining('⭐'), findsNothing, reason: 'the tile');
    await finish(tester, state);
  });

  // ALL-108 (#545): the tile of the start page lists the substitute's chores,
  // and the wall display shows the same; a tick there counts for the
  // substitute.
  testWidgets('ALL-108 the start page and the wall display with absent '
      'children', (tester) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    await addChore('E2E Wand Kind', members: [f.kid.id]);
    await addChore('E2E Wand Fips', members: [fips.id], points: 2);
    await addAbsence(f.kid, today(), inDays(1));
    await addAbsence(fips, today(), inDays(1), substitute: f.bea);
    tester.view.physicalSize =
        const Size(1300, 1600) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await secondKid();
    final state = await startApp(tester);
    await openSection(tester, 'Start');
    await waitFor(tester, find.text('${f.kid.displayName}: ${de.absenceAway}'));
    await waitFor(tester, find.text('${fips.displayName}: 🧹 E2E Wand Fips'));
    expect(find.textContaining('E2E Wand Kind'), findsNothing);
    await openSettingsEntry(tester, de.settingsOpenKiosk);
    await waitFor(tester, find.byType(KioskScreen));
    await tester.pump(const Duration(seconds: 1));
    await waitFor(tester, find.text(de.absenceAway));
    await waitFor(
      tester,
      find.text(de.absenceRepresentedBy(f.bea.displayName)),
    );
    expect(find.textContaining('E2E Wand Kind'), findsNothing);
    final check = find.byWidgetPredicate(
      (w) => w is RoundCheck && w.label == 'E2E Wand Fips',
    );
    await waitFor(tester, check);
    await tap(tester, check);
    final engine = state.engine!;
    final chore = engine.chores.firstWhere((c) => c.title == 'E2E Wand Fips');
    await until(
      tester,
      () => engine.choreCompletion(chore, today()) != null,
      'ticked on the wall',
    );
    expect(
      engine.choreCompletion(chore, today())!.memberId,
      f.bea.id,
      reason: 'for the substitute',
    );
    await tap(tester, find.byTooltip(de.kioskCloseWallDisplay));
    await waitGone(tester, find.byType(KioskScreen));
    await finish(tester, state);
  });

  // ALL-130 (#537, #539): what the menu of a list offers a guest, and what
  // the server makes of renaming and deleting it.
  testWidgets('ALL-130 a guest\'s menu of a list; renamed and deleted '
      'through the API', (tester) async {
    final f = await theFamily();
    await clean(const [Collections.shoppingItems, Collections.shoppingLists]);
    final list = uid('list');
    await seed(f.admin, Collections.shoppingLists, {
      list: ShoppingList(id: list, name: 'E2E Gastmenü').toData(),
    });
    final item = uid('item');
    await seed(f.admin, Collections.shoppingItems, {
      item: ShoppingItem(id: item, listId: list, name: 'E2E Äpfel').toData(),
    });
    final state = await start(tester, user: f.guest.username);
    await openSection(tester, 'Einkauf');
    expect(find.byTooltip(de.shoppingNewList), findsNothing);
    expect(find.byTooltip(de.shoppingListTemplate), findsNothing);
    await tap(tester, find.text('E2E Gastmenü'));
    await waitFor(tester, find.byTooltip(de.commonAdd));
    await tap(tester, find.byType(PopupMenuButton<String>).last);
    await tester.pump(const Duration(milliseconds: 600));
    final menu = [
      for (final e
          in find
              .descendant(
                of: find.byType(PopupMenuItem<String>),
                matching: find.byType(Text),
              )
              .evaluate())
        ?(e.widget as Text).data,
    ];
    debugPrint('E2E-INFO ALL-130 the guest\'s menu: $menu');
    for (final gone in [
      de.commonRename,
      de.shoppingWhoSees,
      de.shoppingDeleteList,
      de.shoppingSaveTemplate,
    ]) {
      expect(menu, isNot(contains(gone)), reason: gone);
    }
    for (final kept in [
      de.shoppingShareText,
      de.shoppingStaples,
      de.shoppingRemoveCheckedItems,
      de.shoppingPreppSuiteMenu,
    ]) {
      expect(menu, contains(kept), reason: kept);
    }
    await tester.tapAt(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 600));
    // Through the API: neither renamed nor deleted, the items stay.
    final guest = await sessionOf(f.guest);
    final renamed = await put(guest, Collections.shoppingLists, {
      list: ShoppingList(id: list, name: 'E2E Vom Gast').toData(),
    });
    final deleted = await remove(guest, Collections.shoppingLists, [list]);
    debugPrint(
      'E2E-INFO ALL-130 refused: ${renamed.refused.map((i) => i.code)} '
      '${deleted.refused.map((i) => i.code)}',
    );
    final lists = await pull(f.admin, Collections.shoppingLists);
    expect(lists[list]?.data['name'], 'E2E Gastmenü');
    expect(
      (await pull(f.admin, Collections.shoppingItems)).containsKey(item),
      isTrue,
    );
    await finish(tester, state);
    await clean(const [Collections.shoppingItems, Collections.shoppingLists]);
  });

  // ALL-179 (#539): calling and e-mail work for a guest; adding and changing
  // through the API the server does not take.
  testWidgets('ALL-179 a guest: no adding, not even from the empty page or '
      'the search; e-mail; nothing through the API', (tester) async {
    final f = await theFamily();
    await clean(const [Collections.contacts]);
    final launcher = fakeLauncher();
    final state = await start(tester, user: f.guest.username);
    await openSection(tester, 'Kontakte');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip(de.contactsAdd), findsNothing, reason: 'empty page');
    expect(find.text(de.contactsAdd), findsNothing);
    await seed(f.admin, Collections.contacts, {
      'e2e-c-schule': const FamilyContact(
        id: 'e2e-c-schule',
        name: 'E2E Schulsekretariat',
        phone: '030 1234',
        email: 'sekretariat@example.org',
      ).toData(),
    });
    await arrives(
      tester,
      state,
      (e) => e.records(Collections.contacts).isNotEmpty,
      'the contact',
    );
    await waitFor(tester, find.text('E2E Schulsekretariat'));
    expect(find.byTooltip(de.contactsAdd), findsNothing);
    await tap(tester, find.byTooltip(de.contactsCallPhone('030 1234')));
    await tap(tester, find.byTooltip(de.contactsWriteEmail));
    await until(
      tester,
      () => launcher.opened.length >= 2,
      'call and e-mail handed on',
    );
    debugPrint('E2E-INFO ALL-179 opened ${launcher.opened}');
    expect(launcher.opened.first, startsWith('tel:'));
    expect(launcher.opened[1], startsWith('mailto:sekretariat@example.org'));
    // From the search: no editor either.
    await openSection(tester, 'Start');
    await tap(tester, find.byTooltip(de.commonSearch));
    final input = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == de.searchEventTaskRecipeContact,
    );
    await waitFor(tester, input);
    await tester.tap(input, warnIfMissed: false);
    await tester.enterText(input, 'Schulsekretariat');
    await tester.pump(const Duration(milliseconds: 800));
    final hit = find.text('E2E Schulsekretariat');
    await waitFor(tester, hit);
    await tester.tap(hit.last, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    expect(field(de.contactsPhone), findsNothing, reason: 'no editor');
    expect(find.text(de.commonContact), findsNothing);
    final guest = await sessionOf(f.guest);
    final added = await put(guest, Collections.contacts, {
      'e2e-c-gast': const FamilyContact(
        id: 'e2e-c-gast',
        name: 'E2E Vom Gast',
      ).toData(),
    });
    final changed = await put(guest, Collections.contacts, {
      'e2e-c-schule': const FamilyContact(
        id: 'e2e-c-schule',
        name: 'E2E Schulsekretariat',
        phone: '0000',
      ).toData(),
    });
    debugPrint(
      'E2E-INFO ALL-179 refused: ${added.refused.map((i) => i.code)} '
      '${changed.refused.map((i) => i.code)}',
    );
    final server = await pull(f.admin, Collections.contacts);
    expect(server.keys, ['e2e-c-schule']);
    expect(server['e2e-c-schule']!.data['phone'], '030 1234');
    await finish(tester, state);
    await clean(const [Collections.contacts]);
  });

  // ALL-192, ALL-201 (6065651): children, guests and service accounts are
  // not offered as the one in charge of a deadline; a child chosen before
  // stays chosen in the editor of the adults. The child sees it with its
  // picture, without "Erledigt".
  testWidgets('ALL-192 ALL-201 who takes care of a deadline: a child chosen '
      'before stays, no other one', (tester) async {
    final f = await theFamily();
    final fips = await secondKid();
    final users = await f.admin.adminUsers();
    final service =
        users
            .where((u) => u.member.username == 'e2e-dienst')
            .firstOrNull
            ?.member ??
        await f.admin.createMember(
          username: 'e2e-dienst',
          displayName: 'E2E Dienst',
          password: kitMemberPassword,
          role: MemberRole.service,
        );
    await clean(const [Collections.deadlines]);
    await seed(f.admin, Collections.deadlines, {
      'e2e-dl-rauch': Deadline(
        id: 'e2e-dl-rauch',
        title: 'E2E Rauchmelder',
        due: inDays(10),
        area: DeadlineArea.home,
        repeatMonths: 12,
        assigneeId: f.kid.id,
      ).toData(),
    });
    // The child.
    var state = await start(tester, user: f.kid.username);
    await openSettingsEntry(tester, de.settingsDeadlines);
    await waitFor(tester, find.text('E2E Rauchmelder'));
    final card = cardOf('E2E Rauchmelder');
    final avatars = find.descendant(
      of: card,
      matching: find.byType(MemberAvatar),
    );
    expect(avatars, findsOneWidget);
    expect(tester.widget<MemberAvatar>(avatars).member.id, f.kid.id);
    expect(
      find.descendant(of: card, matching: find.text(de.commonDoneCap)),
      findsNothing,
    );
    expect(
      find.descendant(of: card, matching: find.byTooltip(de.commonDoneCap)),
      findsNothing,
    );
    await finish(tester, state);
    // The adults' editor.
    state = await start(tester);
    await openSettingsEntry(tester, de.settingsDeadlines);
    await tap(tester, find.text('E2E Rauchmelder'));
    await waitFor(tester, inSheet(find.text(de.tasksWhoTakesCare)));
    final who = inSheet(
      find.ancestor(
        of: find.text(de.tasksWhoTakesCare),
        matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
      ),
    );
    await tester.ensureVisible(who.first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.descendant(of: who, matching: find.text(f.kid.displayName)),
      findsOneWidget,
      reason: 'the child stays chosen',
    );
    await tap(tester, who);
    await tester.pump(const Duration(milliseconds: 600));
    final offered = openMenuTexts();
    debugPrint('E2E-INFO ALL-201 offered: $offered');
    expect(offered, containsAll([kitAdminName, f.bea.displayName]));
    for (final not in [fips, f.guest, service]) {
      expect(offered, isNot(contains(not.displayName)), reason: not.username);
    }
    await tester.tapAt(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 600));
    await closeSheet(tester);
    await finish(tester, state);
    await clean(const [Collections.deadlines]);
  });

  // =========================================================================
  // Ämter – Urlaub (last: the server starts again)
  // =========================================================================

  // The server books pocket money when it starts and every hour
  // (server/lib/src/family/allowance_job.dart). Fips: payday yesterday,
  // the holiday deleted before the server booked it (case 2). The child:
  // payday the day before yesterday in a holiday (case 1), a week before
  // that booked first, then a holiday entered over it (case 3).
  testWidgets('ALL-227 a holiday deleted afterwards: pocket money', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    final dayBefore = inDays(-2), yesterday = inDays(-1);
    Future<String> holiday(DateTime from, DateTime to) async {
      final id = uid('vacation');
      await seed(f.admin, Collections.vacations, {
        id: Vacation(
          id: id,
          from: from,
          to: to,
          title: 'E2E Urlaub',
          allowance: true,
        ).toData(),
      });
      return id;
    }

    final caseOne = await holiday(dayBefore, dayBefore);
    final caseTwo = await holiday(yesterday, yesterday);
    await remove(f.admin, Collections.vacations, [caseTwo]);
    final kidMoney = Allowance(
      memberId: f.kid.id,
      weeklyCents: 500,
      payday: dayBefore.weekday,
      since: inDays(-20),
    );
    final fipsMoney = Allowance(
      memberId: fips.id,
      weeklyCents: 300,
      payday: yesterday.weekday,
      since: inDays(-5),
    );
    await seed(f.admin, Collections.allowances, {
      f.kid.id: kidMoney.toData(),
      fips.id: fipsMoney.toData(),
    });
    Future<Map<String, SyncRecord>> money() =>
        pull(f.admin, Collections.moneyEntries);

    await restartServer();
    var booked = await money();
    debugPrint('E2E-INFO ALL-227 after the first start: ${booked.keys}');
    expect(
      booked.containsKey(kidMoney.bookingId(dayBefore)),
      isFalse,
      reason: 'in the holiday',
    );
    expect(booked.containsKey(kidMoney.bookingId(inDays(-9))), isTrue);
    // Case 2: deleted before the payday was booked: paid as usual.
    expect(booked.containsKey(fipsMoney.bookingId(yesterday)), isTrue);

    // Case 1: the holiday deleted afterwards. Case 3: a holiday entered
    // over a week already paid.
    await remove(f.admin, Collections.vacations, [caseOne]);
    await holiday(inDays(-9), inDays(-9));
    await restartServer();
    booked = await money();
    debugPrint('E2E-INFO ALL-227 after the second start: ${booked.keys}');
    expect(
      booked.containsKey(kidMoney.bookingId(dayBefore)),
      isFalse,
      reason: 'stays paused, nothing paid back',
    );
    expect(
      booked.containsKey(kidMoney.bookingId(inDays(-9))),
      isTrue,
      reason: 'what was paid stays',
    );
    expect(booked.containsKey(fipsMoney.bookingId(yesterday)), isTrue);
    // What the adults see in the child's account.
    final state = await start(tester);
    await openChores(tester);
    await openAccount(tester, f.kid.displayName);
    await tester.pump(const Duration(seconds: 1));
    final paid = [
      for (final r in booked.values)
        if (r.data['memberId'] == f.kid.id) r.id,
    ];
    expect(
      state.engine!
          .records(Collections.moneyEntries)
          .where((r) => r.data['memberId'] == f.kid.id)
          .map((r) => r.id)
          .toSet(),
      paid.toSet(),
    );
    await finish(tester, state);
    await resetChores();
  });

  // ALL-219: a file that cannot be read while it is uploaded (over 8 MiB,
  // streamed) is told as such, not as "Server nicht erreichbar" (#588).
  testWidgets('ALL-219 hint: an unreadable file is told as such', (
    tester,
  ) async {
    await resetTasks();
    final picker = fakeFilePicker();
    final state = await start(tester);
    await openTasks(tester);
    await newTaskSheet(tester);
    await enter(tester, inSheet(titleField), 'E2E Unlesbar groß');
    await moreOptions(tester);
    picker.picks.add(_UnreadableFile('e2e-gross-weg.pdf', 9 * 1024 * 1024));
    await tap(tester, inSheet(find.byTooltip(de.tasksAddPhoto)));
    await waitFor(
      tester,
      inSheet(find.byType(SnackBar)),
      timeout: const Duration(seconds: 60),
    );
    final said = snackTexts().join(' ');
    debugPrint('E2E-INFO ALL-219 unreadable, streamed: $said');
    expect(said, ClientTexts.fileUnreadable);
    await finish(tester, state);
  });

  // ALL-219: a small file (up to 8 MiB) is read when it is chosen; one
  // that cannot be read is told in a dialog, the editor stays (#588).
  testWidgets('ALL-219 hint: a small file that cannot be read', (tester) async {
    await resetTasks();
    final picker = fakeFilePicker();
    final state = await start(tester);
    await openTasks(tester);
    await newTaskSheet(tester);
    await enter(tester, inSheet(titleField), 'E2E Klein unlesbar');
    await moreOptions(tester);
    picker.picks.add(_UnreadableFile('e2e-klein.pdf', 2048));
    await tap(tester, inSheet(find.byTooltip(de.tasksAddPhoto)));
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(end) &&
        find.byType(SnackBar).evaluate().isEmpty &&
        find.byType(AlertDialog).evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final said = [
      ...snackTexts(),
      for (final e
          in find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Text),
              )
              .evaluate())
        ?(e.widget as Text).data,
    ];
    debugPrint('E2E-INFO ALL-219 small unreadable file: $said');
    expect(said, contains(ClientTexts.fileUnreadable));
    expect(sheet(), findsOneWidget);
    await finish(tester, state);
  });
}

/// The packing heading above [text], when the list has no [ListHeading]s.
String? _packingHeadingAbove(WidgetTester tester, String text) {
  double topOf(Element e) =>
      (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;
  final y = topOf(find.text(text).evaluate().first);
  String? best;
  var bestY = double.negativeInfinity;
  for (final e
      in find
          .byWidgetPredicate((w) => w.runtimeType.toString() == '_AisleHeading')
          .evaluate()) {
    final hy = topOf(e);
    if (hy < y && hy > bestY) {
      best = (e.widget as dynamic).label as String;
      bestY = hy;
    }
  }
  return best;
}
