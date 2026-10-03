import 'package:shared_preferences/shared_preferences.dart';

/// Set by `tool/integration_tests.sh`, whose servers are thrown away after
/// each test: a session left over from an aborted run would point at a
/// server that is gone, so every test starts signed out.
const _freshStart = bool.fromEnvironment('FAMIO_FRESH_START');

/// Forgets the saved server and member (call before `AppState.init`).
Future<void> freshStart() async {
  if (!_freshStart) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
}
