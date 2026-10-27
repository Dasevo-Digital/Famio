import 'dart:async';

/// Runs [start] so that an error a background job lets slip (a timer's
/// network call without a catch) is reported to [log] instead of ending the
/// process: in 2.0.15 a TLS error of the Bring! sync during the router's
/// nightly reconnect took the family's server down. Errors before [start]
/// completes go to [fail] instead: a broken setup must not look like a
/// running server.
void runGuarded(
  Future<void> Function() start, {
  required void Function(Object error, StackTrace stack) log,
  required void Function(Object error, StackTrace stack) fail,
}) {
  var started = false;
  runZonedGuarded(() async {
    await start();
    started = true;
  }, (error, stack) => started ? log(error, stack) : fail(error, stack));
}
