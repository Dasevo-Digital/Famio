import 'dart:math' as math;

import '../sync_record.dart';

/// How a subscription's period is counted.
enum SubscriptionUnit { days, weeks, months, years }

/// Suggested categories; families can add their own.
const subscriptionCategories = [
  'Streaming',
  'Musik',
  'Software',
  'Cloud',
  'Spiele',
  'Zeitung',
  'Sport',
  'Mobilfunk',
  'Versicherung',
  'Sonstiges',
];

/// Something paid again and again (`Collections.subscriptions`). The dates
/// of the payments follow from [start] and the period, nothing has to be
/// moved on after a payment.
class Subscription {
  const Subscription({
    required this.id,
    required this.name,
    required this.cents,
    required this.start,
    this.every = 1,
    this.unit = SubscriptionUnit.months,
    this.category = 'Sonstiges',
    this.payment = '',
    this.memberId,
    this.url = '',
    this.note = '',
    this.endsOn,
    this.remindDays = 3,
  });

  factory Subscription.fromRecord(SyncRecord r) => Subscription(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    cents: (r.data['cents'] as num?)?.toInt() ?? 0,
    start: _date(r.data['start']) ?? DateTime(2000),
    every: ((r.data['every'] as num?)?.toInt() ?? 1).clamp(1, 999),
    unit:
        SubscriptionUnit.values.asNameMap()[r.data['unit']] ??
        SubscriptionUnit.months,
    category: r.data['category'] as String? ?? 'Sonstiges',
    payment: r.data['payment'] as String? ?? '',
    memberId: r.data['memberId'] as String?,
    url: r.data['url'] as String? ?? '',
    note: r.data['note'] as String? ?? '',
    endsOn: _date(r.data['endsOn']),
    remindDays: (r.data['remindDays'] as num?)?.toInt(),
  );

  final String id;
  final String name;

  /// What one payment costs.
  final int cents;

  /// The first payment.
  final DateTime start;

  /// Paid every [every] [unit].
  final int every;
  final SubscriptionUnit unit;
  final String category;

  /// How it is paid ("Lastschrift", "PayPal"), in the family's own words.
  final String payment;

  /// Who pays it; null: the family together.
  final String? memberId;

  /// Where to manage or cancel it.
  final String url;
  final String note;

  /// Cancelled: the last day it runs; no payments after it.
  final DateTime? endsOn;

  /// Days ahead of a payment to remind; null: no reminder.
  final int? remindDays;

  /// Payment number [n] (0 is the first). Counted from [start], so that one
  /// on the 31st goes back to the 31st after a short month.
  DateTime paymentAt(int n) {
    final s = start;
    return switch (unit) {
      SubscriptionUnit.days => DateTime(s.year, s.month, s.day + n * every),
      SubscriptionUnit.weeks => DateTime(
        s.year,
        s.month,
        s.day + 7 * n * every,
      ),
      SubscriptionUnit.months => _monthsLater(s, n * every),
      SubscriptionUnit.years => _monthsLater(s, 12 * n * every),
    };
  }

  static DateTime _monthsLater(DateTime s, int months) {
    final first = DateTime(s.year, s.month + months);
    final last = DateTime(first.year, first.month + 1, 0).day;
    return DateTime(first.year, first.month, math.min(s.day, last));
  }

  /// A number of the payment at or shortly before [day].
  int _about(DateTime day) {
    if (!day.isAfter(start)) return 0;
    final n = switch (unit) {
      SubscriptionUnit.days => _days(start, day) ~/ every,
      SubscriptionUnit.weeks => _days(start, day) ~/ (7 * every),
      SubscriptionUnit.months => _months(start, day) ~/ every,
      SubscriptionUnit.years => _months(start, day) ~/ (12 * every),
    };
    return math.max(0, n - 1);
  }

  static int _days(DateTime a, DateTime b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  static int _months(DateTime a, DateTime b) =>
      (b.year - a.year) * 12 + b.month - a.month;

  /// The next [count] payments from the day of [from] on.
  List<DateTime> payments(DateTime from, [int count = 1]) {
    final day = DateTime(from.year, from.month, from.day);
    var n = _about(day);
    while (paymentAt(n).isBefore(day)) {
      n++;
    }
    return [
      for (var i = 0; i < count; i++)
        if (endsOn == null || !paymentAt(n + i).isAfter(endsOn!))
          paymentAt(n + i),
    ];
  }

  /// The next payment; null once it has run out.
  DateTime? nextPayment(DateTime from) {
    final next = payments(from);
    return next.isEmpty ? null : next.first;
  }

  /// Whether payments are still to come.
  bool runsAt(DateTime day) => nextPayment(day) != null;

  /// What it comes to in a year, however often it is paid.
  double get centsPerYear =>
      cents *
      switch (unit) {
        SubscriptionUnit.days => 365 / every,
        SubscriptionUnit.weeks => 365 / (7 * every),
        SubscriptionUnit.months => 12 / every,
        SubscriptionUnit.years => 1 / every,
      };

  double get centsPerMonth => centsPerYear / 12;

  Map<String, Object?> toData() => {
    'name': name,
    'cents': cents,
    'start': _day(start),
    'every': every,
    'unit': unit.name,
    'category': category,
    'payment': payment,
    'memberId': memberId,
    'url': url,
    'note': note,
    'endsOn': endsOn == null ? null : _day(endsOn!),
    'remindDays': remindDays,
  };
}

/// What the subscriptions come to on [now]'s day.
class SubscriptionStats {
  factory SubscriptionStats(Iterable<Subscription> all, DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    final running = <Subscription>[];
    final ended = <Subscription>[];
    for (final s in all) {
      (s.runsAt(day) ? running : ended).add(s);
    }
    running.sort((a, b) => a.nextPayment(day)!.compareTo(b.nextPayment(day)!));
    var perYear = 0.0;
    var saved = 0.0;
    var soon = 0;
    final byCategory = <String, double>{};
    final byMember = <String?, double>{};
    final horizon = DateTime(day.year, day.month, day.day + soonDays);
    for (final s in running) {
      perYear += s.centsPerYear;
      byCategory[s.category] = (byCategory[s.category] ?? 0) + s.centsPerMonth;
      byMember[s.memberId] = (byMember[s.memberId] ?? 0) + s.centsPerMonth;
      for (var n = 0; ; n++) {
        final due = s.payments(day, n + 1);
        if (due.length <= n || due[n].isAfter(horizon)) break;
        soon += s.cents;
      }
    }
    for (final s in ended) {
      saved += s.centsPerMonth;
    }
    return SubscriptionStats._(
      running,
      ended,
      perYear.round(),
      soon,
      saved.round(),
      {for (final e in byCategory.entries) e.key: e.value.round()},
      {for (final e in byMember.entries) e.key: e.value.round()},
    );
  }

  const SubscriptionStats._(
    this.running,
    this.ended,
    this.perYear,
    this.nextDays,
    this.savedPerMonth,
    this.byCategory,
    this.byMember,
  );

  /// The horizon of [nextDays].
  static const soonDays = 30;

  /// Payments still to come, the next one first.
  final List<Subscription> running;

  /// Cancelled and run out.
  final List<Subscription> ended;

  /// Cents a year for what is [running].
  final int perYear;

  int get perMonth => (perYear / 12).round();

  /// Cents due within the next [soonDays] days.
  final int nextDays;

  /// Cents a month no longer paid for what has [ended].
  final int savedPerMonth;

  /// Cents a month by category and by who pays (null: together).
  final Map<String, int> byCategory;
  final Map<String?, int> byMember;
}

DateTime? _date(Object? v) {
  final d = v is String ? DateTime.tryParse(v) : null;
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
