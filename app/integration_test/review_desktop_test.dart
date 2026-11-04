// Acceptance test of the Paperless-ngx connection, the offline copies of
// files and pairing a device, against a throwaway server:
//
//   tool/integration_tests.sh macos integration_test/review_desktop_test.dart
//
// One test per feature, each starts signed out and signs in as the admin.
// Paperless-ngx is a small stand-in served by this test (its API as far as
// Famio uses it); files Famio hands to the system's app for them, and the
// clipboard, are replaced at their plugin boundary, so nothing opens on the
// desktop and the person's clipboard stays as it was.
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'fresh_start.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');

/// A PDF as Paperless-ngx or a person's scanner would have it.
final _pdf = utf8.encode(
  '%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
  '2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\n'
  'trailer << /Root 1 0 R >>\n%%EOF\n',
);

/// Stands in for "open with the system's app": keeps the files.
class _FakeLauncher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

/// Paperless-ngx with one document tagged "Familie", served without a
/// length (like behind some proxies), so Famio learns the size only while
/// downloading.
class _FakePaperless {
  late final HttpServer _server;
  final requests = <String>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final response = request.response;
      requests.add(request.uri.path);
      if (request.headers.value('authorization') != 'Token e2e-token') {
        response.statusCode = 401;
        await response.close();
        return;
      }
      Object? page(List<Object?> results) => {
        'count': results.length,
        'next': null,
        'results': results,
      };
      final json = switch (request.uri.path) {
        '/api/tags/' => page([
          {'id': 7, 'name': 'Familie'},
        ]),
        '/api/documents/' => page([
          {
            'id': 42,
            'title': 'E2E Steuerbescheid',
            'created': '2026-10-30',
            'modified': '2026-10-30T10:00:00Z',
            'original_file_name': 'steuerbescheid.pdf',
            'archived_file_name': 'steuerbescheid.pdf',
            'correspondent': 3,
            'document_type': null,
            'custom_fields': <Object?>[],
          },
        ]),
        '/api/correspondents/' => page([
          {'id': 3, 'name': 'Finanzamt'},
        ]),
        '/api/document_types/' => page([]),
        _ => null,
      };
      if (json != null) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(json));
      } else if (request.uri.path == '/api/documents/42/download/') {
        response.headers
          ..contentType = ContentType('application', 'pdf')
          ..chunkedTransferEncoding = true;
        response.add(_pdf.sublist(0, 20));
        await response.flush();
        response.add(_pdf.sublist(20));
      } else {
        response.statusCode = 404;
      }
      await response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

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

  /// Pumps until [ok] holds.
  Future<void> until(
    WidgetTester tester,
    bool Function() ok,
    String what, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    debugPrint('E2E until $what');
    final end = DateTime.now().add(timeout);
    while (!ok()) {
      if (DateTime.now().isAfter(end)) throw TestFailure('Timed out: $what');
      await tester.pump(const Duration(milliseconds: 200));
    }
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
    final controller = tester.widget<TextField>(field.last).controller;
    await tester.tap(field.last);
    await tester.pump();
    await tester.enterText(field.last, text);
    await tester.pump();
    if (controller != null && controller.text != text) {
      controller.text = text;
      await tester.pump();
    }
  }

  /// Scrolls the page until [finder] is built (long lists build lazily).
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await waitFor(tester, finder);
  }

  Future<void> openSection(WidgetTester tester, String label) async {
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == label) ||
            (w is Tooltip && (w.message == label || w.message == 'Mehr')),
      ),
    );
    if (find.byTooltip(label).evaluate().isNotEmpty) {
      await tap(tester, find.byTooltip(label).last);
    } else if (find.byTooltip('Mehr').evaluate().isNotEmpty) {
      await tap(tester, find.byTooltip('Mehr').last);
      await tap(tester, find.text(label).last);
    } else {
      await tap(tester, find.text(label).last);
    }
    await tester.pump(const Duration(milliseconds: 500));
    if (find.text('Verstanden').evaluate().isNotEmpty) {
      await tap(tester, find.text('Verstanden').last);
    }
  }

  Future<void> back(WidgetTester tester) async {
    await tap(tester, find.byTooltip('Zurück').last);
    await tester.pump(const Duration(milliseconds: 500));
  }

  FamioApiClient? adminApi;
  Future<FamioApiClient> admin() async {
    if (adminApi case final api?) return api;
    final api = FamioApiClient(_url);
    await api.login(username: _user, password: _password, device: 'e2e');
    return adminApi = api;
  }

  Future<void> signIn(WidgetTester tester) async {
    await enter(tester, find.widgetWithText(TextField, 'Server-Adresse'), _url);
    await tap(tester, find.text('Verbinden'));
    await enter(tester, find.widgetWithText(TextField, 'Benutzername'), _user);
    await enter(tester, find.widgetWithText(TextField, 'Passwort'), _password);
    await tap(tester, find.text('Anmelden'));
  }

  Future<void> signedIn(WidgetTester tester, AppState state) async {
    await until(
      tester,
      () => state.me != null && state.engine != null,
      'signed in',
    );
    await state.engine!.sync();
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            (w is Text && w.data == 'Start') ||
            (w is Tooltip && w.message == 'Start'),
      ),
    );
  }

  Future<AppState> start(WidgetTester tester) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    await initializeDateFormatting('de');
    await freshStart();
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));
    if (state.me == null) await signIn(tester);
    await signedIn(tester, state);
    return state;
  }

  Future<void> finish(WidgetTester tester, AppState state) async {
    try {
      await state.signOut();
      await tester.pump(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('E2E clean-up failed: $e');
    }
  }

  /// Opens a document's details from the list and taps "Öffnen".
  Future<void> openDocument(WidgetTester tester, String title) async {
    await openSection(tester, 'Dokumente');
    await scrollTo(tester, find.text(title));
    await tap(tester, find.text(title));
    await tap(tester, find.widgetWithText(ColorButton, 'Öffnen'));
  }

  testWidgets('Abmelden von außen schließt ein offenes Fenster', (
    tester,
  ) async {
    // The session ends while a sheet is open, as when "Das war ich nicht"
    // or a new password on another device signs this one out.
    final state = await start(tester);
    await scrollTo(tester, find.text('Pinnwand'));
    await tap(tester, find.text('Pinnwand'));
    await tap(tester, find.byTooltip('Notiz anlegen'));
    await waitFor(tester, find.text('Neue Notiz'));
    await state.signOut(notice: 'E2E: von einem anderen Gerät abgemeldet');
    await waitFor(tester, find.widgetWithText(TextField, 'Server-Adresse'));
    expect(find.text('Neue Notiz'), findsNothing);
    expect(
      find.text('E2E: von einem anderen Gerät abgemeldet'),
      findsOneWidget,
    );
  });

  testWidgets(
    '#155 #277 #279 Paperless-ngx verbinden, „Ändern“, Dokument öffnen',
    (tester) async {
      final paperless = _FakePaperless();
      await paperless.start();
      final launcher = _FakeLauncher();
      final launcherBefore = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = launcher;
      final state = await start(tester);
      try {
        // Einstellungen → Server-Verwaltung → Einstellungen → Paperless-ngx.
        await openSection(tester, 'Einstellungen');
        await scrollTo(tester, find.text('Server-Verwaltung'));
        await tap(tester, find.text('Server-Verwaltung'));
        await waitFor(tester, find.text('Benutzer'));
        await tap(tester, find.text('Einstellungen').last);
        await waitFor(tester, find.text('Öffentliche Adresse'));
        await scrollTo(tester, find.text('Paperless-ngx'));
        Finder tile() => find.ancestor(
          of: find.text('Paperless-ngx'),
          matching: find.byType(ListTile),
        );
        await tap(
          tester,
          find.descendant(
            of: tile(),
            matching: find.widgetWithText(TextButton, 'Einrichten'),
          ),
        );
        await enter(
          tester,
          find.widgetWithText(
            TextField,
            'Adresse (z. B. http://192.168.1.20:8000)',
          ),
          paperless.url,
        );
        await enter(
          tester,
          find.widgetWithText(TextField, 'Token eines Paperless-ngx-Benutzers'),
          'e2e-token',
        );
        await tap(tester, find.widgetWithText(FilledButton, 'Verbinden'));
        await waitFor(tester, find.text('Paperless-ngx verbunden'));
        await tester.pump(const Duration(seconds: 1));
        if (find.byType(Dialog).evaluate().isNotEmpty) {
          await tester.tapAt(const Offset(10, 10));
          await tester.pump(const Duration(milliseconds: 500));
        }

        // Set up: the tile says so and offers "Ändern" instead.
        await scrollTo(tester, find.text('Paperless-ngx'));
        await waitFor(
          tester,
          find.descendant(
            of: tile(),
            matching: find.textContaining('Verbunden mit 127.0.0.1'),
          ),
        );
        expect(
          find.descendant(
            of: tile(),
            matching: find.widgetWithText(TextButton, 'Ändern'),
          ),
          findsOneWidget,
        );
        // The others are still to set up.
        await scrollTo(tester, find.text('App-Updates über den Server'));
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text('App-Updates über den Server'),
              matching: find.byType(ListTile),
            ),
            matching: find.widgetWithText(TextButton, 'Einrichten'),
          ),
          findsOneWidget,
        );
        await back(tester);

        // The tagged document is in Famio; its size comes with the file.
        await until(
          tester,
          () => state.engine!.records(Collections.externalDocuments).isNotEmpty,
          'document from Paperless-ngx',
        );
        final ref = FileRef.fromJson(
          state.engine!
              .records(Collections.externalDocuments)
              .single
              .data['file'],
        )!;
        expect(ref.size, 0);
        await openDocument(tester, 'E2E Steuerbescheid');
        await until(tester, () => launcher.opened.isNotEmpty, 'file opened');
        final opened = File.fromUri(Uri.parse(launcher.opened.single));
        expect(await opened.readAsBytes(), _pdf);
        expect(paperless.requests, contains('/api/documents/42/download/'));
      } finally {
        UrlLauncherPlatform.instance = launcherBefore;
        try {
          await (await admin()).deletePaperless();
        } catch (_) {}
        await finish(tester, state);
        await paperless.stop();
      }
    },
  );

  testWidgets('Offline-Kopie: öffnen, Speicher leeren, wieder öffnen', (
    tester,
  ) async {
    final api = await admin();
    final ref = await api.uploadFile(
      bytes: _pdf,
      name: 'e2e-impfpass.pdf',
      mime: 'application/pdf',
    );
    final id = newId();
    await api.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.documents,
            id: id,
            data: FamilyDocument(
              id: id,
              title: 'E2E Impfpass',
              category: DocumentCategory.health,
              file: ref,
            ).toData(),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      ),
    );
    final launcher = _FakeLauncher();
    final launcherBefore = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    final state = await start(tester);
    try {
      final files = state.files!;
      files.clear();
      expect(files.size, 0);

      // Opened once, the file stays on the device for offline use.
      await openDocument(tester, 'E2E Impfpass');
      await until(tester, () => launcher.opened.length == 1, 'opened');
      expect(
        await File.fromUri(Uri.parse(launcher.opened.last)).readAsBytes(),
        _pdf,
      );
      expect(files.size, greaterThan(0));
      expect(await files.bytes(ref), _pdf);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 500));

      // Einstellungen → Speicher auf diesem Gerät → Leeren.
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, find.text('Speicher auf diesem Gerät'));
      await tap(
        tester,
        find.descendant(
          of: find.ancestor(
            of: find.text('Speicher auf diesem Gerät'),
            matching: find.byType(ListTile),
          ),
          matching: find.widgetWithText(TextButton, 'Leeren'),
        ),
      );
      await waitFor(tester, find.text('Speicher leeren?'));
      await tap(tester, find.widgetWithText(FilledButton, 'Leeren'));
      await until(tester, () => files.size == 0, 'storage empty');

      // Opened again: fetched anew, the same bytes, stored again.
      await openDocument(tester, 'E2E Impfpass');
      await until(tester, () => launcher.opened.length == 2, 'opened again');
      expect(
        await File.fromUri(Uri.parse(launcher.opened.last)).readAsBytes(),
        _pdf,
      );
      expect(files.size, greaterThan(0));
    } finally {
      UrlLauncherPlatform.instance = launcherBefore;
      state.engine?.delete(Collections.documents, id);
      await state.engine?.sync();
      await finish(tester, state);
    }
  });

  testWidgets('Neues Gerät per Kopplungscode anmelden', (tester) async {
    final first = await start(tester);
    AppState? second;
    try {
      // On the signed-in device: Meine Geräte → Neues Gerät koppeln.
      await openSection(tester, 'Einstellungen');
      await scrollTo(tester, find.text('Meine Geräte'));
      await tap(tester, find.text('Meine Geräte'));
      await tap(tester, find.byTooltip('Neues Gerät koppeln'));
      await tap(tester, find.text('Kopplungscode erstellen'));
      await waitFor(tester, find.byType(QrImageView));
      await waitFor(tester, find.textContaining('Gültig bis'));

      // "Code zum Einfügen kopieren", read from the copy instead of the
      // person's clipboard.
      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      try {
        await tap(tester, find.text('Code zum Einfügen kopieren'));
        await waitFor(tester, find.text('Kopplungscode kopiert.'));
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      }
      expect(copied, startsWith('famio-pair:'));
      final link = DevicePairLink.parse(copied!);
      expect(link, isNotNull);

      // A new device: nothing saved, the first one stays signed in.
      final api = await admin();
      final sessionsBefore = (await api.mySessions()).length;
      // The first device's app goes away completely (its snack bar too).
      await until(
        tester,
        () => find.byType(SnackBar).evaluate().isEmpty,
        'snack bar gone',
        timeout: const Duration(seconds: 15),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
      await first.engine?.dispose();
      await (await SharedPreferences.getInstance()).clear();
      second = AppState();
      await second.init();
      await tester.pumpWidget(FamioApp(state: second));
      await tap(tester, find.text('Vorhandenes Konto koppeln'));
      await enter(
        tester,
        find.widgetWithText(TextField, 'Kopplungscode'),
        copied!,
      );
      await tap(tester, find.text('Dieses Gerät koppeln'));
      await signedIn(tester, second);
      expect(second.me!.username, _user);
      expect((await api.mySessions()).length, sessionsBefore + 1);

      // Used once: the same code does not sign in a third device.
      await expectLater(
        FamioApiClient(_url).redeemDevicePairing(secret: link!.secret),
        throwsA(isA<ApiError>()),
      );
    } finally {
      if (second != null) await finish(tester, second);
    }
  });
}
