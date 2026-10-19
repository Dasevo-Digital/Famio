import 'package:famio/src/data/departures.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const home = (52.52, 13.40);
  // About 6 km north of home.
  const doctor = Place(
    id: 'p1',
    name: 'Kinderarzt',
    latitude: 52.574,
    longitude: 13.40,
  );
  const school = Place(
    id: 'p2',
    name: 'Schule',
    latitude: 52.53,
    longitude: 13.40,
  );
  const schoolNorth = Place(
    id: 'p3',
    name: 'Schule Nord',
    latitude: 52.60,
    longitude: 13.40,
  );
  const near = Place(
    id: 'p4',
    name: 'Bäcker',
    latitude: 52.521,
    longitude: 13.40,
  );
  final places = [doctor, school, schoolNorth, near];

  CalendarEvent event(
    String location, {
    DateTime? start,
    List<String> members = const ['mama'],
    String? bringer,
    bool allDay = false,
  }) {
    final s = start ?? DateTime(2026, 10, 20, 10);
    return CalendarEvent(
      id: location,
      title: 'Termin $location',
      start: s,
      end: s.add(const Duration(hours: 1)),
      location: location,
      memberIds: members,
      bringerId: bringer,
      allDay: allDay,
    );
  }

  List<Departure> run(
    List<CalendarEvent> events, {
    TripMode mode = TripMode.car,
  }) => departures(
    events: events,
    places: places,
    memberId: 'mama',
    origin: home,
    mode: mode,
    from: DateTime(2026, 10, 20, 6),
    to: DateTime(2026, 10, 21, 6),
  );

  test('the location names a family place, with details after it', () {
    expect(placeForLocation('Kinderarzt', places), doctor);
    expect(placeForLocation('kinderarzt, 2. Stock', places), doctor);
    expect(placeForLocation('Schule Nord (Turnhalle)', places), schoolNorth);
    expect(placeForLocation('Schule', places), school);
    expect(placeForLocation('Schulweg 3', places), isNull);
    expect(placeForLocation('', places), isNull);
  });

  test('leave so as to be there five minutes early', () {
    final d = run([event('Kinderarzt')]).single;
    expect(d.place, doctor);
    // 6 km as the crow flies, a third more by road, 30 km/h by car.
    expect(d.minutes, inInclusiveRange(15, 17));
    expect(
      d.at,
      DateTime(2026, 10, 20, 10).subtract(Duration(minutes: d.minutes + 5)),
    );
    final walking = run([event('Kinderarzt')], mode: TripMode.walk).single;
    expect(walking.minutes, greaterThan(90));
  });

  test('not for lifts, all-day entries, others or a place next door', () {
    expect(run([event('Kinderarzt', bringer: 'papa')]), isEmpty);
    expect(run([event('Kinderarzt', bringer: 'mama')]), isEmpty);
    expect(run([event('Kinderarzt', allDay: true)]), isEmpty);
    expect(
      run([
        event('Kinderarzt', members: ['papa']),
      ]),
      isEmpty,
    );
    expect(run([event('Bäcker')]), isEmpty);
    expect(run([event('Irgendwo')]), isEmpty);
    // Nobody picked: everyone's appointment.
    expect(run([event('Kinderarzt', members: [])]), hasLength(1));
  });

  test('only departures inside the window', () {
    expect(
      run([event('Kinderarzt', start: DateTime(2026, 10, 20, 6, 10))]),
      isEmpty,
    );
    expect(
      run([event('Kinderarzt', start: DateTime(2026, 10, 21, 6, 10))]),
      hasLength(1),
    );
  });

  test('home is the place named so', () {
    expect(
      homePlace([
        doctor,
        const Place(id: 'h', name: 'Zuhause', latitude: 0, longitude: 0),
      ])?.id,
      'h',
    );
    expect(homePlace([doctor]), isNull);
  });
}
