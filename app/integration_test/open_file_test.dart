// "Öffnen mit" on Windows and Linux: Famio is started a second time with a
// calendar file, hands it to the Famio that runs and ends. One Famio per
// installation is a release feature, so this runs in profile mode:
//
//   flutter drive --profile -d linux \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/open_file_test.dart
//
// On Linux the bundle needs an application id of its own for the test
// (APPLICATION_ID in linux/CMakeLists.txt), else a Famio installed on the
// same machine would get the file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/platform/opened_files.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _ics = '''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Schule//Kalender//DE
BEGIN:VEVENT
UID:elternabend-2026@schule.example
DTSTART;TZID=Europe/Berlin:20261020T193000
DTEND;TZID=Europe/Berlin:20261020T210000
SUMMARY:Elternabend Klasse 3b – Aula
END:VEVENT
END:VCALENDAR
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a second start hands its calendar file over and ends', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final dir = await Directory.systemTemp.createTemp('famio-öffnen ');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}Schuljahr.ics')
      ..writeAsStringSync(_ics);

    var opened = Completer<void>();
    OpenedFiles.listen();
    OpenedFiles.onOpened = () {
      if (!opened.isCompleted) opened.complete();
    };
    expect(await OpenedFiles.take(), isNull);

    final watch = Stopwatch()..start();
    final second = await Process.run(Platform.resolvedExecutable, [
      file.path,
    ]).timeout(const Duration(seconds: 20));
    expect(second.exitCode, 0);
    // Handed over, not a second Famio that runs until it is closed.
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));

    await opened.future.timeout(const Duration(seconds: 10));
    final taken = await OpenedFiles.take();
    expect(taken?.name, 'Schuljahr.ics');
    expect(utf8.decode(taken!.bytes), _ics);
    expect(await OpenedFiles.take(), isNull);

    // A start without a file only brings Famio to the front.
    opened = Completer<void>();
    final third = await Process.run(
      Platform.resolvedExecutable,
      const [],
    ).timeout(const Duration(seconds: 20));
    expect(third.exitCode, 0);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(opened.isCompleted, isFalse);
    expect(await OpenedFiles.take(), isNull);
  });
}
