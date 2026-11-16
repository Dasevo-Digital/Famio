// e2e-server: FAMIO_BACKUP_DIR=off FAMIO_TLS_PORT=0
//
// Catalog entries that need a server without backups and without its own
// HTTPS port (GRU-104 Gegenprobe, SIC-122) – against a throwaway server that
// tool/integration_tests.sh starts with the settings of the first line:
//
//   tool/integration_tests.sh macos integration_test/catalog_server_off_test.dart
import 'dart:io';

import 'package:famio/src/app_state.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_kit.dart';

/// The server's HTTPS port of this run (FAMIO_E2E_TLS_PORT), on which it
/// listens not.
const _tlsUrl = String.fromEnvironment('FAMIO_NEW_URL');

Finder tile(String title) => find.byWidgetPredicate(
  (w) => w is ListTile && w.title is Text && (w.title! as Text).data == title,
);

String? subtitleOf(WidgetTester tester, String title) {
  final t = tester.widget<ListTile>(tile(title).first);
  return t.subtitle is Text ? (t.subtitle! as Text).data : null;
}

/// Whether anything answers on [port] of this computer.
Future<bool> listening(int port) async {
  for (final host in [
    InternetAddress.loopbackIPv4,
    InternetAddress.loopbackIPv6,
  ]) {
    try {
      final s = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      s.destroy();
      return true;
    } on SocketException {
      // Nothing there.
    }
  }
  return false;
}

/// The value next to [label] on the status page.
String infoValue(WidgetTester tester, String label) {
  final row = find.byWidgetPredicate(
    (w) =>
        w.runtimeType.toString() == '_InfoRow' && (w as dynamic).label == label,
  );
  return (tester.widget(row.first) as dynamic).value as String;
}

void main() {
  deviceLanguage = () => 'de';
  catalogBinding();

  setUp(() {
    expect(kitUrl, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
  });

  testWidgets(
    'GRU-104 without an HTTPS port: told, the connection stays as it was',
    (tester) async {
      tester.view.physicalSize =
          const Size(800, 1600) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      final port = Uri.parse(_tlsUrl).port;
      expect(AppState.defaultTlsPort, port, reason: 'the test server\'s');
      expect(AppState.defaultTlsPort, isNot(8776));
      final admin = await kitAdminApi();
      expect((await admin.adminOverview()).tlsPort, isNull);
      expect(await listening(port), isFalse, reason: 'no HTTPS port');
      final state = await startApp(tester);
      final before = state.serverUrl;
      final token = await state.vault.read('token');
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, find.text(de.settingsUnencryptedLan));
      expect(
        subtitleOf(tester, de.settingsUnencryptedLan),
        de.settingsUnencryptedLanHint,
      );
      await tap(
        tester,
        find.widgetWithText(FilledButton, de.settingsEncryptNow),
      );
      final told = find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(de.settingsServerDoesNotOffer(port)),
      );
      await waitFor(tester, told);
      debugPrint(
        'E2E-INFO without HTTPS: ${de.settingsServerDoesNotOffer(port)}',
      );
      expect(find.text(de.trustMatches), findsNothing);
      // Nothing changed: still the same plain home network connection.
      expect(state.serverUrl, before);
      expect(state.certificatePin, isNull);
      expect(await state.vault.read('token'), token);
      expect(state.me, isNotNull);
      expect(find.text(de.settingsUnencryptedLan), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, de.settingsEncryptNow),
        findsOneWidget,
      );
      final engine = state.engine!;
      await engine.sync();
      expect(engine.status.state, SyncState.idle);
      await finish(tester, state);
    },
  );

  testWidgets('SIC-122 backups switched off: the status tab and the API', (
    tester,
  ) async {
    tester.view.physicalSize =
        const Size(800, 1600) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    final admin = await kitAdminApi();
    expect(await admin.backupStatus(), containsPair('enabled', false));
    final state = await startApp(tester);
    await openAdmin(tester, de.adminStatus);
    await scrollTo(tester, find.text(de.adminTurnedOffFamioBackup));
    debugPrint('E2E-INFO backups: ${de.adminTurnedOffFamioBackup}');
    expect(find.text(de.adminBackups), findsOneWidget);
    expect(find.text(de.adminBackUpNow), findsNothing);
    expect(find.text(de.adminCheckBackup), findsNothing);
    expect(find.text(de.adminNoBackupYet), findsNothing);
    // The same server without its HTTPS port, as the status says.
    await scrollTo(tester, find.text(de.adminHttpsHomeNetwork), up: true);
    expect(infoValue(tester, de.adminHttpsHomeNetwork), de.commonOff);
    // Asked for one through the API anyway.
    Object? refused;
    try {
      await admin.backupNow();
    } on ApiError catch (e) {
      refused = e;
    }
    expect(refused, isA<ApiError>());
    final error = refused! as ApiError;
    debugPrint(
      'E2E-INFO POST /api/admin/backups: ${error.status} ${error.message}',
    );
    expect(error.status, 400);
    expect(
      error.message,
      'Sicherungen sind ausgeschaltet (FAMIO_BACKUP_DIR=off)',
    );
    await finish(tester, state);
  });
}
