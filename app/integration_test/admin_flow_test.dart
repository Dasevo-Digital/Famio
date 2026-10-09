// End-to-end test of the real app against a running server:
//
//   flutter test integration_test -d windows \
//     --dart-define=FAMIO_URL=192.168.1.10:8765 \
//     --dart-define=FAMIO_USER=admin --dart-define=FAMIO_PASSWORD=...
//
// Signs in, manages a temporary member in the server administration and
// signs out again. The admin account must exist already.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'fresh_start.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');

/// The server's certificate fingerprint (from its log); when given, the
/// test expects the HTTPS connection and checks the dialog shows it.
const _fingerprint = String.fromEnvironment('FAMIO_FINGERPRINT');

void main() {
  // The tests read German texts, whatever the device speaks.
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps until [finder] matches; pumpAndSettle would wait forever on
  /// spinners and the sync connection.
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

  Future<void> tap(WidgetTester tester, Finder finder) async {
    debugPrint('E2E tap ${finder.describeMatch(Plurality.many)}');
    await waitFor(tester, finder);
    // E.g. the last rail entries in a low window.
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder.first);
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Dialogs animate out; taps before that hit the fading barrier.
  Future<void> dialogClosed(WidgetTester tester) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (find.byType(Dialog).evaluate().isNotEmpty &&
        DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> enter(WidgetTester tester, String label, String text) async {
    final field = find.widgetWithText(TextField, label);
    await waitFor(tester, field);
    await tester.tap(field.last);
    await tester.pump();
    await tester.enterText(field.last, text);
    await tester.pump();
    // A real desktop window may swallow the simulated input of the first
    // field; the controller is what the form reads.
    final controller = tester.widget<TextField>(field.last).controller;
    if (controller != null && controller.text != text) {
      controller.text = text;
      await tester.pump();
    }
  }

  /// Settings: in the side rail on wide screens, behind "Mehr" on phones.
  Future<void> openSettings(WidgetTester tester) async {
    // Wide screens: "Einstellungen" in the side rail. Phones: the bar shows
    // icons only; "Mehr" opens the other sections.
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
  }

  testWidgets('sign in, manage a member, sign out', (tester) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    // Leftover from an aborted run?
    final api = FamioApiClient(
      _url,
      pinnedCertificate: _fingerprint.isEmpty ? null : _fingerprint,
    );
    await api.login(username: _user, password: _password, device: 'e2e');
    for (final u in await api.adminUsers()) {
      if (u.member.username == 'e2e-testkind') {
        await api.deleteMember(u.member.id);
      }
    }
    await api.logout();
    await initializeDateFormatting('de');
    await freshStart();
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));

    if (state.me == null) {
      await enter(tester, 'Server-Adresse', _url);
      await tap(tester, find.text('Verbinden'));
      if (_fingerprint.isNotEmpty) {
        await waitFor(tester, find.text('Zertifikat des Servers prüfen'));
        final shown = tester
            .widget<SelectableText>(find.byType(SelectableText).last)
            .data!
            .replaceAll('\n', ':');
        expect(shown, _fingerprint);
        await tap(tester, find.text('Stimmt überein'));
        await dialogClosed(tester);
        await waitFor(
          tester,
          find.text('Verschlüsselt verbunden (Zertifikat bestätigt)'),
        );
      }
      await enter(tester, 'Benutzername', _user);
      await enter(tester, 'Passwort', _password);
      await tap(tester, find.text('Anmelden'));
    }
    await openSettings(tester);
    if (_fingerprint.isNotEmpty) {
      // Further down the settings list.
      await waitFor(tester, find.text('Passwort ändern'));
      await tester.dragUntilVisible(
        find.text('Verbindung verschlüsselt'),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      await tester.dragUntilVisible(
        find.text('Server-Verwaltung'),
        find.byType(ListView).first,
        const Offset(0, 200),
      );
    }
    await tap(tester, find.text('Server-Verwaltung'));
    await waitFor(tester, find.textContaining('@$_user'));

    // Add a member.
    await tap(tester, find.byTooltip('Mitglied hinzufügen'));
    // Invite (they pick name and password) or create directly.
    await tap(tester, find.text('Direkt anlegen'));
    await enter(tester, 'Name', 'E2E Testkind');
    await enter(tester, 'Benutzername (für die Anmeldung)', 'e2e-testkind');
    await enter(tester, 'Startpasswort (min. 8 Zeichen)', 'e2e-start-123');
    await tap(tester, find.text('Speichern'));
    await dialogClosed(tester);
    await waitFor(tester, find.text('E2E Testkind'));

    // Reset the password, then remove the member again.
    await tap(tester, find.text('E2E Testkind'));
    await tap(tester, find.text('Passwort zurücksetzen'));
    await enter(tester, 'Neues Passwort (min. 8 Zeichen)', 'e2e-neu-4567');
    await tap(tester, find.text('Festlegen'));
    await dialogClosed(tester);
    await waitFor(tester, find.text('Passwort geändert'));
    await tap(tester, find.text('E2E Testkind entfernen'));
    await tap(tester, find.widgetWithText(FilledButton, 'Entfernen'));
    await dialogClosed(tester);
    await waitFor(tester, find.text('Status'));
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (find.text('E2E Testkind').evaluate().isNotEmpty &&
        DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('E2E Testkind'), findsNothing);

    // Server settings and status load.
    await tap(tester, find.text('Einstellungen').last);
    await waitFor(tester, find.text('Öffentliche Adresse'));
    await tap(tester, find.text('Status'));
    await waitFor(tester, find.textContaining(RegExp(r'^\d+\.\d+\.\d+$')));

    // Back up, the backup is tried right away, and again on request.
    await tester.dragUntilVisible(
      find.text('Jetzt sichern'),
      find.byType(ListView).last,
      const Offset(0, -300),
    );
    await tap(tester, find.text('Jetzt sichern'));
    await waitFor(
      tester,
      find.textContaining('lässt sich wiederherstellen'),
      timeout: const Duration(seconds: 60),
    );
    await tap(tester, find.text('Sicherung prüfen'));
    await waitFor(
      tester,
      find.text('Sicherung geprüft: lässt sich wiederherstellen'),
      timeout: const Duration(seconds: 60),
    );

    // Sign out so the installed app starts clean.
    await tap(tester, find.byTooltip('Zurück'));
    await waitFor(tester, find.text('Passwort ändern'));
    await tester.dragUntilVisible(
      find.text('Abmelden'),
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tap(tester, find.text('Abmelden'));
    await waitFor(tester, find.text('Verbinden'));
  });
}
