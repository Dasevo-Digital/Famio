import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('famio/scan');

/// Phones scan letters and forms (Android: Google's document scanner from
/// Play services, iOS: Apple's document camera).
bool get canScanDocuments => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// The scanned pages as one PDF; null if the person cancelled. Throws a
/// [PlatformException] if the scanner is not available on this phone.
Future<Uint8List?> scanDocument() => _channel.invokeMethod<Uint8List>('scan');
