// Catalog ALL-001 … ALL-110 (tasks, who sees them, confirmations, guests,
// chores and points, routines, rewards, pocket money and savings goals,
// holidays and absences) in the real app against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_all_a_test.dart
//
// One test per catalog entry or small group of entries; the name begins
// with the ids. What a person does goes through the app's own pages; what
// another device, member or account does goes through the API. Each test
// starts from its own data: the tasks of earlier tests ("E2E …") and all
// chores, points, money, holidays and absences are removed first.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/format.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/chores_screens.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio/src/widgets/member_avatar.dart';
import 'package:famio/src/widgets/photo_viewer.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

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

const _pdf =
    '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
    '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n'
    'trailer<</Root 1 0 R>>\n%%EOF\n';

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

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // =========================================================================
  // Aufgaben
  // =========================================================================

  testWidgets('ALL-027 empty task lists show their hints', (tester) async {
    await resetTasks();
    final state = await start(tester);
    await openTasks(tester);
    expect(state.engine!.tasks, isEmpty);
    await waitFor(tester, find.text(de.tasksNothingDoEnjoyDay));
    expect(quickField, findsOneWidget);
    await tab(tester, de.tasksFilterMine);
    await waitFor(tester, find.text(de.tasksNothingAssignedYouRight));
    expect(quickField, findsOneWidget);
    await tab(tester, de.commonDoneCap);
    await waitFor(tester, find.text(de.tasksNothingDoneYet));
    expect(quickField, findsNothing, reason: 'no quick field under "Erledigt"');
    await finish(tester, state);
  });

  testWidgets(
    'ALL-001 ALL-002 quick field: undated for nobody, "Meine" for me',
    (tester) async {
      await resetTasks();
      final state = await start(tester);
      await openTasks(tester);
      // ALL-001: typed and sent with the Enter key.
      await enter(tester, quickField, 'E2E Müll rausbringen');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await until(
        tester,
        () => state.engine!.tasks.any((t) => t.title == 'E2E Müll rausbringen'),
        'task added with Enter',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await waitFor(tester, onCard('E2E Müll rausbringen'));
      expect(headingOf(tester, 'E2E Müll rausbringen'), de.tasksWithoutDate);
      final quick = tester.widget<TextField>(quickField);
      expect(quick.controller!.text, isEmpty, reason: 'the field is empty');
      expect(quick.focusNode!.hasFocus, isTrue, reason: 'and keeps the focus');
      final task = taskOf(state, 'E2E Müll rausbringen');
      expect(task.assigneeIds, isEmpty);
      expect(task.due, isNull);
      expect(
        find.descendant(
          of: cardOf('E2E Müll rausbringen'),
          matching: find.byType(MemberAvatar),
        ),
        findsNothing,
      );
      // The arrow button does the same.
      await quickAdd(tester, 'E2E Zweite schnelle');
      expect(taskOf(state, 'E2E Zweite schnelle').assigneeIds, isEmpty);
      expect(headingOf(tester, 'E2E Zweite schnelle'), de.tasksWithoutDate);

      // ALL-002
      await tab(tester, de.tasksFilterMine);
      await quickAdd(tester, 'E2E Meine schnelle');
      expect(taskOf(state, 'E2E Meine schnelle').assigneeIds, [state.me!.id]);
      final avatar = tester.widget<MemberAvatar>(
        find.descendant(
          of: cardOf('E2E Meine schnelle'),
          matching: find.byType(MemberAvatar),
        ),
      );
      expect(avatar.member.id, state.me!.id);
      expect(find.text('E2E Müll rausbringen'), findsNothing);
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-003 ALL-004 ALL-018 the editor: details, no title, folded options',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final state = await start(tester);
      await openTasks(tester);
      await newTaskSheet(tester);
      expect(inSheet(find.text(de.tasksNewTask2)), findsOneWidget);
      // ALL-018: folded away until asked for.
      final folded = [de.tasksChecklist, de.tasksPhotos, de.commonWhoMaySee];
      for (final t in folded) {
        expect(inSheet(find.text(t)), findsNothing, reason: t);
      }
      await tap(tester, inSheet(find.text(de.tasksMoreOptions)));
      for (final t in folded) {
        expect(inSheet(find.text(t)), findsOneWidget, reason: t);
      }
      // ALL-004: without a title nothing happens.
      final count = state.engine!.tasks.length;
      await leaveField(tester);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await tester.pump(const Duration(seconds: 1));
      expect(sheet(), findsOneWidget, reason: 'stays open');
      expect(state.engine!.tasks.length, count);
      // ALL-003
      await enter(tester, inSheet(titleField), 'E2E Mit Details');
      await enter(
        tester,
        inSheet(field(de.commonNotes)),
        'E2E Erste Zeile\nZweite Zeile',
      );
      await saveSheet(tester);
      await waitFor(tester, find.text('E2E Mit Details'));
      expect(subtitleOf('E2E Mit Details'), 'E2E Erste Zeile');
      expect(
        taskOf(state, 'E2E Mit Details').notes,
        'E2E Erste Zeile\nZweite Zeile',
      );
      // ALL-018: a task with a checklist opens folded out.
      await addTask(
        f.admin,
        'E2E Hat Checkliste',
        checklist: const [TaskStep(id: 's1', text: 'E2E Schritt')],
      );
      await arrives(
        tester,
        state,
        (e) => e.tasks.any((t) => t.title == 'E2E Hat Checkliste'),
        'task with a checklist',
      );
      await openTask(tester, 'E2E Hat Checkliste');
      expect(inSheet(find.text(de.tasksMoreOptions)), findsNothing);
      expect(
        inSheet(find.text(de.tasksChecklistDoneTotal(0, 1))),
        findsOneWidget,
      );
      expect(inSheet(find.text(de.commonWhoMaySee)), findsOneWidget);
      await closeSheet(tester);
      await finish(tester, state);
    },
  );

  testWidgets('ALL-005 ALL-006 due dates group the list, overdue in red', (
    tester,
  ) async {
    await resetTasks();
    final state = await start(tester);
    await openTasks(tester);
    final short = DateFormat.MMMEd('de'), long = DateFormat.MMMMEEEEd('de');
    await quickAdd(tester, 'E2E Heute fällig');
    await openTask(tester, 'E2E Heute fällig');
    await setDue(tester, today());
    expect(inSheet(find.text(long.format(today()))), findsOneWidget);
    await saveSheet(tester);
    await newTask(tester, 'E2E In drei Tagen', due: inDays(3));
    await newTask(tester, 'E2E Gestern fällig', due: inDays(-1));
    await tester.pump(const Duration(seconds: 1));
    expect(headingOf(tester, 'E2E Heute fällig'), de.commonToday);
    expect(headingOf(tester, 'E2E In drei Tagen'), de.tasksComingUp);
    expect(headingOf(tester, 'E2E Gestern fällig'), de.commonOverdue);
    expect(subtitleOf('E2E Heute fällig'), contains(short.format(today())));
    expect(subtitleOf('E2E In drei Tagen'), contains(short.format(inDays(3))));
    // ALL-006: on top, in red, the line under the task too.
    final error = Theme.of(
      tester.element(find.text('E2E Gestern fällig')),
    ).colorScheme.error;
    final heading = tester.widget<ListHeading>(
      find.widgetWithText(ListHeading, de.commonOverdue),
    );
    expect(heading.color, error);
    expect(above(de.commonOverdue, de.commonToday), isTrue);
    Text line(String title) => tester.widget<Text>(
      find.descendant(
        of: cardOf(title),
        matching: find.text(subtitleOf(title)),
      ),
    );
    expect(line('E2E Gestern fällig').style?.color, error);
    expect(line('E2E Heute fällig').style?.color, isNot(error));
    // ALL-005: the x of the chip takes the date away.
    await openTask(tester, 'E2E Heute fällig');
    final chip = inSheet(find.widgetWithText(InputChip, long.format(today())));
    await tap(
      tester,
      find.descendant(of: chip, matching: find.byType(Tooltip)).last,
    );
    await waitFor(tester, inSheet(find.text(de.tasksDue)));
    await saveSheet(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(taskOf(state, 'E2E Heute fällig').due, isNull);
    expect(headingOf(tester, 'E2E Heute fällig'), de.tasksWithoutDate);
    await finish(tester, state);
  });

  testWidgets('ALL-007 tick off and open again', (tester) async {
    await resetTasks();
    final state = await start(tester);
    await openTasks(tester);
    await quickAdd(tester, 'E2E Abhaken eins');
    await quickAdd(tester, 'E2E Abhaken zwei');
    await tap(tester, taskCheck('E2E Abhaken eins'));
    await waitGone(tester, find.text('E2E Abhaken eins'));
    await tester.pump(const Duration(seconds: 1));
    await tap(tester, taskCheck('E2E Abhaken zwei'));
    await waitGone(tester, find.text('E2E Abhaken zwei'));
    expect(taskOf(state, 'E2E Abhaken eins').done, isTrue);
    await tab(tester, de.commonDoneCap);
    await waitFor(tester, find.text('E2E Abhaken eins'));
    await waitFor(tester, find.text('E2E Abhaken zwei'));
    expect(
      above('E2E Abhaken zwei', 'E2E Abhaken eins'),
      isTrue,
      reason: 'newest first',
    );
    for (final t in ['E2E Abhaken eins', 'E2E Abhaken zwei']) {
      expect(
        tester.widget<Text>(find.text(t)).style?.decoration,
        TextDecoration.lineThrough,
        reason: t,
      );
    }
    await tap(tester, taskCheck('E2E Abhaken zwei'));
    await waitGone(tester, find.text('E2E Abhaken zwei'));
    expect(taskOf(state, 'E2E Abhaken zwei').done, isFalse);
    await tab(tester, de.tasksFilterOpen);
    await waitFor(tester, find.text('E2E Abhaken zwei'));
    expect(find.text('E2E Abhaken eins'), findsNothing);
    await finish(tester, state);
  });

  testWidgets(
    'ALL-008 ALL-011 repeating: the choices, without a date from today',
    (tester) async {
      await resetTasks();
      final state = await start(tester);
      await openTasks(tester);
      final items = find.byWidgetPredicate((w) => w is PopupMenuItem);
      Future<List<String>> openRepeat(String chip) async {
        await tap(tester, inSheet(find.text(chip)));
        await waitFor(tester, items);
        await tester.pump(const Duration(milliseconds: 400));
        return [
          for (final e
              in find
                  .descendant(of: items, matching: find.byType(Text))
                  .evaluate())
            (e.widget as Text).data ?? '',
        ];
      }

      Future<void> pick(String label) async {
        await tap(
          tester,
          find.descendant(of: items, matching: find.text(label)),
        );
        await waitGone(tester, items);
        await tester.pump(const Duration(milliseconds: 300));
      }

      await newTaskSheet(tester);
      await enter(tester, inSheet(titleField), 'E2E Täglich ohne Datum');
      expect(await openRepeat(de.tasksRepeat), [
        de.tasksDoNotRepeat,
        'Täglich',
        'Wöchentlich',
        'Alle 2 Wochen',
        'Monatlich',
        'Alle 3 Monate',
        'Jährlich',
      ]);
      await pick('Alle 2 Wochen');
      await waitFor(tester, inSheet(find.text('Alle 2 Wochen')));
      await openRepeat('Alle 2 Wochen');
      await pick('Täglich');
      await waitFor(tester, inSheet(find.text('Täglich')));
      // ALL-011: no date: today.
      await saveSheet(tester);
      await waitFor(tester, find.text('E2E Täglich ohne Datum'));
      final daily = taskOf(state, 'E2E Täglich ohne Datum');
      expect(daily.repeat, TaskRepeat.daily);
      expect(DateUtils.dateOnly(daily.due!), today());
      expect(headingOf(tester, 'E2E Täglich ohne Datum'), de.commonToday);
      expect(
        subtitleOf('E2E Täglich ohne Datum'),
        '${DateFormat.MMMEd('de').format(today())} · ↻ täglich',
      );
      // ALL-008: the rhythm in the list.
      await newTaskSheet(tester);
      await enter(tester, inSheet(titleField), 'E2E Alle zwei Wochen');
      await openRepeat(de.tasksRepeat);
      await pick('Alle 2 Wochen');
      await saveSheet(tester);
      await waitFor(tester, find.text('E2E Alle zwei Wochen'));
      expect(subtitleOf('E2E Alle zwei Wochen'), contains('↻ alle 2 Wochen'));
      final two = taskOf(state, 'E2E Alle zwei Wochen');
      expect((two.repeat, two.repeatEvery), (TaskRepeat.weekly, 2));
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-009 ALL-010 ALL-014 a weekly task moves on, undo, steps start over',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final remind = DateTime(today().year, today().month, today().day, 21);
      await addTask(
        f.admin,
        'E2E Wöchentlich',
        due: today(),
        repeat: TaskRepeat.weekly,
        remindAt: remind,
        checklist: const [
          TaskStep(id: 'a', text: 'E2E Eins', done: true),
          TaskStep(id: 'b', text: 'E2E Zwei', done: true),
        ],
      );
      final state = await start(tester);
      await openTasks(tester);
      await waitFor(tester, find.text('E2E Wöchentlich'));
      expect(subtitleOf('E2E Wöchentlich'), contains('☑ 2/2'));
      await tap(tester, taskCheck('E2E Wöchentlich'));
      final next = inDays(7);
      await waitFor(
        tester,
        snackText(
          de.tasksTitleDoneDueAgain(
            'E2E Wöchentlich',
            DateFormat.MMMMEEEEd('de').format(next),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(de.commonUndo),
        ),
        findsOneWidget,
      );
      final moved = taskOf(state, 'E2E Wöchentlich');
      expect(moved.done, isFalse, reason: 'stays open');
      expect(DateUtils.dateOnly(moved.due!), next);
      expect(
        moved.remindAt!.isAtSameMomentAs(remind.add(next.difference(today()))),
        isTrue,
        reason: 'the reminder moves by the same: ${moved.remindAt}',
      );
      // ALL-014
      expect(moved.checklist.every((s) => !s.done), isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      expect(headingOf(tester, 'E2E Wöchentlich'), de.tasksComingUp);
      expect(subtitleOf('E2E Wöchentlich'), contains('☑ 0/2'));
      // ALL-010
      await undo(tester);
      await until(
        tester,
        () =>
            DateUtils.dateOnly(taskOf(state, 'E2E Wöchentlich').due!) ==
            today(),
        'the old date back',
      );
      final back = taskOf(state, 'E2E Wöchentlich');
      expect(back.remindAt!.isAtSameMomentAs(remind), isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      expect(headingOf(tester, 'E2E Wöchentlich'), de.commonToday);
      await finish(tester, state);
    },
  );

  testWidgets('ALL-015 a reminder: from today on, 18:00 suggested', (
    tester,
  ) async {
    await resetTasks();
    final state = await start(tester);
    await openTasks(tester);
    await quickAdd(tester, 'E2E Erinnerung');
    await openTask(tester, 'E2E Erinnerung');
    await tap(tester, inSheet(find.text(de.tasksRemind)));
    expect(
      await typeDate(tester, inDays(-1)),
      isFalse,
      reason: 'days before today are locked',
    );
    expect(await typeDate(tester, inDays(1)), isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    await waitFor(tester, inDialog(find.text('OK')));
    expect(inDialog(find.text('18')), findsWidgets, reason: 'suggested hour');
    expect(inDialog(find.text('00')), findsWidgets);
    await tester.tap(find.text('OK').last, warnIfMissed: false);
    await dialogClosed(tester);
    final tomorrow = inDays(1);
    final at = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 18);
    await waitFor(
      tester,
      inSheet(find.text(de.tasksReminderTime(dateTimeLabel(at)))),
    );
    await saveSheet(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(subtitleOf('E2E Erinnerung'), contains('⏰ ${dateTimeLabel(at)}'));
    expect(
      taskOf(state, 'E2E Erinnerung').remindAt!.isAtSameMomentAs(at),
      isTrue,
    );
    await finish(tester, state);
  });

  testWidgets('ALL-017 several people take care, "Alle" for nobody', (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    final state = await start(tester);
    await openTasks(tester);
    await quickAdd(tester, 'E2E Viele Hände');
    Finder avatars() => find.descendant(
      of: cardOf('E2E Viele Hände'),
      matching: find.byType(MemberAvatar),
    );
    await openTask(tester, 'E2E Viele Hände');
    await chooseAssignee(tester, f.bea.displayName);
    await chooseAssignee(tester, f.carl.displayName);
    await saveSheet(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(avatars(), findsNWidgets(2));
    expect(taskOf(state, 'E2E Viele Hände').assigneeIds.toSet(), {
      f.bea.id,
      f.carl.id,
    });
    // Four people: three avatars and "+1".
    await openTask(tester, 'E2E Viele Hände');
    await chooseAssignee(tester, kitAdminName);
    await chooseAssignee(tester, f.kid.displayName);
    await saveSheet(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(avatars(), findsNWidgets(3));
    expect(
      find.descendant(of: cardOf('E2E Viele Hände'), matching: find.text('+1')),
      findsOneWidget,
    );
    // "Alle": nobody in particular.
    await openTask(tester, 'E2E Viele Hände');
    await tap(
      tester,
      inSheet(find.widgetWithText(ChoiceChip, de.commonEveryone)),
    );
    await saveSheet(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(avatars(), findsNothing);
    expect(taskOf(state, 'E2E Viele Hände').assigneeIds, isEmpty);
    await finish(tester, state);
  });

  testWidgets('ALL-019 a checklist: add, tick, typed counts, remove', (
    tester,
  ) async {
    await resetTasks();
    final state = await start(tester);
    await openTasks(tester);
    await quickAdd(tester, 'E2E Packliste');
    await openTask(tester, 'E2E Packliste');
    await moreOptions(tester);
    final step = inSheet(field(de.tasksAddItemEG));
    final boxes = inSheet(find.byType(Checkbox));
    await enter(tester, step, 'E2E Sonnencreme');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await until(tester, () => boxes.evaluate().length == 1, 'added with Enter');
    await enter(tester, step, 'E2E Handtuch');
    await tap(tester, inSheet(find.byTooltip(de.commonAdd)));
    await until(tester, () => boxes.evaluate().length == 2, 'added with +');
    Finder rowOf(String text) => find
        .ancestor(of: inSheet(find.text(text)), matching: find.byType(Row))
        .first;
    await tap(
      tester,
      find.descendant(
        of: rowOf('E2E Sonnencreme'),
        matching: find.byType(Checkbox),
      ),
    );
    await waitFor(tester, inSheet(find.text(de.tasksChecklistDoneTotal(1, 2))));
    // Typed but not added: kept as well.
    await enter(tester, step, 'E2E Badehose');
    await saveSheet(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(subtitleOf('E2E Packliste'), contains('☑ 1/3'));
    expect(taskOf(state, 'E2E Packliste').checklist.map((s) => s.text), [
      'E2E Sonnencreme',
      'E2E Handtuch',
      'E2E Badehose',
    ]);
    await openTask(tester, 'E2E Packliste');
    await waitFor(tester, inSheet(find.text(de.tasksChecklistDoneTotal(1, 3))));
    await tap(
      tester,
      find.descendant(
        of: rowOf('E2E Handtuch'),
        matching: find.byTooltip(de.tasksRemoveItem),
      ),
    );
    await waitGone(tester, inSheet(find.text('E2E Handtuch')));
    await saveSheet(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(subtitleOf('E2E Packliste'), contains('☑ 1/2'));
    await finish(tester, state);
  });

  testWidgets(
    'ALL-020 ALL-022 a picture and a PDF attached, the picture removed',
    (tester) async {
      await resetTasks();
      final picker = fakePicker();
      final big = await diskFile('e2e-gross.png', await pngBytes(big: true));
      final pdf = await diskFile('e2e-plan.pdf', _pdf.codeUnits);
      final state = await start(tester);
      await openTasks(tester);
      await quickAdd(tester, 'E2E Mit Anhang');
      await openTask(tester, 'E2E Mit Anhang');
      await moreOptions(tester);
      Finder thumb(String name) => inSheet(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == '${de.tasksOpenPhoto}: $name',
        ),
      );
      final attach = inSheet(find.byTooltip(de.tasksAddPhoto));
      final save = inSheet(colorButton(de.commonSave));
      // Uploading: a spinner, "Speichern" locked.
      picker.picks.add(big);
      await waitFor(tester, attach);
      await tester.ensureVisible(attach.first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(attach.first, warnIfMissed: false);
      var spinner = false, locked = false;
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (thumb('e2e-gross.png').evaluate().isEmpty &&
          DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 10));
        if (inSheet(
          find.byType(CircularProgressIndicator),
        ).evaluate().isNotEmpty) {
          spinner = true;
        }
        if (save.evaluate().isNotEmpty && !enabledButton(tester, save)) {
          locked = true;
        }
      }
      expect(thumb('e2e-gross.png'), findsOneWidget, reason: 'uploaded');
      expect(spinner, isTrue, reason: 'a spinner while uploading');
      expect(locked, isTrue, reason: '"Speichern" locked meanwhile');
      await tester.pump(const Duration(milliseconds: 500));
      expect(enabledButton(tester, save), isTrue);
      picker.picks.add(pdf);
      await tap(tester, attach);
      await waitFor(
        tester,
        thumb('e2e-plan.pdf'),
        timeout: const Duration(seconds: 30),
      );
      await saveSheet(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(
          of: cardOf('E2E Mit Anhang'),
          matching: find.byType(CachedImage),
        ),
        findsOneWidget,
        reason: 'the picture as a small preview',
      );
      expect(subtitleOf('E2E Mit Anhang'), contains('📎 1'));
      expect(taskOf(state, 'E2E Mit Anhang').photos.map((p) => p.name), [
        'e2e-gross.png',
        'e2e-plan.pdf',
      ]);
      // A tap on the preview in the editor opens it.
      await openTask(tester, 'E2E Mit Anhang');
      await tap(tester, thumb('e2e-gross.png'));
      await waitFor(tester, find.byType(PhotoViewer));
      await tap(tester, find.byTooltip(de.commonClose).last);
      await waitGone(tester, find.byType(PhotoViewer));
      // ALL-022: the x of the picture.
      final picture = find.ancestor(
        of: thumb('e2e-gross.png'),
        matching: find.byType(FileThumb),
      );
      await tap(
        tester,
        find.descendant(
          of: picture,
          matching: find.byTooltip(de.tasksRemovePhoto),
        ),
      );
      await waitGone(tester, thumb('e2e-gross.png'));
      await saveSheet(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(
          of: cardOf('E2E Mit Anhang'),
          matching: find.byType(CachedImage),
        ),
        findsNothing,
      );
      expect(taskOf(state, 'E2E Mit Anhang').photos.map((p) => p.name), [
        'e2e-plan.pdf',
      ]);
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-023 ALL-024 deleting by swiping or in the editor, with undo',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final state = await start(tester);
      await openTasks(tester);
      await newTask(
        tester,
        'E2E Wischen',
        notes: 'E2E Notiz bleibt',
        assignees: [f.bea.displayName],
        audience: de.docsOnlyMe,
      );
      final before = taskOf(state, 'E2E Wischen');
      expect(before.visibleTo?.toSet(), {state.me!.id, f.bea.id});
      Future<void> swipe() async {
        await snackGone(tester);
        await tester.drag(
          find.byKey(ValueKey(before.id)),
          const Offset(-600, 0),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await swipe();
      await waitFor(tester, snackText(de.undoWhatDeleted('E2E Wischen')));
      expect(state.engine!.tasks.any((t) => t.id == before.id), isFalse);
      await undo(tester);
      await waitFor(tester, find.text('E2E Wischen'));
      final back = taskOf(state, 'E2E Wischen');
      expect(back.id, before.id);
      expect(back.notes, before.notes);
      expect(back.assigneeIds, before.assigneeIds);
      expect(back.visibleTo?.toSet(), before.visibleTo?.toSet());
      expect(
        find.descendant(
          of: cardOf('E2E Wischen'),
          matching: find.byIcon(AppIcons.lockKey),
        ),
        findsOneWidget,
      );
      await synced(tester, state);
      final bea = await sessionOf(f.bea);
      final carl = await sessionOf(f.carl);
      await eventually(
        tester,
        'back on the server for Bea',
        () async => await taskNamed(bea, 'E2E Wischen') != null,
      );
      expect(await taskNamed(carl, 'E2E Wischen'), isNull);
      // Without a tap the message goes after a few seconds.
      await swipe();
      await waitFor(tester, find.byType(SnackBar));
      final shown = DateTime.now();
      await waitGone(
        tester,
        find.byType(SnackBar),
        timeout: const Duration(seconds: 15),
      );
      debugPrint('E2E-INFO snack bar for ${DateTime.now().difference(shown)}');
      expect(state.engine!.tasks.any((t) => t.id == before.id), isFalse);
      // ALL-024
      await quickAdd(tester, 'E2E Im Editor löschen');
      await openTask(tester, 'E2E Im Editor löschen');
      await tap(tester, inSheet(find.text(de.commonDelete)));
      await waitGone(tester, sheet());
      await waitFor(
        tester,
        snackText(de.undoWhatDeleted('E2E Im Editor löschen')),
      );
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(de.commonUndo),
        ),
        findsOneWidget,
      );
      expect(find.text('E2E Im Editor löschen'), findsNothing);
      expect(
        state.engine!.tasks.any((t) => t.title == 'E2E Im Editor löschen'),
        isFalse,
      );
      await finish(tester, state);
    },
  );

  testWidgets('ALL-028 offline: added and ticked off, synced later', (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    await secondKid();
    final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
    await gate.start();
    addTearDown(gate.close);
    final state = await startVia(tester, gate.url, f.bea.username);
    await openTasks(tester);
    gate.cut();
    await tester.pump(const Duration(seconds: 1));
    await quickAdd(tester, 'E2E Offline angelegt');
    await quickAdd(tester, 'E2E Offline erledigt');
    await tap(tester, taskCheck('E2E Offline erledigt'));
    await waitGone(tester, find.text('E2E Offline erledigt'));
    await tab(tester, de.commonDoneCap);
    await waitFor(tester, find.text('E2E Offline erledigt'));
    await tester.pump(const Duration(seconds: 2));
    expect(
      await taskNamed(f.admin, 'E2E Offline angelegt'),
      isNull,
      reason: 'not on the server while offline',
    );
    gate.restore();
    final carl = await sessionOf(f.carl);
    await eventually(tester, 'both on the server, one done', () async {
      unawaited(state.engine!.sync().catchError((Object _) {}));
      final a = await taskNamed(carl, 'E2E Offline angelegt');
      final b = await taskNamed(carl, 'E2E Offline erledigt');
      return a != null &&
          b != null &&
          b.data['done'] == true &&
          a.data['done'] == false;
    }, timeout: const Duration(seconds: 90));
    await finish(tester, state);
  });

  // =========================================================================
  // Aufgaben – Sichtbarkeit
  // =========================================================================

  testWidgets('ALL-030 ALL-031 "Nur ich" and "Ich und …" with who takes care', (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    final state = await start(tester);
    await openTasks(tester);
    await newTask(tester, 'E2E Nur für mich', audience: de.docsOnlyMe);
    final lock = find.descendant(
      of: cardOf('E2E Nur für mich'),
      matching: find.byIcon(AppIcons.lockKey),
    );
    expect(lock, findsOneWidget);
    final tip = tester.widget<Tooltip>(
      find.ancestor(of: lock, matching: find.byType(Tooltip)).first,
    );
    expect(tip.message, de.caldavVisibleWho(kitAdminName));
    // ALL-031
    await newTaskSheet(tester);
    await enter(tester, inSheet(titleField), 'E2E Ich und Bea');
    await chooseAssignee(tester, f.bea.displayName);
    await moreOptions(tester);
    await tap(tester, inSheet(find.text(de.docsMe)));
    final seer = tester.widget<FilterChip>(
      inSheet(find.widgetWithText(FilterChip, f.bea.displayName)).last,
    );
    expect(seer.selected, isTrue, reason: 'who takes care sees it');
    expect(seer.onSelected, isNull, reason: 'and cannot be taken out');
    expect(inSheet(find.text(de.tasksAudienceHint)), findsOneWidget);
    await saveSheet(tester);
    await waitFor(tester, find.text('E2E Ich und Bea'));
    await synced(tester, state);
    final bea = await sessionOf(f.bea);
    final carl = await sessionOf(f.carl);
    await eventually(
      tester,
      'Bea gets the task she takes care of',
      () async => await taskNamed(bea, 'E2E Ich und Bea') != null,
    );
    expect(await taskNamed(carl, 'E2E Ich und Bea'), isNull);
    expect(await taskNamed(bea, 'E2E Nur für mich'), isNull);
    expect(await taskNamed(f.admin, 'E2E Nur für mich'), isNotNull);
    await finish(tester, state);
  });

  testWidgets(
    'ALL-032 ALL-033 guests only get what is theirs; restricted it goes',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final guest = await sessionOf(f.guest);
      final bea = await sessionOf(f.bea);
      final state = await start(tester);
      await openTasks(tester);
      await newTask(tester, 'E2E Familienaufgabe');
      await newTask(tester, 'E2E Einschränken');
      await synced(tester, state);
      await eventually(
        tester,
        'both on the server',
        () async =>
            await taskNamed(bea, 'E2E Familienaufgabe') != null &&
            await taskNamed(bea, 'E2E Einschränken') != null,
      );
      expect(taskOf(state, 'E2E Familienaufgabe').visibleTo, isNull);
      expect(
        await taskNamed(guest, 'E2E Familienaufgabe'),
        isNull,
        reason: 'not for the guest without being assigned',
      );
      await openTask(tester, 'E2E Familienaufgabe');
      await moreOptions(tester);
      expect(inSheet(find.text(de.tasksWholeFamily)), findsOneWidget);
      await chooseAssignee(tester, f.guest.displayName);
      await saveSheet(tester);
      await synced(tester, state);
      await eventually(
        tester,
        'the guest gets it once assigned',
        () async => await taskNamed(guest, 'E2E Familienaufgabe') != null,
      );
      // ALL-033: Bea's device has it; restricted it goes, shared it comes back.
      final id = taskOf(state, 'E2E Einschränken').id;
      bool has(List<SyncRecord> changes, {required bool deleted}) =>
          changes.any(
            (c) =>
                c.collection == Collections.tasks &&
                c.id == id &&
                c.deleted == deleted,
          );
      var mark = await revOf(bea);
      await openTask(tester, 'E2E Einschränken');
      await moreOptions(tester);
      await tap(tester, inSheet(find.text(de.docsOnlyMe)));
      await saveSheet(tester);
      await synced(tester, state);
      await eventually(
        tester,
        "Bea's device takes it away",
        () async => has(await changesAfter(bea, mark), deleted: true),
      );
      expect(await taskNamed(bea, 'E2E Einschränken'), isNull);
      mark = await revOf(bea);
      await openTask(tester, 'E2E Einschränken');
      await tap(tester, inSheet(find.text(de.tasksWholeFamily)));
      await saveSheet(tester);
      await synced(tester, state);
      await eventually(
        tester,
        "back on Bea's device",
        () async => has(await changesAfter(bea, mark), deleted: false),
      );
      expect(await taskNamed(bea, 'E2E Einschränken'), isNotNull);
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-034 ALL-035 a child: the family task keeps its audience, an own one may be private',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final id = await addTask(
        f.admin,
        'E2E Familienputz',
        notes: 'E2E Alle helfen',
      );
      final state = await start(tester, user: f.kid.username);
      await openTasks(tester);
      await openTask(tester, 'E2E Familienputz');
      await moreOptions(tester);
      await waitFor(tester, inSheet(find.text(de.commonAudienceSetByAdults)));
      expect(
        inSheet(find.byWidgetPredicate((w) => w is RadioListTile)),
        findsNothing,
      );
      await closeSheet(tester);
      // A changed audience from the child's device is not kept.
      final kid = await sessionOf(f.kid);
      final record = (await pull(kid, Collections.tasks))[id]!;
      await put(kid, Collections.tasks, {
        id: {
          ...record.data,
          SyncRecord.visibilityKey: [f.kid.id],
        },
      });
      final stored = (await pull(f.admin, Collections.tasks))[id];
      expect(stored, isNotNull, reason: 'the parents still have it');
      expect(stored!.visibleTo, isNull);
      final bea = await sessionOf(f.bea);
      expect((await pull(bea, Collections.tasks))[id], isNotNull);
      // ALL-035
      await newTaskSheet(tester);
      await enter(tester, inSheet(titleField), 'E2E Kind privat');
      await moreOptions(tester);
      await tap(tester, inSheet(find.text(de.docsOnlyMe)));
      await saveSheet(tester);
      await waitFor(tester, find.text('E2E Kind privat'));
      expect(
        find.descendant(
          of: cardOf('E2E Kind privat'),
          matching: find.byIcon(AppIcons.lockKey),
        ),
        findsOneWidget,
      );
      await synced(tester, state);
      await eventually(
        tester,
        "the child's task on the server",
        () async => await taskNamed(kid, 'E2E Kind privat') != null,
      );
      expect(await taskNamed(f.admin, 'E2E Kind privat'), isNull);
      expect(await taskNamed(bea, 'E2E Kind privat'), isNull);
      await finish(tester, state);
    },
  );

  // =========================================================================
  // Aufgaben – Zusagen
  // =========================================================================

  testWidgets(
    'ALL-038 ALL-039 ALL-044 asking for a confirmation, answering, the reminder',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final state = await start(tester);
      await openTasks(tester);
      await newTaskSheet(tester);
      await enter(tester, inSheet(titleField), 'E2E Zusage');
      final require = inSheet(
        find.widgetWithText(SwitchListTile, de.assignmentRequire),
      );
      expect(require, findsNothing, reason: 'only with somebody taking care');
      await chooseAssignee(tester, kitAdminName);
      await chooseAssignee(tester, f.bea.displayName);
      await waitFor(tester, require);
      await tap(tester, require);
      // ALL-044: without a date or repetition no reminder.
      final remind = inSheet(
        find.widgetWithText(SwitchListTile, de.assignmentRemind),
      );
      await waitFor(tester, remind);
      expect(tester.widget<SwitchListTile>(remind).onChanged, isNull);
      expect(inSheet(find.text(de.assignmentReminderNeedsDue)), findsOneWidget);
      await setDue(tester, inDays(1));
      expect(tester.widget<SwitchListTile>(remind).onChanged, isNotNull);
      await tap(tester, remind);
      await waitFor(tester, inSheet(find.text(de.assignmentReminderLead)));
      expect(inSheet(find.text(de.event1DayBefore)), findsOneWidget);
      final menu = await openMenu(tester, de.assignmentReminderLead);
      expect(menu.toSet(), {
        de.event1HourBefore,
        de.event1DayBefore,
        de.deadlinesDaysDaysBefore(7),
      });
      await tap(tester, find.text(de.event1DayBefore).last);
      await tester.pump(const Duration(milliseconds: 600));
      await saveSheet(tester);
      // ALL-038
      final mine = find.text(assignment(kitAdminName, de.assignmentWaiting));
      final beas = find.text(
        assignment(f.bea.displayName, de.assignmentWaiting),
      );
      await waitFor(tester, mine);
      await waitFor(tester, beas);
      final settings = AssignmentSettings.fromData(
        state.engine!
            .record(Collections.tasks, taskOf(state, 'E2E Zusage').id)!
            .data,
      );
      expect(settings.required, isTrue);
      expect(settings.remindMinutes, 1440);
      // ALL-039: others' chips are plain, mine opens the choice.
      expect(
        find.ancestor(of: beas, matching: find.byType(ActionChip)),
        findsNothing,
      );
      expect(
        find.ancestor(of: beas, matching: find.byType(Chip)),
        findsOneWidget,
      );
      await tap(tester, beas);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(de.assignmentYourResponse), findsNothing);
      if (sheet().evaluate().isNotEmpty) await closeSheet(tester);
      await tap(tester, mine);
      await waitFor(tester, find.text(de.assignmentYourResponse));
      expect(find.text(de.assignmentWithdraw), findsNothing);
      await tap(tester, find.text(de.assignmentAccepted).last);
      await dialogClosed(tester);
      final accepted = find.text(
        assignment(kitAdminName, de.assignmentAccepted),
      );
      await waitFor(tester, accepted);
      Finder icon(Finder label, IconData data) => find.descendant(
        of: find.ancestor(of: label, matching: find.byType(ActionChip)),
        matching: find.byIcon(data),
      );
      expect(icon(accepted, AppIcons.check), findsOneWidget);
      final id = taskOf(state, 'E2E Zusage').id;
      await synced(tester, state);
      await eventually(
        tester,
        'the answer on the server',
        () async =>
            await decisionOf(f.admin, f.adminMember, Collections.tasks, id) ==
            AssignmentDecision.accepted.name,
      );
      await tap(tester, accepted);
      await waitFor(tester, find.text(de.assignmentWithdraw));
      await tap(tester, find.text(de.assignmentWithdraw).last);
      await dialogClosed(tester);
      await waitFor(tester, mine);
      expect(icon(mine, AppIcons.clock), findsOneWidget);
      await synced(tester, state);
      await eventually(
        tester,
        'withdrawn on the server',
        () async =>
            await decisionOf(f.admin, f.adminMember, Collections.tasks, id) ==
            null,
      );
      await finish(tester, state);
    },
  );

  testWidgets('ALL-040 ALL-042 declining, and answering offline', (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    await secondKid();
    final no = await addTask(
      f.admin,
      'E2E Absage',
      due: inDays(2),
      assignees: [f.bea.id],
      confirm: true,
    );
    final later = await addTask(
      f.admin,
      'E2E Offline-Zusage',
      due: inDays(2),
      assignees: [f.bea.id],
      confirm: true,
    );
    final gate = Gate(Uri.parse(kitUrl).replace(host: '127.0.0.1'));
    await gate.start();
    addTearDown(gate.close);
    final state = await startVia(tester, gate.url, f.bea.username);
    await openTasks(tester);
    await waitFor(tester, find.text('E2E Absage'));
    await waitFor(tester, find.text('E2E Offline-Zusage'));
    Finder chip(String title, String status) => find.descendant(
      of: cardOf(title),
      matching: find.text(assignment(f.bea.displayName, status)),
    );
    Future<void> answer(String title, String status, String option) async {
      await snackGone(tester);
      await tap(tester, chip(title, status));
      await waitFor(tester, find.text(de.assignmentYourResponse));
      await tap(tester, find.text(option).last);
      await dialogClosed(tester);
    }

    final mark = (await f.admin.notices()).last;
    // ALL-040
    await answer('E2E Absage', de.assignmentWaiting, de.assignmentDeclined);
    final declined = chip('E2E Absage', de.assignmentDeclined);
    await waitFor(tester, declined);
    expect(
      find.descendant(
        of: find.ancestor(of: declined, matching: find.byType(ActionChip)),
        matching: find.byIcon(AppIcons.x),
      ),
      findsOneWidget,
    );
    await synced(tester, state);
    await eventually(
      tester,
      'declined on the server',
      () async =>
          await decisionOf(f.admin, f.bea, Collections.tasks, no) ==
          AssignmentDecision.declined.name,
    );
    await eventually(
      tester,
      'the one who edited it last hears of it',
      () async {
        final notices = (await f.admin.notices(after: mark)).notices;
        return notices.any((n) => n.brief == 'Neue Rückmeldung');
      },
    );
    // ALL-042
    gate.cut();
    await tester.pump(const Duration(seconds: 1));
    await answer(
      'E2E Offline-Zusage',
      de.assignmentWaiting,
      de.assignmentAccepted,
    );
    await waitFor(
      tester,
      chip(
        'E2E Offline-Zusage',
        '${de.assignmentAccepted} · ${de.assignmentPendingSync}',
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(await decisionOf(f.admin, f.bea, Collections.tasks, later), isNull);
    gate.restore();
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (chip(
          'E2E Offline-Zusage',
          de.assignmentAccepted,
        ).evaluate().isEmpty &&
        DateTime.now().isBefore(end)) {
      unawaited(state.engine!.sync().catchError((Object _) {}));
      await tester.pump(const Duration(seconds: 1));
    }
    expect(chip('E2E Offline-Zusage', de.assignmentAccepted), findsOneWidget);
    expect(
      await decisionOf(f.admin, f.bea, Collections.tasks, later),
      AssignmentDecision.accepted.name,
    );
    await finish(tester, state);
  });

  testWidgets(
    'ALL-046 a guest confirms; restricted away, the answer goes as well',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final id = await addTask(
        f.admin,
        'E2E Gast-Zusage',
        due: inDays(2),
        assignees: [f.guest.id],
        confirm: true,
      );
      final state = await start(tester, user: f.guest.username);
      await openTasks(tester);
      final waiting = find.text(
        assignment(f.guest.displayName, de.assignmentWaiting),
      );
      await waitFor(tester, waiting);
      await tap(tester, waiting);
      await waitFor(tester, find.text(de.assignmentYourResponse));
      await tap(tester, find.text(de.assignmentAccepted).last);
      await dialogClosed(tester);
      await waitFor(
        tester,
        find.text(assignment(f.guest.displayName, de.assignmentAccepted)),
      );
      await synced(tester, state);
      await eventually(
        tester,
        "the guest's answer on the server",
        () async =>
            await decisionOf(f.admin, f.guest, Collections.tasks, id) ==
            AssignmentDecision.accepted.name,
      );
      bool answer(SyncEngine e) => e
          .records(Collections.assignmentResponses)
          .any((r) => r.data['targetId'] == id);
      expect(answer(state.engine!), isTrue);
      // "Nur ich" of an adult: whoever takes care still sees it
      // (tasksAudienceHint), the guest too.
      final record = (await pull(f.admin, Collections.tasks))[id]!;
      await seed(f.admin, Collections.tasks, {
        id: {
          ...record.data,
          SyncRecord.visibilityKey: [f.adminMember.id],
        },
      });
      await synced(tester, state);
      await tester.pump(const Duration(seconds: 2));
      await synced(tester, state);
      final kept = state.engine!.tasks.any((t) => t.id == id);
      debugPrint('E2E-INFO guest keeps the task after "Nur ich": $kept');
      expect(kept, isTrue, reason: 'still assigned to the guest');
      // No longer the guest's: task and answer go from the guest's device.
      final again = (await pull(f.admin, Collections.tasks))[id]!;
      await seed(f.admin, Collections.tasks, {
        id: {
          ...again.data,
          ...Task.fromRecord(again)
              .copyWith(
                assigneeIds: [f.adminMember.id],
                visibleTo: [f.adminMember.id],
              )
              .toData(),
        },
      });
      await arrives(
        tester,
        state,
        (e) => !e.tasks.any((t) => t.id == id) && !answer(e),
        "task and answer gone from the guest's device",
      );
      await waitGone(tester, find.text('E2E Gast-Zusage'));
      await finish(tester, state);
    },
  );

  // =========================================================================
  // Aufgaben – Gäste
  // =========================================================================

  testWidgets(
    'ALL-047 ALL-048 a guest reads a task, ticks a step and the task',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final photo = await f.admin.uploadFile(
        bytes: await pngBytes(),
        name: 'e2e-gast.png',
        mime: 'image/png',
      );
      final id = await addTask(
        f.admin,
        'E2E Gastleseansicht',
        due: inDays(1),
        assignees: [f.guest.id],
        notes: 'E2E Notiz für den Gast',
        checklist: const [
          TaskStep(id: 'a', text: 'E2E Schlüssel holen', done: true),
          TaskStep(id: 'b', text: 'E2E Blumen gießen'),
        ],
        photos: [photo],
      );
      final state = await start(tester, user: f.guest.username);
      await openTasks(tester);
      await openTask(tester, 'E2E Gastleseansicht');
      await waitFor(tester, inSheet(find.text(de.commonClose)));
      expect(
        inSheet(find.text(DateFormat.yMMMEd('de').format(inDays(1)))),
        findsOneWidget,
      );
      expect(inSheet(find.text('E2E Notiz für den Gast')), findsOneWidget);
      expect(
        inSheet(find.text(de.tasksChecklistDoneTotal(1, 2))),
        findsOneWidget,
      );
      expect(inSheet(find.text(de.tasksPhotos)), findsOneWidget);
      expect(inSheet(find.byType(FileThumb)), findsOneWidget);
      // Nothing to change: no fields, chips or "Speichern".
      expect(inSheet(find.byType(TextField)), findsNothing);
      expect(inSheet(find.byType(InputChip)), findsNothing);
      expect(inSheet(find.byType(FilterChip)), findsNothing);
      expect(inSheet(find.text(de.commonSave)), findsNothing);
      expect(inSheet(find.text(de.tasksEditTask)), findsNothing);
      // ALL-048
      await tap(
        tester,
        inSheet(find.widgetWithText(CheckboxListTile, 'E2E Blumen gießen')),
      );
      await waitFor(
        tester,
        inSheet(find.text(de.tasksChecklistDoneTotal(2, 2))),
      );
      await tap(tester, inSheet(find.text(de.commonClose)));
      await waitGone(tester, sheet());
      await tap(tester, taskCheck('E2E Gastleseansicht'));
      await waitGone(tester, find.text('E2E Gastleseansicht'));
      await synced(tester, state);
      final bea = await sessionOf(f.bea);
      await eventually(tester, 'the family gets both ticks', () async {
        final r = (await pull(bea, Collections.tasks))[id];
        if (r == null) return false;
        final t = Task.fromRecord(r);
        return t.done && t.checklist.every((s) => s.done);
      });
      final task = Task.fromRecord((await pull(bea, Collections.tasks))[id]!);
      expect(task.checklist.map((s) => s.text), [
        'E2E Schlüssel holen',
        'E2E Blumen gießen',
      ]);
      expect(task.title, 'E2E Gastleseansicht');
      expect(task.notes, 'E2E Notiz für den Gast');
      expect(task.photos.map((p) => p.id), [photo.id]);
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-049 ALL-051 a guest deletes nothing; a weekly task moves on',
    (tester) async {
      await resetTasks();
      final f = await theFamily();
      final keep = await addTask(
        f.admin,
        'E2E Gast nicht löschen',
        assignees: [f.guest.id],
      );
      final weekly = await addTask(
        f.admin,
        'E2E Gast wöchentlich',
        due: today(),
        repeat: TaskRepeat.weekly,
        assignees: [f.guest.id],
        notes: 'E2E bleibt',
      );
      final state = await start(tester, user: f.guest.username);
      await openTasks(tester);
      await waitFor(tester, find.text('E2E Gast nicht löschen'));
      final dismiss = find.ancestor(
        of: find.text('E2E Gast nicht löschen'),
        matching: find.byType(Dismissible),
      );
      expect(
        tester.widget<Dismissible>(dismiss.first).direction,
        DismissDirection.none,
      );
      await tester.drag(dismiss.first, const Offset(-600, 0));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('E2E Gast nicht löschen'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      // Through the API: the server keeps it and answers with the task.
      final guest = await sessionOf(f.guest);
      final r = await remove(guest, Collections.tasks, [keep]);
      final back = r.rejected.where((x) => x.id == keep);
      expect(back, isNotEmpty, reason: 'turned down');
      expect(back.first.deleted, isFalse, reason: 'answered with the task');
      expect((await pull(guest, Collections.tasks))[keep], isNotNull);
      expect((await pull(f.admin, Collections.tasks))[keep], isNotNull);
      // ALL-051
      await tap(tester, taskCheck('E2E Gast wöchentlich'));
      await until(
        tester,
        () =>
            DateUtils.dateOnly(taskOf(state, 'E2E Gast wöchentlich').due!) ==
            inDays(7),
        'moved on',
      );
      await synced(tester, state);
      await eventually(tester, 'moved on on the server', () async {
        final t = (await pull(f.admin, Collections.tasks))[weekly];
        return t != null &&
            DateUtils.dateOnly(Task.fromRecord(t).due!) == inDays(7);
      });
      final t = Task.fromRecord(
        (await pull(f.admin, Collections.tasks))[weekly]!,
      );
      expect(t.done, isFalse);
      expect(t.title, 'E2E Gast wöchentlich');
      expect(t.notes, 'E2E bleibt');
      expect(t.assigneeIds, [f.guest.id]);
      expect(t.repeat, TaskRepeat.weekly);
      // Nothing else to change: the guest only reads it.
      await openTask(tester, 'E2E Gast wöchentlich');
      expect(inSheet(find.byType(TextField)), findsNothing);
      await tap(tester, inSheet(find.text(de.commonClose)));
      await waitGone(tester, sheet());
      await finish(tester, state);
    },
  );

  testWidgets("ALL-052 ALL-053 a guest's own task; no links to other apps", (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    // Switched on for the family: the admin may list them.
    expect(await f.admin.listAccounts(), isA<List<ListAccount>>());
    final state = await start(tester, user: f.guest.username);
    await openTasks(tester);
    expect(find.byTooltip(de.commonConnectOtherApps), findsNothing);
    await quickAdd(tester, 'E2E Gast eigene');
    await synced(tester, state);
    final guest = await sessionOf(f.guest);
    await eventually(tester, 'the guest keeps it', () async {
      final t = await taskNamed(guest, 'E2E Gast eigene');
      return t != null && (t.visibleTo ?? const []).contains(f.guest.id);
    });
    await synced(tester, state);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('E2E Gast eigene'), findsOneWidget);
    // The server notes the guest as who created it: the guest's own task
    // opens in the editor (#365).
    final created = await taskNamed(guest, 'E2E Gast eigene');
    expect(created?.data[Task.createdByKey], f.guest.id);
    await openTask(tester, 'E2E Gast eigene');
    expect(inSheet(titleField), findsOneWidget);
    await closeSheet(tester);
    // ALL-053
    await openSection(tester, 'Einkauf');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip(de.commonConnectOtherApps), findsNothing);
    try {
      await guest.listAccounts();
      fail('a guest got the list accounts');
    } on ApiError catch (e) {
      expect(e.status, 403);
      expect(e.message, 'Für Gäste nicht verfügbar');
    }
    await finish(tester, state);
  });

  // Hint of ALL-052 (#365): the server notes who created a task; a guest
  // changes and deletes an own task, a task of the family stays for reading
  // and ticking off.
  testWidgets('ALL-052 hint: a guest may change or delete an own task', (
    tester,
  ) async {
    await resetTasks();
    final f = await theFamily();
    final guest = await sessionOf(f.guest);
    final id = uid('task');
    await seed(guest, Collections.tasks, {
      id: Task(
        id: id,
        title: 'E2E Gast löscht eigene',
        createdAt: DateTime.now(),
      ).toData(),
    });
    await addTask(f.admin, 'E2E Gast fremde', assignees: [f.guest.id]);
    final state = await start(tester, user: f.guest.username);
    await openTasks(tester);
    await waitFor(tester, find.text('E2E Gast löscht eigene'));
    await waitFor(tester, find.text('E2E Gast fremde'));
    DismissDirection swipe(String title) => tester
        .widget<Dismissible>(
          find
              .ancestor(
                of: find.text(title),
                matching: find.byType(Dismissible),
              )
              .first,
        )
        .direction;
    expect(swipe('E2E Gast löscht eigene'), DismissDirection.endToStart);
    expect(swipe('E2E Gast fremde'), DismissDirection.none);
    // The family's task: only for reading.
    await openTask(tester, 'E2E Gast fremde');
    expect(inSheet(titleField), findsNothing);
    expect(inSheet(find.text(de.commonClose)), findsOneWidget);
    await tap(tester, inSheet(find.text(de.commonClose)));
    await waitGone(tester, sheet());
    // The own one: renamed in the editor, the server keeps it.
    await openTask(tester, 'E2E Gast löscht eigene');
    expect(inSheet(titleField), findsOneWidget);
    await enter(tester, inSheet(titleField), 'E2E Gast ändert eigene');
    await saveSheet(tester);
    await synced(tester, state);
    await eventually(tester, 'the server keeps the new title', () async {
      final t = await taskNamed(guest, 'E2E Gast ändert eigene');
      return t != null && t.data[Task.createdByKey] == f.guest.id;
    });
    // And deleted in the editor; the server takes the deletion.
    await openTask(tester, 'E2E Gast ändert eigene');
    await tap(tester, inSheet(find.text(de.commonDelete)));
    await waitGone(tester, sheet());
    await waitFor(
      tester,
      snackText(de.undoWhatDeleted('E2E Gast ändert eigene')),
    );
    await synced(tester, state);
    await eventually(
      tester,
      'the server deleted it',
      () async => await taskNamed(guest, 'E2E Gast ändert eigene') == null,
    );
    expect(await taskNamed(guest, 'E2E Gast fremde'), isNotNull);
    await finish(tester, state);
  });

  // =========================================================================
  // Ämter & Punkte
  // =========================================================================

  testWidgets('ALL-057 the empty page of chores for adults and children', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    var state = await start(tester);
    await openChores(tester);
    expect(tabLabels(tester), [
      'Heute',
      'Ämter',
      'Routinen',
      'Belohnungen',
      'Konto',
    ]);
    await waitFor(tester, find.text(de.choresNoChoresYetDecide));
    expect(find.text(de.choresCreateFirstChore), findsOneWidget);
    await finish(tester, state);
    state = await start(tester, user: f.kid.username);
    await openChores(tester);
    await waitFor(tester, find.text(de.choresNoChoresYetAsk));
    expect(find.text(de.choresCreateFirstChore), findsNothing);
    expect(find.byTooltip(de.choresCreateChore), findsNothing);
    await finish(tester, state);
  });

  testWidgets('ALL-058 ALL-059 a new chore: points, how often, who; no title', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    final state = await start(tester);
    await openChores(tester);
    await tab(tester, de.sectionChores);
    await newChoreSheet(tester);
    // ALL-059
    await leaveField(tester);
    await tap(tester, inSheet(find.text(de.commonSave)));
    await tester.pump(const Duration(seconds: 1));
    expect(inSheet(find.text(de.choresNewChore)), findsOneWidget);
    expect(state.engine!.chores, isEmpty);
    // ALL-058
    await enter(
      tester,
      inSheet(field(de.choresWhatNeedsDoing)),
      'E2E Tisch decken',
    );
    await tap(tester, inSheet(find.text('🍽️')));
    expect(inSheet(find.text('2 ⭐')), findsOneWidget);
    await tap(tester, inSheet(stepperButton(de.mealsFewer)));
    await waitFor(tester, inSheet(find.text('1 ⭐')));
    await press(tester, inSheet(stepperButton(de.navMore)), 2);
    await waitFor(tester, inSheet(find.text('3 ⭐')));
    await tap(
      tester,
      inSheet(find.widgetWithText(ChoiceChip, ChoreRepeat.daily.label)),
    );
    await tap(
      tester,
      inSheet(find.widgetWithText(FilterChip, f.kid.displayName)),
    );
    await waitFor(tester, inSheet(find.text('1. ${f.kid.displayName}')));
    expect(inSheet(find.text(de.choresTakeTurns)), findsNothing);
    await saveSheet(tester);
    await waitFor(tester, find.text('E2E Tisch decken'));
    expect(
      choreLine('E2E Tisch decken'),
      '${de.eventRepeatDaily} · ${f.kid.displayName}',
    );
    expect(
      find.descendant(
        of: cardOf('E2E Tisch decken'),
        matching: find.text('⭐ 3'),
      ),
      findsOneWidget,
    );
    final chore = state.engine!.chores.single;
    expect(chore.emoji, '🍽️');
    expect(chore.points, 3);
    expect(chore.repeat, ChoreRepeat.daily);
    expect(chore.memberIds, [f.kid.id]);
    await tab(tester, de.commonToday);
    await waitFor(tester, inPerson(f.kid.id, choreTile('E2E Tisch decken')));
    expect(inPerson(fips.id, choreTile('E2E Tisch decken')), findsNothing);
    await finish(tester, state);
  });

  testWidgets('ALL-060 daily on weekdays only; the last day stays', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final state = await start(tester);
    await openChores(tester);
    await tab(tester, de.sectionChores);
    await newChoreSheet(tester);
    await enter(
      tester,
      inSheet(field(de.choresWhatNeedsDoing)),
      'E2E Werktags',
    );
    await tap(
      tester,
      inSheet(find.widgetWithText(FilterChip, f.kid.displayName)),
    );
    final days = weekdaysShort();
    Finder day(String d) => inSheet(find.widgetWithText(FilterChip, d));
    List<bool> selected() => [
      for (final d in days) tester.widget<FilterChip>(day(d)).selected,
    ];
    expect(selected(), List.filled(7, true), reason: 'every day at first');
    await tap(tester, day(days[5]));
    await tap(tester, day(days[6]));
    // All of them off: the last one stays.
    for (final d in days.take(5)) {
      await tap(tester, day(d));
    }
    expect(selected(), [false, false, false, false, true, false, false]);
    for (final d in days.take(4)) {
      await tap(tester, day(d));
    }
    expect(selected(), [true, true, true, true, true, false, false]);
    await saveSheet(tester);
    await waitFor(tester, find.text('E2E Werktags'));
    expect(
      choreLine('E2E Werktags'),
      '${days.take(5).join(', ')} · ${f.kid.displayName}',
    );
    final chore = state.engine!.chores.single;
    expect(chore.weekdays, {1, 2, 3, 4, 5});
    await tab(tester, de.commonToday);
    await waitFor(tester, personBlock(f.kid.id));
    final weekend = today().weekday > 5;
    expect(
      inPerson(f.kid.id, choreTile('E2E Werktags')),
      weekend ? findsNothing : findsOneWidget,
    );
    final saturday = DateUtils.addDaysToDate(
      today(),
      (DateTime.saturday - today().weekday) % 7,
    );
    expect(state.engine!.choreDue(chore, saturday), isFalse);
    expect(
      state.engine!.choreDue(chore, DateUtils.addDaysToDate(saturday, 1)),
      isFalse,
    );
    expect(
      state.engine!.choreDue(chore, DateUtils.addDaysToDate(saturday, 2)),
      isTrue,
    );
    await finish(tester, state);
  });

  testWidgets('ALL-061 a one-off chore on a day', (tester) async {
    await resetChores();
    final state = await start(tester);
    await openChores(tester);
    await tab(tester, de.sectionChores);
    await newChoreSheet(tester);
    await enter(
      tester,
      inSheet(field(de.choresWhatNeedsDoing)),
      'E2E Einmal morgen',
    );
    await tap(
      tester,
      inSheet(find.widgetWithText(ChoiceChip, ChoreRepeat.once.label)),
    );
    final long = DateFormat.MMMMEEEEd('de');
    await tap(
      tester,
      inSheet(find.widgetWithText(InputChip, long.format(today()))),
    );
    expect(await typeDate(tester, inDays(1)), isTrue);
    await dialogClosed(tester);
    await waitFor(tester, inSheet(find.text(long.format(inDays(1)))));
    await saveSheet(tester);
    await waitFor(tester, find.text('E2E Einmal morgen'));
    expect(
      choreLine('E2E Einmal morgen'),
      '${de.choresDate(DateFormat.MMMEd('de').format(inDays(1)))} · '
      '${de.commonEveryoneLower}',
    );
    final chore = state.engine!.chores.single;
    await tab(tester, de.commonToday);
    await tester.pump(const Duration(seconds: 1));
    expect(choreTile('E2E Einmal morgen'), findsNothing);
    expect(find.text(de.shoppingEveryone), findsNothing);
    expect(state.engine!.choreDue(chore, today()), isFalse);
    expect(state.engine!.choreDue(chore, inDays(1)), isTrue);
    await finish(tester, state);
  });

  testWidgets(
    'ALL-062 ALL-064 taking turns day by day; a new order begins today',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      final fips = await secondKid();
      // Started yesterday: today it is the second one's turn.
      await addChore(
        'E2E Seit gestern',
        members: [f.kid.id, fips.id],
        rotate: true,
        start: inDays(-1),
      );
      final state = await start(tester);
      await openChores(tester);
      await tab(tester, de.sectionChores);
      await newChoreSheet(tester);
      await enter(
        tester,
        inSheet(field(de.choresWhatNeedsDoing)),
        'E2E Abwechselnd',
      );
      await tap(
        tester,
        inSheet(find.widgetWithText(FilterChip, f.kid.displayName)),
      );
      expect(
        inSheet(find.text(de.choresTakeTurns)),
        findsNothing,
        reason: 'only from two people',
      );
      await tap(
        tester,
        inSheet(find.widgetWithText(FilterChip, fips.displayName)),
      );
      await waitFor(tester, inSheet(find.text('2. ${fips.displayName}')));
      expect(inSheet(find.text('1. ${f.kid.displayName}')), findsOneWidget);
      final turns = inSheet(
        find.widgetWithText(SwitchListTile, de.choresTakeTurns),
      );
      await waitFor(tester, turns);
      expect(inSheet(find.text(de.choresEachDaySSomeone)), findsOneWidget);
      await tap(tester, turns);
      await saveSheet(tester);
      await waitFor(tester, find.text('E2E Abwechselnd'));
      final names = '${f.kid.displayName} → ${fips.displayName}';
      expect(
        choreLine('E2E Abwechselnd'),
        '${de.eventRepeatDaily} · ${de.choresTakingTurnsNames(names)} · '
        'heute: ${f.kid.displayName}',
      );
      await tab(tester, de.commonToday);
      await waitFor(tester, inPerson(f.kid.id, choreTile('E2E Abwechselnd')));
      expect(inPerson(fips.id, choreTile('E2E Abwechselnd')), findsNothing);
      // Tomorrow the other one: as today with the chore from yesterday.
      final chore = state.engine!.chores.firstWhere(
        (c) => c.title == 'E2E Abwechselnd',
      );
      expect(chore.assigneeOn(inDays(1)), fips.id);
      expect(inPerson(fips.id, choreTile('E2E Seit gestern')), findsOneWidget);
      expect(inPerson(f.kid.id, choreTile('E2E Seit gestern')), findsNothing);
      // ALL-064: another order begins today with its first person.
      await tab(tester, de.sectionChores);
      expect(
        choreLine('E2E Seit gestern'),
        endsWith('heute: ${fips.displayName}'),
      );
      await tap(tester, find.text('E2E Seit gestern'));
      await waitFor(tester, inSheet(find.text(de.choresEditChore)));
      await tap(tester, inSheet(find.text('1. ${f.kid.displayName}')));
      await waitFor(tester, inSheet(find.text('1. ${fips.displayName}')));
      await tap(tester, inSheet(find.text(f.kid.displayName)));
      await waitFor(tester, inSheet(find.text('2. ${f.kid.displayName}')));
      await saveSheet(tester);
      await until(
        tester,
        () =>
            state.engine!.chores
                .firstWhere((c) => c.title == 'E2E Seit gestern')
                .memberIds
                .first ==
            fips.id,
        'new order saved',
      );
      final moved = state.engine!.chores.firstWhere(
        (c) => c.title == 'E2E Seit gestern',
      );
      expect(moved.memberIds, [fips.id, f.kid.id]);
      expect(moved.start, today(), reason: 'the new order starts today');
      expect(
        choreLine('E2E Seit gestern'),
        endsWith('heute: ${fips.displayName}'),
      );
      await finish(tester, state);
    },
  );

  testWidgets('ALL-063 a weekly chore taking turns week by week', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    await addChore(
      'E2E Wochenamt alt',
      members: [f.kid.id, fips.id],
      rotate: true,
      repeat: ChoreRepeat.weekly,
      start: inDays(-7),
    );
    final state = await start(tester);
    await openChores(tester);
    await tab(tester, de.sectionChores);
    await newChoreSheet(tester);
    await enter(
      tester,
      inSheet(field(de.choresWhatNeedsDoing)),
      'E2E Wochenamt',
    );
    await tap(
      tester,
      inSheet(find.widgetWithText(ChoiceChip, ChoreRepeat.weekly.label)),
    );
    await tap(
      tester,
      inSheet(find.widgetWithText(FilterChip, f.kid.displayName)),
    );
    await tap(
      tester,
      inSheet(find.widgetWithText(FilterChip, fips.displayName)),
    );
    await waitFor(tester, inSheet(find.text(de.wasteEachWeekSSomeone)));
    await tap(
      tester,
      inSheet(find.widgetWithText(SwitchListTile, de.choresTakeTurns)),
    );
    await saveSheet(tester);
    await waitFor(tester, find.text('E2E Wochenamt'));
    await tab(tester, de.commonToday);
    await waitFor(tester, inPerson(f.kid.id, choreTile('E2E Wochenamt')));
    expect(inPerson(fips.id, choreTile('E2E Wochenamt')), findsNothing);
    expect(choreStatus('E2E Wochenamt'), '+2 ⭐ · ${de.choresWeek}');
    await tap(tester, choreCheck('E2E Wochenamt'));
    await until(
      tester,
      () => choreStatus('E2E Wochenamt') == '+2 ⭐ · ${de.choresDone('')}',
      'done',
    );
    final engine = state.engine!;
    final chore = engine.chores.firstWhere((c) => c.title == 'E2E Wochenamt');
    final monday = weekStart(today());
    for (var i = 0; i < 7; i++) {
      expect(
        engine.choreCompletion(chore, DateUtils.addDaysToDate(monday, i)),
        isNotNull,
        reason: 'done for the whole week (day $i)',
      );
    }
    expect(
      engine.choreCompletion(chore, DateUtils.addDaysToDate(monday, 7)),
      isNull,
    );
    // Next week the other one: as now with the chore from last week.
    expect(chore.assigneeOn(inDays(7)), fips.id);
    expect(inPerson(fips.id, choreTile('E2E Wochenamt alt')), findsOneWidget);
    expect(inPerson(f.kid.id, choreTile('E2E Wochenamt alt')), findsNothing);
    await finish(tester, state);
  });

  testWidgets('ALL-065 ALL-066 pausing and deleting a chore', (tester) async {
    await resetChores();
    final f = await theFamily();
    await addChore('E2E Pausieren', members: [f.kid.id]);
    final state = await start(tester);
    await openChores(tester);
    await waitFor(tester, inPerson(f.kid.id, choreTile('E2E Pausieren')));
    await tab(tester, de.sectionChores);
    await newChoreSheet(tester);
    expect(
      inSheet(find.text(de.locationPause)),
      findsNothing,
      reason: 'only for chores that exist',
    );
    await closeSheet(tester);
    await tap(tester, find.text('E2E Pausieren'));
    await waitFor(tester, inSheet(find.text(de.choresEditChore)));
    expect(inSheet(find.text(de.choresEGDuringHolidays)), findsOneWidget);
    await tap(
      tester,
      inSheet(find.widgetWithText(SwitchListTile, de.locationPause)),
    );
    await saveSheet(tester);
    await until(tester, () => state.engine!.chores.single.paused, 'paused');
    await tester.pump(const Duration(milliseconds: 500));
    expect(choreLine('E2E Pausieren'), contains('pausiert'));
    await tab(tester, de.commonToday);
    await tester.pump(const Duration(seconds: 1));
    expect(choreTile('E2E Pausieren'), findsNothing);
    // ALL-066
    await tab(tester, de.sectionChores);
    await tap(tester, find.text('E2E Pausieren'));
    await waitFor(tester, inSheet(find.text(de.choresEditChore)));
    await tap(tester, inSheet(find.text(de.commonDelete)));
    await waitGone(tester, sheet());
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Pausieren')));
    expect(state.engine!.chores, isEmpty);
    expect(find.text('E2E Pausieren'), findsNothing);
    await undo(tester);
    await waitFor(tester, find.text('E2E Pausieren'));
    expect(state.engine!.chores.single.title, 'E2E Pausieren');
    await finish(tester, state);
  });

  // In English the list of chores says "paused" and "today: …" (#545).
  testWidgets('ALL-065 hint: "pausiert" and "heute:" in English', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    await addChore('E2E Paused chore', members: [f.kid.id], paused: true);
    await addChore(
      'E2E Turns chore',
      members: [f.kid.id, fips.id],
      rotate: true,
    );
    final state = await start(tester);
    final en = lookupL10n(const Locale('en'));
    addTearDown(() => state.setLanguage('de'));
    await state.setLanguage('en');
    await tester.pump(const Duration(seconds: 2));
    await openSection(tester, en.sectionChores, keepTip: true);
    await tester.pump(const Duration(milliseconds: 500));
    if (find.text(en.tipGotIt).evaluate().isNotEmpty) {
      await tap(tester, find.text(en.tipGotIt).last);
    }
    await tab(tester, en.sectionChores);
    await waitFor(tester, find.text('E2E Paused chore'));
    final lines = [choreLine('E2E Paused chore'), choreLine('E2E Turns chore')];
    debugPrint('E2E-INFO chores in English: $lines');
    await state.setLanguage('de');
    await tester.pump(const Duration(seconds: 1));
    expect(
      lines.where((l) => l.contains('pausiert') || l.contains('heute:')),
      isEmpty,
      reason: lines.join('\n'),
    );
    await finish(tester, state);
  });

  testWidgets(
    'ALL-067 ALL-068 adults tick off: points at once, "Wer hat es erledigt?"',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      final fips = await secondKid();
      await addChore('E2E Für Kind', members: [f.kid.id], points: 3);
      await addChore('E2E Für alle', points: 2);
      final state = await start(tester);
      await openChores(tester);
      await waitFor(tester, inPerson(f.kid.id, choreTile('E2E Für Kind')));
      expect(shownPoints(tester, f.kid.id), 0);
      await tap(tester, choreCheck('E2E Für Kind'));
      await until(
        tester,
        () => shownPoints(tester, f.kid.id) == 3,
        'the points at once',
      );
      expect(choreStatus('E2E Für Kind'), '+3 ⭐ · ${de.choresDone('')}');
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: choreTile('E2E Für Kind'),
                matching: find.text('E2E Für Kind'),
              ),
            )
            .style
            ?.decoration,
        TextDecoration.lineThrough,
      );
      // ALL-068
      await waitFor(tester, choreTile('E2E Für alle'));
      expect(headingOf(tester, 'E2E Für alle'), de.shoppingEveryone);
      await tap(tester, choreCheck('E2E Für alle'));
      await waitFor(tester, find.text(de.choresWhoDid));
      await tap(
        tester,
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(fips.displayName),
        ),
      );
      await dialogClosed(tester);
      await until(
        tester,
        () =>
            choreStatus('E2E Für alle') ==
            '+2 ⭐ · ${de.choresDone(de.choresName(fips.displayName))}',
        'done by Fips',
      );
      expect(shownPoints(tester, fips.id), 2);
      expect(shownPoints(tester, f.kid.id), 3);
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-069 ALL-072 a child ticks off: a request; only open ones go back',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      final room = await addChore(
        'E2E Kind Zimmer',
        members: [f.kid.id],
        points: 2,
      );
      final bin = await addChore(
        'E2E Kind Müll',
        members: [f.kid.id],
        points: 1,
      );
      String done(String id) =>
          Chore(id: id, title: '', start: today()).completionId(today());
      // The bins were confirmed already.
      await seed(f.admin, Collections.pointEntries, {
        done(bin): PointEntry(
          id: done(bin),
          memberId: f.kid.id,
          points: 1,
          title: 'E2E Kind Müll',
          kind: PointKind.chore,
          at: DateTime.now(),
          refId: bin,
          decidedBy: f.adminMember.id,
        ).toData(),
      });
      final state = await start(tester, user: f.kid.username);
      await openChores(tester);
      await waitFor(tester, choreTile('E2E Kind Zimmer'));
      expect(shownPoints(tester, f.kid.id), 1);
      await tap(tester, choreCheck('E2E Kind Zimmer'));
      await waitFor(tester, snackText(de.choresGreatParentsWillConfirm));
      await until(
        tester,
        () =>
            choreStatus('E2E Kind Zimmer') ==
            '+2 ⭐ · ${de.choresWaitingConfirmation2}',
        'waiting',
      );
      final check = tester.widget<RoundCheck>(choreCheck('E2E Kind Zimmer'));
      final colors = FamioColors.of(
        tester.element(choreCheck('E2E Kind Zimmer')),
      );
      expect(check.value, isTrue);
      expect(check.color, colors.inkSoft, reason: 'grey while waiting');
      expect(shownPoints(tester, f.kid.id), 1, reason: 'no points yet');
      await synced(tester, state);
      Future<String?> status(String id) async =>
          (await pull(
                f.admin,
                Collections.pointEntries,
              ))[done(id)]?.data['status']
              as String?;
      await eventually(
        tester,
        'a request on the server',
        () async => await status(room) == PointStatus.pending.name,
      );
      // ALL-072
      await snackGone(tester);
      await tap(tester, choreCheck('E2E Kind Zimmer'));
      await until(
        tester,
        () => choreStatus('E2E Kind Zimmer') == '+2 ⭐',
        'open again',
      );
      expect(
        tester.widget<RoundCheck>(choreCheck('E2E Kind Zimmer')).value,
        isFalse,
      );
      await synced(tester, state);
      await eventually(
        tester,
        'the request withdrawn',
        () async => await status(room) == null,
      );
      await tap(tester, choreCheck('E2E Kind Müll'));
      await tester.pump(const Duration(seconds: 1));
      expect(choreStatus('E2E Kind Müll'), '+1 ⭐ · ${de.choresDone('')}');
      await synced(tester, state);
      expect(await status(bin), PointStatus.approved.name);
      await finish(tester, state);
    },
  );

  testWidgets("ALL-070 adults confirm or decline a child's request", (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final yes = await addChore(
      'E2E Bestätigen',
      members: [f.kid.id],
      points: 2,
    );
    final no = await addChore('E2E Ablehnen', members: [f.kid.id], points: 3);
    final kid = await sessionOf(f.kid);
    for (final (id, title, points) in [
      (yes, 'E2E Bestätigen', 2),
      (no, 'E2E Ablehnen', 3),
    ]) {
      final key = Chore(
        id: id,
        title: title,
        start: today(),
      ).completionId(today());
      await seed(kid, Collections.pointEntries, {
        key: PointEntry(
          id: key,
          memberId: f.kid.id,
          points: points,
          title: title,
          kind: PointKind.chore,
          at: DateTime.now(),
          refId: id,
          status: PointStatus.pending,
        ).toData(),
      });
    }
    final state = await start(tester);
    await openChores(tester);
    await waitFor(tester, find.text(de.choresWaitingConfirmation));
    String line(String title) => '${f.kid.displayName}: $title';
    Finder pending(String title) => find
        .ancestor(of: find.text(line(title)), matching: find.byType(SoftCard))
        .first;
    await waitFor(tester, find.text(line('E2E Bestätigen')));
    await waitFor(tester, find.text(line('E2E Ablehnen')));
    expect(
      find.descendant(
        of: pending('E2E Bestätigen'),
        matching: find.text(de.choresPointsPoints(2)),
      ),
      findsOneWidget,
    );
    await tap(
      tester,
      find.descendant(
        of: pending('E2E Bestätigen'),
        matching: find.byTooltip(de.commonConfirm),
      ),
    );
    await until(
      tester,
      () => choreStatus('E2E Bestätigen') == '+2 ⭐ · ${de.choresDone('')}',
      'confirmed',
    );
    expect(shownPoints(tester, f.kid.id), 2);
    await tap(
      tester,
      find.descendant(
        of: pending('E2E Ablehnen'),
        matching: find.byTooltip(de.choresDecline),
      ),
    );
    await until(
      tester,
      () => choreStatus('E2E Ablehnen') == '+3 ⭐ · ${de.choresDeclined}',
      'declined',
    );
    expect(shownPoints(tester, f.kid.id), 2, reason: 'no points declined');
    expect(find.text(de.choresWaitingConfirmation), findsNothing);
    await openAccount(tester, f.kid.displayName);
    expect(
      find.descendant(
        of: accountRow('E2E Ablehnen'),
        matching: find.textContaining(de.choresDeclined),
      ),
      findsOneWidget,
    );
    expect(
      trailingOf(tester, 'E2E Ablehnen').style?.decoration,
      TextDecoration.lineThrough,
    );
    expect(
      trailingOf(tester, 'E2E Bestätigen').style?.decoration,
      isNot(TextDecoration.lineThrough),
    );
    await finish(tester, state);
  });

  testWidgets(
    'ALL-073 ALL-074 a child sees and ticks its own, manages nothing',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      final fips = await secondKid();
      await addChore(
        'E2E Geschwister dran',
        members: [f.kid.id, fips.id],
        rotate: true,
        start: inDays(-1),
      );
      await addReward('E2E Kinderpreis', 5);
      await addRoutine('E2E Kinderroutine', member: f.kid.id);
      final state = await start(tester, user: f.kid.username);
      await openChores(tester);
      await waitFor(tester, personBlock(f.kid.id));
      expect(byTypeName('_PersonToday'), findsOneWidget, reason: 'only me');
      expect(personBlock(fips.id), findsNothing);
      expect(choreTile('E2E Geschwister dran'), findsNothing);
      final kid = await sessionOf(f.kid);
      final foreign = uid('points');
      expect(
        await refused(
          kid,
          Collections.pointEntries,
          foreign,
          PointEntry(
            id: foreign,
            memberId: fips.id,
            points: 2,
            title: 'E2E Für Fips',
            kind: PointKind.chore,
            at: DateTime.now(),
            status: PointStatus.pending,
          ).toData(),
        ),
        isTrue,
        reason: 'points for the sibling',
      );
      // ALL-074: no adding anywhere, no editors.
      for (final t in [
        de.commonToday,
        de.sectionChores,
        de.choresTabRoutines,
        de.choresTabRewards,
        de.settingsAccount,
      ]) {
        await tab(tester, t);
        for (final add in [
          de.choresCreateChore,
          de.choresCreateRoutine,
          de.choresCreateReward,
        ]) {
          expect(find.byTooltip(add), findsNothing, reason: '$t: $add');
        }
      }
      await tab(tester, de.sectionChores);
      await tap(tester, find.text('E2E Geschwister dran'));
      await tester.pump(const Duration(seconds: 1));
      expect(sheet(), findsNothing);
      await tab(tester, de.choresTabRoutines);
      await waitFor(tester, find.text('E2E Kinderroutine'));
      expect(find.byTooltip(de.commonEdit), findsNothing);
      await tab(tester, de.choresTabRewards);
      await tap(tester, find.text('E2E Kinderpreis'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(de.rewardsEditReward), findsNothing);
      await openAccount(tester, f.kid.displayName);
      for (final chip in [
        de.choresBonusPoints,
        de.conflictsBooking,
        de.choresSetPocketMoney,
        de.choresRedeemPoints,
      ]) {
        expect(find.text(chip), findsNothing, reason: chip);
      }
      await back(tester);
      // The server takes none of it.
      final chore = uid('chore');
      expect(
        await refused(
          kid,
          Collections.chores,
          chore,
          Chore(id: chore, title: 'E2E Kind-Amt', start: today()).toData(),
        ),
        isTrue,
        reason: 'chore',
      );
      final reward = uid('reward');
      expect(
        await refused(
          kid,
          Collections.rewards,
          reward,
          Reward(id: reward, title: 'E2E Kind-Preis', cost: 1).toData(),
        ),
        isTrue,
        reason: 'reward',
      );
      final money = uid('money');
      expect(
        await refused(
          kid,
          Collections.moneyEntries,
          money,
          MoneyEntry(
            id: money,
            memberId: f.kid.id,
            cents: 10000,
            at: DateTime.now(),
            kind: MoneyKind.gift,
          ).toData(),
        ),
        isTrue,
        reason: 'pocket money',
      );
      expect(
        await titlesOf(f.admin, Collections.chores),
        isNot(contains('E2E Kind-Amt')),
      );
      expect((await pull(f.admin, Collections.moneyEntries))[money], isNull);
      await finish(tester, state);
    },
  );

  testWidgets('ALL-075 a guest looks at chores and routines, ticks nothing', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    await addChore('E2E Gast sieht', members: [f.kid.id]);
    await addRoutine(
      'E2E Gastroutine',
      member: f.kid.id,
      steps: const [('🧦', 'E2E Socken')],
    );
    await addReward('E2E Gastpreis', 5);
    await addPoints(f.kid, 5);
    final state = await start(tester, user: f.guest.username);
    await openChores(tester);
    await waitFor(tester, inPerson(f.kid.id, choreTile('E2E Gast sieht')));
    expect(inPerson(f.kid.id, routineTile('E2E Gastroutine')), findsOneWidget);
    expect(find.byType(RoundCheck), findsNothing, reason: 'no ticks');
    await tab(tester, de.choresTabRoutines);
    await waitFor(tester, find.text('E2E Gastroutine'));
    await tab(tester, de.choresTabRewards);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(de.rewardsRedeem), findsNothing);
    await tab(tester, de.settingsAccount);
    await waitFor(tester, find.text(f.kid.displayName));
    await tap(tester, find.text(f.kid.displayName).last);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MemberAccountScreen), findsNothing);
    await finish(tester, state);
  });

  // Guests get no points, pocket money or its settings
  // (Collections.guestReadable): the tab "Konto" says so instead of showing
  // "⭐ 0", "0,00 €" and "Kein Taschengeld eingestellt" (#545).
  testWidgets('ALL-075 hint: the account tab shows guests the balances', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    await addPoints(f.kid, 7);
    await addMoney(f.kid, 1000);
    final state = await start(tester, user: f.guest.username);
    await openChores(tester);
    await tab(tester, de.settingsAccount);
    await waitFor(tester, find.text(f.kid.displayName));
    final texts = textsIn(cardOf(f.kid.displayName));
    debugPrint('E2E-INFO a guest sees for the child: $texts');
    expect(
      texts.contains('⭐ 0') && texts.contains(formatEuro(0)),
      isFalse,
      reason: 'real balances ⭐ 7 and ${formatEuro(1000)}, shown: $texts',
    );
    expect(find.text(de.choresAccountsGuests), findsOneWidget);
    await finish(tester, state);
  });

  testWidgets(
    'ALL-076 "Heute" per role; without children everyone but the guests',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      final fips = await secondKid();
      await addChore('E2E Nur Kind', members: [f.kid.id]);
      await addPoints(f.kid, 4);
      var state = await start(tester);
      await openChores(tester);
      await waitFor(tester, personBlock(f.kid.id));
      expect(byTypeName('_PersonToday'), findsNWidgets(2));
      expect(personBlock(fips.id), findsOneWidget);
      expect(shownPoints(tester, f.kid.id), 4);
      expect(shownPoints(tester, fips.id), 0);
      expect(inPerson(fips.id, find.text(de.kioskFreeToday)), findsOneWidget);
      expect(inPerson(f.kid.id, find.text(de.kioskFreeToday)), findsNothing);
      await finish(tester, state);
      state = await start(tester, user: f.kid.username);
      await openChores(tester);
      await waitFor(tester, personBlock(f.kid.id));
      expect(byTypeName('_PersonToday'), findsOneWidget);
      await finish(tester, state);
      // Without children (both made adults for a moment).
      Future<void> roles(MemberRole role) async {
        for (final k in [f.kid, fips]) {
          await f.admin.updateUser(k.id, role: role);
        }
      }

      addTearDown(() => roles(MemberRole.child));
      await roles(MemberRole.adult);
      state = await start(tester);
      await openChores(tester);
      await waitFor(tester, personBlock(f.adminMember.id));
      for (final m in [f.adminMember, f.bea, f.carl, f.kid, fips]) {
        expect(personBlock(m.id), findsOneWidget, reason: m.displayName);
      }
      expect(personBlock(f.guest.id), findsNothing);
      await finish(tester, state);
      await roles(MemberRole.child);
    },
  );

  // =========================================================================
  // Ämter – Routinen
  // =========================================================================

  List<String> fieldTexts() => [
    for (final e in inSheet(find.byType(TextField)).evaluate())
      (e.widget as TextField).controller?.text ?? '',
  ];

  testWidgets('ALL-077 ALL-078 the morning and the evening routine', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final state = await start(tester);
    await openChores(tester);
    await tab(tester, de.choresTabRoutines);
    await waitFor(tester, find.text(de.routinesRoutinesChecklistsPicturesE));
    await tap(tester, find.text(de.routinesCreateMorningRoutine));
    await waitFor(tester, inSheet(find.text(de.routinesNewRoutine)));
    final texts = fieldTexts();
    expect(texts.first, de.routinesMorningRoutine);
    expect(
      [for (var i = 2; i < texts.length; i += 2) texts[i]],
      [
        de.routinesGetUp,
        de.routinesToiletWashHands,
        de.routinesGetDressed,
        de.routinesHaveBreakfast,
        de.routinesBrushTeeth,
        de.routinesPackBag,
      ],
    );
    expect(
      [for (var i = 1; i < texts.length; i += 2) texts[i]],
      ['🛏️', '🚽', '👕', '🥣', '🪥', '🎒'],
    );
    expect(
      inSheet(find.text(de.routinesReminderTime('07:00'))),
      findsOneWidget,
    );
    expect(inSheet(find.text('2 ⭐')), findsOneWidget);
    expect(
      [
        for (final d in weekdaysShort())
          tester
              .widget<FilterChip>(inSheet(find.widgetWithText(FilterChip, d)))
              .selected,
      ],
      [true, true, true, true, true, false, false],
    );
    await tap(
      tester,
      inSheet(find.widgetWithText(ChoiceChip, f.kid.displayName)),
    );
    await saveSheet(tester);
    await waitFor(tester, find.text(de.routinesMorningRoutine));
    final weekend = today().weekday > 5;
    expect(
      textsIn(cardOf(de.routinesMorningRoutine)),
      contains(
        [
          f.kid.displayName,
          de.routinesCountSteps(6),
          '⏰ 07:00',
          '+2 ⭐',
          if (weekend) de.routinesNotToday,
        ].join(' · '),
      ),
    );
    // ALL-078
    await tap(tester, find.text(de.routinesEveningRoutineTemplate));
    await waitFor(tester, inSheet(find.text(de.routinesNewRoutine)));
    expect(fieldTexts().first, de.routinesEveningRoutine);
    await saveSheet(tester);
    await waitFor(tester, find.text(de.routinesEveningRoutine));
    expect(find.text(de.routinesEveningRoutineTemplate), findsNothing);
    expect(state.engine!.routines.map((r) => r.title).toSet(), {
      de.routinesMorningRoutine,
      de.routinesEveningRoutine,
    });
    await finish(tester, state);
  });

  testWidgets('ALL-079 a routine of its own: steps, order, empty ones go', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final state = await start(tester);
    await openChores(tester);
    await tab(tester, de.choresTabRoutines);
    await tap(tester, find.byTooltip(de.choresCreateRoutine));
    await waitFor(tester, inSheet(find.text(de.routinesNewRoutine)));
    final fields = inSheet(find.byType(TextField));
    await enterAt(tester, fields, 0, 'E2E Sportsachen');
    await tap(tester, inSheet(find.text('🏃')));
    await tap(
      tester,
      inSheet(find.widgetWithText(ChoiceChip, f.kid.displayName)),
    );
    // Not today: "heute nicht".
    await tap(
      tester,
      inSheet(
        find.widgetWithText(FilterChip, weekdaysShort()[today().weekday - 1]),
      ),
    );
    await tap(tester, inSheet(find.text(de.routinesRemind)));
    await pickTime(tester, 16, 30);
    await waitFor(tester, inSheet(find.text(de.routinesReminderTime('16:30'))));
    await press(tester, inSheet(stepperButton(de.navMore)), 3);
    await waitFor(tester, inSheet(find.text('3 ⭐')));
    for (var i = 0; i < 4; i++) {
      await tap(tester, inSheet(find.text(de.routinesAddStep)));
    }
    await until(
      tester,
      () => fields.evaluate().length == 9,
      'four empty steps',
    );
    for (final (i, text) in [
      '👟',
      'E2E Schuhe',
      '🧥',
      'E2E Jacke',
      '🧢',
      'E2E Mütze',
    ].indexed) {
      await enterAt(tester, fields, i + 1, text);
    }
    await leaveField(tester);
    await tap(tester, inSheet(find.byTooltip(de.routinesMoveUp)).at(2));
    expect(fieldTexts().skip(1).toList(), [
      '👟',
      'E2E Schuhe',
      '🧢',
      'E2E Mütze',
      '🧥',
      'E2E Jacke',
      '',
      '',
    ]);
    await tap(tester, inSheet(find.byTooltip(de.commonRemove)).at(2));
    expect(fieldTexts().skip(1).toList(), [
      '👟',
      'E2E Schuhe',
      '🧢',
      'E2E Mütze',
      '',
      '',
    ]);
    await saveSheet(tester);
    await waitFor(tester, find.text('E2E Sportsachen'));
    final r = state.engine!.routines.single;
    expect(
      [for (final s in r.steps) (s.emoji, s.title)],
      [('👟', 'E2E Schuhe'), ('🧢', 'E2E Mütze')],
    );
    expect(r.emoji, '🏃');
    expect(r.time, '16:30');
    expect(r.points, 3);
    expect(r.memberId, f.kid.id);
    expect(r.weekdays, {
      for (var d = 1; d <= 7; d++)
        if (d != today().weekday) d,
    });
    expect(
      textsIn(cardOf('E2E Sportsachen')),
      contains(
        [
          f.kid.displayName,
          de.routinesCountSteps(2),
          '⏰ 16:30',
          '+3 ⭐',
          de.routinesNotToday,
        ].join(' · '),
      ),
    );
    await finish(tester, state);
  });

  testWidgets('ALL-080 ALL-081 a child goes through its routine: one request', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final id = await addRoutine(
      'E2E Zähne',
      member: f.kid.id,
      points: 2,
      steps: const [
        ('🪥', 'E2E Putzen'),
        ('💧', 'E2E Ausspülen'),
        ('🧴', 'E2E Eincremen'),
      ],
    );
    final pointsId = Routine(id: id, title: '').pointsId(today(), f.kid.id);
    Future<SyncRecord?> request() async =>
        (await pull(f.admin, Collections.pointEntries))[pointsId];
    final state = await start(tester, user: f.kid.username);
    await openChores(tester);
    await waitFor(tester, routineTile('E2E Zähne'));
    expect(
      find.descendant(of: routineTile('E2E Zähne'), matching: find.text('0/3')),
      findsOneWidget,
    );
    Future<void> openIt() async {
      await tap(
        tester,
        find.descendant(
          of: routineTile('E2E Zähne'),
          matching: find.text('E2E Zähne'),
        ),
      );
      await waitFor(tester, find.byType(RoutineRunScreen));
    }

    bool struck(String t) =>
        tester.widget<Text>(find.text(t)).style?.decoration ==
        TextDecoration.lineThrough;
    Future<void> step(String t, {required bool done}) async {
      await tap(tester, find.text(t));
      await until(tester, () => struck(t) == done, '$t: $done');
    }

    await openIt();
    await waitFor(tester, find.text('🪥 E2E Zähne'));
    for (final t in ['E2E Putzen', 'E2E Ausspülen', 'E2E Eincremen']) {
      await step(t, done: true);
    }
    await waitFor(tester, find.text(de.routinesDonePointsPoints(2)));
    await synced(tester, state);
    await eventually(
      tester,
      'a request to the parents',
      () async => (await request())?.data['status'] == PointStatus.pending.name,
    );
    expect((await request())!.data['points'], 2);
    // ALL-081: a step open again, the open request goes …
    await step('E2E Eincremen', done: false);
    await waitGone(tester, find.text(de.routinesDonePointsPoints(2)));
    await synced(tester, state);
    await eventually(
      tester,
      'the request withdrawn',
      () async => await request() == null,
    );
    // … and comes once again.
    await step('E2E Eincremen', done: true);
    await synced(tester, state);
    await eventually(
      tester,
      'asked again',
      () async => (await request())?.data['status'] == PointStatus.pending.name,
    );
    final entries = [
      for (final r in (await pull(f.admin, Collections.pointEntries)).values)
        if (r.data['refId'] == id) r,
    ];
    expect(entries, hasLength(1), reason: 'the points only once');
    await back(tester);
    await waitFor(
      tester,
      find.descendant(of: routineTile('E2E Zähne'), matching: find.text('🎉')),
    );
    // Confirmed points stay when a step is opened again.
    final open = (await request())!;
    await seed(f.admin, Collections.pointEntries, {
      pointsId: {
        ...open.data,
        'status': PointStatus.approved.name,
        'decidedBy': f.adminMember.id,
      },
    });
    await arrives(
      tester,
      state,
      (e) =>
          e.record(Collections.pointEntries, pointsId)?.data['status'] ==
          PointStatus.approved.name,
      'confirmed',
    );
    await openIt();
    await step('E2E Putzen', done: false);
    await synced(tester, state);
    await tester.pump(const Duration(seconds: 2));
    expect((await request())?.data['status'], PointStatus.approved.name);
    expect(state.engine!.pointBalance(f.kid.id), 2);
    await finish(tester, state);
  });

  testWidgets(
    'ALL-082 ALL-083 a routine for all asks for whom; guests tick nothing',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      await addRoutine(
        'E2E Für alle Routine',
        steps: const [('🧺', 'E2E Wäsche')],
      );
      var state = await start(tester);
      await openChores(tester);
      await tab(tester, de.choresTabRoutines);
      await tap(tester, find.text('E2E Für alle Routine'));
      await waitFor(tester, find.byType(SimpleDialog));
      expect(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(de.medsWhom),
        ),
        findsOneWidget,
      );
      await tap(
        tester,
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(f.kid.displayName),
        ),
      );
      await waitFor(tester, find.byType(RoutineRunScreen));
      expect(
        tester.widget<RoutineRunScreen>(find.byType(RoutineRunScreen)).memberId,
        f.kid.id,
      );
      expect(find.text(f.kid.displayName), findsWidgets);
      await finish(tester, state);
      // ALL-083
      state = await start(tester, user: f.guest.username);
      await openChores(tester);
      final tile = inPerson(f.kid.id, routineTile('E2E Für alle Routine'));
      await waitFor(tester, tile);
      await tap(
        tester,
        find.descendant(of: tile, matching: find.text('E2E Für alle Routine')),
      );
      await waitFor(tester, find.byType(RoutineRunScreen));
      await tap(tester, find.text('E2E Wäsche'));
      await tap(tester, find.byType(RoundCheck));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<RoundCheck>(find.byType(RoundCheck)).value, isFalse);
      expect(
        tester.widget<Text>(find.text('E2E Wäsche')).style?.decoration,
        isNot(TextDecoration.lineThrough),
      );
      expect(state.engine!.records(Collections.routineRuns), isEmpty);
      await finish(tester, state);
    },
  );

  // =========================================================================
  // Ämter – Belohnungen & Punkte
  // =========================================================================

  testWidgets(
    'ALL-085 ALL-086 rewards: an idea to take, our own one, deleted',
    (tester) async {
      await resetChores();
      final state = await start(tester);
      await openChores(tester);
      await tab(tester, de.choresTabRewards);
      await waitFor(tester, find.text(de.rewardsWhatWorthCollectingIdeas));
      final idea = '${de.rewards30MinutesTablet} · 10 ⭐';
      await waitFor(tester, find.text(idea));
      await tap(
        tester,
        find.descendant(of: cardOf(idea), matching: find.text(de.commonApply)),
      );
      await waitFor(tester, find.text(de.rewards30MinutesTablet));
      expect(
        find.descendant(
          of: cardOf(de.rewards30MinutesTablet),
          matching: find.text('⭐ 10'),
        ),
        findsOneWidget,
      );
      expect(state.engine!.rewards.single.cost, 10);
      // ALL-086
      await tap(tester, find.byTooltip(de.choresCreateReward));
      await waitFor(tester, find.text(de.rewardsNewReward));
      expect(inDialog(find.text('10 ⭐')), findsOneWidget);
      final minus = inDialog(stepperButton(de.mealsFewer));
      final plus = inDialog(stepperButton(de.navMore));
      await press(tester, minus, 9);
      expect(inDialog(find.text('1 ⭐')), findsOneWidget);
      expect(enabledButton(tester, minus), isFalse, reason: 'not below 1');
      expect(stepper(tester).min, 1);
      expect(stepper(tester).max, 1000);
      await press(tester, plus, 49);
      expect(inDialog(find.text('50 ⭐')), findsOneWidget);
      await press(tester, plus, 1);
      expect(
        inDialog(find.text('55 ⭐')),
        findsOneWidget,
        reason: 'from 50 on in fives',
      );
      // No title: nothing.
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(de.rewardsNewReward), findsOneWidget);
      expect(state.engine!.rewards, hasLength(1));
      await enter(tester, inDialog(field(de.commonReward)), 'E2E Kino');
      await enter(tester, inDialog(field(de.rewardsEmoji)), '');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await waitFor(tester, find.text('E2E Kino'));
      final kino = state.engine!.rewards.firstWhere(
        (r) => r.title == 'E2E Kino',
      );
      expect(kino.emoji, '🎁', reason: 'no emoji: a present');
      expect(kino.cost, 55);
      await tap(tester, find.text('E2E Kino'));
      await waitFor(tester, find.text(de.rewardsEditReward));
      await tap(tester, inDialog(find.text(de.commonDelete)));
      await dialogClosed(tester);
      await waitFor(tester, snackText(de.undoWhatDeleted('E2E Kino')));
      expect(state.engine!.rewards.any((r) => r.title == 'E2E Kino'), isFalse);
      await undo(tester);
      await waitFor(tester, find.text('E2E Kino'));
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-087 ALL-088 a child: too few points, then a wish the parents confirm',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      await addReward('E2E Eis', 10, emoji: '🍦');
      await addPoints(f.kid, 4);
      var state = await start(tester, user: f.kid.username);
      await openChores(tester);
      await tab(tester, de.choresTabRewards);
      await waitFor(tester, find.text(de.rewardsYouHave));
      expect(find.text('⭐ 4'), findsOneWidget);
      final redeem = find.descendant(
        of: cardOf('E2E Eis'),
        matching: find.text(de.rewardsRedeem),
      );
      await tap(tester, redeem);
      await waitFor(tester, snackText(de.rewardsYouStillNeedPoints(6)));
      expect(dialog(), findsNothing);
      expect(state.engine!.pendingPoints, isEmpty, reason: 'nothing booked');
      // ALL-088
      await addPoints(f.kid, 16, title: 'E2E Mehr Punkte');
      await arrives(
        tester,
        state,
        (e) => e.pointBalance(f.kid.id) == 20,
        '20 points',
      );
      await snackGone(tester);
      await tap(tester, redeem);
      await waitFor(tester, find.text(de.rewardsRedeemCostPointsParents(10)));
      expect(find.text('🍦 E2E Eis'), findsOneWidget);
      await tap(tester, find.text(de.rewardsWish));
      await dialogClosed(tester);
      await waitFor(tester, snackText(de.rewardsWishSent));
      expect(state.engine!.pointBalance(f.kid.id), 20, reason: 'not yet');
      await synced(tester, state);
      await finish(tester, state);
      state = await start(tester);
      await openChores(tester);
      await waitFor(tester, find.text(de.choresWaitingConfirmation));
      final wish = de.choresNameWishesTitle(f.kid.displayName, '🍦 E2E Eis');
      await waitFor(tester, find.text(wish));
      final tile = find
          .ancestor(of: find.text(wish), matching: find.byType(SoftCard))
          .first;
      final lines = textsIn(tile);
      debugPrint('E2E-INFO the wish for the adults: $lines');
      expect(lines.any((l) => l.endsWith('Kontostand ⭐ 20')), isTrue);
      await tap(
        tester,
        find.descendant(of: tile, matching: find.byTooltip(de.commonConfirm)),
      );
      await until(
        tester,
        () => state.engine!.pointBalance(f.kid.id) == 10,
        'the balance goes down once confirmed',
      );
      await finish(tester, state);
    },
  );

  // The adults read "10 Punkte · Kontostand ⭐ 20" for a wish of 10 points,
  // not the negative points of the redemption (#545).
  testWidgets(
    'ALL-088 the wish shows what it costs: "10 Punkte · Kontostand ⭐ n"',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      final reward = await addReward('E2E Wunschpreis', 10, emoji: '🍦');
      await addPoints(f.kid, 20);
      final kid = await sessionOf(f.kid);
      final id = uid('wish');
      // As the child's app writes it (engine.redeem).
      await seed(kid, Collections.pointEntries, {
        id: PointEntry(
          id: id,
          memberId: f.kid.id,
          points: -10,
          title: '🍦 E2E Wunschpreis',
          kind: PointKind.reward,
          at: DateTime.now(),
          refId: reward,
          status: PointStatus.pending,
        ).toData(),
      });
      final state = await start(tester);
      await openChores(tester);
      final wish = de.choresNameWishesTitle(
        f.kid.displayName,
        '🍦 E2E Wunschpreis',
      );
      await waitFor(tester, find.text(wish));
      final lines = textsIn(
        find
            .ancestor(of: find.text(wish), matching: find.byType(SoftCard))
            .first,
      );
      debugPrint('E2E-INFO the wish tile: $lines');
      expect(lines, contains(de.choresPointsPointsBalanceBalance(10, 20)));
      await finish(tester, state);
    },
  );

  // Hint of ALL-089 (#377): open wishes keep the points they ask for. With
  // 20 points one wish of 20 goes out; the next ones the app does not send
  // (it says what is set aside) and the server turns down. Confirmed, the
  // balance is 0, not below.
  testWidgets('ALL-089 more wishes than the balance covers', (tester) async {
    await resetChores();
    final f = await theFamily();
    final reward = await addReward('E2E Teuer', 20, emoji: '🎮');
    await addPoints(f.kid, 20);
    final state = await start(tester, user: f.kid.username);
    await openChores(tester);
    await tab(tester, de.choresTabRewards);
    await waitFor(tester, find.text('E2E Teuer'));
    var sent = 0;
    for (var i = 0; i < 3; i++) {
      await snackGone(tester);
      await tap(
        tester,
        find.descendant(
          of: cardOf('E2E Teuer'),
          matching: find.text(de.rewardsRedeem),
        ),
      );
      await tester.pump(const Duration(milliseconds: 800));
      if (find.text(de.rewardsWish).evaluate().isNotEmpty) {
        await tap(tester, find.text(de.rewardsWish));
        await dialogClosed(tester);
        if (snackText(de.rewardsWishSent).evaluate().isNotEmpty) sent++;
      } else {
        expect(
          snackText(de.rewardsNeedPointsWishesOpen(20, 20)),
          findsOneWidget,
          reason: 'attempt ${i + 1} says what is set aside',
        );
      }
    }
    expect(sent, 1);
    await waitFor(tester, find.text(de.rewardsPointsReserved(20)));
    await synced(tester, state);
    // Another device of the child: the server turns it down.
    final kid = await sessionOf(f.kid);
    final extra = uid('wish');
    final answer = await put(kid, Collections.pointEntries, {
      extra: PointEntry(
        id: extra,
        memberId: f.kid.id,
        points: -20,
        title: '🎮 E2E Teuer',
        kind: PointKind.reward,
        at: DateTime.now(),
        refId: reward,
        status: PointStatus.pending,
      ).toData(),
    });
    expect(answer.rejected.where((r) => r.id == extra), isNotEmpty);
    expect(answer.refused.where((i) => i.id == extra).map((i) => i.code), [
      'not_allowed',
    ]);
    final wishes = [
      for (final e in state.engine!.pendingPoints)
        if (e.memberId == f.kid.id) e,
    ];
    expect(wishes, hasLength(1));
    for (final w in wishes) {
      await seed(f.admin, Collections.pointEntries, {
        w.id: w.decide(PointStatus.approved, f.adminMember.id).toData(),
      });
    }
    await arrives(
      tester,
      state,
      (e) => e.pendingPoints.isEmpty,
      'all wishes confirmed',
    );
    final balance = state.engine!.pointBalance(f.kid.id);
    debugPrint(
      'E2E-INFO wishes sent $sent, open ${wishes.length}, '
      'balance after confirming all: $balance',
    );
    expect(balance, 0);
    await finish(tester, state);
  });

  testWidgets('ALL-090 adults redeem for a child', (tester) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    await addReward('E2E Ausflug', 15, emoji: '🚲');
    await addPoints(fips, 20);
    final state = await start(tester);
    await openChores(tester);
    await tab(tester, de.choresTabRewards);
    await waitFor(tester, find.text('E2E Ausflug'));
    final redeem = find.descendant(
      of: cardOf('E2E Ausflug'),
      matching: find.text(de.rewardsRedeem),
    );
    Future<void> forWhom(FamilyMember m) async {
      await snackGone(tester);
      await tap(tester, redeem);
      await waitFor(tester, find.text(de.rewardsWhoRedeems));
      await tap(
        tester,
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(m.displayName),
        ),
      );
      await dialogClosed(tester);
    }

    await forWhom(f.kid);
    await waitFor(
      tester,
      snackText(de.rewardsNameOnlyHasBalance(f.kid.displayName, 0)),
    );
    expect(state.engine!.pointsOf(f.kid.id), isEmpty, reason: 'nothing');
    await forWhom(fips);
    await waitFor(tester, snackText(de.rewardsTitleRedeemed('E2E Ausflug')));
    expect(state.engine!.pointBalance(fips.id), 5, reason: 'at once');
    final entry = state.engine!
        .pointsOf(fips.id)
        .firstWhere((e) => e.kind == PointKind.reward);
    expect(entry.status, PointStatus.approved);
    await tab(tester, de.settingsAccount);
    await waitFor(tester, find.text(fips.displayName));
    expect(textsIn(cardOf(fips.displayName)), contains('⭐ 5'));
    await finish(tester, state);
  });

  testWidgets('ALL-091 ALL-092 bonus points up and down; deleting an entry', (
    tester,
  ) async {
    await resetChores();
    final f = await theFamily();
    final state = await start(tester);
    await openChores(tester);
    await openAccount(tester, f.kid.displayName);
    await tap(tester, find.text(de.choresBonusPoints));
    await waitFor(tester, find.text(de.choresGiveTakePoints));
    expect(stepper(tester).min, -100);
    expect(stepper(tester).max, 100);
    expect(inDialog(find.text('5 ⭐')), findsOneWidget);
    await enter(tester, inDialog(field(de.choresWhat)), 'E2E Streit');
    await leaveField(tester);
    await press(tester, inDialog(stepperButton(de.mealsFewer)), 8);
    expect(inDialog(find.text('-3 ⭐')), findsOneWidget);
    await tap(tester, find.text(de.choresBook).last);
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Streit'));
    expect(trailingOf(tester, 'E2E Streit').data, '-3');
    expect(find.text('⭐ -3'), findsOneWidget);
    expect(state.engine!.pointBalance(f.kid.id), -3);
    // Zero books nothing.
    final count = state.engine!.pointsOf(f.kid.id).length;
    await tap(tester, find.text(de.choresBonusPoints));
    await waitFor(tester, find.text(de.choresGiveTakePoints));
    await press(tester, inDialog(stepperButton(de.mealsFewer)), 5);
    expect(inDialog(find.text('0 ⭐')), findsOneWidget);
    await tap(tester, find.text(de.choresBook).last);
    await dialogClosed(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(state.engine!.pointsOf(f.kid.id).length, count);
    // ALL-092
    expect(find.text(de.choresLongPressDeletesEntry), findsOneWidget);
    await tester.longPress(accountRow('E2E Streit'));
    await tester.pump(const Duration(milliseconds: 500));
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Streit')));
    expect(find.text('E2E Streit'), findsNothing);
    expect(state.engine!.pointBalance(f.kid.id), 0);
    await undo(tester);
    await waitFor(tester, find.text('E2E Streit'));
    expect(state.engine!.pointBalance(f.kid.id), -3);
    await finish(tester, state);
  });

  // =========================================================================
  // Ämter – Taschengeld & Sparziele
  // =========================================================================

  testWidgets(
    'ALL-093 ALL-095 ALL-096 pocket money: weekly, bookings, points to money',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      final fips = await secondKid();
      await addPoints(f.kid, 20);
      await addAllowance(fips, weekly: 0, perPoint: 10);
      final state = await start(tester);
      await openChores(tester);
      await openAccount(tester, f.kid.displayName);
      expect(
        find.text(de.choresRedeemPoints),
        findsNothing,
        reason: 'no value of a point yet',
      );
      // ALL-093
      await tap(tester, find.text(de.choresSetPocketMoney));
      await waitFor(tester, inDialog(field(de.choresPerWeek)));
      await enter(tester, inDialog(field(de.choresPerWeek)), '5');
      await tap(
        tester,
        inDialog(find.widgetWithText(ChoiceChip, weekdaysShort()[5])),
      );
      await enter(tester, inDialog(field(de.choresValueOnePoint)), '0,10');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      final weekly = de.choresAmountPerWeekDay(formatEuro(500), weekdayLong(6));
      await waitFor(tester, find.text(weekly));
      final a = state.engine!.allowance(f.kid.id)!;
      expect(a.weeklyCents, 500);
      expect(a.payday, DateTime.saturday);
      expect(a.centsPerPoint, 10);
      // ALL-096
      await tap(tester, find.text(de.choresRedeemPoints));
      await waitFor(tester, inDialog(find.text('20 ⭐')));
      await press(tester, inDialog(stepperButton(de.mealsFewer)), 10);
      expect(inDialog(find.text('10 ⭐')), findsOneWidget);
      expect(inDialog(find.text('= ${formatEuro(100)}')), findsOneWidget);
      await tap(tester, find.text(de.choresRedeem).last);
      await dialogClosed(tester);
      await waitFor(tester, find.text(de.extrasExchangedPocketMoney));
      expect(trailingOf(tester, de.extrasExchangedPocketMoney).data, '-10');
      expect(
        trailingOf(tester, de.extrasPointsPoints(10)).data,
        '+${formatEuro(100)}',
      );
      expect(
        find.descendant(
          of: accountRow(de.extrasPointsPoints(10)),
          matching: find.textContaining(MoneyKind.points.label),
        ),
        findsOneWidget,
      );
      expect(state.engine!.pointBalance(f.kid.id), 10);
      expect(state.engine!.moneyBalance(f.kid.id), 100);
      // ALL-095
      Future<void> book(String? kind, String amount, String note) async {
        await tap(tester, find.text(de.conflictsBooking));
        await waitFor(tester, inDialog(field(de.commonAmount)));
        if (kind == null) {
          expect(
            tester
                .widget<ChoiceChip>(
                  inDialog(
                    find.widgetWithText(ChoiceChip, MoneyKind.spent.label),
                  ),
                )
                .selected,
            isTrue,
            reason: '"Ausgegeben" first',
          );
        } else {
          await tap(tester, inDialog(find.widgetWithText(ChoiceChip, kind)));
        }
        if (amount.isNotEmpty) {
          await enter(tester, inDialog(field(de.commonAmount)), amount);
        }
        if (note.isNotEmpty) {
          await enter(tester, inDialog(field(de.commonNote)), note);
        }
        await leaveField(tester);
        await tap(tester, find.text(de.choresBook).last);
        await dialogClosed(tester);
      }

      await book(null, '3,50', 'Comic');
      await waitFor(tester, find.text('Comic'));
      expect(trailingOf(tester, 'Comic').data, '−${formatEuro(350)}');
      await book(MoneyKind.gift.label, '10', '');
      await waitFor(tester, find.text(MoneyKind.gift.label));
      expect(
        trailingOf(tester, MoneyKind.gift.label).data,
        '+${formatEuro(1000)}',
      );
      final count = state.engine!.moneyOf(f.kid.id).length;
      await book(null, '', '');
      await tester.pump(const Duration(seconds: 1));
      expect(state.engine!.moneyOf(f.kid.id).length, count, reason: 'empty');
      expect(state.engine!.moneyBalance(f.kid.id), 100 - 350 + 1000);
      expect(find.text(formatEuro(750)), findsOneWidget);
      // ALL-093: empty means no pocket money.
      await tap(tester, find.text(de.choresSetPocketMoney));
      await waitFor(tester, inDialog(field(de.choresPerWeek)));
      await enter(tester, inDialog(field(de.choresPerWeek)), '');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await waitFor(tester, find.text(de.choresNoPocketMoneySet));
      expect(state.engine!.allowance(f.kid.id)!.weeklyCents, 0);
      // ALL-096: a value but no points: no button.
      await back(tester);
      await tap(tester, find.text(fips.displayName).last);
      await waitFor(tester, find.text(de.choresPocketMoney));
      expect(state.engine!.allowance(fips.id)!.centsPerPoint, 10);
      expect(
        find.text(de.choresRedeemPoints),
        findsNothing,
        reason: 'no points',
      );
      await finish(tester, state);
    },
  );

  testWidgets(
    "ALL-097 ALL-098 ALL-099 a child's own account and savings goals",
    (tester) async {
      await resetChores();
      final f = await theFamily();
      final fips = await secondKid();
      final allowance = await addAllowance(f.kid);
      await addMoney(f.kid, 1000);
      await addPoints(f.kid, 5, title: 'E2E Kinderpunkte');
      await addPoints(fips, 3);
      final book = uid('goal');
      await seed(f.admin, Collections.savingsGoals, {
        book: SavingsGoal(
          id: book,
          memberId: f.kid.id,
          title: 'E2E Buch',
          targetCents: 800,
          emoji: '📚',
        ).toData(),
      });
      final state = await start(tester, user: f.kid.username);
      await openChores(tester);
      await tab(tester, de.settingsAccount);
      await waitFor(tester, find.text(f.kid.displayName));
      expect(find.text(fips.displayName), findsNothing);
      await tap(tester, find.text(f.kid.displayName).last);
      await waitFor(tester, find.text(de.choresPocketMoney));
      for (final chip in [
        de.choresBonusPoints,
        de.conflictsBooking,
        de.choresSetPocketMoney,
        de.choresRedeemPoints,
      ]) {
        expect(find.text(chip), findsNothing, reason: chip);
      }
      expect(find.text(de.choresLongPressDeletesEntry), findsNothing);
      await tester.longPress(accountRow('E2E Kinderpunkte'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('E2E Kinderpunkte'), findsOneWidget);
      // ALL-099: reached, buying is for the adults.
      await waitFor(tester, find.text('E2E Buch'));
      expect(
        find.descendant(
          of: cardOf('E2E Buch'),
          matching: find.text(de.savingsGoalReached),
        ),
        findsOneWidget,
      );
      expect(find.text(de.savingsGoalBuy), findsNothing);
      // ALL-098
      Future<void> goal(String what, String amount) async {
        await tap(tester, find.text(de.savingsGoalAdd));
        await waitFor(tester, find.text(de.savingsGoalNew));
        await enter(tester, inDialog(field(de.savingsGoalWhat)), what);
        await enter(tester, inDialog(field(de.savingsGoalAmount)), amount);
        await leaveField(tester);
        await tap(tester, inDialog(find.text(de.commonSave)));
        await dialogClosed(tester);
        await waitFor(tester, find.text(what));
      }

      String when(int target) {
        final on =
            SavingsGoal(
              id: '',
              memberId: '',
              title: '',
              targetCents: target,
            ).reachedOn(
              balanceCents: 1000,
              allowance: allowance,
              today: DateTime.now(),
            )!;
        final weeks = ((target - 1000) / 500).ceil();
        final date = DateFormat.MMMd('de').format(on);
        return weeks <= 1
            ? de.savingsGoalNextPayday(date)
            : de.savingsGoalWhen(weeks, date);
      }

      await goal('E2E Fahrrad', '30');
      expect(
        find.descendant(
          of: cardOf('E2E Fahrrad'),
          matching: find.text(
            de.savingsGoalProgress(formatEuro(1000), formatEuro(3000)),
          ),
        ),
        findsOneWidget,
      );
      expect(when(3000), startsWith('noch etwa 4 Wochen'));
      expect(
        find.descendant(
          of: cardOf('E2E Fahrrad'),
          matching: find.text(when(3000)),
        ),
        findsOneWidget,
      );
      await goal('E2E Ball', '15');
      expect(when(1500), startsWith('mit dem nächsten Taschengeld'));
      expect(
        find.descendant(
          of: cardOf('E2E Ball'),
          matching: find.text(when(1500)),
        ),
        findsOneWidget,
      );
      await synced(tester, state);
      await eventually(
        tester,
        'the goals on the server',
        () async => (await titlesOf(
          f.admin,
          Collections.savingsGoals,
        )).containsAll(['E2E Fahrrad', 'E2E Ball']),
      );
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-099 ALL-098 bought from the pocket money; without it what is missing',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      final fips = await secondKid();
      await addMoney(f.kid, 3000);
      final bike = uid('goal');
      final scooter = uid('goal');
      await seed(f.admin, Collections.savingsGoals, {
        bike: SavingsGoal(
          id: bike,
          memberId: f.kid.id,
          title: 'E2E Fahrrad',
          targetCents: 3000,
        ).toData(),
        scooter: SavingsGoal(
          id: scooter,
          memberId: fips.id,
          title: 'E2E Roller',
          targetCents: 2000,
        ).toData(),
      });
      final state = await start(tester);
      await openChores(tester);
      await openAccount(tester, f.kid.displayName);
      await waitFor(tester, find.text('E2E Fahrrad'));
      expect(
        find.descendant(
          of: cardOf('E2E Fahrrad'),
          matching: find.text(de.savingsGoalReached),
        ),
        findsOneWidget,
      );
      await tap(
        tester,
        find.descendant(
          of: cardOf('E2E Fahrrad'),
          matching: find.text(de.savingsGoalBuy),
        ),
      );
      await waitFor(
        tester,
        find.text(de.savingsGoalBuyConfirm('🎯 E2E Fahrrad', formatEuro(3000))),
      );
      await tap(tester, inDialog(find.text(de.savingsGoalBuy)));
      await dialogClosed(tester);
      await waitFor(tester, find.text('🎯 E2E Fahrrad'));
      expect(trailingOf(tester, '🎯 E2E Fahrrad').data, '−${formatEuro(3000)}');
      expect(
        find.text('E2E Fahrrad'),
        findsNothing,
        reason: 'the goal is gone',
      );
      expect(state.engine!.moneyBalance(f.kid.id), 0);
      expect(state.engine!.savingsGoals(f.kid.id), isEmpty);
      // Without pocket money: what is missing.
      await back(tester);
      await tap(tester, find.text(fips.displayName).last);
      await waitFor(tester, find.text('E2E Roller'));
      expect(
        find.descendant(
          of: cardOf('E2E Roller'),
          matching: find.text(de.savingsGoalLeft(formatEuro(2000))),
        ),
        findsOneWidget,
      );
      await finish(tester, state);
    },
  );

  // =========================================================================
  // Ämter – Urlaub
  // =========================================================================

  testWidgets(
    'ALL-101 ALL-104 a holiday: chores and routines rest; deleted, they are back',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      await addChore('E2E Urlaubsamt', members: [f.kid.id]);
      await addRoutine('E2E Urlaubsroutine', member: f.kid.id);
      final state = await start(tester);
      await openChores(tester);
      await waitFor(tester, inPerson(f.kid.id, choreTile('E2E Urlaubsamt')));
      expect(
        inPerson(f.kid.id, routineTile('E2E Urlaubsroutine')),
        findsOneWidget,
      );
      await tap(tester, find.byTooltip(de.vacationTitle));
      await waitFor(tester, find.text(de.vacationNone));
      await tap(tester, find.text(de.vacationAdd));
      final to = inDays(3);
      await pickRange(tester, today(), to);
      await waitFor(tester, field(de.vacationName));
      await enter(tester, field(de.vacationName), 'E2E Herbstferien');
      await leaveField(tester);
      await tap(tester, find.text(de.commonSave).last);
      await dialogClosed(tester);
      await waitFor(tester, find.text('E2E Herbstferien'));
      final range = DateFormat.yMMMd('de');
      expect(
        find.text('${range.format(today())} – ${range.format(to)}'),
        findsOneWidget,
      );
      await back(tester);
      final banner = find.text(
        de.vacationBanner(DateFormat.MMMEd('de').format(to)),
      );
      await waitFor(tester, banner);
      expect(choreTile('E2E Urlaubsamt'), findsNothing);
      expect(routineTile('E2E Urlaubsroutine'), findsNothing);
      expect(inPerson(f.kid.id, find.text(de.kioskFreeToday)), findsOneWidget);
      // ALL-104: no undo here.
      await tap(tester, find.byTooltip(de.vacationTitle));
      await waitFor(tester, find.text('E2E Herbstferien'));
      await tap(tester, find.byTooltip(de.commonDelete));
      await waitFor(tester, find.text(de.vacationNone));
      expect(find.byType(SnackBar), findsNothing);
      await back(tester);
      await waitFor(tester, inPerson(f.kid.id, choreTile('E2E Urlaubsamt')));
      expect(banner, findsNothing);
      await finish(tester, state);
    },
  );

  testWidgets('ALL-103 holidays are for adults to enter', (tester) async {
    await resetChores();
    final f = await theFamily();
    final id = uid('vacation');
    await seed(f.admin, Collections.vacations, {
      id: Vacation(
        id: id,
        from: inDays(10),
        to: inDays(12),
        title: 'E2E Kinderurlaub',
      ).toData(),
    });
    final state = await start(tester, user: f.kid.username);
    await openChores(tester);
    await tap(tester, find.byTooltip(de.vacationTitle));
    await waitFor(tester, find.text('E2E Kinderurlaub'));
    expect(find.text(de.vacationOnlyAdults), findsOneWidget);
    expect(find.text(de.vacationAdd), findsNothing);
    expect(find.byTooltip(de.commonDelete), findsNothing);
    await tap(tester, find.text('E2E Kinderurlaub'));
    await tester.pump(const Duration(seconds: 1));
    expect(dialog(), findsNothing, reason: 'cannot be opened');
    final kid = await sessionOf(f.kid);
    final own = uid('vacation');
    expect(
      await refused(
        kid,
        Collections.vacations,
        own,
        Vacation(
          id: own,
          from: inDays(20),
          to: inDays(21),
          title: 'E2E Kind will Ferien',
        ).toData(),
      ),
      isTrue,
    );
    expect((await pull(f.admin, Collections.vacations))[own], isNull);
    await finish(tester, state);
  });

  // =========================================================================
  // Ämter – Abwesenheiten
  // =========================================================================

  testWidgets(
    'ALL-105 ALL-110 an absence with a substitute; deleted, the substitute loses it',
    (tester) async {
      await resetChores();
      await resetTasks();
      final f = await theFamily();
      final carl = await sessionOf(f.carl);
      final bea = await sessionOf(f.bea);
      await addTask(
        carl,
        'E2E Carls Sache',
        assignees: [f.carl.id],
        visibleTo: [f.carl.id],
      );
      await addAbsence(f.bea, inDays(-6), inDays(-3), title: 'E2E Vorbei');
      expect(await taskNamed(bea, 'E2E Carls Sache'), isNull);
      final state = await start(tester);
      await openChores(tester);
      await tap(tester, find.byTooltip(de.absenceTitle));
      await waitFor(tester, find.text(de.absenceNone));
      expect(find.text('E2E Vorbei'), findsNothing, reason: 'past');
      await tap(tester, find.text(de.absenceAdd));
      await pickRange(tester, today(), inDays(2));
      await waitFor(tester, find.text(de.absencePerson));
      await choose(tester, de.absencePerson, f.carl.displayName);
      final offered = await openMenu(tester, de.absenceSubstitute);
      expect(offered, isNot(contains(f.carl.displayName)));
      expect(offered, containsAll([de.commonNone, f.bea.displayName]));
      await tap(tester, find.text(f.bea.displayName).last);
      await tester.pump(const Duration(milliseconds: 600));
      await enter(tester, field(de.absenceReason), 'E2E Dienstreise');
      await leaveField(tester);
      await tap(tester, find.text(de.commonSave).last);
      await dialogClosed(tester);
      await waitFor(tester, find.text('E2E Dienstreise'));
      final tile = find
          .ancestor(
            of: find.text('E2E Dienstreise'),
            matching: find.byType(ListTile),
          )
          .first;
      expect(
        find.descendant(
          of: tile,
          matching: find.textContaining(
            de.absenceSubstituteName(f.bea.displayName),
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<MemberAvatar>(
              find.descendant(of: tile, matching: find.byType(MemberAvatar)),
            )
            .member
            .id,
        f.carl.id,
      );
      final a = state.engine!.absences.singleWhere(
        (a) => a.title == 'E2E Dienstreise',
      );
      expect(a.memberId, f.carl.id);
      expect(a.substituteId, f.bea.id);
      expect(a.from, today());
      expect(a.to, inDays(2));
      await synced(tester, state);
      await eventually(
        tester,
        "Bea gets Carl's private task",
        () async => await taskNamed(bea, 'E2E Carls Sache') != null,
      );
      // ALL-110
      await tap(
        tester,
        find.descendant(of: tile, matching: find.byTooltip(de.commonDelete)),
      );
      await waitFor(tester, find.text(de.absenceNone));
      expect(find.byType(SnackBar), findsNothing, reason: 'no undo here');
      await synced(tester, state);
      await eventually(
        tester,
        'Bea loses it again',
        () async => await taskNamed(bea, 'E2E Carls Sache') == null,
      );
      final kept = Task.fromRecord((await taskNamed(carl, 'E2E Carls Sache'))!);
      expect(kept.assigneeIds, [f.carl.id]);
      await finish(tester, state);
    },
  );

  testWidgets(
    'ALL-107 the substitute sees the task under "Meine", afterwards not',
    (tester) async {
      await resetChores();
      await resetTasks();
      final f = await theFamily();
      final carl = await sessionOf(f.carl);
      final bea = await sessionOf(f.bea);
      await addTask(
        carl,
        'E2E Carls Vertretung',
        assignees: [f.carl.id],
        visibleTo: [f.carl.id],
      );
      final absence = await addAbsence(
        f.carl,
        today(),
        inDays(2),
        substitute: f.bea,
      );
      await eventually(
        tester,
        'Bea may see it',
        () async => await taskNamed(bea, 'E2E Carls Vertretung') != null,
      );
      final state = await start(tester, user: f.bea.username);
      await openTasks(tester);
      await tab(tester, de.tasksFilterMine);
      await waitFor(tester, find.text('E2E Carls Vertretung'));
      expect(taskOf(state, 'E2E Carls Vertretung').assigneeIds, [f.carl.id]);
      // The absence is over (ended yesterday).
      await addAbsence(
        f.carl,
        inDays(-3),
        inDays(-1),
        substitute: f.bea,
        id: absence,
      );
      await eventually(
        tester,
        'not for Bea any more',
        () async => await taskNamed(bea, 'E2E Carls Vertretung') == null,
      );
      await arrives(
        tester,
        state,
        (e) => !e.tasks.any((t) => t.title == 'E2E Carls Vertretung'),
        "gone from Bea's device",
      );
      await waitGone(tester, find.text('E2E Carls Vertretung'));
      final kept = Task.fromRecord(
        (await taskNamed(carl, 'E2E Carls Vertretung'))!,
      );
      expect(kept.assigneeIds, [f.carl.id], reason: 'still assigned to Carl');
      expect(kept.visibleTo, [f.carl.id]);
      await finish(tester, state);
    },
  );

  testWidgets('ALL-108 chores and routines of an absent child', (tester) async {
    await resetChores();
    final f = await theFamily();
    final fips = await secondKid();
    await addChore('E2E Abw Kind', members: [f.kid.id]);
    await addChore('E2E Abw Fips', members: [fips.id], points: 2);
    await addRoutine('E2E Abw Routine Kind', member: f.kid.id);
    await addRoutine('E2E Abw Routine Fips', member: fips.id);
    await addAbsence(f.kid, today(), inDays(1));
    await addAbsence(fips, today(), inDays(1), substitute: f.bea);
    final state = await start(tester);
    await openChores(tester);
    await waitFor(tester, personBlock(f.kid.id));
    expect(inPerson(f.kid.id, find.text(de.absenceAway)), findsOneWidget);
    expect(inPerson(f.kid.id, choreTile('E2E Abw Kind')), findsNothing);
    expect(
      inPerson(f.kid.id, routineTile('E2E Abw Routine Kind')),
      findsNothing,
    );
    expect(inPerson(f.kid.id, find.text(de.kioskFreeToday)), findsOneWidget);
    expect(
      inPerson(fips.id, find.text(de.absenceRepresentedBy(f.bea.displayName))),
      findsOneWidget,
    );
    expect(
      inPerson(fips.id, routineTile('E2E Abw Routine Fips')),
      findsNothing,
    );
    await waitFor(tester, inPerson(fips.id, choreTile('E2E Abw Fips')));
    await tap(tester, choreCheck('E2E Abw Fips'));
    await until(
      tester,
      () => choreStatus('E2E Abw Fips').endsWith(de.choresDone('')),
      'done',
    );
    final chore = state.engine!.chores.firstWhere(
      (c) => c.title == 'E2E Abw Fips',
    );
    expect(
      state.engine!.choreCompletion(chore, today())!.memberId,
      f.bea.id,
      reason: 'ticked off for the substitute',
    );
    await finish(tester, state);
  });

  // The tile "Ämter" on the start page says the absent child is away instead
  // of listing its chore as open, as "Heute" does (#545; the wall display
  // likewise).
  testWidgets(
    'ALL-108 hint: the start page leaves out chores of an absent child',
    (tester) async {
      await resetChores();
      final f = await theFamily();
      await addChore('E2E Abwesend Start', members: [f.kid.id]);
      await addAbsence(f.kid, today(), inDays(1));
      final state = await start(tester);
      await openSection(tester, 'Start');
      final busy = find.text('${f.kid.displayName}: 🧹 E2E Abwesend Start');
      final free = find.text('${f.kid.displayName}: ${de.absenceAway}');
      await until(
        tester,
        () => busy.evaluate().isNotEmpty || free.evaluate().isNotEmpty,
        'the chores tile',
      );
      debugPrint(
        'E2E-INFO start page with the child away: '
        '${busy.evaluate().isNotEmpty ? 'chore listed' : 'all done'}',
      );
      expect(busy, findsNothing, reason: 'the child is away');
      expect(free, findsOneWidget);
      await finish(tester, state);
    },
  );

  testWidgets('ALL-109 absences are for adults to manage', (tester) async {
    await resetChores();
    final f = await theFamily();
    await addAbsence(f.carl, today(), inDays(2), title: 'E2E Carl weg');
    var state = await start(tester, user: f.kid.username);
    await openChores(tester);
    await tap(tester, find.byTooltip(de.absenceTitle));
    await waitFor(tester, find.text('E2E Carl weg'));
    expect(find.text(de.absenceOnlyAdults), findsOneWidget);
    expect(find.text(de.absenceAdd), findsNothing);
    expect(find.byTooltip(de.commonDelete), findsNothing);
    await tap(tester, find.text('E2E Carl weg'));
    await tester.pump(const Duration(seconds: 1));
    expect(dialog(), findsNothing, reason: 'cannot be opened');
    final kid = await sessionOf(f.kid);
    final own = uid('absence');
    expect(
      await refused(
        kid,
        Collections.absences,
        own,
        MemberAbsence(
          id: own,
          memberId: f.kid.id,
          from: inDays(5),
          to: inDays(6),
        ).toData(),
      ),
      isTrue,
    );
    await finish(tester, state);
    state = await start(tester, user: f.guest.username);
    await openChores(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip(de.absenceTitle), findsNothing);
    expect(find.byTooltip(de.vacationTitle), findsOneWidget);
    await finish(tester, state);
  });
}
