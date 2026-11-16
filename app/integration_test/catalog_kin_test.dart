// Catalog tests of the area "Kinder und Gesundheit" (KIN) in the real app
// against a throwaway server (one per run of this file):
//
//   tool/integration_tests.sh macos integration_test/catalog_kin_test.dart
//
// One test per catalog entry or small group of entries; the name begins
// with the ids. What a person does goes through the app's own pages; what
// another device, member or account does goes through the API. The file
// picker is replaced at its plugin boundary (the test hands in the picture
// a person would have picked). Tests run in order and share the server:
// the ones that need an empty list (no medications, no children for the
// child account) come first.
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
import 'package:famio/src/data/health_logic.dart';
import 'package:famio/src/data/kids_logic.dart';
import 'package:famio/src/data/pregnancy_logic.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/format.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/kids_log_screens.dart';
import 'package:famio/src/screens/kids_screens.dart';
import 'package:famio/src/screens/pregnancy_screens.dart';
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
class _FakePicker extends FilePickerPlatform {
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

/// No connection to anywhere: every new HTTP client goes to a proxy that
/// refuses (the server is out of reach, as without network).
class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'PROXY 127.0.0.1:9';
}

/// Passes TCP between the app and the throwaway server. While [cutUploads]
/// is on, a connection that carries an upload (POST /api/files) is broken
/// off after [cutAfter] bytes of it, like a network that drops mid-way;
/// everything else (sync, WebSocket) goes on.
class _CuttingGate {
  _CuttingGate(this._upstream);

  final Uri _upstream;
  late final ServerSocket _server;
  var cutUploads = false;
  var cutAfter = 512 * 1024;

  /// Uploads broken off so far.
  var cut = 0;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_accept);
  }

  Future<void> _accept(Socket client) async {
    unawaited(client.done.catchError((Object _) {}));
    final Socket server;
    try {
      server = await Socket.connect(_upstream.host, _upstream.port);
    } catch (_) {
      client.destroy();
      return;
    }
    unawaited(server.done.catchError((Object _) {}));
    void close() {
      client.destroy();
      server.destroy();
    }

    // The last bytes seen, so a request line split across reads is found.
    var tail = '';
    int? uploadBytes;
    client.listen(
      (data) {
        if (uploadBytes == null && cutUploads) {
          final seen = tail + latin1.decode(data, allowInvalid: true);
          final at = seen.indexOf('POST /api/files');
          if (at >= 0) uploadBytes = seen.length - at;
          tail = seen.substring(math.max(0, seen.length - 64));
        } else if (uploadBytes != null) {
          uploadBytes = uploadBytes! + data.length;
        }
        if (uploadBytes != null && uploadBytes! >= cutAfter) {
          cut++;
          debugPrint(
            'E2E-INFO gate: upload broken off after $uploadBytes bytes',
          );
          close();
          return;
        }
        try {
          server.add(data);
        } catch (_) {
          close();
        }
      },
      onDone: close,
      onError: (Object _) => close(),
      cancelOnError: true,
    );
    server.listen(
      (data) {
        try {
          client.add(data);
        } catch (_) {
          close();
        }
      },
      onDone: close,
      onError: (Object _) => close(),
      cancelOnError: true,
    );
  }

  Future<void> close() => _server.close();
}

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // --- seeds: what another device of the admin writes ---------------------

  final audience = <String, List<String>>{};

  Future<FamioApiClient> adminApi() async => (await theFamily()).admin;
  Future<String> adminId() async => (await theFamily()).adminMember.id;

  DateTime born({int years = 0, int months = 0, int days = 0}) {
    final t = today();
    return DateTime(t.year - years, t.month - months, t.day - days);
  }

  DateTime ago(Duration d) => DateTime.now().subtract(d);

  Future<void> seed(
    FamioApiClient api,
    String collection,
    Map<String, Map<String, Object?>> records,
  ) async {
    final answer = await put(api, collection, records);
    expect(
      answer.rejected.map((r) => r.id),
      isEmpty,
      reason: 'seed of $collection',
    );
  }

  Future<String> seedChild(
    String name,
    DateTime birth, {
    ChildSex? sex,
    List<String>? guardians,
    EmergencyInfo emergency = const EmergencyInfo(),
  }) async {
    final g = guardians ?? [await adminId()];
    final id = uid('child');
    audience[id] = g;
    await seed(await adminApi(), Collections.children, {
      id: {
        ...Child(
          id: id,
          name: name,
          birthDate: birth,
          guardianIds: g,
          sex: sex,
          emergency: emergency,
        ).toData(),
        SyncRecord.visibilityKey: g,
      },
    });
    return id;
  }

  Future<void> seedLogs(List<ChildLog> logs) async {
    await seed(await adminApi(), Collections.childLogs, {
      for (final l in logs)
        l.id: {...l.toData(), SyncRecord.visibilityKey: audience[l.childId]},
    });
  }

  Future<void> seedEntries(List<ChildEntry> entries) async {
    await seed(await adminApi(), Collections.childEntries, {
      for (final e in entries)
        e.id: {...e.toData(), SyncRecord.visibilityKey: audience[e.childId]},
    });
  }

  Future<ChildLog> logOf(
    String childId,
    LogKind kind,
    DateTime start, {
    DateTime? end,
    BreastSide? side,
    MilkKind? milk,
    int? amountMl,
    DrinkKind? drink,
    DiaperKind? diaper,
    double? temperatureC,
    String medication = '',
    String dose = '',
    double? minIntervalHours,
  }) async => ChildLog(
    id: uid('log'),
    childId: childId,
    kind: kind,
    start: start,
    end: end,
    side: side,
    milk: milk,
    amountMl: amountMl,
    drink: drink,
    diaper: diaper,
    temperatureC: temperatureC,
    medication: medication,
    dose: dose,
    minIntervalHours: minIntervalHours,
    by: await adminId(),
  );

  Future<String> seedPregnancy(
    String name,
    DateTime due, {
    List<String>? guardians,
  }) async {
    final g = guardians ?? [await adminId()];
    final id = uid('pregnancy');
    await seed(await adminApi(), Collections.pregnancies, {
      id: {
        ...Pregnancy(id: id, dueDate: due, name: name, guardianIds: g).toData(),
        SyncRecord.visibilityKey: g,
      },
    });
    return id;
  }

  Future<String> seedMedication(
    String name, {
    List<String> times = const [],
    List<String>? care,
    String personName = '',
    String dose = '',
    double? stock,
  }) async {
    final id = uid('med');
    await seed(await adminApi(), Collections.medications, {
      id: Medication(
        id: id,
        name: name,
        personName: personName,
        dose: dose,
        times: times,
        start: today(),
        careIds: care ?? [await adminId()],
        stock: stock,
        stockAt: stock == null ? null : DateTime.now(),
      ).toData(),
    });
    return id;
  }

  /// The service account (Home Assistant), created once.
  Future<FamilyMember>? service;
  Future<FamilyMember> serviceAccount() => service ??= () async {
    final api = await adminApi();
    for (final u in await api.adminUsers()) {
      if (u.member.username == 'e2e-dienst') return u.member;
    }
    return api.createMember(
      username: 'e2e-dienst',
      displayName: 'E2E Dienst',
      password: kitMemberPassword,
      role: MemberRole.service,
    );
  }();

  // --- the app ---------------------------------------------------------------

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

  Future<void> synced(WidgetTester tester, AppState state) async {
    await state.engine!.sync();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Waits for what another device wrote.
  Future<void> arrives(
    WidgetTester tester,
    AppState state,
    bool Function(SyncEngine engine) ok,
    String what,
  ) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (!ok(state.engine!)) {
      if (DateTime.now().isAfter(end)) throw TestFailure('Timed out: $what');
      await state.engine!.sync();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  Finder byTypeName(String name) =>
      find.byWidgetPredicate((w) => w.runtimeType.toString() == name);
  final pillTabs = find.byWidgetPredicate(
    (w) => w.runtimeType.toString().startsWith('PillTabs<'),
  );
  String selectedTab(WidgetTester tester) {
    final w = tester.widget(pillTabs.first) as dynamic;
    return w.label(w.selected) as String;
  }

  List<String> tabLabels(WidgetTester tester) {
    final w = tester.widget(pillTabs.first) as dynamic;
    return [for (final v in w.values as List) w.label(v) as String];
  }

  Future<void> tab(WidgetTester tester, String label) => tap(
    tester,
    find.descendant(of: pillTabs.first, matching: find.text(label)),
  );

  Finder saveButton(String label) =>
      find.byWidgetPredicate((w) => w is ColorButton && w.label == label);
  bool enabled(WidgetTester tester, Finder button) =>
      (tester.widget(button.first) as dynamic).onPressed != null;

  Finder sheet() => find.byType(BottomSheet);
  Finder inSheet(Finder f) => find.descendant(of: sheet(), matching: f);

  /// Closes the open sheet and waits until it is gone (a field of a sheet
  /// still sliding out is no field to type into).
  Future<void> closeSheet(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump(const Duration(milliseconds: 300));
    await waitGone(tester, sheet(), timeout: const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Finder snackText(String text) =>
      find.descendant(of: find.byType(SnackBar), matching: find.text(text));
  Future<void> undo(WidgetTester tester) => tap(
    tester,
    find.descendant(
      of: find.byType(SnackBar),
      matching: find.text('Rückgängig'),
    ),
  );

  /// Back on the list of medications (its heading "Alle Medikamente" may be
  /// far below the doses of the day, so not built): its add button shows.
  Future<void> medsList(WidgetTester tester) =>
      waitFor(tester, find.byTooltip(de.medsAddMedication));

  /// The medication's card under "Alle Medikamente" (dose tiles show the
  /// name as well, but cannot be tapped).
  /// No `.first`: that throws while the card is not built yet (long list).
  Finder medCard(String name) => find.ancestor(
    of: find.text(name),
    matching: find.byWidgetPredicate((w) => w is SoftCard && w.onTap != null),
  );

  /// The card (check-up, vaccination, task …) titled [title].
  Finder inCard(String title, Finder what) =>
      find.descendant(of: cardOf(title), matching: what);

  Future<void> expectStatus(
    WidgetTester tester,
    String title,
    String status,
  ) async {
    await scrollTo(tester, find.text(title));
    expect(
      inCard(title, find.text(status)),
      findsOneWidget,
      reason: '$title: $status',
    );
  }

  Future<void> tickCard(WidgetTester tester, String title) async {
    await scrollTo(tester, find.text(title));
    await tap(tester, inCard(title, find.byType(RoundCheck)));
  }

  Future<void> kidsList(WidgetTester tester) async {
    await openSection(tester, 'Kinder');
    if (find.byType(KidsScreen).evaluate().isEmpty) {
      await openSection(tester, 'Kinder');
    }
    await waitFor(tester, find.byType(KidsScreen));
  }

  /// The list of children grows with every test: from its top down until
  /// [finder] shows.
  Future<void> inKidsList(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await tester.dragFrom(const Offset(600, 300), const Offset(0, 500));
      await tester.pump(const Duration(milliseconds: 150));
    }
    for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
      await tester.dragFrom(const Offset(600, 450), const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await waitFor(tester, finder, timeout: const Duration(seconds: 3));
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openChild(WidgetTester tester, String name) async {
    await kidsList(tester);
    await inKidsList(tester, find.text(name));
    await tap(tester, find.text(name));
    await waitFor(tester, find.byType(ChildScreen));
  }

  Future<void> openPregnancy(WidgetTester tester, String name) async {
    await kidsList(tester);
    await inKidsList(tester, find.text(name));
    await tap(tester, find.text(name));
    await waitFor(tester, find.byType(PregnancyScreen));
  }

  /// A quick button of the daily log.
  Finder quickButton(String label) => find.ancestor(
    of: find.descendant(
      of: byTypeName('_QuickButtons'),
      matching: find.text(label),
    ),
    matching: find.byType(InkWell),
  );

  Future<void> tapQuick(WidgetTester tester, String label) async {
    await scrollTo(tester, quickButton(label), up: true);
    await tap(tester, quickButton(label));
  }

  /// A chart of the growth tab by its title (scrolled into view).
  Future<dynamic> chartCard(WidgetTester tester, String title) async {
    final card = find.byWidgetPredicate(
      (w) =>
          w.runtimeType.toString() == '_ChartCard' &&
          (w as dynamic).title == title,
    );
    await scrollTo(tester, card, up: true);
    return tester.widget(card) as dynamic;
  }

  /// Room for the sheets: the default window (800 × 600) is lower than a
  /// phone; see the test of the check-up sheet for what happens there.
  void tallView(WidgetTester tester) {
    final dpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = Size(800 * dpr, 760 * dpr);
    addTearDown(tester.view.resetPhysicalSize);
  }

  /// Signs in like [startApp], in a view tall enough for the sheets.
  Future<AppState> start(WidgetTester tester, {String? user}) {
    tallView(tester);
    return startApp(tester, user: user);
  }

  /// Like [start] as the admin, but through [url] (e.g. a [_CuttingGate]).
  Future<AppState> startVia(WidgetTester tester, String url) async {
    tallView(tester);
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
    await enter(tester, field('Benutzername'), kitUser);
    await enter(tester, field('Passwort'), kitPassword);
    await tap(tester, find.text('Anmelden'));
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    if (find.text(de.commonLater).evaluate().isNotEmpty) {
      await tap(tester, find.text(de.commonLater).last);
    }
    return state;
  }

  /// Types [date] into an open date picker; whether the picker accepted it.
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

  /// The Material time picker, typed in (24 hours).
  Future<void> pickTime(WidgetTester tester, int hour, int minute) async {
    await waitFor(tester, find.byType(Dialog));
    final keyboard = find.descendant(
      of: find.byType(Dialog),
      matching: find.byIcon(Icons.keyboard_outlined),
    );
    if (keyboard.evaluate().isNotEmpty) await tap(tester, keyboard);
    final fields = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextField),
    );
    await waitFor(tester, fields);
    await tester.enterText(fields.at(0), '$hour');
    await tester.pump();
    await tester.enterText(fields.at(1), minute.toString().padLeft(2, '0'));
    await tester.pump();
    await tester.tap(find.text('OK').last, warnIfMissed: false);
    await dialogClosed(tester);
  }

  /// The medication editor: a time through the clock dialog.
  Future<void> addTime(WidgetTester tester, int hour, int minute) async {
    final chip = find.widgetWithText(ActionChip, de.commonTime);
    await scrollTo(tester, chip);
    await tap(tester, chip);
    await pickTime(tester, hour, minute);
  }

  _FakePicker fakePicker() {
    final before = FilePickerPlatform.instance;
    final fake = _FakePicker();
    FilePickerPlatform.instance = fake;
    addTearDown(() => FilePickerPlatform.instance = before);
    return fake;
  }

  /// A picture; [big] ones (noise, about 9 MB) take a while to upload.
  Future<File> picture(String name, {bool big = false}) async {
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
        Paint()..color = const Color(0xFFD1683D),
      );
      image = await recorder.endRecording().toImage(64, 64);
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}/famio-e2e-kin',
    )..createSync(recursive: true);
    return File('${dir.path}/$name')
      ..writeAsBytesSync(data!.buffer.asUint8List());
  }

  /// Taps [button] that uploads a picked picture and watches for the busy
  /// state; whether [save] was disabled meanwhile.
  Future<bool> uploadWatchingSave(
    WidgetTester tester,
    Finder button,
    Finder save,
    bool Function() done, {
    Finder? spinner,
    void Function()? sawSpinner,
  }) async {
    await waitFor(tester, button);
    await tester.ensureVisible(button.first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(button.first, warnIfMissed: false);
    var blocked = false;
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (!done() && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 5));
      if (save.evaluate().isNotEmpty && !enabled(tester, save)) blocked = true;
      if (spinner != null && spinner.evaluate().isNotEmpty) sawSpinner?.call();
    }
    expect(done(), isTrue, reason: 'upload finished');
    await tester.pump(const Duration(milliseconds: 300));
    return blocked;
  }

  /// The value shown above [label] in the day's (or period's) totals.
  String? summaryValue(WidgetTester tester, String label) {
    final card = byTypeName('_SummaryCard');
    final l = find.descendant(of: card.first, matching: find.text(label));
    if (l.evaluate().isEmpty) return null;
    final column = find.ancestor(of: l.first, matching: find.byType(Column));
    return tester
        .widget<Text>(
          find.descendant(of: column.first, matching: find.byType(Text)).first,
        )
        .data;
  }

  /// The log row showing [text].
  Finder logRow(String text) =>
      find.ancestor(of: find.text(text), matching: byTypeName('_LogRow')).first;

  Finder inLog(String text) =>
      find.descendant(of: byTypeName('_LogRow'), matching: find.text(text));

  /// The bar chart "Verlauf" of the log (values, labels, highlight).
  dynamic chart(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find
                    .byWidgetPredicate(
                      (w) =>
                          w is CustomPaint &&
                          w.painter.runtimeType.toString() == '_BarPainter',
                    )
                    .first,
              )
              .painter
          as dynamic;

  Future<void> series(WidgetTester tester, String from, String to) async {
    await scrollTo(tester, find.text(de.kidsLogHistory));
    await choose(tester, from, to);
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Opens the log editor of [quick] and types a temperature.
  Future<void> typeTemperature(WidgetTester tester, String value) async {
    if (find.widgetWithText(TextField, 'Temperatur (°C)').evaluate().isEmpty) {
      await tapQuick(tester, de.kidsLogTemperature);
    }
    await enter(tester, field('Temperatur (°C)'), value);
    await tester.pump(const Duration(milliseconds: 300));
  }

  String adviceText(WidgetTester tester, FeverLevel level) {
    final box = byTypeName('_AdviceBox');
    if (box.evaluate().isEmpty) return '';
    final w = tester.widget(box.first) as dynamic;
    expect(w.level, level);
    return w.text as String;
  }

  Color dangerOf(WidgetTester tester, Finder f) =>
      FamioColors.of(tester.element(f.first)).danger;

  /// Whether [finder] shows anywhere on the page (scrolled top to bottom).
  Future<bool> anywhere(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 12; i++) {
      await tester.dragFrom(const Offset(600, 300), const Offset(0, 300));
      await tester.pump(const Duration(milliseconds: 150));
    }
    for (var i = 0; i < 20; i++) {
      if (finder.evaluate().isNotEmpty) return true;
      await tester.dragFrom(const Offset(600, 450), const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 200));
    }
    return finder.evaluate().isNotEmpty;
  }

  String md(DateTime d) => DateFormat.Md('de').format(d);
  String yMd(DateTime d) => DateFormat.yMd('de').format(d);
  String yMMMd(DateTime d) => DateFormat.yMMMd('de').format(d);
  String hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  // =========================================================================
  // Empty lists first: no medication yet, no child for the child account.
  // =========================================================================

  testWidgets('KIN-094 KIN-107 empty medication plan, start page tile', (
    tester,
  ) async {
    final state = await start(tester);
    // Without medications: no tile on the start page.
    await openSection(tester, 'Start');
    expect(
      await anywhere(tester, find.text(de.commonMedications)),
      isFalse,
      reason: 'no medications tile without medications',
    );

    await openSection(tester, 'Medizin');
    await waitFor(tester, find.text(de.medsFamioOnlyRemindsYou));
    await waitFor(tester, find.text(de.medsNoMedicationsYetFamio));

    // Two open doses today and only enough for one day.
    final child = await seedChild('E2E Kachelkind', born(years: 4));
    final med = await seedMedication(
      'E2E Kachelsaft',
      times: const ['06:00', '22:00'],
      personName: 'E2E Kachelkind',
      stock: 2,
    );
    await arrives(
      tester,
      state,
      (e) => e.medication(med) != null && e.child(child) != null,
      'plan',
    );
    await openSection(tester, 'Start');
    final tile = find.ancestor(
      of: find.text(de.commonMedications),
      matching: find.byType(SoftCard),
    );
    await scrollTo(tester, find.text(de.commonMedications));
    await waitFor(tester, find.text(de.commonOpenCount(2)));
    expect(
      find.descendant(
        of: tile.first,
        matching: find.text('E2E Kachelsaft · E2E Kachelkind'),
      ),
      findsNWidgets(2),
    );
    final doses = state.engine!.medication(med)!.dosesOn(today());
    for (final at in doses) {
      expect(
        find.descendant(of: tile.first, matching: find.text(timeLabel(at))),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(
        of: tile.first,
        matching: find.text(de.homeNameBuyMoreSoon('E2E Kachelsaft')),
      ),
      findsOneWidget,
    );

    // All taken: the tile says so.
    await openSection(tester, 'Medizin');
    for (final at in doses) {
      final card = find.ancestor(
        of: find.text(timeLabel(at)),
        matching: find.ancestor(
          of: find.text('E2E Kachelsaft · E2E Kachelkind'),
          matching: find.byType(SoftCard),
        ),
      );
      await scrollTo(tester, card);
      await tap(
        tester,
        find.descendant(of: card.first, matching: find.byTooltip('Genommen')),
      );
    }
    await openSection(tester, 'Start');
    await scrollTo(tester, find.text(de.homeAllTakenToday));
    await finish(tester, state);
  });

  // Children are adultOnly (record_store.dart): an empty list offers a child
  // account no "Hinzufügen" and the start page does not ask it to add a
  // child (#539).
  testWidgets('KIN-134 child account: an empty list offers no way to add', (
    tester,
  ) async {
    await theFamily();
    final state = await start(tester, user: 'e2e-kind');
    final problems = <String>[];

    await openSection(tester, 'Start');
    if (await anywhere(tester, find.text(de.homeAddChildKeepTrack))) {
      problems.add('start page: "${de.homeAddChildKeepTrack}"');
    }
    expect(await anywhere(tester, find.text(de.kidsNoneYet)), isTrue);
    await kidsList(tester);
    expect(find.byTooltip(de.kidsAddChildPregnancy), findsNothing);
    if (find.text(de.commonAdd).evaluate().isNotEmpty) {
      problems.add('empty list: button "${de.commonAdd}"');
      await tap(tester, find.text(de.commonAdd));
      await tap(tester, find.text(de.kidsAddChild).last);
      await enter(tester, field(de.commonName), 'E2E Kindversuch');
      await tap(tester, find.text(de.commonPickDate));
      await typeDate(tester, born(years: 1));
      await tap(tester, find.text(de.commonSave).last);
      await synced(tester, state);
      final messages = find.byType(SnackBar).evaluate().length;
      final kept = state.engine!.children.any(
        (c) => c.name == 'E2E Kindversuch',
      );
      problems.add(
        'saving: no message ($messages snack bars), kept locally: $kept, '
        'on the server: '
        '${(await pull(await adminApi(), Collections.children)).values.any((r) => r.data['name'] == 'E2E Kindversuch')}',
      );
    }
    expect(find.textContaining(de.kidsNoneYet), findsOneWidget);
    expect(problems, isEmpty);
    await finish(tester, state);
  });

  testWidgets(
    'KIN-134 KIN-138 child account: no editing of the child or its emergency data',
    (tester) async {
      final f = await theFamily();
      final childId = await seedChild(
        'E2E Geschwister',
        born(years: 2),
        guardians: [f.adminMember.id, f.kid.id],
        emergency: const EmergencyInfo(allergies: 'E2E Bienen'),
      );
      final state = await start(tester, user: 'e2e-kind');
      await kidsList(tester);
      await waitFor(tester, find.text('E2E Geschwister'));
      expect(find.byTooltip(de.kidsAddChildPregnancy), findsNothing);
      expect(find.text(de.commonAdd), findsNothing);
      await openChild(tester, 'E2E Geschwister');
      expect(find.byTooltip(de.commonEdit), findsNothing);
      await tap(tester, find.byTooltip(de.kidsEmergencyTitle));
      await waitFor(tester, find.text(de.kidsEmergencyName('E2E Geschwister')));
      await waitFor(tester, find.text('E2E Bienen'));
      expect(find.byTooltip(de.kidsEditEmergencyData), findsNothing);
      expect(find.text(de.kidsAddAllergiesPediatricianCo), findsNothing);
      await back(tester);

      // KIN-138: the child's own API session tries anyway.
      final kidApi = await sessionOf(f.kid);
      final mine = (await pull(kidApi, Collections.children))[childId]!;
      final answer = await put(kidApi, Collections.children, {
        childId: {
          ...mine.data,
          'guardianIds': [f.kid.id],
          'emergency': {
            ...(mine.data['emergency'] as Map).cast<String, Object?>(),
            'allergies': 'E2E keine',
          },
          SyncRecord.visibilityKey: [f.kid.id],
        },
      });
      expect(answer.rejected.map((r) => r.id), contains(childId));
      final stored = Child.fromRecord(
        (await pull(await adminApi(), Collections.children))[childId]!,
      );
      expect(stored.emergency.allergies, 'E2E Bienen');
      expect(stored.guardianIds, unorderedEquals([f.adminMember.id, f.kid.id]));
      await finish(tester, state);
    },
  );

  // Pregnancies are adultOnly: a child account named for one reads it, but
  // is offered no ticks, no contraction timer, no clearing and no "Baby ist
  // da!" (#539).
  testWidgets('KIN-140 child account and the pregnancy', (tester) async {
    final f = await theFamily();
    await seedPregnancy(
      'E2E Kindsicht',
      inDays(70),
      guardians: [f.adminMember.id, f.kid.id],
    );
    final state = await start(tester, user: 'e2e-kind');
    await openPregnancy(tester, 'E2E Kindsicht');
    expect(find.byTooltip(de.commonEdit), findsNothing);
    expect(await anywhere(tester, find.text(de.pregnancyBabyHere)), isFalse);

    await tab(tester, de.pregnancyChecklists);
    final boxes = find.byType(CheckboxListTile);
    await waitFor(tester, boxes.first);
    for (final e in boxes.evaluate()) {
      expect((e.widget as CheckboxListTile).onChanged, isNull);
    }
    await tab(tester, de.commonEvents);
    final checks = find.byType(RoundCheck);
    await waitFor(tester, checks.first);
    for (final e in checks.evaluate()) {
      expect((e.widget as RoundCheck).onChanged, isNull);
    }
    await tab(tester, de.pregnancyContractions);
    await waitFor(tester, find.text(de.pregnancyAdultsEnter));
    expect(find.text(de.pregnancyContractionStarts), findsNothing);
    expect(find.text(de.pregnancyClearHistory), findsNothing);
    await finish(tester, state);
  });

  testWidgets(
    'KIN-141 guest and service account get no children or health data',
    (tester) async {
      final f = await theFamily();
      final ha = await serviceAccount();
      final both = [f.adminMember.id, f.guest.id];
      final childId = await seedChild(
        'E2E Gastkind',
        born(months: 8),
        guardians: both,
        emergency: const EmergencyInfo(allergies: 'E2E Gräser'),
      );
      await seedLogs([
        await logOf(
          childId,
          LogKind.diaper,
          ago(const Duration(minutes: 5)),
          diaper: DiaperKind.wet,
        ),
      ]);
      await seedEntries([
        ChildEntry(
          id: uid('entry'),
          childId: childId,
          kind: ChildEntryKind.measurement,
          date: today(),
          weightKg: 8,
        ),
      ]);
      await seedPregnancy('E2E Gastbauch', inDays(100), guardians: both);
      final med = await seedMedication(
        'E2E Gastsaft',
        times: const ['12:00'],
        care: both,
      );
      final intake = MedicationIntake(
        id: uid('intake'),
        medicationId: med,
        at: DateTime.now(),
        byId: f.adminMember.id,
      );
      await seed(f.admin, Collections.medicationIntakes, {
        intake.id: intake.toData(visibleTo: both),
      });
      await seed(f.admin, Collections.memberEmergency, {
        f.adminMember.id: MemberEmergency(
          memberId: f.adminMember.id,
          info: const EmergencyInfo(allergies: 'E2E Admin-Allergie'),
        ).toData(),
      });

      final state = await start(tester, user: 'e2e-gast');
      await openSection(tester, 'Start');
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Kinder'), findsNothing, reason: 'no section Kinder');
      expect(find.text('Medizin'), findsNothing, reason: 'no section Medizin');
      expect(await anywhere(tester, find.text(de.sectionKids)), isFalse);
      expect(await anywhere(tester, find.text(de.commonMedications)), isFalse);
      expect(state.engine!.children, isEmpty);
      expect(state.engine!.medications, isEmpty);

      const health = [
        Collections.children,
        Collections.childEntries,
        Collections.childLogs,
        Collections.pregnancies,
        Collections.medications,
        Collections.medicationIntakes,
        Collections.memberEmergency,
      ];
      for (final who in [f.guest, ha]) {
        final api = await sessionOf(who);
        for (final c in health) {
          expect(
            await pull(api, c),
            isEmpty,
            reason: '${who.displayName} gets $c',
          );
        }
      }
      // The admin gets it all (the seeds are there).
      final admin = await adminApi();
      expect((await pull(admin, Collections.children)).keys, contains(childId));
      expect((await pull(admin, Collections.medications)).keys, contains(med));
      await finish(tester, state);
    },
  );

  // =========================================================================
  // Children: profile
  // =========================================================================

  testWidgets(
    'KIN-001 KIN-002 KIN-005 new child: required fields, date range, guardians only',
    (tester) async {
      final f = await theFamily();
      final state = await start(tester);
      final before = state.engine!.children.length;

      await kidsList(tester);
      await tap(tester, find.byTooltip(de.kidsAddChildPregnancy));
      await tap(tester, find.text(de.kidsAddChild).last);
      await waitFor(tester, find.text(de.kidsGuardians));
      // KIN-001: nothing without name and birthday.
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, snackText(de.kidsPleaseEnterNameBirthday));
      expect(find.text(de.kidsGuardians), findsOneWidget);
      await enter(tester, field(de.commonName), 'E2E Testkind');
      await snackGone(tester);
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, snackText(de.kidsPleaseEnterNameBirthday));
      expect(state.engine!.children.length, before);

      // KIN-002: no birthday in the future or more than 25 years back.
      final birth = born(months: 3);
      await tap(tester, find.text(de.commonPickDate));
      expect(await typeDate(tester, inDays(1)), isFalse, reason: 'tomorrow');
      expect(
        await typeDate(tester, born(years: 26)),
        isFalse,
        reason: '26 years ago',
      );
      expect(await typeDate(tester, birth), isTrue);
      await waitFor(tester, find.text(DateFormat.yMMMMd('de').format(birth)));
      await tap(tester, find.widgetWithText(ChoiceChip, de.pregnancyGirl));
      final color = famioPalette[3];
      await tap(
        tester,
        find.byWidgetPredicate(
          (w) => w is CircleAvatar && w.backgroundColor == Color(color),
        ),
      );
      // KIN-005: only the admin is a guardian.
      bool chosen(String name) => tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, name))
          .selected;
      expect(chosen(kitAdminName), isTrue);
      for (final other in [f.bea, f.carl]) {
        expect(chosen(other.displayName), isTrue);
        await tap(tester, find.widgetWithText(FilterChip, other.displayName));
        expect(chosen(other.displayName), isFalse);
      }
      expect(chosen(f.guest.displayName), isFalse);
      expect(chosen(f.kid.displayName), isFalse);
      await tap(tester, find.text(de.commonSave).last);

      await waitFor(tester, find.byType(KidsScreen));
      await inKidsList(tester, find.text('E2E Testkind'));
      final card = cardOf('E2E Testkind');
      expect(
        find.descendant(of: card, matching: find.text(de.ageMonths(3))),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(de.kidsCountMilestones(0)),
        ),
        findsOneWidget,
      );
      final child = state.engine!.children.singleWhere(
        (c) => c.name == 'E2E Testkind',
      );
      expect(child.sex, ChildSex.female);
      expect(child.color, color);
      expect(child.birthDate, birth);
      expect(child.guardianIds, [f.adminMember.id]);

      // A log entry and a measurement only for the guardian.
      await openChild(tester, 'E2E Testkind');
      expect(selectedTab(tester), de.kidsTabLog);
      await tapQuick(tester, de.kidsLogPee);
      await tapQuick(tester, de.kidsLogMeasure);
      await enter(tester, field(de.kidsHeightCm), '61');
      await tap(tester, inSheet(find.text(de.commonSave)));
      await until(
        tester,
        () => state.engine!.childEntries(child.id).isNotEmpty,
        'measurement saved',
      );
      await synced(tester, state);
      final admin = await adminApi();
      expect(
        (await pull(
          admin,
          Collections.childLogs,
        )).values.where((r) => r.data['childId'] == child.id),
        hasLength(1),
      );
      for (final other in [f.bea, f.carl]) {
        final api = await sessionOf(other);
        expect(
          (await pull(api, Collections.children)).keys,
          isNot(contains(child.id)),
        );
        for (final c in [Collections.childLogs, Collections.childEntries]) {
          expect(
            (await pull(
              api,
              c,
            )).values.where((r) => r.data['childId'] == child.id),
            isEmpty,
            reason: '${other.displayName}: $c',
          );
        }
      }
      await finish(tester, state);
    },
  );

  // The catalog suspected that a child with only the guest as guardian is
  // lost for all adults. The server keeps its author in the audience, so
  // the admin still manages it (the card says "Nur E2E Gast, Admin").
  testWidgets('KIN-008 only the guest as guardian', (tester) async {
    final f = await theFamily();
    await serviceAccount();
    final state = await start(tester);
    final problems = <String>[];
    await kidsList(tester);
    await tap(tester, find.byTooltip(de.kidsAddChildPregnancy));
    await tap(tester, find.text(de.kidsAddChild).last);
    await enter(tester, field(de.commonName), 'E2E Gastkind Sorge');
    await tap(tester, find.text(de.commonPickDate));
    await typeDate(tester, born(years: 1));
    if (find.widgetWithText(FilterChip, 'E2E Dienst').evaluate().isNotEmpty) {
      problems.add('the service account is offered as guardian');
    }
    for (final adult in [kitAdminName, f.bea.displayName, f.carl.displayName]) {
      await tap(tester, find.widgetWithText(FilterChip, adult));
    }
    await tap(tester, find.widgetWithText(FilterChip, f.guest.displayName));
    await tap(tester, find.text(de.commonSave).last);
    await tester.pump(const Duration(seconds: 1));
    final prevented = find.text(de.kidsGuardians).evaluate().isNotEmpty;
    if (!prevented) {
      final id = state.engine!.children
          .singleWhere((c) => c.name == 'E2E Gastkind Sorge')
          .id;
      await synced(tester, state);
      // The guest gets no child data at all.
      expect(
        (await pull(await sessionOf(f.guest), Collections.children)).keys,
        isNot(contains(id)),
      );
      final onServer = [
        for (final who in [f.adminMember, f.bea])
          (await pull(
            who == f.adminMember ? await adminApi() : await sessionOf(who),
            Collections.children,
          )).containsKey(id),
      ];
      debugPrint('E2E KIN-008 admin, Bea receive the child: $onServer');
      if (!onServer.any((s) => s)) {
        problems.add('no adult receives the child (other device, Bea)');
      }
      final stored = (await pull(await adminApi(), Collections.children))[id];
      debugPrint('E2E KIN-008 audience on the server: ${stored?.visibleTo}');
      // The admin's own device still has it: the admin adds itself.
      if (state.engine!.child(id) != null) {
        await openChild(tester, 'E2E Gastkind Sorge');
        await tap(tester, find.byTooltip(de.commonEdit));
        await tap(tester, find.widgetWithText(FilterChip, kitAdminName));
        await tap(tester, find.text(de.commonSave).last);
        await synced(tester, state);
        await synced(tester, state);
        final fixed = (await pull(
          await adminApi(),
          Collections.children,
        )).containsKey(id);
        if (!fixed) {
          problems.add(
            'the admin cannot correct it: server turns it down, the app '
            '${state.engine!.child(id) == null ? 'drops the child' : 'keeps it'}',
          );
        }
      } else {
        problems.add('gone in the admin app right after saving');
      }
    }
    expect(problems, isEmpty);
    await finish(tester, state);
  });

  testWidgets(
    'KIN-009 KIN-010 photo and profile edits keep the emergency data',
    (tester) async {
      final picker = fakePicker();
      final id = await seedChild(
        'E2E Fotokind',
        born(years: 1, months: 2),
        sex: ChildSex.female,
        emergency: const EmergencyInfo(
          allergies: 'E2E Nüsse',
          bloodType: 'E2E A+',
        ),
      );
      final state = await start(tester);
      await openChild(tester, 'E2E Fotokind');
      await tap(tester, find.byTooltip(de.commonEdit));
      await waitFor(tester, find.text(de.settingsEditProfile));
      picker.picks.add(await picture('kind.png', big: true));
      final blocked = await uploadWatchingSave(
        tester,
        find.byTooltip(de.kidsChoosePhoto),
        saveButton(de.commonSave),
        () => find.byType(CachedImage).evaluate().isNotEmpty,
      );
      debugPrint('E2E KIN-009 save blocked while uploading: $blocked');
      // The upload ends with the photo in the editor (CachedImage above).
      expect(blocked, isTrue, reason: '"Speichern" locked while uploading');
      await enter(tester, field(de.commonName), 'E2E Fotokind Neu');
      await tap(tester, find.widgetWithText(ChoiceChip, de.kidsNotSpecified));
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, find.text('E2E Fotokind Neu'));
      final child = state.engine!.child(id)!;
      expect(child.name, 'E2E Fotokind Neu');
      expect(child.sex, isNull);
      expect(child.photo, isNotNull);
      expect(child.emergency.allergies, 'E2E Nüsse');
      expect(child.emergency.bloodType, 'E2E A+');
      await synced(tester, state);
      final stored = Child.fromRecord(
        (await pull(await adminApi(), Collections.children))[id]!,
      );
      expect(stored.emergency.allergies, 'E2E Nüsse');
      expect(stored.photo?.id, child.photo!.id);
      await kidsList(tester);
      await inKidsList(tester, find.text('E2E Fotokind Neu'));
      expect(
        find.descendant(
          of: cardOf('E2E Fotokind Neu'),
          matching: find.byType(CachedImage),
        ),
        findsOneWidget,
      );

      // An upload that fails is told: the server takes 1 MB at most, the
      // picture has about 9 MB.
      final admin = await adminApi();
      addTearDown(() => admin.updateServerSettings({'maxUploadMb': null}));
      await admin.updateServerSettings({'maxUploadMb': 1});
      await arrives(
        tester,
        state,
        (e) => e.maxUploadBytes == 1024 * 1024,
        'upload limit of 1 MB',
      );
      await openChild(tester, 'E2E Fotokind Neu');
      await tap(tester, find.byTooltip(de.commonEdit));
      await waitFor(tester, find.text(de.settingsEditProfile));
      picker.picks.add(await picture('zu-gross.png', big: true));
      await tap(tester, find.byTooltip(de.kidsChoosePhoto));
      await waitFor(tester, find.byType(AlertDialog));
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(de.filesUploadLimit(fileSizeLabel(1024 * 1024))),
        ),
        findsOneWidget,
      );
      await tap(tester, find.text(de.commonOk).last);
      await dialogClosed(tester);
      expect(find.text(de.settingsEditProfile), findsOneWidget);
      expect(enabled(tester, saveButton(de.commonSave)), isTrue);
      await admin.updateServerSettings({'maxUploadMb': null});
      await back(tester);
      expect(state.engine!.child(id)!.photo?.id, child.photo!.id);
      await finish(tester, state);
    },
  );

  // The connection drops while the photo goes up (after half a megabyte of
  // it): the editor tells it in its snack bar (child_editor.dart), keeps the
  // photo it had, and nothing half of it is kept – neither in the child nor
  // on the server. With the network back, the same picture goes through.
  testWidgets(
    'KIN-009 an upload that breaks off is told, nothing half is kept',
    (tester) async {
      final picker = fakePicker();
      final admin = await adminApi();
      final id = await seedChild('E2E Abbruchkind', born(years: 2));
      final gate = _CuttingGate(Uri.parse(kitUrl));
      await gate.start();
      addTearDown(gate.close);
      final state = await startVia(tester, gate.url);
      await openChild(tester, 'E2E Abbruchkind');
      await tap(tester, find.byTooltip(de.commonEdit));
      await waitFor(tester, find.text(de.settingsEditProfile));
      expect(find.byType(CachedImage), findsNothing);
      final before = await admin.adminOverview();
      gate.cutUploads = true;
      picker.picks.add(await picture('abbruch.png', big: true));
      final button = find.byTooltip(de.kidsChoosePhoto);
      await tester.ensureVisible(button.first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(button.first, warnIfMissed: false);
      final snack = find.descendant(
        of: find.byType(SnackBar),
        matching: find.byType(Text),
      );
      var blocked = false;
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (snack.evaluate().isEmpty && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 20));
        if (!enabled(tester, saveButton(de.commonSave))) blocked = true;
      }
      expect(snack, findsWidgets, reason: 'the failure is told');
      final said = tester.widget<Text>(snack.first).data!;
      debugPrint(
        'E2E KIN-009 upload broken off: "$said", save blocked: $blocked',
      );
      expect(gate.cut, 1, reason: 'the gate broke the upload off');
      expect(blocked, isTrue, reason: '"Speichern" locked while uploading');
      expect(said, startsWith('Server nicht erreichbar'));
      // The editor as it was: no photo, "Speichern" usable again.
      await until(
        tester,
        () => enabled(tester, saveButton(de.commonSave)),
        'save usable again',
      );
      expect(find.byType(CachedImage), findsNothing);
      // Nothing half on the server.
      await eventually(tester, 'no part of the file kept', () async {
        final now = await admin.adminOverview();
        return now.fileCount == before.fileCount &&
            now.fileBytes == before.fileBytes;
      });
      // Saved like this, the child has no photo.
      await snackGone(tester);
      await tap(tester, find.text(de.commonSave).last);
      await waitGone(tester, find.text(de.settingsEditProfile));
      expect(state.engine!.child(id)!.photo, isNull);
      await synced(tester, state);
      expect(
        Child.fromRecord((await pull(admin, Collections.children))[id]!).photo,
        isNull,
      );

      // The network is back: the same picture goes through.
      gate.cutUploads = false;
      await tap(tester, find.byTooltip(de.commonEdit));
      await waitFor(tester, find.text(de.settingsEditProfile));
      picker.picks.add(await picture('abbruch.png', big: true));
      await tap(tester, find.byTooltip(de.kidsChoosePhoto));
      await waitFor(
        tester,
        find.byType(CachedImage),
        timeout: const Duration(seconds: 60),
      );
      await until(
        tester,
        () => enabled(tester, saveButton(de.commonSave)),
        'upload done',
      );
      await tap(tester, find.text(de.commonSave).last);
      await waitGone(tester, find.text(de.settingsEditProfile));
      final photo = state.engine!.child(id)!.photo;
      expect(photo, isNotNull);
      await synced(tester, state);
      expect(
        Child.fromRecord(
          (await pull(admin, Collections.children))[id]!,
        ).photo?.id,
        photo!.id,
      );
      expect((await admin.adminOverview()).fileCount, before.fileCount + 1);
      expect(gate.cut, 1);
      await finish(tester, state);
    },
  );

  testWidgets('KIN-011 removing a child asks first and takes its records', (
    tester,
  ) async {
    final id = await seedChild('E2E Löschkind', born(months: 10));
    await seedLogs([
      await logOf(id, LogKind.bath, ago(const Duration(hours: 1))),
    ]);
    await seedEntries([
      ChildEntry(
        id: uid('entry'),
        childId: id,
        kind: ChildEntryKind.memory,
        date: today(),
        title: 'E2E Erinnerung',
      ),
    ]);
    final state = await start(tester);
    await openChild(tester, 'E2E Löschkind');
    await tap(tester, find.byTooltip(de.commonEdit));
    await scrollTo(tester, find.text(de.kidsRemoveChild));
    await tap(tester, find.text(de.kidsRemoveChild));
    await waitFor(tester, find.text('E2E Löschkind entfernen?'));
    expect(find.text(de.kidsAllEntriesMilestonesMeasurements), findsOneWidget);
    await tap(tester, find.text(de.commonCancel));
    await dialogClosed(tester);
    expect(state.engine!.child(id), isNotNull);
    await tap(tester, find.text(de.kidsRemoveChild));
    await tap(tester, find.widgetWithText(FilledButton, de.commonDelete));
    await waitFor(tester, find.byType(KidsScreen));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('E2E Löschkind'), findsNothing);
    await synced(tester, state);
    final admin = await adminApi();
    expect((await pull(admin, Collections.children)).keys, isNot(contains(id)));
    for (final c in [Collections.childLogs, Collections.childEntries]) {
      expect(
        (await pull(admin, c)).values.where((r) => r.data['childId'] == id),
        isEmpty,
        reason: c,
      );
    }
    await finish(tester, state);
  });

  testWidgets('KIN-012 KIN-013 tabs by age, empty timeline', (tester) async {
    await seedChild('E2E Halbjahr', born(months: 6));
    final three = await seedChild('E2E Dreijährig', born(years: 3));
    await seedChild('E2E Schulkind', born(years: 6));
    final state = await start(tester);
    const always = [
      'Zeitstrahl',
      'Meilensteine',
      'Vorsorge',
      'Impfungen',
      'Wachstum',
    ];

    await openChild(tester, 'E2E Halbjahr');
    expect(selectedTab(tester), de.kidsTabLog);
    expect(tabLabels(tester), containsAll(always));
    expect(tabLabels(tester), isNot(contains(de.commonTimetable)));

    await openChild(tester, 'E2E Dreijährig');
    expect(selectedTab(tester), de.kidsTabTimeline);
    expect(tabLabels(tester), containsAll([...always, de.kidsTabLog]));
    // KIN-013: nothing yet.
    final child = state.engine!.child(three)!;
    await waitFor(tester, find.text(de.timelineTodayAge(ageLabel(child))));
    await scrollTo(tester, find.text(de.timelineNoEntriesYetTap));
    await scrollTo(tester, find.text(de.timelineBirth));
    await scrollTo(
      tester,
      find.textContaining(de.timelineWelcomeName('E2E Dreijährig')),
    );

    await openChild(tester, 'E2E Schulkind');
    expect(tabLabels(tester), containsAll([...always, de.commonTimetable]));
    expect(tabLabels(tester), isNot(contains(de.kidsTabLog)));
    await finish(tester, state);
  });

  // =========================================================================
  // Timeline and milestones
  // =========================================================================

  testWidgets('KIN-014 KIN-015 memories with text, date and photos', (
    tester,
  ) async {
    final picker = fakePicker();
    final birth = born(days: 70);
    final id = await seedChild('E2E Erinnerungskind', birth);
    final state = await start(tester);
    await openChild(tester, 'E2E Erinnerungskind');
    await tab(tester, de.kidsTabTimeline);

    // KIN-014: an empty memory is not saved.
    await tap(tester, find.byTooltip(de.kidsCaptureMemory));
    await waitFor(tester, inSheet(find.text(de.kidsCaptureMemory)));
    await tap(tester, inSheet(find.text(de.commonSave)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(inSheet(field(de.kidsWhatHappened)), findsOneWidget);
    expect(state.engine!.childEntries(id), isEmpty);
    await enter(tester, field(de.kidsWhatHappened), 'E2E Erstes Lachen');
    await enter(tester, field(de.contactsNoteOptional), 'E2E im Garten');
    await tap(tester, inSheet(find.byType(InputChip)));
    await pickDate(tester, birth.add(const Duration(days: 10)));
    await tap(tester, inSheet(find.text(de.commonSave)));
    await waitGone(tester, sheet());
    await scrollTo(tester, find.text('E2E Erstes Lachen'));
    final row = find
        .ancestor(
          of: find.text('E2E Erstes Lachen'),
          matching: find.byType(IntrinsicHeight),
        )
        .first;
    expect(
      find.descendant(of: row, matching: find.byIcon(AppIcons.heart)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('E2E im Garten')),
      findsOneWidget,
    );
    final group = find.text(de.timelineFirstWeeks);
    expect(group, findsOneWidget);
    expect(
      tester.getTopLeft(group).dy,
      lessThan(tester.getTopLeft(find.text('E2E Erstes Lachen')).dy),
    );

    // KIN-015: two pictures, one taken off again.
    await tap(tester, find.byTooltip(de.kidsCaptureMemory));
    await enter(tester, field(de.kidsWhatHappened), 'E2E Ausflug');
    picker.picks
      ..add(await picture('eins.png', big: true))
      ..add(await picture('zwei.png'));
    Finder thumbs() => inSheet(find.byType(CachedImage));
    var spinning = false;
    final blocked = await uploadWatchingSave(
      tester,
      inSheet(find.byTooltip(de.kidsAddPhoto)),
      inSheet(saveButton(de.commonSave)),
      () => thumbs().evaluate().length == 1,
      spinner: inSheet(find.byType(CircularProgressIndicator)),
      sawSpinner: () => spinning = true,
    );
    expect(blocked, isTrue, reason: '"Speichern" locked while uploading');
    expect(spinning, isTrue, reason: 'a circle turns while uploading');
    await uploadWatchingSave(
      tester,
      inSheet(find.byTooltip(de.kidsAddPhoto)),
      inSheet(saveButton(de.commonSave)),
      () => thumbs().evaluate().length == 2,
    );
    await tap(tester, inSheet(find.byTooltip(de.kidsRemovePhoto)));
    expect(thumbs(), findsOneWidget);
    await tap(tester, inSheet(find.text(de.commonSave)));
    await waitGone(tester, sheet());
    await scrollTo(tester, find.text('E2E Ausflug'));
    final trip = find
        .ancestor(
          of: find.text('E2E Ausflug'),
          matching: find.byType(IntrinsicHeight),
        )
        .first;
    final photo = find.descendant(of: trip, matching: find.byType(CachedImage));
    expect(photo, findsOneWidget);
    expect(
      state.engine!
          .childEntries(id)
          .singleWhere((e) => e.title == 'E2E Ausflug')
          .photos,
      hasLength(1),
    );
    await tap(tester, photo);
    await waitFor(tester, find.byType(PhotoViewer));
    await tap(tester, find.byTooltip('Schließen').last);
    await waitGone(tester, find.byType(PhotoViewer));
    debugPrint('E2E KIN-015 save blocked while uploading: $blocked');
    await finish(tester, state);
  });

  // A memory (with its photos) goes with "Rückgängig" on the page (#544).
  testWidgets('KIN-016 deleting a memory asks or can be undone', (
    tester,
  ) async {
    final id = await seedChild('E2E Vergesskind', born(months: 5));
    await seedEntries([
      ChildEntry(
        id: uid('entry'),
        childId: id,
        kind: ChildEntryKind.memory,
        date: today(),
        title: 'E2E Löschmich',
      ),
    ]);
    final state = await start(tester);
    await openChild(tester, 'E2E Vergesskind');
    await tab(tester, de.kidsTabTimeline);
    await scrollTo(tester, find.text('E2E Löschmich'));
    await tap(tester, find.text('E2E Löschmich'));
    await tap(tester, inSheet(find.text(de.commonDelete)));
    await tester.pump(const Duration(milliseconds: 800));
    final asked = find.byType(AlertDialog).evaluate().isNotEmpty;
    final canUndo = find
        .descendant(
          of: find.byType(SnackBar),
          matching: find.text('Rückgängig'),
        )
        .evaluate()
        .isNotEmpty;
    final gone = state.engine!.childEntries(id).isEmpty;
    expect(
      asked || canUndo,
      isTrue,
      reason: 'deleted without asking and without undo (gone: $gone)',
    );
    expect(gone, isTrue);
    await undo(tester);
    await until(
      tester,
      () =>
          state.engine!.childEntries(id).any((e) => e.title == 'E2E Löschmich'),
      'memory back',
    );
    await finish(tester, state);
  });

  testWidgets('KIN-017 KIN-036 coming up in the timeline, vaccination list', (
    tester,
  ) async {
    final birth = born(days: 61);
    await seedChild('E2E Impfkind', birth);
    // Three and a half months: U4 is due, the vaccinations of two months
    // are over, so the few listed include a check-up.
    final id = await seedChild('E2E Demnächst', born(days: 106));
    final state = await start(tester);
    await openChild(tester, 'E2E Demnächst');
    await tab(tester, de.kidsTabTimeline);
    await waitFor(tester, find.text(de.tasksComingUp));
    await scrollTo(tester, find.textContaining('Jetzt fällig · '));
    await scrollTo(tester, find.textContaining('Typisch zwischen '));
    await scrollTo(tester, find.textContaining('Entwicklungsphase · '));
    final child = state.engine!.child(id)!;
    final phase =
        (developmentPhasesFor(child.sex)
                .where(
                  (p) => phaseIsUpcoming(
                    p,
                    child.ageInMonths(DateTime.now()).toDouble(),
                  ),
                )
                .toList()
              ..sort((a, b) => a.fromMonth.compareTo(b.fromMonth)))
            .first;
    await scrollTo(tester, find.text(phase.title));
    await tap(tester, find.text(phase.title));
    await waitFor(tester, inSheet(find.text(phase.info)));
    await closeSheet(tester);
    // A check-up due now opens its sheet (only the next few are listed).
    final dueRows = find.textContaining('Jetzt fällig · ');
    await scrollTo(tester, dueRows, up: true);
    String? checkup;
    for (final e in dueRows.evaluate()) {
      final column = find
          .ancestor(of: find.byWidget(e.widget), matching: find.byType(Column))
          .first;
      final title = tester
          .widget<Text>(
            find.descendant(of: column, matching: find.byType(Text)).first,
          )
          .data!;
      if (RegExp(r'^U\d').hasMatch(title)) {
        checkup = title;
        break;
      }
    }
    debugPrint('E2E KIN-017 check-up due in the timeline: $checkup');
    expect(checkup, isNotNull, reason: 'a check-up among "Jetzt fällig"');
    await tap(tester, find.text(checkup!));
    await waitFor(tester, find.text(de.dueDoneToday));
    await closeSheet(tester);

    // KIN-036.
    await openChild(tester, 'E2E Impfkind');
    await tab(tester, de.kidsTabVaccinations);
    await waitFor(tester, find.text(de.kidsBasedStikoVaccinationCalendar));
    await scrollTo(tester, find.text('Rotaviren – 1. Dosis'));
    final from = DateTime(birth.year, birth.month, birth.day + 42);
    expect(
      inCard(
        'Rotaviren – 1. Dosis',
        find.text(
          de.dueRecommendedDateNote(
            yMd(from),
            ' · Schluckimpfung ab 6 Wochen, Beginn spätestens mit 12 Wochen.',
          ),
        ),
      ),
      findsOneWidget,
    );
    await expectStatus(tester, 'Rotaviren – 1. Dosis', de.dueDueNow);
    await finish(tester, state);
  });

  testWidgets('KIN-019 KIN-020 KIN-021 milestones: areas, reached, reset', (
    tester,
  ) async {
    final id = await seedChild('E2E Sitzkind', born(months: 8));
    final older = await seedChild('E2E Großkind', born(years: 4));
    await seedEntries([
      ChildEntry(
        id: uid('entry'),
        childId: older,
        kind: ChildEntryKind.milestone,
        date: born(years: 3, months: 4),
        refId: 'sit',
      ),
    ]);
    final state = await start(tester);
    await openChild(tester, 'E2E Sitzkind');
    await tab(tester, de.kidsTabMilestones);
    await waitFor(tester, find.text(de.milestonesGuideValuesMostChildren));
    for (final area in [
      'Sehen & Hören',
      'Bewegung',
      'Hände & Geschick',
      'Sprache',
    ]) {
      await scrollTo(tester, find.text(area));
    }
    await scrollTo(tester, find.text('Sitzt frei ohne Stütze'), up: true);
    expect(byTypeName('_WindowBar'), findsWidgets);
    expect(
      inCard('Sitzt frei ohne Stütze', find.textContaining('Meist zwischen ')),
      findsOneWidget,
    );

    // KIN-020.
    final day = inDays(-7);
    await tickCard(tester, 'Sitzt frei ohne Stütze');
    await tap(tester, inSheet(find.byType(InputChip)));
    await pickDate(tester, day);
    await tap(tester, inSheet(find.text(de.kidsDone)));
    await waitGone(tester, sheet());
    final child = state.engine!.child(id)!;
    await scrollTo(tester, find.text('Sitzt frei ohne Stütze'));
    expect(
      inCard(
        'Sitzt frei ohne Stütze',
        find.text(
          de.milestonesReachedDateAge(yMMMd(day), ageLabel(child, day)),
        ),
      ),
      findsOneWidget,
    );
    await tab(tester, de.kidsTabTimeline);
    await scrollTo(tester, find.text('Sitzt frei ohne Stütze'));
    expect(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Sitzt frei ohne Stütze'),
              matching: find.byType(IntrinsicHeight),
            )
            .first,
        matching: find.byIcon(AppIcons.star),
      ),
      findsOneWidget,
    );
    await kidsList(tester);
    await inKidsList(tester, find.text('E2E Sitzkind'));
    expect(
      find.descendant(
        of: cardOf('E2E Sitzkind'),
        matching: find.text(de.kidsCountMilestones(1)),
      ),
      findsOneWidget,
    );
    // Reached long ago: still listed.
    await openChild(tester, 'E2E Großkind');
    await tab(tester, de.kidsTabMilestones);
    await scrollTo(tester, find.text('Sitzt frei ohne Stütze'));
    expect(
      inCard('Sitzt frei ohne Stütze', find.textContaining('Geschafft am ')),
      findsOneWidget,
    );

    // KIN-021.
    await openChild(tester, 'E2E Sitzkind');
    await tab(tester, de.kidsTabMilestones);
    await scrollTo(tester, find.text('Sitzt frei ohne Stütze'));
    await tap(tester, find.text('Sitzt frei ohne Stütze'));
    await tap(tester, inSheet(find.text(de.commonReset)));
    await waitGone(tester, sheet());
    await scrollTo(tester, find.text('Sitzt frei ohne Stütze'));
    expect(
      inCard('Sitzt frei ohne Stütze', find.textContaining('Meist zwischen ')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<RoundCheck>(
            inCard('Sitzt frei ohne Stütze', find.byType(RoundCheck)),
          )
          .value,
      isFalse,
    );
    await tab(tester, de.kidsTabTimeline);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      await anywhere(tester, find.text('Sitzt frei ohne Stütze')),
      isFalse,
    );
    await finish(tester, state);
  });

  // =========================================================================
  // Check-ups and vaccinations
  // =========================================================================

  testWidgets(
    'KIN-026 KIN-029 KIN-030 KIN-031 KIN-048 check-up list, done today, date unknown, measurements',
    (tester) async {
      final id = await seedChild(
        'E2E Vorsorgekind',
        born(days: 28),
        sex: ChildSex.female,
      );
      final state = await start(tester);
      await openChild(tester, 'E2E Vorsorgekind');
      await tab(tester, de.kidsTabCheckups);
      await waitFor(tester, find.text(de.kidsPeriodsGermanChildHealth));
      await expectStatus(
        tester,
        'U1 – Neugeborenen-Erstuntersuchung',
        de.duePeriodOver,
      );
      await expectStatus(tester, 'U3', de.dueDueNow);
      expect(
        inCard('U3', find.textContaining('4.–5. Lebenswoche · ')),
        findsOneWidget,
      );
      await expectStatus(tester, 'U4', de.pregnancySoon);
      expect(await anywhere(tester, find.text('U8')), isFalse);
      expect(await anywhere(tester, find.text('U7a')), isFalse);

      // KIN-029.
      await tickCard(tester, 'U3');
      for (final b in [
        de.dueDoneToday,
        de.dueOtherDateMeasurementsNote,
        de.dueAddAppointment,
        de.dueDoneDateUnknown2,
      ]) {
        expect(find.text(b), findsOneWidget, reason: b);
      }
      await tap(tester, find.text(de.dueDoneToday));
      await waitFor(tester, snackText(de.kidsWhatDone('U3')));
      await expectStatus(tester, 'U3', de.commonDoneLower);
      expect(
        inCard('U3', find.text(de.kidsDate(yMMMd(today())))),
        findsOneWidget,
      );

      // KIN-030.
      const u2 = 'U2 – Neugeborenen-Basisuntersuchung';
      await tickCard(tester, u2);
      await tap(tester, find.text(de.dueDoneDateUnknown2));
      await tester.pump(const Duration(milliseconds: 500));
      await expectStatus(tester, u2, de.commonDoneLower);
      expect(inCard(u2, find.text(de.dueDoneDateUnknown)), findsOneWidget);

      // KIN-031.
      await tickCard(tester, 'U4');
      await tap(tester, find.text(de.dueOtherDateMeasurementsNote));
      await waitFor(
        tester,
        inSheet(find.text(de.kidsMeasurementsCheckupOptional)),
      );
      await enter(tester, field(de.kidsHeightCm), '62');
      await enter(tester, field(de.kidsWeightKg), '6,2');
      await enter(tester, field(de.kidsHeadCm), '40');
      await tap(tester, inSheet(find.text(de.kidsDone)));
      await waitGone(tester, sheet());
      await expectStatus(tester, 'U4', de.commonDoneLower);

      await tab(tester, de.kidsTabTimeline);
      await scrollTo(tester, find.text(de.kidsWhatDone(u2)));
      expect(
        find.descendant(
          of: find
              .ancestor(
                of: find.text(de.kidsWhatDone(u2)),
                matching: find.byType(IntrinsicHeight),
              )
              .first,
          matching: find.text(de.kidsDateUnknown),
        ),
        findsOneWidget,
      );

      await tab(tester, de.kidsTabGrowth);
      final tile = find.widgetWithText(ListTile, '62 cm · 6,2 kg · Kopf 40 cm');
      await scrollTo(tester, tile);
      expect(
        find.descendant(of: tile, matching: find.textContaining('U4 · ')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tile, matching: find.byIcon(AppIcons.stethoscope)),
        findsOneWidget,
      );
      final weight = await chartCard(tester, de.kidsWeightKg);
      expect((weight.points as List).map((p) => p.$2), contains(6.2));
      await scrollTo(tester, tile);
      expect(
        state.engine!.childEntries(id).where((e) => e.refId == 'U4'),
        hasLength(1),
      );
      // KIN-048: a check-up's values open the check-up.
      await tap(tester, tile);
      await waitFor(tester, inSheet(find.text(de.commonReset)));
      expect(inSheet(find.text(de.commonDelete)), findsNothing);
      await closeSheet(tester);
      await finish(tester, state);
    },
  );

  testWidgets(
    'KIN-032 KIN-033 KIN-018 check-up appointment: book, move, cancel, done',
    (tester) async {
      final id = await seedChild('E2E Terminkind', born(days: 65));
      final state = await start(tester);
      final problems = <String>[];
      await openChild(tester, 'E2E Terminkind');
      await tab(tester, de.kidsTabCheckups);

      // KIN-032.
      await tickCard(tester, 'U5');
      await tap(tester, find.text(de.dueAddAppointment));
      await waitFor(tester, inSheet(find.text(de.kidsSaveAppointment)));
      final pills =
          tester.widget(find.descendant(of: sheet(), matching: pillTabs).first)
              as dynamic;
      expect(pills.selected, isTrue, reason: 'Termin geplant chosen');
      expect(inSheet(field(de.kidsHeightCm)), findsNothing);
      expect(inSheet(find.text(de.kidsDateUnknown)), findsNothing);
      await tap(tester, inSheet(find.textContaining('Am ')));
      expect(
        await typeDate(tester, inDays(4 * 365)),
        isTrue,
        reason: 'four years ahead',
      );
      final date = inDays(21);
      await tap(tester, inSheet(find.textContaining('Am ')));
      expect(await typeDate(tester, date), isTrue);
      await tap(tester, inSheet(find.text(de.kidsTimeOptional)));
      await pickTime(tester, 9, 30);
      await waitFor(tester, inSheet(find.text(de.kidsTime('09:30'))));
      await tap(tester, inSheet(find.text(de.kidsSaveAppointment)));
      await waitGone(tester, sheet());
      await expectStatus(tester, 'U5', de.commonEvent);
      final label = de.dueAppointmentDateTime(
        yMMMd(date),
        de.remindersTime('09:30'),
      );
      expect(inCard('U5', find.text(label)), findsOneWidget);
      await openSection(tester, 'Start');
      await scrollTo(tester, find.text(de.homeWhatDate('U5', md(date))));

      // KIN-018: in the timeline, with its time.
      await openSection(tester, 'Kinder');
      await tab(tester, de.kidsTabTimeline);
      await waitFor(tester, find.text(de.tasksComingUp));
      final rowText = find.textContaining('um 09:30 Uhr · Termin');
      await scrollTo(tester, rowText);
      final shown = tester.widget<Text>(rowText.first).data!;
      if (shown.contains('·  um')) problems.add('double space: "$shown"');
      expect(shown, contains(yMMMd(date)));

      // KIN-033: move it to yesterday.
      await tab(tester, de.kidsTabCheckups);
      await tickCard(tester, 'U5');
      for (final b in [
        de.dueDoneToday,
        de.dueChangeAppointment,
        de.dueCancelAppointment,
      ]) {
        expect(find.text(b), findsOneWidget, reason: b);
      }
      await tap(tester, find.text(de.dueChangeAppointment));
      await waitFor(tester, inSheet(find.text(de.kidsSaveAppointment)));
      final yesterday = inDays(-1);
      await tap(tester, inSheet(find.textContaining('Am ')));
      expect(await typeDate(tester, yesterday), isTrue);
      await tap(tester, inSheet(find.text(de.kidsSaveAppointment)));
      await waitGone(tester, sheet());
      await tab(tester, de.kidsTabTimeline);
      await scrollTo(
        tester,
        find.textContaining(de.timelineAppointmentWasDone),
      );

      // Cancelled and back.
      await tab(tester, de.kidsTabCheckups);
      await tickCard(tester, 'U5');
      await tap(tester, find.text(de.dueCancelAppointment));
      final moved = de.dueAppointmentDateTime(
        yMMMd(yesterday),
        de.remindersTime('09:30'),
      );
      await waitFor(tester, snackText(de.dueWhatCanceled(moved)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        state.engine!.childEntries(id).where((e) => e.refId == 'U5'),
        isEmpty,
      );
      await undo(tester);
      await until(
        tester,
        () => state.engine!.childEntries(id).any((e) => e.refId == 'U5'),
        'appointment back',
      );
      await snackGone(tester);
      await expectStatus(tester, 'U5', de.commonEvent);

      // Done on the appointment day.
      await tickCard(tester, 'U5');
      await tap(tester, find.text(de.dueDoneDate(md(yesterday))));
      await tester.pump(const Duration(milliseconds: 500));
      await expectStatus(tester, 'U5', de.commonDoneLower);
      expect(
        inCard('U5', find.text(de.kidsDate(yMMMd(yesterday)))),
        findsOneWidget,
      );
      final done = state.engine!
          .childEntries(id)
          .singleWhere((e) => e.refId == 'U5');
      expect(done.planned, isFalse);

      // A future appointment done: today.
      await tickCard(tester, 'U6');
      await tap(tester, find.text(de.dueAddAppointment));
      await tap(tester, inSheet(find.textContaining('Am ')));
      await typeDate(tester, inDays(30));
      await tap(tester, inSheet(find.text(de.kidsSaveAppointment)));
      await waitGone(tester, sheet());
      await tickCard(tester, 'U6');
      await tap(tester, find.text(de.dueDoneToday));
      await tester.pump(const Duration(milliseconds: 500));
      await expectStatus(tester, 'U6', de.commonDoneLower);
      expect(
        inCard('U6', find.text(de.kidsDate(yMMMd(today())))),
        findsOneWidget,
      );
      debugPrint('E2E KIN-018 notes: $problems');
      await finish(tester, state);
    },
  );

  // The time of a booked appointment (" um {time} Uhr", app_de.arb
  // "remindersTime") is joined with single spaces (#544).
  testWidgets(
    'KIN-018 the appointment time in the timeline has single spaces',
    (tester) async {
      final id = await seedChild('E2E Leerzeichenkind', born(days: 65));
      final date = inDays(21);
      await seedEntries([
        ChildEntry(
          id: uid('entry'),
          childId: id,
          kind: ChildEntryKind.checkup,
          date: date,
          refId: 'U5',
          planned: true,
          time: '09:30',
        ),
      ]);
      final state = await start(tester);
      await openChild(tester, 'E2E Leerzeichenkind');
      await tab(tester, de.kidsTabTimeline);
      await waitFor(tester, find.text(de.tasksComingUp));
      final row = find.textContaining('um 09:30 Uhr · Termin');
      await scrollTo(tester, row);
      final shown = tester.widget<Text>(row.first).data!;
      debugPrint('E2E KIN-018 the row reads "$shown"');
      expect(shown, startsWith(yMMMd(date)));
      expect(shown, isNot(contains('  ')), reason: 'two spaces in "$shown"');
      await finish(tester, state);
    },
  );

  testWidgets('KIN-034 earlier check-ups and vaccinations at once', (
    tester,
  ) async {
    final id = await seedChild('E2E Nachtragkind', born(years: 3));
    final state = await start(tester);
    await openChild(tester, 'E2E Nachtragkind');

    Future<int> markPast(String what, String title, String skip) async {
      final button = find.textContaining('frühere $what nachtragen');
      await scrollTo(tester, button, up: true);
      final count = int.parse(
        tester.widget<Text>(button.first).data!.split(' ').first,
      );
      await tap(tester, button);
      await waitFor(tester, find.text(title));
      expect(find.text(de.dueRecordDoneWithoutExact), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNWidgets(count));
      await tap(tester, find.widgetWithText(CheckboxListTile, skip));
      await tap(tester, find.text(de.dueAddCount(count - 1)));
      await dialogClosed(tester);
      return count;
    }

    await tab(tester, de.kidsTabCheckups);
    const u2 = 'U2 – Neugeborenen-Basisuntersuchung';
    final checkups = await markPast('Vorsorgen', de.dueAddEarlierCheckups, u2);
    await until(
      tester,
      () =>
          state.engine!
              .childEntries(id)
              .where((e) => e.kind == ChildEntryKind.checkup)
              .length ==
          checkups - 1,
      'check-ups recorded',
    );
    await expectStatus(tester, u2, de.duePeriodOver);
    const u1 = 'U1 – Neugeborenen-Erstuntersuchung';
    await expectStatus(tester, u1, de.commonDoneLower);
    expect(inCard(u1, find.text(de.dueDoneDateUnknown)), findsOneWidget);

    await tab(tester, de.kidsTabVaccinations);
    final vaccinations = await markPast(
      'Impfungen',
      de.dueAddEarlierVaccinations,
      'Rotaviren – 1. Dosis',
    );
    await until(
      tester,
      () =>
          state.engine!
              .childEntries(id)
              .where((e) => e.kind == ChildEntryKind.vaccination)
              .length ==
          vaccinations - 1,
      'vaccinations recorded',
    );
    final six =
        'Sechsfach (Tetanus, Diphtherie, Keuchhusten, Hib, Polio, Hepatitis B) – 1. Dosis';
    await expectStatus(tester, six, de.commonDoneLower);
    expect(inCard(six, find.text(de.dueDoneDateUnknown)), findsOneWidget);
    await expectStatus(tester, 'Rotaviren – 1. Dosis', de.dueNotRecorded);
    expect(state.engine!.childEntries(id).every((e) => e.dateUnknown), isTrue);
    await finish(tester, state);
  });

  // With all four choices the sheet of a vaccination fits the Mac app's own
  // default window (800 × 600, MainMenu.xib:338): it scrolls when its
  // subtitle wraps (#544). The other tests run in a taller view.
  testWidgets('KIN-029 the due sheet fits the default window', (tester) async {
    await seedChild('E2E Fensterkind', born(days: 28));
    final state = await startApp(tester);
    await openChild(tester, 'E2E Fensterkind');
    await tab(tester, de.kidsTabCheckups);
    debugPrint('E2E KIN-029 sheet of U3');
    await tickCard(tester, 'U3');
    await waitFor(tester, find.text(de.dueDoneToday));
    await closeSheet(tester);
    await tab(tester, de.kidsTabVaccinations);
    debugPrint('E2E KIN-029 sheet of rota_1');
    await tickCard(tester, 'Rotaviren – 1. Dosis');
    await waitFor(tester, find.text(de.dueDoneToday));
    await scrollTo(tester, inSheet(find.text(de.dueDoneDateUnknown2)));
    await closeSheet(tester);
    await finish(tester, state);
  });

  // With a booked vaccination the card's chip shows "Impfung" and the date,
  // as the start page does, not the internal id (#544).
  testWidgets('KIN-035 chip of the child card: next due, booked appointment', (
    tester,
  ) async {
    await seedChild('E2E Chipkind', born(days: 28));
    final state = await start(tester);
    await kidsList(tester);
    await inKidsList(tester, find.text('E2E Chipkind'));
    final chip = find.descendant(
      of: cardOf('E2E Chipkind'),
      matching: find.text(de.kidsWhatNow('U3')),
    );
    expect(chip, findsOneWidget);
    final chipWidget =
        tester.widget(find.ancestor(of: chip, matching: byTypeName('_Chip')))
            as dynamic;
    expect(
      chipWidget.color,
      Theme.of(tester.element(chip)).colorScheme.error,
      reason: 'an open check-up is red',
    );
    await tap(tester, chip);
    await waitFor(tester, find.text(de.dueDoneToday));
    await closeSheet(tester);

    await openChild(tester, 'E2E Chipkind');
    await tab(tester, de.kidsTabVaccinations);
    final date = inDays(14);
    await tickCard(tester, 'Rotaviren – 1. Dosis');
    await tap(tester, find.text(de.dueAddAppointment));
    await tap(tester, inSheet(find.textContaining('Am ')));
    await typeDate(tester, date);
    await tap(tester, inSheet(find.text(de.kidsSaveAppointment)));
    await waitGone(tester, sheet());
    await openSection(tester, 'Start');
    await scrollTo(
      tester,
      find.text(de.homeWhatDate(de.commonVaccination, md(date))),
    );
    await kidsList(tester);
    await inKidsList(tester, find.text('E2E Chipkind'));
    final texts = find
        .descendant(of: cardOf('E2E Chipkind'), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .toList();
    expect(
      texts.any(
        (t) => t.contains(de.commonVaccination) && t.contains(md(date)),
      ),
      isTrue,
      reason: 'card shows: $texts',
    );
    await finish(tester, state);
  });

  testWidgets(
    'KIN-038 KIN-042 rotavirus past its limit, recorded with a photo',
    (tester) async {
      final picker = fakePicker();
      final birth = born(days: 91);
      final id = await seedChild('E2E Rotakind', birth);
      final state = await start(tester);
      await openChild(tester, 'E2E Rotakind');
      await tab(tester, de.kidsTabVaccinations);
      for (final dose in ['1. Dosis', '2. Dosis', '3. Dosis']) {
        await expectStatus(tester, 'Rotaviren – $dose', de.dueNotRecorded);
      }
      await tickCard(tester, 'Rotaviren – 1. Dosis');
      await waitFor(tester, find.text(de.dueOtherDateMeasurementsNote));
      expect(find.text(de.dueDoneDateUnknown2), findsOneWidget);
      expect(find.text(de.dueDoneToday), findsNothing);
      expect(find.text(de.dueAddAppointment), findsNothing);
      await tap(tester, find.text(de.dueOtherDateMeasurementsNote));
      await waitFor(tester, inSheet(find.text('Rotaviren – 1. Dosis')));
      final given = DateTime(birth.year, birth.month, birth.day + 56);
      await tap(tester, inSheet(find.byType(InputChip)));
      await pickDate(tester, given);
      picker.picks.add(await picture('impfpass.png'));
      await tap(tester, inSheet(find.byTooltip(de.kidsAddPhoto)));
      await waitFor(tester, inSheet(find.byType(CachedImage)));
      await enter(tester, field(de.contactsNoteOptional), 'E2E Impfpass');
      await tap(tester, inSheet(find.text(de.kidsDone)));
      await waitGone(tester, sheet());
      await expectStatus(tester, 'Rotaviren – 1. Dosis', de.commonDoneLower);
      await expectStatus(tester, 'Rotaviren – 2. Dosis', de.dueDueNow);
      await expectStatus(tester, 'Rotaviren – 3. Dosis', de.pregnancySoon);
      await tickCard(tester, 'Rotaviren – 2. Dosis');
      await waitFor(tester, find.text(de.dueDoneToday));
      await closeSheet(tester);

      // KIN-042: the photo in the timeline.
      await tab(tester, de.kidsTabTimeline);
      final title = de.kidsVaccinationTitleDose('Rotaviren', '1. Dosis');
      await scrollTo(tester, find.text(title));
      final row = find
          .ancestor(
            of: find.text(title),
            matching: find.byType(IntrinsicHeight),
          )
          .first;
      expect(
        find.descendant(of: row, matching: find.byType(CachedImage)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('E2E Impfpass')),
        findsOneWidget,
      );
      expect(state.engine!.childEntries(id).single.photos, hasLength(1));
      await finish(tester, state);
    },
  );

  // =========================================================================
  // Growth
  // =========================================================================

  testWidgets('KIN-043 KIN-044 KIN-046 KIN-048 measurements without sex', (
    tester,
  ) async {
    final id = await seedChild('E2E Messkind', born(months: 6));
    final state = await start(tester);
    await openChild(tester, 'E2E Messkind');

    // KIN-043: the log's "Messen" opens the same editor.
    await tapQuick(tester, de.kidsLogMeasure);
    await waitFor(tester, inSheet(find.text(de.kidsMeasurement)));
    expect(inSheet(field(de.kidsHeightCm)), findsOneWidget);
    await closeSheet(tester);

    await tab(tester, de.kidsTabGrowth);
    await tap(tester, find.text(de.growthAddMeasurement));
    await waitFor(tester, inSheet(find.text(de.kidsMeasurement)));
    await tap(tester, inSheet(find.text(de.commonSave)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(sheet(), findsOneWidget);
    expect(state.engine!.childEntries(id), isEmpty);
    await enter(tester, field(de.kidsHeightCm), '60');
    await enter(tester, field(de.kidsWeightKg), '5,8');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await waitGone(tester, sheet());
    final child = state.engine!.child(id)!;
    final first = find.widgetWithText(ListTile, '60 cm · 5,8 kg');
    await scrollTo(tester, first);
    expect(
      find.descendant(
        of: first,
        matching: find.text(
          '${yMMMd(today())} · ${de.growthAge(ageLabel(child, today()))}',
        ),
      ),
      findsOneWidget,
    );
    // KIN-044: one measurement, no curve yet.
    expect(find.text(de.growthCurveAppearsHereTwo), findsOneWidget);
    expect(byTypeName('_ChartCard'), findsNothing);
    await tap(tester, find.text(de.growthAddMeasurement));
    await enter(tester, field(de.kidsHeightCm), '57');
    await enter(tester, field(de.kidsWeightKg), '5,1');
    await tap(tester, inSheet(find.byType(InputChip)));
    await pickDate(tester, inDays(-30));
    await tap(tester, inSheet(find.text(de.commonSave)));
    await waitGone(tester, sheet());
    final cards = [
      await chartCard(tester, de.kidsHeightCm),
      await chartCard(tester, de.kidsWeightKg),
    ];
    expect(find.text(de.growthCurveAppearsHereTwo), findsNothing);
    // KIN-046: without sex, only the child's own line.
    for (final c in cards) {
      expect(c.reference, isNull);
      expect(c.percentile, isNull);
    }
    expect(find.textContaining(RegExp(r'^Perzentile \d+$')), findsNothing);
    await scrollTo(tester, find.text(de.growthGenderProfileFamioShows));
    await tap(tester, find.byTooltip(de.commonEdit));
    await scrollTo(tester, find.text(de.kidsOnlyWhoGrowthCharts));
    await back(tester);

    // KIN-048: change, then delete.
    await tab(tester, de.kidsTabGrowth);
    await scrollTo(tester, first);
    await tap(tester, first);
    await waitFor(tester, inSheet(find.text(de.commonDelete)));
    await enter(tester, field(de.kidsHeightCm), '61');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await waitGone(tester, sheet());
    final changed = find.widgetWithText(ListTile, '61 cm · 5,8 kg');
    await scrollTo(tester, changed);
    final height = await chartCard(tester, de.kidsHeightCm);
    expect((height.points as List).map((p) => p.$2), contains(61.0));
    await scrollTo(tester, changed);
    await tap(tester, changed);
    await tap(tester, inSheet(find.text(de.commonDelete)));
    await waitGone(tester, sheet());
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(ListTile, '61 cm · 5,8 kg'), findsNothing);
    expect(state.engine!.childEntries(id), hasLength(1));
    await finish(tester, state);
  });

  testWidgets('KIN-045 WHO curves and percentile until 24 months', (
    tester,
  ) async {
    final small = await seedChild(
      'E2E WHO Junge',
      born(months: 6),
      sex: ChildSex.male,
    );
    final big = await seedChild(
      'E2E Großer Junge',
      born(months: 30),
      sex: ChildSex.male,
    );
    final state = await start(tester);
    await arrives(
      tester,
      state,
      (e) => e.child(small) != null && e.child(big) != null,
      'children',
    );
    final a = state.engine!.child(small)!, b = state.engine!.child(big)!;
    await seedEntries([
      for (final (c, m, kg) in [
        (a, 4, 7.0),
        (a, 6, 7.9),
        (b, 26, 12.2),
        (b, 29, 12.9),
      ])
        ChildEntry(
          id: uid('entry'),
          childId: c.id,
          kind: ChildEntryKind.measurement,
          date: DateUtils.dateOnly(c.ageDate(m)),
          weightKg: kg,
        ),
    ]);
    await arrives(
      tester,
      state,
      (e) =>
          e.childEntries(small).length == 2 && e.childEntries(big).length == 2,
      'measurements',
    );
    Future<dynamic> weightCard() => chartCard(tester, de.kidsWeightKg);

    await openChild(tester, 'E2E WHO Junge');
    await tab(tester, de.kidsTabGrowth);
    expect((await weightCard()).reference, isNotNull);
    expect(find.textContaining(RegExp(r'^Perzentile \d+$')), findsWidgets);
    await scrollTo(tester, find.text(de.growthGrayWhoGrowthStandards));

    await openChild(tester, 'E2E Großer Junge');
    await tab(tester, de.kidsTabGrowth);
    final older = await weightCard();
    expect(older.percentile, isNull);
    for (final x in [26.0, 27.5, 29.0]) {
      expect((older.reference as dynamic)(x), isNull, reason: 'at $x months');
    }
    expect(find.textContaining(RegExp(r'^Perzentile \d+$')), findsNothing);
    await finish(tester, state);
  });

  // =========================================================================
  // Daily log
  // =========================================================================

  testWidgets(
    'KIN-049 KIN-050 KIN-051 KIN-052 KIN-053 KIN-054 empty log, nursing and sleep',
    (tester) async {
      final id = await seedChild('E2E Stillkind', born(months: 2));
      final state = await start(tester);
      await openChild(tester, 'E2E Stillkind');
      // KIN-049.
      for (final b in [
        de.kidsLogBreastfeeding,
        de.kidsLogBottle,
        de.kidsLogSleep,
        de.kidsLogPee,
        de.kidsLogPoo,
        de.kidsLogPeePoo,
        de.kidsLogSolids,
        'Getränk',
        de.kidsLogTemperature,
        de.kidsLogMedication,
        de.kidsLogSymptom,
        de.kidsLogPump,
        de.kidsLogBath,
        'Spaziergang',
        de.kidsLogMeasure,
      ]) {
        expect(find.text(b), findsWidgets, reason: b);
      }
      await scrollTo(tester, find.text(de.kidsLogNoEntriesYetTap));
      await scrollTo(tester, find.text(de.kidsLogFamioDoesNotReplace));

      // KIN-050: last time on the right.
      await seedLogs([
        await logOf(
          id,
          LogKind.breast,
          ago(const Duration(hours: 2)),
          end: ago(const Duration(hours: 1, minutes: 45)),
          side: BreastSide.right,
        ),
      ]);
      await arrives(tester, state, (e) => e.childLogs(id).isNotEmpty, 'log');
      await tapQuick(tester, de.kidsLogBreastfeeding);
      await waitFor(tester, find.text(de.kidsLogStartBreastfeeding));
      expect(
        find.text(de.kidsLogLastTimeLastStart('rechts', 'links')),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, de.kidsLogLeft), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, de.kidsLogRight),
        findsOneWidget,
      );
      await tap(tester, find.widgetWithText(FilledButton, de.kidsLogLeft));
      final running = state.engine!.childLogs(id).firstWhere((l) => l.running);
      await waitFor(
        tester,
        find.text(
          de.kidsLogBreastfeedingSideSinceSince(
            'links',
            DateFormat.jm('de').format(running.start),
          ),
        ),
      );
      final clock = find.textContaining(RegExp(r'^\d+:\d\d$'));
      final t1 = tester.widget<Text>(clock.first).data;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<Text>(clock.first).data, isNot(t1));
      await tap(tester, find.text(de.kidsLogBreastfeedingRunning));
      expect(find.text(de.kidsLogStartBreastfeeding), findsNothing);
      expect(state.engine!.childLogs(id).where((l) => l.running), hasLength(1));

      // KIN-051 (the running card sits above the buttons, out of view).
      await scrollTo(tester, find.byTooltip(de.kidsLogSwitchSide), up: true);
      await tap(tester, find.byTooltip(de.kidsLogSwitchSide));
      await until(
        tester,
        () =>
            state.engine!.childLogs(id).where((l) => l.running).single.side ==
            BreastSide.right,
        'right side running',
      );
      await waitFor(tester, find.textContaining('Stillen rechts seit '));
      await scrollTo(tester, find.textContaining('Stillen links · '));
      await scrollTo(
        tester,
        find.textContaining('Stillen rechts · läuft seit'),
      );

      // KIN-052.
      await scrollTo(tester, find.text(de.kidsLogStop), up: true);
      await tap(tester, find.text(de.kidsLogStop));
      await waitFor(tester, inSheet(find.text('Stillen')));
      expect(state.engine!.childLogs(id).where((l) => l.running), isEmpty);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      await waitFor(tester, find.text(de.kidsLogNextSideSide('links')));
      expect(find.textContaining('Zuletzt gefüttert '), findsOneWidget);

      // KIN-053: afterwards, 15 minutes; then an end before the start.
      await tapQuick(tester, de.kidsLogBreastfeeding);
      await tap(tester, find.text(de.kidsLogAddAfterwards));
      await waitFor(tester, inSheet(find.text(de.kidsLogAddKind('Stillen'))));
      expect(inSheet(find.textContaining('Beginn: ')), findsOneWidget);
      expect(inSheet(find.textContaining('Ende: ')), findsOneWidget);
      expect(inSheet(find.text('15 min')), findsOneWidget);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      await scrollTo(tester, find.text('Stillen links · 15 min'));
      await tapQuick(tester, de.kidsLogBreastfeeding);
      await tap(tester, find.text(de.kidsLogAddAfterwards));
      final wrong = ago(const Duration(minutes: 30));
      await tap(tester, inSheet(find.textContaining('Ende: ')));
      await pickDate(tester, DateUtils.dateOnly(wrong));
      await pickTime(tester, wrong.hour, wrong.minute);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitFor(tester, snackText(de.commonEndBeforeStart));
      expect(sheet(), findsOneWidget);
      await closeSheet(tester);
      await snackGone(tester);

      // KIN-054: sleep with one tap.
      await tapQuick(tester, de.kidsLogSleep);
      final sleep = state.engine!
          .childLogs(id)
          .firstWhere((l) => l.kind == LogKind.sleep && l.running);
      await scrollTo(
        tester,
        find.text(
          de.kidsLogAsleepSinceSince(DateFormat.jm('de').format(sleep.start)),
        ),
        up: true,
      );
      await scrollTo(tester, quickButton(de.kidsLogWokeUp));
      expect(find.text(de.kidsLogWokeUp), findsOneWidget);
      await openSection(tester, 'Start');
      await scrollTo(
        tester,
        find.text(
          'E2E Stillkind · ${de.homeAsleepSinceTime(timeLabel(sleep.start))}',
        ),
      );
      await openSection(tester, 'Kinder');
      await waitFor(tester, find.byType(ChildScreen));
      final awake = sleep.start.add(const Duration(seconds: 62));
      while (DateTime.now().isBefore(awake)) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tapQuick(tester, de.kidsLogWokeUp);
      await scrollTo(tester, find.text(de.kidsLogSleepDuration('1 min')));
      await scrollTo(tester, byTypeName('_SummaryCard'), up: true);
      expect(summaryValue(tester, de.kidsLogSleepNoun), '1 min');
      await finish(tester, state);
    },
  );

  testWidgets(
    'KIN-057 KIN-059 KIN-061 KIN-062 KIN-063 KIN-065 log entries, edit and undo',
    (tester) async {
      final picker = fakePicker();
      final id = await seedChild('E2E Breikind', born(months: 8));
      final state = await start(tester);
      await openChild(tester, 'E2E Breikind');
      Future<void> quick(String label) => tapQuick(tester, label);

      Future<String?> total(String label) async {
        await scrollTo(tester, byTypeName('_SummaryCard'));
        return summaryValue(tester, label);
      }

      // KIN-057.
      await quick(de.kidsLogBottle);
      await waitFor(
        tester,
        inSheet(find.text(de.kidsLogAddKind('Fläschchen'))),
      );
      for (final m in ['Muttermilch', 'Pre-Milch', 'Andere']) {
        expect(inSheet(find.text(m)), findsOneWidget, reason: m);
      }
      for (final ml in [60, 90, 120, 150, 180, 210]) {
        expect(inSheet(find.widgetWithText(ActionChip, '$ml')), findsOneWidget);
      }
      expect(inSheet(field('Menge (ml)')), findsOneWidget);
      await tap(tester, inSheet(find.text('Pre-Milch')));
      await tap(tester, inSheet(find.widgetWithText(ActionChip, '120')));
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      await scrollTo(tester, find.text('Fläschchen · 120 ml · Pre-Milch'));
      expect(await total(de.kidsLogMilk), '120 ml');
      expect(await total(de.kidsLogMeals), '1');

      // KIN-059.
      await quick(de.kidsLogSolids);
      await enter(tester, field(de.kidsLogWhatWas), 'E2E Möhre');
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      await scrollTo(tester, find.text(de.kidsLogSolidsNote('E2E Möhre')));
      expect(await total(de.kidsLogMeals), '2');

      // KIN-061: pumped, without a side.
      await quick(de.kidsLogPump);
      await tap(tester, inSheet(find.text(de.kidsLogLeft)));
      await enter(tester, field('Menge (ml)'), '90');
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      await scrollTo(tester, find.text('Abgepumpt · 90 ml'));
      expect(
        state.engine!
            .childLogs(id)
            .singleWhere((l) => l.kind == LogKind.pumping)
            .side,
        isNull,
      );
      expect(await total(de.kidsLogMeals), '2');

      // KIN-062.
      await quick(de.kidsLogBath);
      await waitFor(tester, snackText(de.kidsLogBathAdded));
      await scrollTo(tester, find.text(de.kidsLogBathed));
      await snackGone(tester);
      await scrollTo(tester, quickButton(de.kidsLogBath), up: true);
      await tester.longPress(quickButton(de.kidsLogBath));
      await tester.pump(const Duration(milliseconds: 600));
      await waitFor(tester, inSheet(find.text(de.kidsLogAddKind('Baden'))));
      await closeSheet(tester);

      // KIN-063.
      await quick(de.kidsLogSymptom);
      for (final s in [
        'Husten',
        'Schnupfen',
        'Ausschlag',
        'Erbrechen',
        'Durchfall',
        'Bauchweh',
        'Zahnen',
        'Verletzung',
      ]) {
        expect(
          inSheet(find.widgetWithText(ChoiceChip, s)),
          findsOneWidget,
          reason: s,
        );
      }
      await tap(tester, inSheet(find.widgetWithText(ChoiceChip, 'Ausschlag')));
      final symptomField = tester.widget<TextField>(
        inSheet(field(de.kidsLogSymptom)).last,
      );
      expect(symptomField.controller!.text, 'Ausschlag');
      picker.picks.add(await picture('ausschlag.png'));
      await tap(tester, inSheet(find.byTooltip(de.tasksAddPhoto)));
      await waitFor(tester, inSheet(find.byType(FileThumb)));
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      await scrollTo(tester, find.text('Ausschlag'));
      expect(
        find.descendant(
          of: logRow('Ausschlag'),
          matching: find.byIcon(AppIcons.image),
        ),
        findsOneWidget,
      );

      // KIN-065: another time, deleted and back.
      final now = DateTime.now();
      final earlier = now.hour >= 2
          ? now.subtract(const Duration(hours: 2))
          : DateTime(now.year, now.month, now.day, 0, 1);
      await scrollTo(tester, find.text(de.kidsLogBathed));
      await tap(tester, find.text(de.kidsLogBathed));
      await tap(tester, inSheet(find.textContaining('Zeit: ')));
      await pickDate(tester, DateUtils.dateOnly(earlier));
      await pickTime(tester, earlier.hour, earlier.minute);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      final at = DateFormat.jm('de').format(
        DateTime(now.year, now.month, now.day, earlier.hour, earlier.minute),
      );
      await scrollTo(tester, find.text(de.kidsLogBathed));
      expect(
        find.descendant(of: logRow(de.kidsLogBathed), matching: find.text(at)),
        findsOneWidget,
      );
      final bath = state.engine!
          .childLogs(id)
          .singleWhere((l) => l.kind == LogKind.bath);
      await tap(tester, find.text(de.kidsLogBathed));
      await tap(tester, inSheet(find.text(de.commonDelete)));
      await waitFor(tester, snackText(de.undoDeleted));
      expect(state.engine!.childLogs(id).any((l) => l.id == bath.id), isFalse);
      await undo(tester);
      await until(
        tester,
        () => state.engine!.childLogs(id).any((l) => l.id == bath.id),
        'bath back',
      );
      await scrollTo(tester, find.text(de.kidsLogBathed));
      await finish(tester, state);
    },
  );

  // An amount with a decimal comma ("120,5") is rounded to whole ml, not
  // dropped (#544).
  testWidgets('KIN-057 a decimal amount is not dropped silently', (
    tester,
  ) async {
    final id = await seedChild('E2E Kommakind', born(months: 4));
    final state = await start(tester);
    await openChild(tester, 'E2E Kommakind');
    await tapQuick(tester, de.kidsLogBottle);
    await waitFor(tester, inSheet(field('Menge (ml)')));
    await enter(tester, field('Menge (ml)'), '120,5');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await tester.pump(const Duration(seconds: 1));
    final told =
        find.byType(SnackBar).evaluate().isNotEmpty ||
        find.byType(AlertDialog).evaluate().isNotEmpty;
    final saved = state.engine!
        .childLogs(id)
        .where((l) => l.kind == LogKind.bottle)
        .toList();
    final amounts = [for (final l in saved) l.amountMl];
    debugPrint('E2E KIN-057 "120,5": saved $amounts, message: $told');
    expect(
      saved.isEmpty ? told : saved.single.amountMl != null,
      isTrue,
      reason: '"120,5" ml: saved amounts $amounts, message: $told',
    );
    expect(amounts, [121]);
    await finish(tester, state);
  });

  testWidgets('KIN-073 diapers and diarrhoea in the day card', (tester) async {
    final f = await theFamily();
    final id = await seedChild(
      'E2E Windelkind',
      born(months: 4),
      guardians: [f.adminMember.id, f.bea.id],
    );
    final state = await start(tester);
    await openChild(tester, 'E2E Windelkind');
    await tapQuick(tester, de.kidsLogPee);
    await waitFor(tester, snackText(de.kidsLogPeeAdded));
    await snackGone(tester);
    await tapQuick(tester, de.kidsLogPoo);
    await waitFor(tester, find.text(de.kidsLogHowWasStool));
    await tap(tester, inSheet(find.widgetWithText(ChoiceChip, 'Durchfall')));
    await tap(tester, inSheet(find.text(de.commonDone)));
    await waitGone(tester, sheet());
    await tapQuick(tester, de.kidsLogPeePoo);
    await waitFor(tester, find.text(de.kidsLogHowWasStool));
    await tap(tester, inSheet(find.text(de.commonDone)));
    await waitGone(tester, sheet());
    await scrollTo(tester, byTypeName('_SummaryCard'));
    expect(summaryValue(tester, de.kidsLogDiapers), '2 Pipi · 2 Kacka');
    expect(summaryValue(tester, de.kidsLogDiarrhea), '1');
    expect(state.engine!.childLogs(id), hasLength(3));
    await synced(tester, state);
    await finish(tester, state);
  });

  testWidgets(
    'KIN-005 KIN-067 other adult: own children only, guardians see entries with their author',
    (tester) async {
      final f = await theFamily();
      final state = await start(tester, user: 'e2e-bea');
      await kidsList(tester);
      await waitFor(tester, find.text('E2E Windelkind'));
      await scrollTo(tester, find.text(de.kidsMissingChildHint));
      expect(await anywhere(tester, find.text('E2E Testkind')), isFalse);
      await openChild(tester, 'E2E Windelkind');
      final pee = find.text(de.kidsLogDiaperKind(DiaperKind.wet.label).trim());
      await scrollTo(tester, pee);
      final avatar = find.descendant(
        of: logRow(de.kidsLogDiaperKind(DiaperKind.wet.label).trim()),
        matching: find.byType(MemberAvatar),
      );
      expect(avatar, findsOneWidget);
      expect(
        (tester.widget<MemberAvatar>(avatar).member as dynamic).id,
        f.adminMember.id,
      );
      final api = await sessionOf(f.bea);
      final child = (await pull(
        api,
        Collections.children,
      )).values.singleWhere((r) => r.data['name'] == 'E2E Windelkind');
      final logs = (await pull(
        api,
        Collections.childLogs,
      )).values.where((r) => r.data['childId'] == child.id);
      expect(logs, hasLength(3));
      for (final l in logs) {
        expect(l.visibleTo, unorderedEquals(child.visibleTo!));
      }
      await finish(tester, state);
    },
  );

  // In the chart "Verlauf" one diaper with pee and poo counts once, and a
  // temperature below 36 °C is drawn with its value, not as "–" like a day
  // without measuring (#544).
  testWidgets('KIN-074 KIN-084 the chart counts diapers and low temperatures', (
    tester,
  ) async {
    final id = await seedChild('E2E Verlaufkind', born(months: 3));
    final state = await start(tester);
    await openChild(tester, 'E2E Verlaufkind');
    await tapQuick(tester, de.kidsLogPeePoo);
    await waitFor(tester, find.text(de.kidsLogHowWasStool));
    await tap(tester, inSheet(find.text(de.commonDone)));
    await waitGone(tester, sheet());
    await typeTemperature(tester, '35,2');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await waitGone(tester, sheet());
    await until(tester, () => state.engine!.childLogs(id).length == 2, 'logs');
    final problems = <String>[];
    await series(tester, de.kidsLogMeals, de.kidsLogDiapers);
    final diapers = chart(tester);
    if ((diapers.values as List).last != 1.0) {
      problems.add('one diaper is drawn as ${(diapers.values as List).last}');
    }
    await series(tester, de.kidsLogDiapers, de.kidsLogTemperature);
    final temps = chart(tester);
    final v = (temps.values as List<double>).last;
    final baseline = temps.baseline as double;
    final shown = v <= baseline && baseline > 0
        ? '–'
        : (temps.format as String Function(double))(v);
    if (shown != '35,2') problems.add('35,2 °C is shown as "$shown"');
    expect(problems, isEmpty);
    await finish(tester, state);
  });

  testWidgets('KIN-089 KIN-092 day totals and the chart', (tester) async {
    final now = DateTime.now();
    if (now.hour < 3) {
      markTestSkipped('needs three hours of today');
      return;
    }
    final id = await seedChild('E2E Tageskind', born(months: 7));
    DateTime m(int minutes) => ago(Duration(minutes: minutes));
    await seedLogs([
      await logOf(
        id,
        LogKind.breast,
        m(150),
        end: m(140),
        side: BreastSide.left,
      ),
      await logOf(
        id,
        LogKind.bottle,
        m(120),
        amountMl: 120,
        milk: MilkKind.formula,
      ),
      await logOf(id, LogKind.sleep, m(110), end: m(80)),
      await logOf(id, LogKind.diaper, m(70), diaper: DiaperKind.wet),
      await logOf(id, LogKind.diaper, m(65), diaper: DiaperKind.dirty),
      await logOf(
        id,
        LogKind.drink,
        m(60),
        amountMl: 100,
        drink: DrinkKind.water,
      ),
      await logOf(id, LogKind.walk, m(50), end: m(30)),
      await logOf(id, LogKind.temperature, m(20), temperatureC: 37.4),
    ]);
    final state = await start(tester);
    await openChild(tester, 'E2E Tageskind');
    await arrives(tester, state, (e) => e.childLogs(id).length == 8, 'logs');
    await scrollTo(tester, byTypeName('_SummaryCard'));
    final expected = {
      de.kidsLogMeals: '2',
      de.kidsLogMilk: '120 ml',
      de.kidsLogBreastfeeding: '10 min',
      de.kidsLogSleepNoun: '30 min',
      de.kidsLogDiapers: '1 Pipi · 1 Kacka',
      de.kidsLogDrinks: '100 ml',
      de.kidsLogOutdoors: '20 min',
      de.kidsLogHighestTemp: '37,4 °C',
    };
    for (final MapEntry(key: label, value: value) in expected.entries) {
      expect(summaryValue(tester, label), value, reason: label);
    }

    // KIN-092: the week up to the day shown, the day strong; meals first.
    await scrollTo(tester, find.text(de.kidsLogHistory));
    var c = chart(tester);
    final dropdown = find.byWidgetPredicate((w) => w is DropdownButton);
    expect(
      ((tester.widget(dropdown) as dynamic).value as Enum).name,
      'feedings',
    );
    expect((c.values as List), hasLength(7));
    expect(c.highlight, 6);
    expect(c.showValues, isTrue);
    expect((c.values as List).last, 2.0);
    var current = de.kidsLogMeals;
    for (final (label, unit, value) in [
      (de.kidsLogMilk, 'in ml', 120.0),
      (de.kidsLogDrinks, 'in ml', 100.0),
      (de.kidsLogSleepNoun, 'in h', 0.5),
      (de.kidsLogDiapers, null, 2.0),
      (de.kidsLogTemperature, 'in °C (Tageshöchstwert)', 37.4),
    ]) {
      await series(tester, current, label);
      current = label;
      c = chart(tester);
      expect((c.values as List).last, closeTo(value, 0.01), reason: label);
      if (unit != null) {
        expect(find.text(unit), findsOneWidget, reason: unit);
      } else {
        expect(find.textContaining(RegExp(r'^in ')), findsNothing);
      }
    }
    // A month: one bar per day, no numbers.
    await scrollTo(tester, find.text(de.kidsLogMonth), up: true);
    await tap(
      tester,
      find.descendant(
        of: find.byWidgetPredicate((w) => w is SegmentedButton),
        matching: find.text(de.kidsLogMonth),
      ),
    );
    await scrollTo(tester, find.text(de.kidsLogHistory));
    c = chart(tester);
    final days = DateUtils.getDaysInMonth(now.year, now.month);
    expect((c.values as List), hasLength(days));
    expect(c.showValues, isFalse);
    expect(c.highlight, now.day - 1);
    await finish(tester, state);
  });

  testWidgets('KIN-064 status card above the log', (tester) async {
    final id = await seedChild('E2E Statuskind', born(months: 5));
    await seedLogs([
      await logOf(
        id,
        LogKind.breast,
        ago(const Duration(hours: 1, minutes: 15)),
        end: ago(const Duration(hours: 1)),
        side: BreastSide.right,
      ),
      await logOf(
        id,
        LogKind.diaper,
        ago(const Duration(minutes: 30)),
        diaper: DiaperKind.wet,
      ),
      await logOf(
        id,
        LogKind.temperature,
        ago(const Duration(minutes: 20)),
        temperatureC: 38.6,
      ),
      await logOf(
        id,
        LogKind.medication,
        ago(const Duration(minutes: 10)),
        medication: 'E2E Fiebersaft',
        dose: '5 ml',
        minIntervalHours: 6,
      ),
      await logOf(
        id,
        LogKind.medication,
        ago(const Duration(hours: 8)),
        medication: 'E2E Zäpfchen',
        minIntervalHours: 6,
      ),
    ]);
    final state = await start(tester);
    await openChild(tester, 'E2E Statuskind');
    await arrives(tester, state, (e) => e.childLogs(id).length == 5, 'logs');
    final logs = state.engine!.childLogs(id);
    final saft = logs.firstWhere((l) => l.medication == 'E2E Fiebersaft');
    final again = DateFormat.jm(
      'de',
    ).format(saft.start.add(const Duration(hours: 6)));
    for (final pattern in [
      // "vor 1 h" or, a minute on, "vor 1 h 1 min".
      r'^Zuletzt gefüttert vor 1 h( \d+ min)? \(Stillen rechts · 15 min\)$',
      '^${de.kidsLogNextSideSide('links')}\$',
      r'^Windel vor \d+ min$',
      r'^38,6 °C vor \d+ min$',
      '^E2E Fiebersaft vor \\d+ min · wieder ab ${RegExp.escape(again)}\$',
      '^E2E Zäpfchen vor 8 h( \\d+ min)? · wieder möglich\$',
    ]) {
      expect(
        find.textContaining(RegExp(pattern)),
        findsOneWidget,
        reason: pattern,
      );
    }
    await finish(tester, state);
  });

  testWidgets('KIN-085 medicine in the log, recent ones as chips', (
    tester,
  ) async {
    final id = await seedChild('E2E Saftbaby', born(months: 9));
    await seedLogs([
      for (var i = 1; i <= 5; i++)
        await logOf(
          id,
          LogKind.medication,
          ago(Duration(days: i)),
          medication: 'E2E Altmittel $i',
        ),
    ]);
    final state = await start(tester);
    await openChild(tester, 'E2E Saftbaby');
    await arrives(tester, state, (e) => e.childLogs(id).length == 5, 'logs');
    await tapQuick(tester, de.kidsLogMedication);
    await tap(tester, inSheet(find.text(de.commonSave)));
    await waitFor(tester, snackText(de.kidsLogPleaseEnterMedication));
    await enter(tester, field(de.kidsLogMedication), 'E2E Fiebersaft');
    await enter(tester, field(de.kidsLogDose), '5 ml');
    await enter(tester, field('Mindestabstand (h)'), '6');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await waitGone(tester, sheet());
    await snackGone(tester);
    await scrollTo(tester, find.text('E2E Fiebersaft · 5 ml'));

    await tapQuick(tester, de.kidsLogMedication);
    await waitFor(tester, inSheet(find.byType(ActionChip)));
    expect(inSheet(find.byType(ActionChip)), findsNWidgets(5));
    expect(
      inSheet(find.widgetWithText(ActionChip, 'E2E Altmittel 5')),
      findsNothing,
    );
    await tap(
      tester,
      inSheet(find.widgetWithText(ActionChip, 'E2E Fiebersaft')),
    );
    String text(String label) =>
        tester.widget<TextField>(inSheet(field(label)).last).controller!.text;
    expect(text(de.kidsLogMedication), 'E2E Fiebersaft');
    expect(text(de.kidsLogDose), '5 ml');
    expect(text('Mindestabstand (h)'), '6');
    await closeSheet(tester);
    await finish(tester, state);
  });

  // =========================================================================
  // Temperature and fever
  // =========================================================================

  testWidgets(
    'KIN-075 KIN-076 KIN-079 KIN-080 KIN-081 temperatures of a three-year-old',
    (tester) async {
      final id = await seedChild('E2E Fieber Drei', born(years: 3));
      final state = await start(tester);
      await openChild(tester, 'E2E Fieber Drei');
      await tab(tester, de.kidsTabLog);
      final warnings = de.healthCall112RightAway;

      Future<void> saveAndExpectDialog(String title, String text) async {
        await tap(tester, inSheet(find.text(de.commonSave)));
        await waitFor(tester, find.byType(AlertDialog));
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(title),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(de.kidsLogTextFamioDoesNot(text)),
          ),
          findsOneWidget,
        );
        await tap(tester, find.text(de.commonUnderstood).last);
        await dialogClosed(tester);
      }

      // KIN-075: 30 to 45 °C only.
      await typeTemperature(tester, '29');
      expect(inSheet(find.text(de.healthMeasuredRectally)), findsOneWidget);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitFor(tester, snackText(de.kidsLogPleaseEnterTemperatureBetween));
      await snackGone(tester);
      await typeTemperature(tester, '46');
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitFor(tester, snackText(de.kidsLogPleaseEnterTemperatureBetween));
      await snackGone(tester);
      await typeTemperature(tester, '37,2');
      expect(byTypeName('_AdviceBox'), findsNothing);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      expect(find.byType(AlertDialog), findsNothing);
      await scrollTo(tester, inLog('37,2 °C'));

      // KIN-076: fever.
      await typeTemperature(tester, '38,7');
      final fever = de.healthFeverLetChildDrink(warnings);
      expect(adviceText(tester, FeverLevel.fever), fever);
      await saveAndExpectDialog(de.kidsLogFever, fever);
      final row = inLog('38,7 °C');
      await scrollTo(tester, row);
      expect(
        tester.widget<Text>(row.first).style?.color,
        Theme.of(tester.element(row.first)).colorScheme.error,
      );

      // KIN-079: very low.
      await typeTemperature(tester, '34,5');
      final veryLow = de.healthVeryLowTemperature(warnings);
      expect(adviceText(tester, FeverLevel.doctor), veryLow);
      await saveAndExpectDialog(de.kidsLogContactPediatrician, veryLow);

      // KIN-080: low, no dialog.
      await typeTemperature(tester, '35,6');
      expect(
        adviceText(tester, FeverLevel.low),
        de.healthLowTemperatureMeasureAgain,
      );
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AlertDialog), findsNothing);

      // KIN-081: high and very high.
      await typeTemperature(tester, '40,1');
      await saveAndExpectDialog(
        de.kidsLogContactPediatrician,
        de.healthHighFeverContactPediatrician(warnings),
      );
      await typeTemperature(tester, '41,0');
      await saveAndExpectDialog(
        de.kidsLogPleaseGetMedicalHelp,
        de.healthVeryHighFeverGet(warnings),
      );
      expect(
        state.engine!.childLogs(id).where((l) => l.kind == LogKind.temperature),
        hasLength(6),
      );
      await finish(tester, state);
    },
  );

  testWidgets(
    'KIN-077 KIN-078 KIN-080 KIN-081 babies under three and six months',
    (tester) async {
      final t = today();
      await seedChild('E2E Säugling', born(days: 42));
      await seedChild(
        'E2E Fast drei',
        DateTime(t.year, t.month - 3, t.day + 1),
      );
      await seedChild('E2E Genau drei', DateTime(t.year, t.month - 3, t.day));
      await seedChild('E2E Vier Monate', born(months: 4));
      final state = await start(tester);
      final warnings = de.healthCall112RightAway;
      final baby =
          '${de.healthRaisedTemperatureMeasureAgain} '
          '${de.healthBabySignsWithoutFever} $warnings';

      Future<void> dialog(String title, String text) async {
        await tap(tester, inSheet(find.text(de.commonSave)));
        await waitFor(tester, find.byType(AlertDialog));
        expect(find.text(title), findsOneWidget);
        expect(find.text(de.kidsLogTextFamioDoesNot(text)), findsOneWidget);
        await tap(tester, find.text(de.commonUnderstood).last);
        await dialogClosed(tester);
      }

      // KIN-078: raised, a hint, no dialog.
      await openChild(tester, 'E2E Säugling');
      await typeTemperature(tester, '37,8');
      expect(adviceText(tester, FeverLevel.raised), baby);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitGone(tester, sheet());
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AlertDialog), findsNothing);
      // KIN-080 for a baby: low, with the baby's hint.
      await typeTemperature(tester, '35,6');
      expect(
        adviceText(tester, FeverLevel.low),
        '${de.healthLowTemperatureMeasureAgain} '
        '${de.healthBabySignsWithoutFever} $warnings',
      );
      await closeSheet(tester);
      // KIN-077: 38 °C and more under three months.
      await typeTemperature(tester, '38,1');
      await dialog(
        de.kidsLogPleaseGetMedicalHelp,
        de.healthBabiesUnder3Months(warnings),
      );

      // Calendar months: a day before three months, and three months.
      await openChild(tester, 'E2E Fast drei');
      await typeTemperature(tester, '38,1');
      expect(
        adviceText(tester, FeverLevel.urgent),
        de.healthBabiesUnder3Months(warnings),
      );
      await closeSheet(tester);
      await openChild(tester, 'E2E Genau drei');
      await typeTemperature(tester, '38,1');
      expect(
        adviceText(tester, FeverLevel.raised),
        de.healthRaisedTemperatureMeasureAgain,
      );
      await closeSheet(tester);

      // KIN-081: 39,2 °C under six months.
      await openChild(tester, 'E2E Vier Monate');
      await typeTemperature(tester, '39,2');
      await dialog(
        de.kidsLogContactPediatrician,
        de.healthHighFeverContactPediatrician(warnings),
      );
      await finish(tester, state);
    },
  );

  testWidgets('KIN-082 how long the fever lasts, per child', (tester) async {
    final toddler = await seedChild('E2E Fieber Eins', born(years: 1));
    await seedChild('E2E Fieber Zweitkind', born(years: 1));
    final older = await seedChild('E2E Fieber Groß', born(years: 3));
    final longer = await seedChild('E2E Fieber Lang', born(years: 3));
    await seedLogs([
      await logOf(
        toddler,
        LogKind.temperature,
        ago(const Duration(hours: 26)),
        temperatureC: 38.6,
      ),
      await logOf(
        older,
        LogKind.temperature,
        ago(const Duration(hours: 26)),
        temperatureC: 38.6,
      ),
      await logOf(
        longer,
        LogKind.temperature,
        ago(const Duration(days: 4)),
        temperatureC: 38.6,
      ),
    ]);
    final state = await start(tester);
    final warnings = de.healthCall112RightAway;

    Future<void> measure(String child, String title, String text) async {
      await openChild(tester, child);
      await tab(tester, de.kidsTabLog);
      await typeTemperature(tester, '38,7');
      await tap(tester, inSheet(find.text(de.commonSave)));
      await waitFor(tester, find.byType(AlertDialog));
      expect(find.text(title), findsOneWidget, reason: child);
      expect(
        find.text(de.kidsLogTextFamioDoesNot(text)),
        findsOneWidget,
        reason: child,
      );
      await tap(tester, find.text(de.commonUnderstood).last);
      await dialogClosed(tester);
    }

    await measure(
      'E2E Fieber Eins',
      de.kidsLogContactPediatrician,
      de.healthFeverUnderTwoDay(warnings),
    );
    // The other child's measurement does not count.
    await measure(
      'E2E Fieber Zweitkind',
      de.kidsLogFever,
      de.healthFeverLetChildDrink(warnings),
    );
    // Older children: a day is not yet long.
    await measure(
      'E2E Fieber Groß',
      de.kidsLogFever,
      de.healthFeverLetChildDrink(warnings),
    );
    await measure(
      'E2E Fieber Lang',
      de.kidsLogContactPediatrician,
      de.healthFeverDaysDaysPlease(4, warnings),
    );
    await finish(tester, state);
  });

  // =========================================================================
  // Emergency
  // =========================================================================

  testWidgets('KIN-110 KIN-111 KIN-112 emergency page and data', (
    tester,
  ) async {
    final f = await theFamily();
    final id = await seedChild('E2E Notfallkind', born(years: 2, months: 3));
    await seed(f.admin, Collections.contacts, {
      uid('contact'): const FamilyContact(
        id: '',
        name: 'E2E Dr. Hausarzt',
        role: ContactRole.doctor,
        phone: '0301234',
      ).toData(),
    });
    final state = await start(tester);
    await openChild(tester, 'E2E Notfallkind');
    await tap(tester, find.byTooltip(de.kidsEmergencyTitle));
    await waitFor(tester, find.text(de.kidsEmergencyName('E2E Notfallkind')));

    // KIN-111 / KIN-112.
    await scrollTo(tester, find.text(de.kidsAddAllergiesPediatricianCo));
    await tap(tester, find.text(de.kidsAddAllergiesPediatricianCo));
    await waitFor(tester, find.text(de.kidsEmergencyData));
    expect(find.widgetWithText(ChoiceChip, 'E2E Dr. Hausarzt'), findsOneWidget);
    await tap(tester, find.widgetWithText(ActionChip, de.commonNew));
    await waitFor(tester, find.text(de.contactsNewContact));
    await enter(tester, field(de.commonName), 'E2E Dr. Kinderarzt');
    await enter(tester, field(de.contactsPhone), '0309876');
    await tap(tester, find.text(de.commonSave).last);
    await waitFor(tester, find.text(de.kidsEmergencyData));
    await waitFor(
      tester,
      find.widgetWithText(ChoiceChip, 'E2E Dr. Kinderarzt'),
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.widgetWithText(ChoiceChip, 'E2E Dr. Kinderarzt'),
          )
          .selected,
      isTrue,
    );
    final values = {
      de.kidsAllergies: 'E2E Erdnüsse',
      de.kidsPreexisting: 'E2E Asthma',
      de.kidsLongTermMedication: 'E2E Spray',
      de.kidsBloodType: 'E2E 0+',
      de.kidsInsurance: 'E2E Kasse',
      de.kidsInsuranceNumber: 'E2E 123',
      de.kidsOtherNotes: 'E2E Impfpass im Flur',
    };
    for (final MapEntry(key: label, value: value) in values.entries) {
      await enter(tester, field(label), value);
    }
    await scrollTo(tester, find.text(de.kidsVisibleChildSGuardians));
    await tap(tester, find.text(de.commonSave).last);
    await waitFor(tester, find.text(de.kidsEmergencyName('E2E Notfallkind')));
    for (final v in values.values) {
      await scrollTo(tester, find.text(v));
    }
    for (final important in ['E2E Erdnüsse', 'E2E Asthma']) {
      await scrollTo(tester, find.text(important));
      final style = tester.widget<Text>(find.text(important)).style!;
      expect(style.fontWeight, FontWeight.w800, reason: important);
      expect(
        style.color,
        Theme.of(tester.element(find.text(important))).colorScheme.error,
      );
    }
    final child = state.engine!.child(id)!;
    expect(child.name, 'E2E Notfallkind');
    expect(child.guardianIds, [await adminId()]);
    expect(child.emergency.allergies, 'E2E Erdnüsse');
    await scrollTo(tester, find.text('E2E Dr. Kinderarzt'), up: true);

    // KIN-110: what else is there: weight, the last day's log, contacts.
    await seedEntries([
      ChildEntry(
        id: uid('entry'),
        childId: id,
        kind: ChildEntryKind.measurement,
        date: inDays(-3),
        weightKg: 12.4,
      ),
    ]);
    await seedLogs([
      await logOf(
        id,
        LogKind.temperature,
        ago(const Duration(hours: 2)),
        temperatureC: 38.9,
      ),
      await logOf(
        id,
        LogKind.medication,
        ago(const Duration(hours: 1)),
        medication: 'E2E Zäpfchen',
        dose: '125 mg',
      ),
    ]);
    await seed(f.admin, Collections.contacts, {
      uid('contact'): FamilyContact(
        id: '',
        name: 'E2E Oma Kontakt',
        role: ContactRole.family,
        childIds: [id],
      ).toData(),
    });
    await arrives(
      tester,
      state,
      (e) => e.childLogs(id).length == 2 && e.childEntries(id).isNotEmpty,
      'log and weight',
    );
    await waitFor(tester, find.text(de.kidsAlsoWorksWithoutInternet));
    for (final text in [
      '112 – ${de.kidsEmergency}',
      de.kidsOutHoursMedicalService,
      de.kids116117WhenPractice,
      de.kidsPoisonControl,
      de.kids03019240ReachableNationwide,
      de.kidsPhone5WQuestions,
      de.kidsAge,
      de.kidsLogWeight,
      de.kidsWeightKgDate('12,4', yMd(inDays(-3))),
      de.kidsLogTemperature,
      de.kidsLastGiven,
      de.kidsOtherContacts,
      'E2E Oma Kontakt',
    ]) {
      await scrollTo(tester, find.text(text), up: true);
    }
    await scrollTo(tester, find.textContaining('E2E Zäpfchen · 125 mg um '));
    await scrollTo(tester, find.textContaining('38,9 °C um '));
    await finish(tester, state);
  });

  testWidgets('KIN-113 emergency page without a connection', (tester) async {
    final id = await seedChild(
      'E2E Offlinekind',
      born(years: 4),
      emergency: const EmergencyInfo(
        allergies: 'E2E Wespen',
        bloodType: 'E2E B-',
      ),
    );
    final state = await start(tester);
    await openChild(tester, 'E2E Offlinekind');
    await tap(tester, find.byTooltip(de.kidsEmergencyTitle));
    await waitFor(tester, find.text('E2E Wespen'));
    await synced(tester, state);

    // The app closed (its engine and local copy with it); opened again
    // without any connection.
    await tester.pumpWidget(const SizedBox());
    final first = state.engine!;
    state.engine = null;
    await first.dispose();
    first.store.close();
    state.files?.close();
    state.files = null;
    HttpOverrides.global = _NoNetwork();
    addTearDown(() => HttpOverrides.global = null);
    final again = AppState();
    await again.init();
    await tester.pumpWidget(FamioApp(state: again));
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    expect(again.engine!.child(id), isNotNull);
    await expectLater(again.engine!.api.me(), throwsA(isA<Object>()));
    await openChild(tester, 'E2E Offlinekind');
    await tap(tester, find.byTooltip(de.kidsEmergencyTitle));
    await waitFor(tester, find.text(de.kidsEmergencyName('E2E Offlinekind')));
    for (final text in [
      'E2E Wespen',
      'E2E B-',
      '112 – ${de.kidsEmergency}',
      de.kidsOutHoursMedicalService,
      de.kidsPoisonControl,
    ]) {
      await scrollTo(tester, find.text(text), up: true);
    }
    HttpOverrides.global = null;
    await finish(tester, again);
  });

  // =========================================================================
  // Medication plans
  // =========================================================================

  testWidgets('KIN-095 KIN-098 plan with two times, taken, skipped, undone', (
    tester,
  ) async {
    final f = await theFamily();
    await serviceAccount();
    await seedChild('E2E Saftkind', born(years: 5));
    final state = await start(tester);
    await openSection(tester, 'Medizin');
    await tap(tester, find.byTooltip(de.medsAddMedication));
    await waitFor(tester, find.text(de.medsNewMedication));
    await enter(tester, field(de.kidsLogMedication), 'E2E Saft');
    expect(find.widgetWithText(ActionChip, f.guest.displayName), findsNothing);
    expect(find.widgetWithText(ActionChip, 'E2E Dienst'), findsNothing);
    expect(find.widgetWithText(ActionChip, f.bea.displayName), findsOneWidget);
    await tap(tester, find.widgetWithText(ActionChip, 'E2E Saftkind'));
    await enter(tester, field(de.medsDosePrescribed), '5 ml');
    for (final (h, m) in [(8, 0), (20, 0)]) {
      await addTime(tester, h, m);
    }
    await waitFor(tester, find.widgetWithText(InputChip, '08:00'));
    await waitFor(tester, find.widgetWithText(InputChip, '20:00'));
    await tap(tester, find.byTooltip(de.commonSave));
    await medsList(tester);

    const line = 'E2E Saft · E2E Saftkind';
    Finder dose(String time) => find.ancestor(
      of: find.text(time),
      matching: find.ancestor(
        of: find.text(line),
        matching: find.byType(SoftCard),
      ),
    );
    for (final time in ['08:00', '20:00']) {
      await scrollTo(tester, dose(time));
      expect(
        find.descendant(
          of: dose(time).first,
          matching: find.textContaining('5 ml'),
        ),
        findsOneWidget,
      );
    }
    await scrollTo(tester, find.text('E2E Saftkind · 5 ml · 08:00, 20:00'));

    // KIN-098.
    await scrollTo(tester, dose('08:00'));
    await tap(
      tester,
      find.descendant(
        of: dose('08:00').first,
        matching: find.byTooltip(de.medsTaken),
      ),
    );
    await waitFor(
      tester,
      find.descendant(
        of: dose('08:00').first,
        matching: find.textContaining('genommen '),
      ),
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: dose('08:00').first, matching: find.text(line)),
          )
          .style
          ?.decoration,
      TextDecoration.lineThrough,
    );
    await scrollTo(tester, dose('20:00'));
    await tap(
      tester,
      find.descendant(
        of: dose('20:00').first,
        matching: find.text(de.medsSkip),
      ),
    );
    await waitFor(
      tester,
      find.descendant(
        of: dose('20:00').first,
        matching: find.textContaining(de.medsSkipped),
      ),
    );
    await scrollTo(tester, dose('08:00'));
    await tap(
      tester,
      find.descendant(
        of: dose('08:00').first,
        matching: find.byTooltip(de.commonUndo),
      ),
    );
    await waitFor(
      tester,
      find.descendant(
        of: dose('08:00').first,
        matching: find.byTooltip(de.medsTaken),
      ),
    );
    await tap(
      tester,
      find.descendant(
        of: dose('08:00').first,
        matching: find.byTooltip(de.medsTaken),
      ),
    );
    await scrollTo(tester, medCard('E2E Saft'));
    await tap(tester, medCard('E2E Saft'));
    await waitFor(tester, find.byTooltip(de.commonDelete));
    await scrollTo(tester, find.text(de.medsSkippedTime('20:00')));
    await scrollTo(tester, find.textContaining(RegExp('^Genommen ')));
    expect(find.widgetWithText(ListTile, kitAdminName), findsNWidgets(2));
    await back(tester);
    await finish(tester, state);
  });

  testWidgets('KIN-099 an open dose half an hour late is red', (tester) async {
    final late = ago(const Duration(minutes: 31));
    if (late.day != DateTime.now().day) {
      markTestSkipped('too close to midnight');
      return;
    }
    await seedMedication('E2E Spätsaft', times: [hhmm(late)]);
    final state = await start(tester);
    await openSection(tester, 'Medizin');
    final tile = find.ancestor(
      of: find.text('E2E Spätsaft'),
      matching: find.byType(SoftCard),
    );
    await scrollTo(tester, tile);
    final time = find.descendant(
      of: tile.first,
      matching: find.text(hhmm(late)),
    );
    expect(time, findsOneWidget);
    expect(tester.widget<Text>(time).style?.color, dangerOf(tester, time));
    final status = find.descendant(
      of: tile.first,
      matching: find.text(de.medsStillOpen),
    );
    expect(status, findsOneWidget);
    expect(tester.widget<Text>(status).style?.color, dangerOf(tester, status));
    await finish(tester, state);
  });

  testWidgets('KIN-100 two adults tick the same dose', (tester) async {
    final f = await theFamily();
    final med = await seedMedication(
      'E2E Doppelsaft',
      times: const ['12:00'],
      care: [f.adminMember.id, f.bea.id],
    );
    final state = await start(tester);
    await openSection(tester, 'Medizin');
    await arrives(tester, state, (e) => e.medication(med) != null, 'plan');
    final m = state.engine!.medication(med)!;
    final at = m.dosesOn(today()).single;
    final tile = find.ancestor(
      of: find.text('E2E Doppelsaft'),
      matching: find.byType(SoftCard),
    );
    await scrollTo(tester, tile);
    await tap(
      tester,
      find.descendant(of: tile.first, matching: find.byTooltip(de.medsTaken)),
    );
    await synced(tester, state);
    // Bea ticked it on her phone without connection; it arrives later.
    final bea = await sessionOf(f.bea);
    await tester.pump(const Duration(seconds: 1));
    await put(bea, Collections.medicationIntakes, {
      m.intakeId(at): MedicationIntake(
        id: m.intakeId(at),
        medicationId: med,
        at: DateTime.now(),
        byId: f.bea.id,
        scheduled: at,
      ).toData(visibleTo: m.careIds),
    });
    await synced(tester, state);
    final admin = await adminApi();
    final intakes = (await pull(
      admin,
      Collections.medicationIntakes,
    )).values.where((r) => r.data['medicationId'] == med).toList();
    expect(intakes, hasLength(1));
    final winner = intakes.single.data['byId'];
    if (winner == f.bea.id) {
      await until(
        tester,
        () => find
            .descendant(
              of: tile.first,
              matching: find.textContaining(' · ${f.bea.displayName}'),
            )
            .evaluate()
            .isNotEmpty,
        'shown as ticked by Bea',
      );
    } else {
      expect(
        (await pull(
          bea,
          Collections.medicationIntakes,
        ))[m.intakeId(at)]!.data['byId'],
        f.adminMember.id,
      );
    }
    final conflicts = await pull(admin, Collections.conflicts);
    debugPrint(
      'E2E KIN-100 winner ${winner == f.bea.id ? 'Bea' : 'admin'}, '
      'conflicts about the dose: '
      '${conflicts.values.where((c) => '${c.data}'.contains(m.intakeId(at))).length}',
    );
    await finish(tester, state);
  });

  testWidgets('KIN-102 KIN-103 stock counts down, warns and goes on the list', (
    tester,
  ) async {
    final state = await start(tester);
    expect(state.engine!.shoppingLists, isEmpty, reason: 'no list yet');
    await openSection(tester, 'Medizin');
    await tap(tester, find.byTooltip(de.medsAddMedication));
    await enter(tester, field(de.kidsLogMedication), 'E2E Vorratssaft');
    for (final (h, m) in [(7, 0), (19, 0)]) {
      await addTime(tester, h, m);
    }
    await scrollTo(tester, field(de.medsPiecesStock));
    await enter(tester, field(de.medsPiecesStock), '10');
    await scrollTo(tester, find.text(de.commonDaysCount(7)));
    await choose(tester, de.commonDaysCount(7), de.commonDaysCount(5));
    await tap(tester, find.byTooltip(de.commonSave));
    await medsList(tester);
    final card = medCard('E2E Vorratssaft');
    Finder stock(String text) =>
        find.descendant(of: card, matching: find.text(text));
    final ten = de.medsCountLeftLasts('10', de.medsLastsAboutDaysDays(5));
    await scrollTo(tester, stock(ten));
    expect(
      tester.widget<Text>(stock(ten)).style?.color,
      dangerOf(tester, stock(ten)),
    );
    expect(
      find.descendant(of: card, matching: find.byIcon(AppIcons.warningCircle)),
      findsOneWidget,
    );
    // KIN-103: without a shopping list, no button.
    expect(stock(de.medsBuyMore), findsNothing);
    final list = uid('list');
    await seed(await adminApi(), Collections.shoppingLists, {
      list: const ShoppingList(id: '', name: 'E2E Einkauf').toData(),
    });
    await arrives(tester, state, (e) => e.shoppingLists.isNotEmpty, 'list');
    await scrollTo(tester, stock(de.medsBuyMore));

    // Two doses taken.
    for (final time in ['07:00', '19:00']) {
      final tile = find.ancestor(
        of: find.text(time),
        matching: find.ancestor(
          of: find.text('E2E Vorratssaft'),
          matching: find.byType(SoftCard),
        ),
      );
      await scrollTo(tester, tile);
      await tap(
        tester,
        find.descendant(of: tile.first, matching: find.byTooltip(de.medsTaken)),
      );
    }
    final eight = de.medsCountLeftLasts('8', de.medsLastsAboutDaysDays(4));
    await scrollTo(tester, stock(eight));
    // Saved again without a change: nothing taken off twice.
    await tap(tester, card);
    await waitFor(tester, find.byTooltip(de.commonDelete));
    await scrollTo(tester, field(de.medsPiecesStock));
    expect(
      tester.widget<TextField>(field(de.medsPiecesStock).last).controller!.text,
      '8',
    );
    await tap(tester, find.byTooltip(de.commonSave));
    await medsList(tester);
    await scrollTo(tester, stock(eight));

    // KIN-103.
    await tap(tester, stock(de.medsBuyMore));
    await waitFor(tester, snackText(de.medsList('E2E Einkauf')));
    expect(
      state.engine!.shoppingItems(list).map((i) => i.name),
      contains('E2E Vorratssaft (Apotheke)'),
    );

    // The rest taken elsewhere: used up.
    final m = state.engine!.medications.singleWhere(
      (m) => m.name == 'E2E Vorratssaft',
    );
    await seed(await adminApi(), Collections.medicationIntakes, {
      for (var i = 0; i < 8; i++)
        '${uid('intake')}-$i': MedicationIntake(
          id: '',
          medicationId: m.id,
          at: DateTime.now(),
          byId: await adminId(),
        ).toData(visibleTo: m.careIds),
    });
    await arrives(
      tester,
      state,
      (e) => e.intakes(m.id).length == 10,
      'intakes',
    );
    await scrollTo(tester, stock(de.medsSupplyUsedUp));
    await finish(tester, state);
  });

  // The editor says at the field what keeps a plan from being saved: no
  // name, neither times nor "Nur bei Bedarf" (it would never show under
  // "Heute"), an end before the start; the end cannot be picked before the
  // start (#544).
  testWidgets('KIN-096 plan without name or times', (tester) async {
    final state = await start(tester);
    await openSection(tester, 'Medizin');
    await tap(tester, find.byTooltip(de.medsAddMedication));
    await waitFor(tester, find.text(de.medsNewMedication));
    await tap(tester, find.byTooltip(de.commonSave));
    await waitFor(tester, find.text(de.kidsLogPleaseEnterMedication));
    expect(find.text(de.medsNewMedication), findsOneWidget);
    await enter(tester, field(de.kidsLogMedication), 'E2E Zeitlos');
    await tap(tester, find.byTooltip(de.commonSave));
    await waitFor(tester, find.text(de.medsTimesMissing));
    expect(find.text(de.medsNewMedication), findsOneWidget);
    expect(
      state.engine!.medications.any((m) => m.name == 'E2E Zeitlos'),
      isFalse,
    );
    await back(tester);
    await waitFor(tester, find.byTooltip(de.medsAddMedication));

    await tap(tester, find.byTooltip(de.medsAddMedication));
    await waitFor(tester, find.text(de.medsNewMedication));
    await enter(tester, field(de.kidsLogMedication), 'E2E Rückwärts');
    await addTime(tester, 9, 0);
    final permanently = find.widgetWithText(InputChip, de.medsPermanently);
    await scrollTo(tester, permanently);
    await tap(tester, permanently);
    await pickDate(tester, inDays(2));
    await waitFor(
      tester,
      find.widgetWithText(InputChip, de.medsUntilDate(yMd(inDays(2)))),
    );
    // A start after the end.
    await tap(
      tester,
      find.widgetWithText(InputChip, de.medsDate(yMd(today()))),
    );
    await pickDate(tester, inDays(5));
    await tap(tester, find.byTooltip(de.commonSave));
    await waitFor(tester, find.text(de.commonEndBeforeStart));
    expect(
      state.engine!.medications.any((m) => m.name == 'E2E Rückwärts'),
      isFalse,
    );
    await back(tester);
    await finish(tester, state);
  });

  testWidgets('KIN-097 weekdays, start and end', (tester) async {
    final state = await start(tester);
    await openSection(tester, 'Medizin');
    await tap(tester, find.byTooltip(de.medsAddMedication));
    await enter(tester, field(de.kidsLogMedication), 'E2E Wochensaft');
    await addTime(tester, 9, 0);
    bool on(String day) => tester
        .widget<FilterChip>(find.widgetWithText(FilterChip, day))
        .selected;
    Future<void> toggle(String day) async {
      await scrollTo(tester, find.widgetWithText(FilterChip, day));
      await tap(tester, find.widgetWithText(FilterChip, day));
    }

    for (final d in ['Di', 'Do', 'Sa', 'So']) {
      await toggle(d);
    }
    expect(
      [
        for (final d in ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So']) on(d),
      ],
      [true, false, true, false, true, false, false],
    );
    await toggle('Mi');
    await toggle('Fr');
    await toggle('Mo');
    expect(on('Mo'), isTrue, reason: 'the last day stays');
    await toggle('Mi');
    await toggle('Fr');

    final begin = inDays(1), end = inDays(8);
    await tap(
      tester,
      find.widgetWithText(InputChip, de.medsDate(yMd(today()))),
    );
    await pickDate(tester, begin);
    await tap(tester, find.widgetWithText(InputChip, de.medsPermanently));
    await pickDate(tester, end);
    final until = find.widgetWithText(InputChip, de.medsUntilDate(yMd(end)));
    await waitFor(tester, until);
    final clear = find.descendant(
      of: until,
      matching: find.byTooltip('Löschen'),
    );
    await tap(
      tester,
      clear.evaluate().isNotEmpty
          ? clear
          : find.descendant(of: until, matching: find.byType(Icon)).last,
    );
    await waitFor(tester, find.widgetWithText(InputChip, de.medsPermanently));
    await tap(tester, find.widgetWithText(InputChip, de.medsPermanently));
    await pickDate(tester, end);
    await tap(tester, find.byTooltip(de.commonSave));
    await medsList(tester);
    await scrollTo(tester, find.text('09:00 · Mo, Mi, Fr · bis ${yMd(end)}'));
    final m = state.engine!.medications.singleWhere(
      (m) => m.name == 'E2E Wochensaft',
    );
    expect(m.dosesOn(today()), isEmpty, reason: 'before the start');
    expect(
      m.dosesOn(DateUtils.addDaysToDate(end, 7)),
      isEmpty,
      reason: 'after the end',
    );
    expect(m.weekdays, {1, 3, 5});
    expect(
      await anywhere(
        tester,
        find.ancestor(
          of: find.text('09:00'),
          matching: find.ancestor(
            of: find.text('E2E Wochensaft'),
            matching: find.byType(SoftCard),
          ),
        ),
      ),
      isFalse,
      reason: 'no dose today',
    );
    await finish(tester, state);
  });

  testWidgets('KIN-104 a new plan: only the chosen see it', (tester) async {
    final f = await theFamily();
    await serviceAccount();
    final state = await start(tester);
    await openSection(tester, 'Medizin');
    await tap(tester, find.byTooltip(de.medsAddMedication));
    await enter(tester, field(de.kidsLogMedication), 'E2E Geheimsaft');
    await addTime(tester, 12, 0);
    await scrollTo(tester, find.text(de.medsWhoSeesGetsReminded));
    final me = find.widgetWithText(FilterChip, kitAdminName);
    expect(tester.widget<FilterChip>(me).selected, isTrue);
    expect(
      tester.widget<FilterChip>(me).onSelected,
      isNull,
      reason: 'the last one stays',
    );
    expect(
      tester
          .widget<FilterChip>(
            find.widgetWithText(FilterChip, f.bea.displayName),
          )
          .selected,
      isFalse,
    );
    expect(find.widgetWithText(FilterChip, f.guest.displayName), findsNothing);
    expect(find.widgetWithText(FilterChip, 'E2E Dienst'), findsNothing);
    expect(find.text(de.medsHealthDataOnlyThose), findsOneWidget);
    await tap(tester, find.byTooltip(de.commonSave));
    await medsList(tester);
    final tile = find.ancestor(
      of: find.text('12:00'),
      matching: find.ancestor(
        of: find.text('E2E Geheimsaft'),
        matching: find.byType(SoftCard),
      ),
    );
    await scrollTo(tester, tile);
    await tap(
      tester,
      find.descendant(of: tile.first, matching: find.byTooltip(de.medsTaken)),
    );
    await synced(tester, state);
    final m = state.engine!.medications.singleWhere(
      (m) => m.name == 'E2E Geheimsaft',
    );
    expect(
      (await pull(await adminApi(), Collections.medications)).keys,
      contains(m.id),
    );
    final bea = await sessionOf(f.bea);
    expect(
      (await pull(bea, Collections.medications)).keys,
      isNot(contains(m.id)),
    );
    expect(
      (await pull(
        bea,
        Collections.medicationIntakes,
      )).values.where((r) => r.data['medicationId'] == m.id),
      isEmpty,
    );
    await finish(tester, state);
  });

  testWidgets('KIN-106 deleting a plan and bringing it back', (tester) async {
    final med = await seedMedication('E2E Löschsaft', times: const ['10:00']);
    final intake = MedicationIntake(
      id: uid('intake'),
      medicationId: med,
      at: DateTime.now(),
      byId: await adminId(),
    );
    await seed(await adminApi(), Collections.medicationIntakes, {
      intake.id: intake.toData(visibleTo: [await adminId()]),
    });
    final state = await start(tester);
    await openSection(tester, 'Medizin');
    await arrives(tester, state, (e) => e.intakes(med).isNotEmpty, 'intake');
    Future<void> deleteIt() async {
      await scrollTo(tester, medCard('E2E Löschsaft'));
      await tap(tester, medCard('E2E Löschsaft'));
      await tap(tester, find.byTooltip(de.commonDelete));
      await waitFor(tester, snackText(de.undoWhatDeleted('E2E Löschsaft')));
    }

    await deleteIt();
    expect(state.engine!.medication(med), isNull);
    expect(state.engine!.intakes(med), isEmpty);
    await undo(tester);
    await until(
      tester,
      () =>
          state.engine!.medication(med) != null &&
          state.engine!.intakes(med).length == 1,
      'plan and intake back',
    );
    await snackGone(tester);
    await deleteIt();
    await snackGone(tester);
    await synced(tester, state);
    final admin = await adminApi();
    expect(
      (await pull(admin, Collections.medications)).keys,
      isNot(contains(med)),
    );
    expect(
      (await pull(admin, Collections.medicationIntakes)).keys,
      isNot(contains(intake.id)),
    );
    await finish(tester, state);
  });

  // "Nachkaufen" puts the item on a list all who care for the plan see, not
  // on the first one (which may be the admin's own, #544, #376).
  testWidgets(
    'KIN-103 buying more goes on a list all who care for the plan see',
    (tester) async {
      final f = await theFamily();
      final private = uid('privatelist'), shared = uid('sharedlist');
      await seed(await adminApi(), Collections.shoppingLists, {
        private: ShoppingList(
          id: '',
          name: 'E2E Aaa Privat',
          sort: -1,
          visibleTo: [f.adminMember.id],
        ).toData(),
        shared: const ShoppingList(
          id: '',
          name: 'E2E Zett Gemeinsam',
          sort: -1,
        ).toData(),
      });
      final med = await seedMedication(
        'E2E Teilsaft',
        times: const ['08:00', '20:00'],
        care: [f.adminMember.id, f.bea.id],
        stock: 2,
      );
      final state = await start(tester);
      await openSection(tester, 'Medizin');
      await arrives(
        tester,
        state,
        (e) =>
            e.medication(med) != null &&
            e.shoppingList(private) != null &&
            e.shoppingList(shared) != null,
        'plan and lists',
      );
      final card = medCard('E2E Teilsaft');
      final buy = find.descendant(
        of: card,
        matching: find.text(de.medsBuyMore),
      );
      await scrollTo(tester, buy);
      await tap(tester, buy);
      await waitFor(tester, find.byType(SnackBar));
      final onList = [
        for (final l in state.engine!.shoppingLists)
          if (state.engine!
              .shoppingItems(l.id)
              .any((i) => i.name == 'E2E Teilsaft (Apotheke)'))
            l.name,
      ];
      debugPrint('E2E KIN-103 the item went on: $onList');
      await synced(tester, state);
      final bea = await sessionOf(f.bea);
      final beaGets = (await pull(
        bea,
        Collections.shoppingItems,
      )).values.any((r) => r.data['name'] == 'E2E Teilsaft (Apotheke)');
      expect(
        beaGets,
        isTrue,
        reason:
            'Bea cares for the plan but does not get the item; it went on '
            '$onList',
      );
      await finish(tester, state);
    },
  );

  // Texts once written into the code in German are translated: "…
  // entfernen?", the chip "rota_1 ab …", "Menge (ml)", "Temperatur (°C)",
  // "z. B. Fiebersaft", "Mindestabstand (h)", "bis …" and "(Apotheke)"
  // (#544).
  testWidgets(
    'KIN-011 KIN-035 KIN-057 KIN-075 KIN-085 KIN-097 KIN-103 texts in English',
    (tester) async {
      final en = lookupL10n(const Locale('en'));
      final id = await seedChild('E2E English Kid', born(days: 28));
      await seedEntries([
        ChildEntry(
          id: uid('entry'),
          childId: id,
          kind: ChildEntryKind.vaccination,
          date: inDays(14),
          refId: 'rota_1',
          planned: true,
        ),
      ]);
      final med = uid('med');
      await seed(await adminApi(), Collections.medications, {
        med: Medication(
          id: med,
          name: 'E2E Englischsaft',
          times: const ['09:00'],
          start: today(),
          end: inDays(8),
          careIds: [await adminId()],
          stock: 1,
          stockAt: DateTime.now(),
        ).toData(),
      });
      final list = uid('list');
      await seed(await adminApi(), Collections.shoppingLists, {
        list: const ShoppingList(id: '', name: 'E2E List').toData(),
      });
      final state = await start(tester);
      await arrives(
        tester,
        state,
        (e) =>
            e.child(id) != null &&
            e.childEntries(id).isNotEmpty &&
            e.medication(med) != null &&
            e.shoppingList(list) != null,
        'child, plan and list',
      );
      addTearDown(() => state.setLanguage('de'));
      await state.setLanguage('en');
      await tester.pump(const Duration(seconds: 2));
      await waitFor(tester, find.text(en.sectionKids));
      final german = <String>[];

      Future<void> section(String label) async {
        await openSection(tester, label, keepTip: true);
        await tester.pump(const Duration(milliseconds: 500));
        if (find.text(en.tipGotIt).evaluate().isNotEmpty) {
          await tap(tester, find.text(en.tipGotIt).last);
        }
      }

      // KIN-035: the chip of a booked vaccination.
      await section(en.sectionKids);
      await waitFor(tester, find.byType(KidsScreen));
      await inKidsList(tester, find.text('E2E English Kid'));
      final chip = [
        for (final e
            in find
                .descendant(
                  of: find.ancestor(
                    of: find.text('E2E English Kid'),
                    matching: find.byType(SoftCard),
                  ),
                  matching: byTypeName('_Chip'),
                )
                .evaluate())
          (e.widget as dynamic).text as String,
      ];
      if (chip.any((t) => t.contains(' ab '))) german.add('chip: $chip');

      // KIN-057, KIN-075, KIN-085: the log's editors.
      await tap(tester, find.text('E2E English Kid'));
      await waitFor(tester, find.byType(ChildScreen));
      Future<TextField?> fieldIn(String quick, String label) async {
        await tapQuick(tester, quick);
        await waitFor(tester, sheet());
        final f = inSheet(field(label));
        final found = f.evaluate().isEmpty
            ? null
            : tester.widget<TextField>(f.last);
        return found;
      }

      if (await fieldIn(en.kidsLogBottle, 'Menge (ml)') != null) {
        german.add('bottle: "Menge (ml)"');
      }
      await closeSheet(tester);
      if (await fieldIn(en.kidsLogTemperature, 'Temperatur (°C)') != null) {
        german.add('temperature: "Temperatur (°C)"');
      }
      await closeSheet(tester);
      if (await fieldIn(en.kidsLogMedication, 'Mindestabstand (h)') != null) {
        german.add('medication: "Mindestabstand (h)"');
      }
      final name = inSheet(field(en.kidsLogMedication));
      final hint = name.evaluate().isEmpty
          ? null
          : tester.widget<TextField>(name.first).decoration?.hintText;
      if (hint == 'z. B. Fiebersaft') german.add('medication: "$hint"');
      await closeSheet(tester);

      // KIN-011: the question before removing.
      await tap(tester, find.byTooltip(en.commonEdit));
      await scrollTo(tester, find.text(en.kidsRemoveChild));
      await tap(tester, find.text(en.kidsRemoveChild));
      await waitFor(tester, find.byType(AlertDialog));
      final title = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('E2E English Kid'),
      );
      final question = title.evaluate().isEmpty
          ? ''
          : tester.widget<Text>(title.first).data ?? '';
      if (question.contains('entfernen')) german.add('remove: "$question"');
      await tap(tester, find.text(en.commonCancel).last);
      await dialogClosed(tester);
      expect(state.engine!.child(id), isNotNull);

      // KIN-097, KIN-103: the plan's card.
      await section(en.sectionHealth);
      await waitFor(tester, find.byTooltip(en.medsAddMedication));
      final card = medCard('E2E Englischsaft');
      await scrollTo(tester, card);
      final lines = [
        for (final e
            in find
                .descendant(of: card, matching: find.byType(Text))
                .evaluate())
          ?(e.widget as Text).data,
      ];
      if (lines.any((l) => RegExp(r'\bbis \d').hasMatch(l))) {
        german.add('plan: $lines');
      }
      final buy = find.descendant(
        of: card,
        matching: find.text(en.medsBuyMore),
      );
      await scrollTo(tester, buy);
      await tap(tester, buy);
      await waitFor(tester, find.byType(SnackBar));
      final items = [
        for (final l in state.engine!.shoppingLists)
          for (final i in state.engine!.shoppingItems(l.id))
            if (i.name.startsWith('E2E Englischsaft')) i.name,
      ];
      if (items.any((i) => i.contains('Apotheke'))) {
        german.add('shopping: $items');
      }
      debugPrint('E2E KIN texts in English still German: $german');
      await state.setLanguage('de');
      await tester.pump(const Duration(seconds: 1));
      expect(german, isEmpty, reason: german.join('\n'));
      await finish(tester, state);
    },
  );

  // =========================================================================
  // Pregnancy
  // =========================================================================

  testWidgets(
    'KIN-118 KIN-119 KIN-120 KIN-127 KIN-128 pregnancy: add, week view, who sees it, remove',
    (tester) async {
      final f = await theFamily();
      final state = await start(tester);
      final before = state.engine!.pregnancies.length;
      await kidsList(tester);
      await tap(tester, find.byTooltip(de.kidsAddChildPregnancy));
      await tap(tester, find.text(de.commonPregnancy).last);
      await waitFor(tester, find.text(de.pregnancyDueDate2));
      // KIN-118.
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, snackText(de.pregnancyPleaseEnterDueDate));
      expect(find.text(de.pregnancyDueDate2), findsOneWidget);
      expect(state.engine!.pregnancies.length, before);

      // KIN-119.
      final lmp = inDays(-70);
      final due = DateTime(lmp.year, lmp.month, lmp.day + 280);
      await tap(
        tester,
        find.widgetWithText(ActionChip, de.pregnancyCalculateLastPeriod),
      );
      await waitFor(tester, find.text(de.pregnancyFirstDayLastPeriod));
      await pickDate(tester, lmp);
      await waitFor(tester, find.widgetWithText(InputChip, yMMMd(due)));
      await waitFor(tester, find.text(de.pregnancyTodayWeekWeek('10+0')));
      await enter(
        tester,
        field(de.pregnancyNameNicknameOptional),
        'E2E Krümel',
      );
      await tap(tester, find.widgetWithText(ChoiceChip, f.bea.displayName));
      // KIN-127: only oneself sees it.
      bool sees(String name) => tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, name))
          .selected;
      expect(sees(kitAdminName), isTrue);
      expect(sees(f.bea.displayName), isFalse);
      expect(sees(f.carl.displayName), isFalse);
      await scrollTo(tester, find.text(de.pregnancyOnlyTheySeePregnancy));
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, find.byType(KidsScreen));
      final p = state.engine!.pregnancies.singleWhere(
        (p) => p.name == 'E2E Krümel',
      );
      expect(p.dueDate, due);
      expect(p.motherId, f.bea.id);
      await scrollTo(tester, find.text('E2E Krümel'));
      final card = find.ancestor(
        of: find.text('E2E Krümel'),
        matching: find.byType(PregnancyCard),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(
            de.pregnancyWeekWeekLeft('10+0', de.commonDaysLeft(daysToGo(p))),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(de.pregnancyBigLike(pregnancyWeek(10)!.like)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byType(LinearProgressIndicator),
        ),
        findsOneWidget,
      );

      await synced(tester, state);
      final bea = await sessionOf(f.bea);
      expect(
        (await pull(bea, Collections.pregnancies)).keys,
        isNot(contains(p.id)),
      );

      // KIN-120: the week.
      await tap(tester, find.text('E2E Krümel'));
      await waitFor(tester, find.byType(PregnancyScreen));
      expect(selectedTab(tester), de.commonWeek);
      await waitFor(tester, find.text(de.pregnancyWeekWD(10, 0)));
      expect(
        find.text(
          de.pregnancyWeekWeekPregnancyTrimester(
            11,
            trimester(p),
            de.commonDaysLeft(daysToGo(p)),
          ),
        ),
        findsOneWidget,
      );
      final week = pregnancyWeek(10)!;
      expect(
        find.text(de.pregnancyBabyAboutBigLike(week.like)),
        findsOneWidget,
      );
      expect(find.textContaining(RegExp(r'^etwa .* cm · ')), findsOneWidget);
      expect(find.byType(RoundCheck), findsNWidgets(3));
      await scrollTo(
        tester,
        find.text(de.pregnancyMaternityLeaveDate(yMMMd(maternityLeave(p)))),
      );
      await scrollTo(tester, find.text(de.pregnancyDueDate(yMMMd(due))));
      await scrollTo(tester, find.text(de.pregnancySizesAveragesWhatCounts));
      expect(
        find.text(de.pregnancyBabyHere),
        findsNothing,
        reason: 'before week 20',
      );

      // KIN-127: Bea added, then nobody chosen.
      await tap(tester, find.byTooltip(de.commonEdit));
      await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
      await tap(tester, find.text(de.commonSave).last);
      await synced(tester, state);
      expect((await pull(bea, Collections.pregnancies)).keys, contains(p.id));
      await tap(tester, find.byTooltip(de.commonEdit));
      await tap(tester, find.widgetWithText(FilterChip, f.bea.displayName));
      await tap(tester, find.widgetWithText(FilterChip, kitAdminName));
      await tap(tester, find.text(de.commonSave).last);
      await synced(tester, state);
      expect(
        (await pull(bea, Collections.pregnancies)).keys,
        isNot(contains(p.id)),
      );
      final stored = (await pull(
        await adminApi(),
        Collections.pregnancies,
      ))[p.id]!;
      expect(stored.visibleTo, [f.adminMember.id]);

      // KIN-128.
      await tap(tester, find.byTooltip(de.commonEdit));
      await scrollTo(tester, find.widgetWithText(TextButton, de.commonRemove));
      await tap(tester, find.widgetWithText(TextButton, de.commonRemove));
      await waitFor(tester, find.text(de.pregnancyRemovePregnancy));
      await tap(tester, find.widgetWithText(FilledButton, de.commonRemove));
      await waitFor(tester, find.byType(KidsScreen));
      await tester.pump(const Duration(seconds: 1));
      expect(state.engine!.pregnancy(p.id), isNull);
      expect(find.text('E2E Krümel'), findsNothing);
      await synced(tester, state);
      expect(
        (await pull(await adminApi(), Collections.pregnancies)).keys,
        isNot(contains(p.id)),
      );
      await finish(tester, state);
    },
  );

  testWidgets('KIN-120 due date today and past it', (tester) async {
    await seedPregnancy('E2E Heute-ET', today());
    await seedPregnancy('E2E Über-ET', inDays(-3));
    final state = await start(tester);
    await kidsList(tester);
    await inKidsList(
      tester,
      find.text(de.pregnancyWeekWeekLeft('40+0', de.pregnancyDueDateToday)),
    );
    await inKidsList(
      tester,
      find.text(
        de.pregnancyWeekWeekLeft('40+3', de.pregnancyDaysDaysPastDue(3)),
      ),
    );
    await openPregnancy(tester, 'E2E Über-ET');
    await tab(tester, de.commonWeek);
    await waitFor(
      tester,
      find.text(
        de.pregnancyWeekWeekPregnancyTrimester(
          41,
          3,
          de.pregnancyDueDateReached,
        ),
      ),
    );
    await finish(tester, state);
  });

  testWidgets('KIN-121 KIN-126 screenings to tick off, the baby arrives', (
    tester,
  ) async {
    final f = await theFamily();
    final nine = await seedPregnancy('E2E Neun', inDays(217));
    final twenty = await seedPregnancy(
      'E2E Zwanzig',
      inDays(140),
      guardians: [f.adminMember.id, f.bea.id],
    );
    final state = await start(tester);
    await arrives(
      tester,
      state,
      (e) => e.pregnancy(nine) != null && e.pregnancy(twenty) != null,
      'pregnancies',
    );
    final p = state.engine!.pregnancy(nine)!;
    await openPregnancy(tester, 'E2E Neun');
    expect(find.text(de.pregnancyBabyHere), findsNothing);
    await tab(tester, de.commonEvents);
    await waitFor(tester, find.text(de.pregnancyAdditionThereRegularCheckups));
    for (final (title, from, to) in [
      ('1. Ultraschall-Screening', 8, 11),
      ('2. Ultraschall-Screening', 18, 21),
      ('3. Ultraschall-Screening', 28, 31),
    ]) {
      await scrollTo(tester, find.text(title));
      expect(
        inCard(
          title,
          find.text(
            de.pregnancyWeekFromweekToweek(
              from,
              to,
              md(p.dayOf(from)),
              md(p.dayOf(to, 6)),
            ),
          ),
        ),
        findsOneWidget,
        reason: title,
      );
    }
    await expectStatus(tester, '1. Ultraschall-Screening', de.pregnancyNow);
    await expectStatus(tester, '2. Ultraschall-Screening', de.pregnancySoon);
    await tickCard(tester, '1. Ultraschall-Screening');
    await expectStatus(tester, '1. Ultraschall-Screening', de.commonDoneLower);
    expect(state.engine!.pregnancy(nine)!.done, contains('us1'));

    // KIN-126.
    final children = state.engine!.children.length;
    await openPregnancy(tester, 'E2E Zwanzig');
    await scrollTo(tester, find.text(de.pregnancyBabyHere));
    await tap(tester, find.text(de.pregnancyBabyHere));
    await waitFor(tester, find.text(de.pregnancyCongratulations));
    await enter(tester, field(de.commonName), '');
    await leaveField(tester);
    await tap(tester, find.text(de.pregnancyAddChild));
    await dialogClosed(tester);
    expect(find.byType(PregnancyScreen), findsOneWidget);
    expect(state.engine!.children.length, children);
    await tap(tester, find.text(de.pregnancyBabyHere));
    await waitFor(tester, find.text(de.pregnancyCongratulations));
    await enter(tester, field(de.commonName), 'E2E Frischling');
    await leaveField(tester);
    // At 20+0 the day of birth can only be today (not before week 20).
    expect(
      find.widgetWithText(InputChip, de.pregnancyBornDate(yMMMd(today()))),
      findsOneWidget,
    );
    await tap(tester, find.widgetWithText(ChoiceChip, de.pregnancyGirl));
    await tap(tester, find.text(de.pregnancyAddChild));
    await waitFor(tester, find.byType(ChildScreen));
    await waitFor(tester, find.text('E2E Frischling'));
    final child = state.engine!.children.singleWhere(
      (c) => c.name == 'E2E Frischling',
    );
    expect(child.guardianIds, unorderedEquals([f.adminMember.id, f.bea.id]));
    expect(child.sex, ChildSex.female);
    expect(child.birthDate, today());
    expect(state.engine!.pregnancy(twenty)!.childId, child.id);
    await kidsList(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('E2E Zwanzig'), findsNothing);
    await finish(tester, state);
  });

  // "Verlauf leeren" asks before it removes all contractions (#544).
  testWidgets('KIN-125 clearing the contraction history', (tester) async {
    final id = await seedPregnancy('E2E Wehen', inDays(14));
    final state = await start(tester);
    await openPregnancy(tester, 'E2E Wehen');
    expect(selectedTab(tester), de.pregnancyContractions);
    for (var i = 0; i < 2; i++) {
      await tap(tester, find.text(de.pregnancyContractionStarts));
      await tester.pump(const Duration(seconds: 1));
      await tap(tester, find.text(de.pregnancyContractionOver));
    }
    await scrollTo(tester, find.text(de.pregnancyClearHistory));
    expect(state.engine!.pregnancy(id)!.contractions, hasLength(2));
    await tap(tester, find.text(de.pregnancyClearHistory));
    await tester.pump(const Duration(milliseconds: 800));
    final asked = find.byType(AlertDialog).evaluate().isNotEmpty;
    final canUndo = find
        .descendant(
          of: find.byType(SnackBar),
          matching: find.text('Rückgängig'),
        )
        .evaluate()
        .isNotEmpty;
    expect(
      asked || canUndo,
      isTrue,
      reason:
          'cleared without asking and without undo: '
          '${state.engine!.pregnancy(id)!.contractions.length} left',
    );
    expect(find.text(de.pregnancyClearHistoryQuestion), findsOneWidget);
    await tap(tester, find.text(de.commonCancel).last);
    await dialogClosed(tester);
    expect(state.engine!.pregnancy(id)!.contractions, hasLength(2));
    await tap(tester, find.text(de.pregnancyClearHistory));
    await tap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(de.pregnancyClearHistory),
      ),
    );
    await dialogClosed(tester);
    expect(state.engine!.pregnancy(id)!.contractions, isEmpty);
    await finish(tester, state);
  });

  // =========================================================================
  // Large text, last: it changes the window.
  // =========================================================================

  testWidgets('KIN-093 the log with large text on a phone', (tester) async {
    final id = await seedChild('E2E Großschrift', born(months: 5));
    await seedLogs([
      await logOf(id, LogKind.sleep, ago(const Duration(minutes: 12))),
    ]);
    final state = await start(tester);
    await arrives(tester, state, (e) => e.childLogs(id).isNotEmpty, 'sleep');
    // Opened in the window, then the phone's size and text: the page stays.
    await openChild(tester, 'E2E Großschrift');
    await waitFor(tester, find.byType(ChildLogView));
    debugPrint('E2E KIN-093 phone size, text 200 %');
    final dpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = Size(390 * dpr, 844 * dpr);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pump(const Duration(seconds: 1));
    debugPrint('E2E KIN-093 laid out');
    if (find.byType(ChildLogView).evaluate().isEmpty) {
      await openSection(tester, 'Kinder');
    }
    await waitFor(tester, find.byType(ChildLogView));
    await waitFor(tester, find.text(de.kidsLogWokeUp));
    Offset at(String label) => tester.getTopLeft(quickButton(label).first);
    Finder label(String text) => find.descendant(
      of: byTypeName('_QuickButtons'),
      matching: find.text(text),
    );
    // Two columns.
    expect(at(de.kidsLogBottle).dy, at(de.kidsLogBreastfeeding).dy);
    expect(
      at(de.kidsLogBottle).dx,
      greaterThan(at(de.kidsLogBreastfeeding).dx),
    );
    expect(
      at(de.kidsLogWokeUp).dy,
      greaterThan(at(de.kidsLogBreastfeeding).dy),
    );
    expect(at(de.kidsLogWokeUp).dx, at(de.kidsLogBreastfeeding).dx);
    // One line per word.
    final oneLine = tester.getSize(label(de.kidsLogPee)).height;
    for (final word in [
      de.kidsLogTemperature,
      de.kidsLogMedication,
      de.kidsLogBottle,
    ]) {
      await scrollTo(tester, label(word), at: const Offset(195, 500));
      expect(tester.getSize(label(word)).height, oneLine, reason: word);
    }
    // The running card: buttons under the time.
    await scrollTo(
      tester,
      find.text(de.kidsLogStop),
      up: true,
      at: const Offset(195, 500),
    );
    expect(
      tester.getTopLeft(find.text(de.kidsLogStop)).dy,
      greaterThan(tester.getTopLeft(find.textContaining('Schläft seit ')).dy),
    );
    // "Verlauf" above its choice.
    await scrollTo(
      tester,
      find.text(de.kidsLogHistory),
      at: const Offset(195, 500),
    );
    final picker = find.byWidgetPredicate((w) => w is DropdownButton);
    expect(
      tester.getTopLeft(picker).dy,
      greaterThan(tester.getTopLeft(find.text(de.kidsLogHistory)).dy),
    );
    tester.view.resetPhysicalSize();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pump(const Duration(seconds: 1));
    await finish(tester, state);
  });
}
