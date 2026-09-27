import 'package:famio_client/famio_client.dart';

import 'kids_logic.dart';

/// "24+3".
String weekLabel(Pregnancy p, [DateTime? at]) {
  final (w, d) = p.weekOn(at ?? DateTime.now());
  return '$w+$d';
}

/// 1, 2 or 3.
int trimester(Pregnancy p, [DateTime? at]) {
  final (w, _) = p.weekOn(at ?? DateTime.now());
  return w < 13 ? 1 : (w < 28 ? 2 : 3);
}

/// Days until the due date (negative after it).
int daysToGo(Pregnancy p, [DateTime? at]) {
  final now = at ?? DateTime.now();
  return DateTime.utc(
    p.dueDate.year,
    p.dueDate.month,
    p.dueDate.day,
  ).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
}

/// State of an appointment or to-do on [at].
DueState taskState(Pregnancy p, PregnancyTask t, [DateTime? at]) {
  if (p.done.contains(t.id)) return DueState.done;
  final now = at ?? DateTime.now();
  final (w, _) = p.weekOn(now);
  if (w < t.fromWeek) return DueState.upcoming;
  if (w <= t.toWeek) return DueState.due;
  return DueState.late;
}

/// First day of maternity protection: six weeks before the due date.
DateTime maternityLeave(Pregnancy p) =>
    DateTime(p.dueDate.year, p.dueDate.month, p.dueDate.day - 42);

/// Contractions of the last [window]: count, average length and interval
/// (start to start).
({int count, Duration? length, Duration? interval}) contractionStats(
  List<Contraction> all, {
  DateTime? at,
  Duration window = const Duration(hours: 1),
}) {
  final now = at ?? DateTime.now();
  final recent = all.where((c) => now.difference(c.start) <= window).toList();
  final lengths = [for (final c in recent) ?c.length];
  final gaps = [
    for (var i = 1; i < recent.length; i++)
      recent[i].start.difference(recent[i - 1].start),
  ];
  Duration? avg(List<Duration> l) => l.isEmpty
      ? null
      : Duration(
          seconds: l.fold<int>(0, (s, d) => s + d.inSeconds) ~/ l.length,
        );
  return (count: recent.length, length: avg(lengths), interval: avg(gaps));
}

/// The common "5-1-1" rule: contractions every 5 minutes or less, about a
/// minute long, for an hour.
bool timeToCall(List<Contraction> all, {DateTime? at}) {
  final now = at ?? DateTime.now();
  final s = contractionStats(all, at: now);
  final first = all
      .where((c) => now.difference(c.start) <= const Duration(hours: 1))
      .firstOrNull;
  return s.count >= 8 &&
      first != null &&
      now.difference(first.start) >= const Duration(minutes: 50) &&
      (s.interval ?? const Duration(hours: 1)) <= const Duration(minutes: 5) &&
      (s.length ?? Duration.zero) >= const Duration(seconds: 45);
}
