import 'dart:async';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a background error after the start is logged, the server stays',
    () async {
      final logged = <Object>[];
      var failed = false;
      final done = Completer<void>();
      runGuarded(
        () async {
          // Like a timer's sync whose network error nobody catches.
          Timer(const Duration(milliseconds: 20), () {
            Future<void>.error(const HandshakeException('unrecognized name'));
            Timer(const Duration(milliseconds: 20), done.complete);
          });
        },
        log: (error, _) => logged.add(error),
        fail: (_, _) => failed = true,
      );
      await done.future;
      expect(logged.single, isA<HandshakeException>());
      expect(failed, isFalse);
    },
  );

  test('an error while starting still ends it', () async {
    final failed = Completer<void>();
    runGuarded(
      () async => throw StateError('port in use'),
      log: (_, _) {},
      fail: (_, _) => failed.complete(),
    );
    await failed.future.timeout(const Duration(seconds: 2));
  });
}
