import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/app_icons.dart';
import 'package:famio/src/screens/event_editor.dart';
import 'package:famio/src/screens/kids_log_screens.dart';
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

/// Saving while an attachment is still on its way would drop it silently.
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late Completer<http.Response> upload;
  late SyncEngine engine;

  Future<BuildContext> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final before = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker();
    addTearDown(() => FilePickerPlatform.instance = before);
    upload = Completer();
    final client = MockClient((r) async {
      if (r.url.path.contains('files')) return upload.future;
      return http.Response('{}', 503);
    });
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
    return tester.element(find.byType(Scaffold).first);
  }

  http.Response uploaded() => http.Response(
    jsonEncode({
      'id': 'file-1',
      'name': 'foto.png',
      'mime': 'image/png',
      'size': 4,
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.text('Speichern').first, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the log waits for its photo', (tester) async {
    final context = await open(tester);
    final child = Child(
      id: 'c1',
      name: 'Ben',
      birthDate: DateTime.now().subtract(const Duration(days: 90)),
    );
    engine.saveChild(child);
    unawaited(showLogEditor(context, child: child, kind: LogKind.bath));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.camera));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    await tapSave(tester);
    expect(engine.childLogs('c1'), isEmpty);

    upload.complete(uploaded());
    await tester.pumpAndSettle();
    await tapSave(tester);
    await tester.pumpAndSettle();
    expect(engine.childLogs('c1').single.photos.single.id, 'file-1');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the appointment waits for its attachment', (tester) async {
    final context = await open(tester);
    unawaited(
      showEventEditor(context, title: 'Arzt', day: DateTime(2026, 12, 1)),
    );
    await tester.pumpAndSettle();
    final clip = find.byIcon(AppIcons.paperclip);
    await tester.ensureVisible(clip);
    await tester.pumpAndSettle();
    await tester.tap(clip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    await tapSave(tester);
    expect(engine.events, isEmpty);

    upload.complete(uploaded());
    await tester.pumpAndSettle();
    await tapSave(tester);
    await tester.pumpAndSettle();
    expect(engine.events.single.files.single.id, 'file-1');
    await tester.pump(const Duration(seconds: 5));
  });
}
