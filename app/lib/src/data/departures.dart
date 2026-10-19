import 'package:famio_client/famio_client.dart';

/// When to leave for an appointment at a family place.
typedef Departure = ({
  Occurrence occurrence,
  Place place,
  DateTime at,
  int minutes,
});

/// The family place an appointment's [location] names: the place's name
/// alone, or followed by details ("Kinderarzt, 2. Stock"). Longer names
/// win ("Schule Nord" before "Schule").
Place? placeForLocation(String location, Iterable<Place> places) {
  final text = location.trim().toLowerCase();
  if (text.isEmpty) return null;
  final byLength = places.toList()
    ..sort((a, b) => b.name.length.compareTo(a.name.length));
  for (final p in byLength) {
    final name = p.name.trim().toLowerCase();
    if (name.isEmpty) continue;
    if (text == name ||
        text.startsWith('$name,') ||
        text.startsWith('$name ') ||
        text.startsWith('$name(')) {
      return p;
    }
  }
  return null;
}

/// "Rechtzeitig losfahren": for appointments of [memberId] at a family
/// place, when to leave [origin] with [mode] to arrive [buffer] before the
/// start. Estimated like "Bin unterwegs" (as the crow flies plus a third
/// for roads), without a routing service. Not for all-day entries, not
/// when already there (under 500 m), and not for lifts (see
/// `CalendarEvent.bringerId`).
List<Departure> departures({
  required Iterable<CalendarEvent> events,
  required Iterable<Place> places,
  required String memberId,
  required (double, double) origin,
  required TripMode mode,
  required DateTime from,
  required DateTime to,
  Duration buffer = const Duration(minutes: 5),
}) {
  final result = <Departure>[];
  for (final event in events) {
    // With someone bringing, the one who brings has the lift reminder and
    // the others are driven.
    if (event.allDay || event.bringerId != null) continue;
    if (!event.involves(memberId)) continue;
    final place = placeForLocation(event.location, places);
    if (place == null) continue;
    final meters = distanceMeters(
      origin.$1,
      origin.$2,
      place.latitude,
      place.longitude,
    );
    if (meters < 500) continue;
    final travel = Trip.estimate(meters, mode);
    final lead = travel + buffer;
    // Starts just after the window count when the way begins inside it.
    for (final o in event.occurrencesBetween(from, to.add(lead))) {
      final at = o.start.subtract(lead);
      if (at.isBefore(from) || !at.isBefore(to)) continue;
      result.add((
        occurrence: o,
        place: place,
        at: at,
        minutes: travel.inMinutes,
      ));
    }
  }
  result.sort((a, b) => a.at.compareTo(b.at));
  return result;
}

/// The family's home among [places] ("Zuhause", "Home" …), if named so.
Place? homePlace(Iterable<Place> places) => places
    .where(
      (p) => RegExp(
        r'zuhause|zu hause|home|daheim|casa|hogar',
        caseSensitive: false,
      ).hasMatch(p.name),
    )
    .firstOrNull;

extension TripModeEmoji on TripMode {
  String get emoji => switch (this) {
    TripMode.walk => '🚶',
    TripMode.bike => '🚲',
    TripMode.car => '🚗',
    TripMode.transit => '🚌',
  };
}
