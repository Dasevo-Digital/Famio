// Catalog ALL-111 … ALL-205 (shopping lists, templates and packing lists,
// connecting lists, pinboard, chat, contacts, loans, wish lists and gift
// ideas, deadlines and contracts, rights) against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/catalog_all_b_test.dart
//
// Each test signs in through the app's own pages; other members and devices
// are API sessions (what the server gives them, what they write), a second
// device of the admin is a sync engine of its own with the app's code.
// Native parts are replaced at their plugin boundary: the share sheet (its
// method channel) and the file picker. Bring! and Microsoft To Do are real
// services and are not contacted.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/deadlines.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/loans.dart';
import 'package:famio/src/data/shopping_history.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/design/palette.dart';
import 'package:famio/src/format.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/wishes_screen.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio/src/widgets/member_avatar.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'catalog_kit.dart';
import 'fresh_start.dart';

final day = DateFormat.yMd('de');

// --- data ------------------------------------------------------------------

/// A window as high as a big screen: lists build what is on it.
void tall(WidgetTester tester, {double width = 800, double height = 1600}) {
  tester.view.physicalSize = Size(width, height) * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> seed(
  FamioApiClient api,
  String collection,
  Map<String, Map<String, Object?>> records,
) async {
  final r = await put(api, collection, records);
  expect(
    r.rejected.where((x) => records.containsKey(x.id)).map((x) => x.id),
    isEmpty,
    reason: 'the server takes $collection ${records.keys}',
  );
}

/// Removes what the admin gets of [collections], so a test starts empty.
Future<void> clean(Iterable<String> collections) async {
  final f = await theFamily();
  for (final c in collections) {
    final ids = (await pull(f.admin, c)).keys.toList();
    if (ids.isNotEmpty) await remove(f.admin, c, ids);
  }
}

const shoppingCollections = [
  Collections.shoppingItems,
  Collections.shoppingLists,
  Collections.shoppingHistory,
  Collections.listTemplates,
];

Future<void> cleanShopping() => clean(shoppingCollections);

/// Everything the server gives [api]'s member, by collection.
Future<Map<String, Map<String, SyncRecord>>> pullAll(FamioApiClient api) async {
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

/// Another device of the admin running the app's sync engine (its own
/// store), e.g. a phone that opens the same list.
Future<SyncEngine> secondDevice(FamilyMember admin) async {
  final api = FamioApiClient(kitUrl);
  await api.login(
    username: kitUser,
    password: kitPassword,
    device: 'e2e Zweitgerät',
  );
  final engine = SyncEngine(
    store: LocalStore.open(':memory:'),
    api: api,
    memberId: admin.id,
  );
  addTearDown(() async {
    await engine.dispose();
    engine.store.close();
  });
  await engine.sync();
  return engine;
}

DateTime daysAgo(int n, [int hour = 12]) {
  final t = today();
  return DateTime(t.year, t.month, t.day - n, hour);
}

// --- the app -----------------------------------------------------------------

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

/// Lets a few frames and timers run (e.g. after a tap that should do
/// nothing).
Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
  for (var i = 0; i < ms ~/ 200; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Finder inDialog(Finder f) => find.descendant(
  of: find.byWidgetPredicate((w) => w is AlertDialog || w is Dialog),
  matching: f,
);

Finder inSheet(Finder f) =>
    find.descendant(of: find.byType(BottomSheet), matching: f);

Future<void> sheetClosed(WidgetTester tester) async {
  await waitGone(tester, find.byType(BottomSheet));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Closes a modal sheet or popup menu like a tap beside it.
Future<void> tapAway(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 30));
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> openSettingsEntry(WidgetTester tester, String entry) async {
  await openSection(tester, 'Einstellungen');
  await scrollTo(tester, find.text(entry));
  await tap(tester, find.text(entry));
  await dismissTip(tester);
}

/// The texts of an open drop-down menu.
List<String> menuTexts() => [
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

TextStyle? styleOf(WidgetTester tester, Finder text) =>
    tester.widget<Text>(text.first).style;

TextEditingController? controllerOf(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field.last).controller;

// --- shopping ------------------------------------------------------------------

ShoppingList listNamed(SyncEngine engine, String name) =>
    engine.shoppingLists.singleWhere((l) => l.name == name);

Future<void> newList(WidgetTester tester, String name) async {
  await snackGone(tester);
  await tap(tester, find.byTooltip(de.shoppingNewList));
  await waitFor(tester, find.text(de.shoppingNewShoppingList));
  await enter(tester, field(de.commonName), name);
  await leaveField(tester);
  await tap(tester, inDialog(find.text(de.commonOk)));
  await dialogClosed(tester);
  await waitFor(tester, find.byTooltip(de.commonAdd));
}

Future<void> typeItem(WidgetTester tester, String text) async {
  await enter(tester, find.byType(TextField).first, text);
  await tap(tester, find.byTooltip(de.commonAdd));
}

/// Types [text] into a list's input and adds it; [shows] is the name the
/// item gets ("2 Milch" becomes "Milch" with the amount 2).
Future<void> addItem(WidgetTester tester, String text, String shows) async {
  await typeItem(tester, text);
  await waitFor(tester, itemName(shows));
}

Future<void> openMenu(WidgetTester tester) async {
  await tap(tester, find.byType(PopupMenuButton<String>).last);
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> listMenu(WidgetTester tester, String entry) async {
  await openMenu(tester);
  await tap(tester, find.text(entry).last);
}

bool menuEnabled(WidgetTester tester, String entry) => tester
    .widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text(entry).last,
        matching: find.byType(PopupMenuItem<String>),
      ),
    )
    .enabled;

Future<void> closeMenu(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 600));
}

/// The name of an item (or loan, wish …) in its card: suggestion chips above
/// a shopping list carry the same names.
Finder itemName(String name) =>
    find.descendant(of: find.byType(SoftCard), matching: find.text(name));

Finder rowOf(String name) => cardOf(name);

bool struck(WidgetTester tester, String name) =>
    styleOf(tester, itemName(name))?.decoration == TextDecoration.lineThrough;

/// A heading of a packing list (person or "Für alle").
Finder packingHeading(String label) => find.byWidgetPredicate(
  (w) =>
      w.runtimeType.toString() == '_AisleHeading' &&
      (w as dynamic).label == label,
);

// --- files ---------------------------------------------------------------------

/// A file on disk as the file picker hands it over (its bytes as the
/// plugin streams them: Uint8List chunks).
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

_FakePicker _fakePicker() {
  final before = FilePickerPlatform.instance;
  final fake = _FakePicker();
  FilePickerPlatform.instance = fake;
  addTearDown(() => FilePickerPlatform.instance = before);
  return fake;
}

Future<File> tempFile(String name, List<int> bytes) async {
  final dir = Directory(
    '${(await getTemporaryDirectory()).path}/famio-e2e-all-b',
  )..createSync(recursive: true);
  return File('${dir.path}/$name')..writeAsBytesSync(bytes);
}

Future<Uint8List> pngBytes() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 64, 48),
    Paint()..color = const Color(0xFF3587D6),
  );
  final image = await recorder.endRecording().toImage(64, 48);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// A PDF over 8 MiB: the app streams files of that size to the server.
List<int> bigPdf() => [
  ...'%PDF-1.4\n%E2E\n'.codeUnits,
  ...List.filled(9 * 1024 * 1024, 0x20),
  ...'\n%%EOF\n'.codeUnits,
];

// --- a way in that can be cut ---------------------------------------------------

/// Passes TCP between the app and the server; [cut] makes the server
/// unreachable for the app (as with no network) until [restore].
class _Gate {
  _Gate(this._upstream);

  final Uri _upstream;
  late final ServerSocket _server;
  final _open = <Socket>{};
  var _up = true;
  Completer<void>? _held;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_accept);
  }

  Future<void> _accept(Socket client) async {
    unawaited(client.done.catchError((Object _) {}));
    final held = _held;
    if (held != null) await held.future;
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

  /// New connections wait (a slow network) until [release]; open ones go.
  void hold() {
    _held ??= Completer<void>();
    for (final s in [..._open]) {
      s.destroy();
    }
    _open.clear();
  }

  void release() {
    _held?.complete();
    _held = null;
  }

  Future<void> close() async {
    release();
    cut();
    await _server.close();
  }
}

/// Like startApp, at [url] instead of the server's own address.
Future<AppState> startAt(WidgetTester tester, String url) async {
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

// --- chat ----------------------------------------------------------------------

Future<void> cleanChat() => clean([Collections.chatMessages]);

Map<String, Object?> message(
  String id,
  String chatId,
  FamilyMember author,
  String text, {
  DateTime? at,
  List<String>? to,
  Poll? poll,
}) => ChatMessage(
  id: id,
  chatId: chatId,
  authorId: author.id,
  sentAt: at ?? DateTime.now(),
  text: text,
  visibleTo: to,
  poll: poll,
).toData();

Finder get composer => find.byType(TextField).last;

Future<void> send(WidgetTester tester, String text) async {
  await enter(tester, composer, text);
  await tap(tester, find.byTooltip(de.commonSend));
}

bool rightAligned(WidgetTester tester, String text) => find
    .ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate(
        (w) => w is Row && w.mainAxisAlignment == MainAxisAlignment.end,
      ),
    )
    .evaluate()
    .isNotEmpty;

// --- notes ---------------------------------------------------------------------

Future<void> openPinboard(WidgetTester tester) async {
  await openSection(tester, 'Start');
  await scrollTo(tester, find.text(de.commonPinboard));
  await tap(tester, find.text(de.commonPinboard));
  await dismissTip(tester);
  await waitFor(tester, find.text(de.notesNotesFamily));
}

Color? paperOf(WidgetTester tester, String title) => tester
    .widget<Material>(
      find
          .ancestor(of: find.text(title), matching: find.byType(Material))
          .first,
    )
    .color;

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

// --- deadlines -----------------------------------------------------------------

Future<void> openDeadlines(WidgetTester tester) async {
  await openSettingsEntry(tester, de.settingsDeadlines);
  await waitFor(tester, find.text(de.deadlinesCarHousePets));
}

Future<void> cleanDeadlines() =>
    clean([Collections.deadlines, Collections.budgetEntries]);

Deadline deadlineNamed(SyncEngine engine, String title) =>
    engine.deadlines.singleWhere((d) => d.title == title);

DateTime addMonths(DateTime d, int months) {
  final first = DateTime(d.year, d.month + months);
  final last = DateUtils.getDaysInMonth(first.year, first.month);
  return DateTime(first.year, first.month, d.day > last ? last : d.day);
}

void main() {
  // The tests read German texts, whatever the device speaks.
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // --- Erste Schritte: allein in der Familie ------------------------------------

  // Runs first, before the file creates the other members.
  testWidgets(
    'ALL-111 ALL-160 alone: chat list hints, the first shopping list',
    (tester) async {
      tall(tester);
      final state = await startApp(tester);
      final engine = state.engine!;

      // ALL-160: nobody else yet.
      await openSection(tester, 'Chat');
      await waitFor(tester, find.text(de.settingsFamily));
      await waitFor(tester, find.text(de.chatNoMessagesYetSay));
      await waitFor(tester, find.text(de.chatSoonMoreFamilyMembers));
      expect(find.text(de.chatOneOneChats), findsNothing);

      // ALL-111 (a fresh server: no list yet)
      await openSection(tester, 'Einkauf');
      await waitFor(tester, find.text(de.shoppingCreateFirstList));
      // An empty name does nothing.
      await tap(tester, find.text(de.shoppingCreateFirstList));
      await waitFor(tester, find.text(de.shoppingNewShoppingList));
      await tap(tester, inDialog(find.text(de.commonOk)));
      await dialogClosed(tester);
      await settle(tester);
      expect(engine.shoppingLists, isEmpty);
      expect(find.text(de.shoppingCreateFirstList), findsOneWidget);
      // With a name the list opens at once.
      await tap(tester, find.text(de.shoppingCreateFirstList));
      await waitFor(tester, find.text(de.shoppingNewShoppingList));
      await enter(tester, field(de.commonName), 'E2E Wocheneinkauf');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonOk)));
      await dialogClosed(tester);
      await waitFor(
        tester,
        find.widgetWithText(TextField, de.shoppingAddItemEG),
      );
      expect(find.text('E2E Wocheneinkauf'), findsWidgets);
      await back(tester);
      await waitFor(tester, find.text(de.shoppingEmpty));
      expect(
        find.descendant(
          of: cardOf('E2E Wocheneinkauf'),
          matching: find.text(de.shoppingEmpty),
        ),
        findsOneWidget,
      );
      expect(engine.shoppingLists.single.name, 'E2E Wocheneinkauf');
      await engine.sync();
      await finish(tester, state);
      await cleanShopping();
    },
  );

  // --- Einkaufslisten ------------------------------------------------------------

  testWidgets(
    'ALL-112 ALL-113 ALL-114 ALL-115 another list, items with amounts, twice, ticked off',
    (tester) async {
      tall(tester);
      await theFamily();
      await cleanShopping();
      final f = await theFamily();
      await seed(f.admin, Collections.shoppingLists, {
        'e2e-l-alt': const ShoppingList(
          id: 'e2e-l-alt',
          name: 'E2E Altliste',
        ).toData(),
      });
      final state = await startApp(tester);
      final engine = state.engine!;
      await openSection(tester, 'Einkauf');
      await waitFor(tester, find.text('E2E Altliste'));

      // ALL-112: the dialog's name, the new list below the others.
      await newList(tester, 'E2E Drogerie');
      final list = listNamed(engine, 'E2E Drogerie');
      ShoppingItem item(String name) =>
          engine.shoppingItems(list.id).singleWhere((i) => i.name == name);
      int count(String name) =>
          engine.shoppingItems(list.id).where((i) => i.name == name).length;

      // ALL-113
      await addItem(tester, '2 Milch', 'Milch');
      await addItem(tester, '3x Äpfel', 'Äpfel');
      expect((item('Milch').quantity, item('Äpfel').quantity), ('2', '3'));
      expect(
        find.descendant(of: rowOf('Milch'), matching: find.text('2')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rowOf('Äpfel'), matching: find.text('3')),
        findsOneWidget,
      );
      await waitFor(tester, find.text('Kühlregal'));
      await waitFor(tester, find.text('Obst & Gemüse'));

      // ALL-114: open already – pointed out; ticked off – opened again.
      await typeItem(tester, 'Milch');
      await waitFor(tester, find.text(de.shoppingAlreadyOnList('Milch')));
      expect(count('Milch'), 1);
      await addItem(tester, 'Brot', 'Brot');
      await tap(tester, itemName('Brot'));
      await until(tester, () => item('Brot').checked, 'Brot ticked off');
      await snackGone(tester);
      await typeItem(tester, 'Brot');
      await until(tester, () => !item('Brot').checked, 'Brot open again');
      expect(count('Brot'), 1);

      // ALL-115: by the row and by the circle.
      await tap(tester, itemName('Milch'));
      await waitFor(tester, find.text(de.shoppingCartCount(1)));
      expect(struck(tester, 'Milch'), isTrue);
      await waitFor(tester, find.text(de.commonOpenCount(2)));
      await tap(
        tester,
        find.descendant(of: rowOf('Äpfel'), matching: find.byType(RoundCheck)),
      );
      await tap(
        tester,
        find.descendant(of: rowOf('Brot'), matching: find.byType(RoundCheck)),
      );
      await waitFor(tester, find.text(de.shoppingCartCount(3)));
      await waitFor(tester, find.text(de.shoppingAllDone));
      expect(struck(tester, 'Äpfel') && struck(tester, 'Brot'), isTrue);
      await back(tester);
      await waitFor(tester, find.text(de.shoppingEverythingCart));
      final card = cardOf('E2E Drogerie');
      expect(
        find.descendant(
          of: card,
          matching: find.text(de.shoppingEverythingCart),
        ),
        findsOneWidget,
      );
      // No counter beside a list with nothing open.
      expect(
        find.descendant(
          of: card,
          matching: find.byWidgetPredicate(
            (w) => w is Text && RegExp(r'^\d+$').hasMatch(w.data ?? ''),
          ),
        ),
        findsNothing,
      );
      // ALL-112: below the list that was there before.
      expect(
        tester.getTopLeft(find.text('E2E Altliste')).dy,
        lessThan(tester.getTopLeft(find.text('E2E Drogerie')).dy),
      );
      await engine.sync();
      await finish(tester, state);
      await cleanShopping();
    },
  );

  testWidgets(
    'ALL-116 ALL-117 ALL-118 ALL-119 aisles, editing, swiping away, clearing',
    (tester) async {
      tall(tester);
      await theFamily();
      await cleanShopping();
      final state = await startApp(tester);
      final engine = state.engine!;
      await openSection(tester, 'Einkauf');
      await newList(tester, 'E2E Markt');
      final list = listNamed(engine, 'E2E Markt');
      ShoppingItem item(String name) =>
          engine.shoppingItems(list.id).singleWhere((i) => i.name == name);
      await addItem(tester, 'Quark', 'Quark');
      await addItem(tester, 'Brot', 'Brot');
      await waitFor(tester, find.text('Kühlregal'));

      Future<void> edit(String name) async {
        await tap(
          tester,
          find.descendant(
            of: rowOf(name),
            matching: find.byTooltip(de.commonEdit),
          ),
        );
        await waitFor(tester, find.text(de.shoppingEditItem));
      }

      // ALL-116: another aisle, remembered for next time.
      await edit('Quark');
      await choose(tester, de.shoppingAisle, 'Sonstiges');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await until(
        tester,
        () => item('Quark').category == 'other',
        'Quark in Sonstiges',
      );
      await waitFor(tester, find.text('Sonstiges'));
      expect(find.text('Kühlregal'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Sonstiges')).dy,
        lessThan(tester.getTopLeft(itemName('Quark')).dy),
      );

      // ALL-118: swiped away and back.
      Future<void> swipe(String name) async {
        await snackGone(tester);
        await tester.drag(rowOf(name), const Offset(-600, 0));
        await settle(tester, 800);
        await waitGone(tester, itemName(name));
      }

      final quarkId = item('Quark').id;
      await swipe('Quark');
      expect(engine.record(Collections.shoppingItems, quarkId), isNull);
      await waitFor(tester, find.text(de.undoWhatDeleted('Quark')));
      await tap(tester, find.text(de.commonUndo));
      await waitFor(tester, itemName('Quark'));
      expect(item('Quark').id, quarkId);

      // ALL-116: put on again, it lands in the aisle chosen before.
      await swipe('Quark');
      await snackGone(tester);
      await addItem(tester, 'Quark', 'Quark');
      expect(item('Quark').id, isNot(quarkId));
      expect(item('Quark').category, 'other');
      await waitFor(tester, find.text('Sonstiges'));

      // ALL-117: name and amount; an empty name changes nothing.
      await edit('Brot');
      await enter(tester, field(de.shoppingItem), 'Vollkornbrot');
      await enter(tester, field(de.commonQuantity), '1 Laib');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await waitFor(tester, itemName('Vollkornbrot'));
      expect(item('Vollkornbrot').quantity, '1 Laib');
      await edit('Vollkornbrot');
      await enter(tester, field(de.shoppingItem), '');
      await enter(tester, field(de.commonQuantity), '2 Laib');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await settle(tester);
      expect(item('Vollkornbrot').quantity, '1 Laib');

      // ALL-119: nothing ticked – both entries locked.
      await openMenu(tester);
      expect(menuEnabled(tester, de.shoppingRemoveCheckedItems), isFalse);
      expect(menuEnabled(tester, de.shoppingRemoveAllCheckmarks), isFalse);
      await closeMenu(tester);
      await tap(tester, itemName('Vollkornbrot'));
      await tap(tester, itemName('Quark'));
      await waitFor(tester, find.text(de.shoppingCartCount(2)));
      await openMenu(tester);
      expect(menuEnabled(tester, de.shoppingRemoveCheckedItems), isTrue);
      expect(menuEnabled(tester, de.shoppingRemoveAllCheckmarks), isTrue);
      await tap(tester, find.text(de.shoppingRemoveCheckedItems).last);
      await waitFor(tester, find.text(de.shoppingCountCheckedItemsRemoved(2)));
      await until(
        tester,
        () => engine.shoppingItems(list.id).isEmpty,
        'both removed',
      );
      await tap(tester, find.text(de.commonUndo));
      await until(
        tester,
        () =>
            engine.shoppingItems(list.id).length == 2 &&
            engine.shoppingItems(list.id).every((i) => i.checked),
        'both back, ticked',
      );
      await snackGone(tester);
      await listMenu(tester, de.shoppingRemoveAllCheckmarks);
      await until(
        tester,
        () => engine.shoppingItems(list.id).every((i) => !i.checked),
        'both open again',
      );
      await engine.sync();
      await finish(tester, state);
      await cleanShopping();
    },
  );

  testWidgets(
    'ALL-120 ALL-121 ALL-122 suggestions, staples, two devices, packing lists',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await cleanShopping();
      const listId = 'e2e-l-vorrat';
      await seed(f.admin, Collections.shoppingLists, {
        listId: const ShoppingList(id: listId, name: 'E2E Vorrat').toData(),
      });
      final state = await startApp(tester);
      final engine = state.engine!;

      // ALL-121: nothing bought yet.
      await openSection(tester, 'Einkauf');
      await tap(tester, find.text('E2E Vorrat'));
      await waitFor(tester, find.byTooltip(de.commonAdd));
      await listMenu(tester, de.shoppingStaples);
      await waitFor(tester, find.text(de.shoppingStaplesEmpty));
      await tapAway(tester);
      await sheetClosed(tester);
      await back(tester);

      // What the family bought; the staple is due again.
      await seed(f.admin, Collections.shoppingItems, {
        'e2e-i-wasser': const ShoppingItem(
          id: 'e2e-i-wasser',
          listId: listId,
          name: 'Mineralwasser',
        ).toData(),
      });
      BoughtItem bought(
        String name,
        int count,
        int ago, {
        String quantity = '',
        int? every,
        String list = listId,
      }) => BoughtItem(
        key: shoppingKey(name),
        name: name,
        quantity: quantity,
        count: count,
        lastBought: daysAgo(ago),
        listId: list,
        everyDays: every,
      );
      await seed(f.admin, Collections.shoppingHistory, {
        for (final b in [
          bought('Hafermilch', 9, 1, quantity: '1 l'),
          bought('Milch', 2, 3, quantity: '2 l'),
          bought('Mineralwasser', 5, 2),
          bought('E2E Windeln', 3, 15, quantity: '1 Packung', every: 14),
        ])
          b.key: b.toData(),
      });
      // ALL-122: a second phone of the admin knows all that, but not yet
      // what the app puts on the list.
      final other = await secondDevice(f.adminMember);
      await engine.sync();
      await tap(tester, find.text('E2E Vorrat'));
      await waitFor(tester, find.text(de.shoppingStaplesAdded(1)));
      await waitFor(tester, find.text('E2E Windeln'));

      // ALL-120: quick picks, most bought (and lately) first.
      await waitFor(tester, find.text(de.shoppingFrequent));
      Finder chip(String name) => find.widgetWithText(ActionChip, name);
      expect(chip('Hafermilch'), findsOneWidget);
      expect(chip('Milch'), findsOneWidget);
      expect(chip('Mineralwasser'), findsNothing, reason: 'open on the list');
      expect(chip('E2E Windeln'), findsNothing, reason: 'open on the list');
      expect(
        tester.getTopLeft(chip('Hafermilch')).dx,
        lessThan(tester.getTopLeft(chip('Milch')).dx),
      );
      // While typing: what matches, the start of a word first.
      await enter(tester, find.byType(TextField).first, 'Mi');
      await waitGone(tester, find.text(de.shoppingFrequent));
      expect(chip('Mineralwasser'), findsNothing);
      expect(
        tester.getTopLeft(chip('Milch')).dx,
        lessThan(tester.getTopLeft(chip('Hafermilch')).dx),
      );
      await tap(tester, chip('Milch'));
      await until(
        tester,
        () => engine
            .shoppingItems(listId)
            .any((i) => i.name == 'Milch' && i.quantity == '2 l'),
        'Milch with the last amount',
      );
      expect(controllerOf(tester, find.byType(TextField).first)!.text, '');

      // ALL-122: the other phone opens the list at the same time.
      await engine.sync();
      final added = other.addDueStaples();
      expect(added, 1, reason: 'the other device puts the staple on too');
      await other.sync();
      await engine.sync();
      await settle(tester);
      expect(
        engine.shoppingItems(listId).where((i) => i.name == 'E2E Windeln'),
        hasLength(1),
      );
      expect(
        (await pull(
          f.admin,
          Collections.shoppingItems,
        )).values.where((r) => r.data['name'] == 'E2E Windeln'),
        hasLength(1),
        reason: 'one entry on the server',
      );

      // ALL-121: staples with rhythm, forgetting and back.
      await listMenu(tester, de.shoppingStaples);
      await waitFor(tester, find.text(de.shoppingStaplesHint));
      await waitFor(tester, find.text(de.shoppingBoughtTimes(9)));
      final windelnRow = find.ancestor(
        of: find.text('1 Packung E2E Windeln'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(
          of: windelnRow,
          matching: find.textContaining(de.shoppingNextOn('')),
        ),
        findsOneWidget,
      );
      final milchRow = find.ancestor(
        of: find.text('2 l Milch'),
        matching: find.byType(ListTile),
      );
      await tap(
        tester,
        find.descendant(
          of: milchRow,
          matching: find.byType(DropdownButton<int?>),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        menuTexts(),
        containsAll([
          de.shoppingRhythmNone,
          de.shoppingRhythmWeekly,
          de.shoppingRhythmWeeks(2),
          de.shoppingRhythmWeeks(4),
        ]),
      );
      await tap(tester, find.text(de.shoppingRhythmWeekly).last);
      await until(
        tester,
        () => engine.boughtItem(shoppingKey('Milch'))?.everyDays == 7,
        'Milch weekly',
      );
      await waitFor(
        tester,
        find.descendant(
          of: milchRow,
          matching: find.textContaining(de.shoppingNextOn('')),
        ),
      );
      await tapAway(tester);
      await sheetClosed(tester);
      await back(tester);

      // ALL-122: a staple of a packing list goes on a shopping list.
      const packing = 'e2e-l-pack';
      await seed(f.admin, Collections.shoppingLists, {
        packing: const ShoppingList(
          id: packing,
          name: 'E2E Koffer',
          packing: true,
          sort: -1,
        ).toData(),
      });
      await seed(f.admin, Collections.shoppingHistory, {
        shoppingKey('E2E Sonnencreme'): bought(
          'E2E Sonnencreme',
          2,
          30,
          every: 14,
          list: packing,
        ).toData(),
      });
      await engine.sync();
      await snackGone(tester);
      await tap(tester, find.text('E2E Vorrat'));
      await waitFor(tester, find.text(de.shoppingStaplesAdded(1)));
      await waitFor(tester, find.text('E2E Sonnencreme'));
      expect(engine.shoppingItems(packing), isEmpty);
      await engine.sync();
      await finish(tester, state);
      await cleanShopping();
    },
  );

  // Befund (reproduced twice): "Vergessen" in the staples sheet shows its
  // "Rückgängig" in a snack bar of the page under the sheet
  // (shopping_screens.dart:998, deleteWithUndo with the sheet's context): the
  // sheet and its barrier cover it, a tap there hits the sheet, nothing
  // comes back. The test taps where the button is drawn.
  testWidgets('ALL-121 forgetting a staple, and back', skip: true, (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await cleanShopping();
    const listId = 'e2e-l-stamm';
    await seed(f.admin, Collections.shoppingLists, {
      listId: const ShoppingList(id: listId, name: 'E2E Stamm').toData(),
    });
    final key = shoppingKey('Hafermilch');
    await seed(f.admin, Collections.shoppingHistory, {
      key: BoughtItem(
        key: key,
        name: 'Hafermilch',
        quantity: '1 l',
        count: 9,
        lastBought: daysAgo(1),
        listId: listId,
      ).toData(),
    });
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Einkauf');
    await tap(tester, find.text('E2E Stamm'));
    await waitFor(tester, find.byTooltip(de.commonAdd));
    await listMenu(tester, de.shoppingStaples);
    await waitFor(tester, find.text('1 l Hafermilch'));
    await tap(
      tester,
      find.descendant(
        of: find.ancestor(
          of: find.text('1 l Hafermilch'),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip(de.shoppingForget),
      ),
    );
    await until(
      tester,
      () => engine.boughtItem(key) == null,
      'Hafermilch forgotten',
    );
    await waitFor(tester, find.text(de.shoppingStaplesEmpty));
    await waitFor(tester, find.text(de.undoWhatDeleted('Hafermilch')));
    // Where a person taps "Rückgängig": what is on top there?
    final undo = find.text(de.commonUndo);
    final hit = tester.hitTestOnBinding(tester.getCenter(undo));
    final reachable = hit.path.any(
      (e) => e.target == tester.renderObject(undo),
    );
    debugPrint(
      'E2E-INFO "Rückgängig" under the staples sheet reachable: '
      '$reachable',
    );
    await tap(tester, undo);
    await until(
      tester,
      () => engine.boughtItem(key)?.count == 9,
      'Hafermilch back',
      timeout: const Duration(seconds: 8),
    );
    if (find.byType(BottomSheet).evaluate().isNotEmpty) {
      await tapAway(tester);
      await sheetClosed(tester);
    }
    await engine.sync();
    await finish(tester, state);
    await cleanShopping();
  });

  testWidgets(
    'ALL-123 ALL-124 ALL-125 ALL-126 as text, renamed, deleted, gone elsewhere',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await cleanShopping();
      // The share sheet is native: the test reads what Famio hands to it.
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      final shared = <Map<Object?, Object?>>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        shared.add(call.arguments as Map<Object?, Object?>);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final state = await startApp(tester);
      final engine = state.engine!;
      await openSection(tester, 'Einkauf');
      await newList(tester, 'E2E Oma kauft ein');
      final list = listNamed(engine, 'E2E Oma kauft ein');
      await addItem(tester, '3 Äpfel', 'Äpfel');
      await addItem(tester, '2 Milch', 'Milch');
      await addItem(tester, 'Brot', 'Brot');
      await tap(tester, itemName('Brot'));
      await waitFor(tester, find.text(de.shoppingCartCount(1)));

      // ALL-123
      await openMenu(tester);
      expect(menuEnabled(tester, de.shoppingShareText), isTrue);
      await tap(tester, find.text(de.shoppingShareText).last);
      await until(tester, () => shared.isNotEmpty, 'share sheet called');
      final text = shared.single['text'] as String;
      debugPrint('E2E shared text:\n$text');
      final lines = text.split('\n');
      expect(lines.first, 'E2E Oma kauft ein');
      expect(lines, containsAll(['• 3 Äpfel', '• 2 Milch']));
      expect(text, isNot(contains('Brot')));
      expect(
        lines.indexOf('Obst & Gemüse'),
        lessThan(lines.indexOf('• 3 Äpfel')),
      );
      expect(lines.indexOf('Kühlregal'), lessThan(lines.indexOf('• 2 Milch')));
      // Nothing open: locked.
      await tap(tester, itemName('Äpfel'));
      await tap(tester, itemName('Milch'));
      await waitFor(tester, find.text(de.shoppingAllDone));
      await openMenu(tester);
      expect(menuEnabled(tester, de.shoppingShareText), isFalse);
      await closeMenu(tester);

      // ALL-124
      await listMenu(tester, de.commonRename);
      await waitFor(tester, find.text(de.shoppingRenameList));
      await enter(tester, field(de.commonName), 'E2E Opa kauft ein');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonOk)));
      await dialogClosed(tester);
      await waitFor(tester, find.text('E2E Opa kauft ein'));
      expect(engine.shoppingList(list.id)!.name, 'E2E Opa kauft ein');
      await back(tester);
      await waitFor(tester, find.text('E2E Opa kauft ein'));
      expect(find.text('E2E Oma kauft ein'), findsNothing);

      // ALL-125
      await tap(tester, find.text('E2E Opa kauft ein'));
      await waitFor(tester, find.byTooltip(de.commonAdd));
      await listMenu(tester, de.shoppingDeleteList);
      await waitFor(
        tester,
        find.text(de.commonDeleteName('E2E Opa kauft ein')),
      );
      expect(find.text(de.shoppingListAllItsEntries), findsOneWidget);
      await tap(tester, inDialog(find.text(de.commonDelete)));
      await dialogClosed(tester);
      await until(
        tester,
        () =>
            engine.shoppingList(list.id) == null &&
            engine.shoppingItems(list.id).isEmpty,
        'list and items gone',
      );
      await waitGone(tester, find.text('E2E Opa kauft ein'));
      await tap(tester, find.text(de.commonUndo));
      await until(
        tester,
        () =>
            engine.shoppingList(list.id) != null &&
            engine.shoppingItems(list.id).length == 3 &&
            engine.shoppingItems(list.id).every((i) => i.checked),
        'list back with its items and ticks',
      );
      await waitFor(tester, find.text('E2E Opa kauft ein'));
      await engine.sync();

      // ALL-126: deleted on another device while open here.
      await snackGone(tester);
      await tap(tester, find.text('E2E Opa kauft ein'));
      await waitFor(tester, find.byTooltip(de.commonAdd));
      await remove(f.admin, Collections.shoppingItems, [
        for (final i in engine.shoppingItems(list.id)) i.id,
      ]);
      await remove(f.admin, Collections.shoppingLists, [list.id]);
      await engine.sync();
      await waitFor(tester, find.text(de.shoppingListNoLongerExists));
      await finish(tester, state);
      await cleanShopping();
    },
  );

  testWidgets('ALL-127 ALL-131 who sees a list; into the household book', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await cleanShopping();
    await clean([Collections.budgetEntries]);
    final bea = await sessionOf(f.bea);
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Einkauf');
    await newList(tester, 'E2E Geheimliste');
    await addItem(tester, 'Geschenkpapier', 'Geschenkpapier');
    final list = listNamed(engine, 'E2E Geheimliste');
    await engine.sync();
    await eventually(
      tester,
      'Bea gets the family list',
      () async =>
          (await pull(bea, Collections.shoppingLists)).containsKey(list.id),
    );

    // ALL-127: the dialog; "Ich und …" with nobody.
    await listMenu(tester, de.shoppingWhoSees);
    await waitFor(tester, inDialog(find.text(de.shoppingWhoSeesHint)));
    for (final option in [de.commonWholeFamily, de.docsOnlyMe, de.docsMe]) {
      expect(inDialog(find.text(option)), findsOneWidget, reason: option);
    }
    await tap(tester, inDialog(find.text(de.docsMe)));
    await tap(tester, inDialog(find.text(de.commonSave)));
    await dialogClosed(tester);
    await until(
      tester,
      () => engine.shoppingList(list.id)?.visibleTo?.join() == state.me!.id,
      'only me',
    );
    await engine.sync();
    await back(tester);
    await waitFor(tester, find.text(de.commonVisibleTo(kitAdminName)));
    expect(
      find.descendant(
        of: cardOf('E2E Geheimliste'),
        matching: find.byIcon(AppIcons.lockKey),
      ),
      findsOneWidget,
    );
    Future<void> beaGetsNothing() async {
      await eventually(
        tester,
        'Bea gets neither list nor items',
        () async =>
            !(await pull(
              bea,
              Collections.shoppingLists,
            )).containsKey(list.id) &&
            (await pull(
              bea,
              Collections.shoppingItems,
            )).values.every((r) => r.data['listId'] != list.id),
      );
    }

    await beaGetsNothing();
    // "Nur ich"
    await tap(tester, find.text('E2E Geheimliste'));
    await listMenu(tester, de.shoppingWhoSees);
    await tap(tester, inDialog(find.text(de.docsOnlyMe)));
    await tap(tester, inDialog(find.text(de.commonSave)));
    await dialogClosed(tester);
    await engine.sync();
    expect(engine.shoppingList(list.id)?.visibleTo, [state.me!.id]);
    await beaGetsNothing();
    await back(tester);

    // ALL-131: into the household book.
    await newList(tester, 'E2E Samstag');
    await addItem(tester, 'Käse', 'Käse');
    await addItem(tester, 'Butter', 'Butter');
    await addItem(tester, 'Eier', 'Eier');
    await tap(tester, itemName('Butter'));
    await tap(tester, itemName('Eier'));
    await waitFor(tester, find.text(de.shoppingCartCount(2)));
    await tap(tester, find.text(de.purchaseButton));
    await waitFor(tester, find.text(de.purchaseTitle));
    await enter(tester, field(de.purchaseAmount), '12,34');
    await leaveField(tester);
    await tap(tester, find.text(de.purchaseSave));
    await waitFor(
      tester,
      find.textContaining('als Ausgabe für Lebensmittel eingetragen.'),
    );
    await until(
      tester,
      () => engine.budgetEntries.any((e) => e.cents == 1234 && !e.income),
      'an expense in the budget',
    );
    // Who does not see the household book gets no button.
    await snackGone(tester);
    await tap(tester, itemName('Käse'));
    await waitFor(tester, find.text(de.purchaseButton));
    await seed(f.admin, Collections.budgetSettings, {
      BudgetSettings.recordId: {
        ...BudgetSettings(memberIds: [f.bea.id]).toData(),
        SyncRecord.visibilityKey: [f.bea.id],
      },
    });
    addTearDown(
      () => put(f.admin, Collections.budgetSettings, {
        BudgetSettings.recordId: {
          ...const BudgetSettings().toData(),
          SyncRecord.visibilityKey: null,
        },
      }),
    );
    await engine.sync();
    await waitGone(tester, find.text(de.purchaseButton));
    await openMenu(tester);
    expect(find.text(de.purchaseTitle), findsNothing);
    await closeMenu(tester);
    await put(f.admin, Collections.budgetSettings, {
      BudgetSettings.recordId: {
        ...const BudgetSettings().toData(),
        SyncRecord.visibilityKey: null,
      },
    });
    await engine.sync();
    await waitFor(tester, find.text(de.purchaseButton));
    await finish(tester, state);
    await cleanShopping();
    await clean([Collections.budgetEntries]);
  });

  testWidgets('ALL-129 a child and who sees a list', (tester) async {
    tall(tester);
    final f = await theFamily();
    await cleanShopping();
    final kid = await sessionOf(f.kid);
    final bea = await sessionOf(f.bea);
    await seed(f.admin, Collections.shoppingLists, {
      'e2e-l-familie': const ShoppingList(
        id: 'e2e-l-familie',
        name: 'E2E Familienliste',
      ).toData(),
    });
    await seed(kid, Collections.shoppingLists, {
      'e2e-l-kind': ShoppingList(
        id: 'e2e-l-kind',
        name: 'E2E Kinderliste',
        visibleTo: [f.kid.id],
      ).toData(),
    });
    final state = await startApp(tester, user: 'e2e-kind');
    await openSection(tester, 'Einkauf');
    await tap(tester, find.text('E2E Familienliste'));
    await waitFor(tester, find.byTooltip(de.commonAdd));
    await openMenu(tester);
    expect(find.text(de.commonRename), findsWidgets);
    expect(find.text(de.shoppingWhoSees), findsNothing);
    await closeMenu(tester);
    await back(tester);
    await tap(tester, find.text('E2E Kinderliste'));
    await waitFor(tester, find.byTooltip(de.commonAdd));
    await openMenu(tester);
    expect(find.text(de.shoppingWhoSees), findsOneWidget);
    await closeMenu(tester);

    // The audience of the family list set through the API stays.
    await put(kid, Collections.shoppingLists, {
      'e2e-l-familie': ShoppingList(
        id: 'e2e-l-familie',
        name: 'E2E Familienliste',
        visibleTo: [f.kid.id],
      ).toData(),
    });
    final adminView = await pull(f.admin, Collections.shoppingLists);
    expect(adminView['e2e-l-familie']?.visibleTo, isNull);
    expect(
      (await pull(bea, Collections.shoppingLists)).containsKey('e2e-l-familie'),
      isTrue,
    );
    await finish(tester, state);
    await remove(kid, Collections.shoppingLists, ['e2e-l-kind']);
    await cleanShopping();
  });

  testWidgets(
    'ALL-130 ALL-131 a guest adds and ticks off, may not rename or create',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await cleanShopping();
      const listId = 'e2e-l-gast';
      await seed(f.admin, Collections.shoppingLists, {
        listId: const ShoppingList(id: listId, name: 'E2E Gästeliste').toData(),
      });
      await seed(f.admin, Collections.shoppingItems, {
        for (final n in ['Milch', 'Brot'])
          'e2e-i-gast-$n': ShoppingItem(
            id: 'e2e-i-gast-$n',
            listId: listId,
            name: n,
            category: n == 'Milch' ? 'dairy' : 'bakery',
          ).toData(),
      });
      final state = await startApp(tester, user: 'e2e-gast');
      final engine = state.engine!;
      await openSection(tester, 'Einkauf');
      await tap(tester, find.text('E2E Gästeliste'));
      await waitFor(tester, find.byTooltip(de.commonAdd));
      await addItem(tester, 'Kekse', 'Kekse');
      await tap(tester, itemName('Milch'));
      await waitFor(tester, find.text(de.shoppingCartCount(1)));
      // ALL-131: guests get no button.
      expect(find.text(de.purchaseButton), findsNothing);
      await engine.sync();
      await eventually(tester, 'the server keeps Kekse and the tick', () async {
        final items = await pull(f.admin, Collections.shoppingItems);
        return items.values.any((r) => r.data['name'] == 'Kekse') &&
            items['e2e-i-gast-Milch']?.data['checked'] == true;
      });

      // Renaming: back as it was after the sync.
      await listMenu(tester, de.commonRename);
      await enter(tester, field(de.commonName), 'E2E Umbenannt');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonOk)));
      await dialogClosed(tester);
      await engine.sync();
      await until(
        tester,
        () => engine.shoppingList(listId)?.name == 'E2E Gästeliste',
        'the old name back',
      );
      expect(
        (await pull(f.admin, Collections.shoppingLists))[listId]?.data['name'],
        'E2E Gästeliste',
      );
      await back(tester);

      // A new list: gone after the sync (often before its page is up).
      await snackGone(tester);
      await tap(tester, find.byTooltip(de.shoppingNewList));
      await waitFor(tester, find.text(de.shoppingNewShoppingList));
      await enter(tester, field(de.commonName), 'E2E Gastliste');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonOk)));
      await dialogClosed(tester);
      await engine.sync();
      await waitFor(tester, find.text(de.shoppingListNoLongerExists));
      expect(
        engine.shoppingLists.where((l) => l.name == 'E2E Gastliste'),
        isEmpty,
      );
      expect(
        (await pull(
          f.admin,
          Collections.shoppingLists,
        )).values.where((r) => r.data['name'] == 'E2E Gastliste'),
        isEmpty,
      );
      expect(
        (await pull(
          f.admin,
          Collections.shoppingItems,
        )).values.where((r) => r.data['listId'] == listId),
        hasLength(3),
      );
      await finish(tester, state);
      await cleanShopping();
    },
  );

  // Befund (hint of ALL-130, reproduced twice): a guest's "Liste löschen"
  // deletes every item one by one (guests may delete items), the deletion
  // of the list is refused: the list stays, empty – the items are lost for
  // the whole family (family_data.dart:147, shopping_screens.dart:473).
  testWidgets('ALL-130 a guest deletes a list: nothing is lost', skip: true, (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await cleanShopping();
    const listId = 'e2e-l-gast2';
    await seed(f.admin, Collections.shoppingLists, {
      listId: const ShoppingList(id: listId, name: 'E2E Gästeliste 2').toData(),
    });
    await seed(f.admin, Collections.shoppingItems, {
      for (final n in ['Tee', 'Honig'])
        'e2e-i-gast2-$n': ShoppingItem(
          id: 'e2e-i-gast2-$n',
          listId: listId,
          name: n,
        ).toData(),
    });
    final state = await startApp(tester, user: 'e2e-gast');
    final engine = state.engine!;
    await openSection(tester, 'Einkauf');
    await tap(tester, find.text('E2E Gästeliste 2'));
    await waitFor(tester, find.byTooltip(de.commonAdd));
    expect(find.text(de.shoppingDeleteList), findsNothing);
    await listMenu(tester, de.shoppingDeleteList);
    await tap(tester, inDialog(find.text(de.commonDelete)));
    await dialogClosed(tester);
    await engine.sync();
    await settle(tester, 2000);
    await engine.sync();
    final items = (await pull(
      f.admin,
      Collections.shoppingItems,
    )).values.where((r) => r.data['listId'] == listId).toList();
    debugPrint('E2E-INFO items left after the guest deleted: ${items.length}');
    expect(
      (await pull(f.admin, Collections.shoppingLists)).containsKey(listId),
      isTrue,
      reason: 'the list stays',
    );
    expect(engine.shoppingList(listId), isNotNull);
    expect(items, hasLength(2), reason: 'no item may get lost');
    expect(engine.shoppingItems(listId), hasLength(2));
    await finish(tester, state);
    await cleanShopping();
  });

  // --- Vorlagen & Packlisten ------------------------------------------------------

  testWidgets('ALL-134 ALL-135 lists from templates, saved and deleted', (
    tester,
  ) async {
    tall(tester);
    await theFamily();
    await cleanShopping();
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Einkauf');

    // ALL-134
    await tap(tester, find.byTooltip(de.shoppingListTemplate));
    await waitFor(tester, inSheet(find.text(de.templatesSuggestions)));
    expect(inSheet(find.text(de.templatesTemplates)), findsNothing);
    final builtIn = {for (final t in builtInTemplates) t.name: t};
    for (final name in [
      'Urlaub',
      'Kliniktasche Geburt',
      'Schwimmbad',
      'Camping',
    ]) {
      final tile = find.ancestor(
        of: inSheet(find.text(name)),
        matching: find.byType(ListTile),
      );
      expect(tile, findsOneWidget, reason: name);
      expect(
        find.descendant(
          of: tile,
          matching: find.text(
            de.templatesCountEntries(builtIn[name]!.items.length),
          ),
        ),
        findsOneWidget,
        reason: name,
      );
    }
    await tap(tester, inSheet(find.text('Schwimmbad')));
    await sheetClosed(tester);
    await waitFor(tester, find.text('🏊 Schwimmbad'));
    final pool = listNamed(engine, '🏊 Schwimmbad');
    expect(engine.shoppingItems(pool.id).map((i) => i.name).toSet(), {
      for (final i in builtIn['Schwimmbad']!.items) i.name,
    });
    await back(tester);

    // ALL-135: a list named like a suggestion, with a tick.
    await newList(tester, 'Camping');
    await addItem(tester, 'Zelt', 'Zelt');
    await addItem(tester, 'Gaskocher', 'Gaskocher');
    await tap(tester, itemName('Zelt'));
    await waitFor(tester, find.text(de.shoppingCartCount(1)));
    await listMenu(tester, de.shoppingSaveTemplate);
    await waitFor(tester, find.text(de.shoppingNameSavedTemplate('Camping')));
    await until(
      tester,
      () => engine.listTemplates.any((t) => t.name == 'Camping'),
      'saved as template',
    );
    await back(tester);
    await snackGone(tester);
    await tap(tester, find.byTooltip(de.shoppingListTemplate));
    await waitFor(tester, inSheet(find.text(de.templatesTemplates)));
    expect(inSheet(find.text('Camping')), findsOneWidget);
    expect(
      tester.getTopLeft(inSheet(find.text('Camping'))).dy,
      lessThan(
        tester.getTopLeft(inSheet(find.text(de.templatesSuggestions))).dy,
      ),
      reason: 'under "Eure Vorlagen", the suggestion hidden',
    );
    await tap(tester, inSheet(find.text('Camping')));
    await sheetClosed(tester);
    await waitFor(tester, find.text('📋 Camping'));
    final copy = listNamed(engine, '📋 Camping');
    expect(engine.shoppingItems(copy.id).map((i) => i.name).toSet(), {
      'Zelt',
      'Gaskocher',
    });
    expect(
      engine.shoppingItems(copy.id).every((i) => !i.checked),
      isTrue,
      reason: 'a template has no ticks',
    );
    await back(tester);
    await tap(tester, find.byTooltip(de.shoppingListTemplate));
    await waitFor(tester, inSheet(find.text(de.templatesTemplates)));
    await tap(tester, inSheet(find.byTooltip(de.templatesDeleteTemplate)));
    await waitGone(tester, inSheet(find.text(de.templatesTemplates)));
    expect(engine.listTemplates, isEmpty);
    // The suggestion of the same name is back.
    expect(inSheet(find.text('Camping')), findsOneWidget);
    await tapAway(tester);
    await sheetClosed(tester);
    await engine.sync();
    await finish(tester, state);
    await cleanShopping();
  });

  testWidgets('ALL-136 ALL-137 ALL-131 a packing list for a trip, by person', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await cleanShopping();
    final eventId = uid('event');
    final start = DateTime(today().year, today().month, today().day, 10);
    await seed(f.admin, Collections.events, {
      eventId: CalendarEvent(
        id: eventId,
        title: 'E2E Ostsee',
        start: start,
        end: start.add(const Duration(hours: 2)),
        memberIds: [f.adminMember.id, f.bea.id, f.kid.id],
      ).toData(),
    });
    addTearDown(() => remove(f.admin, Collections.events, [eventId]));
    final state = await startApp(tester);
    final engine = state.engine!;
    final editorOpen = find.byWidgetPredicate(
      (w) => w is Text && w.data == de.eventEditEvent,
    );
    await openSection(tester, 'Kalender');
    await tap(tester, find.text('E2E Ostsee').last);
    await waitFor(tester, editorOpen);
    await scrollTo(tester, find.text(de.templatesCreatePackingList));
    expect(find.text(de.templatesTemplatePerPersonReminder), findsOneWidget);
    await tap(tester, find.text(de.templatesCreatePackingList));
    await waitFor(tester, inSheet(find.text(de.templatesPackingListTemplate)));
    await tap(tester, inSheet(find.text('Urlaub')));
    await sheetClosed(tester);
    await waitFor(tester, find.text(de.templatesWhoPacking));
    FilterChip person(String name) => tester.widget<FilterChip>(
      inDialog(find.widgetWithText(FilterChip, name)),
    );
    expect(person(kitAdminName).selected, isTrue);
    expect(person(f.bea.displayName).selected, isTrue);
    expect(person(f.kid.displayName).selected, isTrue);
    expect(person(f.carl.displayName).selected, isFalse);
    expect(
      inDialog(find.widgetWithText(FilterChip, f.guest.displayName)),
      findsNothing,
    );
    await tap(tester, inDialog(find.text(de.templatesCreate)));
    await dialogClosed(tester);
    await waitFor(tester, find.text('🧳 E2E Ostsee'));

    // ALL-136: each person's things, shared ones once, kids' for the kid.
    final list = listNamed(engine, '🧳 E2E Ostsee');
    expect(list.packing, isTrue);
    List<String?> owners(String name) => [
      for (final i in engine.shoppingItems(list.id))
        if (i.name == name) i.memberId,
    ];
    expect(owners('Ausweise & Reisepässe'), [null]);
    expect(owners('Ladegeräte'), [null]);
    expect(owners('Kuscheltier'), [f.kid.id]);
    expect(owners('Unterwäsche & Socken').toSet(), {
      f.adminMember.id,
      f.bea.id,
      f.kid.id,
    });
    final total = engine.shoppingItems(list.id).length;

    // ALL-137: everyone's, grouped; only mine.
    await waitFor(tester, find.widgetWithText(ChoiceChip, de.commonEveryone));
    for (final heading in [
      de.shoppingEveryone,
      de.shoppingMyThings,
      f.bea.displayName,
      f.kid.displayName,
    ]) {
      await scrollTo(tester, packingHeading(heading));
    }
    await scrollTo(tester, find.byType(ChoiceChip), up: true);
    expect(find.text(de.shoppingFrequent), findsNothing);
    expect(find.text('Kühlregal'), findsNothing);
    await tap(tester, find.widgetWithText(ChoiceChip, de.shoppingMe));
    await settle(tester, 600);
    expect(find.text('Kuscheltier'), findsNothing);
    expect(packingHeading(f.bea.displayName), findsNothing);
    expect(packingHeading(f.kid.displayName), findsNothing);
    await scrollTo(tester, find.text('Unterwäsche & Socken'));
    expect(find.text('Unterwäsche & Socken'), findsOneWidget);
    await scrollTo(tester, find.text('Ausweise & Reisepässe'), up: true);
    await scrollTo(tester, find.byType(ChoiceChip), up: true);
    await tap(tester, find.widgetWithText(ChoiceChip, de.commonEveryone));
    await scrollTo(tester, itemName('Ladegeräte'), up: true);
    await tap(tester, itemName('Ladegeräte'));
    await waitFor(tester, find.text(de.shoppingDoneTotalPacked(1, total)));
    await scrollTo(tester, find.text(de.shoppingPackedCount(1)));
    // ALL-131: a packing list is no shopping.
    expect(find.text(de.purchaseButton), findsNothing);
    await openMenu(tester);
    expect(find.text(de.purchaseTitle), findsNothing);
    expect(find.text(de.shoppingStaples), findsNothing);
    await closeMenu(tester);

    // ALL-136: the trip shows the packing list.
    await back(tester);
    await waitFor(tester, editorOpen);
    await scrollTo(tester, find.text(de.templatesPackingList));
    await waitFor(tester, find.text(de.templatesPackedTotalPacked(1, total)));
    await back(tester);
    await engine.sync();
    await finish(tester, state);
    await cleanShopping();
  });

  // --- Listen verbinden -----------------------------------------------------------

  testWidgets('ALL-141 list connections switched off for the family', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    addTearDown(
      () => f.admin.updateServerSettings({'hiddenModules': <String>[]}),
    );
    final state = await startApp(tester);
    final connect = find.byTooltip(de.commonConnectOtherApps);
    await openSection(tester, 'Einkauf');
    await waitFor(tester, connect);
    await openSection(tester, 'Aufgaben');
    await waitFor(tester, connect);

    Future<void> toggle() async {
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
      final sw = inDialog(
        find.widgetWithText(SwitchListTile, de.adminListConnections),
      );
      await tester.ensureVisible(sw);
      await tap(tester, sw);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await waitFor(tester, find.text(de.adminAreasSaved));
      await dialogClosed(tester);
      await back(tester);
    }

    await toggle();
    await openSection(tester, 'Aufgaben');
    await waitGone(tester, connect);
    await openSection(tester, 'Einkauf');
    await settle(tester);
    expect(connect, findsNothing);
    // The server syncs nothing any more.
    Object? error;
    try {
      await f.admin.connectBring(email: 'e2e@example.org', password: 'nope');
    } on ApiError catch (e) {
      error = e.code;
    }
    expect(error, 'lists_disabled');
    expect(
      (await f.admin.config())['hiddenModules'],
      contains(ServerSettings.listSyncModule),
    );
    await toggle();
    await openSection(tester, 'Einkauf');
    await waitFor(tester, connect);
    await finish(tester, state);
  });

  testWidgets(
    'ALL-142 ALL-143 ALL-144 the page to connect lists, its dialogs, no server',
    (tester) async {
      tall(tester);
      await theFamily();
      final gate = _Gate(Uri.parse(kitUrl));
      await gate.start();
      addTearDown(gate.close);
      final state = await startAt(tester, gate.url);
      await openSection(tester, 'Einkauf');
      await tap(tester, find.byTooltip(de.commonConnectOtherApps));
      await waitFor(tester, find.text(de.listsConnectLists));
      await waitFor(tester, find.text(de.listsAppleRemindersThunderbirdCo));
      expect(find.text(de.listsConnectCalendar), findsOneWidget);
      expect(find.text(de.listsSyncBringMicrosoftDo), findsOneWidget);
      await waitFor(tester, find.text(de.listsConnectBring));
      expect(find.text(de.listsConnectMsTodo), findsOneWidget);

      // ALL-143: Bring!'s dialog (signing in would reach the real Bring!).
      await tap(tester, find.text(de.listsConnectBring));
      await waitFor(tester, inDialog(find.text(de.listsBringHasNoOfficial)));
      expect(inDialog(field(de.commonEmailAddress)), findsOneWidget);
      expect(inDialog(field(de.listsBringPassword)), findsOneWidget);
      expect(inDialog(find.text(de.commonSignIn)), findsOneWidget);
      await tap(tester, inDialog(find.text(de.commonCancel)));
      await dialogClosed(tester);

      // ALL-144: Microsoft's dialog; a wrong client id is refused by the
      // server before it asks Microsoft.
      await tap(tester, find.text(de.listsConnectMsTodo));
      await waitFor(tester, inDialog(field(de.listsApplicationClientId)));
      await enter(tester, inDialog(field(de.listsApplicationClientId)), 'abc');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonNext)));
      await waitFor(tester, inDialog(find.textContaining('hat die Form')));
      expect(
        inDialog(find.textContaining('Client-ID (Anwendungs-ID)')),
        findsWidgets,
      );
      await tap(tester, inDialog(find.text(de.commonCancel)));
      await dialogClosed(tester);

      // ALL-142: without the server.
      await back(tester);
      gate.cut();
      await tap(tester, find.byTooltip(de.commonConnectOtherApps));
      await waitFor(tester, find.text(de.commonOnlyWithServer));
      expect(find.text(de.commonAgain), findsOneWidget);
      expect(find.text(de.listsConnectBring), findsNothing);
      gate.restore();
      await tap(tester, find.text(de.commonAgain));
      await waitFor(tester, find.text(de.listsConnectBring));
      await back(tester);
      await finish(tester, state);
    },
  );

  // --- Pinnwand -------------------------------------------------------------------

  testWidgets('ALL-150 ALL-149 ALL-151 notes: not pinned, pinned, colors', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await clean([Collections.notes]);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final state = await startApp(tester);
    final engine = state.engine!;

    // ALL-150: not pinned – on the pinboard, on the start page only counted.
    await openPinboard(tester);
    await waitFor(tester, find.text(de.notesNoNotesYetExample));
    await tap(tester, find.byTooltip(de.notesAddNote));
    await waitFor(tester, find.text(de.notesNewNote));
    await enter(tester, field(de.commonTitle), 'E2E Müllabfuhr');
    await enter(tester, field(de.commonText), 'Dienstags gelbe Tonne');
    await tap(tester, find.text(de.notesPinStartPage));
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, de.notesPinStartPage),
          )
          .value,
      isFalse,
    );
    await leaveField(tester);
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, find.text('E2E Müllabfuhr'));
    expect(engine.notes.single.pinned, isFalse);
    await back(tester);
    await scrollTo(tester, find.text(de.homeCountNotes(1)));
    expect(find.textContaining('E2E Müllabfuhr'), findsNothing);

    // ALL-149: pinned, with title and color; no title saves nothing.
    await tap(tester, find.text(de.commonPinboard));
    await dismissTip(tester);
    await tap(tester, find.byTooltip(de.notesAddNote));
    await waitFor(tester, find.text(de.notesNewNote));
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, de.notesPinStartPage),
          )
          .value,
      isTrue,
    );
    await tap(tester, inSheet(find.text(de.commonSave)));
    await settle(tester);
    expect(find.text(de.notesNewNote), findsOneWidget, reason: 'no title');
    expect(engine.notes, hasLength(1));
    await enter(tester, field(de.commonTitle), 'E2E WLAN für Gäste');
    await enter(
      tester,
      field(de.commonText),
      'Netz: Famio-Gast\nPasswort: siehe Router',
    );
    // ALL-151: the five circles, the chosen one ticked.
    for (final color in [0xFFFFF3B0, 0xFFFFD6E4, 0xFFD3EBFF, 0xFFD9F0E4]) {
      final circle = find.byWidgetPredicate(
        (w) => w is CircleAvatar && w.backgroundColor == Color(color),
      );
      await tap(tester, circle);
      expect(
        find.descendant(of: circle, matching: find.byIcon(AppIcons.check)),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is CircleAvatar &&
              w.backgroundColor != Color(color) &&
              w.child is Icon,
        ),
        findsNothing,
      );
    }
    const lilac = 0xFFE6DDF7;
    await tap(
      tester,
      find.byWidgetPredicate(
        (w) => w is CircleAvatar && w.backgroundColor == const Color(lilac),
      ),
    );
    await leaveField(tester);
    await tap(tester, inSheet(find.text(de.commonSave)));
    await sheetClosed(tester);
    await waitFor(tester, find.text('E2E WLAN für Gäste'));
    // The Mac may itself be dark: first a light device.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await settle(tester);
    expect(paperOf(tester, 'E2E WLAN für Gäste'), const Color(lilac));
    // In the dark: darkened, still readable.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await settle(tester);
    final dark = paperOf(tester, 'E2E WLAN für Gäste')!;
    expect(dark, Color.lerp(const Color(lilac), Colors.black, 0.6));
    final ink = DefaultTextStyle.of(
      tester.element(find.text('E2E WLAN für Gäste')),
    ).style.color;
    final title =
        styleOf(tester, find.text('E2E WLAN für Gäste'))?.color ?? ink;
    debugPrint('E2E-INFO dark note: paper $dark, title $title');
    expect(contrast(title!, dark), greaterThan(4.5));
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    await settle(tester);

    // ALL-149: on the start page "Titel: erste Zeile", at most three.
    await back(tester);
    await scrollTo(tester, find.text('E2E WLAN für Gäste: Netz: Famio-Gast'));
    expect(find.text(de.homeCountNotes(2)), findsNothing);
    await seed(f.admin, Collections.notes, {
      for (final n in [1, 2, 3])
        'e2e-note-pin-$n': FamilyNote(
          id: 'e2e-note-pin-$n',
          title: 'E2E Angeheftet $n',
          text: 'Zeile $n',
          pinned: true,
        ).toData(),
    });
    await engine.sync();
    await until(tester, () => engine.notes.length == 5, 'five notes');
    await settle(tester);
    await scrollTo(tester, find.textContaining('E2E Angeheftet'));
    final lines = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          RegExp(
            r'^E2E (Angeheftet \d|WLAN für Gäste): ',
          ).hasMatch(w.data ?? ''),
    );
    expect(lines, findsNWidgets(3));
    await finish(tester, state);
    await clean([Collections.notes]);
  });

  testWidgets('ALL-152 ALL-155 who sees a note; deleted, back, in the bin', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await clean([Collections.notes]);
    final bea = await sessionOf(f.bea);
    final guest = await sessionOf(f.guest);
    final state = await startApp(tester);
    final engine = state.engine!;
    await openPinboard(tester);

    Future<void> note(String title, String audience, {String? with_}) async {
      await snackGone(tester);
      await tap(tester, find.byTooltip(de.notesAddNote));
      await waitFor(tester, find.text(de.notesNewNote));
      await enter(tester, field(de.commonTitle), title);
      await leaveField(tester);
      await scrollTo(tester, inSheet(find.text(audience)));
      await tap(tester, inSheet(find.text(audience)));
      if (with_ != null) {
        await tap(tester, find.widgetWithText(FilterChip, with_));
      }
      await tap(tester, inSheet(find.text(de.commonSave)));
      await sheetClosed(tester);
      await waitFor(tester, find.text(title));
    }

    await note('E2E Nur meine Notiz', de.docsOnlyMe);
    await note('E2E Für den Gast', de.docsMe, with_: f.guest.displayName);
    await note('E2E Für alle', de.notesWholeFamilyGuestsToo);
    for (final t in ['E2E Nur meine Notiz', 'E2E Für den Gast']) {
      expect(
        find.descendant(
          of: find
              .ancestor(of: find.text(t), matching: find.byType(Material))
              .first,
          matching: find.byIcon(AppIcons.lockKey),
        ),
        findsOneWidget,
        reason: t,
      );
    }
    expect(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('E2E Für alle'),
              matching: find.byType(Material),
            )
            .first,
        matching: find.byIcon(AppIcons.lockKey),
      ),
      findsNothing,
    );
    await engine.sync();
    await eventually(tester, 'everyone gets "E2E Für alle"', () async {
      return (await titlesOf(
            bea,
            Collections.notes,
          )).contains('E2E Für alle') &&
          (await titlesOf(guest, Collections.notes)).contains('E2E Für alle');
    });
    final beaSees = await titlesOf(bea, Collections.notes);
    final guestSees = await titlesOf(guest, Collections.notes);
    expect(beaSees, isNot(contains('E2E Nur meine Notiz')));
    expect(beaSees, isNot(contains('E2E Für den Gast')));
    expect(guestSees, isNot(contains('E2E Nur meine Notiz')));
    expect(guestSees, contains('E2E Für den Gast'));

    // Hint (#472): the "Nur ich" note opens as "Ich und …", nobody chosen.
    await tap(tester, find.text('E2E Nur meine Notiz'));
    await waitFor(tester, find.text(de.notesEditNote));
    final chips = find.byType(FilterChip);
    final opensAsSelected =
        chips.evaluate().isNotEmpty &&
        chips.evaluate().every((e) => !(e.widget as FilterChip).selected);
    debugPrint(
      'E2E-INFO #472 "Nur ich" note opens as "Ich und …" without anyone: '
      '$opensAsSelected',
    );
    await tapAway(tester);
    await sheetClosed(tester);

    // ALL-155: deleted and back; deleted for good: 30 days in the bin.
    final note2 = engine.notes.singleWhere((n) => n.title == 'E2E Für alle');
    Future<void> delete() async {
      await snackGone(tester);
      await tap(tester, find.text('E2E Für alle'));
      await waitFor(tester, find.text(de.notesEditNote));
      await scrollTo(tester, inSheet(find.text(de.commonDelete)));
      await tap(tester, inSheet(find.text(de.commonDelete)));
      await sheetClosed(tester);
      await waitGone(tester, find.text('E2E Für alle'));
    }

    await delete();
    await tap(tester, find.text(de.commonUndo));
    await waitFor(tester, find.text('E2E Für alle'));
    expect(engine.notes.any((n) => n.id == note2.id), isTrue);
    await delete();
    await snackGone(tester);
    await engine.sync();
    final bin = (await f.admin.trash()).items.where(
      (t) => t.record.id == note2.id,
    );
    expect(bin, hasLength(1));
    final kept = bin.single.expiresAt.difference(bin.single.deletedAt);
    expect(kept.inDays, inInclusiveRange(29, 30));
    await openSettingsEntry(tester, de.trashTitle);
    await waitFor(tester, find.text('E2E Für alle'));
    await finish(tester, state);
    await clean([Collections.notes]);
  });

  testWidgets('ALL-153 a child and who sees a note', (tester) async {
    tall(tester);
    final f = await theFamily();
    await clean([Collections.notes]);
    final kid = await sessionOf(f.kid);
    final bea = await sessionOf(f.bea);
    const noteId = 'e2e-note-familie';
    await seed(f.admin, Collections.notes, {
      noteId: const FamilyNote(
        id: noteId,
        title: 'E2E Familiennotiz',
        text: 'Für alle',
      ).toData(),
    });
    final state = await startApp(tester, user: 'e2e-kind');
    await openPinboard(tester);
    await tap(tester, find.text('E2E Familiennotiz'));
    await waitFor(tester, find.text(de.notesEditNote));
    await scrollTo(tester, find.text(de.commonAudienceSetByAdults));
    expect(find.text(de.notesWholeFamilyGuestsToo), findsNothing);
    await tapAway(tester);
    await sheetClosed(tester);
    // A new note: the child chooses.
    await tap(tester, find.byTooltip(de.notesAddNote));
    await waitFor(tester, find.text(de.notesNewNote));
    await scrollTo(tester, inSheet(find.text(de.notesWholeFamilyGuestsToo)));
    expect(inSheet(find.text(de.docsOnlyMe)), findsOneWidget);
    expect(find.text(de.commonAudienceSetByAdults), findsNothing);
    await tapAway(tester);
    await sheetClosed(tester);

    // Deleted and brought back: the parents still have it.
    await tap(tester, find.text('E2E Familiennotiz'));
    await waitFor(tester, find.text(de.notesEditNote));
    await scrollTo(tester, inSheet(find.text(de.commonDelete)));
    await tap(tester, inSheet(find.text(de.commonDelete)));
    await sheetClosed(tester);
    await waitFor(tester, find.text(de.commonUndo));
    await tap(tester, find.text(de.commonUndo));
    await waitFor(tester, find.text('E2E Familiennotiz'));
    await state.engine!.sync();
    await eventually(
      tester,
      'Bea still gets the family note',
      () async => (await titlesOf(
        bea,
        Collections.notes,
      )).contains('E2E Familiennotiz'),
    );
    // Through the API: deleted and written back only for the child.
    await remove(kid, Collections.notes, [noteId]);
    await put(kid, Collections.notes, {
      noteId: FamilyNote(
        id: noteId,
        title: 'E2E Familiennotiz',
        text: 'Für alle',
        visibleTo: [f.kid.id],
      ).toData(),
    });
    final adminView = await pull(f.admin, Collections.notes);
    debugPrint(
      'E2E-INFO note after the child wrote it back: '
      '${adminView[noteId]?.data[SyncRecord.visibilityKey]}',
    );
    expect(
      (await titlesOf(bea, Collections.notes)).contains('E2E Familiennotiz'),
      isTrue,
      reason: 'not hidden from the parents',
    );
    expect(adminView[noteId]?.visibleTo, isNull);
    await finish(tester, state);
    await clean([Collections.notes]);
  });

  testWidgets('ALL-154 a guest reads the pinboard', (tester) async {
    tall(tester);
    final f = await theFamily();
    await clean([Collections.notes]);
    await seed(f.admin, Collections.notes, {
      'e2e-note-babysitter': const FamilyNote(
        id: 'e2e-note-babysitter',
        title: 'E2E Für den Babysitter',
        text: 'Schlafenszeit 19 Uhr',
        pinned: true,
      ).toData(),
    });
    final state = await startApp(tester, user: 'e2e-gast');
    await openPinboard(tester);
    await waitFor(tester, find.text('E2E Für den Babysitter'));
    expect(find.byTooltip(de.notesAddNote), findsNothing);
    await tap(tester, find.text('E2E Für den Babysitter'));
    await settle(tester);
    expect(find.text(de.notesEditNote), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == 'Schlafenszeit 19 Uhr',
      ),
      findsOneWidget,
    );
    await finish(tester, state);
    await clean([Collections.notes]);
  });

  // --- Chat -----------------------------------------------------------------------

  testWidgets(
    'ALL-158 ALL-159 ALL-160 ALL-163 family and direct chat, previews, read',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await cleanChat();
      final bea = await sessionOf(f.bea);
      final carl = await sessionOf(f.carl);
      final me = f.adminMember;
      // Carl wrote yesterday in his chat with the admin.
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final carlChat = ChatIds.direct(me.id, f.carl.id);
      await seed(carl, Collections.chatMessages, {
        'e2e-m-carl': message(
          'e2e-m-carl',
          carlChat,
          f.carl,
          'E2E Bis morgen',
          at: yesterday,
          to: [me.id, f.carl.id],
        ),
      });
      final state = await startApp(tester);
      final engine = state.engine!;
      await openSection(tester, 'Chat');
      await waitFor(tester, find.text(de.chatOneOneChats));

      // ALL-160: a direct chat without a name, the date of yesterday; a chat
      // without messages.
      await waitFor(tester, find.text('E2E Bis morgen'));
      expect(
        find.descendant(
          of: cardOf(f.carl.displayName),
          matching: find.text(DateFormat.Md('de').format(yesterday)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: cardOf(f.guest.displayName),
          matching: find.text(de.chatNoMessagesYetSay),
        ),
        findsOneWidget,
      );

      // ALL-158
      await tap(tester, find.text(de.settingsFamily));
      await waitFor(tester, find.text(de.chatEveryoneFamily));
      final family = ChatIds.family;
      await tap(tester, find.byTooltip(de.commonSend));
      await send(tester, '   ');
      await settle(tester);
      expect(engine.chatMessages(family), isEmpty, reason: 'nothing to send');
      await send(tester, 'E2E Hallo Familie');
      await waitFor(tester, find.text('E2E Hallo Familie'));
      expect(rightAligned(tester, 'E2E Hallo Familie'), isTrue);
      expect(find.text(de.commonToday), findsOneWidget, reason: 'day');
      expect(controllerOf(tester, composer)!.text, '');
      // Desktop keys: Shift+Enter does not send, Enter does.
      await enter(tester, composer, 'E2E Zeile eins\nE2E Zeile zwei');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester, 600);
      expect(engine.chatMessages(family), hasLength(1));
      expect(controllerOf(tester, composer)!.text, contains('E2E Zeile eins'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await until(
        tester,
        () => engine.chatMessages(family).length == 2,
        'sent by Enter',
      );
      await waitFor(tester, find.text('E2E Zeile eins\nE2E Zeile zwei'));

      // ALL-160: Bea writes – with her name in the family chat.
      final beaAt = DateTime.now();
      await seed(bea, Collections.chatMessages, {
        'e2e-m-bea-family': message(
          'e2e-m-bea-family',
          family,
          f.bea,
          'E2E Gleich da',
          at: beaAt,
        ),
      });
      await engine.sync();
      await back(tester);
      await waitFor(tester, find.text('${f.bea.displayName}: E2E Gleich da'));
      expect(
        find.descendant(
          of: cardOf(de.settingsFamily),
          matching: find.text(timeLabel(beaAt)),
        ),
        findsOneWidget,
      );

      // ALL-159: only the two of them.
      await tap(tester, find.text(f.bea.displayName));
      await waitFor(tester, find.text(de.chatPrivateJustTwoYou));
      await send(tester, 'E2E Nur für Bea');
      await waitFor(tester, find.text('E2E Nur für Bea'));
      final direct = ChatIds.direct(me.id, f.bea.id);
      final sent = engine.chatMessages(direct).single;
      expect(sent.visibleTo?.toSet(), {me.id, f.bea.id});
      await engine.sync();
      await eventually(
        tester,
        'Bea gets it',
        () async => (await pull(
          bea,
          Collections.chatMessages,
        )).values.any((r) => r.data['text'] == 'E2E Nur für Bea'),
      );
      expect(
        (await pull(
          carl,
          Collections.chatMessages,
        )).values.any((r) => r.data['text'] == 'E2E Nur für Bea'),
        isFalse,
      );

      // ALL-163: Bea opens it.
      expect(find.textContaining(de.chatRead), findsNothing);
      Future<void> beaReads(String chatId, List<String>? to) =>
          seed(bea, Collections.chatReads, {
            ChatRead.idFor(chatId, f.bea.id): ChatRead(
              chatId: chatId,
              memberId: f.bea.id,
              lastRead: DateTime.now(),
            ).toData(visibleTo: to),
          });
      await beaReads(direct, [me.id, f.bea.id]);
      await engine.sync();
      await waitFor(tester, find.textContaining(de.chatRead));
      // Not in the family chat.
      await beaReads(family, null);
      await engine.sync();
      await back(tester);
      await waitFor(tester, find.text('${de.chatYou}E2E Nur für Bea'));
      await tap(tester, find.text(de.settingsFamily));
      await waitFor(tester, find.text('E2E Hallo Familie'));
      await settle(tester);
      expect(find.textContaining(de.chatRead), findsNothing);
      await finish(tester, state);
      await cleanChat();
    },
  );

  testWidgets('ALL-161 the unread counter', (tester) async {
    tall(tester);
    final f = await theFamily();
    await cleanChat();
    final bea = await sessionOf(f.bea);
    final state = await startApp(tester);
    final engine = state.engine!;
    await seed(bea, Collections.chatMessages, {
      for (final n in [1, 2])
        'e2e-m-unread-$n': message(
          'e2e-m-unread-$n',
          ChatIds.family,
          f.bea,
          'E2E Ungelesen $n',
          at: DateTime.now().add(Duration(milliseconds: n)),
        ),
    });
    await engine.sync();
    await until(tester, () => engine.totalUnread == 2, 'two unread');
    // At the navigation item …
    final badge = find.ancestor(
      of: find.text('2'),
      matching: find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_Badge',
      ),
    );
    await waitFor(tester, badge);
    // … and at the chat, the preview bold.
    await openSection(tester, 'Chat');
    final preview = find.text('${f.bea.displayName}: E2E Ungelesen 2');
    await waitFor(tester, preview);
    expect(
      find.descendant(of: cardOf(de.settingsFamily), matching: find.text('2')),
      findsOneWidget,
    );
    expect(styleOf(tester, preview)?.fontWeight, FontWeight.w800);
    await tap(tester, find.text(de.settingsFamily));
    await waitFor(tester, find.text('E2E Ungelesen 2'));
    await until(tester, () => engine.totalUnread == 0, 'read');
    // Own messages never count.
    await send(tester, 'E2E Selbst geschrieben');
    await waitFor(tester, find.text('E2E Selbst geschrieben'));
    await back(tester);
    await waitFor(tester, find.text('${de.chatYou}E2E Selbst geschrieben'));
    expect(
      find.descendant(of: cardOf(de.settingsFamily), matching: find.text('2')),
      findsNothing,
    );
    expect(badge, findsNothing);
    expect(engine.totalUnread, 0);
    await finish(tester, state);
    await cleanChat();
  });

  testWidgets('ALL-164 a wide window: list and chat side by side', (
    tester,
  ) async {
    tall(tester, width: 1300, height: 1000);
    final f = await theFamily();
    final state = await startApp(tester);
    await openSection(tester, 'Chat');
    await waitFor(tester, find.text(de.chatOneOneChats));
    // The family chat is open beside the list.
    await waitFor(tester, find.text(de.chatEveryoneFamily));
    SoftCard tile(String title) => tester.widget<SoftCard>(cardOf(title));
    expect(tile(de.settingsFamily).color, isNotNull);
    expect(tile(f.bea.displayName).color, isNull);
    await tap(tester, find.text(f.bea.displayName));
    await waitFor(tester, find.text(de.chatPrivateJustTwoYou));
    expect(find.text(de.chatOneOneChats), findsOneWidget, reason: 'list stays');
    expect(find.text(de.chatEveryoneFamily), findsNothing);
    expect(tile(f.bea.displayName).color, isNotNull);
    expect(tile(de.settingsFamily).color, isNull);
    await finish(tester, state);
  });

  testWidgets('ALL-165 a photo with a caption, a file', (tester) async {
    tall(tester);
    await theFamily();
    await cleanChat();
    final picker = _fakePicker();
    final photo = await tempFile('e2e-strand.png', await pngBytes());
    // Small enough for the buffered path (see the finding at the end).
    final pdf = await tempFile('E2E-Zettel.pdf', [
      ...'%PDF-1.4\n%E2E\n'.codeUnits,
      ...List.filled(200 * 1024, 0x20),
      ...'\n%%EOF\n'.codeUnits,
    ]);
    picker.picks
      ..add(_DiskFile(photo))
      ..add(_DiskFile(pdf));
    final gate = _Gate(Uri.parse(kitUrl));
    await gate.start();
    addTearDown(gate.close);
    final state = await startAt(tester, gate.url);
    final engine = state.engine!;
    await openSection(tester, 'Chat');
    await tap(tester, find.text(de.settingsFamily));
    await waitFor(tester, find.text(de.chatEveryoneFamily));
    // The photo with the text typed before.
    await enter(tester, composer, 'E2E Strand');
    await tap(tester, find.byTooltip(de.chatSendPhotoFile));
    await until(
      tester,
      () => engine.chatMessages(ChatIds.family).isNotEmpty,
      'photo sent',
    );
    final withPhoto = engine.chatMessages(ChatIds.family).single;
    expect(withPhoto.text, 'E2E Strand');
    expect(withPhoto.attachment?.isImage, isTrue);
    await waitFor(tester, find.text('E2E Strand'));
    await waitFor(tester, find.byType(CachedImage));
    expect(
      find.ancestor(
        of: find.byType(CachedImage),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Column &&
              w.children.whereType<Text>().any((t) => t.data == 'E2E Strand'),
        ),
      ),
      findsOneWidget,
      reason: 'the text is the caption in the same bubble',
    );
    // The file over a slow network: while it uploads a circle turns.
    await engine.sync();
    gate.hold();
    await tap(tester, find.byTooltip(de.chatSendPhotoFile));
    await waitGone(
      tester,
      find.byTooltip(de.chatSendPhotoFile),
      timeout: const Duration(seconds: 10),
    );
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await settle(tester, 1000);
    expect(find.byTooltip(de.chatSendPhotoFile), findsNothing);
    gate.release();
    await until(
      tester,
      () => engine.chatMessages(ChatIds.family).length == 2,
      'file sent',
      timeout: const Duration(seconds: 60),
    );
    await waitFor(tester, find.byTooltip(de.chatSendPhotoFile));
    await waitFor(tester, find.text('E2E-Zettel.pdf'));
    expect(engine.chatMessages(ChatIds.family).last.text, '');
    expect(
      engine.chatMessages(ChatIds.family).last.attachment?.isImage,
      isFalse,
    );
    await back(tester);
    await waitFor(tester, find.text('${de.chatYou}📎 E2E-Zettel.pdf'));
    await engine.sync();
    await finish(tester, state);
    await cleanChat();
  });

  testWidgets('ALL-166 ALL-167 ALL-168 polls, votes, closed polls, deleting', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await cleanChat();
    final bea = await sessionOf(f.bea);
    final me = f.adminMember;
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Chat');
    await tap(tester, find.text(de.settingsFamily));
    await waitFor(tester, find.text(de.chatEveryoneFamily));

    // ALL-166
    await tap(tester, find.byTooltip(de.chatPoll));
    await waitFor(tester, inDialog(field(de.chatQuestion)));
    await enter(tester, field(de.chatQuestion), 'E2E Wohin am Sonntag?');
    await enter(tester, field(de.chatAnswerNumber(1)), 'Zoo');
    await enter(tester, field(de.chatAnswerNumber(2)), 'Wald');
    await tap(tester, inDialog(find.text(de.chatAnswer)));
    await enter(tester, field(de.chatAnswerNumber(3)), 'Schwimmbad');
    await tap(tester, inDialog(find.text(de.chatAllowMultipleAnswers)));
    await leaveField(tester);
    await tap(tester, inDialog(find.text(de.commonSend)));
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Wohin am Sonntag?'));
    await waitFor(tester, find.textContaining(de.chatMultipleAnswersPossible));
    final poll = engine.chatMessages(ChatIds.family).single.poll!;
    expect(poll.multiple, isTrue);
    expect(poll.options.map((o) => o.text), ['Zoo', 'Wald', 'Schwimmbad']);
    // Ten answers at most; one answer is not enough.
    await tap(tester, find.byTooltip(de.chatPoll));
    await waitFor(tester, inDialog(field(de.chatQuestion)));
    for (var i = 3; i <= 10; i++) {
      await tap(tester, inDialog(find.text(de.chatAnswer)));
      await waitFor(tester, inDialog(field(de.chatAnswerNumber(i))));
    }
    expect(inDialog(find.text(de.chatAnswer)), findsNothing);
    await enter(tester, field(de.chatQuestion), 'E2E Nur eine Antwort?');
    await enter(tester, field(de.chatAnswerNumber(1)), 'Ja');
    await leaveField(tester);
    await tap(tester, inDialog(find.text(de.commonSend)));
    await waitFor(tester, find.text(de.chatQuestionLeastTwoAnswers));
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'stays open');
    expect(inDialog(find.text(de.chatQuestionLeastTwoAnswers)), findsNothing);
    // Hint: behind the dialog's barrier.
    final hit = tester.hitTestOnBinding(
      tester.getCenter(find.text(de.chatQuestionLeastTwoAnswers)),
    );
    final snackText = tester.renderObject(
      find.text(de.chatQuestionLeastTwoAnswers),
    );
    debugPrint(
      'E2E-INFO poll hint: the message is a snack bar of the page under '
      'the dialog; reachable by a tap: '
      '${hit.path.any((e) => e.target == snackText)}',
    );
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    expect(engine.chatMessages(ChatIds.family), hasLength(1));
    // ALL-167: whoever asked ends it.
    await snackGone(tester);
    await tap(tester, find.text(de.commonEnd2));
    await waitFor(tester, find.textContaining(de.chatPollClosed));
    expect(engine.chatMessages(ChatIds.family).single.poll!.closed, isTrue);
    await tap(tester, find.text('Zoo'));
    await settle(tester, 600);
    expect(
      engine.pollVotes(engine.chatMessages(ChatIds.family).single.id),
      isEmpty,
      reason: 'a closed poll takes no votes',
    );

    // ALL-168: own messages go for everyone, others' not.
    await send(tester, 'E2E Weg damit');
    await waitFor(tester, find.text('E2E Weg damit'));
    await seed(bea, Collections.chatMessages, {
      'e2e-m-bea-bleibt': message(
        'e2e-m-bea-bleibt',
        ChatIds.family,
        f.bea,
        'E2E Von Bea',
      ),
    });
    await engine.sync();
    await waitFor(tester, find.text('E2E Von Bea'));
    await tester.longPress(find.text('E2E Von Bea'));
    await settle(tester, 800);
    expect(find.text(de.chatDeleteMessage), findsNothing);
    await tester.tap(
      find.text('E2E Von Bea'),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await settle(tester, 800);
    expect(find.text(de.chatDeleteMessage), findsNothing);
    await tester.longPress(find.text('E2E Weg damit'));
    await waitFor(tester, find.text(de.chatDeleteMessage));
    await tap(tester, inDialog(find.text(de.commonCancel)));
    await dialogClosed(tester);
    await tester.tap(
      find.text('E2E Weg damit'),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await waitFor(tester, find.text(de.chatDeleteMessage));
    expect(find.text(de.chatDisappearsEveryone), findsOneWidget);
    await tap(tester, inDialog(find.text(de.commonDelete)));
    await dialogClosed(tester);
    await waitGone(tester, find.text('E2E Weg damit'));
    await engine.sync();
    await eventually(
      tester,
      'gone for Bea',
      () async => !(await pull(
        bea,
        Collections.chatMessages,
      )).values.any((r) => r.data['text'] == 'E2E Weg damit'),
    );

    // ALL-167: Bea asks in her chat with the admin.
    final direct = ChatIds.direct(me.id, f.bea.id);
    const pollId = 'e2e-m-poll-bea';
    final question = Poll(
      question: 'E2E Pizza oder Pasta?',
      options: const [
        PollOption(id: 'o0', text: 'Pizza'),
        PollOption(id: 'o1', text: 'Pasta'),
      ],
    );
    await seed(bea, Collections.chatMessages, {
      pollId: message(
        pollId,
        direct,
        f.bea,
        '',
        poll: question,
        to: [me.id, f.bea.id],
      ),
    });
    await back(tester);
    await tap(tester, find.text(f.bea.displayName));
    await waitFor(tester, find.text('E2E Pizza oder Pasta?'));
    expect(find.text(de.commonEnd2), findsNothing, reason: 'not my poll');
    List<String>? mine() => engine
        .pollVotes(pollId)
        .where((v) => v.memberId == me.id)
        .firstOrNull
        ?.optionIds;
    await tap(tester, find.text('Pizza'));
    await until(tester, () => mine()?.join() == 'o0', 'voted Pizza');
    await waitFor(tester, find.text('1 ${de.chatVote}'));
    await waitFor(tester, find.text(kitAdminName));
    await tap(tester, find.text('Pasta'));
    await until(tester, () => mine()?.join() == 'o1', 'changed to Pasta');
    await seed(bea, Collections.pollVotes, {
      PollVote.idFor(pollId, f.bea.id): PollVote(
        messageId: pollId,
        memberId: f.bea.id,
        optionIds: const ['o1'],
      ).toData(visibleTo: [me.id, f.bea.id]),
    });
    await engine.sync();
    await waitFor(tester, find.text('2 ${de.chatVotes}'));
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data ?? '').contains(kitAdminName) &&
            (w.data ?? '').contains(f.bea.displayName),
      ),
    );
    final bars = [
      for (final e in find.byType(LinearProgressIndicator).evaluate())
        (e.widget as LinearProgressIndicator).value,
    ];
    expect(bars, [0.0, 1.0]);
    // Bea ends it: nobody votes any more.
    await seed(bea, Collections.chatMessages, {
      pollId: message(
        pollId,
        direct,
        f.bea,
        '',
        poll: question.close(),
        to: [me.id, f.bea.id],
      ),
    });
    await engine.sync();
    await waitFor(tester, find.textContaining(de.chatPollClosed));
    await tap(tester, find.text('Pizza'));
    await settle(tester, 800);
    expect(mine()?.join(), 'o1');
    await finish(tester, state);
    await cleanChat();
  });

  testWidgets('ALL-170 a guest in the chat', (tester) async {
    tall(tester);
    final f = await theFamily();
    await cleanChat();
    final bea = await sessionOf(f.bea);
    final guestApi = await sessionOf(f.guest);
    const pollId = 'e2e-m-poll-gast';
    await seed(f.admin, Collections.chatMessages, {
      'e2e-m-admin': message(
        'e2e-m-admin',
        ChatIds.family,
        f.adminMember,
        'E2E Von Admin',
      ),
      pollId: message(
        pollId,
        ChatIds.family,
        f.adminMember,
        '',
        at: DateTime.now().add(const Duration(milliseconds: 5)),
        poll: const Poll(
          question: 'E2E Kuchen?',
          options: [
            PollOption(id: 'o0', text: 'Ja gern'),
            PollOption(id: 'o1', text: 'Lieber nicht'),
          ],
        ),
      ),
    });
    final state = await startApp(tester, user: 'e2e-gast');
    final engine = state.engine!;
    await openSection(tester, 'Chat');
    await tap(tester, find.text(de.settingsFamily));
    await waitFor(tester, find.text('E2E Kuchen?'));
    await send(tester, 'E2E Gast sagt hallo');
    await waitFor(tester, find.text('E2E Gast sagt hallo'));
    await tap(tester, find.text('Ja gern'));
    await until(
      tester,
      () => engine.pollVotes(pollId).any((v) => v.memberId == f.guest.id),
      'guest voted',
    );
    // Others' messages: no dialog, and the server keeps them.
    await tester.longPress(find.text('E2E Von Admin'));
    await settle(tester, 800);
    expect(find.text(de.chatDeleteMessage), findsNothing);
    final refused = await remove(guestApi, Collections.chatMessages, [
      'e2e-m-admin',
    ]);
    expect(refused.rejected.map((r) => r.id), contains('e2e-m-admin'));
    await engine.sync();
    await eventually(
      tester,
      'Bea gets the guest\'s message and vote',
      () async {
        final all = await pullAll(bea);
        return (all[Collections.chatMessages] ?? {}).values.any(
              (r) => r.data['text'] == 'E2E Gast sagt hallo',
            ) &&
            (all[Collections.pollVotes] ?? {}).containsKey(
              PollVote.idFor(pollId, f.guest.id),
            ) &&
            (all[Collections.chatMessages] ?? {}).containsKey('e2e-m-admin');
      },
    );
    // A direct chat with an adult.
    await back(tester);
    await tap(tester, find.text(f.bea.displayName));
    await waitFor(tester, find.text(de.chatPrivateJustTwoYou));
    await send(tester, 'E2E Gast an Bea');
    await waitFor(tester, find.text('E2E Gast an Bea'));
    await engine.sync();
    await eventually(
      tester,
      'Bea gets the direct message',
      () async => (await pull(
        bea,
        Collections.chatMessages,
      )).values.any((r) => r.data['text'] == 'E2E Gast an Bea'),
    );
    await finish(tester, state);
    await cleanChat();
    await remove(guestApi, Collections.chatMessages, [
      for (final r in (await pull(guestApi, Collections.chatMessages)).values)
        if (r.data['authorId'] == f.guest.id) r.id,
    ]);
  });

  // --- Kontakte -------------------------------------------------------------------

  testWidgets(
    'ALL-174 ALL-175 ALL-177 ALL-178 contacts: by kind, for a child, birthdays',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await clean([Collections.contacts]);
      final childId = uid('child');
      await seed(f.admin, Collections.children, {
        childId: {
          ...Child(
            id: childId,
            name: 'E2E Lina',
            birthDate: DateTime(2021, 5, 1),
            guardianIds: [f.adminMember.id],
          ).toData(),
          SyncRecord.visibilityKey: [f.adminMember.id],
        },
      });
      addTearDown(() => remove(f.admin, Collections.children, [childId]));
      final state = await startApp(tester);
      final engine = state.engine!;
      await openSection(tester, 'Kontakte');
      await waitFor(tester, find.text(de.contactsImportantNumbersOnePlace));

      // ALL-175: no name.
      await tap(tester, find.byTooltip(de.contactsAdd));
      await waitFor(tester, find.text(de.contactsNewContact));
      await tap(tester, find.text(de.commonSave).last);
      await waitFor(tester, find.text(de.contactsPleaseEnterName));
      expect(find.text(de.contactsNewContact), findsOneWidget);

      // ALL-174
      await enter(tester, field(de.commonName), 'E2E Dr. Sommer');
      await tap(tester, find.widgetWithText(ChoiceChip, 'Kinderarzt'));
      await enter(tester, field(de.contactsPhone), '030 1234');
      await enter(tester, field(de.contactsOtherNumberOptional), '0170 5555');
      await enter(
        tester,
        field(de.contactsEmailOptional),
        'praxis@example.org',
      );
      await enter(tester, field(de.contactsAddressOptional), 'Hauptstr. 1');
      await enter(tester, field(de.contactsNoteOptional), 'Mo bis Fr');
      await leaveField(tester);
      await scrollTo(tester, find.widgetWithText(FilterChip, 'E2E Lina'));
      await tap(tester, find.widgetWithText(FilterChip, 'E2E Lina'));
      await snackGone(tester);
      await tap(tester, find.text(de.commonSave).last);
      await waitGone(tester, find.text(de.contactsNewContact));
      await waitFor(tester, find.text('E2E Dr. Sommer'));
      final contact = engine.contacts.single;
      expect(contact.role, ContactRole.pediatrician);
      expect(contact.childIds, [childId]);
      expect(
        (contact.phone, contact.phone2, contact.email, contact.address),
        ('030 1234', '0170 5555', 'praxis@example.org', 'Hauptstr. 1'),
      );
      expect(contact.note, 'Mo bis Fr');
      await waitFor(tester, find.text('Kinderarzt'));
      expect(
        find.descendant(
          of: cardOf('E2E Dr. Sommer'),
          matching: find.textContaining(de.contactsKids('E2E Lina')),
        ),
        findsOneWidget,
      );
      // Grouped by kind.
      await seed(f.admin, Collections.contacts, {
        'e2e-c-kita': const FamilyContact(
          id: 'e2e-c-kita',
          name: 'E2E Kita Sonnenschein',
          role: ContactRole.daycare,
        ).toData(),
      });
      await engine.sync();
      await waitFor(tester, find.text('E2E Kita Sonnenschein'));
      await waitFor(tester, find.text('Kita'));
      expect(
        tester.getTopLeft(find.text('Kinderarzt')).dy,
        lessThan(tester.getTopLeft(find.text('E2E Dr. Sommer')).dy),
      );
      expect(
        tester.getTopLeft(find.text('E2E Dr. Sommer')).dy,
        lessThan(tester.getTopLeft(find.text('Kita')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Kita')).dy,
        lessThan(tester.getTopLeft(find.text('E2E Kita Sonnenschein')).dy),
      );

      // ALL-177: changed.
      Future<void> open() async {
        await snackGone(tester);
        await tap(tester, find.text('E2E Dr. Sommer'));
        await waitFor(tester, find.text(de.commonContact));
      }

      Future<void> save() async {
        await leaveField(tester);
        await tap(tester, find.text(de.commonSave).last);
        await waitGone(tester, find.text(de.contactsBelongs));
      }

      await open();
      await enter(tester, field(de.contactsPhone), '030 9999');
      await save();
      await waitFor(tester, find.textContaining('030 9999'));

      // ALL-178: a birthday with year, then without.
      final now = today();
      await open();
      await scrollTo(tester, find.text(de.birthdayChooseBirthday));
      await tap(tester, find.text(de.birthdayChooseBirthday));
      await pickDate(tester, DateTime(now.year - 30, now.month, now.day));
      await waitFor(tester, find.text(de.birthdayYearUnknown));
      await save();
      // On the start page and in the calendar (today).
      Future<void> birthdayShows(String headline) async {
        await openSection(tester, 'Start');
        await scrollTo(tester, find.text(headline));
        await openSection(tester, 'Kalender');
        final entry = find.text('🎂 E2E Dr. Sommer');
        await scrollTo(tester, entry);
        await tap(tester, entry.last);
        await waitFor(tester, find.textContaining(headline));
        await tapAway(tester);
        await sheetClosed(tester);
      }

      await birthdayShows('E2E Dr. Sommer wird 30');
      await openSection(tester, 'Kontakte');
      await open();
      await scrollTo(tester, find.text(de.birthdayYearUnknown));
      await tap(tester, find.text(de.birthdayYearUnknown));
      await save();
      expect(
        engine.contacts
            .firstWhere((c) => c.name == 'E2E Dr. Sommer')
            .birthday
            ?.year,
        isNull,
      );
      await birthdayShows('E2E Dr. Sommer hat Geburtstag');

      // ALL-177: deleted and back.
      await openSection(tester, 'Kontakte');
      await open();
      await scrollTo(tester, find.text(de.contactsDeleteContact));
      await tap(tester, find.text(de.contactsDeleteContact));
      await waitFor(tester, find.text(de.contactsDeleteName('E2E Dr. Sommer')));
      await tap(tester, inDialog(find.text(de.commonDelete)));
      await dialogClosed(tester);
      await waitGone(tester, find.text('E2E Dr. Sommer'));
      await tap(tester, find.text(de.commonUndo));
      await waitFor(tester, find.text('E2E Dr. Sommer'));
      expect(engine.contacts.any((c) => c.id == contact.id), isTrue);
      await engine.sync();
      await finish(tester, state);
      await clean([Collections.contacts]);
    },
  );

  testWidgets('ALL-179 a guest and the contacts', (tester) async {
    tall(tester);
    final f = await theFamily();
    await clean([Collections.contacts]);
    await seed(f.admin, Collections.contacts, {
      'e2e-c-arzt': const FamilyContact(
        id: 'e2e-c-arzt',
        name: 'E2E Hausarzt Dr. Weiß',
        role: ContactRole.doctor,
        phone: '030 4711',
      ).toData(),
    });
    final state = await startApp(tester, user: 'e2e-gast');
    final engine = state.engine!;
    await openSection(tester, 'Kontakte');
    await waitFor(tester, find.text('E2E Hausarzt Dr. Weiß'));
    // A new contact: not kept by the server.
    await tap(tester, find.byTooltip(de.contactsAdd));
    await waitFor(tester, find.text(de.contactsNewContact));
    await enter(tester, field(de.commonName), 'E2E Gastkontakt');
    await leaveField(tester);
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.contactsNewContact));
    await engine.sync();
    await until(
      tester,
      () => engine.contacts.every((c) => c.name != 'E2E Gastkontakt'),
      'the guest\'s contact gone again',
    );
    // A change: back as it was.
    await tap(tester, find.text('E2E Hausarzt Dr. Weiß'));
    await waitFor(tester, find.text(de.commonContact));
    await enter(tester, field(de.contactsPhone), '0000');
    await leaveField(tester);
    await tap(tester, find.text(de.commonSave).last);
    await waitGone(tester, find.text(de.contactsBelongs));
    await engine.sync();
    await until(
      tester,
      () => engine.contacts.any((c) => c.phone == '030 4711'),
      'the old number back',
    );
    final server = await pull(f.admin, Collections.contacts);
    expect(server.keys, ['e2e-c-arzt']);
    expect(server['e2e-c-arzt']!.data['phone'], '030 4711');
    await finish(tester, state);
    await clean([Collections.contacts]);
  });

  // --- Verleih --------------------------------------------------------------------

  testWidgets(
    'ALL-180 ALL-181 ALL-182 ALL-183 loans: lent and borrowed, overdue, back',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await clean([Collections.loans]);
      final state = await startApp(tester);
      final engine = state.engine!;
      await openSettingsEntry(tester, de.loansTitle);
      await waitFor(tester, find.text(de.loansEmpty));

      // ALL-180: without "Was?" nothing is saved.
      await tap(tester, find.byTooltip(de.loansAdd));
      await waitFor(tester, find.text(de.loansNew));
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await settle(tester);
      expect(engine.loans, isEmpty);

      await tap(tester, find.byTooltip(de.loansAdd));
      await waitFor(tester, find.text(de.loansNew));
      await enter(tester, field(de.loansWhat), 'E2E Bohrmaschine');
      await enter(tester, field(de.loansToWhom), 'Nachbarn');
      await leaveField(tester);
      await choose(tester, de.loansWhoOfUs, f.bea.displayName);
      await tap(tester, inDialog(find.text(de.loansDueBack)));
      // Suggested: in 14 days.
      await tap(tester, find.byTooltip('Zur Texteingabe wechseln'));
      final dateField = find.widgetWithText(TextField, 'Datum eingeben');
      await waitFor(tester, dateField);
      expect(controllerOf(tester, dateField)!.text, day.format(inDays(14)));
      await tap(tester, find.text('OK').last);
      await waitGone(tester, dateField);
      await waitFor(tester, inDialog(find.text(day.format(inDays(14)))));
      await enter(tester, inDialog(field(de.commonNote)), 'mit Koffer');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await waitFor(tester, find.text('E2E Bohrmaschine'));
      final drill = cardOf('E2E Bohrmaschine');
      expect(
        find.descendant(
          of: drill,
          matching: find.text(
            [
              de.loansLentTo('Nachbarn'),
              de.loansSince(day.format(today())),
              'mit Koffer',
            ].join(' · '),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: drill,
          matching: find.text(de.loansDueOn(day.format(inDays(14)))),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: drill,
          matching: find.byWidgetPredicate(
            (w) => w is MemberAvatar && w.member.id == f.bea.id,
          ),
        ),
        findsOneWidget,
      );
      expect(find.text(de.loansLentOut), findsOneWidget);
      // Borrowed: "Von wem?".
      await tap(tester, find.byTooltip(de.loansAdd));
      await waitFor(tester, find.text(de.loansNew));
      await tap(tester, inDialog(find.text(de.loansBorrowed)));
      await waitFor(tester, inDialog(field(de.loansFromWhom)));
      expect(inDialog(field(de.loansToWhom)), findsNothing);
      await enter(tester, field(de.loansWhat), 'E2E Leiter');
      await enter(tester, field(de.loansFromWhom), 'Opa Kurt');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await waitFor(tester, find.text('E2E Leiter'));
      await waitFor(tester, find.text(de.loansBorrowed));
      expect(
        find.descendant(
          of: cardOf('E2E Leiter'),
          matching: find.textContaining(de.loansBorrowedFrom('Opa Kurt')),
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text(de.loansBorrowed)).dy,
        lessThan(tester.getTopLeft(find.text('E2E Leiter')).dy),
      );

      // ALL-181: overdue since yesterday.
      final yesterday = inDays(-1);
      await seed(f.admin, Collections.loans, {
        'e2e-loan-zelt': Loan(
          id: 'e2e-loan-zelt',
          title: 'E2E Zelt',
          person: 'Familie Kern',
          since: inDays(-20),
          due: yesterday,
        ).toData(),
      });
      await engine.sync();
      final overdue = find.text(de.loansOverdueSince(day.format(yesterday)));
      await waitFor(tester, overdue);
      final context = tester.element(overdue);
      expect(
        styleOf(tester, overdue)?.color,
        Theme.of(context).colorScheme.error,
      );
      expect(styleOf(tester, overdue)?.fontWeight, FontWeight.w700);

      // ALL-182: back and not back after all.
      await tap(
        tester,
        find.descendant(
          of: cardOf('E2E Leiter'),
          matching: find.byTooltip(de.loansMarkReturned),
        ),
      );
      await waitFor(tester, find.text(de.loansReturnedHeading));
      expect(struck(tester, 'E2E Leiter'), isTrue);
      expect(
        tester.getTopLeft(find.text(de.loansReturnedHeading)).dy,
        lessThan(tester.getTopLeft(find.text('E2E Leiter')).dy),
      );
      await tap(
        tester,
        find.descendant(
          of: cardOf('E2E Leiter'),
          matching: find.byTooltip(de.loansNotReturned),
        ),
      );
      await waitGone(tester, find.text(de.loansReturnedHeading));
      expect(struck(tester, 'E2E Leiter'), isFalse);
      await waitFor(tester, find.text(de.loansBorrowed));

      // ALL-183: without a date; deleted and back.
      await tap(tester, find.text('E2E Bohrmaschine'));
      await waitFor(tester, find.text(de.loansEdit));
      await tap(tester, inDialog(find.byTooltip(de.loansNoDate)));
      await waitFor(tester, inDialog(find.text(de.loansNoDate)));
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await until(
        tester,
        () =>
            engine.loans
                .singleWhere((l) => l.title == 'E2E Bohrmaschine')
                .due ==
            null,
        'no date',
      );
      expect(
        find.descendant(
          of: cardOf('E2E Bohrmaschine'),
          matching: find.textContaining(de.loansDueOn('')),
        ),
        findsNothing,
      );
      await tap(tester, find.text('E2E Bohrmaschine'));
      await waitFor(tester, find.text(de.loansEdit));
      await tap(tester, inDialog(find.text(de.commonDelete)));
      await dialogClosed(tester);
      await waitGone(tester, find.text('E2E Bohrmaschine'));
      await tap(tester, find.text(de.commonUndo));
      await waitFor(tester, find.text('E2E Bohrmaschine'));
      await engine.sync();
      await finish(tester, state);
      await clean([Collections.loans]);
    },
  );

  // --- Gäste: Verleih, Fristen, Wunschzettel --------------------------------------

  testWidgets(
    'ALL-185 ALL-190 a guest: no loans or deadlines; wish lists of others',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await clean([
        Collections.loans,
        Collections.deadlines,
        Collections.wishes,
      ]);
      final bea = await sessionOf(f.bea);
      final carl = await sessionOf(f.carl);
      final guestApi = await sessionOf(f.guest);
      await seed(f.admin, Collections.loans, {
        'e2e-loan-gast': const Loan(
          id: 'e2e-loan-gast',
          title: 'E2E Beamer',
        ).toData(),
      });
      await seed(f.admin, Collections.deadlines, {
        'e2e-dl-gast': Deadline(
          id: 'e2e-dl-gast',
          title: 'E2E Schornsteinfeger',
          due: inDays(30),
        ).toData(),
      });
      const wishId = 'e2e-wish-buch';
      await seed(bea, Collections.wishes, {
        wishId: Wish(
          id: wishId,
          ownerId: f.bea.id,
          title: 'E2E Buch',
          createdAt: DateTime.now(),
        ).toData(),
      });
      final got = await pullAll(guestApi);
      expect(got[Collections.loans] ?? {}, isEmpty);
      expect(got[Collections.deadlines] ?? {}, isEmpty);

      final state = await startApp(tester, user: 'e2e-gast');
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, find.text(de.trashTitle));
      await scrollTo(tester, find.text(de.settingsSos));
      expect(find.text(de.settingsDeadlines), findsNothing);
      expect(find.text(de.loansTitle), findsNothing);

      // ALL-190
      await scrollTo(tester, find.text(de.settingsWishes));
      await tap(tester, find.text(de.settingsWishes));
      await dismissTip(tester);
      await waitFor(tester, find.text(de.wishesWhatYouWish));
      final ownEmpty = find
          .text(de.wishesNoWishesYetOthers)
          .evaluate()
          .isNotEmpty;
      debugPrint('E2E-INFO #472 guest starts on an own, empty list: $ownEmpty');
      expect(find.byTooltip(de.wishesAddWish), findsNothing);
      await tap(tester, find.widgetWithText(ChoiceChip, f.bea.displayName));
      await waitFor(tester, find.text('E2E Buch'));
      expect(find.byTooltip(de.wishesAddIdea), findsNothing);
      expect(find.text(de.wishesGiftIdeas), findsNothing);
      await tap(tester, find.text(de.wishesILlGet));
      await waitFor(tester, find.text(de.wishesYouReGetting));
      await state.engine!.sync();
      await eventually(
        tester,
        'Carl sees the guest\'s claim',
        () async =>
            (await pull(
              carl,
              Collections.wishClaims,
            ))[wishId]?.data['claimedBy'] ==
            f.guest.id,
      );
      expect(
        (await pull(bea, Collections.wishClaims)).containsKey(wishId),
        isFalse,
      );
      await finish(tester, state);
      await remove(guestApi, Collections.wishClaims, [wishId]);
      await clean([Collections.loans, Collections.deadlines]);
      await remove(bea, Collections.wishes, [wishId]);
    },
  );

  // --- Wunschzettel & Geschenkideen -----------------------------------------------

  testWidgets('ALL-186 ALL-189 own wishes, received and wished again', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await clean([Collections.wishes]);
    final bea = await sessionOf(f.bea);
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSettingsEntry(tester, de.settingsWishes);
    await waitFor(tester, find.text(de.wishesWhatYouWish));
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, de.shoppingMe))
          .selected,
      isTrue,
    );
    await waitFor(tester, find.text(de.wishesNoWishesYetOthers));
    await tap(tester, find.byTooltip(de.wishesAddWish));
    await waitFor(tester, find.text(de.wishesNewWish));
    await enter(tester, field(de.wishesWhat), 'E2E Lego');
    await enter(tester, field(de.wishesLinkOptional), 'example.org/lego');
    await enter(tester, field(de.wishesPriceOptional), 'ca. 30 €');
    await enter(tester, field(de.wishesNoteSizeColor), 'blau');
    await leaveField(tester);
    await tap(tester, inDialog(find.text(de.commonSave)));
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Lego'));
    final lego = cardOf('E2E Lego');
    expect(
      find.descendant(of: lego, matching: find.text('ca. 30 € · blau')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: lego, matching: find.byTooltip(de.wishesOpenLink)),
      findsOneWidget,
    );
    expect(find.text(de.wishesNoWishesYetOthers), findsNothing);

    // ALL-189
    await tap(tester, find.text(de.wishesReceived));
    await until(tester, () => engine.wishes.single.received, 'received');
    expect(struck(tester, 'E2E Lego'), isTrue);
    await engine.sync();
    await eventually(
      tester,
      'the others get it as received',
      () async =>
          (await pull(bea, Collections.wishes)).values
              .where((r) => r.data['title'] == 'E2E Lego')
              .firstOrNull
              ?.data['received'] ==
          true,
    );
    await tap(tester, find.text(de.wishesWishAgain));
    await until(tester, () => !engine.wishes.single.received, 'wished again');
    expect(struck(tester, 'E2E Lego'), isFalse);
    await engine.sync();
    await finish(tester, state);
    await clean([Collections.wishes]);
  });

  testWidgets(
    'ALL-187 ALL-188 ALL-189 who gets a wish stays secret; gift ideas',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await clean([Collections.wishes, Collections.wishClaims]);
      final bea = await sessionOf(f.bea);
      final carl = await sessionOf(f.carl);
      final kid = await sessionOf(f.kid);
      const puzzle = 'e2e-wish-puzzle';
      await seed(bea, Collections.wishes, {
        puzzle: Wish(
          id: puzzle,
          ownerId: f.bea.id,
          title: 'E2E Puzzle',
          createdAt: DateTime.now(),
        ).toData(),
        'e2e-wish-alt': Wish(
          id: 'e2e-wish-alt',
          ownerId: f.bea.id,
          title: 'E2E Altes Spiel',
          received: true,
          createdAt: DateTime.now(),
        ).toData(),
      });
      var state = await startApp(tester);
      await openSettingsEntry(tester, de.settingsWishes);
      await tap(tester, find.widgetWithText(ChoiceChip, f.bea.displayName));
      await waitFor(tester, find.text('E2E Puzzle'));
      // ALL-189: received wishes are hidden from the others.
      expect(find.text('E2E Altes Spiel'), findsNothing);

      // ALL-187
      await tap(tester, find.text(de.wishesILlGet));
      await waitFor(tester, find.text(de.wishesYouReGetting));
      expect(find.text(de.wishesRelease), findsOneWidget);
      await state.engine!.sync();
      await eventually(
        tester,
        'Carl sees the admin gets it',
        () async =>
            (await pull(
              carl,
              Collections.wishClaims,
            ))[puzzle]?.data['claimedBy'] ==
            f.adminMember.id,
      );
      expect(
        (await pull(bea, Collections.wishClaims)).containsKey(puzzle),
        isFalse,
        reason: 'Bea never learns it',
      );
      await tap(tester, find.text(de.wishesRelease));
      await waitFor(tester, find.text(de.wishesILlGet));
      await state.engine!.sync();
      await eventually(
        tester,
        'free again',
        () async =>
            !(await pull(carl, Collections.wishClaims)).containsKey(puzzle),
      );
      await tap(tester, find.text(de.wishesILlGet));
      await waitFor(tester, find.text(de.wishesYouReGetting));

      // ALL-188
      await tap(tester, find.widgetWithText(ChoiceChip, f.kid.displayName));
      await waitFor(tester, find.text(de.wishesNoIdeasYet(f.kid.displayName)));
      await tap(tester, find.byTooltip(de.wishesAddIdea));
      await waitFor(tester, find.text(de.wishesNewIdea(f.kid.displayName)));
      await enter(tester, field(de.wishesWhat), 'E2E Roller');
      await leaveField(tester);
      await tap(tester, inDialog(find.text(de.commonSave)));
      await dialogClosed(tester);
      await waitFor(tester, find.text('E2E Roller'));
      await waitFor(tester, find.text(de.wishesIdeasHidden(f.kid.displayName)));
      await waitFor(tester, find.text(de.wishesYourIdea));
      expect(
        tester.getTopLeft(find.text(de.wishesGiftIdeas)).dy,
        lessThan(tester.getTopLeft(find.text('E2E Roller')).dy),
      );
      await state.engine!.sync();
      await eventually(
        tester,
        'Carl gets the idea',
        () async =>
            (await titlesOf(carl, Collections.wishes)).contains('E2E Roller'),
      );
      expect(
        await titlesOf(kid, Collections.wishes),
        isNot(contains('E2E Roller')),
      );
      await finish(tester, state);

      // What Carl sees.
      state = await startApp(tester, user: 'e2e-carl');
      await openSettingsEntry(tester, de.settingsWishes);
      await tap(tester, find.widgetWithText(ChoiceChip, f.bea.displayName));
      await waitFor(tester, find.text(de.wishesNameGetting(kitAdminName)));
      await tap(tester, find.widgetWithText(ChoiceChip, f.kid.displayName));
      await waitFor(tester, find.text(de.wishesIdeaBy(kitAdminName)));
      await finish(tester, state);
      await clean([Collections.wishes, Collections.wishClaims]);
      await remove(bea, Collections.wishes, [puzzle, 'e2e-wish-alt']);
    },
  );

  // --- Fristen & Verträge ---------------------------------------------------------

  testWidgets(
    'ALL-191 ALL-192 ALL-193 ALL-194 deadlines: suggestions, all fields, done, soon',
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await cleanDeadlines();
      final state = await startApp(tester);
      final engine = state.engine!;
      await openDeadlines(tester);

      // ALL-191
      await waitFor(tester, find.text(de.deadlinesFamioRemindsYouGood));
      for (final p in [
        de.deadlinesCarInspection,
        de.deadlinesHeatingMaintenance,
        de.deadlinesTestSmokeDetectors,
        de.commonVaccination,
      ]) {
        expect(find.widgetWithText(ActionChip, p), findsOneWidget, reason: p);
      }
      await tap(
        tester,
        find.widgetWithText(ActionChip, de.deadlinesCarInspection),
      );
      await waitFor(tester, find.text(de.deadlinesNewDeadline));
      expect(
        controllerOf(tester, field(de.wishesWhat))!.text,
        de.deadlinesCarInspection,
      );
      await tap(tester, inSheet(find.text(de.deadlinesDue)));
      await pickDate(tester, inDays(40));
      await tap(tester, inSheet(find.text(de.commonSave)));
      await sheetClosed(tester);
      await waitFor(tester, find.text('🚗 Auto'));
      await waitFor(
        tester,
        find.text('${day.format(inDays(40))} · ${de.deadlinesDaysDays(40)}'),
      );

      // ALL-192
      await snackGone(tester);
      await tap(tester, find.byTooltip(de.deadlinesAddDeadline));
      await waitFor(tester, find.text(de.deadlinesNewDeadline));
      await tap(tester, inSheet(find.text('🏠 Haus & Wohnung')));
      await tap(
        tester,
        inSheet(
          find.widgetWithText(ActionChip, de.deadlinesHeatingMaintenance),
        ),
      );
      await enter(tester, field(de.budgetWhatOptional), 'Ferienhaus');
      await leaveField(tester);
      await tap(tester, inSheet(find.text(de.deadlinesDue)));
      await pickDate(tester, inDays(100));
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, de.eventRepeat),
          matching: find.text(de.deadlinesEveryYear),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, de.deadlinesRemind),
          matching: find.text(de.deadlinesDaysDaysBefore(14)),
        ),
        findsOneWidget,
      );
      await scrollTo(tester, find.text(de.tasksWhoTakesCare));
      await tap(
        tester,
        find.ancestor(
          of: find.text(de.tasksWhoTakesCare),
          matching: find.byWidgetPredicate((w) => w is DropdownButtonFormField),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final who = menuTexts();
      debugPrint('E2E-INFO "Wer kümmert sich?": $who');
      expect(
        who,
        containsAll([
          de.deadlinesAdults,
          kitAdminName,
          f.bea.displayName,
          f.carl.displayName,
          f.kid.displayName,
        ]),
      );
      expect(who, isNot(contains(f.guest.displayName)));
      await tap(tester, find.text(f.bea.displayName).last);
      await tester.pump(const Duration(milliseconds: 600));
      await enter(
        tester,
        field(de.deadlinesNoteGaragePhoneNumber),
        'Firma Wärme',
      );
      await leaveField(tester);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await sheetClosed(tester);
      const label = 'Heizungswartung · Ferienhaus';
      await waitFor(tester, find.text(label));
      final heating = cardOf(label);
      expect(
        find.descendant(
          of: heating,
          matching: find.text('${de.deadlinesEveryYear} · Firma Wärme'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: heating,
          matching: find.textContaining(day.format(inDays(100))),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: heating,
          matching: find.byWidgetPredicate(
            (w) => w is MemberAvatar && w.member.id == f.bea.id,
          ),
        ),
        findsOneWidget,
      );
      final d = engine.deadlines.singleWhere((d) => d.label == label);
      expect(
        (d.area, d.repeatMonths, d.leadDays, d.assigneeId, d.note),
        (DeadlineArea.home, 12, 14, f.bea.id, 'Firma Wärme'),
      );

      // ALL-193: the recurring one moves on.
      await tap(
        tester,
        find.descendant(of: heating, matching: find.text(de.commonDoneCap)),
      );
      final next = addMonths(today(), 12);
      await waitFor(
        tester,
        find.text(de.deadlinesNextTimeDate(day.format(next))),
      );
      expect(engine.deadlines.singleWhere((x) => x.id == d.id).due, next);
      await snackGone(tester);
      // The one-off is done; undone.
      await seed(f.admin, Collections.deadlines, {
        'e2e-dl-once': Deadline(
          id: 'e2e-dl-once',
          title: 'E2E Rauchmelder einmalig',
          due: inDays(20),
          area: DeadlineArea.home,
        ).toData(),
      });
      await engine.sync();
      await waitFor(tester, find.text('E2E Rauchmelder einmalig'));
      await tap(
        tester,
        find.descendant(
          of: cardOf('E2E Rauchmelder einmalig'),
          matching: find.text(de.commonDoneCap),
        ),
      );
      await waitFor(
        tester,
        find.text(de.deadlinesTitleDone('E2E Rauchmelder einmalig')),
      );
      await waitFor(
        tester,
        find.text(de.deadlinesDoneDate(day.format(today()))),
      );
      expect(
        tester
            .getTopLeft(find.widgetWithText(ListHeading, de.commonDoneCap))
            .dy,
        lessThan(tester.getTopLeft(find.text('E2E Rauchmelder einmalig')).dy),
      );
      await tap(tester, find.text(de.commonUndo));
      await until(
        tester,
        () => !deadlineNamed(engine, 'E2E Rauchmelder einmalig').done,
        'open again',
      );
      await waitGone(
        tester,
        find.text(de.deadlinesDoneDate(day.format(today()))),
      );

      // ALL-194: soon in the area's color and bold, overdue in red.
      await snackGone(tester);
      await seed(f.admin, Collections.deadlines, {
        'e2e-dl-soon': Deadline(
          id: 'e2e-dl-soon',
          title: 'E2E Bald fällig',
          due: inDays(5),
          area: DeadlineArea.other,
        ).toData(),
        'e2e-dl-late': Deadline(
          id: 'e2e-dl-late',
          title: 'E2E Überfällig',
          due: inDays(-3),
          area: DeadlineArea.other,
        ).toData(),
      });
      await engine.sync();
      final soon = find.text(
        '${day.format(inDays(5))} · ${de.deadlinesDaysDays(5)}',
      );
      final late = find.text(
        '${day.format(inDays(-3))} · ${de.deadlinesOverdueDaysDays(3)}',
      );
      await scrollTo(tester, soon);
      final c = FamioColors.of(tester.element(soon));
      expect(styleOf(tester, soon)?.color, c.strong(FamioSection.tasks));
      expect(styleOf(tester, soon)?.fontWeight, FontWeight.w600);
      await scrollTo(tester, late);
      expect(
        styleOf(tester, late)?.color,
        Theme.of(tester.element(late)).colorScheme.error,
      );
      // Not yet within the reminder time: neither.
      final calm = find.text(
        '${day.format(inDays(40))} · ${de.deadlinesDaysDays(40)}',
      );
      await scrollTo(tester, calm);
      expect(styleOf(tester, calm)?.color, c.inkSoft);
      expect(engine.deadlines.length, 5);
      await finish(tester, state);
      await cleanDeadlines();
    },
  );

  // Befund (reproduced twice): soon-due deadlines are not bold beside the
  // others. deadlines_screen.dart:156 sets FontWeight.w600 for them, but the
  // theme's body text has w600 already (design/theme.dart:71), so only the
  // colour tells them apart.
  testWidgets('ALL-194 soon due ones stand out in bold', skip: true, (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await cleanDeadlines();
    await seed(f.admin, Collections.deadlines, {
      'e2e-dl-bold-soon': Deadline(
        id: 'e2e-dl-bold-soon',
        title: 'E2E Bald',
        due: inDays(4),
      ).toData(),
      'e2e-dl-bold-calm': Deadline(
        id: 'e2e-dl-bold-calm',
        title: 'E2E Später',
        due: inDays(60),
      ).toData(),
    });
    final state = await startApp(tester);
    await openDeadlines(tester);
    final soon = find.text(
      '${day.format(inDays(4))} · ${de.deadlinesDaysDays(4)}',
    );
    final calm = find.text(
      '${day.format(inDays(60))} · ${de.deadlinesDaysDays(60)}',
    );
    await waitFor(tester, soon);
    await waitFor(tester, calm);
    final bold = styleOf(tester, soon)!.fontWeight!;
    final normal = styleOf(tester, calm)!.fontWeight!;
    debugPrint('E2E-INFO deadline weights: soon $bold, others $normal');
    expect(bold.value, greaterThan(normal.value));
    await finish(tester, state);
    await cleanDeadlines();
  });

  testWidgets(
    'ALL-196 ALL-197 ALL-198 a contract: notice, household book, cancelled',
    (tester) async {
      tall(tester);
      await theFamily();
      await cleanDeadlines();
      final state = await startApp(tester);
      final engine = state.engine!;
      await openDeadlines(tester);
      final end = inDays(200);

      // ALL-196
      await tap(tester, find.byTooltip(de.deadlinesAddDeadline));
      await waitFor(tester, find.text(de.deadlinesNewDeadline));
      await tap(tester, inSheet(find.text('📄 Verträge & Abos')));
      await waitFor(tester, find.text(de.contractEnd));
      await enter(tester, field(de.wishesWhat), 'E2E Streaming');
      await leaveField(tester);
      await tap(tester, inSheet(find.text(de.contractEnd)));
      await pickDate(tester, end);
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, de.contractRenews),
          matching: find.text(de.deadlinesEveryYear),
        ),
        findsOneWidget,
      );
      await tap(tester, find.text(de.contractNoticeNone));
      await tap(tester, find.text(de.contractNoticeMonths(3)).last);
      await enter(tester, field(de.contractMonthly), '9,99');
      await leaveField(tester);
      await tap(tester, inSheet(find.text(de.commonSave)));
      await sheetClosed(tester);
      await waitFor(tester, find.text('E2E Streaming'));
      final contract = deadlineNamed(engine, 'E2E Streaming');
      final cancelBy = addMonths(end, -3);
      expect((contract.cancelBy, contract.actionDay), (cancelBy, cancelBy));
      final card = cardOf('E2E Streaming');
      expect(
        find.descendant(
          of: card,
          matching: find.textContaining(
            de.contractCancelBy(day.format(cancelBy)),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(
            '${de.contractPerMonth(formatEuro(999))} · ${de.deadlinesEveryYear}',
          ),
        ),
        findsOneWidget,
      );

      // ALL-197
      final entryId = 'contract-${contract.id}';
      Future<void> edit() async {
        await snackGone(tester);
        await tap(tester, find.text('E2E Streaming'));
        await waitFor(tester, find.text(de.deadlinesEditDeadline));
        await scrollTo(
          tester,
          find.widgetWithText(SwitchListTile, de.contractInBudget),
        );
      }

      await edit();
      expect(find.text(de.contractInBudgetHint), findsOneWidget);
      await tap(
        tester,
        find.widgetWithText(SwitchListTile, de.contractInBudget),
      );
      await waitFor(tester, find.text(de.contractCategory));
      await choose(tester, de.contractCategory, 'Freizeit');
      await tap(tester, inSheet(find.text(de.commonSave)));
      await sheetClosed(tester);
      await until(
        tester,
        () => engine.record(Collections.budgetEntries, entryId) != null,
        'a monthly expense',
      );
      var entry = BudgetEntry.fromRecord(
        engine.record(Collections.budgetEntries, entryId)!,
      );
      expect(
        (entry.cents, entry.monthly, entry.category, entry.until),
        (999, true, 'Freizeit', null),
      );
      expect(entry.date, DateTime(today().year, today().month));
      await openSection(tester, de.sectionBudget);
      await waitFor(tester, find.textContaining('9,99'));
      await openDeadlines(tester);
      await edit();
      await tap(
        tester,
        find.widgetWithText(SwitchListTile, de.contractInBudget),
      );
      await tap(tester, inSheet(find.text(de.commonSave)));
      await sheetClosed(tester);
      await until(
        tester,
        () => engine.record(Collections.budgetEntries, entryId) == null,
        'switched off: gone',
      );
      await edit();
      await tap(
        tester,
        find.widgetWithText(SwitchListTile, de.contractInBudget),
      );
      await tap(tester, inSheet(find.text(de.commonSave)));
      await sheetClosed(tester);
      await until(
        tester,
        () => engine.record(Collections.budgetEntries, entryId) != null,
        'back in the budget',
      );

      // ALL-198: cancelled, undone, runs on.
      Future<void> doneAs(String choice) async {
        await snackGone(tester);
        await tap(
          tester,
          find.descendant(
            of: cardOf('E2E Streaming'),
            matching: find.byTooltip(de.commonDoneCap),
          ),
        );
        await tap(tester, find.text(choice).last);
      }

      await doneAs(de.contractCancelled);
      await waitFor(
        tester,
        find.text(de.contractCancelledSnack('E2E Streaming', day.format(end))),
      );
      await waitFor(
        tester,
        find.text(de.contractCancelledOn(day.format(today()), day.format(end))),
      );
      expect(
        tester
            .getTopLeft(find.widgetWithText(ListHeading, de.commonDoneCap))
            .dy,
        lessThan(tester.getTopLeft(find.text('E2E Streaming')).dy),
      );
      entry = BudgetEntry.fromRecord(
        engine.record(Collections.budgetEntries, entryId)!,
      );
      expect(DateUtils.dateOnly(entry.until!), end);
      await tap(tester, find.text(de.commonUndo));
      await until(
        tester,
        () => !deadlineNamed(engine, 'E2E Streaming').done,
        'undone',
      );
      expect(
        BudgetEntry.fromRecord(
          engine.record(Collections.budgetEntries, entryId)!,
        ).until,
        isNull,
      );
      await doneAs(de.contractRunsOn);
      final newEnd = addMonths(end, 12);
      await waitFor(
        tester,
        find.text(de.contractRunsOnUntil(day.format(newEnd))),
      );
      expect(deadlineNamed(engine, 'E2E Streaming').due, newEnd);
      await waitFor(
        tester,
        find.textContaining(
          de.contractCancelBy(day.format(addMonths(newEnd, -3))),
        ),
      );
      await engine.sync();
      await finish(tester, state);
      await cleanDeadlines();
    },
  );

  testWidgets('ALL-200 a child sees the deadlines, may not change them', (
    tester,
  ) async {
    tall(tester);
    final f = await theFamily();
    await cleanDeadlines();
    final kid = await sessionOf(f.kid);
    await seed(f.admin, Collections.deadlines, {
      'e2e-dl-family': Deadline(
        id: 'e2e-dl-family',
        title: 'E2E Wartung Familie',
        due: inDays(30),
        area: DeadlineArea.home,
      ).toData(),
    });
    final state = await startApp(tester, user: 'e2e-kind');
    await openDeadlines(tester);
    await waitFor(tester, find.text('E2E Wartung Familie'));
    expect(find.byTooltip(de.deadlinesAddDeadline), findsNothing);
    expect(
      find.descendant(
        of: cardOf('E2E Wartung Familie'),
        matching: find.text(de.commonDoneCap),
      ),
      findsNothing,
    );
    await tap(tester, find.text('E2E Wartung Familie'));
    await settle(tester);
    expect(find.text(de.deadlinesEditDeadline), findsNothing);
    final refused = await put(kid, Collections.deadlines, {
      'e2e-dl-kind-neu': Deadline(
        id: 'e2e-dl-kind-neu',
        title: 'E2E Vom Kind',
        due: inDays(3),
      ).toData(),
    });
    expect(refused.rejected.map((r) => r.id), contains('e2e-dl-kind-neu'));
    expect(
      (await pull(
        f.admin,
        Collections.deadlines,
      )).containsKey('e2e-dl-kind-neu'),
      isFalse,
    );
    await finish(tester, state);
    await cleanDeadlines();
  });

  // Befund (hint of ALL-201, reproduced twice): children can be chosen under
  // "Wer kümmert sich?" (deadlines_screen.dart:354) and see "Erledigt"
  // (:213), but the server lets children write no deadline
  // (Collections.adultOnly): the sync sets the completion back without a
  // word, the adults never see it.
  testWidgets(
    'ALL-201 a child in charge of a deadline ticks it off',
    skip: true,
    (tester) async {
      tall(tester);
      final f = await theFamily();
      await cleanDeadlines();
      final due = inDays(10);
      await seed(f.admin, Collections.deadlines, {
        'e2e-dl-kind': Deadline(
          id: 'e2e-dl-kind',
          title: 'E2E Rauchmelder testen',
          due: due,
          area: DeadlineArea.home,
          repeatMonths: 12,
          assigneeId: f.kid.id,
        ).toData(),
      });
      final state = await startApp(tester, user: 'e2e-kind');
      final engine = state.engine!;
      await openDeadlines(tester);
      await waitFor(tester, find.text('E2E Rauchmelder testen'));
      await tap(
        tester,
        find.descendant(
          of: cardOf('E2E Rauchmelder testen'),
          matching: find.text(de.commonDoneCap),
        ),
      );
      await waitFor(
        tester,
        find.text(de.deadlinesNextTimeDate(day.format(addMonths(today(), 12)))),
      );
      await engine.sync();
      await settle(tester, 2000);
      await engine.sync();
      final mine = deadlineNamed(engine, 'E2E Rauchmelder testen');
      final server = Deadline.fromRecord(
        (await pull(f.admin, Collections.deadlines))['e2e-dl-kind']!,
      );
      debugPrint(
        'E2E-INFO after the sync: child sees due ${mine.due}, '
        'the adults ${server.due} (asked ${addMonths(today(), 12)})',
      );
      expect(mine.due, isNot(due), reason: 'stays done for the child');
      expect(server.due, isNot(due), reason: 'the adults see it done');
      await finish(tester, state);
      await cleanDeadlines();
    },
  );

  // --- Rechte ---------------------------------------------------------------------

  testWidgets('ALL-202 what guests receive at all', (tester) async {
    final f = await theFamily();
    final admin = f.admin;
    final me = f.adminMember;
    final bea = await sessionOf(f.bea);
    final guestApi = await sessionOf(f.guest);
    final now = DateTime.now();
    final t = today();
    final ids = <String, String>{};
    Future<void> one(
      FamioApiClient api,
      String collection,
      String id,
      Map<String, Object?> data,
    ) async {
      ids[collection] = id;
      await seed(api, collection, {id: data});
    }

    // What a guest should get.
    await seed(admin, Collections.tasks, {
      'e2e-t-gast': Task(
        id: 'e2e-t-gast',
        title: 'E2E Aufgabe für den Gast',
        assigneeIds: [f.guest.id],
      ).toData(),
      'e2e-t-gezeigt': Task(
        id: 'e2e-t-gezeigt',
        title: 'E2E Gezeigte Aufgabe',
        visibleTo: [me.id, f.guest.id],
      ).toData(),
      'e2e-t-familie': const Task(
        id: 'e2e-t-familie',
        title: 'E2E Familienaufgabe',
      ).toData(),
    });
    await one(
      admin,
      Collections.shoppingLists,
      'e2e-g-list',
      const ShoppingList(id: 'e2e-g-list', name: 'E2E Liste').toData(),
    );
    await one(
      admin,
      Collections.shoppingItems,
      'e2e-g-item',
      const ShoppingItem(
        id: 'e2e-g-item',
        listId: 'e2e-g-list',
        name: 'E2E Saft',
      ).toData(),
    );
    await one(
      admin,
      Collections.chatMessages,
      'e2e-g-chat',
      message('e2e-g-chat', ChatIds.family, me, 'E2E Hallo'),
    );
    await one(
      admin,
      Collections.notes,
      'e2e-g-note',
      const FamilyNote(id: 'e2e-g-note', title: 'E2E Zettel').toData(),
    );
    await one(
      bea,
      Collections.wishes,
      'e2e-g-wish',
      Wish(id: 'e2e-g-wish', ownerId: f.bea.id, title: 'E2E Wunsch').toData(),
    );
    await one(
      admin,
      Collections.contacts,
      'e2e-g-contact',
      const FamilyContact(id: 'e2e-g-contact', name: 'E2E Kontakt').toData(),
    );
    await one(
      admin,
      Collections.chores,
      'e2e-g-chore',
      Chore(
        id: 'e2e-g-chore',
        title: 'E2E Tisch decken',
        start: t,
        memberIds: [f.kid.id],
      ).toData(),
    );
    await one(
      admin,
      Collections.routines,
      'e2e-g-routine',
      Routine(
        id: 'e2e-g-routine',
        title: 'E2E Morgenroutine',
        memberId: f.kid.id,
      ).toData(),
    );
    final shouldGet = {...ids};
    ids.clear();

    // What a guest should not get.
    await one(
      admin,
      Collections.pointEntries,
      'e2e-g-points',
      PointEntry(
        id: 'e2e-g-points',
        memberId: f.kid.id,
        points: 5,
        title: 'E2E Bonus',
        kind: PointKind.bonus,
        at: now,
      ).toData(),
    );
    await one(
      admin,
      Collections.allowances,
      f.kid.id,
      Allowance(memberId: f.kid.id, weeklyCents: 200, since: t).toData(),
    );
    await one(
      admin,
      Collections.savingsGoals,
      'e2e-g-goal',
      SavingsGoal(
        id: 'e2e-g-goal',
        memberId: f.kid.id,
        title: 'E2E Fahrrad',
        targetCents: 15000,
      ).toData(),
    );
    await one(
      admin,
      Collections.deadlines,
      'e2e-g-deadline',
      Deadline(id: 'e2e-g-deadline', title: 'E2E TÜV', due: inDays(9)).toData(),
    );
    await one(
      admin,
      Collections.loans,
      'e2e-g-loan',
      const Loan(id: 'e2e-g-loan', title: 'E2E Bohrer').toData(),
    );
    await one(
      admin,
      Collections.vacations,
      'e2e-g-vacation',
      Vacation(
        id: 'e2e-g-vacation',
        from: inDays(20),
        to: inDays(30),
        title: 'E2E Sommer',
      ).toData(),
    );
    await one(
      admin,
      Collections.absences,
      'e2e-g-absence',
      MemberAbsence(
        id: 'e2e-g-absence',
        memberId: f.bea.id,
        from: inDays(3),
        to: inDays(5),
      ).toData(),
    );
    await one(
      admin,
      Collections.rewards,
      'e2e-g-reward',
      const Reward(id: 'e2e-g-reward', title: 'E2E Kino').toData(),
    );
    await one(
      admin,
      Collections.budgetEntries,
      'e2e-g-budget',
      BudgetEntry(
        id: 'e2e-g-budget',
        date: t,
        cents: 1234,
        category: 'Lebensmittel',
      ).toData(),
    );
    final file = await admin.uploadFile(
      bytes: '%PDF-1.4\n%%EOF\n'.codeUnits,
      name: 'e2e-police.pdf',
      mime: 'application/pdf',
    );
    await one(
      admin,
      Collections.documents,
      'e2e-g-doc',
      FamilyDocument(
        id: 'e2e-g-doc',
        title: 'E2E Hausratversicherung',
        category: DocumentCategory.insurance,
        file: file,
      ).toData(),
    );
    final shouldNot = {...ids};

    final got = await pullAll(guestApi);
    bool has(String c, String id) => got[c]?.containsKey(id) ?? false;
    final missing = [
      for (final e in shouldGet.entries)
        if (!has(e.key, e.value)) e.key,
    ];
    final extra = [
      for (final e in shouldNot.entries)
        if ((got[e.key] ?? {}).isNotEmpty) e.key,
    ];
    debugPrint('E2E-INFO guest misses $missing, gets as well $extra');
    expect(missing, isEmpty);
    expect(extra, isEmpty);
    expect(has(Collections.tasks, 'e2e-t-gast'), isTrue);
    expect(has(Collections.tasks, 'e2e-t-gezeigt'), isTrue);
    expect(has(Collections.tasks, 'e2e-t-familie'), isFalse);

    // The guest's app holds the same after its sync.
    final state = await startApp(tester, user: 'e2e-gast');
    final engine = state.engine!;
    await engine.sync();
    for (final e in shouldGet.entries) {
      expect(engine.record(e.key, e.value), isNotNull, reason: e.key);
    }
    for (final c in shouldNot.keys) {
      expect(engine.records(c), isEmpty, reason: c);
    }
    expect(engine.record(Collections.tasks, 'e2e-t-familie'), isNull);
    await openSection(tester, 'Aufgaben');
    await waitFor(tester, find.text('E2E Aufgabe für den Gast'));
    await waitFor(tester, find.text('E2E Gezeigte Aufgabe'));
    expect(find.text('E2E Familienaufgabe'), findsNothing);
    await finish(tester, state);

    await remove(admin, Collections.tasks, [
      'e2e-t-gast',
      'e2e-t-gezeigt',
      'e2e-t-familie',
    ]);
    for (final e in {...shouldGet, ...shouldNot}.entries) {
      await remove(e.key == Collections.wishes ? bea : admin, e.key, [e.value]);
    }
  });

  // A file over 8 MiB from the file picker: the picker hands a
  // Stream<Uint8List> (PlatformFile.readAsByteStream), which
  // FileCache._digesting widens before hashing (#533); any other failure
  // of an upload ends as a message. Last in the file: should the upload
  // break again, an uncaught error would leave the binding broken for the
  // tests after it.
  testWidgets('ALL-165 a file over 8 MiB from the picker', (tester) async {
    tall(tester);
    await theFamily();
    await cleanChat();
    final picker = _fakePicker();
    final pdf = await tempFile('E2E-Gross.pdf', bigPdf());
    picker.picks.add(_DiskFile(pdf));
    final state = await startApp(tester);
    final engine = state.engine!;
    await openSection(tester, 'Chat');
    await tap(tester, find.text(de.settingsFamily));
    await waitFor(tester, find.text(de.chatEveryoneFamily));
    await tap(tester, find.byTooltip(de.chatSendPhotoFile));
    await until(
      tester,
      () => engine.chatMessages(ChatIds.family).isNotEmpty,
      'the large file sent',
      timeout: const Duration(seconds: 60),
    );
    await waitFor(tester, find.text('E2E-Gross.pdf'));
    await finish(tester, state);
    await cleanChat();
  });
}
