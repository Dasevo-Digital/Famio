// Catalog SIC-123 „Sicherung wiederherstellen“: with the server stopped,
// tool/famio-restore-backup.sh puts a backup back; afterwards the Mac app
// shows the state of the backup, the running one as well as after signing
// in again, and the databases from before lie set aside.
//
// tool/integration_tests.sh starts this file's server through
// tool/e2e_server.py, which stops, restores and restarts it on request:
// e2e-control: restore
import 'dart:convert';
import 'dart:io';

import 'package:famio/src/data/family_data.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_kit.dart';

const _control = String.fromEnvironment('FAMIO_E2E_CONTROL');

Future<Map<String, Object?>> _restore(String backup) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('$_control/restore').replace(queryParameters: {'name': backup}),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200, reason: body);
    return jsonDecode(body) as Map<String, Object?>;
  } finally {
    client.close(force: true);
  }
}

Future<void> _openPinboard(WidgetTester tester) async {
  await openSection(tester, 'Start');
  await scrollTo(tester, find.text(de.commonPinboard));
  await tap(tester, find.text(de.commonPinboard));
  await dismissTip(tester);
  await waitFor(tester, find.text(de.notesNotesFamily));
}

void main() {
  catalogBinding();

  testWidgets('SIC-123 a restored backup is what the app shows', (
    tester,
  ) async {
    expect(
      _control,
      isNotEmpty,
      reason: 'tool/integration_tests.sh sets FAMIO_E2E_CONTROL',
    );
    final state = await startApp(tester);
    final admin = await kitAdminApi();
    final before = uid('restore-before');
    final after = uid('restore-after');
    await put(admin, Collections.notes, {
      before: FamilyNote(id: before, title: 'E2E vor der Sicherung').toData(),
    });
    await admin.backupNow();
    await put(admin, Collections.notes, {
      after: FamilyNote(id: after, title: 'E2E nach der Sicherung').toData(),
    });
    await admin.createMember(
      username: 'e2e-nachher',
      displayName: 'E2E Nachher',
      password: kitMemberPassword,
    );
    await eventually(tester, 'both notes on the device', () async {
      final ids = {for (final n in state.engine!.notes) n.id};
      return ids.contains(before) && ids.contains(after);
    });

    final status = await admin.backupStatus();
    final newest = (status['backups'] as List).first['name'] as String;
    final restored = await _restore(newest);
    expect(restored['ok'], isTrue, reason: '${restored['output']}');
    final aside = (restored['aside']! as List).cast<String>();
    expect(aside.where((f) => f.endsWith('/famio.db')), hasLength(1));
    expect(aside.where((f) => f.endsWith('/files.db')), hasLength(1));
    // In a folder named after the time, "before-restore-<Datum-Zeit>".
    for (final f in aside) {
      expect(f, matches(RegExp(r'^before-restore-\d{8}-\d{6}(-\d+)?/')));
    }
    expect('${restored['output']}', contains('Jetzt Famio wieder starten'));

    // The app that kept running is back at the backup's state.
    await eventually(
      tester,
      'only the note from before the backup on the device',
      () async {
        await state.engine!.sync().catchError((Object _) {});
        final ids = {for (final n in state.engine!.notes) n.id};
        return ids.contains(before) && !ids.contains(after);
      },
      timeout: const Duration(minutes: 2),
    );

    // „Famio starten und anmelden“: signed out and in again.
    await finish(tester, state);
    await waitFor(tester, field('Server-Adresse'));
    // The sign-in page asks only for name and password when it still
    // knows the server; otherwise the address comes first.
    if (field('Benutzername').evaluate().isEmpty) {
      await enter(tester, field('Server-Adresse'), kitUrl);
      await tap(tester, find.text('Verbinden'));
    }
    await enter(tester, field('Benutzername'), kitUser);
    await enter(tester, field('Passwort'), kitPassword);
    await tap(tester, find.text('Anmelden'));
    await waitFor(tester, signedInMark, timeout: const Duration(seconds: 60));
    if (find.text(de.commonLater).evaluate().isNotEmpty) {
      await tap(tester, find.text(de.commonLater).last);
    }
    await _openPinboard(tester);
    await waitFor(tester, find.text('E2E vor der Sicherung'));
    expect(find.text('E2E nach der Sicherung'), findsNothing);
    // The member made after the backup is gone with it.
    await expectLater(
      FamioApiClient(kitUrl).login(
        username: 'e2e-nachher',
        password: kitMemberPassword,
        device: 'e2e',
      ),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 401)),
    );
    await finish(tester, state);
  });
}
