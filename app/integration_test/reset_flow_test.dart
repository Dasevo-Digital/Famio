// End-to-end test of "Einstellungen auf Standard" and "Alle Daten löschen".
// DELETES EVERYTHING on the server – only run it against a throwaway one:
//
//   flutter test integration_test/reset_flow_test.dart -d macos \
//     --dart-define=FAMIO_URL=http://localhost:8795 \
//     --dart-define=FAMIO_USER=admin --dart-define=FAMIO_PASSWORD=... \
//     --dart-define=FAMIO_ALLOW_WIPE=yes
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
const _allowWipe = String.fromEnvironment('FAMIO_ALLOW_WIPE');

void main() {
  // The tests read German texts, whatever the device speaks.
  deviceLanguage = () => 'de';
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
    await tester.ensureVisible(finder.first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder.first);
    await tester.pump(const Duration(milliseconds: 500));
  }

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
    final controller = tester.widget<TextField>(field.last).controller;
    if (controller != null && controller.text != text) {
      controller.text = text;
      await tester.pump();
    }
  }

  testWidgets('reset settings and delete all data', (tester) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    expect(
      _allowWipe,
      'yes',
      reason: 'deletes everything: only against a throwaway server',
    );
    // Something to delete: a setting, an event, a member.
    final api = FamioApiClient(_url);
    await api.login(username: _user, password: _password, device: 'e2e');
    await api.updateServerSettings({'maxUploadMb': 7});
    for (final u in await api.adminUsers()) {
      if (u.member.username == 'e2e-reset') await api.deleteMember(u.member.id);
    }
    await api.createMember(
      username: 'e2e-reset',
      displayName: 'E2E Reset',
      password: 'e2e-start-123',
    );
    await api.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.events,
            id: 'e2e-reset-${DateTime.now().millisecondsSinceEpoch}',
            data: const {'title': 'Wird gelöscht'},
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      ),
    );

    await initializeDateFormatting('de');
    await freshStart();
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    if (state.me == null) {
      await enter(tester, 'Server-Adresse', _url);
      await tap(tester, find.text('Verbinden'));
      await enter(tester, 'Benutzername', _user);
      await enter(tester, 'Passwort', _password);
      await tap(tester, find.text('Anmelden'));
    }
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
    await tap(tester, find.text('Server-Verwaltung'));
    await tap(tester, find.text('Einstellungen').last);
    await waitFor(tester, find.text('Öffentliche Adresse'));
    // By label: other fields may show "7" as their hint.
    String uploadLimit() => tester
        .widget<TextField>(
          find.widgetWithText(TextField, 'Maximale Dateigröße (MB)'),
        )
        .controller!
        .text;
    expect(uploadLimit(), '7');

    // a. Settings back to the defaults (at the end of the list).
    await tester.dragUntilVisible(
      find.text('Alle Daten löschen'),
      find.byType(ListView).last,
      const Offset(0, -300),
    );
    await tap(tester, find.widgetWithText(TextButton, 'Zurücksetzen'));
    await tap(tester, find.widgetWithText(FilledButton, 'Zurücksetzen'));
    await dialogClosed(tester);
    await waitFor(tester, find.text('Einstellungen auf Standard gesetzt'));
    expect(uploadLimit(), isEmpty);
    expect((await api.adminOverview()).settings.maxUploadMb, isNull);

    // b. Delete all data, and the other members.
    await tester.dragUntilVisible(
      find.text('Alle Daten löschen'),
      find.byType(ListView).last,
      const Offset(0, -300),
    );
    await tap(tester, find.widgetWithText(TextButton, 'Löschen …'));
    await waitFor(tester, find.text('Alle Daten löschen?'));
    await tap(tester, find.text('Auch alle anderen Mitglieder entfernen'));
    await enter(tester, 'Dein Passwort', _password);
    // A wrong confirmation is refused.
    await enter(tester, 'Zur Bestätigung LÖSCHEN eingeben', 'ja');
    await tap(tester, find.text('Endgültig löschen'));
    await waitFor(tester, find.text('Bitte zur Bestätigung LÖSCHEN eingeben'));
    await enter(tester, 'Zur Bestätigung LÖSCHEN eingeben', 'LÖSCHEN');
    await tap(tester, find.text('Endgültig löschen'));
    await dialogClosed(tester);
    await waitFor(tester, find.textContaining('Gelöscht:'));

    final after = await api.sync(const SyncRequest(since: 0, changes: []));
    expect(after.changes.where((r) => !r.deleted), isEmpty);
    expect(
      [for (final u in await api.adminUsers()) u.member.username],
      [_user],
    );
    await api.logout();

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
