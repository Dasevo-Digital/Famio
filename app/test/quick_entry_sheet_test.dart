import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true},'
    '{"id":"m2","username":"papa","displayName":"Papa"}]';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    state
      ..me = engine.members.firstWhere((m) => m.id == 'm1')
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Schnell eintragen'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pumpAndSettle();
  }

  testWidgets('a line with a time becomes an appointment to check', (
    tester,
  ) async {
    await open(tester);
    // Tomorrow is never ambiguous.
    await type(tester, 'morgen 16 Uhr Kinderarzt');
    expect(find.text('Kinderarzt'), findsOneWidget);
    await tester.tap(find.text('Als Termin'));
    await tester.pumpAndSettle();
    // The event editor, filled in: saved as it is.
    expect(find.widgetWithText(TextField, 'Kinderarzt'), findsOneWidget);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final event = engine.events.single;
    final tomorrow = DateUtils.addDaysToDate(DateTime.now(), 1);
    expect(event.title, 'Kinderarzt');
    expect(event.allDay, isFalse);
    expect(
      event.start,
      DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 16),
    );
    expect(event.end, event.start.add(const Duration(hours: 1)));
  });

  testWidgets('a day it cannot tell is asked before anything opens', (
    tester,
  ) async {
    await open(tester);
    // Tomorrow's weekday: "nächsten …" is tomorrow or a week later.
    final first = DateUtils.addDaysToDate(
      DateUtils.dateOnly(DateTime.now()),
      1,
    );
    const names = [
      'Montag',
      'Dienstag',
      'Mittwoch',
      'Donnerstag',
      'Freitag',
      'Samstag',
      'Sonntag',
    ];
    await type(
      tester,
      'nächsten ${names[first.weekday - 1]} Elternabend vorbereiten',
    );
    expect(find.text('Welcher Tag ist gemeint?'), findsOneWidget);
    // Without a time it is rather a task; nothing goes on until a day is
    // picked.
    final task = find.widgetWithText(FilledButton, 'Als Aufgabe');
    expect(tester.widget<FilledButton>(task).onPressed, isNull);
    final second = DateUtils.addDaysToDate(first, 7);
    final chip = find.widgetWithText(
      ChoiceChip,
      DateFormatHelper.short(second),
    );
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(task).onPressed, isNotNull);
    await tester.tap(task);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, 'Elternabend vorbereiten'),
      findsOneWidget,
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final saved = engine.tasks.single;
    expect(saved.title, 'Elternabend vorbereiten');
    expect(saved.due, second);
  });

  testWidgets('a range of days becomes an all-day appointment', (tester) async {
    await open(tester);
    final now = DateTime.now();
    // Next month, so it is never a past day.
    final month = DateTime(now.year, now.month + 1);
    await type(tester, 'Ferienlager 3.–5.${month.month}.');
    await tester.tap(find.text('Als Termin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final event = engine.events.single;
    expect(event.title, 'Ferienlager');
    expect(event.allDay, isTrue);
    expect(event.start, DateTime(month.year, month.month, 3));
    expect(event.end, DateTime(month.year, month.month, 6));
  });
}

/// The chip labels of the sheet ("Do., 12. Nov.").
abstract final class DateFormatHelper {
  static String short(DateTime d) => DateFormat.MMMEd('de').format(d);
}
