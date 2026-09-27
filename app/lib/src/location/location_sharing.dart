import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Permission level for location on this device.
enum LocationPermission {
  none,

  /// Only while the app is used; sharing survives closing the app but not
  /// a restart of the phone.
  foreground,
  always,
}

/// What the device allows and does for location sharing.
class DeviceSharingStatus {
  const DeviceSharingStatus({
    this.enabled = false,
    this.permission = LocationPermission.none,
    this.precise = false,
    this.locationOn = true,
    this.batteryUnrestricted = true,
    this.notifications = true,
  });

  factory DeviceSharingStatus.fromMap(Map<Object?, Object?> map) =>
      DeviceSharingStatus(
        enabled: map['enabled'] as bool? ?? false,
        permission: LocationPermission.values.firstWhere(
          (p) => p.name == map['permission'],
          orElse: () => LocationPermission.none,
        ),
        precise: map['precise'] as bool? ?? false,
        locationOn: map['locationOn'] as bool? ?? true,
        batteryUnrestricted: map['batteryUnrestricted'] as bool? ?? true,
        notifications: map['notifications'] as bool? ?? true,
      );

  /// Sharing is switched on on this device.
  final bool enabled;
  final LocationPermission permission;
  final bool precise;

  /// Location (GPS) is switched on in the phone's quick settings.
  final bool locationOn;

  /// Exempt from battery optimisation; otherwise some phones stop sharing.
  final bool batteryUnrestricted;
  final bool notifications;
}

/// Location sharing of this phone. The positions are measured and sent by a
/// native service (Android: `LocationService.kt`, iOS: `LocationReporter`
/// in `AppDelegate.swift`), so sharing continues with the app closed; the
/// desktop apps only show the family's positions.
class LocationSharing {
  LocationSharing._();

  static const _channel = MethodChannel('famio/location');

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<DeviceSharingStatus> status() async {
    if (!supported) return const DeviceSharingStatus();
    final map = await _channel.invokeMapMethod<Object?, Object?>('status');
    return DeviceSharingStatus.fromMap(map ?? const {});
  }

  /// Asks for location access; with [background] for "all the time".
  static Future<DeviceSharingStatus> requestPermission({
    bool background = false,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'requestPermission',
      {'background': background},
    );
    return DeviceSharingStatus.fromMap(map ?? const {});
  }

  /// Starts sharing: the phone gets its own token that can only report
  /// positions, and sharing is resumed on the server.
  static Future<void> enable({
    required FamioApiClient api,
    required String serverUrl,
    required String? certificatePin,
    required String device,
  }) async {
    final token = await api.locationDeviceToken(device);
    await api.resumeLocation();
    await _channel.invokeMethod('start', {
      'url': serverUrl,
      'token': token,
      'pin': certificatePin,
      'device': device,
    });
  }

  /// Makes sure a switched-on service runs with the current server address
  /// (e.g. after switching to HTTPS).
  static Future<void> refresh({
    required String serverUrl,
    required String? certificatePin,
    required String device,
  }) async {
    if (!supported) return;
    final token = await _channel.invokeMethod<String>('token');
    if (token == null) return;
    await _channel.invokeMethod('start', {
      'url': serverUrl,
      'token': token,
      'pin': certificatePin,
      'device': device,
    });
  }

  /// Stops sharing on this device and signs its token out.
  static Future<void> disable({FamioApiClient? api}) async {
    if (!supported) return;
    final token = await _channel.invokeMethod<String>('token');
    await _channel.invokeMethod('stop');
    if (token != null && api != null) {
      try {
        await FamioApiClient(
          api.baseUrl.toString(),
          token: token,
          pinnedCertificate: api.pinnedCertificate,
        ).logout();
      } on ApiError {
        // Offline: the token expires unused after 90 days.
      }
    }
  }

  static Future<void> openBatterySettings() =>
      _channel.invokeMethod('openBatterySettings');

  static Future<void> openAppSettings() =>
      _channel.invokeMethod('openAppSettings');
}
