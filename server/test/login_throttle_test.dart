import 'package:famio_server/famio_server.dart';
import 'package:test/test.dart';

void main() {
  var now = DateTime(2026, 9, 27, 12);
  LoginThrottle throttle() => LoginThrottle(clock: () => now);

  setUp(() => now = DateTime(2026, 9, 27, 12));

  test('a mistyping member is slowed down after five tries', () {
    final t = throttle();
    for (var i = 0; i < 4; i++) {
      t.failed('1.2.3.4', 'mama');
    }
    expect(t.blockedFor('1.2.3.4', 'mama'), isNull);
    t.failed('1.2.3.4', 'mama');
    expect(t.blockedFor('1.2.3.4', 'Mama'), isNotNull);
    // Others are not affected.
    expect(t.blockedFor('1.2.3.4', 'papa'), isNull);
    expect(t.blockedFor('5.6.7.8', 'mama'), isNull);
    now = now.add(const Duration(seconds: 31));
    expect(t.blockedFor('1.2.3.4', 'mama'), isNull);
  });

  test('trying many accounts from one address is blocked', () {
    final t = throttle();
    for (var i = 0; i < 20; i++) {
      t.failed('1.2.3.4', 'user$i');
    }
    expect(t.blockedFor('1.2.3.4', 'jemand-neues'), isNotNull);
    expect(t.blockedFor('5.6.7.8', 'jemand-neues'), isNull);
  });

  test('guessing one account from many addresses is blocked', () {
    final t = throttle();
    for (var i = 0; i < 20; i++) {
      t.failed('10.0.0.$i', 'mama');
    }
    expect(t.blockedFor('10.0.1.1', 'mama'), isNotNull);
    expect(t.blockedFor('10.0.1.1', 'papa'), isNull);
  });

  test('flooding with made-up names does not lift a block', () {
    final t = throttle();
    for (var i = 0; i < 6; i++) {
      t.failed('1.2.3.4', 'mama');
    }
    for (var i = 0; i < 12000; i++) {
      t.failed('9.9.${i ~/ 250}.${i % 250}', 'fake$i');
    }
    expect(t.blockedFor('1.2.3.4', 'mama'), isNotNull);
  });

  test('a success forgives only that address and account', () {
    final t = throttle();
    for (var i = 0; i < 4; i++) {
      t.failed('1.2.3.4', 'mama');
    }
    t.succeeded('1.2.3.4', 'mama');
    t.failed('1.2.3.4', 'mama');
    expect(t.blockedFor('1.2.3.4', 'mama'), isNull);
  });

  test('old failures are forgotten after an hour', () {
    final t = throttle();
    for (var i = 0; i < 4; i++) {
      t.failed('1.2.3.4', 'mama');
    }
    now = now.add(const Duration(hours: 2));
    t.failed('1.2.3.4', 'mama');
    expect(t.blockedFor('1.2.3.4', 'mama'), isNull);
  });
}
