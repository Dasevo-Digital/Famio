import 'dart:convert';

import 'package:cryptography/dart.dart';
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

/// The zone [name], if this process knows its rules. Servers load the whole
/// zone database; apps only know the family's zone, whose rules the server
/// sends with the sync ([calendarZoneRules]), so they need not bundle it.
tz.Location? calendarLocation(String? name) {
  if (name == null || name.isEmpty) return null;
  try {
    return tz.getLocation(name);
  } on Exception {
    return null;
  }
}

/// [zone]'s transitions as JSON. The `key` changes with the rules: another
/// zone, or a server with newer zone data.
Map<String, Object?> calendarZoneRules(tz.Location zone) {
  final rules = <String, Object?>{
    'name': zone.name,
    'at': zone.transitionAt,
    'zone': zone.transitionZone,
    'zones': [
      for (final z in zone.zones)
        [z.offset.inMilliseconds, z.isDst, z.abbreviation],
    ],
  };
  final digest = const DartSha256().hashSync(utf8.encode(jsonEncode(rules)));
  return {...rules, 'key': base64UrlEncode(digest.bytes.sublist(0, 12))};
}

/// Makes rules from [calendarZoneRules] known to [calendarLocation]. Returns
/// false and changes nothing if they are malformed.
bool registerCalendarZone(Map<String, Object?> rules) {
  try {
    final zones = [
      for (final z in rules['zones'] as List)
        tz.TimeZone(
          Duration(milliseconds: (z as List)[0] as int),
          isDst: z[1] as bool,
          abbreviation: z[2] as String,
        ),
    ];
    final at = [for (final t in rules['at'] as List) t as int];
    final index = [for (final i in rules['zone'] as List) i as int];
    if (zones.isEmpty ||
        at.length != index.length ||
        index.any((i) => i < 0 || i >= zones.length)) {
      return false;
    }
    tz.timeZoneDatabase.add(
      tz.Location(rules['name'] as String, at, index, zones),
    );
    return true;
  } on TypeError {
    return false;
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
