import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/day_preview.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/home_widget/widget_sync.dart';
import 'package:famio/src/push/own_push.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/documents_screen.dart';
import 'package:famio/src/screens/medication_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

SyncEngine _engine({String me = 'm1'}) => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: me,
);

Medication _medication({List<String> care = const []}) => Medication(
  id: 'saft',
  name: 'Fiebersaft',
  personName: 'Ben',
  start: DateTime(2026),
  careIds: care,
);

CalendarEvent _event(DateTime start, {bool confidential = true}) =>
    CalendarEvent(
      id: 'e1',
      title: 'Psychotherapie',
      location: 'Praxis',
      start: start,
      end: start.add(const Duration(hours: 1)),
      confidential: confidential,
    );

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('medication', () {
    test('nobody chosen stays the author, not the family', () {
      final engine = _engine();
      engine.saveMedication(_medication());
      expect(engine.record(Collections.medications, 'saft')!.visibleTo, ['m1']);
      expect(engine.medications.single.careIds, ['m1']);
    });

    test('what was taken follows the plan', () {
      final engine = _engine();
      final plan = _medication(care: ['m1', 'm2']);
      engine.saveMedication(plan);
      engine.recordIntake(plan);
      final id = engine.intakes('saft').single.id;
      expect(engine.record(Collections.medicationIntakes, id)!.visibleTo, [
        'm1',
        'm2',
      ]);
      engine.saveMedication(_medication(care: ['m1']));
      expect(engine.record(Collections.medicationIntakes, id)!.visibleTo, [
        'm1',
      ]);
    });
  });

  test('a pregnancy nobody was chosen for stays the author\'s', () {
    final engine = _engine();
    engine.savePregnancy(Pregnancy(id: 'p', dueDate: DateTime(2027)));
    expect(engine.record(Collections.pregnancies, 'p')!.visibleTo, ['m1']);
  });

  group('confidential appointments', () {
    final today = DateUtils.dateOnly(DateTime.now());
    final later = DateTime(today.year, today.month, today.day, 23, 30);

    test('say only that they are one where others read along', () {
      expect(_event(later).publicTitle, 'Belegt');
      expect(_event(later, confidential: false).publicTitle, 'Psychotherapie');
    });

    test('in the day overview', () {
      final engine = _engine();
      engine.saveEvent(_event(later));
      final preview = buildDayPreview(engine, today)!;
      expect(preview.body, contains('Belegt'));
      expect(preview.body, isNot(contains('Psychotherapie')));
    });

    test('on the home screen widget', () {
      final engine = _engine();
      engine.saveEvent(_event(later));
      final (_, lines) = widgetLines(engine, today);
      expect(lines.map((l) => l.text), contains('Belegt'));
      expect(lines.map((l) => l.text), isNot(contains('Psychotherapie')));
    });
  });

  group('reminders', () {
    late List<MethodCall> calls;

    Future<ReminderService> service(Map<String, Object> prefs) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues(prefs);
      calls = [];
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'pendingNotificationRequests' ? [] : true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      return (await ReminderService.create(
        await SharedPreferences.getInstance(),
      ))!;
    }

    Future<Map> scheduled(
      Map<String, Object> prefs,
      void Function(SyncEngine) fill,
    ) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final reminders = await service(prefs);
      final engine = _engine();
      fill(engine);
      reminders.attach(engine);
      reminders.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      addTearDown(reminders.detach);
      return calls.firstWhere((c) => c.method == 'zonedSchedule').arguments
          as Map;
    }

    void soon(SyncEngine engine, {bool confidential = false}) =>
        engine.saveEvent(
          _event(
            DateTime.now().add(const Duration(hours: 3)),
            confidential: confidential,
          ).copyWith(reminderMinutes: 15),
        );

    test('name what is due by default', () async {
      final r = await scheduled({}, soon);
      expect(r['title'], 'Psychotherapie');
      expect(r['body'], contains('Praxis'));
    });

    test('a confidential one stays neutral', () async {
      final r = await scheduled({}, (e) => soon(e, confidential: true));
      expect(r['title'], 'Termin');
      expect(r['body'], isNot(contains('Praxis')));
    });

    test('with contents off nothing is said', () async {
      final r = await scheduled({OwnPush.detailsKey: false}, soon);
      expect(r['title'], 'Famio');
      expect(r['body'], 'Details in Famio');
    });
  });

  group('screens', () {
    Future<SyncEngine> open(WidgetTester tester, {String me = 'm1'}) async {
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final state = AppState();
      await state.init();
      final engine = _engine(me: me);
      state
        ..me = engine.members.firstWhere((m) => m.id == me)
        ..engine = engine;
      await tester.pumpWidget(FamioApp(state: state));
      await tester.pumpAndSettle();
      return engine;
    }

    Future<void> push(WidgetTester tester, Widget page) async {
      final context = tester.element(find.byType(Scaffold).first);
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
      await tester.pumpAndSettle();
    }

    testWidgets('a new health document starts as the author\'s', (
      tester,
    ) async {
      await open(tester);
      await push(tester, const DocumentEditor());
      RadioGroup<Object?> group() => tester.widget<RadioGroup<Object?>>(
        find.byWidgetPredicate(
          (w) => '${w.runtimeType}'.startsWith('RadioGroup'),
        ),
      );
      expect('${group().groupValue}', endsWith('.family'));
      await tester.tap(find.text('Gesundheit'));
      await tester.pump();
      expect('${group().groupValue}', endsWith('.me'));
      await tester.tap(find.text('Finanzen & Steuern'));
      await tester.pump();
      expect('${group().groupValue}', endsWith('.family'));
    });

    testWidgets('children see their plan but do not change it', (tester) async {
      final engine = await open(tester, me: 'k1');
      engine.saveMedication(_medication(care: ['k1']));
      await push(tester, const MedicationScreen());
      expect(find.text('Fiebersaft'), findsOneWidget);
      expect(find.byTooltip('Medikament hinzufügen'), findsNothing);
      await tester.tap(find.text('Fiebersaft'));
      await tester.pumpAndSettle();
      expect(find.text('Speichern'), findsNothing);
    });
  });
}
