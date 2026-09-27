import 'package:famio_client/famio_client.dart';

/// "3 Wochen", "5 Monate", "1 Jahr und 3 Monate", "6 Jahre".
String ageLabel(Child child, [DateTime? at]) {
  final now = at ?? DateTime.now();
  final days = now.difference(child.birthDate).inDays;
  if (days < 0) return 'noch nicht geboren';
  if (days < 14) return days == 1 ? '1 Tag' : '$days Tage';
  final months = child.ageInMonths(now);
  if (months < 2) return '${days ~/ 7} Wochen';
  if (months < 24) {
    if (months < 12) return '$months Monate';
    final rest = months - 12;
    return rest == 0
        ? '1 Jahr'
        : '1 Jahr und $rest ${rest == 1 ? 'Monat' : 'Monate'}';
  }
  final years = months ~/ 12;
  final rest = months % 12;
  return years < 6 && rest > 0
      ? '$years Jahre und $rest ${rest == 1 ? 'Monat' : 'Monate'}'
      : '$years Jahre';
}

enum DueState {
  /// Recorded as done.
  done,

  /// Inside its window now.
  due,

  /// Past the window but still within tolerance.
  late,

  /// Tolerance passed without a record.
  missed,

  /// Window lies ahead.
  upcoming,
}

/// A check-up or vaccination with its dates for one child.
class DueItem {
  const DueItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.from,
    required this.to,
    required this.state,
    this.entry,
    this.isCheckup = true,
    this.optional = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final DateTime from;
  final DateTime to;
  final DueState state;
  final ChildEntry? entry;
  final bool isCheckup;

  /// Not covered by every insurance; never nagged about.
  final bool optional;

  bool get open => state == DueState.due || state == DueState.late;
}

List<DueItem> checkupPlan(
  Child child,
  List<ChildEntry> entries, [
  DateTime? at,
]) {
  final now = at ?? DateTime.now();
  return [
    for (final c in checkups)
      () {
        final entry = entries
            .where((e) => e.kind == ChildEntryKind.checkup && e.refId == c.id)
            .firstOrNull;
        final from = child.birthDate.add(Duration(days: c.fromDay));
        final to = child.birthDate.add(Duration(days: c.toDay));
        final tolerance = child.birthDate.add(Duration(days: c.toleranceTo));
        final day = DateTime(now.year, now.month, now.day);
        final state = entry != null
            ? DueState.done
            : day.isBefore(from)
            ? DueState.upcoming
            : !day.isAfter(to)
            ? DueState.due
            : !day.isAfter(tolerance)
            ? DueState.late
            : DueState.missed;
        return DueItem(
          id: c.id,
          title: c.title,
          subtitle:
              '${c.window}${c.optional ? ' · nicht bei allen Kassen' : ''}',
          from: from,
          to: to,
          state: state,
          entry: entry,
          optional: c.optional,
        );
      }(),
  ];
}

List<DueItem> vaccinationPlan(
  Child child,
  List<ChildEntry> entries, [
  DateTime? at,
]) {
  final now = at ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  return [
    for (final v in vaccinations)
      () {
        final entry = entries
            .where(
              (e) => e.kind == ChildEntryKind.vaccination && e.refId == v.id,
            )
            .firstOrNull;
        final from = child.ageDate(v.ageMonths);
        // Vaccinations have no fixed window; a month counts as "due".
        final to = from.add(const Duration(days: 31));
        final state = entry != null
            ? DueState.done
            : day.isBefore(from)
            ? DueState.upcoming
            : !day.isAfter(to)
            ? DueState.due
            // Many parents never record past vaccinations: an old
            // unrecorded dose is neutral, not an endless alarm.
            : DueState.missed;
        return DueItem(
          id: v.id,
          title: v.title,
          subtitle: [v.dose, if (v.note.isNotEmpty) v.note].join(' · '),
          from: from,
          to: to,
          state: state,
          entry: entry,
          isCheckup: false,
        );
      }(),
  ];
}

/// The next thing parents should look after: an open check-up first, then
/// open vaccinations, else the next upcoming check-up.
DueItem? nextDue(Child child, List<ChildEntry> entries, [DateTime? at]) {
  final ups = checkupPlan(child, entries, at).where((d) => !d.optional);
  final vacs = vaccinationPlan(child, entries, at);
  return ups.where((d) => d.open).firstOrNull ??
      vacs.where((d) => d.open).firstOrNull ??
      ups.where((d) => d.state == DueState.upcoming).firstOrNull;
}
