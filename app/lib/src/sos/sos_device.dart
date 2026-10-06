import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Tag of a notice that lets this phone ring (see the server's
/// `SosService.ringTag`).
const ringTag = 'loud_sound';

/// A position for the emergency button.
class SosFix {
  const SosFix({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.battery,
  });

  final double latitude;
  final double longitude;
  final double? accuracy;
  final int? battery;
}

/// What the phone does when the emergency button is pressed: measure the
/// position once, sound a siren (also on silent), call and text. Natively
/// on Android (all of it) and iOS (position, siren while open, call);
/// desktops only open the phone app for a call.
class SosDevice {
  static const _channel = MethodChannel('famio/sos');

  static bool get _native => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Android can text without asking each time.
  static bool get canSms => !kIsWeb && Platform.isAndroid;

  /// A fresh position, or null without permission, signal or support.
  static Future<SosFix?> currentFix({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!_native) return null;
    try {
      final map = await _channel
          .invokeMapMethod<String, Object?>('currentFix', {
            'timeoutMs': timeout.inMilliseconds,
          })
          .timeout(timeout + const Duration(seconds: 5));
      if (map == null || map['latitude'] == null) return null;
      return SosFix(
        latitude: (map['latitude']! as num).toDouble(),
        longitude: (map['longitude']! as num).toDouble(),
        accuracy: (map['accuracy'] as num?)?.toDouble(),
        battery: (map['battery'] as num?)?.toInt(),
      );
    } catch (e) {
      debugPrint('SOS-Position nicht verfügbar: $e');
      return null;
    }
  }

  /// A loud, rising and falling tone at full alarm volume, until [stopSiren].
  static Future<void> startSiren() async {
    if (!_native) return;
    try {
      await _channel.invokeMethod('startSiren', {'wav': sirenWav()});
    } catch (e) {
      debugPrint('Sirene nicht verfügbar: $e');
    }
  }

  static Future<void> stopSiren() async {
    if (!_native) return;
    try {
      await _channel.invokeMethod('stopSiren');
    } catch (_) {}
  }

  /// Calls [number] right away (Android, after a one-time permission) or
  /// opens the phone app with it.
  static Future<void> call(String number) async {
    final clean = number.replaceAll(RegExp(r'[^0-9+*#]'), '');
    if (clean.isEmpty) return;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final ok = await _channel.invokeMethod<bool>('call', {'number': clean});
        if (ok ?? false) return;
      } catch (_) {}
    }
    await launchUrl(Uri(scheme: 'tel', path: clean));
  }

  /// Texts [text] to [numbers] (Android); false if that was not possible.
  static Future<bool> sendSms(List<String> numbers, String text) async {
    if (!canSms || numbers.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('sendSms', {
            'numbers': [
              for (final n in numbers) n.replaceAll(RegExp(r'[^0-9+]'), ''),
            ],
            'text': text,
          }) ??
          false;
    } catch (e) {
      debugPrint('SMS nicht möglich: $e');
      return false;
    }
  }

  /// A one-second siren sweep (WAV, 16-bit mono) the phone plays in a loop.
  @visibleForTesting
  static Uint8List sirenWav({int sampleRate = 22050}) {
    final samples = sampleRate;
    final data = ByteData(44 + samples * 2);
    void text(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    text(0, 'RIFF');
    data.setUint32(4, 36 + samples * 2, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    text(36, 'data');
    data.setUint32(40, samples * 2, Endian.little);
    var phase = 0.0;
    for (var i = 0; i < samples; i++) {
      final t = i / samples;
      // Up from 700 to 1600 Hz and back down: hard to ignore.
      final frequency = 700 + 900 * (t < 0.5 ? t * 2 : (1 - t) * 2);
      phase += 2 * pi * frequency / sampleRate;
      // A square-ish wave sounds louder than a sine on small speakers.
      final value = (sin(phase) >= 0 ? 1 : -1) * 0.9 * 32767;
      data.setInt16(44 + i * 2, value.round(), Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
