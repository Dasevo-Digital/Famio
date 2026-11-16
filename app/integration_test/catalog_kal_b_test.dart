// Catalog KAL-065 … KAL-168: attachments, comments and packing lists of an
// appointment, appointments recognised in text, pictures and PDFs, calendar
// files (.ics), calendar apps with an app password (CalDAV), calendar links,
// subscriptions, the calendars of members, birthdays and public holidays,
// free times, the week plan, the timetable, the bins and the calendar API of
// Home Assistant – against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_kal_b_test.dart
//
// The file picker and the save panel, the clipboard and "open with" are
// replaced at their plugin boundary; the text recognition is the Mac's own.
// Calendar apps, calendar links and Home Assistant are plain HTTP requests.
// The server fetches no subscription from a private address and nothing goes
// out to the internet: what a subscription brings is written as appointments
// carrying its id (as the server's importer would), which the app shows
// read-only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/holidays.dart';
import 'package:famio/src/data/ocr.dart';
import 'package:famio/src/data/waste.dart';
import 'package:famio/src/data/week_plan.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/format.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/ics_import_screen.dart';
import 'package:famio/src/screens/kids_screens.dart';
import 'package:famio/src/widgets/event_comments.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio/src/widgets/member_avatar.dart';
import 'package:famio/src/widgets/photo_viewer.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';

/// The same server over HTTPS with its own certificate.
const tlsUrl = String.fromEnvironment('FAMIO_NEW_URL');

const mb = 1024 * 1024;

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

final _members = <String, Future<FamilyMember>>{};

/// A member of this file only (password [kitMemberPassword]), created once.
Future<FamilyMember> member(
  String username,
  String name, {
  MemberRole role = MemberRole.adult,
}) => _members[username] ??= () async {
  final f = await theFamily();
  for (final u in await f.admin.adminUsers()) {
    if (u.member.username == username) return u.member;
  }
  return f.admin.createMember(
    username: username,
    displayName: name,
    password: kitMemberPassword,
    role: role,
  );
}();

/// A new API session (another device) of [username].
Future<FamioApiClient> loginAs(String username, String password) async {
  final api = FamioApiClient(kitUrl);
  await api.login(username: username, password: password, device: 'e2e-api');
  return api;
}

/// Everything the server gives [api]'s member, by collection.
Future<Map<String, Map<String, SyncRecord>>> pullAll(FamioApiClient api) async {
  final out = <String, Map<String, SyncRecord>>{};
  var since = 0;
  while (true) {
    final r = await api.sync(SyncRequest(since: since));
    for (final c in r.changes) {
      final records = out[c.collection] ??= {};
      if (c.deleted) {
        records.remove(c.id);
      } else {
        records[c.id] = c;
      }
    }
    if (!r.hasMore || r.rev <= since) return out;
    since = r.rev;
  }
}

/// Removes what the tests of this file wrote (the server is this file's
/// own): appointments, comments, subscriptions, packing lists, meals,
/// chores, children, contacts, timetables and the bin settings.
Future<void> wipe() async {
  final f = await theFamily();
  final all = await pullAll(f.admin);
  final packing = {
    for (final r in (all[Collections.shoppingLists] ?? const {}).values)
      if (r.data['packing'] == true) r.id,
  };
  for (final c in [
    Collections.events,
    Collections.eventComments,
    Collections.calendarSubscriptions,
    Collections.mealPlan,
    Collections.chores,
    Collections.children,
    Collections.contacts,
    Collections.timetables,
    Collections.wasteSettings,
  ]) {
    final ids = (all[c] ?? const {}).keys.toList();
    if (ids.isNotEmpty) await remove(f.admin, c, ids);
  }
  final items = [
    for (final r in (all[Collections.shoppingItems] ?? const {}).values)
      if (packing.contains(r.data['listId'])) r.id,
  ];
  if (items.isNotEmpty) await remove(f.admin, Collections.shoppingItems, items);
  if (packing.isNotEmpty) {
    await remove(f.admin, Collections.shoppingLists, packing);
  }
}

/// The family, the service account and nothing of earlier tests.
/// [tall]: a window as high as a big screen, so that lists show everything
/// at once (they only build what is on screen).
Future<KitFamily> setUpFamily(WidgetTester tester, {bool tall = true}) async {
  if (tall) {
    tester.view.physicalSize =
        const Size(800, 1600) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
  }
  await initializeDateFormatting('de');
  final f = await theFamily();
  await theService();
  await wipe();
  addTearDown(wipe);
  return f;
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
  bool confidential = false,
  String location = '',
  String notes = '',
  String? bringer,
  bool countdown = false,
  List<FileRef> files = const [],
  String? sourceId,
  List<String>? visibleTo,
}) async {
  final id = uid('event');
  final r = await put(api, Collections.events, {
    id: {
      ...CalendarEvent(
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
        confidential: confidential,
        bringerId: bringer,
        countdown: countdown,
        files: files,
        sourceId: sourceId,
      ).toData(),
      SyncRecord.visibilityKey: ?visibleTo,
    },
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

/// A subscription of [owner] (null: the family's, as the admin's school
/// holidays) whose address the server does not fetch (a private one).
Future<String> addSubscription(
  FamioApiClient api,
  String name, {
  String? owner,
  CalendarSharing sharing = const CalendarSharing.family(),
  String url = 'https://127.0.0.1:9/e2e.ics',
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

DateTime at(DateTime day, int hour, [int minute = 0]) =>
    DateTime(day.year, day.month, day.day, hour, minute);

String dayHeading(DateTime d) => DateFormat.MMMMEEEEd('de').format(d);
String clock(DateTime t) => DateFormat.jm('de').format(t);
String buttonDate(DateTime d) => DateFormat.yMMMEd('de').format(d);
String shortDate(DateTime d) => DateFormat.yMMMEd('de').format(d);
String dmy(DateTime d) => DateFormat('dd.MM.yyyy').format(d);

/// Notifications of [api]'s member: where they stand now …
Future<int> noticeMark(FamioApiClient api) async => (await api.notices()).last;

/// … and what came after.
Future<List<Notice>> noticesAfter(FamioApiClient api, int mark) async =>
    (await api.notices(after: mark)).notices;

// --- the calendar on screen --------------------------------------------------

bool _is(Widget w, String type) => w.runtimeType.toString() == type;

Finder byTypeName(String type) => find.byWidgetPredicate((w) => _is(w, type));

/// The month grid's cell of [day].
Finder dayCell(DateTime day) => find.byWidgetPredicate(
  (w) =>
      _is(w, '_DayCell') &&
      DateUtils.isSameDay((w as dynamic).day as DateTime, day),
);

final monthGrid = byTypeName('_MonthGrid');
final agendaTiles = byTypeName('_OccurrenceTile');

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

bool tileHasIcon(String title, IconData icon) => find
    .descendant(of: tileOf(title), matching: find.byIcon(icon))
    .evaluate()
    .isNotEmpty;

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
  for (final c in tester.widgetList<Container>(
    find.descendant(of: tileOf(title), matching: find.byType(Container)),
  )) {
    final d = c.decoration;
    if (d is BoxDecoration && d.color != null) return d.color;
  }
  return null;
}

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

SwitchListTile switchOf(WidgetTester tester, String title) =>
    tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title));

Future<void> flip(WidgetTester tester, String title) async {
  await scrollTo(tester, find.widgetWithText(SwitchListTile, title));
  await tap(tester, find.widgetWithText(SwitchListTile, title));
}

FilterChip person(WidgetTester tester, String name) =>
    tester.widget<FilterChip>(find.widgetWithText(FilterChip, name));

final titleField = field(de.commonTitle);

/// The editor's page title ("Neuer Termin", "Termin bearbeiten"): there
/// while the editor is open, wherever its list is scrolled.
final editorOpen = find.byWidgetPredicate(
  (w) =>
      w is Text && (w.data == de.eventNewEvent || w.data == de.eventEditEvent),
);

ColorButton saveButton(WidgetTester tester) =>
    tester.widget<ColorButton>(find.widgetWithText(ColorButton, de.commonSave));

String controllerText(WidgetTester tester, Finder f) =>
    tester.widget<TextField>(f).controller!.text;

/// Saves the editor.
Future<void> save(WidgetTester tester) async {
  await leaveField(tester);
  await tap(tester, find.text(de.commonSave).last);
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

// --- comments ----------------------------------------------------------------

/// The row of the comment [text] (long press deletes an own one).
Finder commentOf(String text) => find
    .ancestor(of: find.text(text), matching: find.byType(GestureDetector))
    .first;

Future<void> comment(WidgetTester tester, String text) async {
  final input = find.descendant(
    of: find.byType(EventComments),
    matching: find.byType(TextField),
  );
  await scrollTo(tester, input);
  await enter(tester, input, text);
  await tap(tester, find.byTooltip(de.commonSend));
  await waitFor(tester, find.text(text));
}

// --- recognising appointments ------------------------------------------------

Future<void> openImport(WidgetTester tester) async {
  await openCalendar(tester);
  await tap(tester, find.byTooltip(de.calendarRecognizeEventsPhotoText));
  await waitFor(tester, field(de.importPasteTextHere));
  await dismissTip(tester);
}

Future<void> searchText(WidgetTester tester, String text) async {
  await enter(tester, field(de.importPasteTextHere), text);
  await leaveField(tester);
  await tap(tester, find.text(de.importFindEvents));
}

/// The title fields of the suggestions, top to bottom.
List<String> suggestionTitles(WidgetTester tester) => [
  for (final t in tester.widgetList<TextField>(
    find.widgetWithText(TextField, de.commonTitle),
  ))
    t.controller!.text,
];

/// The card of the suggestion that shows [when].
Finder suggestion(String when) =>
    find.ancestor(of: find.text(when), matching: find.byType(SoftCard)).first;

bool tickOf(WidgetTester tester, Finder card) => tester
    .widget<Checkbox>(
      find.descendant(of: card, matching: find.byType(Checkbox)),
    )
    .value!;

final sourceCard = find
    .ancestor(
      of: find.text(de.importKeepOriginal),
      matching: find.byType(SoftCard),
    )
    .first;

Finder pageBack() => find.widgetWithText(TextButton, de.commonBack);

// --- stand-ins for the system --------------------------------------------------

/// A file on disk as the file picker hands it over.
base class DiskFile extends PlatformFile {
  DiskFile(this.file);

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

/// Stands in for the native open and save panels: returns the files queued
/// in [picks] and keeps what would have been saved.
class FakePicker extends FilePickerPlatform {
  final picks = <List<PlatformFile>>[];
  final saved = <({String fileName, Uint8List bytes, String mimeType})>[];

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
  }) async => picks.isEmpty ? [] : picks.removeAt(0);

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saved.add((fileName: fileName, bytes: bytes, mimeType: mimeType));
    return Uri.file('/saved/$fileName');
  }
}

FakePicker fakePicker() {
  final before = FilePickerPlatform.instance;
  final fake = FakePicker();
  FilePickerPlatform.instance = fake;
  addTearDown(() => FilePickerPlatform.instance = before);
  return fake;
}

/// Stands in for "open with the system's app".
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

/// The system clipboard while [body] runs: what the app copies lands in the
/// list it gets, what it pastes is [paste].
Future<T> withClipboard<T>(
  WidgetTester tester,
  Future<T> Function(List<String> copied) body, {
  String? paste,
}) async {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        copied.add('${(call.arguments as Map)['text']}');
        return null;
      case 'Clipboard.getData':
        return paste == null ? null : {'text': paste};
      case 'Clipboard.hasStrings':
        return {'value': paste != null};
    }
    return null;
  });
  try {
    return await body(copied);
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  }
}

Future<File> tempFile(String name, List<int> bytes) async {
  final dir = Directory(
    p.join((await getTemporaryDirectory()).path, 'famio-e2e-kal-b'),
  )..createSync(recursive: true);
  return File(p.join(dir.path, name))..writeAsBytesSync(bytes);
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

// --- pictures and documents --------------------------------------------------

Future<Uint8List> _png(ui.Image image) async => (await image.toByteData(
  format: ui.ImageByteFormat.png,
))!.buffer.asUint8List();

/// Random colours, [width] × [height]: a picture that hardly compresses.
Future<ui.Image> noiseImage(int width, int height) {
  final random = math.Random(42);
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    final v = random.nextInt(0x1000000);
    pixels[i] = v & 0xFF;
    pixels[i + 1] = (v >> 8) & 0xFF;
    pixels[i + 2] = (v >> 16) & 0xFF;
    pixels[i + 3] = 255;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

Future<Uint8List> noisePng(int width, int height) async =>
    _png(await noiseImage(width, height));

/// A picture without any text (a sky over a meadow).
Future<Uint8List> landscapePng() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(
      const Rect.fromLTWH(0, 0, 640, 300),
      Paint()..color = const Color(0xFF8EC9F5),
    )
    ..drawRect(
      const Rect.fromLTWH(0, 300, 640, 180),
      Paint()..color = const Color(0xFF5BA84A),
    )
    ..drawCircle(
      const Offset(520, 90),
      50,
      Paint()..color = const Color(0xFFFFD54F),
    );
  return _png(await recorder.endRecording().toImage(640, 480));
}

Future<Uint8List> colourPng(Color colour) async {
  final recorder = ui.PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = colour);
  return _png(await recorder.endRecording().toImage(64, 64));
}

/// A letter as a picture, for the real text recognition of this Mac; with
/// [noise] a part below the text makes it a few megabytes.
Future<File> letterFile(
  String name,
  List<String> lines, {
  bool noise = false,
}) async {
  const width = 1600;
  final height = noise ? 1500 : 800;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = Colors.white,
    );
  for (final (i, line) in lines.indexed) {
    (TextPainter(
      text: TextSpan(
        text: line,
        style: const TextStyle(color: Colors.black, fontSize: 56),
      ),
      textDirection: TextDirection.ltr,
    )..layout()).paint(canvas, Offset(80, 80.0 + i * 120));
  }
  if (noise) {
    canvas.drawImage(
      await noiseImage(width, 800),
      const Offset(0, 700),
      Paint(),
    );
  }
  final image = await recorder.endRecording().toImage(width, height);
  return tempFile(name, await _png(image));
}

/// A PDF with a text layer.
Future<Uint8List> textPdf(List<String> lines) =>
    (pw.Document()..addPage(
          pw.Page(
            build: (_) => pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (final l in lines)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 12),
                    child: pw.Text(l, style: const pw.TextStyle(fontSize: 22)),
                  ),
              ],
            ),
          ),
        ))
        .save();

/// A PDF of only a picture (a scan without text layer, and without text).
Future<Uint8List> picturePdf(Uint8List png) =>
    (pw.Document()..addPage(
          pw.Page(
            build: (_) => pw.Center(child: pw.Image(pw.MemoryImage(png))),
          ),
        ))
        .save();

final pdfBytes = utf8.encode(
  '%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
  '2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\n'
  'trailer << /Root 1 0 R >>\n%%EOF\n',
);

// --- calendar files ----------------------------------------------------------

String icsStamp(DateTime t) =>
    DateFormat("yyyyMMdd'T'HHmmss'Z'").format(t.toUtc());

String vcalendar(List<String> events) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Famio E2E//KAL//DE\r\n'
    '${events.join()}END:VCALENDAR\r\n';

String vevent(
  String uid,
  String summary,
  DateTime start,
  DateTime end, {
  String extra = '',
}) =>
    'BEGIN:VEVENT\r\nUID:$uid\r\nDTSTAMP:20261101T120000Z\r\n'
    'DTSTART:${icsStamp(start)}\r\nDTEND:${icsStamp(end)}\r\n'
    'SUMMARY:$summary\r\n${extra}END:VEVENT\r\n';

// --- calendar apps, links and Home Assistant over HTTP ----------------------

/// A request like a calendar app's, with [user] and an app [password].
Future<(int, String)> dav(
  String method,
  String path, {
  required String user,
  required String password,
  String? body,
  String type = 'application/xml; charset=utf-8',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse(kitUrl).resolve(path),
    );
    request.headers.set(
      'authorization',
      'Basic ${base64.encode(utf8.encode('$user:$password'))}',
    );
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.set('content-type', type);
      request.add(utf8.encode(body));
    }
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  } finally {
    client.close();
  }
}

const calendarQuery =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
    '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
    '<c:filter><c:comp-filter name="VCALENDAR">'
    '<c:comp-filter name="VEVENT"/></c:comp-filter></c:filter>'
    '</c:calendar-query>';

/// What a calendar app gets of [user]'s Famio calendar.
Future<(int, String)> davEvents(String user, String password) => dav(
  'REPORT',
  'dav/calendars/$user/famio/',
  user: user,
  password: password,
  body: calendarQuery,
  headers: {'depth': '1'},
);

Future<int> davStatus(String user, String password) async => (await dav(
  'PROPFIND',
  'dav/',
  user: user,
  password: password,
  headers: {'depth': '0'},
)).$1;

/// A plain GET (a calendar link, the API of Home Assistant).
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

// --- another way in ----------------------------------------------------------

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

/// Passes everything (also the WebSocket) through to the throwaway server;
/// after [holdUploads] it keeps uploads (POST /api/files) waiting until
/// [release], like a slow network.
class HoldingProxy {
  late final HttpServer _server;
  final _client = HttpClient()..autoUncompress = false;
  final _sockets = <WebSocket>[];
  Completer<void>? _gate;
  StreamController<void>? _held;

  String get url => 'http://127.0.0.1:${_server.port}';

  /// Holds uploads from now on; the stream tells of each one held.
  Stream<void> holdUploads() {
    _gate = Completer<void>();
    _held = StreamController<void>.broadcast();
    return _held!.stream;
  }

  void release() {
    _gate?.complete();
    _gate = null;
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = Uri.parse(kitUrl);
    _server.listen((request) async {
      try {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final upstream = await WebSocket.connect(
            target
                .replace(
                  scheme: target.scheme == 'https' ? 'wss' : 'ws',
                  path: request.uri.path,
                  query: request.uri.hasQuery ? request.uri.query : null,
                )
                .toString(),
            headers: {'authorization': ?request.headers.value('authorization')},
          );
          final down = await WebSocketTransformer.upgrade(request);
          _sockets.addAll([upstream, down]);
          upstream.listen(down.add, onDone: down.close, onError: (_) {});
          down.listen(upstream.add, onDone: upstream.close, onError: (_) {});
          return;
        }
        final gate = _gate;
        if (gate != null &&
            request.method == 'POST' &&
            request.uri.path == '/api/files') {
          _held?.add(null);
          await gate.future;
        }
        final out = await _client.openUrl(
          request.method,
          target.replace(
            path: request.uri.path,
            query: request.uri.hasQuery ? request.uri.query : null,
          ),
        );
        out.followRedirects = false;
        request.headers.forEach((name, values) {
          if (const {
            'host',
            'content-length',
            'transfer-encoding',
            'connection',
          }.contains(name)) {
            return;
          }
          for (final v in values) {
            out.headers.add(name, v);
          }
        });
        await out.addStream(request);
        final answer = await out.close();
        request.response.statusCode = answer.statusCode;
        answer.headers.forEach((name, values) {
          if (const {
            'content-length',
            'transfer-encoding',
            'connection',
          }.contains(name)) {
            return;
          }
          for (final v in values) {
            request.response.headers.add(name, v);
          }
        });
        await request.response.addStream(answer);
        await request.response.close();
      } catch (_) {
        try {
          request.response.statusCode = 502;
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  Future<void> stop() async {
    release();
    for (final s in _sockets) {
      await s.close().catchError((Object _) {});
    }
    await _server.close(force: true);
    _client.close(force: true);
  }
}

/// Like [startApp], but through [url] (e.g. a [Gate]).
Future<AppState> startVia(
  WidgetTester tester,
  String url,
  String user,
  String password,
) async {
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
  await enter(tester, field('Passwort'), password);
  await tap(tester, find.text('Anmelden'));
  await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
  if (find.text(de.commonLater).evaluate().isNotEmpty) {
    await tap(tester, find.text(de.commonLater).last);
  }
  return state;
}

/// Signs in over HTTPS, confirming the server's own certificate.
Future<AppState> startHttps(WidgetTester tester, String user) async {
  await initializeDateFormatting('de');
  await freshStart();
  final state = AppState();
  await state.init();
  addTearDown(() async {
    if (state.me != null) await state.signOut();
  });
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(FamioApp(state: state));
  await enter(tester, field(de.connectServerAddress), tlsUrl);
  await tap(tester, find.text(de.commonConnect));
  await waitFor(tester, find.text(de.trustMatches));
  await tap(tester, find.text(de.trustMatches));
  await enter(tester, field(de.commonUsername), user);
  await enter(tester, field(de.commonPassword), kitMemberPassword);
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

// --- pages -------------------------------------------------------------------

/// Kalender → "Mit Google/Apple Kalender verbinden".
Future<void> openConnect(WidgetTester tester) async {
  await openCalendar(tester);
  await tap(tester, find.byTooltip(de.calendarConnectGoogleAppleCalendar));
  await waitFor(tester, find.text(de.calendarConnectCalendarAppsDirectly));
  await dismissTip(tester);
}

/// The list tile titled [title].
Finder listTile(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ListTile)).first;

/// Server-Verwaltung → Benutzer → [name].
Future<void> openUser(WidgetTester tester, String name) async {
  await openAdmin(tester, 'Benutzer');
  await scrollTo(tester, find.text(name));
  await tap(tester, find.text(name).last);
  await waitFor(tester, find.text(de.adminRole));
}

/// Whether [finder] shows anywhere on the page, scrolling it from top to
/// bottom.
Future<bool> seenOnPage(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    await tester.dragFrom(const Offset(600, 400), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 150));
  }
  for (var i = 0; i < 30; i++) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.dragFrom(const Offset(600, 1000), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 250));
  }
  return finder.evaluate().isNotEmpty;
}

/// Taps [finder]; errors the app throws later from what the tap started
/// land in [errors] instead of ending the whole run.
Future<void> tapGuarded(
  WidgetTester tester,
  Finder finder,
  List<Object> errors,
) async {
  await waitFor(tester, finder);
  await tester.ensureVisible(finder.first);
  await tester.pump(const Duration(milliseconds: 300));
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      await tester.tap(finder.first, warnIfMissed: false);
      if (!done.isCompleted) done.complete();
    },
    (error, _) {
      errors.add(error);
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future;
  await tester.pump(const Duration(milliseconds: 500));
}

/// The time picker in its text mode: [hour]:[minute], confirmed.
Future<void> typeTime(
  WidgetTester tester,
  int hour,
  int minute, {
  bool close = true,
}) async {
  await waitFor(tester, find.byType(Dialog));
  await tap(tester, find.byTooltip('Zum Texteingabemodus wechseln'));
  final fields = inDialog(find.byType(TextField));
  await waitFor(tester, fields);
  await tester.enterText(fields.at(0), hour.toString().padLeft(2, '0'));
  await tester.pump();
  await tester.enterText(fields.at(1), minute.toString().padLeft(2, '0'));
  await tester.pump();
  await tap(tester, inDialog(find.text('OK')));
  // The end of a period follows in a dialog of its own.
  if (close) {
    await dialogClosed(tester);
  } else {
    await tester.pump(const Duration(milliseconds: 800));
  }
}

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // --- Anhänge, Kommentare, Packliste -------------------------------------------

  testWidgets('KAL-065 KAL-066 attach a file while it uploads, take one off', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final picker = fakePicker();
    final day = inDays(2);
    final id = await addEvent(f.admin, 'E2E Anhang', at(day, 15));
    // KAL-066: two attachments, from another device.
    final one = await f.admin.uploadFile(
      bytes: await colourPng(const Color(0xFFE53935)),
      name: 'e2e-eins.png',
      mime: 'image/png',
    );
    final two = await f.admin.uploadFile(
      bytes: pdfBytes,
      name: 'e2e-zwei.pdf',
      mime: 'application/pdf',
    );
    final both = await addEvent(
      f.admin,
      'E2E Zwei Anhänge',
      at(day, 17),
      files: [one, two],
    );
    // KAL-065: the upload waits at the proxy until released, as on a slow
    // network.
    final proxy = HoldingProxy();
    await proxy.start();
    addTearDown(proxy.stop);
    final photo = await tempFile('e2e-foto.png', await landscapePng());
    picker.picks.add([DiskFile(photo)]);

    final state = await startVia(tester, proxy.url, kitUser, kitPassword);
    final engine = state.engine!;
    await openCalendar(tester);
    await selectDay(tester, state, day);
    await openEvent(tester, 'E2E Anhang');
    await scrollTo(tester, find.byTooltip(de.tasksAddPhoto));
    expect(find.text(de.tasksPhotos), findsOneWidget);
    final held = proxy.holdUploads().first;
    await tap(tester, find.byTooltip(de.tasksAddPhoto));
    final spinner = find.descendant(
      of: find.byType(OutlinedButton),
      matching: find.byType(CircularProgressIndicator),
    );
    await waitFor(tester, spinner);
    await held.timeout(const Duration(seconds: 30));
    expect(saveButton(tester).onPressed, isNull, reason: 'locked meanwhile');
    // "Speichern" right away: nothing happens yet.
    await tester.tap(
      find.widgetWithText(ColorButton, de.commonSave),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(editorOpen, findsOneWidget);
    expect(find.byType(FileThumb), findsNothing);
    proxy.release();
    await waitFor(
      tester,
      find.byType(FileThumb),
      timeout: const Duration(seconds: 60),
    );
    await waitGone(tester, spinner);
    expect(saveButton(tester).onPressed, isNotNull);
    await save(tester);
    final file = engine.event(id)!.files.single;
    expect(file.name, 'e2e-foto.png');
    await engine.sync();

    // Opened again: the preview opens the picture.
    await openEvent(tester, 'E2E Anhang');
    await scrollTo(tester, find.byType(FileThumb));
    await tester.tap(find.byType(FileThumb).first);
    await waitFor(tester, find.byType(PhotoViewer));
    await tap(tester, find.byTooltip(de.commonClose).last);
    await waitGone(tester, find.byType(PhotoViewer));
    await closeEditor(tester);

    // The other devices of the family have it as well.
    final bea = await sessionOf(f.bea);
    final forBea = CalendarEvent.fromRecord((await eventOf(bea, id))!);
    expect(forBea.files.single.id, file.id);
    expect(
      listEquals(await bea.downloadFile(file.id), photo.readAsBytesSync()),
      isTrue,
    );

    // KAL-066: the first one off, the second stays.
    await openEvent(tester, 'E2E Zwei Anhänge');
    await scrollTo(tester, find.byType(FileThumb));
    expect(find.byType(FileThumb), findsNWidgets(2));
    await tap(tester, find.byTooltip(de.tasksRemovePhoto).first);
    expect(find.byType(FileThumb), findsOneWidget);
    await save(tester);
    await engine.sync();
    await eventually(tester, 'one attachment left on the server', () async {
      final e = CalendarEvent.fromRecord((await eventOf(f.admin, both))!);
      return e.files.length == 1 && e.files.single.id == two.id;
    });
    await finish(tester, state);
  });

  // A file over 8 MB from the system's file picker comes as a stream of
  // Uint8List (file_picker_darwin via cross_file); FileCache._digesting
  // widens it before hashing (#533), and any other failure of the upload
  // ends as a message.
  testWidgets('KAL-065 a photo over 8 MB from the file picker', (tester) async {
    await setUpFamily(tester);
    final picker = fakePicker();
    final day = inDays(2);
    final id = await addEvent(
      (await theFamily()).admin,
      'E2E Großes Foto',
      at(day, 15),
    );
    final photo = await tempFile('e2e-gross.png', await noisePng(1800, 1700));
    expect(photo.lengthSync(), greaterThan(8 * mb));
    picker.picks.add([DiskFile(photo)]);
    final state = await startApp(tester);
    final engine = state.engine!;
    await openCalendar(tester);
    await selectDay(tester, state, day);
    await openEvent(tester, 'E2E Großes Foto');
    await scrollTo(tester, find.byTooltip(de.tasksAddPhoto));
    final errors = <Object>[];
    await tapGuarded(tester, find.byTooltip(de.tasksAddPhoto), errors);
    await tester.pump(const Duration(seconds: 5));
    debugPrint('E2E-INFO attaching the big photo threw: $errors');
    expect(errors, isEmpty);
    await waitFor(
      tester,
      find.byType(FileThumb),
      timeout: const Duration(seconds: 90),
    );
    await save(tester);
    expect(engine.event(id)!.files.single.size, photo.lengthSync());
    await finish(tester, state);
  });

  testWidgets(
    'KAL-067 KAL-068 KAL-069 comments: written, deleted, told to the others',
    (tester) async {
      final f = await setUpFamily(tester);
      final bea = await sessionOf(f.bea);
      final guest = await sessionOf(f.guest);
      final day = inDays(2);
      final party = await addEvent(f.admin, 'E2E Grillfest', at(day, 16));
      await addEvent(
        f.admin,
        'E2E Ausflug',
        at(day, 9),
        members: [f.adminMember.id, f.bea.id],
      );
      await addEvent(
        f.admin,
        'E2E Geheimbesuch',
        at(day, 11),
        members: [f.adminMember.id, f.bea.id],
        confidential: true,
      );
      final state = await startApp(tester);
      await openCalendar(tester);
      await selectDay(tester, state, day);

      // KAL-067
      await openEvent(tester, 'E2E Grillfest');
      await scrollTo(tester, find.byType(EventComments));
      expect(find.text(de.commentsComments), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(EventComments),
          matching: find.text(de.commentsCommentEGI),
        ),
        findsOneWidget,
      );
      await comment(tester, 'Ich bringe Kuchen mit');
      await waitFor(tester, find.text(de.commentsCommentsCount(1)));
      final mine = commentOf('Ich bringe Kuchen mit');
      expect(
        find.descendant(of: mine, matching: find.byType(MemberAvatar)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: mine,
          matching: find.textContaining('$kitAdminName · '),
        ),
        findsOneWidget,
      );
      await eventually(tester, 'Bea has the comment', () async {
        final all = await pull(bea, Collections.eventComments);
        return all.values.any(
          (r) =>
              r.data['text'] == 'Ich bringe Kuchen mit' &&
              r.data['eventId'] == party &&
              r.data['authorId'] == f.adminMember.id,
        );
      });
      // The guest comments as well (from the guest's device).
      final fromGuest = uid('comment');
      final g = await put(guest, Collections.eventComments, {
        fromGuest: EventComment(
          id: fromGuest,
          eventId: party,
          authorId: f.guest.id,
          at: DateTime.now(),
          text: 'E2E Gast kommt auch',
        ).toData(),
      });
      expect(g.rejected, isEmpty, reason: 'a guest may comment');
      final fromBea = uid('comment');
      await put(bea, Collections.eventComments, {
        fromBea: EventComment(
          id: fromBea,
          eventId: party,
          authorId: f.bea.id,
          at: DateTime.now(),
          text: 'E2E Bea bringt Salat',
        ).toData(),
      });
      await waitFor(tester, find.text(de.commentsCommentsCount(3)));
      await waitFor(tester, find.text('E2E Gast kommt auch'));
      expect(
        find.descendant(
          of: commentOf('E2E Gast kommt auch'),
          matching: find.textContaining('${f.guest.displayName} · '),
        ),
        findsOneWidget,
      );

      // KAL-068: the own one goes and comes back …
      await snackGone(tester);
      await tester.longPress(commentOf('Ich bringe Kuchen mit'));
      await tester.pump(const Duration(milliseconds: 500));
      await waitFor(tester, find.text(de.commentsCommentDeleted));
      await waitGone(tester, find.text('Ich bringe Kuchen mit'));
      await tap(tester, find.text(de.commonUndo));
      await waitFor(tester, find.text('Ich bringe Kuchen mit'));
      await snackGone(tester);
      // … someone else's does nothing.
      await tester.longPress(commentOf('E2E Bea bringt Salat'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(de.commentsCommentDeleted), findsNothing);
      expect(find.text('E2E Bea bringt Salat'), findsOneWidget);
      await eventually(tester, 'the own one is back on the server', () async {
        final all = await pull(bea, Collections.eventComments);
        return all.values.any((r) => r.data['text'] == 'Ich bringe Kuchen mit');
      });
      // Nobody writes in someone else's name.
      final forged = uid('comment');
      final r = await put(f.admin, Collections.eventComments, {
        forged: EventComment(
          id: forged,
          eventId: party,
          authorId: f.bea.id,
          at: DateTime.now(),
          text: 'E2E Im Namen von Bea',
        ).toData(),
      });
      final stored = (await pull(bea, Collections.eventComments))[forged];
      debugPrint(
        'E2E-INFO comment in Bea\'s name: rejected=${r.rejected.map((x) => x.id).contains(forged)} '
        'stored=${stored?.data}',
      );
      expect(stored?.data['authorId'], isNot(f.bea.id));
      // Hinweis: an adult removes someone else's comment through the API.
      final removal = await remove(f.admin, Collections.eventComments, [
        fromBea,
      ]);
      final kept = (await pull(
        bea,
        Collections.eventComments,
      )).containsKey(fromBea);
      debugPrint(
        'E2E-INFO adult removes Bea\'s comment through the API: '
        'rejected=${removal.rejected.isNotEmpty} kept=$kept',
      );
      await closeEditor(tester);

      // KAL-069: Bea takes part and hears of it …
      var mark = await noticeMark(bea);
      await openEvent(tester, 'E2E Ausflug');
      await comment(tester, 'Ich bringe Kuchen');
      late Notice heard;
      await eventually(tester, 'Bea hears of the comment', () async {
        final n = (await noticesAfter(
          bea,
          mark,
        )).where((n) => n.title == 'Kommentar zu „E2E Ausflug“');
        if (n.isEmpty) return false;
        heard = n.first;
        return true;
      });
      expect(heard.body, '$kitAdminName: Ich bringe Kuchen');
      await closeEditor(tester);
      // … of a confidential one only that there is one, and from whom.
      mark = await noticeMark(bea);
      await openEvent(tester, 'E2E Geheimbesuch');
      await comment(tester, 'Ich bringe Kuchen');
      await eventually(tester, 'Bea hears of the second comment', () async {
        final n = (await noticesAfter(
          bea,
          mark,
        )).where((n) => n.title == 'Neuer Kommentar zu einem Termin');
        if (n.isEmpty) return false;
        heard = n.first;
        return true;
      });
      expect(heard.body, kitAdminName);
      for (final n in await noticesAfter(bea, mark)) {
        for (final t in [n.title, n.body, n.brief]) {
          expect(t, isNot(contains('Geheimbesuch')));
          expect(t, isNot(contains('Kuchen')));
        }
      }
      await closeEditor(tester);
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-072 KAL-073 a packing list from a template, its line in the appointment',
    (tester) async {
      final f = await setUpFamily(tester);
      final ha = await theService();
      final start = inDays(6);
      final trip = await addEvent(
        f.admin,
        'E2E Ostsee',
        start,
        end: inDays(9),
        allDay: true,
        members: [f.adminMember.id, f.kid.id],
      );
      // KAL-073: a trip with its list of five, two of them packed.
      final campDay = inDays(12);
      final camp = await addEvent(f.admin, 'E2E Zelten', campDay, allDay: true);
      final list = uid('list');
      await put(f.admin, Collections.shoppingLists, {
        list: ShoppingList(
          id: list,
          name: '🧳 E2E Zelten',
          packing: true,
          eventId: camp,
        ).toData(),
      });
      await put(f.admin, Collections.shoppingItems, {
        for (var i = 0; i < 5; i++)
          '$list-$i': ShoppingItem(
            id: '$list-$i',
            listId: list,
            name: 'E2E Sache $i',
            checked: i < 2,
          ).toData(),
      });
      // An appointment of a subscription.
      await addEvent(
        f.admin,
        'E2E Abotermin',
        at(campDay, 10),
        sourceId: 'e2e-feed',
      );

      final state = await startApp(tester);
      final engine = state.engine!;
      await openCalendar(tester);
      await selectDay(tester, state, start);
      await openEvent(tester, 'E2E Ostsee');
      await scrollTo(tester, find.text(de.templatesCreatePackingList));
      await tap(tester, find.text(de.templatesCreatePackingList));
      await waitFor(tester, find.text(de.templatesPackingListTemplate));
      await tap(tester, find.text('Urlaub').last);
      await waitFor(tester, find.text(de.templatesWhoPacking));
      final chips = {
        for (final c in tester.widgetList<FilterChip>(
          inDialog(find.byType(FilterChip)),
        ))
          (c.label as Text).data!: c.selected,
      };
      final users = [for (final u in await f.admin.adminUsers()) u.member];
      expect(chips.keys.toSet(), {
        for (final m in users)
          if (!m.isGuest && !m.isService) m.displayName,
      });
      expect(chips.containsKey(f.guest.displayName), isFalse);
      expect(chips.containsKey(ha.displayName), isFalse);
      expect(chips.keys, containsAll([kitAdminName, f.bea.displayName]));
      expect(
        {
          for (final e in chips.entries)
            if (e.value) e.key,
        },
        {kitAdminName, f.kid.displayName},
        reason: 'those taking part are chosen',
      );
      await tap(tester, inDialog(find.text(de.templatesCreate)));
      await waitFor(tester, find.text('🧳 E2E Ostsee'));
      final packing = engine.packingListOf(trip)!;
      expect(packing.name, '🧳 E2E Ostsee');
      final items = engine.shoppingItems(packing.id);
      Set<String?> owners(String name) => {
        for (final i in items)
          if (i.name == name) i.memberId,
      };
      int count(String name) => items.where((i) => i.name == name).length;
      expect(owners('Unterwäsche & Socken'), {f.adminMember.id, f.kid.id});
      expect(owners('Kuscheltier'), {f.kid.id}, reason: 'children\'s things');
      expect(count('Kuscheltier'), 1);
      expect(owners('Ausweise & Reisepässe'), {null});
      expect(count('Ausweise & Reisepässe'), 1);
      expect(owners('Ladegeräte'), {null});
      expect(count('Ladegeräte'), 1);
      await back(tester);
      await scrollTo(
        tester,
        find.text(de.templatesPackedTotalPacked(0, items.length)),
      );
      expect(find.text(de.templatesCreatePackingList), findsNothing);
      await closeEditor(tester);

      // KAL-073
      await selectDay(tester, state, campDay);
      await openEvent(tester, 'E2E Zelten');
      await scrollTo(tester, find.text(de.templatesPackedTotalPacked(2, 5)));
      expect(find.text(de.templatesPackingList), findsOneWidget);
      expect(find.text(de.templatesCreatePackingList), findsNothing);
      await tap(tester, find.text(de.templatesPackingList));
      await waitFor(tester, find.text('🧳 E2E Zelten'));
      await waitFor(tester, find.text('E2E Sache 4'));
      await back(tester);
      await closeEditor(tester);
      // A subscription's appointment: its details only, no packing list.
      await tap(tester, find.text('E2E Abotermin'));
      await tester.pump(const Duration(seconds: 1));
      await waitFor(tester, find.textContaining('nur lesbar'));
      expect(editorOpen, findsNothing);
      expect(find.text(de.templatesCreatePackingList), findsNothing);
      expect(find.text(de.templatesPackingList), findsNothing);
      await closeSheet(tester);
      await finish(tester, state);
    },
  );

  // --- Termine erkennen (Foto, PDF, Text) --------------------------------------

  testWidgets('KAL-076 KAL-078 KAL-079 KAL-080 appointments from pasted text', (
    tester,
  ) async {
    await setUpFamily(tester);
    final state = await startApp(tester);
    final engine = state.engine!;
    final now = today();
    final day = DateFormat.yMMMEd('de');
    await openImport(tester);

    // KAL-076
    var evening = DateTime(now.year, 12, 17);
    if (evening.isBefore(now)) evening = DateTime(now.year + 1, 12, 17);
    final letter = [
      'Einladung zum Elternabend',
      'Datum: ${dmy(evening)}',
      'Uhrzeit: 19:30 Uhr',
      'Ort: Aula der Grundschule',
    ];
    await searchText(tester, letter.join('\n'));
    await waitFor(tester, find.text(de.importTakeOver1Event));
    // The extractor keeps the invitation's own words
    // (app/test/event_extract_test.dart: 'an invitation with one fact per
    // line').
    expect(suggestionTitles(tester), ['Einladung zum Elternabend']);
    final when = de.importDay(day.format(evening), '19:30', '20:30');
    expect(find.text(when), findsOneWidget);
    final card = suggestion(when);
    expect(tickOf(tester, card), isTrue);
    expect(
      find.descendant(of: card, matching: find.text('Aula der Grundschule')),
      findsOneWidget,
    );
    final lines = [
      for (final t in tester.widgetList<Text>(
        find.descendant(of: card, matching: find.byType(Text)),
      ))
        ?t.data,
    ];
    debugPrint('E2E-INFO suggestion shows: $lines');
    expect(
      lines.any(
        (l) =>
            l != 'Aula der Grundschule' &&
            letter.join('\n').contains(l) &&
            l.length > 8,
      ),
      isTrue,
      reason: 'the line it came from',
    );
    // The title can be changed.
    expect(
      tester
          .widget<TextField>(
            find.descendant(of: card, matching: find.byType(TextField)),
          )
          .enabled,
      isNot(false),
    );
    await tap(tester, pageBack());

    // KAL-079
    await searchText(tester, 'Liebe Eltern, bitte bringt Kuchen mit.');
    await waitFor(tester, find.text(de.importNoEventsFoundText));
    final message = find.text(de.importNoEventsFoundText);
    expect(
      tester.widget<Text>(message).style?.color,
      Theme.of(tester.element(message)).colorScheme.error,
    );
    await tap(tester, pageBack());

    // KAL-078 and KAL-080: three suggestions, the past one not ticked.
    final past = inDays(-14), soon = inDays(14), noYear = inDays(-45);
    var summer = DateTime(now.year, noYear.month, noYear.day);
    if (summer.isBefore(inDays(-30))) {
      summer = DateTime(now.year + 1, noYear.month, noYear.day);
    }
    final three = [
      'Laternenumzug am ${dmy(past)}',
      'Adventsbasar am ${dmy(soon)} um 14:30 Uhr',
      'Sommerfest am ${noYear.day}.${noYear.month}.',
    ];
    await searchText(tester, three.join('\n'));
    await waitFor(tester, find.text(de.importTakeOverCountEvents(2)));
    debugPrint('E2E-INFO suggestions: ${suggestionTitles(tester)}');
    expect(suggestionTitles(tester), hasLength(3));
    final pastCard = suggestion(de.importDayAllDay(day.format(past)));
    final basarWhen = de.importDay(day.format(soon), '14:30', '15:30');
    final basarCard = suggestion(basarWhen);
    final summerCard = suggestion(de.importDayAllDay(day.format(summer)));
    expect(tickOf(tester, pastCard), isFalse, reason: 'over already');
    expect(tickOf(tester, basarCard), isTrue);
    expect(tickOf(tester, summerCard), isTrue, reason: 'next year\'s');
    expect(summer.year, greaterThanOrEqualTo(now.year));

    // KAL-080: a title changed, two taken over.
    await enter(
      tester,
      find.descendant(of: basarCard, matching: find.byType(TextField)),
      'E2E Adventsbasar Klasse 3',
    );
    await leaveField(tester);
    await tap(tester, find.text(de.importTakeOverCountEvents(2)));
    await waitFor(tester, find.text(de.importCountEventsAdded(2)));
    await waitFor(tester, monthGrid);
    final basar = engine.events.singleWhere(
      (e) => e.title == 'E2E Adventsbasar Klasse 3',
    );
    expect(basar.allDay, isFalse);
    expect(basar.start.isAtSameMomentAs(at(soon, 14, 30)), isTrue);
    expect(basar.end.isAtSameMomentAs(at(soon, 15, 30)), isTrue);
    expect(basar.notes, de.importTakenLine(three[1]));
    final fest = engine.events.singleWhere(
      (e) => e.title.contains('Sommerfest'),
    );
    expect(fest.allDay, isTrue);
    expect(DateUtils.isSameDay(fest.start, summer), isTrue);
    expect(fest.notes, startsWith('Übernommen aus: '));
    expect(fest.notes, contains('Sommerfest'));
    expect(
      engine.events.where((e) => e.title.contains('Laternenumzug')),
      isEmpty,
    );
    await finish(tester, state);
  });

  // #296: with the family in Asia/Tokyo and the device elsewhere "19:30 Uhr"
  // is 19:30 in Tokyo (10:30 UTC): extractEvents reads the letter in the
  // family's zone (app/test/event_import_zone_test.dart).
  testWidgets('KAL-080 a recognised time is the family\'s time', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    addTearDown(() => f.admin.updateServerSettings({'timeZone': null}));
    await f.admin.updateServerSettings({'timeZone': 'Asia/Tokyo'});
    final state = await startApp(tester);
    final engine = state.engine!;
    await eventually(
      tester,
      'the app knows the zone',
      () async => engine.familyTimeZone == 'Asia/Tokyo',
    );
    final d = inDays(10);
    await openImport(tester);
    await searchText(tester, 'E2E Zeitzone am ${dmy(d)} um 19:30 Uhr');
    await waitFor(tester, find.text(de.importTakeOver1Event));
    await tap(tester, find.text(de.importTakeOver1Event));
    await waitFor(tester, find.text(de.import1EventAdded));
    final e = engine.events.singleWhere((e) => e.title.contains('Zeitzone'));
    // 19:30 in Tokyo (UTC+9, no daylight saving).
    final tokyo = DateTime.utc(
      d.year,
      d.month,
      d.day,
      19,
      30,
    ).subtract(const Duration(hours: 9));
    debugPrint(
      'E2E-INFO recognised 19:30 saved as ${e.start.toUtc()} '
      '(19:30 in Tokyo is $tokyo)',
    );
    expect(e.start.isAtSameMomentAs(tokyo), isTrue);
    await finish(tester, state);
  });

  testWidgets('KAL-077 text from the clipboard', (tester) async {
    await setUpFamily(tester);
    final state = await startApp(tester);
    final d1 = inDays(20), d2 = inDays(22);
    final letter =
        'Liebe Eltern,\n'
        'der Wandertag ist am ${dmy(d1)}.\n'
        'Das Herbstkonzert findet am ${dmy(d2)} um 18:00 Uhr statt.';
    await openImport(tester);
    await withClipboard(tester, paste: letter, (_) async {
      await tap(tester, find.text(de.importClipboard));
      await waitFor(tester, find.text(de.importTakeOverCountEvents(2)));
    });
    expect(suggestionTitles(tester), hasLength(2));
    final day = DateFormat.yMMMEd('de');
    expect(find.text(de.importDayAllDay(day.format(d1))), findsOneWidget);
    expect(
      find.text(de.importDay(day.format(d2), '18:00', '19:00')),
      findsOneWidget,
    );
    // Back: the letter is in the field.
    await tap(tester, pageBack());
    await waitFor(tester, field(de.importPasteTextHere));
    expect(controllerText(tester, field(de.importPasteTextHere)), letter);
    await finish(tester, state);
  });

  testWidgets('KAL-081 suggestions edited before they are taken over', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final state = await startApp(tester);
    final engine = state.engine!;
    final d1 = inDays(8), d2 = inDays(9);
    await openImport(tester);
    await searchText(
      tester,
      'E2E Elternsprechtag am ${dmy(d1)} um 16:00 Uhr\n'
      'Ort: Raum 12\n\n'
      'E2E Bastelnachmittag am ${dmy(d2)} um 15:00 Uhr',
    );
    await waitFor(tester, find.text(de.importTakeOverCountEvents(2)));
    final titles = suggestionTitles(tester);
    debugPrint('E2E-INFO suggestions: $titles');
    expect(titles, hasLength(2));
    final day = DateFormat.yMMMEd('de');
    final firstCard = suggestion(
      de.importDay(day.format(d1), '16:00', '17:00'),
    );
    expect(
      find.descendant(of: firstCard, matching: find.text('Raum 12')),
      findsOneWidget,
    );

    // The first: the whole form, filled in.
    await tap(tester, find.byTooltip(de.importEditEvent).first);
    await waitFor(tester, editorOpen);
    expect(controllerText(tester, titleField), titles[0]);
    expect(shown(tester, de.commonStart), (buttonDate(d1), '16:00'));
    expect(shown(tester, de.commonEnd), (buttonDate(d1), '17:00'));
    await scrollTo(tester, field(de.commonNotes));
    expect(controllerText(tester, field(de.commonPlace)), 'Raum 12');
    expect(
      controllerText(tester, field(de.commonNotes)),
      startsWith('Übernommen aus: '),
    );
    await scrollTo(tester, find.widgetWithText(FilterChip, f.bea.displayName));
    await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
    await scrollTo(
      tester,
      find.ancestor(
        of: find.text(de.commonReminder),
        matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
      ),
    );
    await choose(tester, de.commonReminder, de.event30MinutesBefore);
    await save(tester);
    await waitFor(tester, find.text(de.import1EventAdded));
    expect(suggestionTitles(tester), [titles[1]]);
    await snackGone(tester);

    // The second, and the page closes.
    await tap(tester, find.byTooltip(de.importEditEvent).first);
    await waitFor(tester, editorOpen);
    expect(controllerText(tester, titleField), titles[1]);
    expect(shown(tester, de.commonStart), (buttonDate(d2), '15:00'));
    await save(tester);
    await waitFor(tester, find.text(de.importCountEventsAdded(2)));
    await waitFor(tester, monthGrid);
    final first = engine.events.singleWhere((e) => e.title == titles[0]);
    expect(first.memberIds, [f.bea.id]);
    expect(first.reminderMinutes, 30);
    expect(first.location, 'Raum 12');
    expect(first.start.isAtSameMomentAs(at(d1, 16)), isTrue);
    expect(engine.events.where((e) => e.title == titles[1]), hasLength(1));
    await finish(tester, state);
  });

  testWidgets(
    'KAL-082 KAL-083 KAL-084 KAL-086 a picture: read, its original kept or not, too big, no text',
    (tester) async {
      final f = await setUpFamily(tester);
      addTearDown(() => f.admin.updateServerSettings({'maxUploadMb': null}));
      final picker = fakePicker();
      final d1 = inDays(12), d2 = inDays(13), d3 = inDays(14);
      String on(DateTime d, String time) =>
          'am ${d.day}.${d.month}.${d.year} um $time Uhr';
      final first = await letterFile('e2e-brief-1.png', [
        'E2E Flohmarkt',
        on(d1, '15:30'),
        'Turnhalle der Grundschule',
      ]);
      final second = await letterFile('e2e-brief-2.png', [
        'E2E Kuchenbasar',
        on(d2, '14:00'),
        'Schulhof',
      ]);
      final big = await letterFile('e2e-brief-3.png', [
        'E2E Laternenfest',
        on(d3, '17:00'),
        'Kirchplatz',
      ], noise: true);
      expect(big.lengthSync(), greaterThan(mb));
      final landscape = await tempFile('e2e-wiese.png', await landscapePng());

      final state = await startApp(tester);
      final engine = state.engine!;

      // KAL-082
      await openImport(tester);
      picker.picks.add([DiskFile(first)]);
      await tap(tester, find.text(de.importChoosePicture));
      await waitFor(
        tester,
        find.text(de.importTakeOver1Event),
        timeout: const Duration(seconds: 60),
      );
      debugPrint('E2E-INFO recognised: ${suggestionTitles(tester)}');
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: sourceCard, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );
      final preview = find.descendant(
        of: sourceCard,
        matching: find.byType(Image),
      );
      expect(preview, findsOneWidget);
      await tap(tester, preview);
      await waitFor(tester, find.byType(InteractiveViewer));
      expect(inDialog(find.byType(Image)), findsOneWidget);
      await tap(tester, inDialog(find.text(de.commonClose)));
      await dialogClosed(tester);
      await tap(tester, find.text(de.importTakeOver1Event));
      await waitFor(tester, find.text(de.import1EventAdded));
      final market = engine.events.singleWhere(
        (e) => e.title.contains('Flohmarkt'),
      );
      expect(market.start.isAtSameMomentAs(at(d1, 15, 30)), isTrue);
      expect(market.files, hasLength(1));
      expect(market.files.single.mime, startsWith('image/'));
      await engine.sync();
      await selectDay(tester, state, d1);
      await openEvent(tester, market.title);
      await scrollTo(tester, find.byType(FileThumb));
      expect(find.text(de.tasksPhotos), findsOneWidget);
      expect(find.byType(FileThumb), findsOneWidget);
      await closeEditor(tester);

      // KAL-083
      await openImport(tester);
      picker.picks.add([DiskFile(second)]);
      await tap(tester, find.text(de.importChoosePicture));
      await waitFor(
        tester,
        find.text(de.importTakeOver1Event),
        timeout: const Duration(seconds: 60),
      );
      await tap(
        tester,
        find.descendant(of: sourceCard, matching: find.byType(Checkbox)),
      );
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: sourceCard, matching: find.byType(Checkbox)),
            )
            .value,
        isFalse,
      );
      await tap(tester, find.text(de.importTakeOver1Event));
      await waitFor(tester, find.text(de.import1EventAdded));
      final cake = engine.events.singleWhere(
        (e) => e.title.contains('Kuchenbasar'),
      );
      expect(cake.files, isEmpty);
      await snackGone(tester);

      // KAL-086
      await openImport(tester);
      picker.picks.add([DiskFile(landscape)]);
      await tap(tester, find.text(de.importChoosePicture));
      await waitFor(
        tester,
        find.text(de.importNoTextWasRecognized),
        timeout: const Duration(seconds: 60),
      );
      final message = find.text(de.importNoTextWasRecognized);
      expect(
        tester.widget<Text>(message).style?.color,
        Theme.of(tester.element(message)).colorScheme.error,
      );
      await back(tester);

      // KAL-084: the server takes at most 1 MB.
      await f.admin.updateServerSettings({'maxUploadMb': 1});
      await eventually(tester, 'the app knows the limit', () async {
        await engine.sync();
        return engine.maxUploadBytes == mb;
      });
      await openImport(tester);
      picker.picks.add([DiskFile(big)]);
      await tap(tester, find.text(de.importChoosePicture));
      await waitFor(
        tester,
        find.text(de.importTakeOver1Event),
        timeout: const Duration(seconds: 60),
      );
      await tap(tester, find.text(de.importTakeOver1Event));
      await waitFor(
        tester,
        find.text('${de.import1EventAdded} ${de.importOriginalNotKept}'),
      );
      final lantern = engine.events.singleWhere(
        (e) => e.title.contains('Laternenfest'),
      );
      expect(lantern.files, isEmpty);
      await finish(tester, state);
    },
  );

  testWidgets('KAL-085 a PDF with text and one without', (tester) async {
    await setUpFamily(tester);
    final picker = fakePicker();
    final d = inDays(15);
    final withText = await tempFile(
      'e2e-einladung.pdf',
      await textPdf([
        'E2E Theaterabend',
        'am ${dmy(d)} um 18:00 Uhr',
        'Ort: Aula',
      ]),
    );
    final scan = await tempFile(
      'e2e-scan.pdf',
      await picturePdf(await landscapePng()),
    );
    final state = await startApp(tester);
    await openImport(tester);
    picker.picks.add([DiskFile(withText)]);
    await tap(tester, find.text(de.importChoosePdf));
    await waitFor(
      tester,
      find.text(de.importTakeOver1Event),
      timeout: const Duration(seconds: 60),
    );
    debugPrint('E2E-INFO from the PDF: ${suggestionTitles(tester)}');
    expect(
      find.text(
        de.importDay(DateFormat.yMMMEd('de').format(d), '18:00', '19:00'),
      ),
      findsOneWidget,
    );
    // The card shows a PDF symbol instead of a preview.
    expect(
      find.descendant(of: sourceCard, matching: find.byIcon(AppIcons.fileText)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sourceCard, matching: find.byType(Image)),
      findsNothing,
    );
    await tap(tester, pageBack());
    picker.picks.add([DiskFile(scan)]);
    await tap(tester, find.text(de.importChoosePdf));
    await waitFor(
      tester,
      find.text(de.importNoTextWasFound),
      timeout: const Duration(seconds: 60),
    );
    await finish(tester, state);
  });

  // --- Kalenderdateien (.ics) --------------------------------------------------

  testWidgets(
    'KAL-090 KAL-092 KAL-093 KAL-094 calendar files: chosen, all or none, special rules, refused',
    (tester) async {
      await setUpFamily(tester);
      final picker = fakePicker();
      final now = DateTime.now();
      final single = at(inDays(10), 10);
      final weekly = at(inDays(3), 17);
      final twoEvents = await tempFile(
        'e2e-zwei.ics',
        utf8.encode(
          vcalendar([
            vevent(
              'e2e-ics-dentist@example.com',
              'E2E Zahnarzt',
              single,
              single.add(const Duration(minutes: 30)),
            ),
            vevent(
              'e2e-ics-swim@example.com',
              'E2E Schwimmkurs',
              weekly,
              weekly.add(const Duration(hours: 1)),
              extra: 'RRULE:FREQ=WEEKLY;COUNT=10\r\n',
            ),
          ]),
        ),
      );
      final threeEvents = await tempFile(
        'e2e-drei.ics',
        utf8.encode(
          vcalendar([
            for (var i = 1; i <= 3; i++)
              vevent(
                'e2e-ics-three-$i@example.com',
                'E2E Termin $i',
                at(inDays(20 + i), 9),
                at(inDays(20 + i), 10),
              ),
          ]),
        ),
      );
      // A second Tuesday of every month (no rule of Famio's), running and
      // one that ended two years ago.
      final lastMonth = DateTime(now.year, now.month - 1, 1, 18);
      final special = await tempFile(
        'e2e-regel.ics',
        utf8.encode(
          vcalendar([
            vevent(
              'e2e-ics-club@example.com',
              'E2E Vereinsabend',
              lastMonth,
              lastMonth.add(const Duration(hours: 2)),
              extra: 'RRULE:FREQ=MONTHLY;BYDAY=2TU\r\n',
            ),
            vevent(
              'e2e-ics-old@example.com',
              'E2E Alter Stammtisch',
              DateTime.utc(now.year - 3, 1, 10, 18),
              DateTime.utc(now.year - 3, 1, 10, 20),
              extra:
                  'RRULE:FREQ=MONTHLY;BYDAY=2TU;UNTIL=${now.year - 2}0101T000000Z\r\n',
            ),
          ]),
        ),
      );
      final tooBig = await tempFile(
        'e2e-gross.ics',
        List.filled(10 * mb + 512, 0x41),
      );
      final empty = await tempFile(
        'e2e-leer.ics',
        utf8.encode(vcalendar(const [])),
      );

      final state = await startApp(tester);
      final engine = state.engine!;

      // KAL-090
      await openImport(tester);
      picker.picks.add([DiskFile(twoEvents)]);
      await tap(tester, find.text(de.importIcsFile));
      await waitFor(tester, find.byType(IcsImportScreen));
      await dismissTip(tester);
      expect(find.text(de.importIcsFile), findsWidgets);
      expect(find.text(de.importIcsCount(2)), findsWidgets);
      expect(find.text(de.importIcsHint), findsOneWidget);
      expect(
        [
          for (final c in tester.widgetList<Checkbox>(find.byType(Checkbox)))
            c.value,
        ],
        [true, true],
      );
      expect(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('E2E Schwimmkurs'),
                matching: find.byType(SoftCard),
              )
              .first,
          matching: find.textContaining(de.importIcsRepeats),
        ),
        findsOneWidget,
      );
      await tap(
        tester,
        find.descendant(
          of: find
              .ancestor(
                of: find.text('E2E Zahnarzt'),
                matching: find.byType(SoftCard),
              )
              .first,
          matching: find.byType(Checkbox),
        ),
      );
      await tap(tester, find.text(de.importTakeOver1Event));
      await waitFor(tester, find.text(de.import1EventAdded));
      await waitFor(tester, monthGrid);
      final swim = engine.events.singleWhere(
        (e) => e.title == 'E2E Schwimmkurs',
      );
      expect(swim.recurrence?.frequency, RecurrenceFrequency.weekly);
      expect(engine.events.where((e) => e.title == 'E2E Zahnarzt'), isEmpty);
      await snackGone(tester);

      // KAL-092
      await openImport(tester);
      picker.picks.add([DiskFile(threeEvents)]);
      await tap(tester, find.text(de.importIcsFile));
      await waitFor(tester, find.byType(IcsImportScreen));
      final takeButton = find.ancestor(
        of: find.textContaining(RegExp(r'Termine? übernehmen$')),
        matching: find.byType(FilledButton),
      );
      await tap(tester, find.text(de.importIcsNone));
      expect(
        [
          for (final c in tester.widgetList<Checkbox>(find.byType(Checkbox)))
            c.value,
        ],
        [false, false, false],
      );
      expect(tester.widget<FilledButton>(takeButton).onPressed, isNull);
      await tap(tester, find.text(de.importIcsAll));
      expect(
        [
          for (final c in tester.widgetList<Checkbox>(find.byType(Checkbox)))
            c.value,
        ],
        [true, true, true],
      );
      expect(find.text(de.importTakeOverCountEvents(3)), findsOneWidget);
      expect(tester.widget<FilledButton>(takeButton).onPressed, isNotNull);
      await tap(tester, pageBack());
      await waitGone(tester, find.byType(IcsImportScreen));

      // KAL-093
      picker.picks.add([DiskFile(special)]);
      await tap(tester, find.text(de.importIcsFile));
      await waitFor(tester, find.byType(IcsImportScreen));
      expect(find.text(de.importIcsExpanded(1)), findsOneWidget);
      await scrollTo(tester, find.text(de.importIcsSkipped));
      final skipped = find.textContaining('E2E Alter Stammtisch: ');
      expect(skipped, findsOneWidget);
      debugPrint('E2E-INFO skipped: ${tester.widget<Text>(skipped).data}');
      expect(
        tester.widget<Text>(skipped).data!.length,
        greaterThan('E2E Alter Stammtisch: '.length),
        reason: 'with a reason',
      );
      expect(find.text('E2E Vereinsabend'), findsWidgets);
      await tap(tester, pageBack());
      await waitGone(tester, find.byType(IcsImportScreen));

      // KAL-094
      picker.picks.add([DiskFile(tooBig)]);
      await tap(tester, find.text(de.importIcsFile));
      await waitFor(tester, find.text(de.importIcsTooLarge));
      picker.picks.add([DiskFile(empty)]);
      await tap(tester, find.text(de.importIcsFile));
      await waitFor(tester, find.text('Die Datei enthält keine Termine.'));
      expect(find.byType(IcsImportScreen), findsNothing);
      await finish(tester, state);
    },
  );

  testWidgets('KAL-096 a calendar file dragged onto the window', (
    tester,
  ) async {
    await setUpFamily(tester);
    final d = inDays(11);
    final ics = await tempFile(
      'e2e-gezogen.ics',
      utf8.encode(
        vcalendar([
          vevent(
            'e2e-ics-drop@example.com',
            'E2E Gezogener Termin',
            at(d, 10),
            at(d, 11),
          ),
        ]),
      ),
    );
    final pdf = await tempFile('e2e-brief.pdf', pdfBytes);
    final state = await startApp(tester);
    expect(monthGrid, findsNothing, reason: 'the app starts on "Start"');
    await dropFiles(tester, [ics]);
    await waitFor(tester, find.byType(IcsImportScreen));
    await dismissTip(tester);
    await waitFor(tester, find.text('E2E Gezogener Termin'));
    expect(find.text(de.importIcsCount(1)), findsWidgets);
    await tap(tester, pageBack());
    await waitGone(tester, find.byType(IcsImportScreen));
    await waitFor(tester, monthGrid);
    // Other files go to "Teilen an Famio".
    await dropFiles(tester, [pdf]);
    await waitFor(tester, find.text(de.shareTitle));
    expect(find.byType(IcsImportScreen), findsNothing);
    await closeSheet(tester);
    await finish(tester, state);
  });

  // --- Famio in Kalender-Apps (App-Passwort) -----------------------------------

  testWidgets(
    'KAL-097 KAL-098 KAL-099 app password, access data, a calendar app reads',
    (tester) async {
      final f = await setUpFamily(tester);
      addTearDown(() => f.admin.updateServerSettings({'publicUrl': null}));
      for (final p in await f.admin.appPasswords()) {
        await f.admin.deleteAppPassword(p.id);
      }
      await addEvent(f.admin, 'E2E Kalender-App', at(inDays(3), 10));
      final davUrl = Uri.parse(kitUrl).resolve('dav/').toString();
      final state = await startApp(tester);
      await openConnect(tester);

      // KAL-098: address, username; no certificate over plain HTTP.
      await scrollTo(tester, find.text(de.caldavCreateAppPassword));
      expect(find.text(de.commonServerAddress), findsOneWidget);
      expect(find.text(davUrl), findsOneWidget);
      expect(find.text(de.commonUsername), findsOneWidget);
      expect(find.text(kitUser), findsWidgets);
      expect(find.text(de.caldavCertificateSha256Compare), findsNothing);
      expect(find.text(de.caldavServerAddressEverywhere), findsNothing);
      final copied = await withClipboard(tester, (copied) async {
        await tap(tester, find.byTooltip(de.caldavCopyAddress));
        await waitFor(tester, find.text(de.caldavAddressCopied));
        return copied;
      });
      expect(copied, [davUrl]);
      // With a public address: that one in addition.
      await f.admin.updateServerSettings({
        'publicUrl': 'https://famio.example.org',
      });
      await back(tester);
      await snackGone(tester);
      await openConnect(tester);
      await scrollTo(tester, find.text(de.caldavCreateAppPassword));
      expect(find.text(de.caldavServerAddressEverywhere), findsOneWidget);
      expect(find.text('https://famio.example.org/dav/'), findsOneWidget);
      expect(find.text(de.caldavServerAddressHomeNetwork), findsOneWidget);
      await f.admin.updateServerSettings({'publicUrl': null});
      await back(tester);
      await openConnect(tester);

      // KAL-097: a wrong password, then none: nothing is made.
      await scrollTo(tester, find.text(de.caldavCreateAppPassword));
      await tap(tester, find.text(de.caldavCreateAppPassword));
      await waitFor(tester, find.text(de.caldavNewAppPassword));
      await enter(tester, field(de.caldavWhichDevice), 'iPhone');
      await leaveField(tester);
      await tap(tester, find.text(de.commonCreate).last);
      await waitFor(tester, find.text(de.accountPasswordTitle));
      await enter(
        tester,
        inDialog(find.widgetWithText(TextField, de.commonPassword)),
        'falsches-passwort-1',
      );
      await leaveField(tester);
      await tap(tester, find.text(de.commonConfirm));
      await waitFor(tester, find.text('Passwort falsch'));
      expect(find.text(de.caldavNewAppPassword), findsOneWidget);
      expect(await f.admin.appPasswords(), isEmpty);
      await tap(tester, find.text(de.commonCreate).last);
      await waitFor(tester, find.text(de.accountPasswordTitle));
      await tap(tester, inDialog(find.text(de.commonCancel)).last);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(de.caldavNewAppPassword), findsOneWidget);
      expect(await f.admin.appPasswords(), isEmpty);
      // The right one: shown once.
      await tap(tester, find.text(de.commonCreate).last);
      await waitFor(tester, find.text(de.accountPasswordTitle));
      await enter(
        tester,
        inDialog(find.widgetWithText(TextField, de.commonPassword)),
        kitPassword,
      );
      await leaveField(tester);
      await tap(tester, find.text(de.commonConfirm));
      await waitFor(tester, find.text(de.caldavAppPassword));
      final secret = tester
          .widget<SelectableText>(inDialog(find.byType(SelectableText)))
          .data!;
      expect(secret, isNotEmpty);
      expect(inDialog(find.text(de.commonCopy)), findsOneWidget);
      final again = await withClipboard(tester, (copied) async {
        await tap(tester, inDialog(find.text(de.commonCopy)));
        return copied;
      });
      expect(again, [secret]);
      await tap(tester, inDialog(find.text(de.commonDone)));
      await dialogClosed(tester);
      await scrollTo(tester, find.text('iPhone'));
      expect(
        find.descendant(
          of: listTile('iPhone'),
          matching: find.text(de.caldavNotUsedYet),
        ),
        findsOneWidget,
      );
      expect((await f.admin.appPasswords()).single.name, 'iPhone');

      // KAL-099: a calendar app with it …
      expect(await davStatus(kitUser, secret), 207);
      final (home, homeBody) = await dav(
        'PROPFIND',
        'dav/calendars/$kitUser/',
        user: kitUser,
        password: secret,
        headers: {'depth': '1'},
      );
      expect(home, 207);
      expect(homeBody, contains('/dav/calendars/$kitUser/famio/'));
      expect(homeBody, contains('Famio'));
      final (status, events) = await davEvents(kitUser, secret);
      expect(status, 207);
      expect(events, contains('SUMMARY:E2E Kalender-App'));
      // … and with the Famio password: no.
      expect(await davStatus(kitUser, kitPassword), 401);
      await back(tester);
      await openConnect(tester);
      await scrollTo(tester, find.text('iPhone'));
      expect(
        find.descendant(
          of: listTile('iPhone'),
          matching: find.textContaining('zuletzt '),
        ),
        findsOneWidget,
      );
      for (final p in await f.admin.appPasswords()) {
        await f.admin.deleteAppPassword(p.id);
      }
      await finish(tester, state);
    },
  );

  testWidgets('KAL-098 over HTTPS: the certificate to compare', (tester) async {
    await setUpFamily(tester);
    expect(tlsUrl, startsWith('https://'));
    final state = await startHttps(tester, 'e2e-bea');
    expect(state.serverUrl, startsWith('https://'));
    await openConnect(tester);
    await scrollTo(tester, find.text(de.caldavCertificateSha256Compare));
    expect(find.text(state.certificatePin!), findsOneWidget);
    expect(
      find.text(Uri.parse(tlsUrl).resolve('dav/').toString()),
      findsOneWidget,
    );
    expect(find.text('e2e-bea'), findsWidgets);
    await finish(tester, state);
  });

  testWidgets('KAL-100 confidential appointments in calendar apps', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final ha = await theService();
    final haApi = await sessionOf(ha);
    final bea = await sessionOf(f.bea);
    final kid = await sessionOf(f.kid);
    final day = inDays(4);
    final secret = await addEvent(
      f.admin,
      'E2E Geheim DAV',
      at(day, 11),
      members: [f.adminMember.id],
      confidential: true,
      location: 'Praxis',
    );
    await addEvent(f.admin, 'E2E Offen DAV', at(day, 9));
    final (_, plain) = await f.admin.createAppPassword(
      name: 'E2E ohne',
      password: kitPassword,
    );
    final (_, shown) = await f.admin.createAppPassword(
      name: 'E2E mit',
      password: kitPassword,
      includeConfidential: true,
    );
    final (_, beaShown) = await bea.createAppPassword(
      name: 'E2E Bea mit',
      password: kitMemberPassword,
      includeConfidential: true,
    );
    final (_, kidShown) = await kid.createAppPassword(
      name: 'E2E Kind mit',
      password: kitMemberPassword,
      includeConfidential: true,
    );
    final (_, haShown) = await haApi.createAppPassword(
      name: 'E2E HA mit',
      password: kitMemberPassword,
      includeConfidential: true,
    );
    addTearDown(() async {
      for (final api in [f.admin, bea, kid, haApi]) {
        for (final p in await api.appPasswords()) {
          await api.deleteAppPassword(p.id);
        }
      }
    });
    String item(String user) => 'dav/calendars/$user/famio/$secret.ics';

    // Without the switch: not there.
    expect(
      (await dav('GET', item(kitUser), user: kitUser, password: plain)).$1,
      404,
    );
    final (_, plainList) = await davEvents(kitUser, plain);
    expect(plainList, contains('SUMMARY:E2E Offen DAV'));
    expect(plainList, isNot(contains('E2E Geheim DAV')));
    // With it: there.
    final (got, body) = await dav(
      'GET',
      item(kitUser),
      user: kitUser,
      password: shown,
    );
    expect(got, 200);
    expect(body, contains('SUMMARY:E2E Geheim DAV'));
    final (_, shownList) = await davEvents(kitUser, shown);
    expect(shownList, contains('SUMMARY:E2E Geheim DAV'));
    // Only for those who may see it (adults do): not the child, who takes
    // no part, never the service account.
    expect(
      (await dav(
        'GET',
        item('e2e-bea'),
        user: 'e2e-bea',
        password: beaShown,
      )).$1,
      200,
    );
    expect(
      (await dav(
        'GET',
        item('e2e-kind'),
        user: 'e2e-kind',
        password: kidShown,
      )).$1,
      404,
    );
    expect(
      (await dav('GET', item('e2e-ha'), user: 'e2e-ha', password: haShown)).$1,
      404,
    );
    final (_, haList) = await davEvents('e2e-ha', haShown);
    expect(haList, isNot(contains('E2E Geheim DAV')));
    expect(haList, contains('SUMMARY:E2E Offen DAV'));

    // The entries say which one shows them.
    final state = await startApp(tester);
    await openConnect(tester);
    await scrollTo(tester, find.text('E2E mit'));
    expect(
      find.descendant(
        of: listTile('E2E mit'),
        matching: find.textContaining(de.caldavPrivateEvents),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: listTile('E2E ohne'),
        matching: find.textContaining(de.caldavPrivateEvents),
      ),
      findsNothing,
    );
    await finish(tester, state);
  });

  testWidgets(
    'KAL-101 an appointment made, changed and deleted in a calendar app',
    (tester) async {
      final f = await setUpFamily(tester);
      final (_, secret) = await f.admin.createAppPassword(
        name: 'E2E Kalender',
        password: kitPassword,
        includeConfidential: true,
      );
      addTearDown(() async {
        for (final p in await f.admin.appPasswords()) {
          await f.admin.deleteAppPassword(p.id);
        }
      });
      final id = uid('dav');
      final day = inDays(4);
      final start = at(day, 14);
      String ics(String title) => vcalendar([
        vevent(id, title, start, start.add(const Duration(hours: 1))),
      ]);
      final path = 'dav/calendars/$kitUser/famio/$id.ics';
      final made = await dav(
        'PUT',
        path,
        user: kitUser,
        password: secret,
        body: ics('E2E Aus der Kalender-App'),
        type: 'text/calendar; charset=utf-8',
      );
      expect(made.$1, 201, reason: made.$2);

      final state = await startApp(tester);
      final engine = state.engine!;
      await openCalendar(tester);
      await selectDay(tester, state, day);
      await waitFor(tester, find.text('E2E Aus der Kalender-App'));
      expect(engine.event(id)!.start.isAtSameMomentAs(start), isTrue);
      // In Famio: Bea takes part, and it is confidential.
      await openEvent(tester, 'E2E Aus der Kalender-App');
      await scrollTo(
        tester,
        find.widgetWithText(FilterChip, f.bea.displayName),
      );
      await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
      await flip(tester, de.commonPrivate);
      await save(tester);
      await engine.sync();
      await eventually(tester, 'the server has it', () async {
        final e = CalendarEvent.fromRecord((await eventOf(f.admin, id))!);
        return e.confidential && e.memberIds.contains(f.bea.id);
      });

      // A new title from the calendar app keeps both.
      final changed = await dav(
        'PUT',
        path,
        user: kitUser,
        password: secret,
        body: ics('E2E Geaendert in der Kalender-App'),
        type: 'text/calendar; charset=utf-8',
      );
      expect(changed.$1, 204, reason: changed.$2);
      await waitFor(tester, find.text('E2E Geaendert in der Kalender-App'));
      final now = engine.event(id)!;
      expect(now.confidential, isTrue);
      expect(now.memberIds, contains(f.bea.id));

      // Deleted there: gone here.
      final deleted = await dav(
        'DELETE',
        path,
        user: kitUser,
        password: secret,
      );
      expect(deleted.$1, anyOf(200, 204), reason: deleted.$2);
      await waitGone(tester, find.text('E2E Geaendert in der Kalender-App'));
      expect(engine.event(id), isNull);
      await finish(tester, state);
    },
  );

  testWidgets(
    'KAL-103 KAL-104 an app password disconnected, a new password ends them',
    (tester) async {
      final f = await setUpFamily(tester);
      final m = await member('e2e-kal-pw', 'E2E Passwort');
      const user = 'e2e-kal-pw';
      const newPassword = 'E2E-Neues-Kennwort-4711';
      addTearDown(() => f.admin.resetPassword(m.id, kitMemberPassword));
      var api = await loginAs(user, kitMemberPassword);
      final (_, first) = await api.createAppPassword(
        name: 'iPhone',
        password: kitMemberPassword,
      );
      expect(await davStatus(user, first), 207);

      // KAL-103
      final state = await startApp(tester, user: user);
      await openConnect(tester);
      await scrollTo(tester, find.text('iPhone'));
      await tap(
        tester,
        find.descendant(
          of: listTile('iPhone'),
          matching: find.byTooltip(de.commonDisconnect),
        ),
      );
      await waitFor(tester, find.text(de.caldavDisconnectName('iPhone')));
      await tap(tester, find.widgetWithText(FilledButton, de.commonDisconnect));
      await dialogClosed(tester);
      await waitGone(tester, find.text('iPhone'));
      expect(await api.appPasswords(), isEmpty);
      expect(await davStatus(user, first), 401);
      await back(tester);

      // KAL-104: the own new password …
      final (_, second) = await api.createAppPassword(
        name: 'E2E Mac',
        password: kitMemberPassword,
      );
      expect(await davStatus(user, second), 207);
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, find.text(de.settingsChangePassword));
      await tap(tester, find.text(de.settingsChangePassword));
      await waitFor(tester, find.text(de.settingsPasswordChangeNote));
      await enter(tester, field(de.settingsCurrentPassword), kitMemberPassword);
      await enter(tester, field(de.settingsNewPassword), newPassword);
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await waitGone(tester, find.text(de.settingsPasswordChangeNote));
      expect(await davStatus(user, second), 401);
      api = await loginAs(user, newPassword);
      expect(await api.appPasswords(), isEmpty);
      await openConnect(tester);
      await scrollTo(tester, find.text(de.caldavCreateAppPassword));
      expect(find.text('E2E Mac'), findsNothing);
      await finish(tester, state);

      // … and one an admin sets.
      final (_, third) = await api.createAppPassword(
        name: 'E2E iPad',
        password: newPassword,
      );
      expect(await davStatus(user, third), 207);
      await f.admin.resetPassword(m.id, kitMemberPassword);
      expect(await davStatus(user, third), 401);
      expect(
        await (await loginAs(user, kitMemberPassword)).appPasswords(),
        isEmpty,
      );
    },
  );

  // --- Kalender-Link (ICS-Feed) ------------------------------------------------

  testWidgets(
    'KAL-107 KAL-108 KAL-109 KAL-110 KAL-112 calendar links: all, mine, busy, revoked',
    (tester) async {
      final f = await setUpFamily(tester);
      final (old, _) = await f.admin.calendarFeeds();
      for (final feed in old) {
        await f.admin.deleteCalendarFeed(feed.id);
      }
      addTearDown(() async {
        final (left, _) = await f.admin.calendarFeeds();
        for (final feed in left) {
          await f.admin.deleteCalendarFeed(feed.id);
        }
      });
      final day = inDays(2);
      await addEvent(
        f.admin,
        'E2E Mit Admin',
        at(day, 10),
        members: [f.adminMember.id],
        location: 'Turnhalle',
        notes: 'Bitte Schuhe mitbringen',
      );
      await addEvent(f.admin, 'E2E Nur Bea', at(day, 12), members: [f.bea.id]);
      await addEvent(f.admin, 'E2E Familie Feed', at(day, 15));
      final secret = await addEvent(
        f.admin,
        'E2E Geheim Feed',
        at(day, 17),
        members: [f.adminMember.id],
        confidential: true,
      );
      final state = await startApp(tester);
      await openConnect(tester);
      await scrollTo(tester, find.text(de.calendarCreateLink));

      // KAL-112: no public address.
      expect(find.text(de.calendarGoogleCalendarAppleCalendar), findsOneWidget);

      Future<void> create({String? scope, bool busy = false}) async {
        await snackGone(tester);
        await scrollTo(tester, find.text(de.calendarCreateLink));
        await tap(tester, find.text(de.calendarCreateLink));
        await waitFor(tester, find.text(de.calendarNewCalendarLink));
        expect(
          controllerText(
            tester,
            inDialog(
              find.widgetWithText(TextField, de.calendarNameOtherCalendar),
            ),
          ),
          'Famio',
        );
        final segments = tester.widget<SegmentedButton<FeedScope>>(
          find.byType(SegmentedButton<FeedScope>),
        );
        expect(segments.selected, {FeedScope.all});
        if (scope != null) await tap(tester, inDialog(find.text(scope)));
        if (busy) {
          await tap(
            tester,
            find.widgetWithText(SwitchListTile, de.calendarShowOnlyBusy),
          );
        }
        await tap(tester, inDialog(find.text(de.commonCreate)));
        await waitFor(tester, find.text(de.accountPasswordTitle));
        await enter(
          tester,
          inDialog(find.widgetWithText(TextField, de.commonPassword)),
          kitPassword,
        );
        await leaveField(tester);
        await tap(tester, find.text(de.commonConfirm));
        await dialogClosed(tester);
      }

      Future<String> copyLink(String tile) async {
        await snackGone(tester);
        await scrollTo(tester, find.text(tile));
        final copied = await withClipboard(tester, (copied) async {
          await tap(
            tester,
            find.descendant(
              of: listTile(tile),
              matching: find.byTooltip(de.calendarCopyLink),
            ),
          );
          await waitFor(tester, find.text(de.calendarLinkCopied));
          return copied;
        });
        return copied.single;
      }

      // KAL-107
      await create();
      final allTile = 'Famio · ${de.calendarAllEvents2}';
      await waitFor(tester, find.text(allTile));
      final all = await copyLink(allTile);
      // KAL-112: the server address of the app.
      expect(Uri.parse(all).origin, Uri.parse(kitUrl).origin);
      final (status, feed) = await fetch(all);
      expect(status, 200);
      expect(feed, contains('BEGIN:VCALENDAR'));
      for (final t in ['E2E Mit Admin', 'E2E Nur Bea', 'E2E Familie Feed']) {
        expect(feed, contains('SUMMARY:$t'));
      }
      expect(feed, isNot(contains('E2E Geheim Feed')), reason: 'KAL-109');
      expect(feed, isNot(contains(secret)));
      await snackGone(tester);
      final webcal = await withClipboard(tester, (copied) async {
        await tap(
          tester,
          find.descendant(
            of: listTile(allTile),
            matching: find.byType(PopupMenuButton<String>),
          ),
        );
        await tap(tester, find.text(de.calendarCopyWebcal));
        await waitFor(tester, find.text(de.calendarWebcalLinkCopied));
        return copied;
      });
      expect(webcal.single, startsWith('webcal://'));
      expect(
        webcal.single.substring('webcal'.length),
        all.substring('http'.length),
      );

      // KAL-108
      await create(scope: de.calendarOnlyMine);
      final mineTile = 'Famio · ${de.calendarOnlyMine2}';
      await waitFor(tester, find.text(mineTile));
      final (_, mine) = await fetch(await copyLink(mineTile));
      expect(mine, contains('SUMMARY:E2E Mit Admin'));
      expect(mine, contains('SUMMARY:E2E Familie Feed'));
      expect(mine, isNot(contains('E2E Nur Bea')));

      // KAL-109
      await create(busy: true);
      final busyTile = 'Famio · ${de.calendarAllEvents2}${de.calendarOnlyBusy}';
      await waitFor(tester, find.text(busyTile));
      final (_, busy) = await fetch(await copyLink(busyTile));
      debugPrint('E2E-INFO busy feed:\n$busy');
      expect('SUMMARY:Belegt'.allMatches(busy), hasLength(3));
      expect('BEGIN:VEVENT'.allMatches(busy), hasLength(3));
      for (final t in [
        'E2E Mit Admin',
        'E2E Nur Bea',
        'E2E Familie Feed',
        'E2E Geheim Feed',
        'Turnhalle',
        'Schuhe',
      ]) {
        expect(busy, isNot(contains(t)));
      }
      expect(busy, isNot(contains('LOCATION:')));
      expect(busy, isNot(contains('DESCRIPTION:')));

      // KAL-110
      await snackGone(tester);
      await scrollTo(tester, find.text(allTile));
      await tap(
        tester,
        find.descendant(
          of: listTile(allTile),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tap(tester, find.text(de.commonRevoke).last);
      await waitFor(tester, find.text(de.calendarRevokeLinkName('Famio')));
      await tap(tester, find.widgetWithText(FilledButton, de.commonRevoke));
      await dialogClosed(tester);
      await waitGone(tester, find.text(allTile));
      final (gone, goneBody) = await fetch(all);
      expect(gone, 404);
      expect(goneBody, contains('Unbekannter Kalender'));
      expect(find.text(mineTile), findsOneWidget);
      await finish(tester, state);
    },
  );

  testWidgets('KAL-111 a guest gets no calendar link', (tester) async {
    final f = await setUpFamily(tester);
    final guest = await sessionOf(f.guest);
    final state = await startApp(tester, user: 'e2e-gast');
    await openConnect(tester);
    await scrollTo(tester, find.text(de.calendarCreateLink));
    await tap(tester, find.text(de.calendarCreateLink));
    await waitFor(tester, find.text(de.calendarNewCalendarLink));
    await tap(tester, inDialog(find.text(de.commonCreate)));
    await waitFor(tester, find.text(de.accountPasswordTitle));
    await enter(
      tester,
      inDialog(find.widgetWithText(TextField, de.commonPassword)),
      kitMemberPassword,
    );
    await leaveField(tester);
    await tap(tester, find.text(de.commonConfirm));
    await waitFor(tester, find.text('Für Gäste nicht verfügbar'));
    final (feeds, _) = await guest.calendarFeeds();
    expect(feeds, isEmpty);
    expect(find.textContaining('Famio · '), findsNothing);
    await finish(tester, state);
  });

  // --- Verbundene Kalender, Abos -----------------------------------------------

  // Was a Befund: a guest got no hint that connected calendars and
  // subscriptions are not for guests ("Nur mit Verbindung zum Server
  // verfügbar", and "Kalender abonnieren" closed as if saved). Now both
  // sections say so, and there is nothing to subscribe.
  testWidgets(
    'KAL-121 a guest learns that connected calendars are not for guests',
    (tester) async {
      final f = await setUpFamily(tester);
      final guest = await sessionOf(f.guest);
      final state = await startApp(tester, user: 'e2e-gast');
      final engine = state.engine!;
      await openConnect(tester);
      await scrollTo(tester, find.text(de.calendarSyncGoogleIcloudNextcloud));
      await tester.pump(const Duration(seconds: 2));
      debugPrint('E2E-INFO the guest sees: ${onScreen()}');
      expect(find.text(de.commonOnlyWithServer), findsNothing);
      expect(find.text(de.calendarNotForGuests), findsWidgets);
      // Nothing to subscribe that would never be saved.
      await scrollTo(tester, find.text(de.calendarShowOtherCalendarsFamio));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(de.calendarSubscribeCalendar), findsNothing);
      expect(find.text(de.calendarNotForGuests), findsWidgets);
      await engine.sync();
      expect(await pull(guest, Collections.calendarSubscriptions), isEmpty);
      await finish(tester, state);
    },
  );

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

  testWidgets(
    'KAL-122 KAL-124 KAL-125 KAL-126 KAL-129 subscribe, wrong addresses, fetch, remove',
    (tester) async {
      final f = await setUpFamily(tester);
      final bea = await sessionOf(f.bea);
      final state = await startApp(tester);
      final engine = state.engine!;
      await openConnect(tester);

      // KAL-124: refused at the field, the dialog stays open.
      await scrollTo(tester, find.text(de.calendarSubscribeCalendar));
      await tap(tester, find.text(de.calendarSubscribeCalendar));
      await waitFor(tester, find.text(de.calendarWhoSeesEvents));
      await enter(tester, field(de.commonName), 'E2E Falsch');
      for (final wrong in ['ftp://x', 'kalender']) {
        await enter(tester, field(de.calendarIcsAddress), wrong);
        await leaveField(tester);
        await tap(tester, inDialog(find.text(de.commonSave)));
        await waitFor(tester, find.text(de.calendarAddressMustStartHttps));
        expect(find.text(de.calendarWhoSeesEvents), findsOneWidget);
      }
      await tap(tester, inDialog(find.text(de.commonCancel)));
      await dialogClosed(tester);
      expect(engine.calendarSubscriptions, isEmpty);

      // KAL-122
      final colour = famioPalette[2];
      await subscribe(
        tester,
        'E2E Schule',
        'https://127.0.0.1:9/e2e-schule.ics',
        colour: colour,
      );
      final school = engine.calendarSubscriptions.singleWhere(
        (s) => s.name == 'E2E Schule',
      );
      expect(school.color, colour);
      expect(school.ownerId, f.adminMember.id);
      expect(school.sharing.family, isTrue);
      await waitFor(tester, find.text('E2E Schule'));
      final subtitle = find.descendant(
        of: listTile('E2E Schule'),
        matching: find.textContaining(
          de.calendarOwnerVisibleWho(de.calendarYou, de.commonWholeFamily),
        ),
      );
      expect(subtitle, findsOneWidget);
      debugPrint(
        'E2E-INFO new subscription: ${tester.widget<Text>(subtitle).data}',
      );
      final firstLine = tester.widget<Text>(subtitle).data!.split('\n').first;
      expect(
        firstLine,
        anyOf(de.calendarWillLoadedNextSync, contains('127.0.0.1')),
      );
      // Its appointments (as the importer writes them): its colour, read-only.
      final day = inDays(3);
      await addEvent(
        f.admin,
        'E2E Schule Elternabend',
        at(day, 19),
        sourceId: school.id,
      );
      await back(tester);
      await selectDay(tester, state, day);
      await waitFor(tester, find.text('E2E Schule Elternabend'));
      expect(barOf(tester, 'E2E Schule Elternabend'), Color(colour));
      expect(
        find.descendant(
          of: tileOf('E2E Schule Elternabend'),
          matching: find.byTooltip('E2E Schule'),
        ),
        findsOneWidget,
      );
      await tap(tester, find.text('E2E Schule Elternabend'));
      await waitFor(
        tester,
        find.text(de.calendarSourceReadOnlyMake('E2E Schule')),
      );
      expect(editorOpen, findsNothing);
      await closeSheet(tester);

      // KAL-125: http and a private address are accepted by the app …
      await openConnect(tester);
      await subscribe(tester, 'E2E Privat', 'http://192.168.1.50/kal.ics');
      final private = engine.calendarSubscriptions.singleWhere(
        (s) => s.name == 'E2E Privat',
      );
      // … the server's answer comes in red, without appointments.
      await eventually(
        tester,
        'the error of the fetch',
        () async => engine.subscriptionStatus(private.id)?.error != null,
      );
      final error = find.descendant(
        of: listTile('E2E Privat'),
        matching: find.textContaining('HTTPS'),
      );
      await waitFor(tester, error);
      debugPrint(
        'E2E-INFO private address: ${tester.widget<Text>(error).data}',
      );
      expect(
        tester.widget<Text>(error).style?.color,
        Theme.of(tester.element(error)).colorScheme.error,
      );
      expect(engine.subscriptionStatus(private.id)?.eventCount ?? 0, 0);

      // KAL-126
      await scrollTo(tester, find.text('E2E Schule'));
      await tap(
        tester,
        find.descendant(
          of: listTile('E2E Schule'),
          matching: find.byTooltip(de.calendarFetchNow),
        ),
      );
      final told = find.descendant(
        of: find.byType(SnackBar),
        matching: find.byType(Text),
      );
      await waitFor(tester, told);
      final said = tester.widget<Text>(told.first).data!;
      debugPrint('E2E-INFO fetched now: $said');
      expect(said, contains('127.0.0.1'), reason: 'the fetch\'s error');
      await snackGone(tester);

      // KAL-129: removed, undone, removed – for everyone it was shared with.
      await eventually(
        tester,
        'Bea has the subscription',
        () async => (await pull(
          bea,
          Collections.calendarSubscriptions,
        )).containsKey(school.id),
      );
      await scrollTo(tester, find.text('E2E Schule'));
      await tap(
        tester,
        find.descendant(
          of: listTile('E2E Schule'),
          matching: find.byTooltip(de.commonRemove),
        ),
      );
      await waitFor(tester, find.text(de.commonRemoveName('E2E Schule')));
      await tap(tester, find.widgetWithText(FilledButton, de.commonRemove));
      await dialogClosed(tester);
      await waitGone(tester, find.text('E2E Schule'));
      await tap(tester, find.text(de.commonUndo));
      await waitFor(tester, find.text('E2E Schule'));
      await snackGone(tester);
      await engine.sync();
      expect(
        (await pull(
          bea,
          Collections.calendarSubscriptions,
        )).containsKey(school.id),
        isTrue,
      );
      await tap(
        tester,
        find.descendant(
          of: listTile('E2E Schule'),
          matching: find.byTooltip(de.commonRemove),
        ),
      );
      await tap(tester, find.widgetWithText(FilledButton, de.commonRemove));
      await dialogClosed(tester);
      await waitGone(tester, find.text('E2E Schule'));
      await snackGone(tester);
      await engine.sync();
      await eventually(
        tester,
        'gone for Bea',
        () async => !(await pull(
          bea,
          Collections.calendarSubscriptions,
        )).containsKey(school.id),
      );
      await finish(tester, state);
    },
  );

  // The error of a refused address is the message of RemoteUrlPolicy
  // ("Externe Ziele brauchen eine HTTPS-Adresse …"), not "Import
  // fehlgeschlagen: ApiException(…)".
  testWidgets('KAL-125 the error of a private address reads like one', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final id = await addSubscription(
      f.admin,
      'E2E Privat lesbar',
      owner: f.adminMember.id,
      url: 'http://192.168.1.50/kal.ics',
    );
    final state = await startApp(tester);
    final engine = state.engine!;
    await eventually(
      tester,
      'the fetch failed',
      () async => engine.subscriptionStatus(id)?.error != null,
    );
    final error = engine.subscriptionStatus(id)!.error!;
    debugPrint('E2E-INFO error of the subscription: $error');
    expect(error, contains('HTTPS'));
    expect(error, isNot(contains('ApiException')));
    expect(error, isNot(contains('unsafe_remote_url')));
    await finish(tester, state);
  });

  testWidgets(
    'KAL-127 KAL-128 who sees a subscription, only its owner changes it',
    (tester) async {
      final f = await setUpFamily(tester);
      final bea = await sessionOf(f.bea);
      final carl = await sessionOf(f.carl);
      final kid = await sessionOf(f.kid);
      var state = await startApp(tester);
      var engine = state.engine!;
      await openConnect(tester);
      // KAL-127
      await subscribe(
        tester,
        'E2E Nur ich',
        'https://127.0.0.1:9/nur-ich.ics',
        who: de.docsOnlyMe,
      );
      await subscribe(
        tester,
        'E2E Fuer Bea',
        'https://127.0.0.1:9/bea.ics',
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
      await waitFor(
        tester,
        find.textContaining(
          de.calendarOwnerVisibleWho(de.calendarYou, de.docsOnlyMe),
        ),
      );
      await engine.sync();
      Future<Set<String>> names(FamioApiClient api) async => {
        for (final r in (await pull(
          api,
          Collections.calendarSubscriptions,
        )).values)
          '${r.data['name']}',
      };
      await eventually(
        tester,
        'Bea gets hers only',
        () async => (await names(bea)).contains('E2E Fuer Bea'),
      );
      expect(await names(bea), isNot(contains('E2E Nur ich')));
      for (final api in [kid, carl]) {
        expect(await names(api), isNot(contains('E2E Fuer Bea')));
        expect(await names(api), isNot(contains('E2E Nur ich')));
      }
      expect(
        await names(f.admin),
        containsAll(['E2E Nur ich', 'E2E Fuer Bea']),
      );
      await finish(tester, state);

      // KAL-128: Bea sees the family's subscription of the admin …
      final family = await addSubscription(
        f.admin,
        'E2E Familienabo',
        owner: f.adminMember.id,
      );
      state = await startApp(tester, user: 'e2e-bea');
      engine = state.engine!;
      await openConnect(tester);
      await scrollTo(tester, find.text('E2E Familienabo'));
      final tile = listTile('E2E Familienabo');
      expect(
        find.descendant(of: tile, matching: find.byTooltip(de.commonRemove)),
        findsNothing,
      );
      expect(tester.widget<ListTile>(tile).onTap, isNull);
      expect(
        find.descendant(
          of: tile,
          matching: find.textContaining(
            de.calendarOwnerVisibleWho(kitAdminName, de.commonWholeFamily),
          ),
        ),
        findsOneWidget,
      );
      // … and changes nothing through the API.
      final record = (await pull(
        bea,
        Collections.calendarSubscriptions,
      ))[family]!;
      final changed = await put(bea, Collections.calendarSubscriptions, {
        family: {...record.data, 'name': 'E2E Gekapert'},
      });
      final removed = await remove(bea, Collections.calendarSubscriptions, [
        family,
      ]);
      debugPrint(
        'E2E-INFO Bea changes the admin\'s subscription: '
        'rejected=${changed.rejected.map((r) => r.id)} / '
        'removal rejected=${removed.rejected.map((r) => r.id)}',
      );
      final stays = (await pull(
        f.admin,
        Collections.calendarSubscriptions,
      ))[family];
      expect(stays?.data['name'], 'E2E Familienabo');
      await finish(tester, state);
    },
  );

  // A subscription without an owner (the admin's school holidays) is the
  // adults' (#538): the child sees no remove button
  // (CalendarSubscription.editableBy), and the server turns down its
  // renaming and removal.
  testWidgets('KAL-128 a family subscription without an owner stays the adults\'', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final kid = await sessionOf(f.kid);
    final id = await addSubscription(f.admin, 'E2E Schulferien ohne Besitzer');
    final state = await startApp(tester, user: 'e2e-kind');
    await openConnect(tester);
    await scrollTo(tester, find.text('E2E Schulferien ohne Besitzer'));
    final removable = find
        .descendant(
          of: listTile('E2E Schulferien ohne Besitzer'),
          matching: find.byTooltip(de.commonRemove),
        )
        .evaluate()
        .isNotEmpty;
    final record = (await pull(kid, Collections.calendarSubscriptions))[id]!;
    final changed = await put(kid, Collections.calendarSubscriptions, {
      id: {...record.data, 'name': 'E2E Vom Kind umbenannt'},
    });
    final afterChange = (await pull(
      f.admin,
      Collections.calendarSubscriptions,
    ))[id];
    final removed = await remove(kid, Collections.calendarSubscriptions, [id]);
    final afterRemoval = (await pull(
      f.admin,
      Collections.calendarSubscriptions,
    ))[id];
    debugPrint(
      'E2E-INFO the child and the family\'s subscription: remove button=$removable, '
      'change rejected=${changed.rejected.isNotEmpty} name=${afterChange?.data['name']}, '
      'removal rejected=${removed.rejected.isNotEmpty} still there=${afterRemoval != null}',
    );
    expect(removable, isFalse);
    expect(afterChange?.data['name'], 'E2E Schulferien ohne Besitzer');
    expect(afterRemoval, isNotNull);
    await finish(tester, state);
  });

  testWidgets('KAL-131 school holidays subscribed twice', (tester) async {
    final f = await setUpFamily(tester);
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    final state = await startVia(tester, gate.url, kitUser, kitPassword);
    final engine = state.engine!;
    await openAdmin(tester, 'Einstellungen');
    await scrollTo(
      tester,
      find.ancestor(
        of: find.text(de.adminFederalState),
        matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
      ),
    );
    await choose(tester, de.adminFederalState, 'Bayern');
    final button = find.text(de.adminSubscribeSchoolHolidaysRegion('Bayern'));
    await scrollTo(tester, button);
    // Offline from here: the server never fetches the real school holidays.
    gate.cut();
    final url = GermanState.by.schoolHolidaysUrl;
    await tap(tester, button);
    await waitFor(tester, find.textContaining('Schulferien Bayern abonniert'));
    expect(
      engine.calendarSubscriptions.where((s) => s.url == url),
      hasLength(1),
    );
    await snackGone(tester);
    await tap(tester, button);
    await waitFor(
      tester,
      find.text(de.adminSchoolHolidaysStateAlready('Bayern')),
    );
    final subs = engine.calendarSubscriptions.where((s) => s.url == url);
    expect(subs, hasLength(1), reason: 'no second subscription');
    engine.deleteCalendarSubscription(subs.single.id);
    gate.restore();
    await engine.sync();
    expect(
      (await pull(
        f.admin,
        Collections.calendarSubscriptions,
      )).values.where((r) => r.data['url'] == url),
      isEmpty,
    );
    await finish(tester, state);
  });

  testWidgets(
    'KAL-132 KAL-133 calendars shared with a member, one switched off',
    (tester) async {
      final f = await setUpFamily(tester);
      final kid = await sessionOf(f.kid);
      addTearDown(() => f.admin.setMemberCalendars(f.kid.id, const []));
      final state = await startApp(tester);
      // KAL-133: nobody shared anything with Bea yet.
      await openUser(tester, f.bea.displayName);
      await scrollTo(
        tester,
        find.text(de.memberCalendarsNone(f.bea.displayName)),
      );
      await back(tester);

      // KAL-132
      final club = await addSubscription(
        f.admin,
        'E2E Vereinskalender',
        owner: f.adminMember.id,
      );
      final own = await addSubscription(
        kid,
        'E2E Kinderkalender',
        owner: f.kid.id,
      );
      addTearDown(() => remove(kid, Collections.calendarSubscriptions, [own]));
      await tap(tester, find.text(f.kid.displayName).last);
      await waitFor(tester, find.text(de.adminRole));
      await scrollTo(
        tester,
        find.text(de.memberCalendarsShared(f.kid.displayName)),
      );
      final toggle = find.widgetWithText(SwitchListTile, 'E2E Vereinskalender');
      await scrollTo(tester, toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(
        find.widgetWithText(SwitchListTile, 'E2E Kinderkalender'),
        findsNothing,
      );
      // Switched off as the switch does (the switch itself: the next test).
      await f.admin.setMemberCalendars(f.kid.id, [club]);
      await eventually(tester, 'gone from the child\'s devices', () async {
        final subs = await pull(kid, Collections.calendarSubscriptions);
        return !subs.containsKey(club) && subs.containsKey(own);
      });
      // Bea still has it.
      expect(
        (await pull(
          await sessionOf(f.bea),
          Collections.calendarSubscriptions,
        )).containsKey(club),
        isTrue,
      );
      // The page shows it off.
      await back(tester);
      await tap(tester, find.text(f.kid.displayName).last);
      await waitFor(tester, find.text(de.adminRole));
      await scrollTo(tester, toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await finish(tester, state);
    },
  );

  // Was a Befund: the switch of a shared calendar on a member's page threw
  // "setState() callback argument returned a Future" (debug builds) and the
  // page kept showing it on.
  testWidgets('KAL-132 a shared calendar switched off on the member\'s page', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final kid = await sessionOf(f.kid);
    addTearDown(() => f.admin.setMemberCalendars(f.kid.id, const []));
    final club = await addSubscription(
      f.admin,
      'E2E Vereinskalender',
      owner: f.adminMember.id,
    );
    final state = await startApp(tester);
    await openUser(tester, f.kid.displayName);
    final toggle = find.widgetWithText(SwitchListTile, 'E2E Vereinskalender');
    await scrollTo(tester, toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    final errors = <Object>[];
    await tapGuarded(tester, toggle, errors);
    await tester.pump(const Duration(seconds: 2));
    debugPrint('E2E-INFO switching it off threw: $errors');
    await eventually(tester, 'gone from the child\'s devices', () async {
      final subs = await pull(kid, Collections.calendarSubscriptions);
      return !subs.containsKey(club);
    });
    expect(errors, isEmpty);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await finish(tester, state);
  });

  // --- Geburtstage und Feiertage -----------------------------------------------

  testWidgets(
    'KAL-134 KAL-137 birthdays in the calendar, a child\'s only for its guardians',
    (tester) async {
      final f = await setUpFamily(tester);
      final bea = await sessionOf(f.bea);
      final guest = await sessionOf(f.guest);
      final d3 = inDays(3), d4 = inDays(4), d5 = inDays(5);
      addTearDown(() => f.admin.updateMe(clearBirthday: true));
      await f.admin.updateMe(birthday: Birthday(d3.month, d3.day, 1990));
      final child = uid('child');
      await put(f.admin, Collections.children, {
        child: {
          ...Child(
            id: child,
            name: 'E2E Mila',
            birthDate: DateTime(d4.year - 6, d4.month, d4.day),
            guardianIds: [f.adminMember.id],
          ).toData(),
          SyncRecord.visibilityKey: [f.adminMember.id],
        },
      });
      final contact = uid('contact');
      await put(f.admin, Collections.contacts, {
        contact: FamilyContact(
          id: contact,
          name: 'E2E Oma Inge',
          birthday: Birthday(d5.month, d5.day, 1956),
        ).toData(),
      });

      var state = await startApp(tester);
      await openCalendar(tester);
      await selectDay(tester, state, d3);
      final mine = '🎂 $kitAdminName';
      await waitFor(tester, find.text(mine));
      expect(timeOf(tester, mine), de.commonAllDayLower);
      expect(tileHasIcon(mine, AppIcons.repeat), isFalse);
      expect(tileHasIcon(mine, AppIcons.cake), isTrue);
      expect(
        find.descendant(
          of: tileOf(mine),
          matching: find.byTooltip(de.commonBirthday),
        ),
        findsOneWidget,
      );
      await tap(tester, find.text(mine));
      await waitFor(
        tester,
        find.text(
          de.calendarWhatChangeProfileChild(
            '$kitAdminName wird ${d3.year - 1990}',
          ),
        ),
      );
      expect(editorOpen, findsNothing);
      expect(find.byIcon(AppIcons.cake), findsWidgets);
      await closeSheet(tester);
      await selectDay(tester, state, d4);
      await waitFor(tester, find.text('🎂 E2E Mila'));
      await selectDay(tester, state, d5);
      await waitFor(tester, find.text('🎂 E2E Oma Inge'));
      await finish(tester, state);

      // KAL-137: Bea gets no data of the child, the guest neither.
      expect(
        (await pull(bea, Collections.children)).containsKey(child),
        isFalse,
      );
      expect(
        (await pull(guest, Collections.children)).containsKey(child),
        isFalse,
      );
      state = await startApp(tester, user: 'e2e-gast');
      await openCalendar(tester);
      await selectDay(tester, state, d5);
      await waitFor(tester, find.text('🎂 E2E Oma Inge'));
      await selectDay(tester, state, d4);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('🎂 E2E Mila'), findsNothing);
      await finish(tester, state);
    },
  );

  testWidgets('KAL-138 public holidays by the state, also offline', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    addTearDown(() => f.admin.updateServerSettings({'holidayRegion': null}));
    final now = today();
    final allSaints = DateTime(now.year, 11, 1);
    var state = await startApp(tester);

    Future<void> setRegion(String label) async {
      await openAdmin(tester, 'Einstellungen');
      final dropdown = find.ancestor(
        of: find.text(de.adminFederalState),
        matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
      );
      await scrollTo(tester, dropdown);
      await choose(tester, de.adminFederalState, label);
      await scrollTo(tester, find.text(de.commonSave));
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, find.text(de.adminServerSettingsSaved));
      await back(tester);
      await snackGone(tester);
    }

    await setRegion('Nordrhein-Westfalen');
    await eventually(
      tester,
      'the app knows the state',
      () async => familyHolidayRegion == GermanState.nw,
    );
    await openCalendar(tester);
    await selectDay(tester, state, allSaints);
    await waitFor(tester, find.text('Allerheiligen'));
    expect(timeOf(tester, 'Allerheiligen'), de.commonAllDayLower);
    expect(barOf(tester, 'Allerheiligen'), const Color(0xFF7A8796));
    expect(
      find.descendant(
        of: tileOf('Allerheiligen'),
        matching: find.byTooltip(de.calendarPublicHoliday),
      ),
      findsOneWidget,
    );
    await tap(tester, find.text('Allerheiligen'));
    await waitFor(tester, find.text(de.calendarAdminsSetFederalState));
    expect(editorOpen, findsNothing);
    await closeSheet(tester);

    await setRegion(de.adminNoPublicHolidays);
    await eventually(
      tester,
      'no state any more',
      () async => familyHolidayRegion == null,
    );
    await openCalendar(tester);
    await selectDay(tester, state, allSaints);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Allerheiligen'), findsNothing);
    await finish(tester, state);

    // Offline: the state stays with the app.
    await f.admin.updateServerSettings({'holidayRegion': 'NW'});
    final gate = Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    state = await startVia(tester, gate.url, 'e2e-bea', kitMemberPassword);
    await eventually(
      tester,
      'Bea\'s app knows the state',
      () async => familyHolidayRegion == GermanState.nw,
    );
    gate.cut();
    familyHolidayRegion = null;
    state = await restart(tester, state);
    expect(familyHolidayRegion, GermanState.nw, reason: 'kept on the device');
    await openCalendar(tester);
    await selectDay(tester, state, allSaints);
    await waitFor(tester, find.text('Allerheiligen'));
    gate.restore();
    await finish(tester, state);
  });

  // --- Wann haben alle Zeit? ---------------------------------------------------

  /// The suggestions under [day]'s heading on the free-time page.
  List<String> slotsOn(WidgetTester tester, DateTime day) {
    final heading = find.text(dayHeading(day));
    if (heading.evaluate().isEmpty) return const [];
    final top = tester.getTopLeft(heading).dy;
    final below = [
      for (var i = -1; i < 17; i++)
        if (find.text(dayHeading(inDays(i))).evaluate().isNotEmpty)
          tester.getTopLeft(find.text(dayHeading(inDays(i)))).dy,
    ].where((y) => y > top).fold(double.infinity, math.min);
    final slot = RegExp(r'^\d\d:\d\d – \d\d:\d\d$');
    final found = <(double, String)>[];
    for (final e in find.byType(Text).evaluate()) {
      final text = (e.widget as Text).data;
      if (text == null || !slot.hasMatch(text)) continue;
      final y = (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;
      if (y > top && y < below) found.add((y, text));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, t) in found) t];
  }

  List<String> allSlots() => [
    for (final e in find.byType(Text).evaluate())
      if ((e.widget as Text).data case final t?
          when RegExp(r'^\d\d:\d\d – \d\d:\d\d$').hasMatch(t))
        t,
  ];

  testWidgets(
    'KAL-139 KAL-141 KAL-142 when everyone has time: found, other lengths, none',
    (tester) async {
      final f = await setUpFamily(tester);
      final bea = await sessionOf(f.bea);
      final tomorrow = inDays(1);
      await addEvent(
        f.admin,
        'E2E Termin Admin',
        at(tomorrow, 10),
        end: at(tomorrow, 12),
        members: [f.adminMember.id],
      );
      await addEvent(
        bea,
        'E2E Termin Bea',
        at(tomorrow, 14),
        end: at(tomorrow, 16),
        members: [f.bea.id],
      );
      final users = [for (final u in await f.admin.adminUsers()) u.member];
      final state = await startApp(tester);
      await openCalendar(tester);
      await tap(tester, find.byTooltip(de.freeTimeTitle));
      await waitFor(tester, find.text(de.freeTimeWho));
      await dismissTip(tester);

      // KAL-139: me and all adults, an hour, the day.
      for (final m in users) {
        final chip = find.widgetWithText(FilterChip, m.displayName);
        if (m.isService) {
          expect(chip, findsNothing);
          continue;
        }
        expect(
          tester.widget<FilterChip>(chip).selected,
          m.isAdult,
          reason: m.displayName,
        );
      }
      bool chosen(String label) => tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
          .selected;
      expect(chosen(de.freeTimeHours('1')), isTrue);
      expect(chosen(de.freeTimeDay), isTrue);
      // Today from the next quarter of an hour on.
      final now = DateTime.now();
      final minutes = now.hour * 60 + now.minute;
      if (minutes >= 8 * 60 && minutes < 18 * 60 + 45) {
        await scrollTo(tester, find.text(dayHeading(today())));
        final todays = slotsOn(tester, today());
        debugPrint('E2E-INFO today at ${clock(now)}: $todays');
        expect(todays, isNotEmpty);
        final first = todays.first.split(' – ').first.split(':');
        final start = at(today(), int.parse(first[0]), int.parse(first[1]));
        expect(start.minute % 15, 0);
        expect(
          start.difference(now).inMinutes,
          inInclusiveRange(-1, 15),
          reason: 'the next quarter hour',
        );
      }
      await scrollTo(tester, find.text(dayHeading(tomorrow)));
      expect(slotsOn(tester, tomorrow), [
        '08:00 – 09:00',
        '12:00 – 13:00',
        '16:00 – 17:00',
      ]);
      // A tap: the editor with this time and the chosen ones.
      final tap1200 = find.text('12:00 – 13:00');
      Element? target;
      final tomorrowTop = tester.getTopLeft(find.text(dayHeading(tomorrow))).dy;
      for (final e in tap1200.evaluate()) {
        final y = (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;
        if (y > tomorrowTop && (target == null)) target = e;
      }
      await tester.tap(find.byElementPredicate((e) => e == target));
      await tester.pump(const Duration(milliseconds: 500));
      await waitFor(tester, editorOpen);
      expect(shown(tester, de.commonStart), (buttonDate(tomorrow), '12:00'));
      expect(shown(tester, de.commonEnd), (buttonDate(tomorrow), '13:00'));
      for (final m in users) {
        if (m.isService) continue;
        final chip = find.widgetWithText(FilterChip, m.displayName);
        await scrollTo(tester, chip);
        expect(
          person(tester, m.displayName).selected,
          m.isAdult,
          reason: m.displayName,
        );
      }
      await closeEditor(tester);

      // KAL-141
      await scrollTo(
        tester,
        find.widgetWithText(ChoiceChip, de.freeTimeEvening),
        up: true,
      );
      for (final label in [
        de.cookMinutes('30'),
        de.freeTimeHours('1'),
        de.freeTimeHours('1,5'),
        de.freeTimeHours('2'),
        de.freeTimeHours('3'),
        de.freeTimeMorning,
        de.freeTimeDay,
        de.freeTimeEvening,
      ]) {
        await scrollTo(
          tester,
          find.widgetWithText(ChoiceChip, label),
          up: true,
        );
        expect(
          find.widgetWithText(ChoiceChip, label),
          findsOneWidget,
          reason: label,
        );
      }
      final three = find.widgetWithText(ChoiceChip, de.freeTimeHours('3'));
      final evenings = find.widgetWithText(ChoiceChip, de.freeTimeEvening);
      await scrollTo(tester, three, up: true);
      await tap(tester, three);
      await scrollTo(tester, evenings, up: true);
      await tap(tester, evenings);
      await scrollTo(tester, three, up: true);
      expect(chosen(de.freeTimeHours('3')), isTrue);
      await scrollTo(tester, evenings, up: true);
      expect(chosen(de.freeTimeEvening), isTrue);
      await tester.pump(const Duration(seconds: 1));
      final evening = allSlots();
      debugPrint('E2E-INFO evening slots: $evening');
      expect(evening, isNotEmpty);
      for (final s in evening) {
        final [from, to] = s.split(' – ');
        int minutes(String t) =>
            int.parse(t.split(':')[0]) * 60 + int.parse(t.split(':')[1]);
        expect(minutes(from), greaterThanOrEqualTo(17 * 60), reason: s);
        expect(minutes(to), lessThanOrEqualTo(22 * 60), reason: s);
        expect(minutes(to) - minutes(from), 180, reason: s);
      }

      // KAL-142: the admin busy every evening for weeks.
      await addEvent(
        f.admin,
        'E2E Abendkurs',
        at(today(), 17, 30),
        end: at(today(), 21, 30),
        members: [f.adminMember.id],
        recurrence: const Recurrence(RecurrenceFrequency.daily),
      );
      await waitFor(tester, find.text(de.freeTimeNone));
      expect(allSlots(), isEmpty);
      // Nobody chosen: nothing either.
      for (final m in users) {
        if (m.isService || !m.isAdult) continue;
        final chip = find.widgetWithText(FilterChip, m.displayName);
        await scrollTo(tester, chip, up: true);
        await tap(tester, chip);
      }
      for (final m in users) {
        if (m.isService) continue;
        expect(person(tester, m.displayName).selected, isFalse);
      }
      await scrollTo(
        tester,
        find.widgetWithText(ChoiceChip, de.freeTimeDay),
        up: true,
      );
      await tap(tester, find.widgetWithText(ChoiceChip, de.freeTimeDay));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(de.freeTimeNone), findsOneWidget);
      expect(allSlots(), isEmpty);
      await finish(tester, state);
    },
  );

  // --- Wochenplan (PDF) --------------------------------------------------------

  Future<String> weekPlanText(
    WidgetTester tester,
    FakePicker picker,
    String option,
  ) async {
    await tap(tester, find.byTooltip(de.weekPlanPrint));
    await waitFor(tester, find.text(de.weekPlanWhichWeek));
    await tap(tester, find.text(option));
    await waitFor(tester, find.text(de.weekPlanSaved));
    final saved = picker.saved.last;
    expect(saved.mimeType, 'application/pdf');
    final file = await tempFile(saved.fileName, saved.bytes);
    final text = await Ocr.pdfText(file.path);
    debugPrint('E2E-INFO week plan text: $text');
    expect(text, isNotNull);
    return text!;
  }

  testWidgets('KAL-143 KAL-144 the week plan as a PDF, without secrets', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final picker = fakePicker();
    final now = today();
    await addEvent(
      f.admin,
      'E2E Turnen',
      at(now, 16),
      members: [f.bea.id],
      bringer: f.carl.id,
    );
    await addEvent(
      f.admin,
      'E2E Psychotherapie',
      at(now, 10),
      members: [f.adminMember.id],
      confidential: true,
    );
    await addEvent(f.admin, 'Gelbe Tonne', now, allDay: true);
    final meal = uid('meal');
    await put(f.admin, Collections.mealPlan, {
      meal: PlannedMeal(
        id: meal,
        date: now,
        slot: MealSlot.dinner,
        title: '🍝 E2E Spaghetti',
      ).toData(),
    });
    final chore = uid('chore');
    await put(f.admin, Collections.chores, {
      chore: Chore(
        id: chore,
        title: 'E2E Blumen giessen',
        memberIds: [f.bea.id],
        start: now,
      ).toData(),
    });
    await put(f.admin, Collections.wasteSettings, {
      WasteSettings.recordId: WasteSettings(memberIds: [f.carl.id]).toData(),
    });

    final state = await startApp(tester);
    await openCalendar(tester);
    final monday = weekPlanMonday(now);
    String range(DateTime m) =>
        '${DateFormat.MMMd('de').format(m)} – '
        '${DateFormat.MMMd('de').format(DateUtils.addDaysToDate(m, 6))}';
    await tap(tester, find.byTooltip(de.weekPlanPrint));
    await waitFor(tester, find.text(de.weekPlanWhichWeek));
    expect(find.text(de.weekPlanThisWeekOption), findsOneWidget);
    expect(find.text(range(monday)), findsOneWidget);
    expect(find.text(de.weekPlanNextWeekOption), findsOneWidget);
    expect(
      find.text(range(DateUtils.addDaysToDate(monday, 7))),
      findsOneWidget,
    );
    expect(find.text(de.weekPlanSelectedWeek), findsNothing);
    await closeSheet(tester);
    // Another day chosen: its week as well.
    final later = inDays(21);
    await selectDay(tester, state, later);
    await tap(tester, find.byTooltip(de.weekPlanPrint));
    await waitFor(tester, find.text(de.weekPlanSelectedWeek));
    expect(find.text(range(weekPlanMonday(later))), findsOneWidget);
    await closeSheet(tester);
    await tap(tester, find.byTooltip(de.commonToday));

    final text = await weekPlanText(tester, picker, de.weekPlanThisWeekOption);
    expect(
      picker.saved.last.fileName,
      'famio-plan-${DateFormat('yyyy-MM-dd').format(monday)}.pdf',
    );
    String plain(String s) => s.replaceAll(RegExp(r'\s+'), ' ');
    final flat = plain(text);
    expect(flat, contains('E2E Turnen'));
    expect(flat, contains('16:00'));
    expect(flat, contains(f.bea.displayName));
    expect(flat, contains(plain(de.weekPlanBrings(f.carl.displayName))));
    expect(flat, contains('E2E Spaghetti'));
    expect(flat, contains('E2E Blumen giessen'));
    // KAL-144
    expect(flat, contains('Belegt'));
    expect(flat, isNot(contains('Psychotherapie')));
    expect('Gelbe Tonne'.allMatches(flat), hasLength(1));
    expect(flat, isNot(contains('🍝')));
    await finish(tester, state);
  });

  // Was a Befund (Hinweis KAL-144, #519): an appointment only the admin
  // sees (an audience, as from a private calendar) was printed with its
  // title on the plan for the fridge. Now it says "Belegt", as the wall
  // display does.
  testWidgets('KAL-144 a private calendar\'s appointment on the week plan', (
    tester,
  ) async {
    final f = await setUpFamily(tester);
    final picker = fakePicker();
    final now = today();
    final private = await addEvent(
      f.admin,
      'E2E Privattermin',
      at(now, 12),
      visibleTo: [f.adminMember.id],
    );
    expect(
      (await pull(
        await sessionOf(f.bea),
        Collections.events,
      )).containsKey(private),
      isFalse,
      reason: 'only the admin sees it',
    );
    final state = await startApp(tester);
    await openCalendar(tester);
    final text = await weekPlanText(tester, picker, de.weekPlanThisWeekOption);
    expect(text, isNot(contains('E2E Privattermin')));
    expect(text, contains(de.eventBusy));
    await finish(tester, state);
  });

  // --- Stundenplan und Schulranzen ---------------------------------------------

  Finder cellOf(int weekday, int period) => find.byWidgetPredicate(
    (w) =>
        _is(w, '_Cell') &&
        (w as dynamic).place ==
            de.timetableLesson(weekdayShort(weekday), period),
  );

  Future<void> fillCell(
    WidgetTester tester,
    int weekday,
    int period, {
    String? subject,
    String? chip,
    String room = '',
    String bring = '',
  }) async {
    await tap(tester, cellOf(weekday, period));
    await waitFor(
      tester,
      find.text(de.timetableLesson(weekdayShort(weekday), period)),
    );
    if (chip != null) {
      await tap(tester, inDialog(find.widgetWithText(ActionChip, chip)));
    } else {
      await enter(tester, field(de.timetableSubject), subject!);
    }
    if (room.isNotEmpty) {
      await enter(tester, field(de.timetableRoomOptional), room);
    }
    if (bring.isNotEmpty) await enter(tester, field(de.timetableBring), bring);
    await leaveField(tester);
    await tap(tester, inDialog(find.text(de.commonSave)));
    await dialogClosed(tester);
  }

  testWidgets(
    'KAL-146 KAL-147 KAL-148 KAL-149 timetable, period times, cleared lesson, the school bag',
    (tester) async {
      final f = await setUpFamily(tester);
      final now = today();
      final tom = uid('child'), ben = uid('child');
      await put(f.admin, Collections.children, {
        tom: {
          ...Child(
            id: tom,
            name: 'E2E Tom',
            birthDate: DateTime(now.year - 7, 3, 4),
            guardianIds: [f.adminMember.id],
          ).toData(),
          SyncRecord.visibilityKey: [f.adminMember.id],
        },
        ben: {
          ...Child(
            id: ben,
            name: 'E2E Ben',
            birthDate: DateTime(now.year - 3, 5, 6),
            guardianIds: [f.adminMember.id],
          ).toData(),
          SyncRecord.visibilityKey: [f.adminMember.id],
        },
      });
      final tomorrow = inDays(1);
      await addEvent(f.admin, 'Wandertag E2E Tom', tomorrow, allDay: true);
      await addEvent(
        f.admin,
        'Arzt E2E Tom',
        at(tomorrow, 9),
        members: [f.adminMember.id],
        confidential: true,
      );
      final state = await startApp(tester);
      final engine = state.engine!;

      // KAL-146: younger children have no timetable.
      await openSection(tester, 'Kinder');
      await scrollTo(tester, find.text('E2E Ben'));
      await tap(tester, find.text('E2E Ben'));
      await waitFor(tester, find.byType(ChildScreen));
      await dismissTip(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(de.commonTimetable), findsNothing);
      await back(tester);
      await scrollTo(tester, find.text('E2E Tom'));
      await tap(tester, find.text('E2E Tom'));
      await waitFor(tester, find.byType(ChildScreen));
      await dismissTip(tester);
      await tap(tester, find.text(de.commonTimetable));
      await waitFor(tester, cellOf(1, 1));
      for (var d = 1; d <= 5; d++) {
        expect(find.text(weekdayShort(d)), findsWidgets);
      }
      for (var p = 1; p <= 6; p++) {
        expect(find.text('$p.'), findsOneWidget);
      }
      expect(find.text('7.'), findsNothing);
      await fillCell(tester, 1, 1, subject: 'Mathe', room: '12');
      await fillCell(tester, 2, 1, chip: 'Mathe');
      for (final d in [1, 2]) {
        expect(
          find.descendant(of: cellOf(d, 1), matching: find.text('Mathe')),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(of: cellOf(1, 1), matching: find.text('12')),
        findsOneWidget,
      );
      Color? colourOf(int d, int p) => tester
          .widget<Material>(
            find
                .descendant(of: cellOf(d, p), matching: find.byType(Material))
                .first,
          )
          .color;
      expect(colourOf(1, 1), colourOf(2, 1));
      expect(colourOf(1, 1), isNot(colourOf(3, 1)));

      // KAL-147
      await tap(tester, find.text('1.'));
      await typeTime(tester, 7, 55, close: false);
      await typeTime(tester, 8, 40);
      await waitFor(tester, find.text('07:55'));
      await tap(tester, find.text('1.'));
      await typeTime(tester, 8, 0, close: false);
      await typeTime(tester, 8, 45);
      await waitFor(tester, find.text('08:00'));
      expect(find.text('07:55'), findsNothing);
      expect(engine.timetable(tom)!.periods.first.start, '08:00');
      expect(engine.timetable(tom)!.periods.first.end, '08:45');

      // KAL-149: Sport tomorrow, with its things.
      final weekday = tomorrow.weekday;
      if (weekday <= DateTime.friday) {
        await fillCell(
          tester,
          weekday,
          3,
          subject: 'Sport',
          bring: 'Sportzeug',
        );
        final subjects = [if (weekday <= 2) 'Mathe', 'Sport'];
        await scrollTo(tester, find.text(de.timetableForTomorrow));
        final expected = [
          subjects.join(', '),
          de.schoolBagBring('Sportzeug'),
          'Wandertag E2E Tom',
        ].join(' · ');
        expect(find.text(expected), findsOneWidget, reason: onScreen());
        expect(find.textContaining('Arzt'), findsNothing);
        await scrollTo(tester, cellOf(1, 1), up: true);
      } else {
        debugPrint('E2E-INFO tomorrow is no school day: KAL-149 not checked');
      }

      // KAL-148
      await tap(tester, cellOf(1, 1));
      await waitFor(tester, inDialog(find.text(de.settingsStorageClear)));
      await tap(tester, inDialog(find.text(de.settingsStorageClear)));
      await dialogClosed(tester);
      expect(
        find.descendant(of: cellOf(1, 1), matching: find.byIcon(AppIcons.plus)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cellOf(1, 1), matching: find.text('Mathe')),
        findsNothing,
      );
      await finish(tester, state);
    },
  );

  // --- Abfallkalender ----------------------------------------------------------

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

  testWidgets(
    'KAL-152 KAL-154 KAL-155 KAL-156 the bins: found, from a calendar, subscribed, in turns',
    (tester) async {
      final f = await setUpFamily(tester);
      final state = await startApp(tester);
      final engine = state.engine!;
      final date = DateFormat.MMMEd('de');

      // KAL-152: nothing yet.
      await openWaste(tester);
      expect(groupValue(tester), isNull, reason: '"Automatisch erkennen"');
      await scrollTo(tester, find.text(de.wasteNoCollectionFoundNext));
      final yellow = inDays(2), rest = inDays(5);
      await addEvent(f.admin, 'Gelbe Tonne', yellow, allDay: true);
      await addEvent(f.admin, 'Restmüll', rest, allDay: true);
      // Paper every week from tomorrow: more pickups than are shown.
      await addEvent(
        f.admin,
        'Altpapier',
        inDays(1),
        allDay: true,
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
      );
      await scrollTo(tester, find.text('🟡 Gelbe Tonne'));
      expect(
        find.descendant(
          of: listTile('🟡 Gelbe Tonne'),
          matching: find.text(date.format(yellow)),
        ),
        findsOneWidget,
      );
      await scrollTo(tester, find.text('⚫ Restmüll'));
      expect(
        find.descendant(
          of: listTile('⚫ Restmüll'),
          matching: find.text(date.format(rest)),
        ),
        findsOneWidget,
      );
      // At most eight, the next two months.
      for (var i = 0; i < 10; i++) {
        await tester.dragFrom(const Offset(600, 1000), const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byIcon(AppIcons.recycle), findsNWidgets(8));
      expect(engine.wasteConfigured, isFalse);
      await scrollTo(tester, find.text(de.wasteTurnReminders), up: true);
      await tap(tester, find.text(de.wasteTurnReminders));
      await eventually(
        tester,
        'switched on',
        () async => engine.wasteConfigured,
      );
      expect(find.text(de.wasteTurnReminders), findsNothing);

      // KAL-154: one calendar of the bins.
      final tours = await addSubscription(
        f.admin,
        'E2E Entsorger',
        owner: f.adminMember.id,
      );
      final tourDay = inDays(3);
      await addEvent(f.admin, 'Tour 3', tourDay, allDay: true, sourceId: tours);
      final choice = find.widgetWithText(
        RadioListTile<String?>,
        'E2E Entsorger',
      );
      await scrollTo(tester, choice, up: true);
      await tap(tester, choice);
      await eventually(
        tester,
        'chosen',
        () async => engine.wasteSettings.sourceId == tours,
      );
      await scrollTo(tester, find.text('🗑️ Abholung'));
      expect(
        find.descendant(
          of: listTile('🗑️ Abholung'),
          matching: find.text(date.format(tourDay)),
        ),
        findsOneWidget,
      );
      expect(find.text('🟡 Gelbe Tonne'), findsNothing);
      expect(find.text('⚫ Restmüll'), findsNothing);

      // KAL-155
      await scrollTo(tester, find.text(de.wasteSubscribe), up: true);
      await tap(tester, find.text(de.wasteSubscribe));
      await enter(
        tester,
        field(de.wasteCalendarAddressIcs),
        'https://127.0.0.1:9/e2e-abfall.ics',
      );
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.wasteSubscribe2)));
      await dialogClosed(tester);
      final added = engine.calendarSubscriptions.singleWhere(
        (s) => s.name == de.settingsWaste,
      );
      expect(added.url, 'https://127.0.0.1:9/e2e-abfall.ics');
      await eventually(
        tester,
        'the new one is chosen',
        () async => engine.wasteSettings.sourceId == added.id,
      );
      expect(groupValue(tester), added.id);
      expect(
        find.widgetWithText(RadioListTile<String?>, de.settingsWaste),
        findsOneWidget,
      );

      // KAL-156
      await tap(
        tester,
        find.widgetWithText(
          RadioListTile<String?>,
          de.wasteDetectAutomatically,
        ),
      );
      await eventually(
        tester,
        'automatic again',
        () async => engine.wasteSettings.sourceId == null,
      );
      final turns = find.widgetWithText(
        SwitchListTile,
        de.wasteTakeTurnsWeekly,
      );
      await scrollTo(tester, find.widgetWithText(FilterChip, kitAdminName));
      expect(find.text(de.wasteNobodyChosenAllAdults), findsOneWidget);
      await tap(tester, find.widgetWithText(FilterChip, kitAdminName));
      await waitFor(tester, find.text(de.wasteOnlyThoseChosenReminded));
      expect(tester.widget<SwitchListTile>(turns).onChanged, isNull);
      await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
      await eventually(
        tester,
        'two chosen',
        () async => engine.wasteSettings.memberIds.length == 2,
      );
      expect(tester.widget<SwitchListTile>(turns).onChanged, isNotNull);
      await tap(tester, turns);
      await eventually(
        tester,
        'in turns',
        () async => engine.wasteSettings.rotate,
      );
      String nameOf(DateTime day) => engine
          .member(engine.wasteSettings.responsibleFor(day).single)!
          .displayName;
      final week1 = inDays(1), week2 = inDays(8);
      expect(nameOf(week1), isNot(nameOf(week2)));
      for (final d in [week1, week2]) {
        final line = find.text('${date.format(d)} · ${nameOf(d)}');
        await scrollTo(tester, line);
        expect(line, findsOneWidget);
      }
      // The tile on "Start" for tomorrow's paper.
      await openSection(tester, 'Start');
      await waitFor(tester, find.text(de.homeBins));
      final who = engine.wasteSettings.responsibleFor(week1).single;
      await waitFor(
        tester,
        find.text(
          who == f.adminMember.id
              ? de.homeSTurn
              : de.homeNamesSTurn(f.bea.displayName),
        ),
      );
      await finish(tester, state);
    },
  );

  testWidgets('KAL-158 the bins for a child and a guest', (tester) async {
    final f = await setUpFamily(tester);
    await put(f.admin, Collections.wasteSettings, {
      WasteSettings.recordId: WasteSettings(memberIds: [f.bea.id]).toData(),
    });
    await addEvent(f.admin, 'Gelbe Tonne', inDays(2), allDay: true);
    var state = await startApp(tester, user: 'e2e-kind');
    await openWaste(tester);
    expect(find.text(de.sosOnlyAdultsCanChange), findsOneWidget);
    await scrollTo(tester, find.text('🟡 Gelbe Tonne'));
    for (final r in tester.widgetList<RadioListTile<String?>>(
      find.byType(RadioListTile<String?>),
    )) {
      expect(r.enabled, isFalse);
    }
    for (final c in tester.widgetList<FilterChip>(find.byType(FilterChip))) {
      expect(c.onSelected, isNull);
    }
    expect(switchOf(tester, de.wasteTakeTurnsWeekly).onChanged, isNull);
    expect(
      tester
          .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
          .onChanged,
      isNull,
    );
    expect(find.text(de.wasteTurnReminders), findsNothing);
    expect(find.text(de.wasteSubscribe), findsNothing);
    await finish(tester, state);

    state = await startApp(tester, user: 'e2e-gast');
    await openSection(tester, 'Einstellungen');
    expect(await seenOnPage(tester, find.text(de.settingsWaste)), isFalse);
    await finish(tester, state);
  });

  // --- Home Assistant und Kalender-API -----------------------------------------

  testWidgets(
    'KAL-166 KAL-167 the calendar API and the overview for Home Assistant',
    (tester) async {
      final f = await setUpFamily(tester);
      final ha = await sessionOf(await theService());
      final school = await addSubscription(
        f.admin,
        'E2E Schulabo',
        owner: f.adminMember.id,
      );
      final series = await addEvent(
        f.admin,
        'E2E Serie HA',
        at(inDays(1), 17),
        recurrence: const Recurrence(RecurrenceFrequency.weekly),
      );
      final fromSchool = await addEvent(
        f.admin,
        'E2E Abo HA',
        at(inDays(3), 8),
        sourceId: school,
      );
      final secret = await addEvent(
        f.admin,
        'E2E Arzt HA',
        at(inDays(2), 9),
        members: [f.adminMember.id],
        confidential: true,
        location: 'Praxis Dr. E2E',
        notes: 'E2E Befund',
        countdown: true,
      );
      await put(f.admin, Collections.wasteSettings, {
        WasteSettings.recordId: WasteSettings(memberIds: [f.bea.id]).toData(),
      });
      final bins = inDays(3);
      await addEvent(f.admin, 'Gelbe Tonne', bins, allDay: true);
      final state = await startApp(tester);
      final base = Uri.parse(kitUrl);

      // KAL-166
      final from = dayKey(today()), to = dayKey(inDays(30));
      final (status, body) = await fetch(
        base.resolve('api/calendar/occurrences?from=$from&to=$to').toString(),
        headers: ha.authHeaders,
      );
      expect(status, 200, reason: body);
      final occurrences = [
        for (final o in (jsonDecode(body) as Map)['occurrences'] as List)
          (o as Map).cast<String, Object?>(),
      ];
      final ofSeries = occurrences.where((o) => o['id'] == series).toList();
      expect(ofSeries.length, greaterThanOrEqualTo(4), reason: 'expanded');
      expect(ofSeries.every((o) => o['recurring'] == true), isTrue);
      expect({
        for (final o in ofSeries) o['start'],
      }, hasLength(ofSeries.length));
      final abo = occurrences.singleWhere((o) => o['id'] == fromSchool);
      expect(abo['readOnly'], isTrue);
      expect(abo['calendar'], 'E2E Schulabo');
      final hidden = occurrences.singleWhere((o) => o['id'] == secret);
      expect(hidden['confidential'], isTrue);
      expect(hidden['title'], '');
      expect(hidden['location'], '');
      expect(hidden['notes'], '');
      expect(body, isNot(contains('E2E Arzt HA')));
      expect(body, isNot(contains('Praxis Dr. E2E')));
      expect(body, isNot(contains('E2E Befund')));
      final (tooLong, tooLongBody) = await fetch(
        base
            .resolve(
              'api/calendar/occurrences?from=$from&to=${dayKey(inDays(401))}',
            )
            .toString(),
        headers: ha.authHeaders,
      );
      expect(tooLong, 400);
      expect(
        tooLongBody,
        contains('Zeitraum angeben (from, to; höchstens 400 Tage)'),
      );

      // KAL-167
      final (ok, overviewBody) = await fetch(
        base.resolve('api/overview').toString(),
        headers: ha.authHeaders,
      );
      expect(ok, 200, reason: overviewBody);
      final overview = (jsonDecode(overviewBody) as Map)
          .cast<String, Object?>();
      final countdown = [
        for (final c in overview['countdowns'] as List)
          (c as Map).cast<String, Object?>(),
      ].singleWhere((c) => c['id'] == secret);
      expect(countdown['title'], 'Belegt');
      expect(countdown['days'], 2);
      final waste = [
        for (final w in overview['waste'] as List)
          (w as Map).cast<String, Object?>(),
      ].singleWhere((w) => w['day'] == dayKey(bins));
      expect(waste['kinds'], ['packaging']);
      expect(waste['days'], 3);
      expect(waste['memberIds'], [f.bea.id]);
      expect(overviewBody, isNot(contains('E2E Arzt HA')));
      await finish(tester, state);
    },
  );
}
