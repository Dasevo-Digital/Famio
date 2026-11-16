import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/shopping_history.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/event_editor.dart';
import 'package:famio/src/screens/kids_log_screens.dart';
import 'package:famio/src/screens/kids_screens.dart';
import 'package:famio/src/screens/shopping_screens.dart';
import 'package:famio/src/screens/tasks_screen.dart';
import 'package:famio/src/widgets/sheet_messenger.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Picked extends PlatformFile {
  _Picked(this.bytes);

  final Uint8List bytes;

  @override
  String get name => 'foto.png';
  @override
  Uri get uri => Uri.parse('memory:foto.png');
  @override
  String? get path => null;
  @override
  get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => bytes.length;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _Picker extends FilePickerPlatform {
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
  }) async => [_Picked(Uint8List.fromList(utf8.encode('bild')))];
}

const _uploadFailed = 'Der Speicher ist voll';

/// Messages of a sheet ("Rückgängig" after deleting, a failed upload, a
/// hint about the form) show over the sheet, where they can be read and
/// tapped, not on the page below it (ALL-121, #364).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  Future<BuildContext> open(
    WidgetTester tester, {
    String members = '[]',
    String me = 'm1',
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    final before = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker();
    addTearDown(() => FilePickerPlatform.instance = before);
    // Every upload fails, the rest is offline.
    final client = MockClient((r) async {
      if (r.url.path.contains('files')) {
        return http.Response(
          jsonEncode({'error': 'storage_full', 'message': _uploadFailed}),
          507,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 503);
    });
    final state = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', members),
      api: FamioApiClient('localhost:1', httpClient: client),
      memberId: me,
    );
    state
      ..me = FamilyMember(id: me, username: 'mama', displayName: 'Mama')
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    return tester.element(find.byType(Scaffold).first);
  }

  /// What a finger hits there is the message, not the sheet or its barrier.
  void reachable(Finder finder) =>
      expect(finder.hitTestable(), findsOneWidget, reason: '$finder');

  Future<void> closeSheet(WidgetTester tester) async {
    await tester.tapAt(const Offset(195, 20));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  }

  group('SheetMessenger', () {
    Future<Size> sheetSize(WidgetTester tester, {required bool wrapped}) async {
      final context = await open(tester);
      final content = Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Inhalt'),
            TextButton(onPressed: () {}, child: const Text('Knopf')),
          ],
        ),
      );
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          builder: (_) => wrapped ? SheetMessenger(child: content) : content,
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(BottomSheet));
    }

    testWidgets('the sheet keeps its size', (tester) async {
      final plain = await sheetSize(tester, wrapped: false);
      await closeSheet(tester);
      expect(await sheetSize(tester, wrapped: true), plain);
    });

    testWidgets('a message shows over the sheet and takes its taps, the rest '
        'of the sheet still takes them; a plain message ends with the '
        'sheet, one to act on moves to the page', (tester) async {
      final context = await open(tester);
      var counted = 0;
      var acted = 0;
      void show(BuildContext context, String text, {bool action = false}) =>
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              persist: false,
              content: Text(text),
              action: action
                  ? SnackBarAction(label: 'Tun', onPressed: () => acted++)
                  : null,
            ),
          );
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => SheetMessenger(
            child: Builder(
              builder: (sheet) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 200),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => counted++,
                      child: const Text('Zählen'),
                    ),
                    TextButton(
                      onPressed: () => show(sheet, 'Hinweis'),
                      child: const Text('Hinweis zeigen'),
                    ),
                    TextButton(
                      onPressed: () => show(sheet, 'Erledigt', action: true),
                      child: const Text('Erledigen'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Erledigen'));
      await tester.pumpAndSettle();
      reachable(find.text('Erledigt'));
      reachable(find.text('Zählen'));
      await tester.tap(find.text('Zählen'));
      await tester.pump();
      expect(counted, 1);
      await tester.tap(find.text('Tun'));
      await tester.pumpAndSettle();
      expect(acted, 1);

      // Closing the sheet: a hint about it goes with it.
      await tester.tap(find.text('Hinweis zeigen'));
      await tester.pumpAndSettle();
      reachable(find.text('Hinweis'));
      await closeSheet(tester);
      expect(find.text('Hinweis'), findsNothing);

      // … what can still be done moves to the page.
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          builder: (_) => SheetMessenger(
            child: Builder(
              builder: (sheet) => TextButton(
                onPressed: () {
                  show(sheet, 'Gelöscht', action: true);
                  Navigator.pop(sheet);
                },
                child: const Text('Löschen und zu'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Löschen und zu'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      reachable(find.text('Gelöscht'));
      await tester.tap(find.text('Tun'));
      await tester.pumpAndSettle();
      expect(acted, 2);
    });
  });

  testWidgets('ALL-121 "Rückgängig" after forgetting a staple can be tapped, '
      'also after the sheet is closed', (tester) async {
    final context = await open(tester);
    for (final (name, count) in [('Hafermilch', 9), ('Brot', 4)]) {
      engine.saveBoughtItem(
        BoughtItem(
          key: name.toLowerCase(),
          name: name,
          count: count,
          lastBought: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );
    }
    unawaited(showStaples(context));
    await tester.pumpAndSettle();

    Finder forget(String name) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
      matching: find.byTooltip(tr.shoppingForget),
    );
    await tester.tap(forget('Hafermilch'));
    await tester.pumpAndSettle();
    expect(engine.boughtItem('hafermilch'), isNull);
    expect(find.byType(BottomSheet), findsOneWidget);
    reachable(find.text(tr.undoWhatDeleted('Hafermilch')));
    reachable(find.text(tr.commonUndo));
    await tester.tap(find.text(tr.commonUndo));
    await tester.pumpAndSettle();
    expect(engine.boughtItem('hafermilch')?.count, 9);

    // Closed right after: "Rückgängig" waits on the page.
    await tester.tap(forget('Brot'));
    await tester.pumpAndSettle();
    expect(engine.boughtItem('brot'), isNull);
    await closeSheet(tester);
    reachable(find.text(tr.commonUndo));
    await tester.tap(find.text(tr.commonUndo));
    await tester.pumpAndSettle();
    expect(engine.boughtItem('brot')?.count, 4);
  });

  group('#364', () {
    final child = Child(
      id: 'c1',
      name: 'Ben',
      birthDate: DateTime.now().subtract(const Duration(days: 90)),
    );

    testWidgets('a hint of the log editor shows over it', (tester) async {
      final context = await open(tester);
      engine.saveChild(child);
      unawaited(
        showLogEditor(context, child: child, kind: LogKind.temperature),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.commonSave));
      await tester.pumpAndSettle();
      expect(engine.childLogs('c1'), isEmpty);
      reachable(find.text(tr.kidsLogPleaseEnterTemperatureBetween));
    });

    Future<void> failedUpload(WidgetTester tester, Finder add) async {
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      reachable(find.text(_uploadFailed));
    }

    testWidgets('a failed upload in the log editor', (tester) async {
      final context = await open(tester);
      engine.saveChild(child);
      unawaited(showLogEditor(context, child: child, kind: LogKind.bath));
      await tester.pumpAndSettle();
      await failedUpload(tester, find.byIcon(AppIcons.camera));
    });

    testWidgets('a failed upload in the task editor', (tester) async {
      final context = await open(tester);
      unawaited(showTaskEditor(context));
      await tester.pumpAndSettle();
      final more = find.text(tr.tasksMoreOptions);
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      await failedUpload(tester, find.byTooltip(tr.tasksAddPhoto));
    });

    testWidgets('a failed upload in the entry editor of a child', (
      tester,
    ) async {
      final context = await open(tester);
      engine.saveChild(child);
      unawaited(
        showEntryEditor(context, child: child, kind: ChildEntryKind.memory),
      );
      await tester.pumpAndSettle();
      await failedUpload(tester, find.byTooltip(tr.kidsAddPhoto));
    });

    testWidgets('deleting a log entry still offers "Rückgängig" on the page', (
      tester,
    ) async {
      final context = await open(tester);
      engine
        ..saveChild(child)
        ..saveChildLog(
          ChildLog(
            id: 'l1',
            childId: 'c1',
            kind: LogKind.bath,
            start: DateTime.now(),
            by: 'm1',
          ),
        );
      unawaited(
        showLogEditor(
          context,
          child: child,
          kind: LogKind.bath,
          existing: engine.childLogs('c1').single,
        ),
      );
      await tester.pumpAndSettle();
      final delete = find.text(tr.commonDelete);
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(engine.childLogs('c1'), isEmpty);
      reachable(find.text(tr.commonUndo));
      await tester.tap(find.text(tr.commonUndo));
      await tester.pumpAndSettle();
      expect(engine.childLogs('c1').single.id, 'l1');
    });

    testWidgets('"Rückgängig" for a deleted comment in the details of an '
        'appointment', (tester) async {
      final context = await open(
        tester,
        members:
            '[{"id":"m1","username":"gast","displayName":"Gast",'
            '"role":"guest"}]',
      );
      final start = DateTime.now().add(const Duration(days: 1));
      final event = CalendarEvent(
        id: 'e1',
        title: 'Elternabend',
        start: start,
        end: start.add(const Duration(hours: 1)),
      );
      engine
        ..saveEvent(event)
        ..addEventComment('e1', 'Ich komme mit');
      unawaited(
        showEventEditor(
          context,
          occurrence: Occurrence(event, event.start, event.end),
        ),
      );
      await tester.pumpAndSettle();
      final comment = find.text('Ich komme mit');
      await tester.ensureVisible(comment);
      await tester.pumpAndSettle();
      await tester.longPress(comment);
      await tester.pumpAndSettle();
      expect(engine.eventComments('e1'), isEmpty);
      expect(find.byType(BottomSheet), findsOneWidget);
      reachable(find.text(tr.commonUndo));
      await tester.tap(find.text(tr.commonUndo));
      await tester.pumpAndSettle();
      expect(engine.eventComments('e1').single.text, 'Ich komme mit');
    });
  });
}
