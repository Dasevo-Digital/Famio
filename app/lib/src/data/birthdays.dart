import 'package:famio_client/famio_client.dart';

import 'family_data.dart';

enum BirthdayOf { member, child, contact }

/// Someone's birthday in the family's view.
class FamilyBirthday {
  const FamilyBirthday({
    required this.of,
    required this.id,
    required this.name,
    required this.birthday,
    this.color,
  });

  final BirthdayOf of;
  final String id;
  final String name;
  final Birthday birthday;
  final int? color;

  /// Source id of the calendar entry.
  String get sourceId => 'birthday:${of.name}:$id';

  /// The next birthday on or after [from].
  DateTime next(DateTime from) => birthday.next(from);

  /// "Oma Inge wird 70" or "Oma Inge hat Geburtstag".
  String headline(DateTime on) {
    final age = birthday.ageOn(on);
    return age == null || age <= 0 ? '$name hat Geburtstag' : '$name wird $age';
  }
}

/// Birthdays of members, children (only those this member may see) and
/// contacts.
List<FamilyBirthday> familyBirthdays(SyncEngine engine) => [
  for (final m in engine.members)
    if (m.birthday case final b?)
      FamilyBirthday(
        of: BirthdayOf.member,
        id: m.id,
        name: m.displayName,
        birthday: b,
        color: m.color,
      ),
  for (final c in engine.children)
    FamilyBirthday(
      of: BirthdayOf.child,
      id: c.id,
      name: c.name,
      birthday: Birthday.ofDate(c.birthDate),
      color: c.color,
    ),
  for (final c in engine.contacts)
    if (c.birthday case final b?)
      FamilyBirthday(
        of: BirthdayOf.contact,
        id: c.id,
        name: c.name,
        birthday: b,
      ),
];

/// Birthdays from [from] within [days], soonest first.
List<(FamilyBirthday, DateTime)> upcomingBirthdays(
  SyncEngine engine,
  DateTime from, {
  int days = 30,
}) {
  final today = DateTime(from.year, from.month, from.day);
  final end = today.add(Duration(days: days));
  return [
    for (final b in familyBirthdays(engine))
      if (b.next(today) case final d when d.isBefore(end)) (b, d),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
}

bool isBirthdaySource(String? sourceId) =>
    sourceId?.startsWith('birthday:') ?? false;

/// Birthdays as yearly all-day calendar entries (read-only).
List<CalendarEvent> birthdayEvents(SyncEngine engine) => [
  for (final b in familyBirthdays(engine))
    () {
      // Series start in the birth year when known, else in 2000.
      final first = b.birthday.inYear(b.birthday.year ?? 2000);
      return CalendarEvent(
        id: b.sourceId,
        title: '🎂 ${b.name}',
        start: first,
        end: first.add(const Duration(days: 1)),
        allDay: true,
        recurrence: const Recurrence(RecurrenceFrequency.yearly),
        sourceId: b.sourceId,
        notes: b.birthday.year == null ? '' : 'Geboren ${b.birthday.year}',
      );
    }(),
];

extension BirthdayOccurrences on SyncEngine {
  /// Birthday of the entry behind a calendar [sourceId].
  FamilyBirthday? birthdayOf(String? sourceId) =>
      familyBirthdays(this).where((b) => b.sourceId == sourceId).firstOrNull;
}
