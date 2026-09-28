// End-to-end test of the 0.13 features against a running (dev) server:
//
//   flutter test integration_test/features_flow_test.dart -d macos \
//     --dart-define=FAMIO_URL=localhost:8775 \
//     --dart-define=FAMIO_USER=admin --dart-define=FAMIO_PASSWORD=...
//
// Creates a child, a chore, a routine and a reward, lets the child ask for
// points through the API, approves them in the app, checks the wall
// display, a poll and the pantry, and cleans up again.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');
const _fingerprint = String.fromEnvironment('FAMIO_FINGERPRINT');

void main() {
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

  /// Sections in the side rail; on phones an icon in the bar (tooltip) or
  /// behind "Mehr".
  Future<void> openSection(WidgetTester tester, String label) async {
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == label) ||
            (w is Tooltip && (w.message == label || w.message == 'Mehr')),
      ),
    );
    if (find.text(label).evaluate().isNotEmpty) {
      await tap(tester, find.text(label).last);
    } else if (find.byTooltip(label).evaluate().isNotEmpty) {
      await tap(tester, find.byTooltip(label).last);
    } else {
      await tap(tester, find.byTooltip('Mehr').last);
      await tap(tester, find.text(label).last);
    }
  }

  testWidgets('chores, points, wall display, poll and pantry', (tester) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    final pin = _fingerprint.isEmpty ? null : _fingerprint;
    final admin = FamioApiClient(_url, pinnedCertificate: pin);
    await admin.login(username: _user, password: _password, device: 'e2e');
    for (final u in await admin.adminUsers()) {
      if (u.member.username == 'e2e-kind') {
        await admin.deleteMember(u.member.id);
      }
    }
    final kid = await admin.createMember(
      username: 'e2e-kind',
      displayName: 'E2E Kind',
      password: 'e2e-kind-123',
      role: MemberRole.child,
    );
    expect(kid.role, MemberRole.child);

    // The child asks for points; a child's attempt to book approved
    // points is undone by the server.
    final kidApi = FamioApiClient(_url, pinnedCertificate: pin);
    await kidApi.login(
      username: 'e2e-kind',
      password: 'e2e-kind-123',
      device: 'e2e',
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    SyncRecord points(String id, String status) => SyncRecord(
      collection: Collections.pointEntries,
      id: id,
      data: PointEntry(
        id: id,
        memberId: kid.id,
        points: 4,
        title: 'E2E Zimmer',
        kind: PointKind.chore,
        at: DateTime.now(),
        status: PointStatus.parse(status),
      ).toData(),
      updatedAt: now,
    );
    final sync = await kidApi.sync(
      SyncRequest(
        since: 0,
        changes: [
          points('e2e-$now-1', 'pending'),
          points('e2e-$now-2', 'approved'),
        ],
      ),
    );
    expect(sync.rejected.map((r) => r.id), ['e2e-$now-2']);

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
      if (_fingerprint.isNotEmpty) {
        await waitFor(tester, find.text('Zertifikat des Servers prüfen'));
        await tap(tester, find.text('Stimmt überein'));
      }
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

    // Approve the child's request.
    await openSection(tester, 'Ämter');
    await waitFor(tester, find.text('E2E Kind: E2E Zimmer'));
    await tap(tester, find.byTooltip('Bestätigen'));

    // A new chore for the child.
    await tap(tester, find.byTooltip('Amt anlegen'));
    await enter(
      tester,
      find.widgetWithText(TextField, 'Was ist zu tun?'),
      'E2E Tisch decken',
    );
    await tap(tester, find.text('E2E Kind').last);
    await tap(tester, find.text('Speichern').last);
    await waitFor(tester, find.text('E2E Tisch decken'));
    await waitFor(tester, find.text('⭐ 4'));

    // Wall display.
    await openSection(tester, 'Start');
    await tap(tester, find.byTooltip('Wandanzeige'));
    await waitFor(tester, find.text('Ämter & Routinen'));
    await waitFor(tester, find.textContaining('E2E Tisch decken'));
    await tap(tester, find.byTooltip('Wandanzeige beenden'));

    // Poll in the family chat.
    await openSection(tester, 'Chat');
    await tap(tester, find.text('Familie').first);
    await tap(tester, find.byTooltip('Umfrage'));
    await enter(tester, find.widgetWithText(TextField, 'Frage'), 'E2E Pizza?');
    await enter(tester, find.widgetWithText(TextField, 'Antwort 1'), 'Ja');
    await enter(tester, find.widgetWithText(TextField, 'Antwort 2'), 'Nein');
    await tap(tester, find.text('Senden').last);
    await waitFor(tester, find.text('E2E Pizza?'));
    await tap(tester, find.text('Ja'));
    await waitFor(tester, find.text('1 Stimme'));

    // Pantry.
    await openSection(tester, 'Einkauf');
    await tap(tester, find.text('Vorrat'));
    await tap(tester, find.byTooltip('Artikel hinzufügen'));
    await enter(tester, find.widgetWithText(TextField, 'Artikel'), 'E2E Milch');
    await tap(tester, find.text('Speichern').last);
    await waitFor(tester, find.text('E2E Milch'));

    // Clean up: records of the test and the child.
    await tester.pump(const Duration(seconds: 3));
    final engine = state.engine!;
    for (final c in [
      Collections.chores,
      Collections.pointEntries,
      Collections.pantryItems,
      Collections.chatMessages,
      Collections.pollVotes,
    ]) {
      for (final r in engine.records(c).toList()) {
        if (r.id.startsWith('e2e-') ||
            '${r.data['title']}${r.data['name']}${r.data['poll']}${r.data['memberId']}'
                .contains(RegExp('E2E|${kid.id}'))) {
          engine.delete(c, r.id);
        }
      }
    }
    await engine.sync();
    await admin.deleteMember(kid.id);
    await state.signOut();
    await tester.pump(const Duration(seconds: 1));
  });
}
