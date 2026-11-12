import 'package:famio_client/famio_client.dart';
import '../l10n.dart';

/// "3 Wochen", "5 Monate", "1 Jahr und 3 Monate", "6 Jahre".
String ageLabel(Child child, [DateTime? at]) {
  final now = at ?? DateTime.now();
  final days = daysBetween(child.birthDate, now);
  if (days < 0) return tr.ageNotBornYet;
  if (days < 14) return tr.ageDays(days);
  final months = child.ageInMonths(now);
  if (months < 2) return tr.ageWeeks(days ~/ 7);
  if (months < 12) return tr.ageMonths(months);
  final years = months ~/ 12;
  final rest = months % 12;
  return rest > 0 && years < 6
      ? tr.ageYearsMonths(years, rest)
      : tr.ageYears(years);
}

/// Whether an unfinished milestone is still useful to show for this age.
///
/// Developmental milestones are not a checklist parents need to complete.
/// Keep a short look-back window for genuinely delayed steps, but do not ask
/// the family of a two-year-old about first steps (window ends at 18 months).
bool milestoneIsRelevant(Milestone milestone, double ageInMonths) =>
    milestone.toMonth >= ageInMonths - _keptAfter(milestone) &&
    milestone.fromMonth <= ageInMonths + 12;

/// An unfinished milestone whose time has passed: offered only folded away,
/// to add it afterwards.
bool milestoneIsPast(Milestone milestone, double ageInMonths) =>
    milestone.toMonth < ageInMonths - _keptAfter(milestone);

/// Whether an unfinished milestone's window is over: for a boundary step
/// the hint to mention it at the next check-up.
bool milestoneIsOverdue(Milestone milestone, double ageInMonths) =>
    milestone.boundary && ageInMonths > milestone.toMonth;

/// Months an unfinished milestone stays in the list after its window: a
/// boundary step a year, so it is not folded away as "reached earlier".
double _keptAfter(Milestone milestone) => milestone.boundary ? 12 : 3;

/// Whether the timeline suggests an unfinished milestone as coming up: it
/// starts within the next half year, never one whose time has passed.
bool milestoneIsUpcoming(Milestone milestone, int ageInMonths) =>
    milestone.fromMonth > ageInMonths - 1 &&
    milestone.fromMonth <= ageInMonths + 6;

/// Whether a development phase is going on at this age.
bool phaseIsCurrent(DevelopmentPhase phase, double ageInMonths) =>
    phase.fromMonth <= ageInMonths && ageInMonths < phase.toMonth;

/// Whether a development phase begins within the next [months].
bool phaseIsUpcoming(
  DevelopmentPhase phase,
  double ageInMonths, [
  double months = 6,
]) => phase.fromMonth > ageInMonths && phase.fromMonth <= ageInMonths + months;

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
    this.tooLate = false,
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

  /// No longer given at this age: it can only be recorded afterwards.
  final bool tooLate;

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
  final birth = child.birthDate;
  return [
    for (final c in checkups)
      () {
        final entry = _entryFor(entries, ChildEntryKind.checkup, c.id);
        // Calendar days, weeks and months as the Kinder-Richtlinie counts
        // them; [to] and [tolerance] are the last days that still count.
        final from = c.from.after(birth);
        final to = c.until.lastDayBefore(birth);
        final tolerance = c.toleranceUntil.lastDayBefore(birth);
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
              '${c.window}${c.optional ? tr.kidsNotAllHealthInsurers : ''}',
          from: from,
          to: to,
          state: state,
          entry: entry,
          optional: c.optional,
        );
      }(),
  ];
}

/// RSV antibodies after the STIKO recommendation: a baby born in the season
/// (October–March) soon after birth, ideally at the U2; one born April to
/// September in the autumn before its first season. Either way it can be
/// caught up until that season ends in March. One born January to March
/// mostly met no RSV yet: missed, it is caught up in the next autumn, until
/// the first birthday (RKI). [at] picks that second window after March.
(DateTime, DateTime) rsvWindow(DateTime birth, [DateTime? at]) {
  if (birth.month >= 4 && birth.month <= 9) {
    final autumn = DateTime(birth.year, 9, 1);
    return (
      birth.isAfter(autumn) ? birth : autumn,
      DateTime(birth.year + 1, 3, 31),
    );
  }
  final seasonEnd = DateTime(
    birth.month >= 10 ? birth.year + 1 : birth.year,
    3,
    31,
  );
  if (birth.month <= 3 && at != null && at.isAfter(seasonEnd)) {
    return (
      DateTime(birth.year, 9, 1),
      DateTime(birth.year + 1, birth.month, birth.day - 1),
    );
  }
  return (birth, seasonEnd);
}

/// [date] plus [months], on the last day of a shorter month.
DateTime _plusMonths(DateTime date, int months) {
  final month = DateTime(date.year, date.month + months);
  final length = DateTime(month.year, month.month + 1, 0).day;
  return DateTime(month.year, month.month, date.day.clamp(1, length));
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
        final birth = child.ageDate(0);
        final rule = vaccinationRules[v.id];
        DateTime? last;
        var (from, to) = v.id == 'rsv'
            ? rsvWindow(birth, day)
            : () {
                var from = switch (rule?.fromDays) {
                  final days? => DateTime(
                    birth.year,
                    birth.month,
                    birth.day + days,
                  ),
                  null => child.ageDate(v.ageMonths),
                };
                // Not before the minimum interval after the dose before,
                // once that one is recorded with its date.
                final before = rule?.after == null
                    ? null
                    : _entryFor(
                        entries,
                        ChildEntryKind.vaccination,
                        rule!.after!,
                      );
                if (before != null && !before.planned && !before.dateUnknown) {
                  final given = before.date;
                  final month = _plusMonths(
                    DateTime(given.year, given.month, given.day),
                    rule!.gapMonths,
                  );
                  final earliest = DateTime(
                    month.year,
                    month.month,
                    month.day + rule.gapDays,
                  );
                  if (earliest.isAfter(from)) from = earliest;
                }
                // Vaccinations have no fixed window; a month counts as
                // "due".
                return (from, DateTime(from.year, from.month, from.day + 31));
              }();
        if (rule?.untilDays case final days?) {
          last = DateTime(birth.year, birth.month, birth.day + days);
          if (to.isAfter(last)) to = last;
        }
        // Past the age at which it is still given (Rotavirus).
        final tooLate =
            last != null && (day.isAfter(last) || from.isAfter(last));
        final state = _stateOf(
          entry,
          () => tooLate
              ? DueState.missed
              : day.isBefore(from)
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
          tooLate: tooLate,
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
