import 'package:famio_client/famio_client.dart';
import '../l10n.dart';

/// Totals of one day of a child's log.
class DaySummary {
  DaySummary(this.day);

  final DateTime day;
  var milkMl = 0;
  var feedings = 0;
  var breast = Duration.zero;
  var sleep = Duration.zero;
  var wet = 0;
  var dirty = 0;
  double? maxTemperature;
  var medications = 0;

  bool get isEmpty =>
      feedings == 0 &&
      sleep == Duration.zero &&
      wet == 0 &&
      dirty == 0 &&
      maxTemperature == null &&
      medications == 0;
}

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// Totals for [day]; sleep and nursing count only the part inside the day
/// (a night's sleep is split at midnight).
DaySummary summarize(List<ChildLog> logs, DateTime day, [DateTime? now]) {
  final start = _dayOf(day);
  final end = DateTime(start.year, start.month, start.day + 1);
  final at = now ?? DateTime.now();
  final s = DaySummary(start);
  Duration overlap(ChildLog l) {
    final from = l.start.isBefore(start) ? start : l.start;
    final stop = l.end ?? at;
    final to = stop.isAfter(end) ? end : stop;
    return to.isAfter(from) ? to.difference(from) : Duration.zero;
  }

  for (final l in logs) {
    final inDay = !l.start.isBefore(start) && l.start.isBefore(end);
    switch (l.kind) {
      case LogKind.sleep:
        s.sleep += overlap(l);
      case LogKind.breast:
        s.breast += overlap(l);
        if (inDay) s.feedings++;
      case LogKind.bottle:
        if (inDay) {
          s.feedings++;
          s.milkMl += l.amountMl ?? 0;
        }
      case LogKind.solids:
        if (inDay) s.feedings++;
      case LogKind.diaper:
        if (inDay) {
          if (l.diaper != DiaperKind.dirty) s.wet++;
          if (l.diaper != DiaperKind.wet) s.dirty++;
        }
      case LogKind.temperature:
        final t = l.temperatureC;
        if (inDay && t != null) {
          s.maxTemperature = s.maxTemperature == null || t > s.maxTemperature!
              ? t
              : s.maxTemperature;
        }
      case LogKind.medication:
        if (inDay) s.medications++;
      case LogKind.pumping || LogKind.symptom || LogKind.bath:
        break;
    }
  }
  return s;
}

/// How much of a child's log the summary covers.
enum LogPeriod { day, week, month }

/// The days of the [period] around [anchor]: the day itself, Monday to
/// Sunday, or the calendar month.
List<DateTime> periodDays(LogPeriod period, DateTime anchor) {
  final day = _dayOf(anchor);
  final (first, count) = switch (period) {
    LogPeriod.day => (day, 1),
    LogPeriod.week => (
      DateTime(day.year, day.month, day.day - (day.weekday - 1)),
      7,
    ),
    LogPeriod.month => (
      DateTime(day.year, day.month),
      DateTime(day.year, day.month + 1, 0).day,
    ),
  };
  return [
    for (var i = 0; i < count; i++)
      DateTime(first.year, first.month, first.day + i),
  ];
}

/// [anchor] moved by [steps] periods (negative: back in time).
DateTime shiftPeriod(LogPeriod period, DateTime anchor, int steps) =>
    switch (period) {
      LogPeriod.day => DateTime(anchor.year, anchor.month, anchor.day + steps),
      LogPeriod.week => DateTime(
        anchor.year,
        anchor.month,
        anchor.day + 7 * steps,
      ),
      // The 1st, so that 31 January does not jump over February.
      LogPeriod.month => DateTime(anchor.year, anchor.month + steps),
    };

/// Averages per day over [days], counting only days from the first entry
/// up to [now]: a week that has just begun, or a month in which the log
/// was started, is not diluted by days nobody wrote anything down.
class PeriodSummary {
  PeriodSummary(List<ChildLog> logs, List<DateTime> days, DateTime now) {
    final today = _dayOf(now);
    final first = logs.isEmpty
        ? today
        : _dayOf(
            logs.map((l) => l.start).reduce((a, b) => a.isBefore(b) ? a : b),
          );
    final counted = [
      for (final d in days)
        if (!d.isAfter(today) && !d.isBefore(first)) d,
    ];
    this.days = counted.length;
    for (final d in counted) {
      final s = summarize(logs, d, now);
      feedings += s.feedings;
      milkMl += s.milkMl;
      breast += s.breast;
      sleep += s.sleep;
      wet += s.wet;
      dirty += s.dirty;
      if (s.maxTemperature case final t?
          when maxTemperature == null || t > maxTemperature!) {
        maxTemperature = t;
      }
    }
  }

  late final int days;
  var feedings = 0;
  var milkMl = 0;
  var breast = Duration.zero;
  var sleep = Duration.zero;
  var wet = 0;
  var dirty = 0;
  double? maxTemperature;

  double perDay(num total) => days == 0 ? 0 : total / days;
  Duration durationPerDay(Duration total) =>
      days == 0 ? Duration.zero : total ~/ days;
}

/// The latest entry of [kind] (logs are newest first).
ChildLog? lastOf(List<ChildLog> logs, LogKind kind) =>
    logs.where((l) => l.kind == kind).firstOrNull;

/// The latest feeding of any kind.
ChildLog? lastFeeding(List<ChildLog> logs) => logs
    .where(
      (l) =>
          l.kind == LogKind.breast ||
          l.kind == LogKind.bottle ||
          l.kind == LogKind.solids,
    )
    .firstOrNull;

/// The side to offer next: the other one than last time.
BreastSide? nextBreastSide(List<ChildLog> logs) {
  final last = lastOf(logs, LogKind.breast)?.side;
  return switch (last) {
    BreastSide.left => BreastSide.right,
    BreastSide.right => BreastSide.left,
    null => null,
  };
}

/// When [medication] may be given again, from the latest dose and the
/// interval entered with it; null without an interval.
DateTime? nextDoseAt(List<ChildLog> logs, String medication) {
  final name = medication.trim().toLowerCase();
  final last = logs
      .where(
        (l) =>
            l.kind == LogKind.medication &&
            l.medication.trim().toLowerCase() == name,
      )
      .firstOrNull;
  final hours = last?.minIntervalHours;
  if (last == null || hours == null || hours <= 0) return null;
  return last.start.add(Duration(minutes: (hours * 60).round()));
}

/// Medicines given before, most recent first (for quick re-entry).
List<ChildLog> recentMedications(List<ChildLog> logs) {
  final seen = <String>{};
  return [
    for (final l in logs)
      if (l.kind == LogKind.medication &&
          l.medication.isNotEmpty &&
          seen.add(l.medication.trim().toLowerCase()))
        l,
  ];
}

enum FeverLevel { normal, raised, fever, doctor, urgent }

/// A cautious hint for a measured temperature. Famio does not diagnose;
/// the texts point to the pediatrician, 116 117 or 112.
({FeverLevel level, String text}) feverAdvice(
  Child child,
  double celsius, {
  DateTime? at,
  List<ChildLog> logs = const [],
}) {
  final now = at ?? DateTime.now();
  bool youngerThanMonths(int months) {
    final month = DateTime(
      child.birthDate.year,
      child.birthDate.month + months,
    );
    final days = DateTime(month.year, month.month + 1, 0).day;
    return now.isBefore(
      DateTime(month.year, month.month, child.birthDate.day.clamp(1, days)),
    );
  }

  final warnings = tr.healthCall112RightAway;
  if (celsius >= 41) {
    return (
      level: FeverLevel.urgent,
      text: tr.healthVeryHighFeverGet(warnings),
    );
  }
  if (celsius >= 38 && youngerThanMonths(3)) {
    return (
      level: FeverLevel.urgent,
      text: tr.healthBabiesUnder3Months(warnings),
    );
  }
  if ((celsius >= 39 && youngerThanMonths(6)) || celsius >= 40) {
    return (
      level: FeverLevel.doctor,
      text: tr.healthHighFeverContactPediatrician(warnings),
    );
  }
  if (celsius >= 38.5) {
    final temperatures = [
      for (final l in logs)
        if (l.childId == child.id &&
            l.kind == LogKind.temperature &&
            l.temperatureC != null &&
            !l.start.isAfter(now))
          l,
    ]..sort((a, b) => b.start.compareTo(a.start));
    final episode = <ChildLog>[];
    for (final l in temperatures) {
      if (l.temperatureC! < 38.5) break;
      episode.add(l);
    }
    // https://www.kindergesundheit-info.de/themen/krankes-kind/krankheitszeichen/fieber/
    final underTwo = youngerThanMonths(24);
    if (underTwo &&
        episode.any((l) => now.difference(l.start) > const Duration(days: 1))) {
      return (
        level: FeverLevel.doctor,
        text: tr.healthFeverUnderTwoDay(warnings),
      );
    }
    final feverDays = {
      for (final l in episode)
        if (now.difference(l.start).inDays < 4) _dayOf(l.start),
      _dayOf(now),
    };
    return (
      level: feverDays.length >= 3 ? FeverLevel.doctor : FeverLevel.fever,
      text: feverDays.length >= 3
          ? tr.healthFeverDaysDaysPlease(feverDays.length, warnings)
          : tr.healthFeverLetChildDrink(warnings),
    );
  }
  if (celsius >= 37.6) {
    return (
      level: FeverLevel.raised,
      text: tr.healthRaisedTemperatureMeasureAgain,
    );
  }
  return (level: FeverLevel.normal, text: tr.healthNormalTemperature);
}

/// "2 h 5 min", "12 min", "40 s".
String durationLabel(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return h == 0 ? '$m min' : '$h h${m == 0 ? '' : ' $m min'}';
}

/// "gerade eben", "vor 25 min", "vor 2 h 40 min", "vor 3 Tagen".
String sinceLabel(DateTime t, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return tr.agoJustNow;
  if (d.inHours < 24) return tr.agoAgo(durationLabel(d));
  return tr.agoDaysAgo(d.inDays);
}
