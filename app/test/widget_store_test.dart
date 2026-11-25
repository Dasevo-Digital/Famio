import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/home_widget/widget_sync.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The home screen widget's rows go to Android's encrypted store of the
/// widget, no longer to home_widget's plain preferences (#607).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  late List<MethodCall> widget;
  late List<MethodCall> plain;
  late bool placed;

  setUp(() {
    widget = [];
    plain = [];
    placed = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('famio/widget'), (
      call,
    ) async {
      widget.add(call);
      return call.method == 'save' ? placed : null;
    });
    // home_widget's own channel: what it writes is plain text.
    messenger.setMockMethodCallHandler(const MethodChannel('home_widget'), (
      call,
    ) async {
      plain.add(call);
      return null;
    });
    HomeWidgetSync.debugSupported = true;
  });

  tearDown(() async {
    await HomeWidgetSync.clear();
    HomeWidgetSync.debugSupported = null;
  });

  SyncEngine family() {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final now = DateTime.now();
    final child = Child(
      id: 'k1',
      name: 'Emil',
      birthDate: DateTime(now.year - 1, 3, 3),
      guardianIds: const ['m1'],
    );
    engine
      ..saveChild(child)
      ..saveChildLog(
        ChildLog(
          id: 'l1',
          childId: child.id,
          kind: LogKind.sleep,
          start: now.subtract(const Duration(minutes: 30)),
        ),
      );
    return engine;
  }

  List<Map<Object?, Object?>> rows(MethodCall save) => [
    for (final r in (save.arguments as Map)['rows'] as List) r as Map,
  ];

  testWidgets('the rows go to the widget store, nothing in plain text', (
    tester,
  ) async {
    HomeWidgetSync.attach(family());
    await tester.pump(const Duration(seconds: 3));
    final save = widget.singleWhere((c) => c.method == 'save');
    expect((save.arguments as Map)['date'], isNotEmpty);
    expect(rows(save).single['kind'], 'sleep');
    expect(rows(save).single['text'], contains('Emil'));
    expect(plain, isEmpty, reason: 'home_widget keeps it unencrypted');
    await HomeWidgetSync.clear();
  });

  testWidgets('a widget placed meanwhile is filled when Famio is back', (
    tester,
  ) async {
    placed = false;
    HomeWidgetSync.attach(family());
    await tester.pump(const Duration(seconds: 3));
    expect(widget.where((c) => c.method == 'save'), hasLength(1));
    // The widget was placed from the launcher, then Famio came back.
    placed = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(widget.where((c) => c.method == 'save'), hasLength(2));
    await HomeWidgetSync.clear();
  });

  testWidgets('signing out empties the widget store', (tester) async {
    HomeWidgetSync.attach(family());
    await tester.pump(const Duration(seconds: 3));
    await HomeWidgetSync.clear();
    expect(widget.last.method, 'clear');
    // Nothing is written afterwards.
    final count = widget.length;
    await tester.pump(const Duration(seconds: 3));
    expect(widget, hasLength(count));
    expect(plain, isEmpty);
  });
}
