// End-to-end test of two-factor login against a throwaway server:
// sets up an authenticator in the app, signs out, signs in with a code and
// makes two-factor login mandatory in the server administration.
//
//   FLUTTER_XCODE_FAMIO_APP_NAME="Famio Dev" \
//   FLUTTER_XCODE_FAMIO_BUNDLE_ID=de.status403.famio.dev \
//   FLUTTER_XCODE_FAMIO_APP_ICON=AppIconDev \
//   flutter test integration_test/two_factor_flow_test.dart -d macos \
//     --dart-define=FAMIO_ENV=dev --dart-define=FAMIO_URL=http://localhost:8795 \
//     --dart-define=FAMIO_USER=admin --dart-define=FAMIO_PASSWORD=...
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');

/// RFC 6238 code like an authenticator app, [offset] steps from now.
String totp(String secret, {int offset = 0}) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final bytes = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final char in secret.toUpperCase().split('')) {
    buffer = (buffer << 5) | alphabet.indexOf(char);
    bits += 5;
    if (bits >= 8) {
      bytes.add((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  final step = DateTime.now().millisecondsSinceEpoch ~/ 30000 + offset;
  final counter = ByteData(8)..setUint64(0, step);
  final hash = Hmac(sha1, bytes).convert(counter.buffer.asUint8List()).bytes;
  final o = hash.last & 0x0f;
  final value =
      ((hash[o] & 0x7f) << 24) |
      (hash[o + 1] << 16) |
      (hash[o + 2] << 8) |
      hash[o + 3];
  return (value % pow(10, 6)).toString().padLeft(6, '0');
}

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

  Future<void> dialogClosed(WidgetTester tester) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (find.byType(Dialog).evaluate().isNotEmpty &&
        DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
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

  Future<void> openSettings(WidgetTester tester) async {
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == 'Einstellungen') ||
            (w is Tooltip && w.message == 'Mehr'),
      ),
    );
    if (find.text('Einstellungen').evaluate().isEmpty) {
      await tap(tester, find.byTooltip('Mehr').last);
    }
    await tap(tester, find.text('Einstellungen').last);
  }

  Future<void> signIn(WidgetTester tester) async {
    await enter(tester, find.widgetWithText(TextField, 'Server-Adresse'), _url);
    await tap(tester, find.text('Verbinden'));
    await enter(tester, find.widgetWithText(TextField, 'Benutzername'), _user);
    await enter(tester, find.widgetWithText(TextField, 'Passwort'), _password);
    await tap(tester, find.text('Anmelden'));
  }

  Future<void> signOut(WidgetTester tester) async {
    await openSettings(tester);
    await waitFor(tester, find.text('Konto, Familie & Server'));
    await tester.dragUntilVisible(
      find.text('Abmelden'),
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tap(tester, find.text('Abmelden'));
    await waitFor(tester, find.text('Verbinden'));
  }

  testWidgets('set up two-factor login and sign in with a code', (
    tester,
  ) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    await initializeDateFormatting('de');
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    if (state.me != null) {
      // Still signed in from an earlier run – unless that session is gone.
      await waitFor(
        tester,
        find.byWidgetPredicate(
          (w) =>
              (w is Text &&
                  (w.data == 'Einstellungen' || w.data == 'Verbinden')) ||
              (w is Tooltip && w.message == 'Mehr'),
        ),
      );
      if (find.text('Verbinden').evaluate().isEmpty) await signOut(tester);
    }

    // 1. Sign in and set up the authenticator.
    await signIn(tester);
    await openSettings(tester);
    await tap(tester, find.text('Anmeldung & Sicherheit'));
    await tap(tester, find.widgetWithText(FilledButton, 'Einrichten'));
    await waitFor(tester, find.byType(QrImageView));
    // The key shown for typing it by hand (groups of four).
    final secret = tester
        .widget<SelectableText>(find.byType(SelectableText).first)
        .data!
        .replaceAll(' ', '');
    expect(secret, hasLength(32));
    await enter(tester, find.widgetWithText(TextField, 'Code'), totp(secret));
    await tap(tester, find.text('Einschalten'));
    await waitFor(tester, find.text('Zwei-Faktor ist eingeschaltet'));
    // Ten recovery codes, shown once.
    final codes = RegExp(r'[a-z0-9]{5}-[a-z0-9]{5}')
        .allMatches(
          tester
              .widget<SelectableText>(find.byType(SelectableText).first)
              .data!,
        )
        .map((m) => m.group(0)!)
        .toList();
    expect(codes, hasLength(10));
    await tap(tester, find.text('Codes gesichert – fertig'));
    await waitFor(tester, find.text('Eingeschaltet'));
    await tap(tester, find.byTooltip('Zurück'));

    // 2. Sign out; the next login asks for the code.
    await signOut(tester);
    await signIn(tester);
    await waitFor(tester, find.text('Zwei-Faktor-Anmeldung'));
    await enter(tester, find.widgetWithText(TextField, 'Code'), '000000');
    await tap(tester, find.text('Bestätigen'));
    await waitFor(tester, find.text('Der Code stimmt nicht'));
    // The setup used this step already: the next one (allowed drift).
    await enter(
      tester,
      find.widgetWithText(TextField, 'Code'),
      totp(secret, offset: 1),
    );
    await tap(tester, find.text('Bestätigen'));
    await dialogClosed(tester);

    // 3. Signed in: make it mandatory for everybody.
    await openSettings(tester);
    await waitFor(tester, find.text('Server-Verwaltung'));
    await tap(tester, find.text('Server-Verwaltung'));
    await tap(tester, find.text('Einstellungen').last);
    await waitFor(tester, find.text('Öffentliche Adresse'));
    await tester.dragUntilVisible(
      find.text('Zwei-Faktor-Anmeldung verlangen'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tap(tester, find.text('Nicht verlangt'));
    await tap(tester, find.text('Für Alle Mitglieder').last);
    await tester.dragUntilVisible(
      find.text('Speichern'),
      find.byType(ListView).last,
      const Offset(0, 200),
    );
    await tap(tester, find.text('Speichern'));
    await waitFor(tester, find.text('Servereinstellungen gespeichert'));

    final api = FamioApiClient(_url);
    try {
      await api.login(username: _user, password: _password);
      fail('two-factor login expected');
    } on TwoFactorRequired catch (challenge) {
      await api.loginTwoFactor(challenge: challenge.challenge, code: codes[1]);
    }
    expect(
      (await api.adminOverview()).settings.twoFactorRequired,
      TwoFactorPolicy.all,
    );
    // Clean up for the next run.
    await api.updateServerSettings({'twoFactorRequired': null});
    await api.logout();

    await tap(tester, find.byTooltip('Zurück'));
    await signOut(tester);
  });
}
