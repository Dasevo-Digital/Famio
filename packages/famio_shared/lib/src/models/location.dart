import 'dart:math';

import '../sync_record.dart';

/// A place the family cares about (home, school, grandma's …), stored in
/// `Collections.places`. Members get notified when someone arrives or
/// leaves.
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.radius = defaultRadius,
    this.notifyMemberIds = const [],
  });

  factory Place.fromRecord(SyncRecord r) => Place(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    latitude: (r.data['latitude'] as num?)?.toDouble() ?? 0,
    longitude: (r.data['longitude'] as num?)?.toDouble() ?? 0,
    radius: ((r.data['radius'] as num?)?.toDouble() ?? defaultRadius).clamp(
      minRadius,
      maxRadius,
    ),
    notifyMemberIds: [
      for (final m in r.data['notifyMemberIds'] as List? ?? const [])
        m as String,
    ],
  );

  static const defaultRadius = 150.0;
  static const minRadius = 50.0;
  static const maxRadius = 2000.0;

  final String id;
  final String name;
  final double latitude;
  final double longitude;

  /// Meters around the center that count as "here".
  final double radius;

  /// Members who want a notification when someone arrives or leaves.
  final List<String> notifyMemberIds;

  Place copyWith({
    String? name,
    double? latitude,
    double? longitude,
    double? radius,
    List<String>? notifyMemberIds,
  }) => Place(
    id: id,
    name: name ?? this.name,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    radius: radius ?? this.radius,
    notifyMemberIds: notifyMemberIds ?? this.notifyMemberIds,
  );

  Map<String, Object?> toData() => {
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    'radius': radius,
    'notifyMemberIds': notifyMemberIds,
  };
}

/// Whether a member's device currently shares its location.
enum SharingState {
  /// Positions arrive regularly.
  active,

  /// Paused with the parents' code, see [MemberLocation.pausedUntil].
  paused,

  /// The app lacks the location permission on the device.
  denied,

  /// Location (GPS) is switched off on the device.
  off,
}

/// Last known position and sharing status of a member, stored by the
/// server in `Collections.memberLocations` (record id = member id).
class MemberLocation {
  const MemberLocation({
    required this.memberId,
    required this.state,
    this.latitude,
    this.longitude,
    this.accuracy,
    this.at,
    this.lastContact,
    this.pausedUntil,
    this.placeId,
    this.placeSince,
    this.battery,
    this.device,
    this.platform,
  });

  factory MemberLocation.fromRecord(SyncRecord r) => MemberLocation(
    memberId: r.id,
    state:
        SharingState.values
            .where((s) => s.name == r.data['state'])
            .firstOrNull ??
        SharingState.active,
    latitude: (r.data['latitude'] as num?)?.toDouble(),
    longitude: (r.data['longitude'] as num?)?.toDouble(),
    accuracy: (r.data['accuracy'] as num?)?.toDouble(),
    at: _time(r.data['at']),
    lastContact: _time(r.data['lastContact']),
    pausedUntil: _time(r.data['pausedUntil']),
    placeId: r.data['placeId'] as String?,
    placeSince: _time(r.data['placeSince']),
    battery: r.data['battery'] as int?,
    device: r.data['device'] as String?,
    platform: r.data['platform'] as String?,
  );

  final String memberId;
  final SharingState state;
  final double? latitude;
  final double? longitude;

  /// Radius of uncertainty in meters.
  final double? accuracy;

  /// When the position was measured.
  final DateTime? at;

  /// When the device last reported (also while paused or without a fix).
  final DateTime? lastContact;

  /// End of a pause; null while paused means until resumed by hand.
  final DateTime? pausedUntil;

  /// The [Place] the member is at, if any, and since when.
  final String? placeId;
  final DateTime? placeSince;

  /// Battery level of the device in percent.
  final int? battery;
  final String? device;

  /// `android` or `ios`. iPhones only report when moving, so a long silence
  /// is normal there.
  final String? platform;

  bool get hasPosition => latitude != null && longitude != null;

  Map<String, Object?> toData() => {
    'state': state.name,
    'latitude': ?latitude,
    'longitude': ?longitude,
    'accuracy': ?accuracy,
    'at': ?_iso(at),
    'lastContact': ?_iso(lastContact),
    'pausedUntil': ?_iso(pausedUntil),
    'placeId': ?placeId,
    'placeSince': ?_iso(placeSince),
    'battery': ?battery,
    'device': ?device,
    'platform': ?platform,
  };
}

/// "Someone arrived at / left a place", written by the server into
/// `Collections.locationAlerts` for each member who asked to be notified.
class LocationAlert {
  const LocationAlert({
    required this.id,
    required this.memberId,
    required this.placeId,
    required this.placeName,
    required this.arrived,
    required this.at,
  });

  factory LocationAlert.fromRecord(SyncRecord r) => LocationAlert(
    id: r.id,
    memberId: r.data['memberId'] as String? ?? '',
    placeId: r.data['placeId'] as String? ?? '',
    placeName: r.data['placeName'] as String? ?? '',
    arrived: r.data['arrived'] as bool? ?? true,
    at: _time(r.data['at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
  );

  final String id;

  /// Who arrived or left.
  final String memberId;
  final String placeId;
  final String placeName;
  final bool arrived;
  final DateTime at;

  String text(String memberName) => arrived
      ? '$memberName ist bei „$placeName“ angekommen'
      : '$memberName hat „$placeName“ verlassen';

  Map<String, Object?> toData() => {
    'memberId': memberId,
    'placeId': placeId,
    'placeName': placeName,
    'arrived': arrived,
    'at': _iso(at),
  };
}

/// One position measured by a device.
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.at,
    this.accuracy,
    this.battery,
  });

  factory LocationFix.fromJson(Map<String, Object?> json) => LocationFix(
    latitude: (json['lat'] as num).toDouble(),
    longitude: (json['lon'] as num).toDouble(),
    accuracy: (json['acc'] as num?)?.toDouble(),
    at: DateTime.fromMillisecondsSinceEpoch(
      (json['at'] as num).toInt(),
      isUtc: true,
    ),
    battery: (json['battery'] as num?)?.toInt(),
  );

  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime at;
  final int? battery;

  bool get valid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180 &&
      (accuracy == null || accuracy! >= 0);

  Map<String, Object?> toJson() => {
    'lat': latitude,
    'lon': longitude,
    'acc': ?accuracy,
    'at': at.millisecondsSinceEpoch,
    'battery': ?battery,
  };
}

/// Great-circle distance in meters (haversine).
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const earth = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  return 2 * earth * asin(min(1, sqrt(a)));
}

DateTime? _time(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toLocal() : null;

String? _iso(DateTime? t) => t?.toUtc().toIso8601String();
