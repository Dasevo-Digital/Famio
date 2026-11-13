import 'dart:typed_data';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio/src/screens/tasks_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:famio/src/data/family_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Picked extends PlatformFile {
  _Picked(this.bytes);

  final Uint8List bytes;

  @override
  String get name => 'video.mp4';
  @override
  Uri get uri => Uri.parse('memory:video.mp4');
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
  }) async => [_Picked(Uint8List(5000))];
}

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true}]';

/// A picked file over the upload limit is told, not dropped silently
/// (#486).
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Future<SyncEngine> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final before = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker();
    addTearDown(() => FilePickerPlatform.instance = before);
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta('members', _members)
        // The server allows 1000 bytes.
        ..setMeta('maxUploadBytes', '1000'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    state
      ..me = engine.members.first
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    return engine;
  }

  Future<void> push(WidgetTester tester, Widget page) async {
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pumpAndSettle();
  }

  Future<void> expectTold(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    expect(find.text('Maximal 1000 B pro Datei'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  }

  testWidgets('documents: a file over the limit', (tester) async {
    await open(tester);
    await push(tester, const DocumentsScreen());
    await tester.tap(
      find.byTooltip('Dokument hinzufügen').first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await expectTold(tester);
    expect(find.byType(DocumentEditor), findsNothing);
  });

  testWidgets('task editor: a file over the limit', (tester) async {
    final engine = await open(tester);
    engine.saveTask(Task(id: 't', title: 'Steuer', createdAt: DateTime(2026)));
    await push(tester, const TasksScreen());
    await tester.tap(find.text('Steuer'));
    await tester.pumpAndSettle();
    final more = find.text('Checkliste, Dateien, Sichtbarkeit');
    if (more.evaluate().isNotEmpty) {
      await tester.tap(more);
      await tester.pumpAndSettle();
    }
    await tester.tap(
      find.byTooltip('Foto oder Datei anhängen').first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await expectTold(tester);
    // The editor is still open, nothing attached.
    expect(find.text('Speichern'), findsOneWidget);
    expect(engine.tasks.single.photos, isEmpty);
  });
}
