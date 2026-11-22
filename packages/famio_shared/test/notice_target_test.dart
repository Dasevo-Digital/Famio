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

  test('dates far from any calendar are left out (#579)', () {
    for (final text in [
      'day:@+275760-09-13T00:00:00.000Z',
      'day:@-271821-04-20',
      'day:@1899-12-31',
      'day:@2201-01-01',
    ]) {
      expect(NoticeTarget.decode(text), isNull, reason: text);
    }
    final link = NoticeTarget.fromLink(
      Uri.parse('famio://open?target=event:weekly@%2B275760-09-13T00:00:00Z'),
    );
    expect(link, const NoticeTarget.event('weekly'));
    expect(
      NoticeTarget.decode('day:@1900-01-01'),
      NoticeTarget.day(DateTime(1900)),
    );
    expect(
      NoticeTarget.decode('event:e1@2200-12-31T10:00:00.000')?.at,
      DateTime(2200, 12, 31, 10),
    );
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
