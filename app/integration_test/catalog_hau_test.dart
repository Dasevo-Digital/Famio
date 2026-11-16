// Catalog tests of the area "Haushalt, Essen, Finanzen, Dokumente" (HAU) in
// the real app against a throwaway server (one per run of this file):
//
//   tool/integration_tests.sh macos integration_test/catalog_hau_test.dart
//
// One test per catalog entry or small group of entries; the name begins
// with the ids. What a person does goes through the app's own pages; what
// another device, member or account does goes through the API. Native
// parts are replaced at their plugin boundary: the file picker hands in the
// file a person would have picked, "open with" and the browser keep the
// address, the clipboard holds what the test put there. Recipe pages come
// from a small server of the test on 127.0.0.1 (on the Mac the app fetches
// them itself); Open Food Facts is never asked. Each test starts from its
// own data: what earlier tests left in its collections is removed first.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/meal_suggestions.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/budget_screens.dart';
import 'package:famio/src/screens/cooking_mode.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio/src/screens/home_screen.dart';
import 'package:famio/src/screens/home_tiles.dart';
import 'package:famio/src/screens/meal_suggest_screen.dart';
import 'package:famio/src/screens/meals_screens.dart';
import 'package:famio/src/screens/nutrition_screens.dart';
import 'package:famio/src/screens/pantry_screens.dart';
import 'package:famio/src/screens/subscriptions_screen.dart';
import 'package:famio/src/screens/year_review_screen.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio/src/widgets/member_avatar.dart';
import 'package:famio/src/widgets/photo_viewer.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';

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

/// No connection to anywhere: every new HTTP client goes to a proxy that
/// refuses (as without network). Clients made before keep working.
class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'PROXY 127.0.0.1:9';
}

/// The throwaway server behind a relay of the test, which can be switched
/// off: for the app the server is gone, as if it had been stopped.
class _Relay {
  _Relay(this.target);

  final String target;
  late final HttpServer _server;
  final _client = HttpClient()..autoUncompress = false;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_relay);
  }

  Future<void> _relay(HttpRequest request) async {
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

/// Recipe pages as a site serves them (schema.org `Recipe` in JSON-LD).
class _Pages {
  late final HttpServer _server;
  final requests = <String>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requests.add(request.uri.path);
      final response = request.response;
      switch (request.uri.path) {
        case '/rezept':
          response.headers.contentType = ContentType.html;
          response.write(
            '<html><head><title>E2E Apfelkuchen</title>'
            '<script type="application/ld+json">${jsonEncode({
              '@context': 'https://schema.org',
              '@type': 'Recipe',
              'name': 'E2E Apfelkuchen',
              'recipeYield': '8',
              'totalTime': 'PT50M',
              // Its photo lies in the private network: the server must not
              // fetch it.
              'image': '$url/bild.png',
              'recipeIngredient': ['500 g Äpfel', '200 g Mehl', '3 Eier'],
              'recipeInstructions': ['Äpfel schneiden.', '40 Minuten backen.'],
            })}</script></head><body>Kuchen</body></html>',
          );
        case '/bild.png':
          response.headers.contentType = ContentType('image', 'png');
          response.add(await pngBytes());
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
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

void main() {
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  // Recipes
  // =========================================================================

  testWidgets('HAU-002 HAU-001 HAU-003 HAU-008 a recipe by hand: title '
      'required, servings 1 to 50, search', (tester) async {
    await reset(_meals);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final state = await start(tester);
    final engine = state.engine!;
    await openRecipes(tester);

    // The empty list offers the first recipe.
    await waitFor(tester, find.text(de.mealsCollectFavoriteRecipesWritten));
    await tap(tester, find.widgetWithText(ColorButton, de.mealsAddRecipe));
    await waitFor(tester, find.text(de.mealsNewRecipe));

    // HAU-002: without a title nothing is saved, the editor stays.
    await enter(tester, field(de.mealsIngredientsOnePerLine), '250 g Mehl');
    await tap(tester, find.text(de.commonSave).last);
    await idle(tester, const Duration(seconds: 1));
    expect(find.text(de.mealsNewRecipe), findsOneWidget);
    expect(engine.recipes, isEmpty);
    expect(find.byType(SnackBar), findsNothing, reason: 'no message (hint)');

    // HAU-001: all fields.
    await enter(tester, field(de.commonTitle), 'E2E Gemüsepfanne');
    await enter(tester, field(de.mealsServings), '2');
    await enter(tester, field(de.mealsMinutes), '30');
    await enter(
      tester,
      field(de.mealsIngredientsOnePerLine),
      '250 g Mehl\n3 Eier',
    );
    await enter(
      tester,
      field(de.mealsPreparationOneStepPer),
      'Gemüse schneiden.\nAnbraten.',
    );
    await enter(tester, field(de.mealsTagsOptional), 'schnell, vegetarisch');
    await enter(tester, field(de.mealsSourceOptional), 'Oma Inge');
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.mealsNewRecipe));
    await waitFor(tester, find.text('E2E Gemüsepfanne'));
    expect(
      recipeSubtitle(tester, 'E2E Gemüsepfanne'),
      '${de.mealsCountIngredients(2)} · 30 min · schnell · vegetarisch',
    );
    final saved = engine.recipes.single;
    expect((saved.servings, saved.minutes, saved.source), (2, 30, 'Oma Inge'));
    expect(saved.tags, ['schnell', 'vegetarisch']);
    expect(saved.ingredients.map((i) => i.editText), ['250 g Mehl', '3 Eier']);
    expect(saved.steps, 'Gemüse schneiden.\nAnbraten.');
    await synced(tester, state);
    await eventually(
      tester,
      'Bea gets the recipe',
      () async => (await titlesOf(
        bea,
        Collections.recipes,
      )).contains('E2E Gemüsepfanne'),
    );

    // HAU-003: 0 → 1, 100 → 50, empty → 4.
    for (final (title, servings) in [
      ('E2E Null Portionen', '0'),
      ('E2E Hundert Portionen', '100'),
      ('E2E Ohne Portionen', ''),
    ]) {
      await tap(tester, find.byTooltip(de.mealsAddRecipe));
      await waitFor(tester, find.text(de.mealsNewRecipe));
      await enter(tester, field(de.commonTitle), title);
      await enter(tester, field(de.mealsServings), servings);
      await tap(tester, find.text(de.commonSave).last);
      await waitGone(tester, find.text(de.mealsNewRecipe));
      await waitFor(tester, find.text(title));
    }
    for (final (title, servings) in [
      ('E2E Null Portionen', '1'),
      ('E2E Hundert Portionen', '50'),
      ('E2E Ohne Portionen', '4'),
    ]) {
      await tap(tester, find.text(title));
      await waitFor(tester, find.byType(RecipeScreen));
      expect(servingsShown(tester), servings, reason: title);
      await back(tester);
      await waitGone(tester, find.byType(RecipeScreen));
    }

    // HAU-008: by title, tag and ingredient, case does not matter.
    await seedRecipe('E2E Dal', ingredients: ['200 g Rote Linsen']);
    await seedRecipe('E2E Kartoffelsuppe', tags: ['deftig']);
    await arrives(
      tester,
      state,
      (e) => e.recipes.length == 6,
      'the two recipes of another device',
    );
    final search = find.byType(TextField).first;
    Future<void> searchFor(String q, Set<String> shown) async {
      await enter(tester, search, q);
      await tester.pump(const Duration(milliseconds: 400));
      for (final t in [
        'E2E Gemüsepfanne',
        'E2E Dal',
        'E2E Kartoffelsuppe',
        'E2E Null Portionen',
      ]) {
        expect(
          find.text(t),
          shown.contains(t) ? findsOneWidget : findsNothing,
          reason: '"$q": $t',
        );
      }
    }

    await searchFor('LINSEN', {'E2E Dal'});
    await searchFor('Vegetarisch', {'E2E Gemüsepfanne'});
    await searchFor('kartoffel', {'E2E Kartoffelsuppe'});
    await searchFor('pORTION', {'E2E Null Portionen'});
    await finish(tester, state);
  });

  testWidgets('HAU-024 HAU-004 HAU-007 recipe page: cooking mode only with '
      'steps, servings, favourite', (tester) async {
    await reset(_meals);
    await seedRecipe(
      'E2E Pfannkuchen',
      ingredients: ['250 g Mehl', '3 Eier', '500 ml Milch'],
    );
    await seedRecipe(
      'E2E Eintopf',
      ingredients: ['500 g Kartoffeln'],
      steps: 'Schälen.\nKochen.\nWürzen.',
    );
    final state = await start(tester);
    final engine = state.engine!;

    // HAU-024: only with steps.
    await openRecipe(tester, 'E2E Pfannkuchen');
    expect(inRecipe(find.text(de.mealsCookingMode)), findsNothing);

    // HAU-004: more and fewer servings.
    final more = inRecipe(find.byTooltip(de.navMore));
    final fewer = find.ancestor(
      of: inRecipe(find.byTooltip(de.mealsFewer)),
      matching: find.byType(IconButton),
    );
    expect(servingsShown(tester), '4');
    expect(inRecipe(find.text('250 g')), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tap(tester, more);
    }
    expect(servingsShown(tester), '8');
    expect(inRecipe(find.text('500 g')), findsOneWidget);
    expect(inRecipe(find.text('6')), findsOneWidget, reason: 'six eggs');
    expect(inRecipe(find.text('1000 ml')), findsOneWidget);
    for (var i = 0; i < 7; i++) {
      await tap(tester, fewer);
    }
    expect(servingsShown(tester), '1');
    expect(isEnabled(tester, fewer), isFalse);

    // HAU-007: a favourite.
    await tap(tester, find.byTooltip(de.mealsFavorite));
    await waitFor(tester, find.byTooltip(de.mealsNoLongerFavorite));
    expect(
      engine.recipes.firstWhere((r) => r.title == 'E2E Pfannkuchen').favorite,
      isTrue,
    );
    await back(tester);
    await waitFor(
      tester,
      inTile('E2E Pfannkuchen', find.byIcon(AppIcons.heart)),
    );
    expect(
      tester
          .widget<Icon>(inTile('E2E Pfannkuchen', find.byIcon(AppIcons.heart)))
          .color,
      const Color(0xFFDB4A7E),
    );
    expect(inTile('E2E Eintopf', find.byIcon(AppIcons.heart)), findsNothing);
    // … and a star in "Woche vorschlagen".
    await tab(tester, de.mealsWeekPlan);
    await weeksAhead(tester, 1);
    await tap(tester, find.text(de.mealsSuggestWeek));
    await waitFor(tester, find.byType(MealSuggestScreen));
    await waitFor(tester, find.text('E2E Pfannkuchen ★'));
    expect(find.text('E2E Eintopf'), findsOneWidget);
    await back(tester);
    await waitGone(tester, find.byType(MealSuggestScreen));
    await tab(tester, de.mealsRecipes);
    await tap(tester, find.text('E2E Pfannkuchen'));
    await waitFor(tester, find.byType(RecipeScreen));
    await tap(tester, find.byTooltip(de.mealsNoLongerFavorite));
    await waitFor(tester, find.byTooltip(de.mealsFavorite));
    await back(tester);
    await waitFor(tester, find.text('E2E Pfannkuchen'));
    await until(
      tester,
      () => inTile(
        'E2E Pfannkuchen',
        find.byIcon(AppIcons.heart),
      ).evaluate().isEmpty,
      'heart gone',
    );

    // HAU-024: with steps there is the cooking mode, with its hint.
    await tap(tester, find.text('E2E Eintopf'));
    await waitFor(tester, find.byType(RecipeScreen));
    expect(
      find.descendant(
        of: find.byTooltip(de.mealsCookingModeHint),
        matching: find.text(de.mealsCookingMode),
      ),
      findsOneWidget,
    );
    await finish(tester, state);
  });

  testWidgets('HAU-026 HAU-030 cooking mode: pages, keys, swiping, a timer '
      'chip', (tester) async {
    await reset(_meals);
    await seedRecipe(
      'E2E Nudeltopf',
      servings: 2,
      ingredients: ['200 g Nudeln'],
      steps: 'Nudeln 10 Minuten kochen.\nSoße rühren.\nAnrichten.',
    );
    final state = await start(tester);
    await openRecipe(tester, 'E2E Nudeltopf');
    await tap(tester, find.text(de.mealsCookingMode));
    await waitFor(tester, find.byType(CookingModeScreen));
    final cook = find.byType(CookingModeScreen);
    Finder inCook(Finder f) => find.descendant(of: cook, matching: f);
    final backButton = find.ancestor(
      of: inCook(find.text(de.commonBack)),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    );
    Future<void> onStep(int n) => until(
      tester,
      () => inCook(find.text(de.cookStepOf(n, 3))).evaluate().length == 2,
      'step $n, top and bottom',
    );

    // The ingredients first; "Zurück" off.
    await waitFor(
      tester,
      find.text('${de.mealsIngredients} · ${de.mealsServings} 2'),
    );
    expect(isEnabled(tester, backButton), isFalse);
    await tap(tester, inCook(find.text(de.commonNext)));
    await onStep(1);
    expect(find.text('Nudeln 10 Minuten kochen.'), findsOneWidget);
    expect(isEnabled(tester, backButton), isTrue);

    // HAU-030: a timer on step 1, then elsewhere.
    await tap(tester, find.text(de.cookTimer(de.cookMinutes('10'))));
    final chip = find.byType(InputChip);
    await waitFor(tester, chip);
    expect(find.textContaining('${de.cookStepOf(1, 3)} · 09:'), findsOneWidget);
    await tap(tester, inCook(find.text(de.commonNext)));
    await onStep(2);
    await tap(tester, inCook(find.text(de.commonNext)));
    await onStep(3);
    // The last page ends with "Fertig".
    expect(
      inCook(find.widgetWithText(ColorButton, de.commonDone)),
      findsOneWidget,
    );
    await tap(tester, chip);
    await onStep(1);
    expect(find.text('Nudeln 10 Minuten kochen.'), findsOneWidget);
    await tap(tester, find.byTooltip(de.cookTimerStop));
    await waitGone(tester, chip);

    // HAU-026: keys (the page has the keyboard, as after opening it).
    Focus.of(
      tester.element(
        find.descendant(of: cook, matching: find.byType(Scaffold)),
      ),
    ).requestFocus();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await onStep(2);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await onStep(3);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await onStep(2);
    // Swiping.
    await tester.fling(find.byType(PageView), const Offset(500, 0), 1500);
    await onStep(1);
    await idle(tester, const Duration(seconds: 1));
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1500);
    await onStep(2);
    // The page settles before the next tap.
    await idle(tester, const Duration(seconds: 1));
    // Back to the ingredients with "Zurück".
    await tap(tester, backButton);
    await onStep(1);
    await tap(tester, backButton);
    await waitFor(
      tester,
      find.text('${de.mealsIngredients} · ${de.mealsServings} 2'),
    );
    expect(isEnabled(tester, backButton), isFalse);
    // To the end and "Fertig": closed, without a question (no timer).
    for (var n = 1; n <= 3; n++) {
      await tap(tester, inCook(find.text(de.commonNext)));
      await onStep(n);
    }
    await tap(tester, inCook(find.text(de.commonDone)));
    await waitGone(tester, cook);
    expect(find.text(de.cookLeaveTitle), findsNothing);
    expect(find.byType(RecipeScreen), findsOneWidget);
    await finish(tester, state);
  });

  testWidgets('HAU-010 a photo of our own for a recipe', (tester) async {
    await reset(_meals);
    final picker = fakePicker();
    final png = await pngBytes(color: const Color(0xFFE8703A));
    picker.picks.add(await tempFile('e2e-auflauf.png', png));
    final state = await start(tester);
    final engine = state.engine!;
    await openRecipes(tester);
    await tap(tester, find.byTooltip(de.mealsAddRecipe));
    await waitFor(tester, find.text(de.mealsNewRecipe));
    await tap(tester, find.text(de.commonPhoto));
    // Uploaded; a preview, and the button changes.
    await waitFor(tester, find.text(de.mealsChangePhoto));
    await waitFor(tester, find.byType(CachedImage));
    await enter(tester, field(de.commonTitle), 'E2E Fotoauflauf');
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.mealsNewRecipe));
    await waitFor(tester, inTile('E2E Fotoauflauf', find.byType(CachedImage)));
    expect(
      tester
          .widget<CachedImage>(
            inTile('E2E Fotoauflauf', find.byType(CachedImage)),
          )
          .thumb,
      160,
      reason: 'small in the list',
    );
    final photo = engine.recipes.single.photo!;
    expect((photo.name, photo.mime), ('e2e-auflauf.png', 'image/png'));
    await tap(tester, find.text('E2E Fotoauflauf'));
    await waitFor(tester, inRecipe(find.byType(CachedImage)));
    expect(
      tester.widget<CachedImage>(inRecipe(find.byType(CachedImage))).thumb,
      960,
      reason: 'big on the recipe page',
    );
    await synced(tester, state);
    expect(await engine.api.downloadFile(photo.id), png);
    await finish(tester, state);
  });

  testWidgets('HAU-006 a recipe deleted and brought back', (tester) async {
    await reset(_meals);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final soup = await seedRecipe('E2E Testsuppe', ingredients: ['1 Brühe']);
    final week = mondayOf(today());
    final meal = await seedMeal(week, MealSlot.dinner, recipeId: soup);
    final state = await start(tester);
    final engine = state.engine!;
    Future<void> deleteIt() async {
      await openRecipe(tester, 'E2E Testsuppe');
      await tap(tester, find.byTooltip(de.commonEdit));
      await waitFor(tester, find.text(de.mealsEditRecipe));
      await scrollTo(tester, find.text(de.mealsDeleteRecipe));
      await tap(tester, find.text(de.mealsDeleteRecipe));
      await waitFor(
        tester,
        inDialog(find.text(de.commonDeleteName('E2E Testsuppe'))),
      );
      await tap(tester, inDialog(find.text(de.commonDelete)));
      await dialogClosed(tester);
    }

    await deleteIt();
    // Back on the list, without it.
    await waitGone(tester, find.text(de.mealsEditRecipe));
    await waitGone(tester, find.byType(RecipeScreen));
    await waitFor(tester, find.text(de.mealsRecipes));
    expect(find.text('E2E Testsuppe'), findsNothing);
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Testsuppe')));
    await undo(tester);
    await waitFor(tester, find.text('E2E Testsuppe'));
    await synced(tester, state);
    await eventually(
      tester,
      'Bea has it again',
      () async =>
          (await titlesOf(bea, Collections.recipes)).contains('E2E Testsuppe'),
    );

    // Hint: for good, without a trash; the planned meal stays without title.
    await snackGone(tester);
    await deleteIt();
    await waitGone(tester, find.byType(RecipeScreen));
    await snackGone(tester);
    await synced(tester, state);
    await eventually(
      tester,
      'gone for Bea',
      () async =>
          !(await titlesOf(bea, Collections.recipes)).contains('E2E Testsuppe'),
    );
    final trash = await f.admin.trash();
    expect(
      trash.items.where((t) => t.record.collection == Collections.recipes),
      isEmpty,
      reason: 'recipes do not go to the trash',
    );
    expect(
      engine
          .plannedMeals(week, DateUtils.addDaysToDate(week, 7))
          .map((m) => m.id),
      contains(meal),
      reason: 'the planned meal stays (#482)',
    );
    await tab(tester, de.mealsWeekPlan);
    await waitFor(tester, inDay(week, find.text(MealSlot.dinner.label)));
    debugPrint(
      'E2E HAU-006 meal of the deleted recipe: '
      '${find.descendant(of: dayCard(week), matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data).join(' | ')}',
    );
    await finish(tester, state);
  });

  // =========================================================================
  // Recipes from web pages
  // =========================================================================

  testWidgets('HAU-014 HAU-016 HAU-017 recipe from a web page: out of reach, '
      'a pasted link, a photo the server may not fetch', (tester) async {
    await reset(_meals);
    final pages = _Pages();
    await pages.start();
    addTearDown(pages.stop);
    final state = await start(tester);
    await openRecipes(tester);
    await tap(tester, find.byTooltip(de.mealsAddRecipe));
    await waitFor(tester, find.text(de.mealsNewRecipe));
    final address = inDialog(find.byType(TextField));
    Future<void> openImport() async {
      await tap(tester, find.text(de.mealsTakeWebsite));
      await waitFor(tester, find.text(de.mealsRecipeWebsite));
    }

    // HAU-014: nothing listens there.
    await openImport();
    await enter(tester, address, 'http://127.0.0.1:9/rezept');
    await tap(tester, inDialog(find.text(de.commonApply)));
    await waitFor(tester, snackText(de.mealsPageNotReachable));
    expect(textOf(tester, field(de.commonTitle)), '');
    expect(textOf(tester, field(de.mealsIngredientsOnePerLine)), '');
    expect(isEnabled(tester, button(de.commonSave).first), isTrue);
    await enter(tester, field(de.commonTitle), 'E2E noch bedienbar');
    expect(textOf(tester, field(de.commonTitle)), 'E2E noch bedienbar');
    await snackGone(tester);

    // HAU-016: only the link of the copied text, only on request.
    var clipboard = 'Lasagne https://e2e.invalid/lasagne';
    await withClipboard(tester, paste: () => clipboard, (reads) async {
      await openImport();
      await enter(tester, address, '');
      await tester.pump(const Duration(milliseconds: 500));
      expect(reads[0], 0, reason: 'not read on its own');
      await tap(tester, inDialog(find.byTooltip(de.mealsPasteLink)));
      await until(
        tester,
        () => textOf(tester, address) == 'https://e2e.invalid/lasagne',
        'the link alone',
      );
      expect(reads[0], 1);
      clipboard = 'Nur Text ohne Adresse';
      await tap(tester, inDialog(find.byTooltip(de.mealsPasteLink)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(reads[0], 2);
      expect(textOf(tester, address), 'https://e2e.invalid/lasagne');
      await tap(tester, inDialog(find.text(de.commonCancel)));
      await dialogClosed(tester);
    });

    // HAU-017: filled in, the photo is turned down.
    await openImport();
    await enter(tester, address, '${pages.url}/rezept');
    await tap(tester, inDialog(find.text(de.commonApply)));
    await waitFor(
      tester,
      snackText(de.mealsPhotoNotImported),
      timeout: const Duration(seconds: 40),
    );
    expect(pages.requests, contains('/rezept'));
    expect(textOf(tester, field(de.commonTitle)), 'E2E Apfelkuchen');
    expect(textOf(tester, field(de.mealsServings)), '8');
    expect(
      textOf(tester, field(de.mealsIngredientsOnePerLine)),
      '500 g Äpfel\n200 g Mehl\n3 Eier',
    );
    expect(find.text(de.mealsChangePhoto), findsNothing, reason: 'no photo');
    expect(pages.requests, isNot(contains('/bild.png')), reason: 'not fetched');
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.mealsNewRecipe));
    await waitFor(tester, find.text('E2E Apfelkuchen'));
    await finish(tester, state);
  });

  // Ohne Rezept auf der Seite steht die eingegebene Adresse trotzdem in
  // „Quelle“ (#547).
  testWidgets('HAU-013 a page without a recipe keeps its address', (
    tester,
  ) async {
    await reset(_meals);
    final state = await start(tester);
    await openRecipes(tester);
    await tap(tester, find.byTooltip(de.mealsAddRecipe));
    await waitFor(tester, find.text(de.mealsNewRecipe));
    await tap(tester, find.text(de.mealsTakeWebsite));
    await waitFor(tester, find.text(de.mealsRecipeWebsite));
    // The start page of the Famio server: a page, but no recipe on it.
    final page = '$kitUrl/';
    await enter(tester, inDialog(find.byType(TextField)), page);
    await tap(tester, inDialog(find.text(de.commonApply)));
    await waitFor(tester, snackText(de.mealsNoRecipeWasFound));
    expect(textOf(tester, field(de.mealsSourceOptional)), page);
    await finish(tester, state);
  });

  // Eine Adresse ohne http(s) wird mit https:// versucht, statt still
  // verworfen zu werden (#547).
  testWidgets('HAU-015 an address without http(s)', (tester) async {
    await reset(_meals);
    final state = await start(tester);
    await openRecipes(tester);
    await tap(tester, find.byTooltip(de.mealsAddRecipe));
    await waitFor(tester, find.text(de.mealsNewRecipe));
    await tap(tester, find.text(de.mealsTakeWebsite));
    await waitFor(tester, find.text(de.mealsRecipeWebsite));
    // A name that never resolves (RFC 6761): no real site is asked.
    await enter(tester, inDialog(find.byType(TextField)), 'e2e.invalid/rezept');
    await tap(tester, inDialog(find.text(de.commonApply)));
    await dialogClosed(tester);
    // Famio says something, or tries it as https://.
    final said = DateTime.now().add(const Duration(seconds: 30));
    var answered = false;
    while (DateTime.now().isBefore(said) && !answered) {
      await tester.pump(const Duration(milliseconds: 200));
      answered =
          find.byType(SnackBar).evaluate().isNotEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    }
    expect(answered, isTrue, reason: 'nothing happened');
    expect(
      textOf(tester, field(de.mealsSourceOptional)),
      'https://e2e.invalid/rezept',
    );
    await finish(tester, state);
  });

  testWidgets('HAU-022 "Rezept" only for inbox entries with a link', (
    tester,
  ) async {
    final f = await theFamily();
    await reset({Collections.inbox});
    addTearDown(
      () => f.admin.updateServerSettings({'hiddenModules': <String>[]}),
    );
    final file = await f.admin.uploadFile(
      bytes: await pngBytes(),
      name: 'e2e-zettel.png',
      mime: 'image/png',
    );
    await seed(f.admin, Collections.inbox, {
      uid('inbox-a'): InboxItem(
        id: 'a',
        title: 'E2E Nur Text',
        text: 'Zettel vom Kühlschrank',
      ).toData(),
      uid('inbox-b'): InboxItem(
        id: 'b',
        title: 'E2E Mit Datei',
        text: 'https://e2e.invalid/rezept',
        files: [file],
      ).toData(),
      uid('inbox-c'): InboxItem(
        id: 'c',
        title: 'E2E Mit Link',
        text: 'Lecker: https://e2e.invalid/rezept',
      ).toData(),
    });
    final state = await start(tester);
    await openSection(tester, 'Start');
    await tap(tester, find.byTooltip(de.inboxTitle));
    await waitFor(tester, find.text('E2E Mit Link'));
    Future<bool> offersRecipe(String title) async {
      await tap(
        tester,
        find.descendant(
          of: find.widgetWithText(ListTile, title),
          matching: find.byTooltip(de.inboxFileAs),
        ),
      );
      await waitFor(tester, find.text(de.commonTask));
      final offered = find.text(de.commonRecipe).evaluate().isNotEmpty;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await waitGone(tester, find.text(de.commonTask));
      await tester.pump(const Duration(milliseconds: 300));
      return offered;
    }

    expect(await offersRecipe('E2E Nur Text'), isFalse);
    expect(await offersRecipe('E2E Mit Datei'), isFalse);
    expect(await offersRecipe('E2E Mit Link'), isTrue);
    // "Essen" hidden: nowhere.
    await f.admin.updateServerSettings({
      'hiddenModules': [FamioSection.meals.name],
    });
    await eventually(
      tester,
      'the app knows',
      () async => state.hiddenModules.contains(FamioSection.meals.name),
    );
    for (final t in ['E2E Nur Text', 'E2E Mit Datei', 'E2E Mit Link']) {
      expect(await offersRecipe(t), isFalse, reason: t);
    }
    await finish(tester, state);
  });

  // =========================================================================
  // Week plan
  // =========================================================================

  testWidgets('HAU-035 HAU-033 HAU-034 HAU-036 HAU-037 HAU-038 the week '
      'plan: weeks, a recipe, free text, changed and removed', (tester) async {
    await reset(_meals);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final lasagne = await seedRecipe(
      'E2E Lasagne',
      ingredients: ['250 g Lasagneplatten', '500 g Hack'],
    );
    final state = await start(tester);
    final engine = state.engine!;
    final now = today();
    final monday = mondayOf(now);
    final tuesday = DateUtils.addDaysToDate(monday, 1);
    final wednesday = DateUtils.addDaysToDate(monday, 2);
    final thursday = DateUtils.addDaysToDate(monday, 3);
    final friday = DateUtils.addDaysToDate(monday, 4);
    final next = DateUtils.addDaysToDate(monday, 7);
    String heading(DateTime m) =>
        '${DateFormat.MMMd('de').format(m)} – '
        '${DateFormat.MMMd('de').format(DateUtils.addDaysToDate(m, 6))}';
    await openWeek(tester);

    // HAU-035: Monday to Sunday, today tinted, "–" without a meal.
    await waitFor(tester, find.text(heading(monday)));
    expect(tester.widget<SoftCard>(dayCard(now).first).color, isNotNull);
    final other = now == monday ? tuesday : monday;
    expect(tester.widget<SoftCard>(dayCard(other).first).color, isNull);
    expect(inDay(other, find.text('–')), findsOneWidget);
    await weeksAhead(tester, 1);
    await waitFor(tester, find.text(heading(next)));
    expect(
      tester
          .widget<SoftCard>(dayCard(DateUtils.addDaysToDate(next, 2)).first)
          .color,
      isNull,
    );
    await weeksAhead(tester, -1);
    await waitFor(tester, find.text(heading(monday)));

    // HAU-033: a recipe for Tuesday's dinner, for three.
    await tap(tester, inDay(tuesday, find.byTooltip(de.mealsPlanMeal)));
    await waitFor(tester, inSheet(find.text(de.mealsPlanMeal)));
    expect(inSheet(find.text(de.mealsServings)), findsNothing);
    await tap(
      tester,
      inSheet(find.widgetWithText(ChoiceChip, MealSlot.dinner.label)),
    );
    await choose(tester, de.commonRecipe, 'E2E Lasagne');
    await waitFor(tester, inSheet(find.text(de.mealsServings)));
    await tap(tester, inSheet(find.widgetWithText(ChoiceChip, '3')));
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, inDay(tuesday, find.text('E2E Lasagne')));
    expect(inDay(tuesday, find.text(MealSlot.dinner.label)), findsOneWidget);
    await tap(tester, inDay(tuesday, find.text('E2E Lasagne')));
    await waitFor(tester, find.byType(RecipeScreen));
    expect(servingsShown(tester), '3');
    await back(tester);
    await waitGone(tester, find.byType(RecipeScreen));
    await synced(tester, state);
    await eventually(tester, 'Bea gets the meal', () async {
      final meals = (await pull(
        bea,
        Collections.mealPlan,
      )).values.map(PlannedMeal.fromRecord);
      return meals.any(
        (m) =>
            m.recipeId == lasagne &&
            m.date == tuesday &&
            m.servings == 3 &&
            m.slot == MealSlot.dinner,
      );
    });

    // HAU-034: free text for Wednesday's lunch; without text nothing.
    await tap(tester, inDay(wednesday, find.byTooltip(de.mealsPlanMeal)));
    await waitFor(tester, inSheet(find.text(de.mealsPlanMeal)));
    expect(inSheet(find.text(de.mealsNoRecipeJustText)), findsOneWidget);
    await enter(
      tester,
      inSheet(field(de.mealsWhatSDinner)),
      'E2E Pizza bestellen',
    );
    await tap(
      tester,
      inSheet(find.widgetWithText(ChoiceChip, MealSlot.lunch.label)),
    );
    expect(inSheet(find.text(de.mealsServings)), findsNothing);
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, inDay(wednesday, find.text('E2E Pizza bestellen')));
    expect(inDay(wednesday, find.text(MealSlot.lunch.label)), findsOneWidget);
    // A tap opens the editor.
    await tap(tester, inDay(wednesday, find.text('E2E Pizza bestellen')));
    await waitFor(tester, inSheet(find.text(de.commonRemove)));
    expect(
      textOf(tester, inSheet(find.byType(TextField))),
      'E2E Pizza bestellen',
    );
    await closeSheet(tester);
    final before = engine.plannedMeals(monday, next).length;
    await tap(tester, inDay(friday, find.byTooltip(de.mealsPlanMeal)));
    await waitFor(tester, inSheet(find.text(de.mealsPlanMeal)));
    await tap(tester, inSheet(find.text(de.commonSave)));
    await idle(tester, const Duration(seconds: 1));
    expect(
      inSheet(find.text(de.mealsPlanMeal)),
      findsOneWidget,
      reason: 'stays open',
    );
    expect(engine.plannedMeals(monday, next), hasLength(before));
    await closeSheet(tester);

    // HAU-036: moved to Thursday, removed and brought back.
    await tap(tester, inDay(wednesday, find.byTooltip(de.commonChange)));
    await waitFor(tester, inSheet(find.byType(InputChip)));
    await tap(tester, inSheet(find.byType(InputChip)));
    await pickDate(tester, thursday);
    await waitFor(tester, inSheet(find.text(dayLabel(thursday))));
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, inDay(thursday, find.text('E2E Pizza bestellen')));
    expect(inDay(wednesday, find.text('E2E Pizza bestellen')), findsNothing);
    await tap(tester, inDay(thursday, find.byTooltip(de.commonChange)));
    await tap(tester, inSheet(find.text(de.commonRemove)));
    await sheetClosed(tester);
    await waitGone(tester, inDay(thursday, find.text('E2E Pizza bestellen')));
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Pizza bestellen')));
    await undo(tester);
    await waitFor(tester, inDay(thursday, find.text('E2E Pizza bestellen')));
    // Hint: a meal with a recipe says only "Gelöscht".
    await snackGone(tester);
    await tap(tester, inDay(tuesday, find.byTooltip(de.commonChange)));
    await tap(tester, inSheet(find.text(de.commonRemove)));
    await sheetClosed(tester);
    await waitFor(tester, find.byType(SnackBar));
    expect(snackText(de.undoDeleted), findsOneWidget, reason: 'hint');
    await undo(tester);
    await waitFor(tester, inDay(tuesday, find.text('E2E Lasagne')));

    // HAU-037: from the recipe page, for six, today.
    await tab(tester, de.mealsRecipes);
    await tap(tester, find.text('E2E Lasagne'));
    await waitFor(tester, find.byType(RecipeScreen));
    await tap(tester, inRecipe(find.byTooltip(de.navMore)));
    await tap(tester, inRecipe(find.byTooltip(de.navMore)));
    expect(servingsShown(tester), '6');
    await tap(tester, find.text(de.mealsSchedule));
    await waitFor(tester, inSheet(find.text(de.mealsPlanMeal)));
    expect(inSheet(find.text(dayLabel(now))), findsOneWidget);
    expect(inSheet(find.text('E2E Lasagne')), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(inSheet(find.widgetWithText(ChoiceChip, '6')))
          .selected,
      isTrue,
    );
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    expect(
      engine
          .plannedMeals(now, DateUtils.addDaysToDate(now, 1))
          .where((m) => m.recipeId == lasagne && m.servings == 6),
      hasLength(1),
    );
    await back(tester);
    await tab(tester, de.mealsWeekPlan);
    await waitFor(tester, inDay(now, find.text('E2E Lasagne')));

    // HAU-038: at most a year ahead.
    await tap(tester, inDay(friday, find.byTooltip(de.mealsPlanMeal)));
    await tap(tester, inSheet(find.byType(InputChip)));
    final t = today();
    expect(
      await typeDate(tester, DateTime(t.year + 1, t.month + 1, t.day)),
      isFalse,
      reason: '13 months ahead',
    );
    expect(
      await typeDate(tester, DateUtils.addDaysToDate(t, 365)),
      isTrue,
      reason: 'one year ahead',
    );
    await waitFor(
      tester,
      inSheet(find.text(dayLabel(DateUtils.addDaysToDate(t, 365)))),
    );
    await closeSheet(tester);
    await finish(tester, state);
  });

  testWidgets('HAU-040 HAU-043 HAU-042 suggestions for the week: adjusted, '
      'planned, what is missing, nothing left to suggest', (tester) async {
    await reset(_meals);
    final f = await theFamily();
    for (final (title, ingredients, fav) in [
      ('E2E Milchreis', ['1 l Milch'], true),
      ('E2E Rührei', ['4 Eier', '100 ml Milch'], false),
      ('E2E Omelett', ['3 Eier'], false),
      ('E2E Kuchen', ['200 g Mehl', '3 Eier'], false),
      ('E2E Spätzle', ['300 g Mehl', '2 Eier'], false),
      ('E2E Quiche', ['200 g Mehl', '4 Eier', '200 g Lauch'], false),
      ('E2E Nudeln', ['250 g Nudeln'], false),
      ('E2E Kürbissuppe', ['1 Kürbis'], false),
      ('E2E Salat', ['1 Kopfsalat'], false),
    ]) {
      await seedRecipe(title, ingredients: ingredients, favorite: fav);
    }
    await seedPantry('Mehl');
    await seedPantry('Milch');
    await seedList('E2E Wocheneinkauf');
    await seedList('E2E Drogerie');
    final monday = mondayOf(today());
    DateTime week(int n) => DateUtils.addDaysToDate(monday, 7 * n);
    // HAU-042: week +6 is planned through, all recipes were on in week +8.
    for (var d = 0; d < 7; d++) {
      for (final slot in [MealSlot.lunch, MealSlot.dinner]) {
        await seedMeal(
          DateUtils.addDaysToDate(week(6), d),
          slot,
          title: 'E2E Reste',
        );
      }
    }
    final state = await start(tester);
    final engine = state.engine!;
    final all = engine.recipes;
    expect(all, hasLength(9));
    for (final (i, r) in all.indexed) {
      await seedMeal(
        DateUtils.addDaysToDate(week(8), i ~/ 2),
        i.isEven ? MealSlot.lunch : MealSlot.dinner,
        recipeId: r.id,
      );
    }
    await arrives(
      tester,
      state,
      (e) => e.plannedMeals(week(8), week(9)).length == 9,
      'week +8 planned',
    );
    await openWeek(tester);
    await weeksAhead(tester, 1);
    await tap(tester, find.text(de.mealsSuggestWeek));
    await waitFor(tester, find.byType(MealSuggestScreen));
    final apply = find.byWidgetPredicate(
      (w) => w is ColorButton && w.label.endsWith(' einplanen'),
    );
    String applyLabel() => tester.widget<ColorButton>(apply).label;

    // HAU-040: seven days, the favourite first.
    expect(suggested(tester), hasLength(7));
    expect(applyLabel(), de.mealsSuggestApply(7));
    expect(suggested(tester).first, 'E2E Milchreis');
    expect(
      tester
          .widget<ChoiceChip>(
            find.widgetWithText(ChoiceChip, MealSlot.dinner.label),
          )
          .selected,
      isTrue,
    );
    await tap(tester, find.widgetWithText(ChoiceChip, MealSlot.lunch.label));
    expect(
      tester
          .widget<ChoiceChip>(
            find.widgetWithText(ChoiceChip, MealSlot.lunch.label),
          )
          .selected,
      isTrue,
    );
    // Other suggestions mix the rest.
    final first = suggested(tester);
    var mixed = false;
    for (var i = 0; i < 8 && !mixed; i++) {
      await tap(tester, find.text(de.mealsSuggestOther));
      mixed = !listEquals(suggested(tester), first);
    }
    expect(mixed, isTrue, reason: 'other suggestions');
    expect(suggested(tester).first, 'E2E Milchreis');
    expect(suggested(tester).toSet(), hasLength(7));
    // Another recipe for day 3: one that is on no other day.
    final shown = suggested(tester);
    await tap(
      tester,
      find.descendant(
        of: suggestionCard(2),
        matching: find.byTooltip(de.mealsSuggestSwap),
      ),
    );
    final swapped = suggested(tester);
    expect(swapped[2], isNot(shown[2]));
    expect(shown, isNot(contains(swapped[2])));
    expect(swapped.toSet(), hasLength(7));
    // Day 4 left out, and filled again.
    await tap(
      tester,
      find.descendant(
        of: suggestionCard(3),
        matching: find.byTooltip(de.mealsSuggestLeaveOut),
      ),
    );
    expect(suggested(tester)[3], isNull);
    expect(
      find.descendant(
        of: suggestionCard(3),
        matching: find.text(de.mealsSuggestLeftOut),
      ),
      findsOneWidget,
    );
    expect(applyLabel(), de.mealsSuggestApply(6));
    await tap(
      tester,
      find.descendant(
        of: suggestionCard(3),
        matching: find.byTooltip(de.mealsSuggestAdd),
      ),
    );
    expect(suggested(tester)[3], isNotNull);
    expect(applyLabel(), de.mealsSuggestApply(7));

    // HAU-043: only the favourite, which the pantry covers: no button.
    for (var d = 1; d < 7; d++) {
      await tap(
        tester,
        find.descendant(
          of: suggestionCard(d),
          matching: find.byTooltip(de.mealsSuggestLeaveOut),
        ),
      );
    }
    expect(applyLabel(), de.mealsSuggestApply(1));
    await tap(tester, apply);
    await waitGone(tester, find.byType(MealSuggestScreen));
    await waitFor(tester, snackText(de.mealsSuggestPlanned(1)));
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.byType(SnackBarAction),
      ),
      findsNothing,
    );
    final planned = engine.plannedMeals(week(1), week(2));
    expect(planned.map((m) => (m.slot, engine.recipe(m.recipeId)?.title)), [
      (MealSlot.lunch, 'E2E Milchreis'),
    ]);
    await snackGone(tester);

    // HAU-043: week +2, the same meal for all days, eggs are missing.
    await weeksAhead(tester, 1);
    await tap(tester, find.text(de.mealsSuggestWeek));
    await waitFor(tester, find.byType(MealSuggestScreen));
    expect(
      tester
          .widget<ChoiceChip>(
            find.widgetWithText(ChoiceChip, MealSlot.lunch.label),
          )
          .selected,
      isTrue,
      reason: 'the slot the family plans most',
    );
    expect(suggested(tester), isNot(contains('E2E Milchreis')));
    expect(applyLabel(), de.mealsSuggestApply(7));
    await tap(tester, apply);
    await waitGone(tester, find.byType(MealSuggestScreen));
    await waitFor(tester, snackText(de.mealsSuggestPlanned(7)));
    final second = engine.plannedMeals(week(2), week(3));
    expect(second, hasLength(7));
    expect(second.map((m) => m.slot).toSet(), {MealSlot.lunch});
    expect(second.map((m) => m.recipeId).toSet(), hasLength(7));
    final missing = {
      for (final m in second)
        for (final i in engine.recipe(m.recipeId)!.ingredients)
          if (!const {'Mehl', 'Milch'}.contains(i.name)) i.name,
    };
    await tap(
      tester,
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(de.mealsSuggestShopMissing),
      ),
    );
    await chooseList(tester, 'E2E Wocheneinkauf');
    final list = engine.shoppingLists.singleWhere(
      (l) => l.name == 'E2E Wocheneinkauf',
    );
    await until(
      tester,
      () => engine.shoppingItems(list.id).isNotEmpty,
      'on the list',
    );
    final onList = {for (final i in engine.shoppingItems(list.id)) i.name};
    expect(onList, missing);
    expect(onList, contains('Eier'));
    expect(onList, isNot(contains('Mehl')));
    await snackGone(tester);

    // HAU-042, case 1: every day planned.
    await weeksAhead(tester, 4);
    await tap(tester, find.text(de.mealsSuggestWeek));
    await waitFor(tester, find.text(de.mealsSuggestAllPlanned));
    expect(isEnabled(tester, apply), isFalse);
    await back(tester);
    // Case 2: every recipe was on in the two weeks before.
    await weeksAhead(tester, 3);
    await tap(tester, find.text(de.mealsSuggestWeek));
    await waitFor(tester, find.text(de.mealsSuggestNoRecipes));
    expect(applyLabel(), de.mealsSuggestApply(0));
    expect(isEnabled(tester, apply), isFalse);
    await back(tester);
    // A week that is over has no suggestions.
    await weeksAhead(tester, -10);
    await waitFor(
      tester,
      find.text(
        '${DateFormat.MMMd('de').format(week(-1))} – '
        '${DateFormat.MMMd('de').format(DateUtils.addDaysToDate(week(-1), 6))}',
      ),
    );
    expect(find.text(de.mealsSuggestWeek), findsNothing);
    await weeksAhead(tester, 1);
    expect(find.text(de.mealsSuggestWeek), findsOneWidget);
    expect(f.adminMember.id, isNotEmpty);
    await finish(tester, state);
  });

  // =========================================================================
  // Ingredients to the shopping list
  // =========================================================================

  testWidgets('HAU-009 HAU-044 HAU-047 recipes and the pantry, ingredients '
      'to the shopping list', (tester) async {
    await reset(_meals);
    final f = await theFamily();
    await seedRecipe(
      'E2E Pfannkuchen',
      ingredients: ['250 g Mehl', '3 Eier', '500 ml Milch'],
    );
    await seedRecipe(
      'E2E Bohneneintopf',
      ingredients: ['500 g Rindfleisch', '2 Paprika', '3 Zwiebeln'],
    );
    final state = await start(tester);
    final engine = state.engine!;
    await openRecipes(tester);
    await waitFor(tester, find.text('E2E Pfannkuchen'));

    // HAU-009 without a pantry: the number of ingredients, by name.
    expect(
      recipeSubtitle(tester, 'E2E Pfannkuchen'),
      de.mealsCountIngredients(3),
    );
    expect(
      recipeSubtitle(tester, 'E2E Bohneneintopf'),
      de.mealsCountIngredients(3),
    );
    expect(
      top(tester, find.text('E2E Bohneneintopf')),
      lessThan(top(tester, find.text('E2E Pfannkuchen'))),
    );

    // HAU-044: no list yet: "Einkauf" without a question.
    await tap(tester, find.text('E2E Pfannkuchen'));
    await waitFor(tester, find.byType(RecipeScreen));
    final fewer = inRecipe(find.byTooltip(de.mealsFewer));
    await tap(tester, fewer);
    await tap(tester, fewer);
    expect(servingsShown(tester), '2');
    await tap(tester, find.text(de.mealsShoppingList));
    await waitFor(tester, find.byType(SnackBar));
    expect(find.text(de.commonWhichList), findsNothing);
    expect(
      snackText(de.mealsCountIngredientsListAdded(3, de.sectionShopping, '')),
      findsOneWidget,
    );
    Map<String, String> items(String listName) {
      final list = engine.shoppingLists.singleWhere((l) => l.name == listName);
      return {
        for (final i in engine.shoppingItems(list.id)) i.name: i.quantity,
      };
    }

    expect(items(de.sectionShopping), {
      'Mehl': '125 g',
      'Eier': '1,5',
      'Milch': '250 ml',
    });
    // One list: no question either.
    await snackGone(tester);
    await tap(tester, find.text(de.mealsShoppingList));
    await waitFor(tester, find.byType(SnackBar));
    expect(find.text(de.commonWhichList), findsNothing);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('auf „${de.sectionShopping}“'),
      ),
      findsOneWidget,
    );
    await snackGone(tester);
    // Two lists: which one?
    await remove(f.admin, Collections.shoppingLists, [
      engine.shoppingLists.single.id,
    ]);
    final weekly = await seedList('E2E Wocheneinkauf');
    await seedList('E2E Drogerie');
    await arrives(
      tester,
      state,
      (e) =>
          e.shoppingLists.map((l) => l.name).toSet().containsAll({
            'E2E Wocheneinkauf',
            'E2E Drogerie',
          }) &&
          e.shoppingLists.length == 2,
      'two lists',
    );
    await tap(tester, find.text(de.mealsShoppingList));
    await chooseList(tester, 'E2E Wocheneinkauf');
    await waitFor(
      tester,
      snackText(de.mealsCountIngredientsListAdded(3, 'E2E Wocheneinkauf', '')),
    );
    expect(items('E2E Wocheneinkauf'), {
      'Mehl': '125 g',
      'Eier': '1,5',
      'Milch': '250 ml',
    });
    expect(items('E2E Drogerie'), isEmpty);
    await snackGone(tester);
    await back(tester);

    // HAU-009 with a pantry: what it covers first.
    final pantry = [
      await seedPantry('Mehl'),
      await seedPantry('Eier', amount: 6),
      await seedPantry('Milch'),
    ];
    await arrives(tester, state, (e) => e.pantryItems.length == 3, 'pantry');
    await until(
      tester,
      () => find.text(de.mealsEverythingPantry).evaluate().isNotEmpty,
      'shown with the pantry',
    );
    expect(recipeSubtitle(tester, 'E2E Pfannkuchen'), de.mealsEverythingPantry);
    expect(
      recipeSubtitle(tester, 'E2E Bohneneintopf'),
      de.mealsHaveTotalPantry(0, 3),
    );
    expect(
      top(tester, find.text('E2E Pfannkuchen')),
      lessThan(top(tester, find.text('E2E Bohneneintopf'))),
    );

    // HAU-047: eggs missing.
    await remove(f.admin, Collections.pantryItems, [pantry[1]]);
    await arrives(tester, state, (e) => e.pantryItems.length == 2, 'no eggs');
    final cart = [for (final i in engine.shoppingItems(weekly)) i.id];
    await remove(f.admin, Collections.shoppingItems, cart);
    await arrives(
      tester,
      state,
      (e) => e.shoppingItems(weekly).isEmpty,
      'an empty list',
    );
    await tap(tester, find.text('E2E Pfannkuchen'));
    await waitFor(tester, find.byType(RecipeScreen));
    Finder ingredientRow(String name) => find.ancestor(
      of: inRecipe(find.text(name)),
      matching: find.byType(Row),
    );
    for (final (name, have) in [
      ('Mehl', true),
      ('Milch', true),
      ('Eier', false),
    ]) {
      expect(
        find.descendant(
          of: ingredientRow(name).first,
          matching: find.byTooltip(de.mealsPantry),
        ),
        have ? findsOneWidget : findsNothing,
        reason: name,
      );
    }
    expect(find.text(de.mealsEverythingShoppingList), findsOneWidget);
    await tap(tester, find.text(de.mealsMissingItemsShoppingList));
    await chooseList(tester, 'E2E Wocheneinkauf');
    await waitFor(tester, find.byType(SnackBar));
    expect(items('E2E Wocheneinkauf').keys, ['Eier']);
    await snackGone(tester);
    // Everything there, or nothing of it: no "Fehlendes".
    await seedPantry('Eier', amount: 6);
    await arrives(tester, state, (e) => e.pantryItems.length == 3, 'all');
    await until(
      tester,
      () => find.text(de.mealsMissingItemsShoppingList).evaluate().isEmpty,
      'all in stock',
    );
    expect(find.text(de.mealsEverythingShoppingList), findsOneWidget);
    await remove(f.admin, Collections.pantryItems, [
      for (final p in engine.pantryItems) p.id,
    ]);
    await seedPantry('E2E Senf');
    await arrives(
      tester,
      state,
      (e) => e.pantryItems.map((p) => p.name).join() == 'E2E Senf',
      'none of it',
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(de.mealsMissingItemsShoppingList), findsNothing);
    expect(find.text(de.mealsEverythingShoppingList), findsOneWidget);
    await finish(tester, state);
  });

  // =========================================================================
  // Pantry
  // =========================================================================

  testWidgets('HAU-055 HAU-056 HAU-058 HAU-059 HAU-061 the pantry: card, '
      'new item, places, best before, removed', (tester) async {
    await reset(_meals);
    final state = await start(tester);
    final engine = state.engine!;
    final t = today();

    // HAU-055: the card while empty, and where it leads.
    await openSection(tester, de.sectionShopping);
    await waitFor(
      tester,
      find.descendant(
        of: find.byType(PantryCard),
        matching: find.text(de.pantryFridgePantryGlanceBarcode),
      ),
    );
    await tap(tester, find.byType(PantryCard));
    await waitFor(tester, find.byType(PantryScreen));
    await dismissTip(tester);
    expect(find.text(de.conflictsPantry), findsWidgets);
    expect(find.text(de.pantryWhatSStillThere), findsOneWidget);

    // HAU-056: without a name nothing; then a whole item.
    await tap(tester, find.byTooltip(de.pantryAddItem));
    await waitFor(tester, inSheet(find.text(de.pantryIntoPantry)));
    await enter(tester, inSheet(field(de.pantryBrandOptional)), 'E2E Hof');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await idle(tester, const Duration(seconds: 1));
    expect(inSheet(find.text(de.pantryIntoPantry)), findsOneWidget);
    expect(engine.pantryItems, isEmpty);
    await enter(tester, inSheet(field(de.shoppingItem)), 'E2E Joghurt');
    await enter(tester, inSheet(field(de.commonQuantity)), '2');
    await enter(tester, inSheet(field(de.pantryUnit)), 'Packungen');
    await enter(tester, inSheet(field(de.pantryLow)), '1');
    await tap(
      tester,
      inSheet(
        find.widgetWithText(ChoiceChip, '🧊 ${PantryPlace.fridge.label}'),
      ),
    );
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, find.text('E2E Joghurt'));
    expect(inTile('E2E Joghurt', find.text('🧊')), findsOneWidget);
    expect(inTile('E2E Joghurt', find.text('E2E Hof')), findsOneWidget);
    expect(inTile('E2E Joghurt', find.text('2 Packungen')), findsOneWidget);
    final joghurt = engine.pantryItems.single;
    expect(
      (
        joghurt.amount,
        joghurt.unit,
        joghurt.minAmount,
        joghurt.place,
        joghurt.brand,
      ),
      (2.0, 'Packungen', 1.0, PantryPlace.fridge, 'E2E Hof'),
    );

    // HAU-058: by place.
    await seedPantry('E2E Butter', place: PantryPlace.fridge);
    await seedPantry('E2E Spirelli', place: PantryPlace.pantry);
    await arrives(tester, state, (e) => e.pantryItems.length == 3, 'items');
    for (final (label, shown) in [
      (de.commonAll, {'E2E Joghurt', 'E2E Butter', 'E2E Spirelli'}),
      ('🧊 ${PantryPlace.fridge.label}', {'E2E Joghurt', 'E2E Butter'}),
      ('❄️ ${PantryPlace.freezer.label}', <String>{}),
      ('🥫 ${PantryPlace.pantry.label}', {'E2E Spirelli'}),
      ('📦 ${PantryPlace.other.label}', <String>{}),
    ]) {
      await tab(tester, label);
      for (final name in ['E2E Joghurt', 'E2E Butter', 'E2E Spirelli']) {
        expect(
          find.text(name),
          shown.contains(name) ? findsOneWidget : findsNothing,
          reason: '$label: $name',
        );
      }
    }
    await tab(tester, '🧊 ${PantryPlace.fridge.label}');
    await tap(tester, find.byTooltip(de.pantryAddItem));
    await waitFor(tester, inSheet(find.text(de.pantryIntoPantry)));
    expect(
      tester
          .widget<ChoiceChip>(
            inSheet(
              find.widgetWithText(ChoiceChip, '🧊 ${PantryPlace.fridge.label}'),
            ),
          )
          .selected,
      isTrue,
    );
    await closeSheet(tester);
    await tab(tester, de.commonAll);

    // HAU-059: what to use soon, by date.
    final dated = {
      'E2E Quark': -1,
      'E2E Sahne': 0,
      'E2E Milch': 1,
      'E2E Käse': 2,
      'E2E Salami': 10,
    };
    for (final MapEntry(key: name, value: days) in dated.entries) {
      await seedPantry(
        name,
        place: PantryPlace.fridge,
        bestBefore: DateUtils.addDaysToDate(t, days),
      );
    }
    await seedPantry('E2E Mehl', amount: 1, minAmount: 2);
    await arrives(tester, state, (e) => e.pantryItems.length == 9, 'dated');
    await waitFor(tester, find.text(de.pantryUseSoon));
    final ctx = tester.element(find.byType(PantryScreen));
    final danger = FamioColors.of(ctx).danger;
    for (final (name, label, red) in [
      ('E2E Quark', de.pantryExpired, true),
      ('E2E Sahne', de.pantryBestBeforeToday, true),
      ('E2E Milch', de.pantryBestBeforeTomorrow, true),
      (
        'E2E Käse',
        de.pantryBestBeforeDate(
          DateFormat.Md('de').format(DateUtils.addDaysToDate(t, 2)),
        ),
        false,
      ),
    ]) {
      final sub = inTile(name, find.text(label));
      expect(sub, findsOneWidget, reason: name);
      expect(
        tester.widget<Text>(sub).style?.color == danger,
        red,
        reason: '$name red',
      );
    }
    final order = [
      'E2E Quark',
      'E2E Sahne',
      'E2E Milch',
      'E2E Käse',
    ].map((n) => top(tester, find.text(n))).toList();
    expect(order, [...order]..sort());
    expect(top(tester, find.text(de.pantryUseSoon)), lessThan(order.first));
    final allHeading = find.descendant(
      of: find.byType(ListHeading),
      matching: find.text(de.commonAll),
    );
    expect(top(tester, allHeading), greaterThan(order.last));
    expect(
      top(tester, find.text('E2E Salami')),
      greaterThan(top(tester, allHeading)),
    );
    // The cross takes the date away.
    await tap(tester, find.text('E2E Käse'));
    await waitFor(tester, inSheet(find.text(de.pantryEditPantryItem)));
    final chip = inSheet(find.byType(InputChip));
    await tap(tester, chipCross(chip));
    await waitFor(tester, inSheet(find.text(de.pantryBestBefore)));
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await until(
      tester,
      () =>
          engine.pantryItems
              .firstWhere((p) => p.name == 'E2E Käse')
              .bestBefore ==
          null,
      'no date',
    );
    expect(
      top(tester, find.text('E2E Käse')),
      greaterThan(top(tester, allHeading)),
    );

    // HAU-061: removed, and back.
    await tap(tester, find.text('E2E Salami'));
    await tap(tester, inSheet(find.text(de.commonRemove)));
    await sheetClosed(tester);
    await waitGone(tester, find.text('E2E Salami'));
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Salami')));
    await undo(tester);
    await waitFor(tester, find.text('E2E Salami'));

    // HAU-055: the card counts, what runs low and what expires.
    await back(tester);
    await waitFor(tester, find.byType(PantryCard));
    expect(
      find.descendant(
        of: find.byType(PantryCard),
        matching: find.text(
          [
            de.pantryCountItems(9),
            de.pantryCountRunningLow(1),
            de.pantryCountExpiringSoon(3),
          ].join(' · '),
        ),
      ),
      findsOneWidget,
    );
    await finish(tester, state);
  });

  // =========================================================================
  // Into the household book
  // =========================================================================

  testWidgets('HAU-072 HAU-071 shopping into the budget: no amount, a '
      'photo of the receipt', (tester) async {
    await reset({..._meals, ..._budget});
    final f = await theFamily();
    final list = await seedList('E2E Samstag');
    await seed(f.admin, Collections.shoppingItems, {
      for (final name in ['Brot', 'Käse'])
        uid('item-$name'): ShoppingItem(
          id: 'x',
          listId: list,
          name: name,
          checked: true,
        ).toData(),
    });
    final picker = fakePicker();
    picker.picks
      ..add(
        await tempFile(
          'e2e-bon.png',
          await letterPng([
            'REWE',
            'Musterstraße 12',
            'BROT 2,49',
            'KAESE 4,48',
            'SUMME EUR 6,97',
            'Geg. BAR EUR 10,00',
            'Rückgeld EUR 3,03',
          ]),
        ),
      )
      ..add(
        await tempFile(
          'e2e-danke.png',
          await letterPng(['Vielen Dank', 'für Ihren Einkauf']),
        ),
      );
    final state = await start(tester);
    final engine = state.engine!;
    await openSection(tester, de.sectionShopping);
    await tap(tester, find.text('E2E Samstag'));
    await tap(tester, find.text(de.purchaseButton));
    await waitFor(tester, inDialog(find.text(de.purchaseTitle)));
    final amount = inDialog(field(de.purchaseAmount));

    // HAU-072: no amount, no booking.
    await tap(tester, inDialog(find.text(de.purchaseSave)));
    await waitFor(tester, inDialog(find.text(de.budgetPleaseEnterAmount)));
    expect(inDialog(find.text(de.purchaseTitle)), findsOneWidget);
    expect(engine.budgetEntries, isEmpty);

    // HAU-071: read from the photo: the sum, not cash or change.
    // Tapped without the kit's pause afterwards: reading is quick.
    await waitFor(tester, inDialog(find.byTooltip(de.purchaseScan)));
    await tester.tap(inDialog(find.byTooltip(de.purchaseScan)));
    var progress = false;
    final read = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(read) &&
        inDialog(find.text(de.purchaseScanned)).evaluate().isEmpty) {
      progress |= inDialog(
        find.byType(CircularProgressIndicator),
      ).evaluate().isNotEmpty;
      await tester.pump(const Duration(milliseconds: 16));
    }
    await waitFor(tester, inDialog(find.text(de.purchaseScanned)));
    expect(progress, isTrue, reason: 'a progress indicator meanwhile');
    expect(textOf(tester, amount), '6,97');
    expect(textOf(tester, inDialog(field(de.purchaseNote))), 'REWE');
    // A receipt without an amount.
    await tap(tester, inDialog(find.byTooltip(de.purchaseScan)));
    await waitFor(
      tester,
      inDialog(find.text(de.purchaseNotRead)),
      timeout: const Duration(seconds: 40),
    );
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    expect(engine.budgetEntries, isEmpty);
    await finish(tester, state);
  });

  // =========================================================================
  // Household book
  // =========================================================================

  testWidgets('HAU-073 HAU-077 the first booking, months', (tester) async {
    await reset(_budget);
    final state = await start(tester);
    final engine = state.engine!;
    final t = today();
    await openBudget(tester);
    await tap(tester, find.widgetWithText(ColorButton, de.budgetFirstBooking));
    await waitFor(tester, inSheet(find.text(de.budgetExpense)));
    expect(
      tester
          .widget<SegmentedButton<bool>>(
            inSheet(find.byType(SegmentedButton<bool>)),
          )
          .selected,
      {false},
    );
    await enter(tester, inSheet(field(de.commonAmount)), '42,50');
    await tap(tester, inSheet(find.widgetWithText(ChoiceChip, 'Freizeit')));
    await enter(tester, inSheet(field(de.budgetWhatOptional)), 'E2E Zoo');
    expect(
      tester
          .widget<ChoiceChip>(
            inSheet(find.widgetWithText(ChoiceChip, kitAdminName)),
          )
          .selected,
      isTrue,
    );
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, booking('E2E Zoo'));

    expect(textOf(tester, summaryValue(de.budgetIncome)), '0,00 €');
    expect(textOf(tester, summaryValue(de.budgetExpenses)), '42,50 €');
    expect(textOf(tester, summaryValue(de.homeBalance)), '−42,50 €');
    final ctx = tester.element(find.byType(BudgetScreen));
    expect(
      tester.widget<Text>(summaryValue(de.homeBalance)).style?.color,
      FamioColors.of(ctx).text(Theme.of(ctx).colorScheme.error),
      reason: 'red',
    );
    final bar = byTypeName('_CategoryBar');
    expect(
      find.descendant(of: bar, matching: find.text('Freizeit')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.text('42,50 € · 100 %')),
      findsOneWidget,
    );
    expect(
      top(tester, find.text(de.budgetExpensesCategory)),
      lessThan(top(tester, bar)),
    );
    expect(
      find.descendant(
        of: booking('E2E Zoo'),
        matching: find.text(
          'Freizeit · ${DateFormat.Md('de').format(t)} · $kitAdminName',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: booking('E2E Zoo'), matching: find.text('−42,50 €')),
      findsOneWidget,
    );
    final entry = engine.budgetEntries.single;
    expect(
      (entry.cents, entry.category, entry.income, entry.memberId),
      (4250, 'Freizeit', false, engine.memberId),
    );

    // HAU-077: other months.
    String month(int n) =>
        DateFormat.yMMMM('de').format(DateTime(t.year, t.month + n));
    await tap(tester, find.byTooltip(de.budgetPreviousMonth));
    await waitFor(tester, find.text(month(-1)));
    expect(find.text(de.budgetNoBookingsMonth), findsOneWidget);
    expect(textOf(tester, summaryValue(de.budgetExpenses)), '0,00 €');
    expect(booking('E2E Zoo'), findsNothing);
    await tap(tester, find.byTooltip(de.budgetNextMonth));
    await tap(tester, find.byTooltip(de.budgetNextMonth));
    await waitFor(tester, find.text(month(1)));
    expect(find.text(de.budgetNoBookingsMonth), findsOneWidget);
    await tap(tester, find.byTooltip(de.budgetPreviousMonth));
    await waitFor(tester, find.text(month(0)));
    expect(booking('E2E Zoo'), findsOneWidget);
    expect(textOf(tester, summaryValue(de.budgetExpenses)), '42,50 €');
    await finish(tester, state);
  });

  testWidgets('HAU-076 HAU-084 income, a booking changed, deleted and '
      'brought back', (tester) async {
    await reset(_budget);
    await seedBooking('E2E Zoo', 4250);
    final state = await start(tester);
    final engine = state.engine!;
    await openBudget(tester);
    await waitFor(tester, booking('E2E Zoo'));
    expect(textOf(tester, summaryValue(de.homeBalance)), '−42,50 €');

    // HAU-076: income and its categories.
    await tap(tester, find.byTooltip(de.budgetAddBooking));
    await waitFor(tester, inSheet(find.text(de.budgetIncome2)));
    await tap(tester, inSheet(find.text(de.budgetIncome2)));
    for (final c in incomeCategories) {
      expect(
        inSheet(find.widgetWithText(ChoiceChip, c)),
        findsOneWidget,
        reason: c,
      );
    }
    for (final c in ['Lebensmittel', 'Freizeit', 'Wohnen']) {
      expect(
        inSheet(find.widgetWithText(ChoiceChip, c)),
        findsNothing,
        reason: c,
      );
    }
    await tap(tester, inSheet(find.widgetWithText(ChoiceChip, 'Kindergeld')));
    await enter(tester, inSheet(field(de.commonAmount)), '250');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, booking('Kindergeld'));
    expect(textOf(tester, summaryValue(de.budgetIncome)), '250,00 €');
    expect(textOf(tester, summaryValue(de.homeBalance)), '207,50 €');
    final plus = find.descendant(
      of: booking('Kindergeld'),
      matching: find.text('+250,00 €'),
    );
    expect(plus, findsOneWidget);
    final ctx = tester.element(find.byType(BudgetScreen));
    final c = FamioColors.of(ctx);
    expect(
      tester.widget<Text>(plus).style?.color,
      c.text(c.strong(FamioSection.budget)),
    );
    expect(
      find.descendant(
        of: byTypeName('_CategoryBar'),
        matching: find.text('Kindergeld'),
      ),
      findsNothing,
    );

    // HAU-084: changed at once in the month.
    await tap(tester, booking('E2E Zoo'));
    await waitFor(tester, inSheet(find.text(de.commonDelete)));
    expect(textOf(tester, inSheet(field(de.commonAmount))), '42,50');
    await enter(tester, inSheet(field(de.commonAmount)), '50');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(
      tester,
      find.descendant(of: booking('E2E Zoo'), matching: find.text('−50,00 €')),
    );
    expect(textOf(tester, summaryValue(de.budgetExpenses)), '50,00 €');
    await tap(tester, booking('E2E Zoo'));
    await tap(tester, inSheet(find.text(de.commonDelete)));
    await sheetClosed(tester);
    await waitGone(tester, booking('E2E Zoo'));
    expect(textOf(tester, summaryValue(de.budgetExpenses)), '0,00 €');
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Zoo')));
    await undo(tester);
    await waitFor(tester, booking('E2E Zoo'));
    expect(textOf(tester, summaryValue(de.budgetExpenses)), '50,00 €');
    expect(
      engine.budgetEntries.firstWhere((e) => e.note == 'E2E Zoo').cents,
      5000,
    );
    await finish(tester, state);
  });

  testWidgets('HAU-078 HAU-079 monthly bookings, ended after this month', (
    tester,
  ) async {
    await reset(_budget);
    final t = today();
    final kita = await seedBooking(
      'E2E Kita',
      18000,
      category: 'Kinder',
      monthly: true,
      date: DateTime(t.year, t.month - 3, 1),
    );
    await seedBooking('E2E Zoo', 4250);
    final state = await start(tester);
    final engine = state.engine!;
    await openBudget(tester);
    await waitFor(tester, booking('E2E Kita'));
    Future<void> toMonth(int from, int to) async {
      for (var i = from; i != to; i += to > from ? 1 : -1) {
        await tap(
          tester,
          find.byTooltip(
            to > from ? de.budgetNextMonth : de.budgetPreviousMonth,
          ),
        );
      }
      await waitFor(
        tester,
        find.text(
          DateFormat.yMMMM('de').format(DateTime(t.year, t.month + to)),
        ),
      );
    }

    // HAU-078: rent from the 1st of last month.
    await tap(tester, find.byTooltip(de.budgetAddBooking));
    await waitFor(tester, inSheet(find.text(de.budgetExpense)));
    await enter(tester, inSheet(field(de.commonAmount)), '900');
    await tap(tester, inSheet(find.widgetWithText(ChoiceChip, 'Wohnen')));
    await enter(tester, inSheet(field(de.budgetWhatOptional)), 'E2E Miete');
    await tap(
      tester,
      inSheet(find.widgetWithText(FilterChip, de.budgetMonthly)),
    );
    final dateChip = inSheet(find.byType(InputChip));
    await until(
      tester,
      () => textOf(
        tester,
        find.descendant(of: dateChip, matching: find.byType(Text)),
      ).startsWith(de.budgetFrom),
      'Ab …',
    );
    await tap(tester, dateChip);
    final firstOfLast = DateTime(t.year, t.month - 1, 1);
    await pickDate(tester, firstOfLast);
    await waitFor(
      tester,
      inSheet(
        find.text(
          '${de.budgetFrom}${DateFormat.yMd('de').format(firstOfLast)}',
        ),
      ),
    );
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, booking('E2E Miete'));
    final rent = 'Wohnen · ${de.budgetMonthlyUntil('')} · $kitAdminName';
    expect(
      find.descendant(of: booking('E2E Miete'), matching: find.text(rent)),
      findsOneWidget,
    );
    await toMonth(0, -1);
    expect(booking('E2E Miete'), findsOneWidget);
    await toMonth(-1, -2);
    expect(booking('E2E Miete'), findsNothing);
    await toMonth(-2, 2);
    expect(booking('E2E Miete'), findsOneWidget);
    await toMonth(2, 0);

    // HAU-079: the Kita ends after this month.
    await tap(tester, booking('E2E Kita'));
    await tap(tester, inSheet(find.text(de.budgetEndAfterMonth)));
    await sheetClosed(tester);
    final until_ = de.budgetUntilDate(
      DateFormat.yM('de').format(DateTime(t.year, t.month + 1, 0)),
    );
    await waitFor(
      tester,
      find.descendant(
        of: booking('E2E Kita'),
        matching: find.text(
          'Kinder · ${de.budgetMonthlyUntil(until_)} · $kitAdminName',
        ),
      ),
    );
    final ended = BudgetEntry.fromRecord(
      engine.record(Collections.budgetEntries, kita)!,
    );
    expect(ended.until, DateTime(t.year, t.month + 1, 0));
    await toMonth(0, 1);
    expect(booking('E2E Kita'), findsNothing);
    await toMonth(1, -1);
    expect(booking('E2E Kita'), findsOneWidget);
    await toMonth(-1, -3);
    expect(booking('E2E Kita'), findsOneWidget);
    await toMonth(-3, 0);
    // Ended or once only: no such button.
    await tap(tester, booking('E2E Kita'));
    await waitFor(tester, inSheet(find.text(de.commonDelete)));
    expect(inSheet(find.text(de.budgetEndAfterMonth)), findsNothing);
    await closeSheet(tester);
    await tap(tester, booking('E2E Zoo'));
    await waitFor(tester, inSheet(find.text(de.commonDelete)));
    expect(inSheet(find.text(de.budgetEndAfterMonth)), findsNothing);
    await closeSheet(tester);
    await finish(tester, state);
  });

  // Eine eigene Kategorie aus dem Import (keine Standardkategorie) steht
  // im Editor zur Auswahl und bleibt beim Speichern erhalten (#488).
  testWidgets('HAU-086 an own category from the import stays', (tester) async {
    await reset(_budget);
    final id = await seedBooking(
      'E2E Futter',
      2999,
      category: 'E2E Hund',
      importId: 'e2e-import-1',
    );
    final state = await start(tester);
    final engine = state.engine!;
    await openBudget(tester);
    await waitFor(tester, booking('E2E Futter'));
    expect(
      find.descendant(
        of: booking('E2E Futter'),
        matching: find.textContaining('E2E Hund'),
      ),
      findsOneWidget,
    );
    await tap(tester, booking('E2E Futter'));
    await waitFor(tester, inSheet(find.text(de.commonDelete)));
    await enter(
      tester,
      inSheet(field(de.budgetWhatOptional)),
      'E2E Futter Nov',
    );
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, booking('E2E Futter Nov'));
    final entry = BudgetEntry.fromRecord(
      engine.record(Collections.budgetEntries, id)!,
    );
    expect(entry.category, 'E2E Hund');
    await finish(tester, state);
  });

  testWidgets('HAU-083 HAU-155 HAU-160 who sees the household book: all, '
      'only A, A and B; children and the service account', (tester) async {
    await reset(_budget);
    final f = await theFamily();
    final service = await serviceAccount();
    final bea = await sessionOf(f.bea);
    final kid = await sessionOf(f.kid);
    final ha = await sessionOf(service);
    addTearDown(() => restrictBudget(null));
    await seedBooking('E2E Einkauf A', 3000);
    await seedSubscription('E2E Stream', 999);
    Future<Set<String>> bookings(FamioApiClient api) async => {
      for (final r in (await pull(api, Collections.budgetEntries)).values)
        '${r.data['note']}',
    };
    Future<Set<String>> abos(FamioApiClient api) async => {
      for (final r in (await pull(api, Collections.subscriptions)).values)
        '${r.data['name']}',
    };

    // Open to all: the child sees the bookings and may add its own.
    expect(await bookings(kid), contains('E2E Einkauf A'));
    final kidEntry = uid('booking');
    final answer = await put(kid, Collections.budgetEntries, {
      kidEntry: BudgetEntry(
        id: kidEntry,
        date: today(),
        cents: 500,
        category: 'Freizeit',
        note: 'E2E Kind Eis',
        memberId: f.kid.id,
      ).toData(),
    });
    expect(answer.rejected.map((r) => r.id), isEmpty, reason: 'own booking');
    expect(await bookings(bea), containsAll(['E2E Einkauf A', 'E2E Kind Eis']));
    // HAU-160: open to all, the service account gets them like a member
    // (decided so: an open household book is the whole family's).
    final forService = await bookings(ha);
    debugPrint('E2E HAU-160 open budget, service account gets $forService');
    expect(forService, containsAll(['E2E Einkauf A', 'E2E Kind Eis']));

    final state = await start(tester);
    await openBudget(tester);
    await scrollTo(tester, find.text(de.budgetVisibleWholeFamilyRestrict));
    Future<void> audience(Set<String> names) async {
      await tap(tester, find.byTooltip(de.budgetWhoSeesLimits));
      await waitFor(tester, find.text(de.budgetWhoSeesBudget));
      for (final m in [kitAdminName, f.bea.displayName, f.kid.displayName]) {
        final chip = find.widgetWithText(FilterChip, m);
        if (tester.widget<FilterChip>(chip).selected != names.contains(m)) {
          await tap(tester, chip);
        }
      }
      await tap(tester, find.text(de.commonSave).last);
      await waitGone(tester, find.text(de.budgetWhoSeesBudget));
    }

    // HAU-083: only A.
    await audience({kitAdminName});
    await scrollTo(tester, find.text(de.budgetVisibleNames(kitAdminName)));
    await synced(tester, state);
    await eventually(
      tester,
      'Bea and the child lose bookings and subscriptions',
      () async =>
          (await bookings(bea)).isEmpty &&
          (await abos(bea)).isEmpty &&
          (await bookings(kid)).isEmpty &&
          (await abos(kid)).isEmpty,
    );
    // HAU-160: restricted, the service account gets none.
    expect(await bookings(ha), isEmpty);

    // HAU-155: A and B: still nothing for the child.
    await audience({kitAdminName, f.bea.displayName});
    await synced(tester, state);
    await eventually(
      tester,
      'Bea sees them again',
      () async =>
          (await bookings(bea)).containsAll(['E2E Einkauf A', 'E2E Kind Eis']),
    );
    expect(await bookings(kid), isEmpty);
    expect(await bookings(ha), isEmpty);

    // Hint: whoever restricts stays in it.
    await audience({f.bea.displayName});
    final kept = state.engine!.budgetSettings.memberIds;
    expect(kept.toSet(), {f.adminMember.id, f.bea.id});
    // Nobody chosen: the whole family.
    await audience({});
    await scrollTo(tester, find.text(de.budgetVisibleWholeFamilyRestrict));
    await synced(tester, state);
    await eventually(
      tester,
      'open again',
      () async => (await bookings(kid)).contains('E2E Einkauf A'),
    );
    await finish(tester, state);
  });

  // Wer nicht in der Zielgruppe ist, bekommt die Budget-Einstellungen nicht
  // und seine App legt Buchungen ohne Einschränkung an; der Server setzt die
  // Zielgruppe aus den Einstellungen (dazu den Schreibenden), die Buchung
  // erreicht das Kind nicht (#538).
  testWidgets('HAU-162 an adult outside the audience of the budget', (
    tester,
  ) async {
    await reset(_budget);
    final f = await theFamily();
    final kid = await sessionOf(f.kid);
    addTearDown(() => restrictBudget(null));
    await restrictBudget([f.adminMember.id]);
    await seedBooking('E2E Einkauf A', 3000, visibleTo: [f.adminMember.id]);
    final state = await start(tester, user: f.bea.username);
    await openBudget(tester);
    await waitFor(tester, find.text(de.budgetFirstBooking));
    expect(find.text('E2E Einkauf A'), findsNothing, reason: 'B sees none');
    await tap(tester, find.widgetWithText(ColorButton, de.budgetFirstBooking));
    await waitFor(tester, inSheet(find.text(de.budgetExpense)));
    await enter(tester, inSheet(field(de.commonAmount)), '12');
    await enter(tester, inSheet(field(de.budgetWhatOptional)), 'E2E Bea Kino');
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, booking('E2E Bea Kino'));
    await synced(tester, state);
    await eventually(
      tester,
      'on the server',
      () async => (await pull(
        f.admin,
        Collections.budgetEntries,
      )).values.any((r) => r.data['note'] == 'E2E Bea Kino'),
    );
    final forKid = {
      for (final r in (await pull(kid, Collections.budgetEntries)).values)
        '${r.data['note']}',
    };
    debugPrint('E2E HAU-162 the child gets $forKid');
    expect(forKid, isNot(contains('E2E Bea Kino')));
    await finish(tester, state);
  });

  // =========================================================================
  // Subscriptions
  // =========================================================================

  testWidgets('HAU-097 HAU-102 HAU-095 HAU-100 subscriptions: sorted, '
      'deleted, required fields, an own category', (tester) async {
    await reset(_budget);
    final t = today();
    await seedSubscription(
      'E2E Zeitung',
      1200,
      start: DateUtils.addDaysToDate(t, 5),
      category: 'Software',
    );
    await seedSubscription(
      'E2E Cloud',
      12000,
      start: DateUtils.addDaysToDate(t, 2),
      unit: SubscriptionUnit.years,
      category: 'Spiele',
    );
    await seedSubscription(
      'E2E Ab Musik',
      1500,
      start: DateUtils.addDaysToDate(t, 10),
      category: 'Zeitung',
    );
    final state = await start(tester);
    final engine = state.engine!;
    await openSubscriptions(tester);
    await waitFor(tester, find.text('E2E Ab Musik'));

    // HAU-097: the order of each sort.
    final names = ['E2E Zeitung', 'E2E Cloud', 'E2E Ab Musik'];
    List<String> order() => [...names]
      ..sort(
        (a, b) =>
            top(tester, find.text(a)).compareTo(top(tester, find.text(b))),
      );
    for (final (chip, expected) in [
      (de.subscriptionsSortNext, ['E2E Cloud', 'E2E Zeitung', 'E2E Ab Musik']),
      (de.commonName, ['E2E Ab Musik', 'E2E Cloud', 'E2E Zeitung']),
      (de.subscriptionsSortPrice, ['E2E Ab Musik', 'E2E Zeitung', 'E2E Cloud']),
      (de.commonCategory, ['E2E Zeitung', 'E2E Cloud', 'E2E Ab Musik']),
    ]) {
      await tap(tester, find.widgetWithText(ChoiceChip, chip));
      await tester.pump(const Duration(milliseconds: 400));
      expect(order(), expected, reason: chip);
    }
    expect(subscriptionCategoryLabel('Spiele'), isNotEmpty);

    // HAU-102: deleted, the sums go down; and back.
    final perMonth = find
        .descendant(
          of: find
              .ancestor(
                of: find.descendant(
                  of: byTypeName('_Summary'),
                  matching: find.text(de.subscriptionsPerMonth),
                ),
                matching: find.byType(Column),
              )
              .first,
          matching: find.byType(Text),
        )
        .first;
    expect(textOf(tester, perMonth), '37,00 €');
    await tap(tester, find.text('E2E Ab Musik'));
    await tap(tester, inSheet(find.text(de.commonDelete)));
    await sheetClosed(tester);
    await waitGone(tester, find.text('E2E Ab Musik'));
    expect(textOf(tester, perMonth), '22,00 €');
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Ab Musik')));
    await undo(tester);
    await waitFor(tester, find.text('E2E Ab Musik'));
    expect(textOf(tester, perMonth), '37,00 €');
    await snackGone(tester);

    // HAU-095: required fields, in a window as low as the app's default.
    tester.view.physicalSize =
        const Size(800, 600) * tester.view.devicePixelRatio;
    await tester.pump(const Duration(seconds: 1));
    final count = engine.subscriptions.length;
    await tap(tester, find.byTooltip(de.subscriptionsAdd));
    final name = inSheet(field(de.commonName));
    await waitFor(tester, name);
    bool visible(Finder f) {
      final r = tester.getRect(f.first);
      final s = tester.getRect(sheet().first);
      return r.top >= s.top - 1 && r.bottom <= s.bottom + 1;
    }

    Future<void> save() async {
      await scrollTo(
        tester,
        inSheet(find.text(de.commonSave)),
        at: tester.getCenter(sheet().first),
      );
      await tap(tester, inSheet(find.text(de.commonSave)));
      await idle(tester, const Duration(milliseconds: 800));
    }

    await save();
    await waitFor(tester, inSheet(find.text(de.subscriptionsEnterName)));
    expect(visible(name), isTrue, reason: 'scrolled to the name');
    await enter(tester, name, 'E2E Pflicht');
    await save();
    await waitFor(tester, inSheet(find.text(de.budgetPleaseEnterAmount)));
    expect(inSheet(find.text(de.subscriptionsEnterName)), findsNothing);
    expect(visible(inSheet(field(de.commonAmount))), isTrue);
    await enter(tester, inSheet(field(de.commonAmount)), '4,99');
    for (final every in ['0', '1000']) {
      await enter(tester, inSheet(field(de.subscriptionsEvery)), every);
      await save();
      await waitFor(tester, inSheet(find.text(de.subscriptionsEnterPeriod)));
      expect(
        visible(inSheet(field(de.subscriptionsEvery))),
        isTrue,
        reason: every,
      );
    }
    expect(engine.subscriptions, hasLength(count));
    await closeSheet(tester);
    tester.view.physicalSize =
        const Size(800, 1600) * tester.view.devicePixelRatio;
    await tester.pump(const Duration(seconds: 1));

    // HAU-100: an own category; empty is "Sonstiges"; offered next time.
    Future<void> addOwn(String title, String category) async {
      await tap(tester, find.byTooltip(de.subscriptionsAdd));
      await waitFor(tester, inSheet(field(de.commonName)));
      await enter(tester, inSheet(field(de.commonName)), title);
      await enter(tester, inSheet(field(de.commonAmount)), '5');
      await tap(
        tester,
        inSheet(find.widgetWithText(ChoiceChip, de.subscriptionsOwnCategory)),
      );
      await enter(
        tester,
        inSheet(find.widgetWithText(TextField, de.subscriptionsOwnCategory)),
        category,
      );
      await tap(tester, inSheet(find.text(de.commonSave)));
      await sheetClosed(tester);
      await waitFor(tester, find.text(title));
    }

    await addOwn('E2E Sportverein', 'E2E Verein');
    await addOwn('E2E Sonstwas', '');
    expect(
      engine.subscriptions
          .firstWhere((s) => s.name == 'E2E Sportverein')
          .category,
      'E2E Verein',
    );
    expect(
      engine.subscriptions.firstWhere((s) => s.name == 'E2E Sonstwas').category,
      'Sonstiges',
    );
    await tap(tester, find.byTooltip(de.subscriptionsAdd));
    await waitFor(tester, inSheet(field(de.commonName)));
    expect(
      inSheet(find.widgetWithText(ChoiceChip, 'E2E Verein')),
      findsOneWidget,
    );
    await closeSheet(tester);
    await finish(tester, state);
  });

  // Eine Adresse ohne Schema wird zu https://…; andere Links wie "mailto:"
  // werden erkannt und nicht als https://mailto:… geöffnet (#547).
  testWidgets('HAU-101 the link to manage a subscription', (tester) async {
    await reset(_budget);
    final launcher = fakeLauncher();
    await seedSubscription('E2E Zeitung', 1200);
    final state = await start(tester);
    await openSubscriptions(tester);
    await tap(tester, find.text('E2E Zeitung'));
    final link = inSheet(field(de.subscriptionsLink));
    await waitFor(tester, link);
    // Without a scheme: https.
    await enter(tester, link, 'beispiel.de/konto');
    await tap(tester, inSheet(find.byTooltip(de.subscriptionsOpenLink)));
    await until(tester, () => launcher.opened.isNotEmpty, 'opened');
    expect(launcher.opened, ['https://beispiel.de/konto']);
    expect(inSheet(find.text(de.subscriptionsLinkInvalid)), findsNothing);
    // mailto: not opened, a word at the field.
    await enter(tester, link, 'mailto:x@y');
    await tap(tester, inSheet(find.byTooltip(de.subscriptionsOpenLink)));
    await idle(tester, const Duration(seconds: 1));
    debugPrint('E2E HAU-101 opened: ${launcher.opened}');
    expect(launcher.opened, hasLength(1), reason: 'mailto opened');
    expect(inSheet(find.text(de.subscriptionsLinkInvalid)), findsOneWidget);
    await closeSheet(tester);
    await finish(tester, state);
  });

  testWidgets('HAU-104 subscriptions hidden for the whole family', (
    tester,
  ) async {
    await reset(_budget);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    addTearDown(
      () => f.admin.updateServerSettings({'hiddenModules': <String>[]}),
    );
    await seedSubscription(
      'E2E Streaming',
      1299,
      start: DateUtils.addDaysToDate(today(), 3),
    );
    final state = await start(tester);
    final engine = state.engine!;
    await openBudget(tester);
    await waitFor(tester, find.byType(SubscriptionsCard));
    List<String> reminders(bool on) => [
      for (final r in familyReminders(
        engine,
        from: DateTime.now(),
        to: DateTime.now().add(const Duration(days: 60)),
        subscriptions: on,
      ))
        if (r.key.startsWith('subscription:')) r.key,
    ];
    expect(reminders(true), isNotEmpty);
    expect(state.reminders?.subscriptions?.call() ?? true, isTrue);

    await editAreas(tester, () async {
      await tap(tester, areaSwitch(de.subscriptionsTitle));
    });
    await waitFor(
      tester,
      find.text(de.adminHiddenAreas(de.subscriptionsTitle)),
    );
    expect(
      (await bea.config())['hiddenModules'],
      contains(ServerSettings.subscriptionsModule),
    );
    await eventually(
      tester,
      'the app knows',
      () async =>
          state.hiddenModules.contains(ServerSettings.subscriptionsModule),
    );
    if (state.reminders case final r?) {
      expect(r.subscriptions!(), isFalse, reason: 'no more reminders');
    }
    await back(tester);
    await openBudget(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SubscriptionsCard), findsNothing);

    // On again: all there.
    await editAreas(tester, () async {
      await tap(tester, areaSwitch(de.subscriptionsTitle));
    });
    await eventually(
      tester,
      'shown again',
      () async =>
          !state.hiddenModules.contains(ServerSettings.subscriptionsModule),
    );
    await back(tester);
    await openBudget(tester);
    await waitFor(tester, find.byType(SubscriptionsCard));
    expect(
      find.descendant(
        of: find.byType(SubscriptionsCard),
        matching: find.text(de.subscriptionsCardSummary(1, '12,99 €')),
      ),
      findsOneWidget,
    );
    expect(state.reminders?.subscriptions?.call() ?? true, isTrue);
    await finish(tester, state);
  });

  // =========================================================================
  // Documents
  // =========================================================================

  testWidgets('HAU-106 a document from a file', (tester) async {
    await reset({Collections.documents});
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final picker = fakePicker();
    final pdf = await pdfBytes('Reisepass der Bundesrepublik');
    final file = await tempFile('Reisepass_Kind.pdf', pdf);
    final state = await start(tester);
    final engine = state.engine!;
    await openDocuments(tester);
    await addDocument(tester, picker, file);
    await waitFor(tester, find.text(de.docsNewDocument));
    expect(
      find.text('Reisepass_Kind.pdf'),
      findsOneWidget,
      reason: 'file name',
    );
    expect(textOf(tester, field(de.commonTitle)), 'Reisepass Kind');
    await tap(
      tester,
      find.widgetWithText(ChoiceChip, DocumentCategory.identity.label),
    );
    await tap(tester, find.widgetWithText(FilterChip, f.kid.displayName));
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.byType(DocumentEditor));
    await waitFor(tester, find.text('Reisepass Kind'));
    final doc = engine.documents.single;
    expect(doc.memberIds, [f.kid.id]);
    expect(doc.visibleTo, isNull);
    expect(doc.file?.size, pdf.length);
    expect(
      inTile(
        'Reisepass Kind',
        find.text(
          '${DocumentCategory.identity.label} · ${fileSizeLabel(pdf.length)}',
        ),
      ),
      findsOneWidget,
    );
    expect(
      inTile(
        'Reisepass Kind',
        find.byWidgetPredicate(
          (w) => w is MemberAvatar && w.member.id == f.kid.id,
        ),
      ),
      findsOneWidget,
    );
    await synced(tester, state);
    await eventually(
      tester,
      'Bea gets it',
      () async => (await titlesOf(
        bea,
        Collections.documents,
      )).contains('Reisepass Kind'),
    );
    expect(await bea.downloadFile(doc.file!.id), pdf);
    await finish(tester, state);
  });

  testWidgets('HAU-112 HAU-113 a document only for me, and for me and B', (
    tester,
  ) async {
    await reset({Collections.documents});
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final kid = await sessionOf(f.kid);
    final picker = fakePicker();
    final state = await start(tester);
    final engine = state.engine!;
    await openDocuments(tester);

    Future<FamilyDocument> add(
      String title, {
      required Future<void> Function() visibility,
    }) async {
      await addDocument(
        tester,
        picker,
        await tempFile(
          '$title.pdf'.replaceAll(' ', '_'),
          await pdfBytes(title),
        ),
      );
      await enter(tester, field(de.commonTitle), title);
      await visibility();
      await tap(tester, find.text(de.commonSave).last);
      await waitGone(tester, find.byType(DocumentEditor));
      await waitFor(tester, find.text(title));
      return engine.documents.firstWhere((d) => d.title == title);
    }

    // HAU-112: only me.
    final mine = await add(
      'E2E Tagebuch',
      visibility: () async {
        await scrollTo(tester, find.text(de.docsOnlyMe));
        await tap(tester, find.text(de.docsOnlyMe));
      },
    );
    expect(mine.visibleTo, [f.adminMember.id]);
    final lock = de.commonVisibleTo(kitAdminName);
    expect(inTile('E2E Tagebuch', find.byTooltip(lock)), findsOneWidget);
    await tap(tester, find.text('E2E Tagebuch'));
    await waitFor(tester, inSheet(find.text(lock)));
    await closeSheet(tester);
    await synced(tester, state);
    await eventually(
      tester,
      'on the server',
      () async => (await titlesOf(
        f.admin,
        Collections.documents,
      )).contains('E2E Tagebuch'),
    );
    expect(
      await titlesOf(bea, Collections.documents),
      isNot(contains('E2E Tagebuch')),
    );
    await expectLater(
      bea.downloadFile(mine.file!.id),
      throwsA(isA<ApiError>()),
    );

    // HAU-113: me and B.
    final ours = await add(
      'E2E Mietvertrag Kopie',
      visibility: () async {
        await scrollTo(tester, find.text(de.docsMe));
        await tap(tester, find.text(de.docsMe));
        await waitFor(
          tester,
          find.widgetWithText(FilterChip, f.bea.displayName),
        );
        await tap(
          tester,
          find.widgetWithText(FilterChip, f.bea.displayName).last,
        );
      },
    );
    expect(ours.visibleTo?.toSet(), {f.adminMember.id, f.bea.id});
    final tooltip = tester
        .widget<Tooltip>(
          find
              .descendant(
                of: tile('E2E Mietvertrag Kopie'),
                matching: find.byType(Tooltip),
              )
              .first,
        )
        .message!;
    expect(
      tooltip,
      anyOf(
        de.commonVisibleTo('$kitAdminName, ${f.bea.displayName}'),
        de.commonVisibleTo('${f.bea.displayName}, $kitAdminName'),
      ),
    );
    await synced(tester, state);
    await eventually(
      tester,
      'Bea gets it',
      () async => (await titlesOf(
        bea,
        Collections.documents,
      )).contains('E2E Mietvertrag Kopie'),
    );
    expect(await bea.downloadFile(ours.file!.id), isNotEmpty);
    expect(
      await titlesOf(kid, Collections.documents),
      isNot(contains('E2E Mietvertrag Kopie')),
    );
    await expectLater(
      kid.downloadFile(ours.file!.id),
      throwsA(isA<ApiError>()),
    );
    await finish(tester, state);
  });

  // Ein „Nur ich“-Dokument öffnet im Editor als „Nur ich“, nicht als
  // „Ich und …“ (#539).
  testWidgets('HAU-115 an only-me document opens as only me', (tester) async {
    await reset({Collections.documents});
    final f = await theFamily();
    await seedDocument('E2E Nur-ich-Dokument', visibleTo: [f.adminMember.id]);
    final state = await start(tester);
    final engine = state.engine!;
    await openDocuments(tester);
    await tap(tester, find.text('E2E Nur-ich-Dokument'));
    await tap(tester, inSheet(find.text(de.commonEdit)));
    await waitFor(tester, find.text(de.docsEditDocument));
    final group =
        tester.widget(
              find.byWidgetPredicate(
                (w) => w.runtimeType.toString().startsWith('RadioGroup<'),
              ),
            )
            as dynamic;
    final chosen = '${group.groupValue}';
    debugPrint('E2E HAU-115 opens as $chosen');
    // Hint: saving keeps who sees it either way.
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.docsEditDocument));
    expect(engine.documents.single.visibleTo, [f.adminMember.id]);
    expect(chosen, endsWith('.me'), reason: '"Nur ich" chosen');
    await finish(tester, state);
  });

  testWidgets('HAU-111 HAU-116 HAU-118 documents: filter and search, valid '
      'until, opened', (tester) async {
    await reset({Collections.documents});
    final f = await theFamily();
    final launcher = fakeLauncher();
    final photo = await f.admin.uploadFile(
      bytes: await pngBytes(color: const Color(0xFF2A9D6E)),
      name: 'pass.png',
      mime: 'image/png',
    );
    final pdf = await f.admin.uploadFile(
      bytes: await pdfBytes('Hausratversicherung'),
      name: 'police_hausrat.pdf',
      mime: 'application/pdf',
    );
    await seedDocument(
      'E2E Reisepass Mia',
      category: DocumentCategory.identity,
      file: photo,
      notes: 'Nummer C01X',
    );
    await seedDocument(
      'E2E Hausrat',
      category: DocumentCategory.insurance,
      file: pdf,
    );
    await seedDocument('E2E Kfz', category: DocumentCategory.insurance);
    final state = await start(tester);
    final engine = state.engine!;
    final t = today();
    await openDocuments(tester);
    await waitFor(tester, find.text('E2E Kfz'));
    const titles = ['E2E Reisepass Mia', 'E2E Hausrat', 'E2E Kfz'];
    void shows(Set<String> shown, String why) {
      for (final title in titles) {
        expect(
          find.text(title),
          shown.contains(title) ? findsOneWidget : findsNothing,
          reason: '$why: $title',
        );
      }
    }

    // HAU-111: tabs only for categories in use.
    expect(tabLabels(tester), [
      de.docsAllCount(3),
      DocumentCategory.identity.label,
      DocumentCategory.insurance.label,
    ]);
    await tab(tester, DocumentCategory.insurance.label);
    shows({'E2E Hausrat', 'E2E Kfz'}, 'insurance');
    await tab(tester, de.docsAllCount(3));
    shows(titles.toSet(), 'all');
    final search = find.byType(TextField).first;
    for (final (q, shown) in [
      ('c01x', {'E2E Reisepass Mia'}),
      ('POLICE_HAUS', {'E2E Hausrat'}),
      ('kfz', {'E2E Kfz'}),
    ]) {
      await enter(tester, search, q);
      await tester.pump(const Duration(milliseconds: 400));
      shows(shown, q);
    }
    await enter(tester, search, 'e2e-gibt-es-nicht');
    await waitFor(tester, find.text(de.commonNothingFound));
    shows({}, 'nothing');
    await enter(tester, search, '');
    await tester.pump(const Duration(milliseconds: 400));

    // HAU-116: valid until; red under 90 days, grey after, expired.
    Future<void> expires(String title, DateTime? date) async {
      await tap(tester, find.text(title));
      await tap(tester, inSheet(find.text(de.commonEdit)));
      await waitFor(tester, find.text(de.docsEditDocument));
      await scrollTo(tester, find.text(de.docsValidUntilOptional));
      final chip = find.byType(InputChip);
      if (date == null) {
        await tap(tester, chipCross(chip));
        await waitFor(tester, find.text(de.docsNoExpiryDate));
      } else {
        await tap(tester, chip);
        await pickDate(tester, date);
      }
      await tap(tester, find.text(de.commonSave).last);
      await waitGone(tester, find.text(de.docsEditDocument));
    }

    final ctx = tester.element(find.byType(DocumentsScreen));
    final errorBox = Theme.of(ctx).colorScheme.errorContainer;
    final grey = FamioColors.of(ctx).surfaceSoft;
    Color? boxOf(String text) =>
        (tester
                    .widget<Container>(
                      find
                          .ancestor(
                            of: find.text(text),
                            matching: find.byType(Container),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration?)
            ?.color;
    final soon = DateUtils.addDaysToDate(t, 60);
    final later = DateUtils.addDaysToDate(t, 200);
    final past = DateUtils.addDaysToDate(t, -1);
    String valid(DateTime d) =>
        '${de.docsValidUntil} ${DateFormat.yMd('de').format(d)}';
    await expires('E2E Reisepass Mia', soon);
    await waitFor(tester, find.text(valid(soon)));
    expect(boxOf(valid(soon)), errorBox);
    await expires('E2E Hausrat', later);
    await waitFor(tester, find.text(valid(later)));
    expect(boxOf(valid(later)), grey);
    await expires('E2E Kfz', past);
    final expired = '${de.docsExpired} ${DateFormat.yMd('de').format(past)}';
    await waitFor(tester, find.text(expired));
    await expires('E2E Kfz', null);
    await waitGone(tester, find.text(expired));
    expect(
      engine.documents.firstWhere((d) => d.title == 'E2E Kfz').expiresAt,
      isNull,
    );

    // HAU-118: the sheet; a picture in Famio, a PDF in the system's app.
    await tap(tester, find.text('E2E Reisepass Mia'));
    await waitFor(tester, inSheet(find.byType(CachedImage)));
    expect(inSheet(find.text('E2E Reisepass Mia')), findsOneWidget);
    expect(inSheet(find.text('Nummer C01X')), findsOneWidget);
    expect(inSheet(find.text(de.docsVisibleWholeFamily)), findsOneWidget);
    await tap(tester, inSheet(find.text(de.commonOpen)));
    await waitFor(tester, find.byType(PhotoViewer));
    expect(launcher.opened, isEmpty);
    await tap(tester, find.byTooltip(de.commonClose).last);
    await waitGone(tester, find.byType(PhotoViewer));
    if (sheet().evaluate().isNotEmpty) await closeSheet(tester);
    await tap(tester, find.text('E2E Hausrat'));
    await tap(tester, inSheet(find.text(de.commonOpen)));
    await until(tester, () => launcher.opened.isNotEmpty, 'handed on');
    expect(launcher.opened.single, startsWith('file://'));
    expect(launcher.opened.single, endsWith('.pdf'));
    expect(find.byType(PhotoViewer), findsNothing);
    if (sheet().evaluate().isNotEmpty) await closeSheet(tester);
    await finish(tester, state);
  });

  testWidgets('HAU-119 an edit keeps what another device changed', (
    tester,
  ) async {
    await reset({Collections.documents});
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final doc = await seedDocument(
      'E2E Hausordnung',
      category: DocumentCategory.home,
      notes: 'alt',
    );
    final state = await start(tester);
    final engine = state.engine!;
    await openDocuments(tester);
    await tap(tester, find.text('E2E Hausordnung'));
    await tap(tester, inSheet(find.text(de.commonEdit)));
    await waitFor(tester, find.text(de.docsEditDocument));
    // Meanwhile B writes a note on another device.
    final r = await put(bea, Collections.documents, {
      doc.id: FamilyDocument(
        id: doc.id,
        title: doc.title,
        category: doc.category,
        file: null,
        notes: 'E2E Notiz von Bea',
        createdAt: doc.createdAt,
      ).toData(),
    });
    expect(r.rejected, isEmpty);
    await arrives(
      tester,
      state,
      (e) => e.documents.any(
        (d) => d.id == doc.id && d.notes == 'E2E Notiz von Bea',
      ),
      'Bea\'s note on this device',
    );
    await enter(tester, field(de.commonTitle), 'E2E Hausordnung neu');
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.docsEditDocument));
    await synced(tester, state);
    Future<FamilyDocument?> asSeenBy(FamioApiClient api) async {
      final r = (await pull(api, Collections.documents))[doc.id];
      return r == null ? null : FamilyDocument.fromRecord(r);
    }

    await eventually(tester, 'both on the server', () async {
      final d = await asSeenBy(bea);
      return d?.title == 'E2E Hausordnung neu';
    });
    for (final api in [bea, f.admin]) {
      final d = (await asSeenBy(api))!;
      expect((d.title, d.notes), ('E2E Hausordnung neu', 'E2E Notiz von Bea'));
    }
    expect(engine.documents.single.notes, 'E2E Notiz von Bea');
    await finish(tester, state);
  });

  testWidgets('HAU-120 a document deleted, back with "Rückgängig" and from '
      'the trash', (tester) async {
    await reset({Collections.documents});
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    final bytes = await pdfBytes('Mietvertrag');
    final file = await f.admin.uploadFile(
      bytes: bytes,
      name: 'mietvertrag.pdf',
      mime: 'application/pdf',
    );
    final doc = await seedDocument(
      'E2E Mietvertrag',
      category: DocumentCategory.contracts,
      file: file,
    );
    final state = await start(tester);
    await openDocuments(tester);
    Future<void> deleteIt() async {
      await tap(tester, find.text('E2E Mietvertrag'));
      await tap(tester, inSheet(find.text(de.commonDelete)));
      await waitFor(
        tester,
        inDialog(find.text(de.commonDeleteName('E2E Mietvertrag'))),
      );
      expect(
        inDialog(find.text(de.docsDocumentRemovedEveryone)),
        findsOneWidget,
      );
      await tap(tester, inDialog(find.text(de.commonDelete)));
      await dialogClosed(tester);
      await sheetClosed(tester);
      await waitGone(tester, find.text('E2E Mietvertrag'));
    }

    Future<bool> beaHasIt() async => (await titlesOf(
      bea,
      Collections.documents,
    )).contains('E2E Mietvertrag');

    await deleteIt();
    await waitFor(tester, snackText(de.undoWhatDeleted('E2E Mietvertrag')));
    await synced(tester, state);
    await eventually(tester, 'gone for Bea', () async => !await beaHasIt());
    await undo(tester);
    await waitFor(tester, find.text('E2E Mietvertrag'));
    await synced(tester, state);
    await eventually(tester, 'back for Bea', beaHasIt);
    expect(await bea.downloadFile(file.id), bytes);

    // Later: from the trash.
    await snackGone(tester);
    await deleteIt();
    await snackGone(tester);
    await synced(tester, state);
    await eventually(tester, 'gone again', () async => !await beaHasIt());
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.trashTitle));
    await tap(tester, find.text(de.trashTitle));
    await waitFor(tester, find.text('E2E Mietvertrag'));
    await tap(
      tester,
      find.descendant(
        of: find
            .ancestor(
              of: find.text('E2E Mietvertrag'),
              matching: find.byType(SoftCard),
            )
            .first,
        matching: find.text(de.trashRestore),
      ),
    );
    await waitFor(tester, find.text(de.trashRestored));
    await arrives(
      tester,
      state,
      (e) => e.documents.any((d) => d.id == doc.id),
      'restored on this device',
    );
    expect(state.engine!.documents.single.file?.id, file.id);
    await eventually(tester, 'restored for Bea', beaHasIt);
    expect(await bea.downloadFile(file.id), bytes);
    await finish(tester, state);
  });

  testWidgets('HAU-122 the upload fails while the server is gone', (
    tester,
  ) async {
    await reset({Collections.documents});
    final f = await theFamily();
    final relay = _Relay(kitUrl);
    await relay.start();
    final picker = fakePicker();
    final file = await tempFile('e2e-zeugnis.pdf', await pdfBytes('Zeugnis'));
    final state = await startAt(tester, relay.url);
    final engine = state.engine!;
    await openDocuments(tester);
    await addDocument(tester, picker, file);
    await waitFor(tester, find.text(de.docsNewDocument));
    await enter(tester, field(de.commonTitle), 'E2E Zeugnis');
    // The server stops.
    await relay.stop();
    await tap(tester, find.text(de.commonSave).last);
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
    debugPrint('E2E HAU-122 message: $message');
    expect(message.trim(), isNotEmpty);
    // The editor stays, "Speichern" works again, no document.
    expect(find.byType(DocumentEditor), findsOneWidget);
    expect(textOf(tester, field(de.commonTitle)), 'E2E Zeugnis');
    final saveButton = find.widgetWithText(ColorButton, de.commonSave);
    await waitFor(tester, saveButton);
    expect(isEnabled(tester, saveButton), isTrue);
    expect(engine.documents.where((d) => d.title == 'E2E Zeugnis'), isEmpty);
    expect(
      await titlesOf(f.admin, Collections.documents),
      isNot(contains('E2E Zeugnis')),
    );
    await finish(tester, state);
  });

  // Der Server lehnt neue Gesundheitsdaten eines Kindes ohne es selbst in
  // visibleTo ab; die App bietet Kindern bei „Gesundheit“ deshalb „Ganze
  // Familie“ nicht an und sagt es (#539).
  testWidgets('HAU-157 a child files a health document for the family', (
    tester,
  ) async {
    await reset({Collections.documents});
    final f = await theFamily();
    final picker = fakePicker();
    final file = await tempFile('e2e-befund.pdf', await pdfBytes('Befund'));
    final state = await start(tester, user: f.kid.username);
    final engine = state.engine!;
    await openDocuments(tester);
    await addDocument(tester, picker, file);
    await enter(tester, field(de.commonTitle), 'E2E Befund Kind');
    await tap(
      tester,
      find.widgetWithText(ChoiceChip, DocumentCategory.health.label),
    );
    await scrollTo(tester, find.text(de.commonWholeFamily));
    expect(find.text(de.docsChildHealthAudience), findsOneWidget);
    // Off: the tap changes nothing.
    await tap(tester, find.text(de.commonWholeFamily));
    // Saved on the device; it may go with the very next sync, so the tap
    // is without the kit's pause and the device is looked at often.
    await tester.tap(find.text(de.commonSave).last);
    var seen = false;
    final saved = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(saved) &&
        find.byType(DocumentEditor).evaluate().isNotEmpty) {
      seen |= engine.documents.any((d) => d.title == 'E2E Befund Kind');
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 20; i++) {
      seen |= engine.documents.any((d) => d.title == 'E2E Befund Kind');
      await tester.pump(const Duration(milliseconds: 16));
    }
    // The editor closes only after the document was saved.
    expect(find.byType(DocumentEditor), findsNothing, reason: 'saved');
    debugPrint('E2E HAU-157 seen on the device: $seen');
    for (var i = 0; i < 3; i++) {
      await synced(tester, state);
    }
    await idle(tester, const Duration(seconds: 2));
    final kept = engine.documents.any((d) => d.title == 'E2E Befund Kind');
    final told =
        find.byType(SnackBar).evaluate().isNotEmpty ||
        find.byType(AlertDialog).evaluate().isNotEmpty;
    debugPrint('E2E HAU-157 kept: $kept, told: $told');
    expect(kept || told, isTrue, reason: 'gone without a word');
    expect(
      engine.documents
          .singleWhere((d) => d.title == 'E2E Befund Kind')
          .visibleTo,
      contains(f.kid.id),
    );
    // "Ganze Familie" is not offered: it is the child's alone ("Nur ich"),
    // on the server too, and the adults do not get it.
    final server = await pull(await sessionOf(f.kid), Collections.documents);
    expect(
      server.values.where((r) => r.data['title'] == 'E2E Befund Kind'),
      hasLength(1),
    );
    final adults = await pull(f.admin, Collections.documents);
    expect(
      adults.values.where((r) => r.data['title'] == 'E2E Befund Kind'),
      isEmpty,
    );
    await finish(tester, state);
  });

  testWidgets('HAU-158 a child edits a family document', (tester) async {
    await reset({Collections.documents});
    final f = await theFamily();
    final doc = await seedDocument(
      'E2E Elternbrief',
      category: DocumentCategory.school,
      notes: 'Ausflug',
    );
    final state = await start(tester, user: f.kid.username);
    await openDocuments(tester);
    await tap(tester, find.text('E2E Elternbrief'));
    await tap(tester, inSheet(find.text(de.commonEdit)));
    await waitFor(tester, find.text(de.docsEditDocument));
    await scrollTo(tester, find.text(de.commonAudienceSetByAdults));
    expect(find.text(de.docsOnlyMe), findsNothing);
    expect(find.text(de.commonWholeFamily), findsNothing);
    await enter(
      tester,
      find
          .descendant(
            of: find.byType(DocumentEditor),
            matching: find.byType(TextField),
          )
          .last,
      'Ausflug – E2E Turnbeutel mit',
    );
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.docsEditDocument));
    await synced(tester, state);
    await eventually(tester, 'saved on the server', () async {
      final r = (await pull(f.admin, Collections.documents))[doc.id];
      return r != null && r.data['notes'] == 'Ausflug – E2E Turnbeutel mit';
    });
    final r = (await pull(f.admin, Collections.documents))[doc.id]!;
    expect(r.visibleTo, isNull, reason: 'still for the family');
    await finish(tester, state);
  });

  // =========================================================================
  // Rights
  // =========================================================================

  testWidgets('HAU-151 a guest reads recipes, week plan and pantry, but '
      'changes nothing', (tester) async {
    await reset(_meals);
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    await seedRecipe('E2E Gastsuppe', ingredients: ['1 l Brühe']);
    final now = today();
    await seedMeal(now, MealSlot.dinner, title: 'E2E Familienessen');
    await seedPantry('E2E Reis', amount: 2);
    final state = await start(tester, user: f.guest.username);

    // Reads.
    await openWeek(tester);
    await waitFor(tester, inDay(now, find.text('E2E Familienessen')));
    await tab(tester, de.mealsRecipes);
    await tap(tester, find.text('E2E Gastsuppe'));
    await waitFor(tester, find.byType(RecipeScreen));
    expect(inRecipe(find.text('Brühe')), findsOneWidget);
    // Changing the recipe, a favourite, planning it: not offered (#539).
    expect(find.byTooltip(de.commonEdit), findsNothing);
    expect(find.byTooltip(de.mealsFavorite), findsNothing);
    expect(find.text(de.mealsSchedule), findsNothing);
    await back(tester);

    // No recipe of its own: the server would undo it after the sync.
    expect(find.byTooltip(de.mealsAddRecipe), findsNothing);
    // No meal either.
    await tab(tester, de.mealsWeekPlan);
    expect(find.byTooltip(de.mealsPlanMeal), findsNothing);
    expect(find.text(de.mealsSuggestWeek), findsNothing);
    // The pantry: what is there, without counting.
    await openPantry(tester);
    await waitFor(tester, find.text('E2E Reis'));
    expect(find.byTooltip(de.pantryOneMore), findsNothing);
    expect(find.byTooltip(de.pantryOneLess), findsNothing);
    expect(find.byTooltip(de.pantryAddItem), findsNothing);
    // A guest's card opens nothing, so it is no tappable tile.
    await waitFor(
      tester,
      find.descendant(
        of: find.ancestor(
          of: find.text('E2E Reis'),
          matching: find.byType(SoftCard),
        ),
        matching: find.text('2'),
      ),
    );
    expect(tile('E2E Reis'), findsNothing);

    // The adults see none of it.
    expect(await titlesOf(bea, Collections.recipes), {'E2E Gastsuppe'});
    final meals = (await pull(bea, Collections.mealPlan)).values;
    expect(meals.map((r) => r.data['title']), ['E2E Familienessen']);
    final rice = (await pull(bea, Collections.pantryItems)).values.single;
    expect(PantryItem.fromRecord(rice).amount, 2);
    await finish(tester, state);
  });

  // =========================================================================
  // Year in review, memories
  // =========================================================================

  testWidgets('HAU-138 HAU-141 the year in review: which year, years back '
      'and forth', (tester) async {
    await reset({Collections.events});
    final f = await theFamily();
    final now = DateTime.now();
    final year = now.month == 12 ? now.year : now.year - 1;
    final id = uid('event');
    await seed(f.admin, Collections.events, {
      id: CalendarEvent(
        id: id,
        title: 'E2E Sommerfest $year',
        start: DateTime(year, 7, 4, 15),
        end: DateTime(year, 7, 4, 18),
      ).toData(),
    });
    final state = await start(tester);
    // HAU-138: no hint on the start page outside 15.12.–31.1.
    await openSection(tester, 'Start');
    await waitFor(tester, find.byType(HomeScreen));
    final banner = now.month == 1 || (now.month == 12 && now.day >= 15);
    expect(
      find.text(de.yearReviewHomeHint(year)),
      banner ? findsOneWidget : findsNothing,
    );
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.yearReviewMenu));
    await tap(tester, find.text(de.yearReviewMenu));
    await waitFor(tester, find.byType(YearReviewScreen));
    await waitFor(tester, find.text(de.yearReviewTitle(year)));
    expect(find.text(de.yearReviewNumbers), findsOneWidget);
    final pdf = iconButton(de.yearReviewPdf);
    final later = iconButton(de.yearReviewNext);
    expect(isEnabled(tester, pdf), isTrue);

    // HAU-141: an empty year, and the current one.
    for (var y = year - 1; y >= year - 5; y--) {
      await tap(tester, find.byTooltip(de.yearReviewPrevious));
      await waitFor(tester, find.text(de.yearReviewTitle(y)));
    }
    await waitFor(tester, find.text(de.yearReviewEmpty(year - 5)));
    expect(isEnabled(tester, pdf), isFalse);
    expect(isEnabled(tester, later), isTrue);
    for (var y = year - 4; y <= now.year; y++) {
      await tap(tester, find.byTooltip(de.yearReviewNext));
      await waitFor(tester, find.text(de.yearReviewTitle(y)));
    }
    expect(isEnabled(tester, later), isFalse);
    await finish(tester, state);
  });

  testWidgets('HAU-144 HAU-147 memories of several years; the tile hidden '
      'for the family', (tester) async {
    await reset({Collections.events, Collections.childEntries});
    final f = await theFamily();
    final bea = await sessionOf(f.bea);
    addTearDown(
      () => f.admin.updateServerSettings({'hiddenModules': <String>[]}),
    );
    final t = today();
    Future<void> trip(String title, int yearsAgo) async {
      final day = DateTime(t.year - yearsAgo, t.month, t.day);
      final id = uid('event');
      await seed(f.admin, Collections.events, {
        id: CalendarEvent(
          id: id,
          title: title,
          start: DateUtils.addDaysToDate(day, -1),
          end: DateUtils.addDaysToDate(day, 2),
          allDay: true,
        ).toData(),
      });
    }

    await trip('E2E Ostsee', 1);
    await trip('E2E Alpen', 3);
    final state = await start(tester);
    await openSection(tester, 'Start');
    Finder line(String text) =>
        find.ancestor(of: find.text(text), matching: byTypeName('_Line'));
    await scrollTo(tester, find.text('E2E Ostsee'));
    expect(find.text(de.memoriesTitleYears), findsOneWidget);
    expect(find.text(de.memoriesTitle), findsNothing);
    expect(
      find.descendant(
        of: line('E2E Ostsee'),
        matching: find.text(de.memoriesYearsAgo(1)),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: line('E2E Alpen'),
        matching: find.text(de.memoriesYearsAgo(3)),
      ),
      findsOneWidget,
    );

    // HAU-147: switched off in the server settings.
    await editAreas(tester, () async {
      await tap(tester, areaSwitch(de.memoriesTitleYears));
    });
    await waitFor(
      tester,
      find.text(de.adminHiddenAreas(de.memoriesTitleYears)),
    );
    expect(
      (await bea.config())['hiddenModules'],
      contains(HomeTile.memories.module),
    );
    await back(tester);
    await openSection(tester, 'Start');
    await waitFor(tester, find.byType(HomeScreen));
    await waitGone(tester, find.text('E2E Ostsee'));
    expect(find.text(de.memoriesTitleYears), findsNothing);
    expect(find.text('E2E Alpen'), findsNothing);
    await finish(tester, state);
  });

  // War ein Befund: Die Kachel „Heute vor einem Jahr“/„An diesem Tag“
  // zeigte den Titel vertraulicher Reisen. Jetzt lässt sie sie weg wie der
  // Jahresrückblick.
  testWidgets('HAU-149 a confidential trip among the memories', (tester) async {
    await reset({Collections.events, Collections.childEntries});
    final f = await theFamily();
    final t = today();
    final day = DateTime(t.year - 1, t.month, t.day);
    final id = uid('event');
    await seed(f.admin, Collections.events, {
      id: CalendarEvent(
        id: id,
        title: 'E2E Geheimreise',
        start: DateUtils.addDaysToDate(day, -1),
        end: DateUtils.addDaysToDate(day, 2),
        allDay: true,
        confidential: true,
      ).toData(),
    });
    final state = await start(tester);
    // As in the year in review: left out.
    await openSection(tester, 'Einstellungen');
    await scrollTo(tester, find.text(de.yearReviewMenu));
    await tap(tester, find.text(de.yearReviewMenu));
    await waitFor(tester, find.byType(YearReviewScreen));
    var y = DateTime.now().month == 12 ? t.year : t.year - 1;
    while (y > day.year) {
      await tap(tester, find.byTooltip(de.yearReviewPrevious));
      y--;
    }
    await waitFor(tester, find.text(de.yearReviewTitle(day.year)));
    expect(
      find.text('E2E Geheimreise'),
      findsNothing,
      reason: 'year in review',
    );
    await back(tester);
    await openSection(tester, 'Start');
    await waitFor(tester, find.byType(HomeScreen));
    await tester.pump(const Duration(seconds: 2));
    debugPrint('E2E HAU-149 start page: ${onScreen()}');
    expect(find.text('E2E Geheimreise'), findsNothing, reason: 'memories');
    await finish(tester, state);
  });

  // =========================================================================
  // Nutrients
  // =========================================================================

  testWidgets('HAU-053 HAU-052 Open Food Facts out of reach; a link undone, '
      'the consent taken back', (tester) async {
    await reset(_meals);
    final f = await theFamily();
    final id = uid('recipe');
    await seed(f.admin, Collections.recipes, {
      id: const Recipe(
        id: 'x',
        title: 'E2E Haferbrei',
        servings: 2,
        ingredients: [
          Ingredient(
            name: 'Haferflocken',
            amount: 100,
            unit: 'g',
            nutrition: Nutrition(
              code: '4000000000001',
              product: 'E2E Haferflocken zart',
              kcal: 370,
              protein: 13,
              fat: 7,
              carbs: 59,
            ),
          ),
          Ingredient(name: 'Honig', amount: 20, unit: 'g'),
        ],
        steps: 'Alles aufkochen.',
      ).toData(),
    });
    final state = await start(tester);
    final engine = state.engine!;
    await openRecipe(tester, 'E2E Haferbrei');
    await tap(tester, find.text(de.mealsNutritionLink));
    await waitFor(tester, find.text(de.nutritionConsentTitle));
    await tap(tester, find.text(de.nutritionConsentAllow));
    await waitFor(tester, find.text(de.nutritionLinkTitle));
    expect(find.text(de.nutritionNotLinked), findsOneWidget);
    final linkPage = find.byType(NutritionLinkScreen);
    Finder row(String name) => find.ancestor(
      of: find.descendant(of: linkPage, matching: find.textContaining(name)),
      matching: find.byType(ListTile),
    );

    // HAU-053: no network for the search.
    HttpOverrides.global = _NoNetwork();
    addTearDown(() => HttpOverrides.global = null);
    await tap(
      tester,
      find.descendant(
        of: row('Honig').first,
        matching: find.byTooltip(de.commonSearch),
      ),
    );
    await waitFor(tester, inDialog(find.text(de.nutritionOffline)));
    HttpOverrides.global = null;
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    final honey = engine.recipe(id)!.ingredients.last;
    expect(honey.nutrition, isNull);
    expect(
      engine.recipe(id)!.ingredients.first.nutrition?.product,
      'E2E Haferflocken zart',
    );

    // HAU-052: the link undone.
    await tap(
      tester,
      find.descendant(
        of: row('Haferflocken').first,
        matching: find.byTooltip(de.nutritionUnlink),
      ),
    );
    await until(
      tester,
      () => find.text(de.nutritionNotLinked).evaluate().length == 2,
      'not linked',
    );
    expect(engine.recipe(id)!.ingredients.first.nutrition, isNull);
    // "nicht mehr fragen": the page closes, next time it asks again.
    await scrollTo(tester, find.text(de.nutritionStop));
    await tap(tester, find.text(de.nutritionStop));
    await waitGone(tester, linkPage);
    await waitFor(tester, find.byType(RecipeScreen));
    await tap(tester, find.text(de.mealsNutritionStart));
    await waitFor(tester, find.text(de.nutritionConsentTitle));
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    expect(linkPage, findsNothing);
    await finish(tester, state);
  });
}
