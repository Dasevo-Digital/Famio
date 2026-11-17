// What comes from outside Famio opens where it belongs, on a real phone
// system: a famio:// link (ntfy) and a tapped notification of the own push
// open the task (#385); on iPhones, what the share sheet hands over reaches
// "Teilen an Famio" with a recipe link first (#567).
//
// Android: tool/android_review_tests.py emulator-<port>
//   --file integration_test/review_open_test.dart
// iOS simulator: tool/ios_review_tests.py <simulator id>
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'catalog_kit.dart';

const _hostPort = String.fromEnvironment('FAMIO_E2E_HOST_PORT');

/// The Mac seen from the emulator or the simulator.
String get _hostAddress => Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';

var _seq = 0;

String b64(String text) => base64Url.encode(utf8.encode(text));

/// Something only the host can do; it says whether it worked.
Future<String> hostOk(String command) async {
  final id = 'o${_seq++}';
  // ignore: avoid_print
  print('E2E-HOST $command @id=$id');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final watch = Stopwatch()..start();
  try {
    while (watch.elapsed < const Duration(minutes: 3)) {
      try {
        final request = await client.getUrl(
          Uri.parse('http://$_hostAddress:$_hostPort/r/$id'),
        );
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 200) {
          final json = jsonDecode(body) as Map<String, Object?>;
          if (json['ok'] != true) {
            throw TestFailure('host $command failed: ${json['out']}');
          }
          return '${json['out'] ?? ''}';
        }
      } on IOException {
        // Not up yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  } finally {
    client.close(force: true);
  }
  throw TestFailure('The host did not answer: $command');
}

/// A link as another app opens it: Android through `am start`; on iOS
/// handed to the native code as iOS hands it over, without the system's
/// question "Open in Famio?" that a simulator cannot answer.
Future<void> openLink(String url) async {
  if (Platform.isAndroid) {
    await hostOk('view-link ${b64(url)}');
  } else {
    const channel = MethodChannel('famio/open_file');
    expect(await channel.invokeMethod<bool>('debugOpenURL', url), isTrue);
  }
}

Future<void> _task(
  WidgetTester tester,
  AppState state,
  String id,
  String title,
) async {
  final admin = await kitAdminApi();
  await put(admin, Collections.tasks, {
    id: Task(id: id, title: title, assigneeIds: [state.me!.id]).toData(),
  });
  await eventually(
    tester,
    'task $id on the device',
    () async => state.engine!.tasks.any((t) => t.id == id),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a famio:// link opens the task (#385)', (tester) async {
    final state = await startApp(tester);
    await _task(tester, state, 'e2e-open-link', 'E2E Link-Aufgabe');
    await openLink(const NoticeTarget.task('e2e-open-link').link);
    await waitFor(
      tester,
      find.widgetWithText(TextField, 'E2E Link-Aufgabe'),
      timeout: const Duration(seconds: 30),
    );
    await finish(tester, state);
  });

  testWidgets('a tapped notification of the own push opens the task (#385)', (
    tester,
  ) async {
    final state = await startApp(tester);
    await hostOk('grant');
    // Android: the own push runs as a service once switched on.
    await state.ownPush!.setEnabled(true);
    await tester.pump(const Duration(seconds: 3));
    final family = await theFamily();
    final bea = await sessionOf(family.bea);
    await put(bea, Collections.tasks, {
      'e2e-open-push': Task(
        id: 'e2e-open-push',
        title: 'E2E Push-Aufgabe',
        assigneeIds: [state.me!.id],
      ).toData(),
    });
    await hostOk(
      'tap-notification ${b64('E2E Push-Aufgabe|Neue Aufgabe für dich')} 60',
    );
    await waitFor(
      tester,
      find.widgetWithText(TextField, 'E2E Push-Aufgabe'),
      timeout: const Duration(seconds: 30),
    );
    await state.ownPush!.setEnabled(false);
    await finish(tester, state);
  }, skip: defaultTargetPlatform != TargetPlatform.android);

  testWidgets('the share sheet hands a recipe link over (#567)', (
    tester,
  ) async {
    final state = await startApp(tester);
    await hostOk(
      'share-sheet ${b64(jsonEncode({'text': 'Spaghetti Carbonara – Rezept | Chefkoch '
          'https://www.chefkoch.de/rezepte/1234/Carbonara.html', 'subject': 'Spaghetti Carbonara'}))}',
    );
    // The share extension then opens Famio with its link.
    await openLink('famio://share');
    await waitFor(
      tester,
      find.text('Teilen an Famio'),
      timeout: const Duration(seconds: 30),
    );
    final recipe = tester.getTopLeft(find.text('Als Rezept importieren'));
    final inbox = tester.getTopLeft(find.text('Im Familien-Eingang ablegen'));
    expect(recipe.dy, lessThan(inbox.dy));
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await finish(tester, state);
  }, skip: defaultTargetPlatform != TargetPlatform.iOS);
}
