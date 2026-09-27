import 'package:famio_client/famio_client.dart';

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
  final ageDays = now.difference(child.birthDate).inDays;
  const warnings =
      'Sofort 112 bei Krampfanfall, Atemnot, starker Teilnahmslosigkeit oder '
      'Flecken, die sich nicht wegdrücken lassen.';
  if (celsius >= 41) {
    return (
      level: FeverLevel.urgent,
      text:
          'Sehr hohes Fieber: sofort ärztliche Hilfe holen (116 117, bei '
          'Warnzeichen 112). $warnings',
    );
  }
  if (celsius >= 38 && ageDays < 91) {
    return (
      level: FeverLevel.urgent,
      text:
          'Säuglinge unter 3 Monaten mit 38 °C oder mehr: umgehend Kinderarzt '
          'oder ärztlichen Bereitschaftsdienst (116 117) anrufen. $warnings',
    );
  }
  if ((celsius >= 39 && ageDays < 183) || celsius >= 40) {
    return (
      level: FeverLevel.doctor,
      text:
          'Hohes Fieber: heute noch beim Kinderarzt oder unter 116 117 '
          'melden. $warnings',
    );
  }
  if (celsius >= 38.5) {
    final feverDays = {
      for (final l in logs)
        if (l.kind == LogKind.temperature &&
            (l.temperatureC ?? 0) >= 38.5 &&
            now.difference(l.start).inDays < 4)
          _dayOf(l.start),
      _dayOf(now),
    };
    return (
      level: feverDays.length >= 3 ? FeverLevel.doctor : FeverLevel.fever,
      text: feverDays.length >= 3
          ? 'Fieber seit ${feverDays.length} Tagen: bitte beim Kinderarzt '
                'abklären lassen. $warnings'
          : 'Fieber. Viel trinken lassen und beobachten. Zum Kinderarzt, wenn '
                'es länger als 3 Tage anhält oder das Kind schlecht trinkt. '
                '$warnings',
    );
  }
  if (celsius >= 37.6) {
    return (
      level: FeverLevel.raised,
      text: 'Erhöhte Temperatur – später noch einmal messen.',
    );
  }
  return (level: FeverLevel.normal, text: 'Normale Temperatur.');
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
  if (d.inMinutes < 1) return 'gerade eben';
  if (d.inHours < 24) return 'vor ${durationLabel(d)}';
  final days = d.inDays;
  return days == 1 ? 'vor 1 Tag' : 'vor $days Tagen';
}
