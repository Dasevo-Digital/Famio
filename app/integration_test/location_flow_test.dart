// End-to-end test of location sharing on Android against a running server:
//
//   adb emu geo fix 9.995 53.575          # the emulator's position
//   flutter test integration_test/location_flow_test.dart -d emulator-5554 \
//     --dart-define=FAMIO_URL=https://10.0.2.2:8766 \
//     --dart-define=FAMIO_FINGERPRINT=AB:CD:… \
//     --dart-define=FAMIO_USER=admin --dart-define=FAMIO_PASSWORD=...
//
// The location permission must be granted beforehand (adb shell pm grant),
// Android's dialog cannot be tapped from a test. Creates a temporary child
// account and a place at the emulator's position, shares the location from
// the app, pauses, resumes and ends sharing with the parents' code, and
// removes everything again.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/location/location_sharing.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');
const _fingerprint = String.fromEnvironment('FAMIO_FINGERPRINT');

/// The emulator's position (see `adb emu geo fix`).
const _lat = 53.575;
const _lon = 9.995;

const _kid = 'e2e-standort';
const _kidPassword = 'e2e-standort-123';
const _code = '2468';

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
    throw TestFailure('Timed out waiting for $finder');
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await waitFor(tester, finder);
    // The phone keyboard may cover it.
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

  Finder inDialog(String label) => find.descendant(
    of: find.byType(Dialog),
    matching: find.widgetWithText(FilledButton, label),
  );

  Future<void> enter(WidgetTester tester, String label, String text) async {
    final field = find.widgetWithText(TextField, label);
    await waitFor(tester, field);
    await tester.enterText(field.last, text);
    await tester.pump();
  }

  /// Polls the server (as the parent) until [check] holds.
  Future<T> serverUntil<T>(
    WidgetTester tester,
    FamioApiClient api,
    T? Function(List<SyncRecord> records) check, {
    Duration timeout = const Duration(seconds: 150),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final records = (await api.sync(const SyncRequest(since: 0))).changes;
      final result = check(records);
      if (result != null) return result;
      await tester.pump(const Duration(seconds: 2));
    }
    throw TestFailure('Server did not reach the expected state');
  }

  testWidgets('share, arrive, pause, resume and end', (tester) async {
    expect(_url, isNotEmpty, reason: 'pass --dart-define=FAMIO_URL=…');
    final parent = FamioApiClient(_url, pinnedCertificate: _fingerprint);
    await parent.login(username: _user, password: _password, device: 'e2e');
    final codeWasSet = (await parent.adminOverview()).locationCodeSet;
    expect(codeWasSet, isFalse, reason: 'test would change the real code');
    for (final u in await parent.adminUsers()) {
      if (u.member.username == _kid) await parent.deleteMember(u.member.id);
    }
    final kid = await parent.createMember(
      username: _kid,
      displayName: 'E2E Standort',
      password: _kidPassword,
    );
    await parent.setLocationCode(_code);
    final me = await parent.me();
    final placeId = newId();
    await parent.sync(
      SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.places,
            id: placeId,
            data: Place(
              id: placeId,
              name: 'E2E Schule',
              latitude: _lat,
              longitude: _lon,
              radius: 300,
              notifyMemberIds: [me.id],
            ).toData(),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      ),
    );

    try {
      await initializeDateFormatting('de');
      final state = AppState();
      await state.init();
      await tester.pumpWidget(FamioApp(state: state));

      // Sign in as the child.
      await enter(tester, 'Server-Adresse', _url);
      await tap(tester, find.text('Verbinden'));
      if (_fingerprint.isNotEmpty) {
        await waitFor(tester, find.text('Zertifikat des Servers prüfen'));
        await tap(tester, find.text('Stimmt überein'));
        await dialogClosed(tester);
      }
      await enter(tester, 'Benutzername', _kid);
      await enter(tester, 'Passwort', _kidPassword);
      await tap(tester, find.text('Anmelden'));

      // Standort sits behind "Mehr" on phones.
      await tap(tester, find.byTooltip('Mehr'));
      await tap(tester, find.text('Standort'));
      await waitFor(tester, find.text('Wo ist wer?'));
      await tap(tester, find.text('Standort teilen'));
      // Without "all the time" Famio offers it afterwards; not here.
      await waitFor(
        tester,
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data == 'Später' || w.data == 'Du teilst deinen Standort'),
        ),
        timeout: const Duration(seconds: 60),
      );
      if (find.text('Später').evaluate().isNotEmpty) {
        await tap(tester, find.text('Später'));
        await dialogClosed(tester);
      }
      await waitFor(tester, find.text('Du teilst deinen Standort'));
      expect((await LocationSharing.status()).enabled, isTrue);

      // The native service reports: the child arrives at the place and the
      // parent gets a notice.
      final location = await serverUntil(tester, parent, (records) {
        final r = records
            .where(
              (r) =>
                  r.collection == Collections.memberLocations &&
                  r.id == kid.id &&
                  !r.deleted,
            )
            .firstOrNull;
        if (r == null) return null;
        final l = MemberLocation.fromRecord(r);
        return l.placeId == placeId ? l : null;
      });
      expect(location.state, SharingState.active);
      expect((location.latitude! - _lat).abs(), lessThan(0.01));
      final alert = await serverUntil(
        tester,
        parent,
        (records) => records
            .where(
              (r) => r.collection == Collections.locationAlerts && !r.deleted,
            )
            .map(LocationAlert.fromRecord)
            .where((a) => a.memberId == kid.id)
            .firstOrNull,
      );
      expect(alert.text('E2E Standort'), contains('„E2E Schule“ angekommen'));
      await waitFor(
        tester,
        find.textContaining('Bei „E2E Schule“'),
        timeout: const Duration(seconds: 60),
      );

      // A wrong code does not pause; the right one does.
      await tap(tester, find.text('Pausieren'));
      await tap(tester, find.text('3 Stunden'));
      await enter(tester, 'Eltern-Code', '0000');
      await tap(tester, inDialog('Pausieren'));
      await waitFor(tester, find.text('Der Eltern-Code stimmt nicht'));
      await enter(tester, 'Eltern-Code', _code);
      await tap(tester, inDialog('Pausieren'));
      await dialogClosed(tester);
      await waitFor(tester, find.text('Freigabe pausiert'));
      await serverUntil(
        tester,
        parent,
        (records) =>
            records.any(
              (r) =>
                  r.collection == Collections.memberLocations &&
                  r.id == kid.id &&
                  MemberLocation.fromRecord(r).state == SharingState.paused,
            )
            ? true
            : null,
      );

      // Resuming needs no code.
      await tap(tester, find.text('Fortsetzen'));
      await waitFor(tester, find.text('Du teilst deinen Standort'));

      // Ending on this phone needs the code and stops the service.
      await tap(tester, find.text('Beenden'));
      await enter(tester, 'Eltern-Code', _code);
      await tap(tester, inDialog('Beenden'));
      await dialogClosed(tester);
      await waitFor(tester, find.text('Standort teilen'));
      expect((await LocationSharing.status()).enabled, isFalse);

      await state.signOut();
    } finally {
      await parent.deleteMember(kid.id);
      await parent.sync(
        SyncRequest(
          since: 0,
          changes: [
            SyncRecord(
              collection: Collections.places,
              id: placeId,
              data: const {},
              deleted: true,
              updatedAt: DateTime.now().millisecondsSinceEpoch + 1000,
            ),
          ],
        ),
      );
      await parent.setLocationCode(null);
      await parent.logout();
    }
  });
}
