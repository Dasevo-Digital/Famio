import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('the estimate adds a third for roads and rounds up', () {
    // 6.5 km as the crow flies: 8.45 km of road.
    expect(Trip.estimate(6500, TripMode.bike), const Duration(minutes: 34));
    expect(Trip.estimate(6500, TripMode.walk), const Duration(minutes: 113));
    expect(Trip.estimate(10, TripMode.car), const Duration(minutes: 1));
  });

  test('a trip shows until an hour after the expected arrival', () {
    final trip = Trip(
      memberId: 'papa',
      placeId: 'home',
      placeName: 'Zuhause',
      eta: DateTime(2026, 10, 18, 18, 40),
      startedAt: DateTime(2026, 10, 18, 18, 10),
    );
    expect(trip.activeAt(DateTime(2026, 10, 18, 19, 39)), isTrue);
    expect(trip.activeAt(DateTime(2026, 10, 18, 19, 41)), isFalse);
  });
}
