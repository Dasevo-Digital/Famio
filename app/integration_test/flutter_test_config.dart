import 'dart:async';

import 'package:famio/src/l10n.dart';

/// The tests read German texts; the test machine's language is English.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  deviceLanguage = () => 'de';
  await testMain();
}
