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

/// Whether an unfinished milestone is still useful to show for this age.
///
/// Developmental milestones are not a checklist parents need to complete.
/// Keep a small look-back window for genuinely delayed steps, but hide early
/// baby milestones once they no longer help a family of an older toddler.
bool milestoneIsRelevant(Milestone milestone, double ageInMonths) =>
    milestone.toMonth >= ageInMonths - 6 &&
    milestone.fromMonth <= ageInMonths + 12;

/// Whether the timeline suggests an unfinished milestone as coming up: it
/// starts within the next half year, never one whose time has passed.
bool milestoneIsUpcoming(Milestone milestone, int ageInMonths) =>
    milestone.fromMonth > ageInMonths - 1 &&
    milestone.fromMonth <= ageInMonths + 6;

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

  /// An appointment is booked (check-ups and vaccinations).
  planned,
}

/// The record for one catalog item: a done entry wins over an appointment.
ChildEntry? _entryFor(
  List<ChildEntry> entries,
  ChildEntryKind kind,
  String id,
) {
  final matching = entries.where((e) => e.kind == kind && e.refId == id);
  return matching.where((e) => !e.planned).firstOrNull ?? matching.firstOrNull;
}

DueState _stateOf(ChildEntry? entry, DueState Function() open) =>
    entry == null ? open() : (entry.planned ? DueState.planned : DueState.done);

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

  /// The booked appointment, if any.
  ChildEntry? get appointment => state == DueState.planned ? entry : null;
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
        final entry = _entryFor(entries, ChildEntryKind.checkup, c.id);
        final from = child.birthDate.add(Duration(days: c.fromDay));
        final to = child.birthDate.add(Duration(days: c.toDay));
        final tolerance = child.birthDate.add(Duration(days: c.toleranceTo));
        final day = DateTime(now.year, now.month, now.day);
        final state = _stateOf(
          entry,
          () => day.isBefore(from)
              ? DueState.upcoming
              : !day.isAfter(to)
              ? DueState.due
              : !day.isAfter(tolerance)
              ? DueState.late
              : DueState.missed,
        );
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
        final entry = _entryFor(entries, ChildEntryKind.vaccination, v.id);
        final from = child.ageDate(v.ageMonths);
        // Vaccinations have no fixed window; a month counts as "due".
        final to = from.add(const Duration(days: 31));
        final state = _stateOf(
          entry,
          () => day.isBefore(from)
              ? DueState.upcoming
              : !day.isAfter(to)
              ? DueState.due
              // Many parents never record past vaccinations: an old
              // unrecorded dose is neutral, not an endless alarm.
              : DueState.missed,
        );
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

/// The next thing parents should look after: a booked appointment first,
/// then an open check-up, open vaccinations, else the next upcoming check-up.
DueItem? nextDue(Child child, List<ChildEntry> entries, [DateTime? at]) {
  final now = at ?? DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final ups = checkupPlan(child, entries, at).where((d) => !d.optional);
  final vacs = vaccinationPlan(child, entries, at);
  final booked = [
    for (final d in [...ups, ...vacs])
      if (d.appointment case final a? when !a.date.isBefore(today)) d,
  ]..sort((a, b) => a.entry!.appointmentAt.compareTo(b.entry!.appointmentAt));
  return booked.firstOrNull ??
      ups.where((d) => d.open).firstOrNull ??
      vacs.where((d) => d.open).firstOrNull ??
      ups.where((d) => d.state == DueState.upcoming).firstOrNull;
}
