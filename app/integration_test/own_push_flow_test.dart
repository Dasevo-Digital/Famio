// Switches on Famio's own push in the app (Android: the background
// service). The script around it then closes the app, lets another
// member write and checks that Android shows the notification:
//
//   tool/android_dev_test.sh emulator-5554 integration_test/own_push_flow_test.dart \
//     --dart-define=FAMIO_URL=http://10.0.2.2:8795 \
//     --dart-define=FAMIO_USER=papa --dart-define=FAMIO_PASSWORD=...
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _user = String.fromEnvironment('FAMIO_USER');
const _password = String.fromEnvironment('FAMIO_PASSWORD');

void main() {
  // The tests read German texts, whatever the device speaks.
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
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

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await waitFor(tester, finder);
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder.first);
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> enter(WidgetTester tester, Finder field, String text) async {
    await waitFor(tester, field);
    await tester.tap(field.last);
    await tester.pump();
    await tester.enterText(field.last, text);
    await tester.pump();
    final controller = tester.widget<TextField>(field.last).controller;
    if (controller != null && controller.text != text) {
      controller.text = text;
      await tester.pump();
    }
  }

  testWidgets('switch on own push on this phone', (tester) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    await initializeDateFormatting('de');
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

    // Einstellungen → Push-Benachrichtigungen.
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == 'Einstellungen') ||
            (w is Tooltip &&
                (w.message == 'Mehr' || w.message == 'Einstellungen')),
      ),
    );
    if (find.text('Einstellungen').evaluate().isNotEmpty) {
      await tap(tester, find.text('Einstellungen').last);
    } else if (find.byTooltip('Einstellungen').evaluate().isNotEmpty) {
      // A low window: the side rail shows icons only.
      await tap(tester, find.byTooltip('Einstellungen').last);
    } else {
      await tap(tester, find.byTooltip('Mehr').last);
      await tap(tester, find.text('Einstellungen').last);
    }
    await waitFor(tester, find.text('Push-Benachrichtigungen'));
    await tester.dragUntilVisible(
      find.text('Push-Benachrichtigungen'),
      find.byType(ListView).first,
      const Offset(0, -200),
    );
    await tap(tester, find.text('Push-Benachrichtigungen'));
    await waitFor(tester, find.text('Direkt über Famio'));

    final phoneSwitch = find.widgetWithText(SwitchListTile, 'Auf diesem Handy');
    await waitFor(tester, phoneSwitch);
    if (!tester.widget<SwitchListTile>(phoneSwitch).value) {
      await tap(tester, phoneSwitch);
    }
    // The service runs once the switch shows it.
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end) &&
        !tester.widget<SwitchListTile>(phoneSwitch).value) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(tester.widget<SwitchListTile>(phoneSwitch).value, isTrue);
    expect((await state.ownPush!.status()).enabled, isTrue);
    expect(find.text('Test senden'), findsOneWidget);
  });
}
