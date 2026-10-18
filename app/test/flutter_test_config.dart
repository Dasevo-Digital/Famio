import 'dart:async';

import 'package:famio/src/l10n.dart';
import 'package:famio/src/screens/deferred_sections.dart';

/// The tests read German texts; the test machine's language is English.
/// The deferred areas are loaded first, as in the apps: in a test's fake
/// time loading them would never finish.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  deviceLanguage = () => 'de';
  await loadAllSections();
  await testMain();
}
