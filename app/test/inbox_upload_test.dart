import 'dart:convert';
import 'dart:typed_data';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/screens/inbox_screen.dart';
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
  String get name => 'zettel.png';
  @override
  Uri get uri => Uri.parse('memory:zettel.png');
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

/// A failed upload costs the attachment, not what was typed.
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final before = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker();
    addTearDown(() => FilePickerPlatform.instance = before);
    final client = MockClient((r) async => http.Response('{}', 503));
    final state = AppState();
    await state.init();
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1', httpClient: client),
      memberId: me.id,
    );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    Navigator.of(
      tester.element(find.byType(Scaffold).first),
    ).push(MaterialPageRoute<void>(builder: (_) => const InboxScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AddButton));
    await tester.pumpAndSettle();
  }

  Future<void> attachAndSave(WidgetTester tester) async {
    await tester.tap(find.byIcon(AppIcons.paperclip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Speichern'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('what was typed stays and the failure is shown', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).at(0), 'Wichtiger Zettel');
    await tester.enterText(find.byType(TextField).at(1), 'Nicht vergessen');
    await attachAndSave(tester);

    expect(tester.takeException(), isNull);
    final item = engine.inboxItems.single;
    expect(item.title, 'Wichtiger Zettel');
    expect(item.text, 'Nicht vergessen');
    expect(item.files, isEmpty);
    expect(find.textContaining('nicht hochgeladen'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('with only a file nothing is saved', (tester) async {
    await open(tester);
    await attachAndSave(tester);

    expect(tester.takeException(), isNull);
    expect(engine.inboxItems, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
