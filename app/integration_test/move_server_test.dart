// The family server moved (same data, new address): the app switches over
// without signing in again.
//
//   flutter drive … --target integration_test/move_server_test.dart \
//     --dart-define=FAMIO_URL=localhost:8775 \
//     --dart-define=FAMIO_NEW_URL=192.168.1.10:8775 \
//     --dart-define=FAMIO_PASSWORD=…
import 'package:famio/src/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _url = String.fromEnvironment('FAMIO_URL');
const _newUrl = String.fromEnvironment('FAMIO_NEW_URL');
const _user = String.fromEnvironment('FAMIO_USER', defaultValue: 'admin');
const _password = String.fromEnvironment('FAMIO_PASSWORD');

/// First run of a real move: only sign in, then copy the server's data to
/// the new place and run again without it.
const _signInOnly = bool.fromEnvironment('FAMIO_SIGN_IN_ONLY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('moving to a new address keeps the session', (tester) async {
    final state = AppState();
    await state.init();
    if (state.me == null) {
      final server = await state.resolveServer(_url, trust: (_) async => true);
      await state.signIn(server, _user, _password);
    }
    if (_signInOnly) return;
    final me = state.me!;
    final before = state.serverUrl!;

    await state.moveServer(_newUrl, trust: (_) async => true);
    expect(state.serverUrl, isNot(before));
    expect(
      Uri.parse(state.serverUrl!).port,
      isNot(Uri.parse(before).port),
    );
    expect(state.me!.id, me.id);
    expect(state.certificatePin, isNotNull);
    await state.engine!.sync();

    // An address without that session is refused and nothing changes.
    final moved = state.serverUrl;
    await expectLater(
      state.moveServer('localhost:9', trust: (_) async => true),
      throwsA(anything),
    );
    expect(state.serverUrl, moved);
    await state.signOut();
  });
}
