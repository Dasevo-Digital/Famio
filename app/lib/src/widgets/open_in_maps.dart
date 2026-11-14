import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// The link that opens a position in the device's map app: Apple Maps on
/// iPhone, iPad and Mac (they have no app for `geo:`, #499), `geo:` on
/// Android, where the family picks the map app, otherwise OpenStreetMap.
Uri mapUri(double latitude, double longitude, {TargetPlatform? platform}) {
  final at = '${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
  return switch (kIsWeb ? null : platform ?? defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => Uri.https(
      'maps.apple.com',
      '/',
      {'ll': at, 'q': at},
    ),
    TargetPlatform.android => Uri.parse('geo:$at?q=$at'),
    _ => osmUri(latitude, longitude),
  };
}

/// The position on openstreetmap.org, which every browser opens.
Uri osmUri(double latitude, double longitude) {
  final lat = latitude.toStringAsFixed(6);
  final lon = longitude.toStringAsFixed(6);
  return Uri.parse(
    'https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=17/$lat/$lon',
  );
}

/// Opens the position in a map app, or else in the browser.
Future<void> openInMaps(
  double latitude,
  double longitude, {
  Future<bool> Function(Uri url, {LaunchMode mode}) launch = launchUrl,
}) async {
  var opened = false;
  try {
    opened = await launch(
      mapUri(latitude, longitude),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // No app for the link: the browser below.
  }
  if (!opened) {
    await launch(
      osmUri(latitude, longitude),
      mode: LaunchMode.externalApplication,
    );
  }
}
