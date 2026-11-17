import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('targets survive encoding', () {
    for (final t in [
      const NoticeTarget.task('t1'),
      NoticeTarget.event('e1', DateTime(2026, 11, 17, 9)),
      const NoticeTarget.event('e2'),
      const NoticeTarget.chat('family'),
      const NoticeTarget.child('k1'),
      const NoticeTarget.pregnancy('p1'),
      const NoticeTarget.sos('a1'),
      const NoticeTarget.section('location'),
      const NoticeTarget.page(NoticeTarget.deadlines),
      NoticeTarget.day(DateTime(2026, 11, 20, 18, 30)),
    ]) {
      expect(NoticeTarget.decode(t.encode()), t, reason: t.encode());
    }
    expect(
      NoticeTarget.day(DateTime(2026, 11, 20, 18, 30)).at,
      DateTime(2026, 11, 20),
    );
  });

  test('ids from other calendars keep their @', () {
    final t = NoticeTarget.decode(
      'event:abc@example.com@2026-11-17T09:00:00.000',
    );
    expect(t?.id, 'abc@example.com');
    expect(t?.at, DateTime(2026, 11, 17, 9));
    expect(NoticeTarget.decode('event:abc@example.com')?.id, 'abc@example.com');
  });

  test('anything else is no target', () {
    for (final text in [
      null,
      '',
      'task',
      'task:',
      'day:',
      'day:x',
      'nonsense:1',
      'http://example.com',
      'x' * 600,
    ]) {
      expect(NoticeTarget.decode(text), isNull, reason: '$text');
    }
  });
}
