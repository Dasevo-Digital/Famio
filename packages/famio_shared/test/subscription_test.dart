import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

Subscription abo({
  int cents = 1000,
  DateTime? start,
  int every = 1,
  SubscriptionUnit unit = SubscriptionUnit.months,
  DateTime? endsOn,
  String category = 'Streaming',
  String? memberId,
}) => Subscription(
  id: 'a',
  name: 'Film',
  cents: cents,
  start: start ?? DateTime(2026, 1, 15),
  every: every,
  unit: unit,
  endsOn: endsOn,
  category: category,
  memberId: memberId,
);

void main() {
  group('next payment', () {
    test('before the first payment it is the first', () {
      expect(abo().nextPayment(DateTime(2025, 12, 1)), DateTime(2026, 1, 15));
    });

    test('on the day of a payment it is that day', () {
      expect(
        abo().nextPayment(DateTime(2026, 3, 15, 22)),
        DateTime(2026, 3, 15),
      );
    });

    test('the day after it is the next one', () {
      expect(abo().nextPayment(DateTime(2026, 3, 16)), DateTime(2026, 4, 15));
    });

    test('the 31st goes back to the 31st after a short month', () {
      final s = abo(start: DateTime(2026, 1, 31));
      expect(s.nextPayment(DateTime(2026, 2, 1)), DateTime(2026, 2, 28));
      expect(s.nextPayment(DateTime(2026, 3, 1)), DateTime(2026, 3, 31));
      expect(s.nextPayment(DateTime(2026, 4, 1)), DateTime(2026, 4, 30));
    });

    test('a leap day comes back in a leap year only', () {
      final s = abo(start: DateTime(2024, 2, 29), unit: SubscriptionUnit.years);
      expect(s.nextPayment(DateTime(2025, 1, 1)), DateTime(2025, 2, 28));
      expect(s.nextPayment(DateTime(2028, 1, 1)), DateTime(2028, 2, 29));
    });

    test('weeks and days keep the calendar over the clock change', () {
      final weekly = abo(
        start: DateTime(2026, 3, 23),
        unit: SubscriptionUnit.weeks,
      );
      expect(weekly.nextPayment(DateTime(2026, 3, 30)), DateTime(2026, 3, 30));
      expect(weekly.nextPayment(DateTime(2026, 3, 31)), DateTime(2026, 4, 6));
      final daily = abo(
        start: DateTime(2026, 10, 24),
        every: 2,
        unit: SubscriptionUnit.days,
      );
      expect(daily.nextPayment(DateTime(2026, 10, 25)), DateTime(2026, 10, 26));
    });

    test('every three months over a new year', () {
      final s = abo(start: DateTime(2025, 11, 10), every: 3);
      expect(s.nextPayment(DateTime(2026, 1, 1)), DateTime(2026, 2, 10));
      expect(s.nextPayment(DateTime(2026, 2, 11)), DateTime(2026, 5, 10));
    });

    test('long after the start it still finds the right one', () {
      final s = abo(start: DateTime(2010, 1, 15));
      expect(s.nextPayment(DateTime(2026, 11, 9)), DateTime(2026, 11, 15));
    });

    test('a cancelled one stops after its last day', () {
      final s = abo(endsOn: DateTime(2026, 4, 30));
      expect(s.nextPayment(DateTime(2026, 4, 1)), DateTime(2026, 4, 15));
      expect(s.nextPayment(DateTime(2026, 4, 16)), isNull);
      expect(s.runsAt(DateTime(2026, 4, 16)), isFalse);
      expect(s.payments(DateTime(2026, 3, 1), 5), [
        DateTime(2026, 3, 15),
        DateTime(2026, 4, 15),
      ]);
    });
  });

  group('costs', () {
    test('come to the same per month and year for any period', () {
      expect(abo(cents: 1200).centsPerYear, 14400);
      expect(abo(cents: 1200).centsPerMonth, 1200);
      expect(
        abo(cents: 12000, unit: SubscriptionUnit.years).centsPerMonth,
        1000,
      );
      expect(abo(cents: 3000, every: 3).centsPerMonth, 1000);
      expect(abo(cents: 700, unit: SubscriptionUnit.weeks).centsPerYear, 36500);
      expect(abo(cents: 100, unit: SubscriptionUnit.days).centsPerYear, 36500);
    });

    test('add up what is running, by category and by who pays', () {
      final now = DateTime(2026, 3, 1);
      final stats = SubscriptionStats([
        abo(cents: 1000, start: DateTime(2026, 1, 20)),
        abo(
          cents: 2400,
          every: 2,
          start: DateTime(2026, 1, 5),
          category: 'Cloud',
          memberId: 'm1',
        ),
        abo(cents: 500, endsOn: DateTime(2026, 2, 20), category: 'Musik'),
      ], now);
      expect(stats.running.map((s) => s.cents), [2400, 1000]);
      expect(stats.ended.single.cents, 500);
      expect(stats.perMonth, 2200);
      expect(stats.perYear, 26400);
      expect(stats.byCategory, {'Streaming': 1000, 'Cloud': 1200});
      expect(stats.byMember, {null: 1000, 'm1': 1200});
      expect(stats.savedPerMonth, 500);
    });

    test('the next days count every payment in them', () {
      final now = DateTime(2026, 3, 1);
      final stats = SubscriptionStats([
        abo(
          cents: 100,
          start: DateTime(2026, 3, 2),
          unit: SubscriptionUnit.weeks,
        ),
        abo(cents: 1000, start: DateTime(2026, 6, 1)),
      ], now);
      // 2, 9, 16, 23 and 30 March; the other one starts in June.
      expect(stats.nextDays, 500);
    });

    test('nothing at all', () {
      final stats = SubscriptionStats(const [], DateTime(2026, 3, 1));
      expect(stats.perMonth, 0);
      expect(stats.running, isEmpty);
      expect(stats.byCategory, isEmpty);
    });
  });

  test('survives the record round trip', () {
    final s = Subscription(
      id: 'x',
      name: 'Zeitung',
      cents: 1999,
      start: DateTime(2026, 2, 3),
      every: 6,
      unit: SubscriptionUnit.weeks,
      category: 'Eigene',
      payment: 'PayPal',
      memberId: 'm1',
      url: 'https://example.org',
      note: 'Familienabo',
      endsOn: DateTime(2027, 1, 1),
      remindDays: null,
    );
    final back = Subscription.fromRecord(
      SyncRecord(
        collection: Collections.subscriptions,
        id: 'x',
        data: s.toData(),
        updatedAt: 1,
      ),
    );
    expect(back.toData(), s.toData());
    expect(back.remindDays, isNull);
  });

  test('an unknown unit falls back to months', () {
    final r = Subscription.fromRecord(
      const SyncRecord(
        collection: Collections.subscriptions,
        id: 'x',
        data: {'unit': 'fortnights', 'every': 0},
        updatedAt: 1,
      ),
    );
    expect(r.unit, SubscriptionUnit.months);
    expect(r.every, 1);
  });
}
