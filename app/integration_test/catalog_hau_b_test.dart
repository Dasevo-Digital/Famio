// Catalog HAU, entries added on 23.11.2026 (HAU-164 … HAU-182), in the
// real app against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_hau_b_test.dart
//
// Recipe pages that refuse or are gone (from a small server of the test on
// 127.0.0.1; the app reaches its Famio server through a relay of the test,
// which notes what it asks), the pantry editor, the categories of the
// booking editor, who gets the bookings of a restricted household book,
// and a document's file while the server is gone. The helpers are those of
// catalog_hau_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/meal_suggestions.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio/src/screens/meals_screens.dart';
import 'package:famio/src/screens/pantry_screens.dart';
import 'package:famio/src/screens/subscriptions_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';
import 'package:famio/src/data/recipe_import.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// --- native parts --------------------------------------------------------------

/// A file on disk as the file picker hands it over.
final class _DiskFile extends PlatformFile {
  _DiskFile(this.file);

  final File file;

  @override
  String get name => file.uri.pathSegments.last;

  @override
  String? get path => file.path;

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

/// The throwaway server behind a relay of the test, which can be switched
/// off: for the app the server is gone, as if it had been stopped.
class _Relay {
  _Relay(this.target);

  final String target;
  late final HttpServer _server;
  final _client = HttpClient()..autoUncompress = false;

  /// The paths the app asked for, in order.
  final paths = <String>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_relay);
  }

  Future<void> _relay(HttpRequest request) async {
    paths.add(request.uri.path);
    final response = request.response;
    try {
      // No WebSocket: the app checks the server by syncing.
      if ((request.headers.value('upgrade') ?? '').toLowerCase() ==
          'websocket') {
        response.statusCode = HttpStatus.serviceUnavailable;
        await response.close();
        return;
      }
      final out = await _client.openUrl(
        request.method,
        Uri.parse('$target${request.uri}'),
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
      if (request.contentLength >= 0) out.contentLength = request.contentLength;
      await out.addStream(request);
      final back = await out.close();
      response.statusCode = back.statusCode;
      back.headers.forEach((name, values) {
        if (const {
          'content-length',
          'transfer-encoding',
          'connection',
        }.contains(name)) {
          return;
        }
        for (final v in values) {
          response.headers.add(name, v);
        }
      });
      if (back.contentLength >= 0) response.contentLength = back.contentLength;
      await response.addStream(back);
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      await response.close().catchError((Object _) {});
    }
  }

  Future<void> stop() async {
    await _server.close(force: true);
    _client.close(force: true);
  }
}

/// The system clipboard while [body] runs: what it pastes is [paste];
/// [reads] counts how often the app looked.
Future<T> withClipboard<T>(
  WidgetTester tester,
  Future<T> Function(List<int> reads) body, {
  required String Function() paste,
}) async {
  final reads = <int>[0];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.getData':
        reads[0]++;
        return {'text': paste()};
      case 'Clipboard.hasStrings':
        return {'value': true};
    }
    return null;
  });
  try {
    return await body(reads);
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  }
}

// --- files -----------------------------------------------------------------------

Future<Uint8List> pngBytes({Color color = const Color(0xFF3D8FD1)}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = color);
  final image = await recorder.endRecording().toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// A letter or receipt as a photo: black lines on white.
Future<Uint8List> letterPng(List<String> lines) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawRect(
      const Rect.fromLTWH(0, 0, 1200, 1100),
      Paint()..color = Colors.white,
    );
  for (final (i, line) in lines.indexed) {
    (TextPainter(
      text: TextSpan(
        text: line,
        style: const TextStyle(color: Colors.black, fontSize: 56),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout()).paint(canvas, Offset(80, 60.0 + i * 120));
  }
  final image = await recorder.endRecording().toImage(1200, 1100);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

Future<Uint8List> pdfBytes(String text) async {
  final doc = pw.Document()..addPage(pw.Page(build: (_) => pw.Text(text)));
  return doc.save();
}

Future<File> tempFile(String name, List<int> bytes) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/famio-e2e-hau')
    ..createSync(recursive: true);
  return File('${dir.path}/$name')..writeAsBytesSync(bytes);
}

// --- family and data ---------------------------------------------------------------

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

/// Everything the server currently gives [api]'s member, by collection.
Future<Map<String, Map<String, SyncRecord>>> everything(
  FamioApiClient api,
) async {
  final out = <String, Map<String, SyncRecord>>{};
  var since = 0;
  while (true) {
    final r = await api.sync(SyncRequest(since: since));
    for (final c in r.changes) {
      final of = out.putIfAbsent(c.collection, () => {});
      if (c.deleted) {
        of.remove(c.id);
      } else {
        of[c.id] = c;
      }
    }
    if (!r.hasMore || r.rev <= since) return out;
    since = r.rev;
  }
}

/// Removes what the admin, Bea and the child see of [collections]: each
/// test starts from its own data.
Future<void> reset(Set<String> collections) async {
  final f = await theFamily();
  for (final m in [f.adminMember, f.bea, f.kid]) {
    final api = await apiOf(m);
    final all = await everything(api);
    for (final c in collections) {
      final ids = [...?all[c]?.keys];
      if (ids.isNotEmpty) await remove(api, c, ids);
    }
  }
}

const _meals = {
  Collections.recipes,
  Collections.mealPlan,
  Collections.pantryItems,
  Collections.shoppingLists,
  Collections.shoppingItems,
};

const _budget = {
  Collections.budgetEntries,
  Collections.budgetSettings,
  Collections.subscriptions,
};

Future<String> seedRecipe(
  String title, {
  List<String> ingredients = const [],
  String steps = '',
  int servings = 4,
  bool favorite = false,
  List<String> tags = const [],
  int? minutes,
}) async {
  final f = await theFamily();
  final id = uid('recipe');
  await seed(f.admin, Collections.recipes, {
    id: Recipe(
      id: id,
      title: title,
      servings: servings,
      ingredients: [for (final i in ingredients) Ingredient.parse(i)],
      steps: steps,
      favorite: favorite,
      tags: tags,
      minutes: minutes,
    ).toData(),
  });
  return id;
}

Future<String> seedMeal(
  DateTime day,
  MealSlot slot, {
  String? recipeId,
  String title = '',
}) async {
  final f = await theFamily();
  final id = uid('meal');
  await seed(f.admin, Collections.mealPlan, {
    id: PlannedMeal(
      id: id,
      date: DateUtils.dateOnly(day),
      slot: slot,
      recipeId: recipeId,
      title: title,
    ).toData(),
  });
  return id;
}

Future<String> seedPantry(
  String name, {
  double amount = 2,
  double minAmount = 0,
  PantryPlace place = PantryPlace.pantry,
  DateTime? bestBefore,
}) async {
  final f = await theFamily();
  final id = uid('pantry');
  await seed(f.admin, Collections.pantryItems, {
    id: PantryItem(
      id: id,
      name: name,
      amount: amount,
      minAmount: minAmount,
      place: place,
      bestBefore: bestBefore,
    ).toData(),
  });
  return id;
}

Future<String> seedList(String name) async {
  final f = await theFamily();
  final id = uid('list');
  await seed(f.admin, Collections.shoppingLists, {
    id: ShoppingList(id: id, name: name).toData(),
  });
  return id;
}

Future<String> seedBooking(
  String note,
  int cents, {
  String category = 'Freizeit',
  DateTime? date,
  bool income = false,
  bool monthly = false,
  String? importId,
  List<String>? visibleTo,
  FamioApiClient? as,
}) async {
  final f = await theFamily();
  final id = uid('booking');
  await seed(as ?? f.admin, Collections.budgetEntries, {
    id: {
      ...BudgetEntry(
        id: id,
        date: date ?? today(),
        cents: cents,
        category: category,
        income: income,
        note: note,
        memberId: f.adminMember.id,
        monthly: monthly,
        importId: importId,
      ).toData(),
      SyncRecord.visibilityKey: visibleTo,
    },
  });
  return id;
}

Future<String> seedSubscription(
  String name,
  int cents, {
  DateTime? start,
  int every = 1,
  SubscriptionUnit unit = SubscriptionUnit.months,
  String category = 'Sonstiges',
  List<String>? visibleTo,
}) async {
  final f = await theFamily();
  final id = uid('abo');
  await seed(f.admin, Collections.subscriptions, {
    id: {
      ...Subscription(
        id: id,
        name: name,
        cents: cents,
        start: start ?? today(),
        every: every,
        unit: unit,
        category: category,
      ).toData(),
      SyncRecord.visibilityKey: visibleTo,
    },
  });
  return id;
}

Future<FamilyDocument> seedDocument(
  String title, {
  DocumentCategory category = DocumentCategory.other,
  FileRef? file,
  String notes = '',
  List<String>? visibleTo,
  DateTime? expiresAt,
}) async {
  final f = await theFamily();
  final doc = FamilyDocument(
    id: uid('doc'),
    title: title,
    category: category,
    file: file,
    notes: notes,
    visibleTo: visibleTo,
    expiresAt: expiresAt,
    createdAt: DateTime.now(),
  );
  await seed(f.admin, Collections.documents, {doc.id: doc.toData()});
  return doc;
}

/// The service account (Home Assistant), created once.
Future<FamilyMember>? _service;
Future<FamilyMember> serviceAccount() => _service ??= () async {
  final f = await theFamily();
  for (final u in await f.admin.adminUsers()) {
    if (u.member.username == 'e2e-dienst') return u.member;
  }
  return f.admin.createMember(
    username: 'e2e-dienst',
    displayName: 'E2E Dienst',
    password: kitMemberPassword,
    role: MemberRole.service,
  );
}();

/// Who sees the household book, as the admin's app writes it.
Future<void> restrictBudget(List<String>? members) async {
  final f = await theFamily();
  await seed(f.admin, Collections.budgetSettings, {
    BudgetSettings.recordId: {
      ...BudgetSettings(memberIds: members ?? const []).toData(),
      SyncRecord.visibilityKey: members,
    },
  });
}

DateTime mondayOf(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - 1));

// --- the app ----------------------------------------------------------------------

/// A window as high as a big screen: lists and sheets build everything at
/// once (lists only build what is near the screen).
void tall(WidgetTester tester) {
  tester.view.physicalSize =
      const Size(800, 1600) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}

Future<AppState> start(WidgetTester tester, {String? user}) async {
  tall(tester);
  await theFamily();
  return startApp(tester, user: user);
}

/// Signs in like [startApp], but at [url] (the relay).
Future<AppState> startAt(WidgetTester tester, String url) async {
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
  await enter(tester, field('Benutzername'), kitUser);
  await enter(tester, field('Passwort'), kitPassword);
  await tap(tester, find.text('Anmelden'));
  await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
  if (find.text(de.commonLater).evaluate().isNotEmpty) {
    await tap(tester, find.text(de.commonLater).last);
  }
  return state;
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

Future<void> synced(WidgetTester tester, AppState state) async {
  try {
    await state.engine!.sync();
  } catch (_) {}
  await tester.pump(const Duration(milliseconds: 500));
}

/// Waits for what another device wrote (or what the server answered).
Future<void> arrives(
  WidgetTester tester,
  AppState state,
  bool Function(SyncEngine engine) ok,
  String what,
) async {
  debugPrint('E2E arrives $what');
  final end = DateTime.now().add(const Duration(seconds: 45));
  while (!ok(state.engine!)) {
    if (DateTime.now().isAfter(end)) {
      throw TestFailure('Timed out: $what\nOn screen: ${onScreen()}');
    }
    try {
      await state.engine!.sync();
    } catch (_) {}
    await tester.pump(const Duration(milliseconds: 500));
  }
  await tester.pump(const Duration(milliseconds: 300));
}

/// Pumps for a while without waiting for anything (a person looking).
Future<void> idle(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
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
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pump(const Duration(milliseconds: 300));
  await waitGone(tester, sheet(), timeout: const Duration(seconds: 10));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> sheetClosed(WidgetTester tester) async {
  await waitGone(tester, sheet(), timeout: const Duration(seconds: 10));
  await tester.pump(const Duration(milliseconds: 300));
}

Finder snackText(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

Future<void> undo(WidgetTester tester) => tap(
  tester,
  find.descendant(of: find.byType(SnackBar), matching: find.text('Rückgängig')),
);

/// A button by its label (Material buttons and Famio's coloured ones).
Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate(
    (w) => w is ButtonStyleButton || w is ColorButton,
  ),
);

Finder iconButton(String tooltip) => find.ancestor(
  of: find.byTooltip(tooltip),
  matching: find.byWidgetPredicate((w) => w is IconButton || w is BubbleButton),
);

bool isEnabled(WidgetTester tester, Finder f) {
  final w = tester.widget(f.first);
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    IconButton b => b.onPressed != null,
    ColorButton b => b.onPressed != null,
    BubbleButton b => b.onPressed != null,
    _ => throw ArgumentError('not a button: $w'),
  };
}

String textOf(WidgetTester tester, Finder f) {
  final w = tester.widget(f.first);
  if (w is TextField) return w.controller?.text ?? '';
  if (w is Text) return w.data ?? w.textSpan?.toPlainText() ?? '';
  throw ArgumentError('no text: $w');
}

double top(WidgetTester tester, Finder f) => tester.getTopLeft(f.first).dy;

/// The tappable card around [text] (recipe, pantry item, document …).
Finder tile(String text) => find.ancestor(
  of: find.text(text),
  matching: find.byWidgetPredicate((w) => w is SoftCard && w.onTap != null),
);

Finder inTile(String title, Finder f) =>
    find.descendant(of: tile(title), matching: f);

/// The date picker, typed in; whether it took the date.
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

/// The delete cross of an input chip.
Finder chipCross(Finder chip) => find.descendant(
  of: chip,
  matching: find.byWidgetPredicate(
    (w) => w is Icon && (w.icon == Icons.cancel || w.icon == Icons.clear),
  ),
);

// --- meals -------------------------------------------------------------------------

Future<void> openWeek(WidgetTester tester) async {
  await openSection(tester, de.sectionMeals);
  await tab(tester, de.mealsWeekPlan);
}

Future<void> openRecipes(WidgetTester tester) async {
  await openSection(tester, de.sectionMeals);
  await tab(tester, de.mealsRecipes);
}

Future<void> openRecipe(WidgetTester tester, String title) async {
  await openRecipes(tester);
  await tap(tester, find.text(title));
  await waitFor(tester, find.byType(RecipeScreen));
}

Finder inRecipe(Finder f) =>
    find.descendant(of: find.byType(RecipeScreen), matching: f);

/// The number shown next to "Portionen" on a recipe's page.
String servingsShown(WidgetTester tester) {
  final row = find
      .ancestor(
        of: inRecipe(find.text(de.mealsServings)),
        matching: find.byType(Row),
      )
      .first;
  return find
      .descendant(of: row, matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .singleWhere((t) => RegExp(r'^\d+$').hasMatch(t));
}

/// The subtitle under a recipe in the list.
String recipeSubtitle(WidgetTester tester, String title) => textOf(
  tester,
  find.descendant(of: tile(title), matching: find.byType(Text)).at(1),
);

String dayLabel(DateTime day) => DateFormat.MMMMEEEEd('de').format(day);

/// A day of the week plan.
Finder dayCard(DateTime day) => find.ancestor(
  of: find.text(dayLabel(day)),
  matching: find.byType(SoftCard),
);

Finder inDay(DateTime day, Finder f) =>
    find.descendant(of: dayCard(day), matching: f);

Future<void> weeksAhead(WidgetTester tester, int n) async {
  for (var i = 0; i < n.abs(); i++) {
    await tap(
      tester,
      find.byTooltip(n > 0 ? de.mealsNextWeek : de.mealsPreviousWeek),
    );
  }
}

/// The recipes on the days of "Woche vorschlagen"; null where left out.
List<String?> suggested(WidgetTester tester) => [
  for (final e in byTypeName('_SuggestionCard').evaluate())
    ((e.widget as dynamic).candidate as MealCandidate?)?.recipe.title,
];

Finder suggestionCard(int day) => byTypeName('_SuggestionCard').at(day);

/// Picks the list in "Auf welche Liste?" when the app asks.
Future<void> chooseList(WidgetTester tester, String name) async {
  await waitFor(tester, inSheet(find.text(de.commonWhichList)));
  await tap(tester, inSheet(find.text(name)));
  await sheetClosed(tester);
}

// --- budget, documents -------------------------------------------------------------

/// A value of the month's summary ("Einnahmen", "Ausgaben", "Saldo").
Finder summaryValue(String label) => find
    .descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Column))
          .first,
      matching: find.byType(Text),
    )
    .first;

Finder booking(String title) => find.widgetWithText(ListTile, title);

Future<void> openBudget(WidgetTester tester) =>
    openSection(tester, de.sectionBudget);

Future<void> openSubscriptions(WidgetTester tester) async {
  await openBudget(tester);
  await tap(tester, find.byType(SubscriptionsCard));
  await waitFor(tester, find.byType(SubscriptionsScreen));
  await dismissTip(tester);
}

Future<void> openDocuments(WidgetTester tester) =>
    openSection(tester, de.sectionDocuments);

/// Adds a document from [file] (through the replaced file picker).
Future<void> addDocument(
  WidgetTester tester,
  FakePicker picker,
  File file,
) async {
  picker.picks.add(file);
  final add = find.byTooltip(de.docsAdd);
  if (add.evaluate().isEmpty) {
    await tap(tester, find.text(de.docsAddFirstDocument));
  } else {
    await tap(tester, add);
  }
  await waitFor(tester, find.byType(DocumentEditor));
}

Future<void> openPantry(WidgetTester tester) async {
  await openSection(tester, de.sectionShopping);
  await tap(tester, find.byType(PantryCard));
  await waitFor(tester, find.byType(PantryScreen));
  await dismissTip(tester);
}

/// The areas dialog of the server settings: [inDialog] switches, then it
/// is saved.
Future<void> editAreas(
  WidgetTester tester,
  Future<void> Function() inside,
) async {
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
  await inside();
  await tap(tester, inDialog(find.text(de.commonSave)));
  await waitFor(tester, find.text(de.adminAreasSaved));
  await dialogClosed(tester);
}

Finder areaSwitch(String title) =>
    inDialog(find.widgetWithText(SwitchListTile, title));

// --- more of this file -------------------------------------------------------------

/// Recipe pages that answer the way a site sometimes does: refused (403),
/// gone (404), refused after a while. [hits] counts each path.
class _Site {
  late final HttpServer _server;
  final hits = <String, int>{};

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      final response = request.response;
      switch (path) {
        case '/abgelehnt':
          response.statusCode = HttpStatus.forbidden;
        case '/langsam':
          await Future<void>.delayed(const Duration(seconds: 3));
          response.statusCode = HttpStatus.forbidden;
        case '/weg':
          response.statusCode = HttpStatus.notFound;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      response.headers.contentType = ContentType.html;
      response.write('<html><body>nein</body></html>');
      await response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// The app's address field of "Von Webseite übernehmen" for [address],
/// then "Übernehmen".
Future<void> importFrom(WidgetTester tester, String address) async {
  await tap(tester, find.text(de.mealsTakeWebsite));
  await waitFor(tester, find.text(de.mealsRecipeWebsite));
  await enter(tester, inDialog(find.byType(TextField)), address);
  await tap(tester, inDialog(find.text(de.commonApply)));
  await dialogClosed(tester);
}

Future<void> newRecipe(WidgetTester tester) async {
  await openRecipes(tester);
  await tap(tester, find.byTooltip(de.mealsAddRecipe));
  await waitFor(tester, find.text(de.mealsNewRecipe));
}

/// The texts inside [f] (top to bottom as built).
List<String> textsIn(Finder f) => [
  for (final e
      in find.descendant(of: f, matching: find.byType(Text)).evaluate())
    ?((e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText()),
];

/// "Erneut versuchen" of the snack bar on screen.
Finder retryAction() => find.descendant(
  of: find.byType(SnackBar),
  matching: find.widgetWithText(SnackBarAction, de.commonRetry),
);

/// An API client whose server answers every request with [status] and
/// the error [code] (as the Famio server answers the web app).
FamioApiClient answering(int status, String code, String message) =>
    FamioApiClient(
      'http://127.0.0.1:1',
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({'error': code, 'message': message}),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  // =========================================================================
  // Rezept-Import
  // =========================================================================

  // On the Mac the device fetches the page itself, twice; then the server
  // is asked (/api/web/page through the relay: it may not fetch a page in
  // the private network). The device's answer tells the most.
  testWidgets('HAU-164 HAU-167 a page that always refuses: twice, the '
      'server, "Erneut versuchen"', (tester) async {
    await reset(_meals);
    final site = _Site();
    await site.start();
    addTearDown(site.stop);
    final relay = _Relay(kitUrl);
    await relay.start();
    addTearDown(relay.stop);
    final state = await startAt(tester, relay.url);
    await newRecipe(tester);
    final address = '${site.url}/abgelehnt';
    await importFrom(tester, address);
    await waitFor(
      tester,
      snackText(de.mealsRecipePageRefused(403)),
      timeout: const Duration(seconds: 60),
    );
    expect(retryAction(), findsOneWidget);
    expect(site.hits['/abgelehnt'], 2, reason: 'the device asked twice');
    expect(
      relay.paths.where((p) => p == '/api/web/page'),
      hasLength(1),
      reason: 'then the server once',
    );
    expect(textOf(tester, field(de.commonTitle)), '');
    expect(textOf(tester, field(de.mealsIngredientsOnePerLine)), '');
    expect(textOf(tester, field(de.mealsSourceOptional)), address);

    // HAU-167: "Erneut versuchen" starts it again, the message goes.
    await tap(tester, retryAction());
    var busy = false;
    final end = DateTime.now().add(const Duration(seconds: 30));
    while ((site.hits['/abgelehnt'] ?? 0) < 4 && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
      busy |= find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    }
    expect(busy, isTrue, reason: 'the circle turns');
    expect(site.hits['/abgelehnt'], 4);
    await waitFor(
      tester,
      snackText(de.mealsRecipePageRefused(403)),
      timeout: const Duration(seconds: 30),
    );
    expect(textOf(tester, field(de.mealsSourceOptional)), address);
    // Without a tap the message goes after a few seconds.
    final shown = DateTime.now();
    await waitGone(
      tester,
      find.byType(SnackBar),
      timeout: const Duration(seconds: 20),
    );
    debugPrint(
      'E2E-INFO HAU-167 message for ${DateTime.now().difference(shown)}',
    );
    // While an import runs, "Erneut versuchen" of an earlier message starts
    // no second one.
    await importFrom(tester, address);
    await waitFor(
      tester,
      snackText(de.mealsRecipePageRefused(403)),
      timeout: const Duration(seconds: 30),
    );
    final before = site.hits['/abgelehnt']!;
    await importFrom(tester, '${site.url}/langsam');
    await tester.pump(const Duration(milliseconds: 300));
    final stillThere = retryAction().evaluate().isNotEmpty;
    debugPrint('E2E-INFO HAU-167 old message still there: $stillThere');
    if (stillThere) {
      await tester.tap(retryAction().first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      await waitGone(
        tester,
        find.byType(SnackBar),
        timeout: const Duration(seconds: 10),
      );
    }
    await waitFor(
      tester,
      snackText(de.mealsRecipePageRefused(403)),
      timeout: const Duration(seconds: 40),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(site.hits['/langsam'], 2);
    expect(
      site.hits['/abgelehnt'],
      before,
      reason: 'no second import of the earlier page',
    );
    expect(stillThere, isTrue, reason: 'the old message was there to tap');
    await finish(tester, state);
  });

  testWidgets('HAU-166 a page that is gone: once, no server, no retry', (
    tester,
  ) async {
    await reset(_meals);
    final site = _Site();
    await site.start();
    addTearDown(site.stop);
    final relay = _Relay(kitUrl);
    await relay.start();
    addTearDown(relay.stop);
    final state = await startAt(tester, relay.url);
    await newRecipe(tester);
    final address = '${site.url}/weg';
    await importFrom(tester, address);
    await waitFor(
      tester,
      snackText(de.mealsRecipePageGone),
      timeout: const Duration(seconds: 30),
    );
    expect(retryAction(), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(site.hits['/weg'], 1, reason: 'asked once');
    expect(
      relay.paths.where((p) => p == '/api/web/page'),
      isEmpty,
      reason: 'the server does not ask',
    );
    expect(textOf(tester, field(de.mealsSourceOptional)), address);
    await finish(tester, state);
  });

  // Hint from the catalog review (recipe_import.dart:275): the web app only
  // asks the server, which answers every status of the page but 200 with
  // 502 "page_unavailable" ("Die Seite antwortet mit 404."), without the
  // status. What importRecipe makes of the server's answers there.
  testWidgets('HAU-166 hint: what the web app makes of the server\'s answers', (
    tester,
  ) async {
    Future<RecipeImportError> fails(FamioApiClient api) async {
      try {
        await importRecipe(
          Uri.parse('https://e2e.invalid/rezept'),
          id: 'e2e-web',
          api: api,
          direct: false,
          retryAfter: Duration.zero,
        );
      } on RecipeImportError catch (e) {
        return e;
      }
      throw TestFailure('imported');
    }

    // A page that is gone, as the server tells it.
    final gone = await fails(
      answering(502, 'page_unavailable', 'Die Seite antwortet mit 404.'),
    );
    // A page that refuses with 429.
    final busyPage = await fails(
      answering(502, 'page_unavailable', 'Die Seite antwortet mit 429.'),
    );
    // The Famio server itself has too many pages to fetch.
    final busyServer = await fails(
      answering(
        429,
        'too_many_requests',
        'Gerade werden zu viele Seiten abgerufen. Bitte gleich noch einmal '
            'versuchen.',
      ),
    );
    debugPrint(
      'E2E-INFO HAU-166 hint: 404 → $gone (gone ${gone.gone}); '
      'page 429 → $busyPage; server 429 → $busyServer',
    );
    // The editor tells "abgelehnt" for refused without a status, "nicht
    // erreichbar" for unreachable (meals_screens.dart _importFailed).
    expect(gone.problem, RecipeImportProblem.refused);
    expect(gone.status, isNull);
    expect(gone.gone, isFalse, reason: 'no "gibt es nicht (mehr)"');
    expect(busyPage.problem, RecipeImportProblem.refused);
    expect(busyServer.problem, RecipeImportProblem.unreachable);
  });

  // =========================================================================
  // Vorrat
  // =========================================================================

  testWidgets('HAU-174 a pantry item edited: amount with a comma, low, place, '
      'best before', (tester) async {
    await reset(_meals);
    await seedPantry('E2E Milch', amount: 2, place: PantryPlace.fridge);
    final state = await start(tester);
    final engine = state.engine!;
    await openPantry(tester);
    await waitFor(tester, find.text('E2E Milch'));
    await tap(tester, find.text('E2E Milch'));
    await waitFor(tester, inSheet(find.text(de.pantryEditPantryItem)));
    await enter(tester, inSheet(field(de.commonQuantity)), '1,5');
    await enter(tester, inSheet(field(de.pantryLow)), '2');
    await tap(
      tester,
      inSheet(
        find.widgetWithText(ChoiceChip, '🥫 ${PantryPlace.pantry.label}'),
      ),
    );
    final best = inDays(20);
    await tap(tester, inSheet(find.text(de.pantryBestBefore)));
    expect(await typeDate(tester, best), isTrue, reason: 'date taken');
    await dialogClosed(tester);
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await until(
      tester,
      () => engine.pantryItems.single.amount == 1.5,
      'the new amount',
    );
    final item = engine.pantryItems.single;
    expect(
      (item.amount, item.minAmount, item.place, item.bestBefore),
      (1.5, 2.0, PantryPlace.pantry, best),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(inTile('E2E Milch', find.textContaining('1,5')), findsWidgets);
    final mhd = inTile(
      'E2E Milch',
      find.text(de.pantryBestBeforeDate(DateFormat.Md('de').format(best))),
    );
    debugPrint('E2E-INFO HAU-174 best before shown: ${mhd.evaluate().length}');
    // Under "Wird knapp", and under its new place.
    await waitFor(tester, find.text(de.pantryRunningLow));
    expect(
      find
          .text('E2E Milch')
          .evaluate()
          .any(
            (e) =>
                top(tester, find.byWidget(e.widget)) >
                top(tester, find.text(de.pantryRunningLow)),
          ),
      isTrue,
    );
    await tab(tester, '🥫 ${PantryPlace.pantry.label}');
    expect(find.text('E2E Milch'), findsWidgets);
    await tab(tester, '🧊 ${PantryPlace.fridge.label}');
    expect(find.text('E2E Milch'), findsNothing);
    await synced(tester, state);
    final f = await theFamily();
    await eventually(tester, 'on the server', () async {
      for (final r in (await pull(f.admin, Collections.pantryItems)).values) {
        if (r.data['name'] == 'E2E Milch') {
          return PantryItem.fromRecord(r).amount == 1.5;
        }
      }
      return false;
    });
    await finish(tester, state);
  });

  // =========================================================================
  // Haushaltsbuch
  // =========================================================================

  testWidgets('HAU-175 the categories of the booking editor', (tester) async {
    await reset(_budget);
    await seedBooking(
      'E2E Futter',
      2999,
      category: 'Hund',
      importId: 'e2e-import-hund',
    );
    await seedBooking('E2E Job', 20000, category: 'Nebenjob', income: true);
    final f = await theFamily();
    await seed(f.admin, Collections.budgetSettings, {
      BudgetSettings.recordId: const BudgetSettings(
        limits: {'Verein': 5000},
      ).toData(),
    });
    addTearDown(() => restrictBudget(null));
    final state = await start(tester);
    await openBudget(tester);
    await waitFor(tester, booking('E2E Futter'));
    await tap(tester, find.byTooltip(de.budgetAddBooking));
    await waitFor(tester, inSheet(find.text(de.budgetIncome2)));
    List<String> chips() => [
      for (final e in inSheet(find.byType(ChoiceChip)).evaluate())
        ...textsIn(find.byWidget(e.widget)),
    ];
    const known = {
      ...expenseCategories,
      ...incomeCategories,
      'Hund',
      'Verein',
      'Nebenjob',
    };
    List<String> categories() => [
      for (final c in chips())
        if (known.contains(c)) c,
    ];
    debugPrint('E2E-INFO HAU-175 chips of expenses: ${chips()}');
    expect(categories(), [...expenseCategories, 'Hund', 'Verein']);
    await tap(tester, inSheet(find.text(de.budgetIncome2)));
    await tester.pump(const Duration(milliseconds: 500));
    debugPrint('E2E-INFO HAU-175 chips of income: ${chips()}');
    expect(categories(), [...incomeCategories, 'Nebenjob']);
    await closeSheet(tester);
    await finish(tester, state);
  });

  testWidgets('HAU-176 restricted to A: B keeps the own bookings, the child '
      'gets none, who wrote stays', (tester) async {
    await reset(_budget);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final kid = await sessionOf(f.kid);
    addTearDown(() => restrictBudget(null));
    final ofA = await seedBooking('E2E Von A', 1000);
    final ofB = await seedBooking('E2E Von B', 2000, as: bea);
    final abo = await seedSubscription('E2E Abo A', 999);
    Future<Map<String, SyncRecord>> bookingsOf(FamioApiClient api) =>
        pull(api, Collections.budgetEntries);
    final state = await start(tester);
    await openBudget(tester);
    await waitFor(tester, booking('E2E Von B'));
    await tap(tester, find.byTooltip(de.budgetWhoSeesLimits));
    await waitFor(tester, find.text(de.budgetWhoSeesBudget));
    for (final m in [kitAdminName, f.bea.displayName, f.kid.displayName]) {
      final chip = find.widgetWithText(FilterChip, m);
      if (tester.widget<FilterChip>(chip).selected != (m == kitAdminName)) {
        await tap(tester, chip);
      }
    }
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.budgetWhoSeesBudget));
    await synced(tester, state);
    await eventually(tester, 'B keeps only the own, the child none', () async {
      final b = await bookingsOf(bea);
      final k = await bookingsOf(kid);
      return b.keys.toSet().containsAll({ofB}) &&
          !b.containsKey(ofA) &&
          k.isEmpty &&
          (await pull(bea, Collections.subscriptions)).isEmpty;
    });
    final all = await bookingsOf(f.admin);
    expect(all[ofB]!.visibleTo?.toSet(), {f.adminMember.id, f.bea.id});
    expect(all[ofA]!.visibleTo, [f.adminMember.id]);
    expect(all[ofB]!.updatedBy, f.bea.id, reason: 'who wrote it stays');
    expect(all[ofA]!.updatedBy, f.adminMember.id);
    expect((await pull(f.admin, Collections.subscriptions))[abo]!.visibleTo, [
      f.adminMember.id,
    ]);
    expect(await pull(kid, Collections.subscriptions), isEmpty);
    await finish(tester, state);
  });

  testWidgets('HAU-177 a child writes into a household book restricted to A', (
    tester,
  ) async {
    await reset(_budget);
    final f = await theFamily();
    final service = await serviceAccount();
    final bea = await sessionOf(f.bea);
    final ha = await sessionOf(service);
    addTearDown(() => restrictBudget(null));
    await restrictBudget([f.adminMember.id]);
    // Through the app of the child.
    final state = await start(tester, user: f.kid.username);
    await openBudget(tester);
    await waitFor(tester, find.text(de.budgetFirstBooking));
    await tap(tester, find.widgetWithText(ColorButton, de.budgetFirstBooking));
    await waitFor(tester, inSheet(find.text(de.budgetExpense)));
    await enter(tester, inSheet(field(de.commonAmount)), '3');
    await enter(tester, inSheet(field(de.budgetWhatOptional)), 'E2E Kind Eis');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, booking('E2E Kind Eis'));
    await synced(tester, state);
    // And without an audience through the API, as an older app.
    final kid = await sessionOf(f.kid);
    final bare = uid('booking');
    await seed(kid, Collections.budgetEntries, {
      bare: BudgetEntry(
        id: bare,
        date: today(),
        cents: 200,
        category: 'Freizeit',
        note: 'E2E Kind ohne Zielgruppe',
        memberId: f.kid.id,
      ).toData(),
    });
    Future<Set<String>> notes(FamioApiClient api) async => {
      for (final r in (await pull(api, Collections.budgetEntries)).values)
        '${r.data['note']}',
    };
    await eventually(
      tester,
      'A gets both',
      () async => (await notes(
        f.admin,
      )).containsAll(['E2E Kind Eis', 'E2E Kind ohne Zielgruppe']),
    );
    final forA = await pull(f.admin, Collections.budgetEntries);
    for (final r in forA.values) {
      expect(r.visibleTo?.toSet(), {
        f.adminMember.id,
        f.kid.id,
      }, reason: '${r.data['note']}');
    }
    expect(await notes(bea), isEmpty, reason: 'not B');
    expect(await notes(ha), isEmpty, reason: 'not the service account');
    expect(await notes(kid), {
      'E2E Kind Eis',
      'E2E Kind ohne Zielgruppe',
    }, reason: 'the child keeps its own');
    await finish(tester, state);
  });

  // =========================================================================
  // Geänderte Einträge: was catalog_hau_test.dart nicht prüft
  // =========================================================================

  // HAU-013, HAU-014 (#570): both messages offer "Erneut versuchen"; the
  // address stays in "Quelle", the editor stays usable.
  testWidgets('HAU-013 HAU-014 no recipe, out of reach: "Erneut versuchen", '
      'the address in "Quelle"', (tester) async {
    await reset(_meals);
    final state = await start(tester);
    await newRecipe(tester);
    // HAU-013: the start page of the Famio server, a page without a recipe.
    final page = '$kitUrl/';
    await importFrom(tester, page);
    await waitFor(tester, snackText(de.mealsNoRecipeWasFound));
    expect(retryAction(), findsOneWidget);
    expect(textOf(tester, field(de.mealsSourceOptional)), page);
    await waitGone(
      tester,
      find.byType(SnackBar),
      timeout: const Duration(seconds: 20),
    );
    // HAU-014: nothing listens there.
    const away = 'http://127.0.0.1:9/rezept';
    await importFrom(tester, away);
    await waitFor(
      tester,
      snackText(de.mealsPageNotReachable),
      timeout: const Duration(seconds: 60),
    );
    expect(retryAction(), findsOneWidget);
    expect(textOf(tester, field(de.mealsSourceOptional)), away);
    expect(textOf(tester, field(de.commonTitle)), '');
    expect(textOf(tester, field(de.mealsIngredientsOnePerLine)), '');
    await enter(tester, field(de.commonTitle), 'E2E bedienbar');
    expect(textOf(tester, field(de.commonTitle)), 'E2E bedienbar');
    expect(isEnabled(tester, button(de.commonSave).first), isTrue);
    await finish(tester, state);
  });

  // HAU-015 (6065651): without a scheme https:// is put before it; a
  // mailto: address is no web page.
  testWidgets('HAU-015 an address without https://, and mailto:', (
    tester,
  ) async {
    await reset(_meals);
    final state = await start(tester);
    await newRecipe(tester);
    // A name that never resolves (RFC 6761): no real site is asked.
    await importFrom(tester, 'e2e.invalid/rezept');
    await waitFor(
      tester,
      find.byType(SnackBar),
      timeout: const Duration(seconds: 60),
    );
    expect(
      textOf(tester, field(de.mealsSourceOptional)),
      'https://e2e.invalid/rezept',
    );
    await waitGone(
      tester,
      find.byType(SnackBar),
      timeout: const Duration(seconds: 20),
    );
    await enter(tester, field(de.mealsSourceOptional), '');
    await tap(tester, find.text(de.mealsTakeWebsite));
    await waitFor(tester, find.text(de.mealsRecipeWebsite));
    await enter(
      tester,
      inDialog(find.byType(TextField)),
      'mailto:koch@example.org',
    );
    await tap(tester, inDialog(find.text(de.commonApply)));
    await tester.pump(const Duration(seconds: 1));
    final said = [
      ...find
          .descendant(of: find.byType(SnackBar), matching: find.byType(Text))
          .evaluate()
          .map((e) => (e.widget as Text).data),
      ...inDialog(
        find.byType(Text),
      ).evaluate().map((e) => (e.widget as Text).data),
    ];
    debugPrint('E2E-INFO HAU-015 mailto: $said');
    expect(said, contains(de.mealsWebAddressNeeded));
    if (dialog().evaluate().isNotEmpty) {
      await tap(tester, inDialog(find.text(de.commonCancel)));
      await dialogClosed(tester);
    }
    expect(textOf(tester, field(de.mealsSourceOptional)), '');
    await finish(tester, state);
  });

  // HAU-151 (#539): what still works for a guest, and what the server makes
  // of the guest's writes.
  testWidgets('HAU-151 a guest: onto the shopping list, no barcode, nothing '
      'through the API', (tester) async {
    await reset(_meals);
    final f = await theFamily();
    final recipe = await seedRecipe(
      'E2E Gastsalat',
      ingredients: ['2 Gurken', '1 Feta'],
    );
    final list = await seedList('E2E Gastliste');
    final pantry = await seedPantry('E2E Gastreis', amount: 2);
    final state = await start(tester, user: f.guest.username);
    final engine = state.engine!;
    await openRecipe(tester, 'E2E Gastsalat');
    await tap(tester, find.text(de.mealsEverythingShoppingList));
    if (inSheet(find.text(de.commonWhichList)).evaluate().isNotEmpty) {
      await chooseList(tester, 'E2E Gastliste');
    }
    await until(
      tester,
      () => engine.shoppingItems(list).map((i) => i.name).toSet().containsAll({
        'Gurken',
        'Feta',
      }),
      'on the list',
    );
    await synced(tester, state);
    await eventually(tester, 'on the server', () async {
      final names = {
        for (final r in (await pull(f.admin, Collections.shoppingItems)).values)
          if (r.data['listId'] == list) r.data['name'],
      };
      return names.containsAll({'Gurken', 'Feta'});
    });
    await back(tester);
    await openPantry(tester);
    await waitFor(tester, find.text('E2E Gastreis'));
    expect(find.byTooltip(de.pantryScanBarcode), findsNothing);
    expect(find.text(de.pantryScanBarcode), findsNothing);
    // Through the API.
    final guest = await sessionOf(f.guest);
    final current = (await pull(guest, Collections.recipes))[recipe]!;
    await put(guest, Collections.recipes, {
      recipe: {...current.data, 'title': 'E2E Vom Gast'},
    });
    final meal = uid('meal');
    await put(guest, Collections.mealPlan, {
      meal: PlannedMeal(
        id: meal,
        date: today(),
        slot: MealSlot.lunch,
        title: 'E2E Gastessen',
      ).toData(),
    });
    final stock = (await pull(guest, Collections.pantryItems))[pantry]!;
    await put(guest, Collections.pantryItems, {
      pantry: {...stock.data, 'amount': 9},
    });
    expect(await titlesOf(f.admin, Collections.recipes), {'E2E Gastsalat'});
    expect((await pull(f.admin, Collections.mealPlan))[meal], isNull);
    expect(
      PantryItem.fromRecord(
        (await pull(f.admin, Collections.pantryItems))[pantry]!,
      ).amount,
      2,
    );
    await finish(tester, state);
  });

  // HAU-162 (#538): B's booking reaches neither the child nor the service
  // account; A sees it, with A and B as its audience.
  testWidgets('HAU-162 B writes into a household book restricted to A', (
    tester,
  ) async {
    await reset(_budget);
    final f = await theFamily();
    final service = await serviceAccount();
    final kid = await sessionOf(f.kid);
    final ha = await sessionOf(service);
    addTearDown(() => restrictBudget(null));
    await restrictBudget([f.adminMember.id]);
    await seedBooking('E2E Von A allein', 3000, visibleTo: [f.adminMember.id]);
    final state = await start(tester, user: f.bea.username);
    await openBudget(tester);
    await waitFor(tester, find.text(de.budgetFirstBooking));
    expect(find.text('E2E Von A allein'), findsNothing);
    await tap(tester, find.widgetWithText(ColorButton, de.budgetFirstBooking));
    await waitFor(tester, inSheet(find.text(de.budgetExpense)));
    await enter(tester, inSheet(field(de.commonAmount)), '8');
    await enter(
      tester,
      inSheet(field(de.budgetWhatOptional)),
      'E2E Bea Kaffee',
    );
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, booking('E2E Bea Kaffee'));
    await synced(tester, state);
    SyncRecord? named(Map<String, SyncRecord> all) =>
        all.values.where((r) => r.data['note'] == 'E2E Bea Kaffee').firstOrNull;
    await eventually(
      tester,
      'A sees it',
      () async => named(await pull(f.admin, Collections.budgetEntries)) != null,
    );
    final forA = named(await pull(f.admin, Collections.budgetEntries))!;
    expect(forA.visibleTo?.toSet(), {f.adminMember.id, f.bea.id});
    expect(named(await pull(kid, Collections.budgetEntries)), isNull);
    expect(named(await pull(ha, Collections.budgetEntries)), isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('E2E Bea Kaffee'), findsWidgets, reason: 'B keeps it');
    await finish(tester, state);
  });

  // =========================================================================
  // Dokumente
  // =========================================================================

  testWidgets('HAU-182 opening a file of a document while the server is gone', (
    tester,
  ) async {
    await reset({Collections.documents});
    final f = await theFamily();
    final launcher = fakeLauncher();
    final pdf = await f.admin.uploadFile(
      bytes: await pdfBytes('Mietvertrag'),
      name: 'e2e-mietvertrag.pdf',
      mime: 'application/pdf',
    );
    await seedDocument('E2E Mietvertrag', file: pdf);
    final relay = _Relay(kitUrl);
    await relay.start();
    final state = await startAt(tester, relay.url);
    await openDocuments(tester);
    await waitFor(tester, find.text('E2E Mietvertrag'));
    await relay.stop();
    await tap(tester, find.text('E2E Mietvertrag'));
    await waitFor(tester, inSheet(find.text(de.commonOpen)));
    await tap(tester, inSheet(find.text(de.commonOpen)));
    await waitFor(
      tester,
      find.byType(SnackBar),
      timeout: const Duration(seconds: 60),
    );
    final message = find
        .descendant(of: find.byType(SnackBar), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .join(' ');
    debugPrint('E2E-INFO HAU-182 message: $message');
    expect(message.trim(), isNotEmpty);
    expect(launcher.opened, isEmpty, reason: 'nothing to open');
    // Over the sheet, readable; the sheet stays.
    expect(
      find.descendant(of: sheet(), matching: find.byType(SnackBar)),
      findsOneWidget,
    );
    // A plain message takes no taps over a sheet (SheetMessenger); it lies
    // over the sheet, on screen.
    final box = tester.getRect(find.byType(SnackBar));
    final screen =
        Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      screen.contains(box.topLeft) &&
          screen.contains(box.bottomRight - const Offset(1, 1)),
      isTrue,
      reason: 'on screen: $box',
    );
    expect(sheet(), findsOneWidget);
    expect(inSheet(find.text('E2E Mietvertrag')), findsOneWidget);
    await finish(tester, state);
  });
}
