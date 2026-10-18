import '../sync_record.dart';

/// How someone is on the way; sets the speed of the estimate.
enum TripMode {
  walk(4.5),
  bike(15),
  car(30),
  transit(18);

  const TripMode(this.kmh);

  /// Average speed in town, stops and lights included.
  final double kmh;

  static TripMode parse(Object? v) =>
      values.where((m) => m.name == v).firstOrNull ?? car;
}

/// "Bin unterwegs": [memberId] is heading for a family place and arrives
/// about [eta]. Stored in `Collections.trips` with the member's id, so a
/// new trip replaces the last; the server removes it on arrival.
class Trip {
  const Trip({
    required this.memberId,
    required this.placeId,
    required this.placeName,
    required this.eta,
    required this.startedAt,
    this.mode = TripMode.car,
  });

  factory Trip.fromRecord(SyncRecord r) => Trip(
    memberId: r.id,
    placeId: r.data['placeId'] as String? ?? '',
    placeName: r.data['placeName'] as String? ?? '',
    eta:
        DateTime.tryParse(r.data['eta'] as String? ?? '')?.toLocal() ??
        DateTime(2000),
    startedAt:
        DateTime.tryParse(r.data['startedAt'] as String? ?? '')?.toLocal() ??
        DateTime(2000),
    mode: TripMode.parse(r.data['mode']),
  );

  final String memberId;
  final String placeId;
  final String placeName;
  final DateTime eta;
  final DateTime startedAt;
  final TripMode mode;

  /// Shown until an hour after the expected arrival, in case the arrival
  /// itself was not noticed (no location shared).
  bool activeAt(DateTime now) =>
      now.isBefore(eta.add(const Duration(hours: 1)));

  /// Time for [meters] as the crow flies: roads are about a third longer.
  static Duration estimate(double meters, TripMode mode) => Duration(
    minutes: (meters * 1.3 / 1000 / mode.kmh * 60).ceil().clamp(1, 24 * 60),
  );

  Map<String, Object?> toData() => {
    'placeId': placeId,
    'placeName': placeName,
    'eta': eta.toUtc().toIso8601String(),
    'startedAt': startedAt.toUtc().toIso8601String(),
    'mode': mode.name,
  };
}
