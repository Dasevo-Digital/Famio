import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n.dart';

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
/// on Android (all of it) and iOS (position, siren while open, call, a
/// prepared text the person sends); desktops only open the phone app for a
/// call.
class SosDevice {
  static const _channel = MethodChannel('famio/sos');

  static bool get _native => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Called when the quick settings tile or the shortcut opens the
  /// running app (Android).
  static void Function()? onLaunch;

  static bool _listening = false;

  /// Whether the app was opened from the tile or the shortcut (once).
  static Future<bool> takeLaunch() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'launch' && await takeLaunch()) onLaunch?.call();
      });
    }
    try {
      return await _channel.invokeMethod<bool>('takeLaunch') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Phones text without internet: Android on its own, an iPhone opens
  /// the prepared text and the person taps "Send" (iOS lets no app text by
  /// itself). By the target platform, which tests can set.
  static bool get canSms =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Whether the text still needs a tap on "Send" (iPhone, iPad).
  static bool get smsNeedsTap =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// The position service exists on Android only (by the target platform,
  /// which tests can set).
  static bool get _androidService =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
      debugPrint(tr.sosSosPositionNotAvailable(e));
      return null;
    }
  }

  /// A loud, rising and falling tone at full alarm volume, until [stopSiren].
  static Future<void> startSiren() async {
    if (!_native) return;
    try {
      await _channel.invokeMethod('startSiren', {'wav': sirenWav()});
    } catch (e) {
      debugPrint(tr.sosSirenNotAvailableError(e));
    }
  }

  static Future<void> stopSiren() async {
    if (!_native) return;
    try {
      await _channel.invokeMethod('stopSiren');
    } catch (_) {}
  }

  /// Android: a background service sends the position of alert [alertId]
  /// until [until], also with the screen off (see SosLocationService).
  /// False where there is none; then the app sends while it runs.
  static Future<bool> startLiveService({
    required String serverUrl,
    required String token,
    required String? pin,
    required String alertId,
    required DateTime until,
  }) async {
    if (!_androidService) return false;
    try {
      return await _channel.invokeMethod<bool>('startLive', {
            'url': serverUrl.endsWith('/') ? serverUrl : '$serverUrl/',
            'token': token,
            'pin': pin,
            'alert': alertId,
            'until': until.millisecondsSinceEpoch,
          }) ??
          false;
    } catch (e) {
      debugPrint(tr.sosEmergencyLocationServiceNot(e));
      return false;
    }
  }

  static Future<void> stopLiveService() async {
    if (!_androidService) return;
    try {
      await _channel.invokeMethod('stopLive');
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

  /// Texts [text] to [numbers]: Android sends it, an iPhone shows it ready
  /// to send and answers once the person sent or cancelled it. False if it
  /// was not sent (no SIM, cancelled, not possible).
  static Future<bool> sendSms(List<String> numbers, String text) async {
    if (!canSms || numbers.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>(
            smsNeedsTap ? 'composeSms' : 'sendSms',
            {
              'numbers': [
                for (final n in numbers) n.replaceAll(RegExp(r'[^0-9+]'), ''),
              ],
              'text': text,
            },
          ) ??
          false;
    } catch (e) {
      debugPrint(tr.sosTextMessageNotPossible(e));
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
