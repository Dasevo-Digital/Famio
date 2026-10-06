import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';

import '../data/family_extras.dart';
import 'sos_device.dart';

/// What happened when the button was pressed, for the screen.
enum SosStep { starting, sent, offline, failed }

/// Runs one press of the emergency button on this device: siren, alarm to
/// the server (or a text without internet), the call, and the position
/// every [interval] while the alarm is open and the app runs.
class SosController extends ChangeNotifier {
  SosController(
    this.engine, {
    this.interval = const Duration(seconds: 20),
    this.serverUrl,
    this.pin,
    this.device = 'Telefon',
  });

  /// For the background service (Android).
  final String? serverUrl;
  final String? pin;
  final String device;

  /// The press running on this device, so its screen can be reopened.
  static SosController? current;

  final SyncEngine engine;
  final Duration interval;

  SosStep step = SosStep.starting;
  String? alertId;
  bool sirenOn = false;
  bool smsSent = false;
  String? callNumber;
  Timer? _live;
  DateTime? _liveUntil;
  bool _disposed = false;

  SosSettings get settings => SosSettings.fromRecord(
    engine.record(Collections.sosSettings, SosSettings.recordId),
  );

  List<FamilyMember> get adults => [
    for (final m in engine.members)
      if (m.isAdult) m,
  ];

  String get _me => engine.memberId;

  /// The button was held: everything at once, nothing waits for the
  /// network before the siren and the call.
  Future<void> trigger({bool call = true}) async {
    final s = settings;
    if (s.siren) await siren(true);
    callNumber = s.callNumber(_me, adults);
    final fix = SosDevice.currentFix(timeout: const Duration(seconds: 15));
    try {
      alertId = await engine.api.raiseSos();
      step = SosStep.sent;
      _notify();
      unawaited(_sendPosition(await fix));
      if (!await _startService()) _startLive();
    } on ApiError catch (e) {
      step = e.code == 'network' ? SosStep.offline : SosStep.failed;
      _notify();
      if (s.sms && SosDevice.canSms) {
        final position = await fix;
        smsSent = await SosDevice.sendSms(
          s.smsNumbers(_me, adults),
          smsText(engine.me?.displayName ?? 'Famio', position),
        );
        _notify();
      }
    }
    final number = callNumber;
    if (call && number != null) await SosDevice.call(number);
  }

  /// The text sent without internet.
  static String smsText(String name, SosFix? fix) {
    final where = fix == null
        ? 'Standort unbekannt.'
        : 'Standort: https://www.openstreetmap.org/?mlat='
              '${fix.latitude.toStringAsFixed(6)}&mlon='
              '${fix.longitude.toStringAsFixed(6)}';
    return 'SOS von $name (Famio): Ich brauche Hilfe! $where';
  }

  Future<void> siren(bool on) async {
    sirenOn = on;
    _notify();
    on ? await SosDevice.startSiren() : await SosDevice.stopSiren();
  }

  Future<void> _sendPosition(SosFix? fix) async {
    final id = alertId;
    if (fix == null || id == null) return;
    try {
      await engine.api.sosPosition(
        id,
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracy: fix.accuracy,
        battery: fix.battery,
      );
    } on ApiError catch (e) {
      // Over (resolved or after half an hour): stop sending.
      if (e.status == 409 || e.status == 404) stop();
    }
  }

  /// Android: positions also with the screen off, from a service.
  Future<bool> _startService() async {
    final url = serverUrl;
    final id = alertId;
    if (url == null || id == null) return false;
    try {
      return await SosDevice.startLiveService(
        serverUrl: url,
        token: await engine.api.sosDeviceToken(device),
        pin: pin,
        alertId: id,
        until: DateTime.now().add(SosAlert.live),
      );
    } on ApiError {
      return false;
    }
  }

  void _startLive() {
    _liveUntil = DateTime.now().add(SosAlert.live);
    _live?.cancel();
    _live = Timer.periodic(interval, (_) async {
      if (DateTime.now().isAfter(_liveUntil!) || !_open) {
        stop();
        return;
      }
      await _sendPosition(await SosDevice.currentFix());
    });
  }

  bool get _open {
    final id = alertId;
    if (id == null) return false;
    final r = engine.record(Collections.sosAlerts, id);
    return r == null || SosAlert.fromRecord(r).open;
  }

  /// "Ich bin sicher": ends the alarm for everyone.
  Future<void> resolve() async {
    final id = alertId;
    stop();
    if (id != null) await engine.api.sosResolve(id);
  }

  /// Stops siren and position updates on this device.
  void stop() {
    _live?.cancel();
    _live = null;
    unawaited(SosDevice.stopLiveService());
    if (sirenOn) unawaited(siren(false));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
