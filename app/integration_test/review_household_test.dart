// Acceptance test of the shopping, meals, budget and calendar import
// features against a throwaway server (one per run of this file):
//
//   tool/integration_tests.sh macos integration_test/review_household_test.dart
//
// One test per feature. Each starts the app signed out, signs in as the
// admin, seeds what a family would have built up over time through the API
// and then uses the feature like a person. Native parts cannot be driven:
// the share sheet and the file picker / save panel are replaced at their
// plugin boundary (the test hands in the file a person would have picked
// and reads what would have been shared or saved), files dragged onto the
// window arrive through the app's own drop handler.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/ocr.dart';
import 'package:famio/src/data/shopping_history.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/widgets/files.dart';
import 'package:famio/src/widgets/photo_viewer.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'fresh_start.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');
const _fingerprint = String.fromEnvironment('FAMIO_FINGERPRINT');

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

/// Stands in for the native open and save panels: returns the files queued
/// in [picks] and keeps what would have been saved.
class _FakePicker extends FilePickerPlatform {
  final picks = <File>[];
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
  }) async => picks.isEmpty ? [] : [_DiskFile(picks.removeAt(0))];

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

void main() {
  // The tests read German texts, whatever the device speaks.
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final pin = _fingerprint.isEmpty ? null : _fingerprint;

  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    debugPrint('E2E wait ${finder.describeMatch(Plurality.many)}');
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isNotEmpty) return;
    }
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .join(' | ');
    throw TestFailure('Timed out waiting for $finder\nOn screen: $texts');
  }

  /// Pumps until [ok] holds.
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
        final texts = find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .whereType<String>()
            .join(' | ');
        throw TestFailure('Timed out: $what\nOn screen: $texts');
      }
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    debugPrint('E2E tap ${finder.describeMatch(Plurality.many)}');
    await waitFor(tester, finder);
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder.first);
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// A section's first-visit tip lies over the page: put away like a
  /// person who read it.
  Future<void> dismissTip(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 700));
    if (find.text('Verstanden').evaluate().isNotEmpty) {
      await tap(tester, find.text('Verstanden').last);
    }
  }

  /// A snack bar covers the bottom of the page for a few seconds.
  Future<void> snackGone(WidgetTester tester) => until(
    tester,
    () => find.byType(SnackBar).evaluate().isEmpty,
    'snack bar gone',
    timeout: const Duration(seconds: 15),
  );

  /// Scrolls the page until [finder] is built (long lists build lazily).
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await dismissTip(tester);
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await waitFor(tester, finder);
  }

  /// Types into [field]; the controller is taken first, so a finder by
  /// hint text still works once the hint is gone.
  Future<void> enter(WidgetTester tester, Finder field, String text) async {
    await waitFor(tester, field);
    final controller = tester.widget<TextField>(field.last).controller;
    await tester.tap(field.last);
    await tester.pump();
    await tester.enterText(field.last, text);
    await tester.pump();
    if (controller != null && controller.text != text) {
      controller.text = text;
      await tester.pump();
    }
  }

  /// Sections: on phones an icon in the bar (tooltip) or behind "Mehr", on
  /// wide windows in the side rail.
  Future<void> openSection(WidgetTester tester, String label) async {
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == label) ||
            (w is Tooltip && (w.message == label || w.message == 'Mehr')),
      ),
    );
    // The bar first: on phones the start page has cards titled like the
    // sections.
    if (find.byTooltip(label).evaluate().isNotEmpty) {
      await tap(tester, find.byTooltip(label).last);
    } else if (find.byTooltip('Mehr').evaluate().isNotEmpty) {
      await tap(tester, find.byTooltip('Mehr').last);
      await tap(tester, find.text(label).last);
    } else {
      await tap(tester, find.text(label).last);
    }
    // The first visit's tip sits above the bottom of the page; a person
    // reads it and puts it away.
    await tester.pump(const Duration(milliseconds: 500));
    if (find.text('Verstanden').evaluate().isNotEmpty) {
      await tap(tester, find.text('Verstanden').last);
    }
  }

  // --- Server side: the admin's API session, other members, seed data ---

  FamioApiClient? adminApi;
  Future<FamioApiClient> admin() async {
    if (adminApi case final api?) return api;
    final api = FamioApiClient(_url, pinnedCertificate: pin);
    await api.login(username: _user, password: _password, device: 'e2e');
    return adminApi = api;
  }

  final members = <String, FamilyMember>{};
  Future<FamilyMember> member(String username, MemberRole role) async {
    if (members[username] case final m?) return m;
    final api = await admin();
    for (final u in await api.adminUsers()) {
      if (u.member.username == username) return members[username] = u.member;
    }
    return members[username] = await api.createMember(
      username: username,
      displayName: switch (role) {
        MemberRole.child => 'E2E Kind',
        MemberRole.guest => 'E2E Gast',
        _ => 'E2E Papa',
      },
      password: '$username-123',
      role: role,
    );
  }

  Future<FamioApiClient> signInAs(String username) async {
    final api = FamioApiClient(_url, pinnedCertificate: pin);
    await api.login(
      username: username,
      password: '$username-123',
      device: 'e2e',
    );
    return api;
  }

  /// Writes [records] (collection, id, data) as the admin, as if built up
  /// in the app over time.
  Future<void> seed(
    List<(String, String, Map<String, Object?>)> records,
  ) async {
    final api = await admin();
    final now = DateTime.now().millisecondsSinceEpoch;
    final response = await api.sync(
      SyncRequest(
        since: 0,
        changes: [
          for (final (collection, id, data) in records)
            SyncRecord(
              collection: collection,
              id: id,
              data: data,
              updatedAt: now,
            ),
        ],
      ),
    );
    expect(
      response.rejected.map((r) => r.id),
      isEmpty,
      reason: 'seed data refused',
    );
  }

  /// What [api]'s account gets from the server: the newest version of
  /// every record, deletions included.
  Future<Map<String, SyncRecord>> serverView(FamioApiClient api) async {
    final view = <String, SyncRecord>{};
    var since = 0;
    while (true) {
      final response = await api.sync(SyncRequest(since: since));
      for (final r in response.changes) {
        view['${r.collection}/${r.id}'] = r;
      }
      since = response.rev;
      if (!response.hasMore) return view;
    }
  }

  List<SyncRecord> live(Map<String, SyncRecord> view, String collection) => [
    for (final r in view.values)
      if (r.collection == collection && !r.deleted) r,
  ];

  // --- The app ---

  Future<AppState> start(WidgetTester tester) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    await initializeDateFormatting('de');
    await freshStart();
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    if (state.me == null) {
      await enter(
        tester,
        find.widgetWithText(TextField, 'Server-Adresse'),
        _url,
      );
      await tap(tester, find.text('Verbinden'));
      if (_fingerprint.isNotEmpty) {
        await waitFor(tester, find.text('Zertifikat des Servers prüfen'));
        await tap(tester, find.text('Stimmt überein'));
      }
      await enter(
        tester,
        find.widgetWithText(TextField, 'Benutzername'),
        _user,
      );
      await enter(
        tester,
        find.widgetWithText(TextField, 'Passwort'),
        _password,
      );
      await tap(tester, find.text('Anmelden'));
    }
    await until(
      tester,
      () => state.me != null && state.engine != null,
      'signed in',
    );
    await state.engine!.sync();
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == 'Start') ||
            (w is Tooltip && w.message == 'Start'),
      ),
    );
    return state;
  }

  /// Removes what the test left in [collections] and signs out, so the
  /// next test starts clean.
  Future<void> finish(
    WidgetTester tester,
    AppState state,
    Set<String> collections,
  ) async {
    try {
      final engine = state.engine;
      if (engine != null) {
        for (final c in collections) {
          for (final r in engine.records(c).toList()) {
            engine.delete(c, r.id);
          }
        }
        await engine.sync();
      }
      await state.signOut();
      await tester.pump(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('E2E clean-up failed: $e');
    }
  }

  // --- Shopping ---

  Future<void> newList(WidgetTester tester, String name) async {
    await openSection(tester, 'Einkauf');
    await tap(tester, find.byTooltip('Neue Liste'));
    await enter(tester, find.widgetWithText(TextField, 'Name'), name);
    await tap(tester, find.text('OK'));
    await waitFor(tester, find.byTooltip('Hinzufügen'));
  }

  /// Types [text] into a list's input and adds it; [shows] is the name the
  /// item gets ("2 Milch" becomes "Milch" with the amount 2).
  Future<void> addItem(WidgetTester tester, String text, String shows) async {
    await enter(tester, find.byType(TextField).first, text);
    await tap(tester, find.byTooltip('Hinzufügen'));
    await waitFor(tester, find.text(shows));
  }

  Future<void> listMenu(WidgetTester tester, String entry) async {
    await tap(tester, find.byType(PopupMenuButton<String>));
    await tap(tester, find.text(entry).last);
  }

  DateTime today() => DateUtils.dateOnly(DateTime.now());
  DateTime daysAgo(int n, [int hour = 12]) {
    final t = today();
    return DateTime(t.year, t.month, t.day - n, hour);
  }

  _FakePicker fakePicker() {
    final before = FilePickerPlatform.instance;
    final fake = _FakePicker();
    FilePickerPlatform.instance = fake;
    addTearDown(() => FilePickerPlatform.instance = before);
    return fake;
  }

  Future<File> tempFile(String name, List<int> bytes) async {
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}/famio-e2e-review',
    )..createSync(recursive: true);
    return File('${dir.path}/$name')..writeAsBytesSync(bytes);
  }

  /// Drops [file] onto the window, the way the system delivers a file
  /// dragged from the Finder.
  Future<void> dropFile(WidgetTester tester, File file) async {
    final target = tester.widget<DropTarget>(find.byType(DropTarget).first);
    target.onDragDone!(
      DropDoneDetails(
        files: [DropItemFile(file.path, name: file.uri.pathSegments.last)],
        localPosition: const Offset(200, 200),
        globalPosition: const Offset(200, 200),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('#230 Einkaufslisten: einstellen, wer eine Liste sieht', (
    tester,
  ) async {
    final papa = await member('e2e-papa', MemberRole.adult);
    final kid = await member('e2e-kind', MemberRole.child);
    final state = await start(tester);
    try {
      final engine = state.engine!;
      await newList(tester, 'E2E Geschenke');
      await addItem(tester, 'Geschenkpapier', 'Geschenkpapier');
      await addItem(tester, '6 Kerzen', 'Kerzen');
      await engine.sync();
      final list = engine.shoppingLists.singleWhere(
        (l) => l.name == 'E2E Geschenke',
      );

      // Before: the whole family gets the list and its items.
      final papaApi = await signInAs('e2e-papa');
      final kidApi = await signInAs('e2e-kind');
      var seen = await serverView(papaApi);
      expect(
        live(seen, Collections.shoppingLists).map((r) => r.id),
        contains(list.id),
      );
      expect(
        live(
          seen,
          Collections.shoppingItems,
        ).where((r) => r.data['listId'] == list.id).length,
        2,
      );

      // Only me and the child.
      await listMenu(tester, 'Wer sieht die Liste?');
      await tap(tester, find.text('Ich und …'));
      await tap(tester, find.widgetWithText(FilterChip, 'E2E Kind'));
      await tap(tester, find.text('Speichern').last);
      await until(
        tester,
        () =>
            engine.shoppingList(list.id)?.visibleTo?.toSet().containsAll({
              state.me!.id,
              kid.id,
            }) ??
            false,
        'list restricted',
      );
      await engine.sync();
      // The overview shows the lock with the names.
      await openSection(tester, 'Einkauf');
      await waitFor(tester, find.text('Sichtbar für: Admin, E2E Kind'));

      // The second adult gets neither the list nor its items any more …
      seen = await serverView(papaApi);
      expect(
        live(seen, Collections.shoppingLists).map((r) => r.id),
        isNot(contains(list.id)),
      );
      expect(
        live(
          seen,
          Collections.shoppingItems,
        ).where((r) => r.data['listId'] == list.id),
        isEmpty,
      );
      // … the child does.
      final kidSeen = await serverView(kidApi);
      expect(
        live(kidSeen, Collections.shoppingLists).map((r) => r.id),
        contains(list.id),
      );
      expect(
        live(
          kidSeen,
          Collections.shoppingItems,
        ).where((r) => r.data['listId'] == list.id).length,
        2,
      );

      // Nobody writes into a list they do not see.
      final sneaked = await papaApi.sync(
        SyncRequest(
          since: 0,
          changes: [
            SyncRecord(
              collection: Collections.shoppingItems,
              id: 'e2e-papa-item',
              data: ShoppingItem(
                id: 'e2e-papa-item',
                listId: list.id,
                name: 'E2E Papa war hier',
              ).toData(),
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ],
        ),
      );
      expect(
        sneaked.rejected.where((r) => r.id == 'e2e-papa-item' && r.deleted),
        isNotEmpty,
        reason: 'the write into the hidden list must be refused',
      );
      await engine.sync();
      expect(
        engine.shoppingItems(list.id).map((i) => i.name),
        isNot(contains('E2E Papa war hier')),
      );
      expect(papa.id, isNot(state.me!.id));
    } finally {
      await finish(tester, state, {
        Collections.shoppingLists,
        Collections.shoppingItems,
        Collections.shoppingHistory,
      });
    }
  });

  testWidgets('#213 Einkaufsliste als Text teilen', (tester) async {
    // The share sheet is native: the test reads what Famio hands to it.
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    final shared = <Map<Object?, Object?>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      shared.add(call.arguments as Map<Object?, Object?>);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final state = await start(tester);
    try {
      await newList(tester, 'E2E Oma kauft ein');
      await addItem(tester, '3 Äpfel', 'Äpfel');
      await addItem(tester, '2 Milch', 'Milch');
      await addItem(tester, 'Brot', 'Brot');
      // Already in the cart: not for grandma.
      await tap(tester, find.text('Brot'));
      await waitFor(tester, find.text('Im Wagen (1)'));

      await listMenu(tester, 'Als Text teilen');
      await until(tester, () => shared.isNotEmpty, 'share sheet called');
      final text = shared.single['text'] as String;
      debugPrint('E2E shared text:\n$text');
      expect(shared.single['subject'], 'E2E Oma kauft ein');
      final lines = text.split('\n');
      expect(lines.first, 'E2E Oma kauft ein');
      expect(lines, containsAll(['• 3 Äpfel', '• 2 Milch']));
      expect(text, isNot(contains('Brot')));
      // By aisle, with headings as there are two.
      expect(
        lines.indexOf('Obst & Gemüse'),
        lessThan(lines.indexOf('• 3 Äpfel')),
      );
      expect(lines.indexOf('Kühlregal'), lessThan(lines.indexOf('• 2 Milch')));
      expect(lines.indexOf('• 3 Äpfel'), lessThan(lines.indexOf('Kühlregal')));
    } finally {
      await finish(tester, state, {
        Collections.shoppingLists,
        Collections.shoppingItems,
        Collections.shoppingHistory,
      });
    }
  });

  testWidgets('#216 oft gekaufte Sachen und Stammartikel', (tester) async {
    // What the family bought over the last weeks.
    await seed([
      (
        Collections.shoppingLists,
        'e2e-l216',
        const ShoppingList(id: 'e2e-l216', name: 'E2E Wocheneinkauf').toData(),
      ),
      (
        Collections.shoppingHistory,
        'windeln',
        BoughtItem(
          key: 'windeln',
          name: 'Windeln',
          quantity: '1 Packung',
          count: 3,
          lastBought: daysAgo(15),
          listId: 'e2e-l216',
          everyDays: 14,
        ).toData(),
      ),
      (
        Collections.shoppingHistory,
        'milch',
        BoughtItem(
          key: 'milch',
          name: 'Milch',
          quantity: '2 l',
          count: 6,
          lastBought: daysAgo(2),
          listId: 'e2e-l216',
        ).toData(),
      ),
      (
        Collections.shoppingHistory,
        'bananen',
        BoughtItem(
          key: 'bananen',
          name: 'Bananen',
          quantity: '6',
          count: 2,
          lastBought: daysAgo(5),
          listId: 'e2e-l216',
        ).toData(),
      ),
    ]);
    final state = await start(tester);
    try {
      final engine = state.engine!;
      await openSection(tester, 'Einkauf');
      await tap(tester, find.text('E2E Wocheneinkauf'));

      // The staple is due again: back on the list by itself.
      await waitFor(tester, find.text('1 Stammartikel wieder auf der Liste.'));
      await waitFor(tester, find.text('Windeln'));
      expect(find.text('1 Packung'), findsOneWidget);

      // Quick picks: what the family buys, not what is on the list.
      await waitFor(tester, find.text('Oft gekauft:'));
      expect(find.widgetWithText(ActionChip, 'Milch'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Bananen'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Windeln'), findsNothing);
      await tap(tester, find.widgetWithText(ActionChip, 'Milch'));
      await waitFor(tester, find.text('2 l'));
      expect(find.widgetWithText(ActionChip, 'Milch'), findsNothing);

      // While typing: what matches.
      await enter(tester, find.byType(TextField).first, 'ban');
      await waitFor(tester, find.widgetWithText(ActionChip, 'Bananen'));
      expect(find.text('Oft gekauft:'), findsNothing);
      await tap(tester, find.widgetWithText(ActionChip, 'Bananen'));
      await until(
        tester,
        () => engine
            .shoppingItems('e2e-l216')
            .any((i) => i.name == 'Bananen' && i.quantity == '6'),
        'Bananen with the last amount on the list',
      );

      // Ticking off counts as bought.
      await tap(tester, find.text('Milch'));
      await until(
        tester,
        () => engine.boughtItem('milch')?.count == 7,
        'Milch counted as bought',
      );

      // Milch becomes a weekly staple.
      await listMenu(tester, 'Stammartikel');
      await waitFor(tester, find.text('7-mal gekauft'));
      expect(find.textContaining('wieder am'), findsOneWidget); // Windeln
      await tap(
        tester,
        find.descendant(
          of: find.ancestor(
            of: find.text('7-mal gekauft'),
            matching: find.byType(ListTile),
          ),
          matching: find.byType(DropdownButton<int?>),
        ),
      );
      await tap(tester, find.text('jede Woche').last);
      await until(
        tester,
        () => engine.boughtItem('milch')?.everyDays == 7,
        'Milch weekly',
      );
      await waitFor(tester, find.textContaining('7-mal gekauft · wieder am'));
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 500));

      await engine.sync();
      final view = await serverView(await admin());
      final milch = view['${Collections.shoppingHistory}/milch']!;
      expect((milch.data['count'], milch.data['everyDays']), (7, 7));
      expect(
        live(view, Collections.shoppingItems).where(
          (r) =>
              r.data['listId'] == 'e2e-l216' &&
              r.data['name'] == 'Windeln' &&
              r.id.startsWith('staple-'),
        ),
        hasLength(1),
      );
    } finally {
      await finish(tester, state, {
        Collections.shoppingLists,
        Collections.shoppingItems,
        Collections.shoppingHistory,
      });
    }
  });

  testWidgets('#204 Einkauf ins Haushaltsbuch', (tester) async {
    final state = await start(tester);
    try {
      final engine = state.engine!;
      await newList(tester, 'E2E Samstagseinkauf');
      await addItem(tester, 'Käse', 'Käse');
      await addItem(tester, 'Brot', 'Brot');
      await addItem(tester, 'Butter', 'Butter');
      await tap(tester, find.text('Brot'));
      await tap(tester, find.text('Butter'));
      await waitFor(tester, find.text('Im Wagen (2)'));

      await tap(tester, find.text('Bezahlt? Betrag ins Haushaltsbuch'));
      await waitFor(tester, find.text('Einkauf ins Haushaltsbuch'));
      expect(
        find.text('Die 2 abgehakten Sachen von der Liste nehmen'),
        findsOneWidget,
      );
      await enter(
        tester,
        find.widgetWithText(TextField, 'Betrag laut Kassenbon'),
        '23,45',
      );
      await tap(tester, find.text('Eintragen'));
      await waitFor(
        tester,
        find.textContaining('als Ausgabe für Lebensmittel eingetragen.'),
      );
      // The cart left the list; what is still to buy stays.
      await until(
        tester,
        () =>
            engine
                .shoppingItems(
                  engine.shoppingLists
                      .singleWhere((l) => l.name == 'E2E Samstagseinkauf')
                      .id,
                )
                .map((i) => i.name)
                .join(',') ==
            'Käse',
        'only Käse left on the list',
      );

      // In the budget, as today's groceries.
      await openSection(tester, 'Finanzen');
      await waitFor(tester, find.textContaining('23,45'));
      await engine.sync();
      final entries = live(
        await serverView(await admin()),
        Collections.budgetEntries,
      ).map(BudgetEntry.fromRecord).toList();
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(
        (entry.cents, entry.category, entry.income, entry.note, entry.date),
        (2345, 'Lebensmittel', false, 'E2E Samstagseinkauf', today()),
      );
    } finally {
      await finish(tester, state, {
        Collections.shoppingLists,
        Collections.shoppingItems,
        Collections.shoppingHistory,
        Collections.budgetEntries,
      });
    }
  });

  // --- Meals ---

  Recipe recipe(
    String id,
    String title,
    List<String> ingredients, {
    bool favorite = false,
    String steps = '',
    int servings = 4,
  }) => Recipe(
    id: id,
    title: title,
    favorite: favorite,
    servings: servings,
    steps: steps,
    ingredients: [
      for (final i in ingredients) Ingredient(name: i, amount: 200, unit: 'g'),
    ],
  );

  testWidgets('#203 Essensplan vorschlagen', (tester) async {
    final recipes = [
      recipe('e2e-f1', 'E2E Linsensuppe', ['Linsen'], favorite: true),
      recipe('e2e-f2', 'E2E Kürbisrisotto', [
        'Kürbis',
        'Risottoreis',
      ], favorite: true),
      recipe('e2e-f3', 'E2E Gemüselasagne', [
        'Zucchini',
        'Lasagneplatten',
      ], favorite: true),
      recipe('e2e-n1', 'E2E Pfannkuchen', ['Mehl', 'Milch', 'Eier']),
      recipe('e2e-n2', 'E2E Fischstäbchen', ['Fischstäbchen']),
      recipe('e2e-n3', 'E2E Bratkartoffeln', ['Kartoffeln']),
      recipe('e2e-n4', 'E2E Tomatensuppe', ['Tomaten']),
    ];
    final lastWeek = DateUtils.dateOnly(daysAgo(7));
    await seed([
      for (final r in recipes) (Collections.recipes, r.id, r.toData()),
      // The lentil soup was on the table a week ago.
      (
        Collections.mealPlan,
        'e2e-m-past',
        PlannedMeal(
          id: 'e2e-m-past',
          date: lastWeek,
          slot: MealSlot.dinner,
          recipeId: 'e2e-f1',
        ).toData(),
      ),
      for (final name in ['Mehl', 'Milch', 'Eier'])
        (
          Collections.pantryItems,
          'e2e-p-$name',
          PantryItem(id: 'e2e-p-$name', name: name, amount: 2).toData(),
        ),
    ]);
    final state = await start(tester);
    try {
      final engine = state.engine!;
      final now = today();
      final monday = DateTime(now.year, now.month, now.day - now.weekday + 1);
      final days = 8 - now.weekday; // today to Sunday
      final planned = days < 6 ? days : 6;

      await openSection(tester, 'Essen');
      await tap(tester, find.text('Woche vorschlagen'));
      await waitFor(tester, find.text('Vorschlag für die Woche'));
      // Not what was there in the last two weeks.
      expect(find.textContaining('E2E Linsensuppe'), findsNothing);
      if (days >= 2) {
        expect(find.text('E2E Kürbisrisotto ★'), findsOneWidget);
        expect(find.text('E2E Gemüselasagne ★'), findsOneWidget);
      }
      if (days >= 3) {
        expect(find.text('E2E Pfannkuchen'), findsOneWidget);
        expect(find.text('3 von 3 Zutaten im Vorrat'), findsOneWidget);
      }
      await tap(tester, find.text('$planned einplanen'));
      await waitFor(
        tester,
        find.text(
          planned == 1 ? '1 Essen eingeplant.' : '$planned Essen eingeplant.',
        ),
      );

      final week =
          engine
              .plannedMeals(
                monday,
                DateTime(monday.year, monday.month, monday.day + 7),
              )
              .toList()
            ..sort((a, b) => a.date.compareTo(b.date));
      expect(week, hasLength(planned));
      expect(week.map((m) => m.slot).toSet(), {MealSlot.dinner});
      expect(week.map((m) => m.date).toSet(), hasLength(planned));
      expect(week.first.date, now);
      expect(week.map((m) => m.recipeId), isNot(contains('e2e-f1')));
      // Favourites first, then what the pantry covers.
      if (days >= 2) {
        expect(week.take(2).map((m) => m.recipeId).toSet(), {
          'e2e-f2',
          'e2e-f3',
        });
      }
      if (days >= 3) expect(week[2].recipeId, 'e2e-n1');
      await waitFor(tester, find.text('E2E Kürbisrisotto'));

      await engine.sync();
      final onServer = live(
        await serverView(await admin()),
        Collections.mealPlan,
      ).where((r) => r.id != 'e2e-m-past');
      expect(onServer, hasLength(planned));
    } finally {
      await finish(tester, state, {
        Collections.recipes,
        Collections.mealPlan,
        Collections.pantryItems,
      });
    }
  });

  testWidgets('#185 Kochmodus mit Schritten und Timern', (tester) async {
    await seed([
      (
        Collections.recipes,
        'e2e-r185',
        const Recipe(
          id: 'e2e-r185',
          title: 'E2E Spaghetti',
          servings: 2,
          ingredients: [
            Ingredient(name: 'Spaghetti', amount: 200, unit: 'g'),
            Ingredient(name: 'Tomaten', amount: 1, unit: 'Dose'),
          ],
          steps:
              'Wasser zum Kochen bringen.\n'
              'Spaghetti 10 Minuten kochen.\n'
              'Soße 5 Sekunden pürieren.',
        ).toData(),
      ),
    ]);
    final state = await start(tester);
    try {
      await openSection(tester, 'Essen');
      await tap(tester, find.text('Rezepte'));
      await tap(tester, find.text('E2E Spaghetti'));
      await tap(tester, find.text('Kochmodus'));

      // First the ingredients to tick off.
      await waitFor(tester, find.text('Zutaten · Portionen 2'));
      await tap(tester, find.text('200 g Spaghetti'));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.ancestor(
                of: find.text('200 g Spaghetti'),
                matching: find.byType(CheckboxListTile),
              ),
            )
            .value,
        isTrue,
      );
      // The screen stays on.
      await tester.pump(const Duration(milliseconds: 500));
      expect(await WakelockPlus.enabled, isTrue);

      // One big step per page.
      await tap(tester, find.text('Weiter'));
      await waitFor(tester, find.text('Wasser zum Kochen bringen.'));
      expect(find.text('Schritt 1 von 3'), findsWidgets);
      await tap(tester, find.text('Weiter'));
      await waitFor(tester, find.text('Spaghetti 10 Minuten kochen.'));
      // The time in the step is a timer.
      await tap(tester, find.text('Timer 10 Min.'));
      await waitFor(tester, find.textContaining('Schritt 2 von 3 · 09:'));

      await tap(tester, find.text('Weiter'));
      await waitFor(tester, find.text('Soße 5 Sekunden pürieren.'));
      await tap(tester, find.text('Timer 5 Sek.'));
      await waitFor(tester, find.textContaining('Schritt 3 von 3 · 00:0'));
      // It rings.
      await waitFor(
        tester,
        find.text('Timer abgelaufen'),
        timeout: const Duration(seconds: 20),
      );
      expect(find.text('E2E Spaghetti: Schritt 3'), findsOneWidget);
      await tap(tester, find.text('OK'));

      // Leaving with a running timer asks first.
      await tap(tester, find.byTooltip('Schließen'));
      await waitFor(tester, find.text('Kochmodus verlassen?'));
      await tap(tester, find.text('Timer beenden'));
      await waitFor(tester, find.text('Kochmodus'));
      expect(find.text('Zutaten · Portionen 2'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(await WakelockPlus.enabled, isFalse);
    } finally {
      await finish(tester, state, {Collections.recipes});
    }
  });

  testWidgets('#122 Rezepte: Nährwerte über Open Food Facts', (tester) async {
    await seed([
      (
        Collections.recipes,
        'e2e-r122',
        const Recipe(
          id: 'e2e-r122',
          title: 'E2E Haferbrei',
          servings: 2,
          ingredients: [
            Ingredient(name: 'Haferflocken', amount: 100, unit: 'g'),
            Ingredient(name: 'Honig', amount: 20, unit: 'g'),
          ],
          steps: 'Alles aufkochen.',
        ).toData(),
      ),
    ]);
    final state = await start(tester);
    try {
      final engine = state.engine!;
      await openSection(tester, 'Essen');
      await tap(tester, find.text('Rezepte'));
      await tap(tester, find.text('E2E Haferbrei'));
      await tap(tester, find.text('Nährwerte aus Open Food Facts'));
      // Asked once per device.
      await waitFor(tester, find.text('Open Food Facts fragen?'));
      await tap(tester, find.text('Erlauben'));
      await waitFor(tester, find.text('Nährwerte verknüpfen'));
      expect(find.text('nicht verknüpft'), findsNWidgets(2));

      await tap(tester, find.byTooltip('Suchen').first);
      final results = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(ListTile),
      );
      final offline = find.text('Open Food Facts ist gerade nicht erreichbar.');
      final answered = find.byWidgetPredicate(
        (w) =>
            (w is Text &&
                (w.data == 'Open Food Facts ist gerade nicht erreichbar.' ||
                    w.data == 'Nichts gefunden.')) ||
            (w is ListTile &&
                w.subtitle is Text &&
                ((w.subtitle as Text).data ?? '').contains('kcal je 100 g')),
      );
      // Its search is often busy (HTTP 503): a person tries again.
      for (var attempt = 1; ; attempt++) {
        await waitFor(tester, answered, timeout: const Duration(seconds: 60));
        if (offline.evaluate().isEmpty || attempt == 8) break;
        debugPrint('E2E Open Food Facts busy, attempt $attempt');
        await tester.pump(const Duration(seconds: 3));
        await tap(
          tester,
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byTooltip('Suchen'),
          ),
        );
      }
      expect(
        find.text('Open Food Facts ist gerade nicht erreichbar.'),
        findsNothing,
        reason: 'world.openfoodfacts.org not reachable',
      );
      expect(results, findsWidgets);
      final product =
          (tester.widget<ListTile>(results.first).title as Text).data!;
      debugPrint('E2E Open Food Facts product: $product');
      await tap(tester, results.first);
      await until(
        tester,
        () =>
            engine.recipe('e2e-r122')?.ingredients.first.nutrition?.product ==
            product,
        'Haferflocken linked',
      );
      await waitFor(tester, find.textContaining('$product · '));
      expect(find.text('nicht verknüpft'), findsOneWidget);

      // Back in the recipe: per serving, from one of two ingredients.
      await tap(tester, find.byTooltip('Zurück'));
      await waitFor(
        tester,
        find.text('pro Portion, ungefähr · aus 1 von 2 Zutaten'),
      );
      expect(find.text('kcal'), findsOneWidget);
      final perServing = engine.recipe('e2e-r122')!.nutritionPerServing!;
      expect(perServing.kcal, greaterThan(0));

      await engine.sync();
      final stored = (await serverView(
        await admin(),
      ))['${Collections.recipes}/e2e-r122']!;
      final first = (stored.data['ingredients'] as List).first as Map;
      expect(first['nutrition'], isA<Map<Object?, Object?>>());
    } finally {
      await finish(tester, state, {Collections.recipes});
    }
  });

  // --- Calendar and start page ---

  testWidgets('#202 Wochenplan zum Ausdrucken (PDF)', (tester) async {
    final picker = fakePicker();
    final now = today();
    await seed([
      (
        Collections.events,
        'e2e-e202',
        CalendarEvent(
          id: 'e2e-e202',
          title: 'E2E Kinderarzt',
          start: DateTime(now.year, now.month, now.day, 16),
          end: DateTime(now.year, now.month, now.day, 17),
        ).toData(),
      ),
      (
        Collections.mealPlan,
        'e2e-m202',
        PlannedMeal(
          id: 'e2e-m202',
          date: now,
          slot: MealSlot.dinner,
          title: 'E2E Nudelauflauf',
        ).toData(),
      ),
    ]);
    final state = await start(tester);
    try {
      await openSection(tester, 'Kalender');
      await tap(tester, find.byTooltip('Wochenplan drucken'));
      await waitFor(tester, find.text('Welche Woche?'));
      await tap(tester, find.text('Diese Woche'));
      // The save panel is native: the test takes the PDF it gets.
      await waitFor(tester, find.text('Wochenplan gespeichert.'));
      final saved = picker.saved.single;
      final monday = DateTime(now.year, now.month, now.day - now.weekday + 1);
      expect(
        saved.fileName,
        'famio-plan-${DateFormat('yyyy-MM-dd').format(monday)}.pdf',
      );
      expect(saved.mimeType, 'application/pdf');
      expect(ascii.decode(saved.bytes.take(5).toList()), '%PDF-');
      // Its text, read with the system's PDF reader.
      final file = await tempFile(saved.fileName, saved.bytes);
      final text = await Ocr.pdfText(file.path);
      debugPrint('E2E week plan text: $text');
      expect(text, isNotNull);
      expect(text, contains('Wochenplan'));
      expect(text, contains('E2E Kinderarzt'));
      expect(text, contains('E2E Nudelauflauf'));
    } finally {
      await finish(tester, state, {Collections.events, Collections.mealPlan});
    }
  });

  Future<Uint8List> pngBytes() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 64, 64),
      Paint()..color = const Color(0xFF3D8FD1),
    );
    final image = await recorder.endRecording().toImage(64, 64);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  testWidgets('#214 Heute vor einem Jahr auf der Startseite', (tester) async {
    final api = await admin();
    final me = await api.me();
    final now = today();
    final yearAgo = DateTime(now.year - 1, now.month, now.day);
    final photo = await api.uploadFile(
      bytes: await pngBytes(),
      name: 'strand.png',
      mime: 'image/png',
    );
    await seed([
      (
        Collections.children,
        'e2e-k214',
        Child(
          id: 'e2e-k214',
          name: 'E2E Mia',
          birthDate: DateTime(now.year - 3, 5, 1),
        ).toData(),
      ),
      (
        Collections.childEntries,
        'e2e-m214',
        ChildEntry(
          id: 'e2e-m214',
          childId: 'e2e-k214',
          kind: ChildEntryKind.milestone,
          date: yearAgo,
          title: 'Erste Schritte',
        ).toData(),
      ),
      (
        Collections.events,
        'e2e-e214',
        CalendarEvent(
          id: 'e2e-e214',
          title: 'E2E Ostsee-Urlaub',
          start: DateTime(yearAgo.year, yearAgo.month, yearAgo.day - 1),
          end: DateTime(yearAgo.year, yearAgo.month, yearAgo.day + 2),
          allDay: true,
        ).toData(),
      ),
      (
        Collections.chatMessages,
        'e2e-c214',
        ChatMessage(
          id: 'e2e-c214',
          chatId: ChatIds.family,
          authorId: me.id,
          sentAt: DateTime(yearAgo.year, yearAgo.month, yearAgo.day, 15),
          attachment: photo,
        ).toData(),
      ),
    ]);
    final state = await start(tester);
    try {
      await openSection(tester, 'Start');
      await waitFor(tester, find.text('Heute vor einem Jahr'));
      expect(find.text('E2E Mia: Erste Schritte'), findsOneWidget);
      expect(find.text('E2E Ostsee-Urlaub'), findsOneWidget);
      expect(find.text('1 Foto von diesem Tag'), findsOneWidget);

      // A tap opens the photo in Famio.
      await tap(
        tester,
        find.descendant(
          of: find
              .ancestor(
                of: find.text('1 Foto von diesem Tag'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byType(CachedImage),
        ),
      );
      await waitFor(tester, find.byType(PhotoViewer));
      await tap(tester, find.byTooltip('Schließen').last);
      await until(
        tester,
        () => find.byType(PhotoViewer).evaluate().isEmpty,
        'photo viewer closed',
      );

      // Only what the member may see: a guest gets no child's milestone.
      await member('e2e-gast', MemberRole.guest);
      final guestView = await serverView(await signInAs('e2e-gast'));
      expect(guestView['${Collections.childEntries}/e2e-m214'], isNull);

      // Hidden for today.
      await tap(tester, find.text('Für heute ausblenden'));
      await until(
        tester,
        () => find.text('Heute vor einem Jahr').evaluate().isEmpty,
        'memories hidden',
      );
      expect(find.text('E2E Mia: Erste Schritte'), findsNothing);
    } finally {
      await finish(tester, state, {
        Collections.childEntries,
        Collections.children,
        Collections.events,
        Collections.chatMessages,
      });
    }
  });

  testWidgets('#121 Haushaltsbuch: Kontoauszug-Import (CSV, CAMT.053)', (
    tester,
  ) async {
    final picker = fakePicker();
    String day(DateTime d) => DateFormat('dd.MM.yy').format(d);
    String iso(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
    // Bookings the family entered earlier: the farm shop as groceries, the
    // nursery fee by hand.
    await seed([
      (
        Collections.budgetEntries,
        'e2e-b-hof',
        BudgetEntry(
          id: 'e2e-b-hof',
          date: DateUtils.dateOnly(daysAgo(20)),
          cents: 2500,
          category: 'Lebensmittel',
          note: 'Hofladen Sonnenberg – Gemüsekiste',
        ).toData(),
      ),
      (
        Collections.budgetEntries,
        'e2e-b-kita',
        BudgetEntry(
          id: 'e2e-b-kita',
          date: DateUtils.dateOnly(daysAgo(4)),
          cents: 12000,
          category: 'Kinder',
          note: 'Kita',
        ).toData(),
      ),
    ]);
    // A Sparkasse-like CSV export: three booked, one pending.
    final csv = await tempFile(
      'umsaetze.csv',
      utf8.encode(
        '"Auftragskonto";"Buchungstag";"Valutadatum";"Buchungstext";'
        '"Verwendungszweck";"Beguenstigter/Zahlungspflichtiger";"Betrag";'
        '"Waehrung";"Info"\r\n'
        '"DE00";"${day(daysAgo(3))}";"${day(daysAgo(3))}";"KARTENZAHLUNG";'
        '"Gemuesekiste";"Hofladen Sonnenberg";"-18,40";"EUR";"Umsatz gebucht"\r\n'
        '"DE00";"${day(daysAgo(3))}";"${day(daysAgo(3))}";"LASTSCHRIFT";'
        '"Beitrag";"Kita Sonnenschein";"-120,00";"EUR";"Umsatz gebucht"\r\n'
        '"DE00";"${day(daysAgo(5))}";"${day(daysAgo(5))}";"LASTSCHRIFT";'
        '"Abschlag Strom";"Stadtwerke";"-85,00";"EUR";"Umsatz gebucht"\r\n'
        '"DE00";"${day(daysAgo(1))}";"${day(daysAgo(1))}";"KARTENZAHLUNG";'
        '"Eis";"Eiscafe";"-6,50";"EUR";"Umsatz vorgemerkt"\r\n',
      ),
    );
    final camt = await tempFile(
      'auszug.xml',
      utf8.encode('''<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08">
<BkToCstmrStmt><Stmt><Id>1</Id>
<Ntry>
  <Amt Ccy="EUR">45.67</Amt><CdtDbtInd>DBIT</CdtDbtInd>
  <Sts><Cd>BOOK</Cd></Sts>
  <BookgDt><Dt>${iso(daysAgo(2))}</Dt></BookgDt>
  <AcctSvcrRef>E2E-REWE-1</AcctSvcrRef>
  <NtryDtls><TxDtls>
    <RltdPties><Cdtr><Pty><Nm>REWE Markt GmbH</Nm></Pty></Cdtr></RltdPties>
    <RmtInf><Ustrd>Einkauf</Ustrd></RmtInf>
  </TxDtls></NtryDtls>
</Ntry>
<Ntry>
  <Amt Ccy="EUR">2500.00</Amt><CdtDbtInd>CRDT</CdtDbtInd>
  <Sts><Cd>BOOK</Cd></Sts>
  <BookgDt><Dt>${iso(daysAgo(2))}</Dt></BookgDt>
  <AcctSvcrRef>E2E-GEHALT-1</AcctSvcrRef>
  <NtryDtls><TxDtls>
    <RltdPties><Dbtr><Nm>Arbeitgeber AG</Nm></Dbtr></RltdPties>
    <RmtInf><Ustrd>Gehalt</Ustrd></RmtInf>
  </TxDtls></NtryDtls>
</Ntry>
</Stmt></BkToCstmrStmt></Document>
'''),
    );
    final state = await start(tester);
    try {
      final engine = state.engine!;
      Finder row(String title) => find.ancestor(
        of: find.text(title),
        matching: find.byType(CheckboxListTile),
      );

      await openSection(tester, 'Finanzen');
      picker.picks.add(csv);
      await tap(tester, find.byTooltip('Kontoauszug importieren'));
      await waitFor(
        tester,
        find.text('3 Buchungen · 1 schon im Haushaltsbuch'),
      );
      expect(find.text('Eiscafe'), findsNothing); // pending: left out
      // The category the family chose before for the same payee.
      expect(
        find.descendant(
          of: row('Hofladen Sonnenberg'),
          matching: find.text('Lebensmittel'),
        ),
        findsOneWidget,
      );
      // The nursery fee entered by hand: probably a duplicate, not ticked.
      expect(
        find.descendant(
          of: row('Kita Sonnenschein'),
          matching: find.text('Vielleicht schon eingetragen'),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<CheckboxListTile>(row('Kita Sonnenschein')).value,
        isFalse,
      );
      expect(
        tester.widget<CheckboxListTile>(row('Hofladen Sonnenberg')).value,
        isTrue,
      );
      await tap(tester, find.text('2 Buchungen übernehmen'));
      await waitFor(tester, find.text('2 Buchungen übernommen'));

      // CAMT.053 from another bank.
      picker.picks.add(camt);
      await tap(tester, find.byTooltip('Kontoauszug importieren'));
      await waitFor(tester, find.text('2 Buchungen'));
      expect(
        find.descendant(
          of: row('Arbeitgeber AG'),
          matching: find.text('Gehalt'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row('REWE Markt GmbH'),
          matching: find.text('Lebensmittel'),
        ),
        findsOneWidget,
      );
      await snackGone(tester);
      await tap(tester, find.text('2 Buchungen übernehmen'));
      await waitFor(tester, find.text('2 Buchungen übernommen'));

      // The same statement again: nothing new.
      picker.picks.add(csv);
      await tap(tester, find.byTooltip('Kontoauszug importieren'));
      await waitFor(
        tester,
        find.text('3 Buchungen · 3 schon im Haushaltsbuch'),
      );
      expect(find.text('Schon im Haushaltsbuch'), findsNWidgets(2));
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.ancestor(
                of: find.text('0 Buchungen übernehmen'),
                matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, find.byTooltip('Zurück'));

      await engine.sync();
      final entries = live(
        await serverView(await admin()),
        Collections.budgetEntries,
      ).map(BudgetEntry.fromRecord).toList();
      expect(entries, hasLength(6));
      final imported = {
        for (final e in entries)
          if (e.importId != null) e.note: (e.cents, e.category, e.income),
      };
      debugPrint('E2E imported: $imported');
      expect(imported.keys.toSet(), {
        'Hofladen Sonnenberg – Gemuesekiste',
        'Stadtwerke – Abschlag Strom',
        'REWE Markt GmbH – Einkauf',
        'Arbeitgeber AG – Gehalt',
      });
      expect(imported['Hofladen Sonnenberg – Gemuesekiste'], (
        1840,
        'Lebensmittel',
        false,
      ));
      expect(imported['Stadtwerke – Abschlag Strom']?.$1, 8500);
      expect(imported['REWE Markt GmbH – Einkauf'], (
        4567,
        'Lebensmittel',
        false,
      ));
      expect(imported['Arbeitgeber AG – Gehalt'], (250000, 'Gehalt', true));
    } finally {
      await finish(tester, state, {Collections.budgetEntries});
    }
  });

  testWidgets('#136 Termine aus englischem und spanischem Text', (
    tester,
  ) async {
    final state = await start(tester);
    try {
      final engine = state.engine!;
      final day = DateFormat.yMMMEd('de');
      // Past dates are offered, but not ticked.
      final year = DateTime.now().year + 1;

      Future<void> recognize(String text, List<String> expected) async {
        await openSection(tester, 'Kalender');
        await tap(
          tester,
          find.byTooltip('Termine aus Foto, Text oder Kalenderdatei'),
        );
        await enter(
          tester,
          find.widgetWithText(TextField, 'Oder Text hier einfügen'),
          text,
        );
        await tap(tester, find.text('Termine suchen'));
        for (final when in expected) {
          await waitFor(tester, find.text(when));
        }
        await tap(tester, find.text('${expected.length} Termine übernehmen'));
        await waitFor(
          tester,
          find.text('${expected.length} Termine eingetragen'),
        );
      }

      await recognize(
        'Dear parents,\n'
        'the parent evening is on December 11, $year at 2:30 pm.\n'
        'School party 10/12/$year',
        [
          '${day.format(DateTime(year, 12, 11))}, 14:30–15:30 Uhr',
          '${day.format(DateTime(year, 10, 12))}, ganztägig',
        ],
      );
      await recognize(
        'Queridas familias:\n'
        'la reunión de padres será el 15 de diciembre de $year a las 18:30 h.\n'
        'Fiesta 10/12/$year',
        [
          '${day.format(DateTime(year, 12, 15))}, 18:30–19:30 Uhr',
          '${day.format(DateTime(year, 12, 10))}, ganztägig',
        ],
      );

      final events = {for (final e in engine.events) e.title: e};
      (int, int, int, int, int) at(DateTime d) =>
          (d.year, d.month, d.day, d.hour, d.minute);
      debugPrint('E2E recognised: ${events.keys.join(' | ')}');
      final evening = events['Parent evening']!;
      expect(at(evening.start), (year, 12, 11, 14, 30));
      expect(evening.allDay, isFalse);
      // Month first in an English text …
      expect(at(events['School party']!.start), (year, 10, 12, 0, 0));
      final meeting = events['Reunión de padres']!;
      expect(at(meeting.start), (year, 12, 15, 18, 30));
      // … day first in a Spanish one.
      expect(at(events['Fiesta']!.start), (year, 12, 10, 0, 0));
      expect(events['Fiesta']?.allDay, isTrue);
    } finally {
      await finish(tester, state, {Collections.events});
    }
  });

  const ics = '''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Famio E2E//Review//DE
BEGIN:VEVENT
UID:e2e-swim@famio.test
DTSTAMP:20261101T120000Z
DTSTART:20261110T153000Z
DTEND:20261110T163000Z
RRULE:FREQ=WEEKLY;COUNT=8
EXDATE:20261124T153000Z
SUMMARY:E2E Schwimmkurs
LOCATION:Hallenbad
END:VEVENT
BEGIN:VEVENT
UID:e2e-dentist@famio.test
DTSTAMP:20261101T120000Z
DTSTART:20261203T080000Z
DTEND:20261203T083000Z
SUMMARY:E2E Zahnarzt
END:VEVENT
BEGIN:VEVENT
UID:e2e-meetup@famio.test
DTSTAMP:20261101T120000Z
DTSTART;VALUE=DATE:20261127
DTEND;VALUE=DATE:20261128
RRULE:FREQ=MONTHLY;BYDAY=-1FR
SUMMARY:E2E Elternstammtisch
END:VEVENT
END:VCALENDAR
''';

  testWidgets('#150 Kalenderdateien (.ics) importieren', (tester) async {
    final picker = fakePicker();
    final file = await tempFile('termine.ics', utf8.encode(ics));
    final state = await start(tester);
    try {
      final engine = state.engine!;
      int count(String title) =>
          engine.events.where((e) => e.title == title).length;

      // Dragged onto the window.
      await dropFile(tester, file);
      await waitFor(tester, find.text('Kalenderdatei (.ics)'));
      await dismissTip(tester);
      await waitFor(tester, find.textContaining('Termine in der Datei'));
      // The last Friday of a month has no Famio rule: single events.
      expect(
        find.textContaining('als einzelne Termine übernommen'),
        findsOneWidget,
      );
      await scrollTo(tester, find.text('E2E Schwimmkurs'));
      expect(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('E2E Schwimmkurs'),
                matching: find.byType(Column),
              )
              .first,
          matching: find.textContaining('wiederholt sich'),
        ),
        findsOneWidget,
        reason: 'the swimming course stays a series',
      );
      final take = find.textContaining(RegExp(r'^\d+ Termine übernehmen$'));
      await scrollTo(tester, take);
      final n = int.parse((tester.widget<Text>(take).data!).split(' ').first);
      await tap(tester, take);
      await waitFor(tester, find.text('$n Termine eingetragen'));
      expect(count('E2E Zahnarzt'), 1);
      final swim = engine.events.singleWhere(
        (e) => e.title == 'E2E Schwimmkurs',
      );
      expect(swim.recurrence, isNotNull);
      expect(swim.exceptions, isNotEmpty);
      expect(swim.location, 'Hallenbad');
      final meetups = count('E2E Elternstammtisch');
      expect(meetups, greaterThan(12));

      // The same file again through "Termine erkennen": updated, not doubled.
      await openSection(tester, 'Kalender');
      await tap(
        tester,
        find.byTooltip('Termine aus Foto, Text oder Kalenderdatei'),
      );
      picker.picks.add(file);
      await tap(tester, find.text('Kalenderdatei (.ics)'));
      await waitFor(tester, find.text('Schon in Famio – wird aktualisiert'));
      await scrollTo(tester, find.text('$n Termine übernehmen'));
      await snackGone(tester);
      await tap(tester, find.text('$n Termine übernehmen'));
      await waitFor(tester, find.text('$n Termine eingetragen'));
      expect(count('E2E Zahnarzt'), 1);
      expect(count('E2E Schwimmkurs'), 1);
      expect(count('E2E Elternstammtisch'), meetups);

      await engine.sync();
      final onServer = live(
        await serverView(await admin()),
        Collections.events,
      );
      expect(onServer, hasLength(engine.events.length));
    } finally {
      await finish(tester, state, {Collections.events});
    }
  });

  testWidgets('#244 Dokumente nach Inhalt durchsuchen', (tester) async {
    await member('e2e-papa', MemberRole.adult);
    // A scan with a text layer, as a scanner app or the bank makes it.
    final doc = pw.Document()
      ..addPage(
        pw.Page(
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Stadtverwaltung Musterstadt'),
              pw.Text('Grundsteuerbescheid fuer das Jahr 2027'),
              pw.Text('Aktenzeichen QX4711-B'),
            ],
          ),
        ),
      );
    final file = await tempFile('scan-0815.pdf', await doc.save());
    final state = await start(tester);
    try {
      final engine = state.engine!;
      await dropFile(tester, file);
      await waitFor(tester, find.text('Teilen an Famio'));
      await tap(tester, find.text('Als Dokument speichern'));
      await waitFor(tester, find.text('Neues Dokument'));
      // Read on this device.
      await waitFor(
        tester,
        find.textContaining('Text erkannt ('),
        timeout: const Duration(seconds: 60),
      );
      await tap(tester, find.text('Speichern').last);
      await waitFor(tester, find.text('scan 0815'));
      await until(
        tester,
        () => engine.documents.any(
          (d) => d.title == 'scan 0815' && d.content.contains('QX4711'),
        ),
        'document with its text',
      );

      // Found by a word that is only in the file.
      await enter(tester, find.widgetWithText(TextField, 'Suchen …'), 'qx4711');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('scan 0815'), findsOneWidget);
      await enter(tester, find.byType(TextField).first, 'steuererklaerung');
      await waitFor(tester, find.text('Nichts gefunden.'));
      expect(find.text('scan 0815'), findsNothing);

      // The search over everything shows where.
      await openSection(tester, 'Start');
      await tap(tester, find.byTooltip('Suchen'));
      await enter(
        tester,
        find.widgetWithText(TextField, 'Termin, Aufgabe, Rezept, Kontakt …'),
        'QX4711',
      );
      await waitFor(tester, find.text('scan 0815'));
      await waitFor(tester, find.textContaining('Aktenzeichen QX4711'));

      // The text travels with the document to the family.
      await engine.sync();
      final papaView = await serverView(await signInAs('e2e-papa'));
      final stored = live(papaView, Collections.documents)
          .map(FamilyDocument.fromRecord)
          .singleWhere((d) => d.title == 'scan 0815');
      expect(stored.content, contains('Grundsteuerbescheid'));
      expect(stored.file?.mime, 'application/pdf');
    } finally {
      await finish(tester, state, {Collections.documents});
    }
  });

  testWidgets('#152 Aufgaben: Fotos anhängen', (tester) async {
    await member('e2e-papa', MemberRole.adult);
    // The task editor attaches through the file picker (on the Mac there
    // is no camera choice): the test hands in the photo a person picks.
    final picker = fakePicker();
    final png = await pngBytes();
    final photoFile = await tempFile('zimmer.png', png);
    final state = await start(tester);
    try {
      final engine = state.engine!;
      await openSection(tester, 'Aufgaben');
      await tap(tester, find.byTooltip('Aufgabe mit Details anlegen'));
      await waitFor(tester, find.text('Neue Aufgabe'));
      await enter(
        tester,
        find.widgetWithText(TextField, 'Titel'),
        'E2E Zimmer aufräumen',
      );
      await tap(tester, find.text('Checkliste, Dateien, Sichtbarkeit'));
      picker.picks.add(photoFile);
      await tap(tester, find.byTooltip('Foto oder Datei anhängen'));
      // Uploaded right away; the editor shows the picture.
      final thumb = find.byWidgetPredicate(
        (w) =>
            w is Semantics && w.properties.label == 'Anhang öffnen: zimmer.png',
      );
      await waitFor(tester, thumb);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(CachedImage),
        ),
        findsOneWidget,
      );
      await tap(tester, find.text('Speichern').last);

      // In the list: the task with its photo.
      await until(
        tester,
        () => engine.tasks.any((t) => t.title == 'E2E Zimmer aufräumen'),
        'task saved',
      );
      final task = engine.tasks.singleWhere(
        (t) => t.title == 'E2E Zimmer aufräumen',
      );
      expect(task.photos, hasLength(1));
      final photo = task.photos.single;
      expect(
        (photo.name, photo.mime, photo.size),
        ('zimmer.png', 'image/png', png.length),
      );
      await waitFor(tester, find.text('E2E Zimmer aufräumen'));
      final row = find.ancestor(
        of: find.text('E2E Zimmer aufräumen'),
        matching: find.byType(Row),
      );
      await waitFor(
        tester,
        find.descendant(of: row, matching: find.byType(CachedImage)),
      );

      // Opened again, a tap on the picture shows it in Famio's viewer.
      await tap(tester, find.text('E2E Zimmer aufräumen'));
      await waitFor(tester, find.text('Aufgabe bearbeiten'));
      await tap(tester, thumb);
      await waitFor(tester, find.byType(PhotoViewer));
      await tap(tester, find.byTooltip('Schließen').last);
      await until(
        tester,
        () => find.byType(PhotoViewer).evaluate().isEmpty,
        'photo viewer closed',
      );
      await tap(tester, find.text('Speichern').last);
      await until(
        tester,
        () => find.text('Aufgabe bearbeiten').evaluate().isEmpty,
        'editor closed',
      );

      // On the server: the task's reference and the file itself.
      await engine.sync();
      final api = await admin();
      final stored = Task.fromRecord(
        (await serverView(api))['${Collections.tasks}/${task.id}']!,
      );
      expect(stored.photos.map((f) => f.id), [photo.id]);
      expect(await api.downloadFile(photo.id), png);

      // A second adult gets the task and may fetch the photo.
      final papaApi = await signInAs('e2e-papa');
      final papaTask = live(
        await serverView(papaApi),
        Collections.tasks,
      ).map(Task.fromRecord).singleWhere((t) => t.id == task.id);
      expect(papaTask.photos.map((f) => f.id), [photo.id]);
      expect(await papaApi.downloadFile(photo.id), png);
    } finally {
      await finish(tester, state, {Collections.tasks});
    }
  });
}
