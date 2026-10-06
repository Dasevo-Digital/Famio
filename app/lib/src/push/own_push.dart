import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What this device does with Famio's own push.
class OwnPushStatus {
  const OwnPushStatus({
    required this.enabled,
    required this.details,
    this.notifications = true,
    this.batteryUnrestricted = true,
  });

  final bool enabled;

  /// Show names and texts (else only e.g. "Neue Nachricht").
  final bool details;

  /// Android: allowed to show notifications at all.
  final bool notifications;

  /// Android: exempt from battery optimisation, so the connection holds.
  final bool batteryUnrestricted;
}

/// Famio's own push notifications – no ntfy, no Google: the device keeps a
/// request to the family's server open, which answers as soon as something
/// happens (see the server's `NoticeBox`).
///
/// * Android: a native background service (`NotifyService.kt`) with its own
///   token, also while the app is closed.
/// * macOS, Windows, Linux (and iOS while open): a loop in the running
///   app; notices are shown when the app is not in front.
class OwnPush {
  OwnPush(this._prefs, {required this.show});

  final SharedPreferences _prefs;

  /// Shows a notice as a system notification.
  final Future<void> Function(Notice notice, {required bool details}) show;

  static const _channel = MethodChannel('famio/notify');

  static bool get native => !kIsWeb && Platform.isAndroid;

  static const _enabledKey = 'ownPush.enabled';
  static const _detailsKey = 'ownPush.details';

  /// On desktops it costs nothing noticeable, so it is on by default; on
  /// phones it needs a background connection and is switched on by hand.
  bool get _enabled => _prefs.getBool(_enabledKey) ?? !native;
  bool get _details => _prefs.getBool(_detailsKey) ?? true;

  /// True while this device receives own push (then the app's older
  /// in-app chat and place notifications stay quiet).
  bool get active => _enabled;

  FamioApiClient? _api;
  String? _serverUrl;
  String? _pin;
  String _device = 'Gerät';
  var _generation = 0;

  Future<OwnPushStatus> status() async {
    if (!native) return OwnPushStatus(enabled: _enabled, details: _details);
    final map =
        await _channel.invokeMapMethod<Object?, Object?>('status') ?? const {};
    return OwnPushStatus(
      enabled: map['enabled'] as bool? ?? false,
      details: _details,
      notifications: map['notifications'] as bool? ?? true,
      batteryUnrestricted: map['batteryUnrestricted'] as bool? ?? true,
    );
  }

  /// A session started (or the server address changed).
  Future<void> attach(
    FamioApiClient api, {
    required String serverUrl,
    required String? pin,
    required String device,
  }) async {
    _api = api;
    _serverUrl = serverUrl;
    _pin = pin;
    _device = device;
    if (!_enabled) return;
    if (native) {
      // Keep the running service on the current address and settings.
      final token = await _channel.invokeMethod<String>('token');
      if (token != null) await _startNative(token);
    } else {
      _loop();
    }
  }

  /// Signed out: stop, and sign the phone's own token out as well.
  Future<void> detach() async {
    _generation++;
    final api = _api;
    _api = null;
    if (native) await _stopNative(api);
  }

  Future<void> setEnabled(bool value) async {
    await _prefs.setBool(_enabledKey, value);
    final api = _api;
    if (api == null) return;
    if (native) {
      if (value) {
        await _channel.invokeMethod('requestPermission');
        await _startNative(await api.noticeDeviceToken(_device));
      } else {
        await _stopNative(api);
      }
    } else {
      value ? _loop() : _generation++;
    }
  }

  Future<void> setDetails(bool value) async {
    await _prefs.setBool(_detailsKey, value);
    if (native && _enabled) {
      final token = await _channel.invokeMethod<String>('token');
      if (token != null) await _startNative(token);
    }
  }

  Future<void> _startNative(String token) => _channel.invokeMethod('start', {
    'url': _serverUrl,
    'token': token,
    'pin': _pin,
    'details': _details,
  });

  Future<void> _stopNative(FamioApiClient? api) async {
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

  /// Desktop: fetch while the app runs; a new generation ends older loops.
  Future<void> _loop() async {
    final generation = ++_generation;
    bool current() => generation == _generation && _api != null;
    int? last;
    var delay = const Duration(seconds: 2);
    while (current()) {
      final api = _api!;
      try {
        final batch = last == null
            ? await api.notices()
            : await api.notices(after: last, wait: const Duration(minutes: 4));
        if (!current()) return;
        // In front, the family sees it in the app anyway.
        final inFront =
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        if (last != null) {
          for (final notice in batch.notices.take(5)) {
            // The test message always shows: it is asked for in the app;
            // alarms and rings too.
            if (!inFront || notice.tag == 'tada' || notice.alarm) {
              await show(notice, details: _details);
            }
          }
        }
        last = batch.last;
        delay = const Duration(seconds: 2);
      } on ApiError catch (e) {
        if (e.isUnauthorized) return;
        await Future<void>.delayed(delay);
        delay = Duration(seconds: (delay.inSeconds * 2).clamp(2, 120));
      }
    }
  }

  /// Asks the server to send a test notification to this member.
  Future<void> test() async => _api?.testNotice();
}
