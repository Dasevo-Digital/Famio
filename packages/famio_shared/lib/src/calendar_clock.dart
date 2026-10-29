import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

/// Civil dates and instants in one family calendar, independent of the device.
class FamilyCalendar {
  const FamilyCalendar(this.timeZone);
  final String? timeZone;

  DateTime local(DateTime instant) =>
      timeZone == null ? instant.toLocal() : inCalendarZone(instant, timeZone);
  DateTime date(
    int year, [
    int month = 1,
    int day = 1,
    int hour = 0,
    int minute = 0,
  ]) {
    final zone = calendarLocation(timeZone);
    return zone == null
        ? DateTime(year, month, day, hour, minute)
        : tz.TZDateTime(zone, year, month, day, hour, minute);
  }

  DateTime day(DateTime civilDate) =>
      date(civilDate.year, civilDate.month, civilDate.day);
  DateTime today([DateTime? instant]) => day(local(instant ?? DateTime.now()));
  DateTime addDays(DateTime civilDate, int days) =>
      date(civilDate.year, civilDate.month, civilDate.day + days);
}

tz.Location? calendarLocation(String? name) {
  if (name == null || name.isEmpty) return null;
  if (tz.timeZoneDatabase.locations.isEmpty) data.initializeTimeZones();
  try {
    return tz.getLocation(name);
  } on Exception {
    return null;
  }
}

String? calendarZoneName(DateTime value) =>
    value is tz.TZDateTime ? value.location.name : null;

/// Creates a civil date in the calendar's zone rather than the device's zone.
DateTime calendarDate(
  DateTime reference,
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
  int millisecond = 0,
  int microsecond = 0,
]) {
  if (reference is tz.TZDateTime) {
    return tz.TZDateTime(
      reference.location,
      year,
      month,
      day,
      hour,
      minute,
      second,
      millisecond,
      microsecond,
    );
  }
  return reference.isUtc
      ? DateTime.utc(
          year,
          month,
          day,
          hour,
          minute,
          second,
          millisecond,
          microsecond,
        )
      : DateTime(
          year,
          month,
          day,
          hour,
          minute,
          second,
          millisecond,
          microsecond,
        );
}

DateTime inCalendarZone(DateTime value, String? name, {bool dateOnly = false}) {
  final location = calendarLocation(name);
  if (location == null) return value;
  return dateOnly
      ? tz.TZDateTime(location, value.year, value.month, value.day)
      : tz.TZDateTime.from(value, location);
}
