import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/app_icons.dart';
import '../l10n.dart';

/// What the device offers to prove it is its owner: fingerprint, face or
/// its own PIN. Famio keeps no second PIN.
abstract interface class DeviceUnlock {
  Future<bool> get available;

  Future<bool> unlock(String reason);
}

class SystemUnlock implements DeviceUnlock {
  const SystemUnlock();

  /// Phones, tablets and Macs; not Windows, Linux and browsers.
  static bool get _supported =>
      !kIsWeb &&
      const {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);

  static LocalAuthPlatform get _auth => LocalAuthPlatform.instance;

  @override
  Future<bool> get available async {
    if (!_supported) return false;
    try {
      return await _auth.isDeviceSupported();
    } on Exception {
      return false;
    }
  }

  @override
  Future<bool> unlock(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        authMessages: const [AndroidAuthMessages(), IOSAuthMessages()],
        options: const AuthenticationOptions(useErrorDialogs: false),
      );
    } on Exception catch (e) {
      // Nothing set up (any more), or too many attempts.
      debugPrint('Famio: unlock failed: $e');
      return false;
    }
  }
}

/// Optional lock of this device's app: after [delay] away it asks for the
/// device's own unlock, and while locked or in the background it hides what
/// is on screen. For phones the family shares; the data is encrypted either
/// way. The settings stay on the device.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock(
    this._prefs, {
    this._device = const SystemUnlock(),
    DateTime Function()? now,
    TargetPlatform? platform,
  }) : _now = now ?? DateTime.now,
       _platform = platform ?? defaultTargetPlatform {
    locked = enabled;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_applySecure());
    if (_platform == TargetPlatform.iOS && !kIsWeb) {
      _privacy.setMethodCallHandler((call) async {
        if (call.method != 'cameBack') return null;
        final away = (call.arguments as Map?)?['awayMs'] as int? ?? 0;
        return _cameBack(Duration(milliseconds: away));
      });
    }
  }

  static const _key = 'appLock.enabled';
  static const _delayKey = 'appLock.delay';

  /// How long Famio may be in the background before it asks again.
  static const delays = [
    Duration.zero,
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];

  /// Until somebody chooses: a quick look at another app needs no unlock.
  static const defaultDelay = Duration(minutes: 1);

  /// Famio's own trips to the camera, a file picker, the scanner or the share
  /// sheet count as away only after this long, even with no [delay]: else
  /// "at once" would ask after every photo.
  static const pickerDelay = Duration(minutes: 1);

  /// A trip of [picking] counts for at most this long after it began: a
  /// picker that never answers (closed without telling Famio) must not keep
  /// "at once" at a minute for good (#568).
  static const pickerLimit = Duration(minutes: 10);

  /// The trips of [picking] under way, with when each began.
  static final _picks = <Object, DateTime>{};

  /// Whether a trip of [picking] is under way, and not older than
  /// [pickerLimit].
  static bool get _picking {
    final since = clock.now().subtract(pickerLimit);
    return _picks.values.any((began) => began.isAfter(since));
  }

  /// Runs [pick], which opens the camera, a file picker, the scanner or the
  /// share sheet. On Android these are apps of their own that send Famio to
  /// the background.
  static Future<T> picking<T>(Future<T> Function() pick) async {
    final trip = Object();
    _picks[trip] = clock.now();
    try {
      return await pick();
    } finally {
      _picks.remove(trip);
    }
  }

  /// Locked now: the trips under way were judged with it. One that answers
  /// later changes nothing; one that never answers no longer counts (#568).
  static void _pickingJudged() => _picks.clear();

  static var _previewing = 0;

  /// Runs [show], which shows a document in iOS's preview inside Famio. It
  /// lies over Flutter's view, so its coming and going is no time away;
  /// and while it is up Flutter hears nothing of Famio going away and coming
  /// back: then the iPhone's cover asks [_cameBack] (#512, catalog GRU-115).
  static Future<T> previewing<T>(Future<T> Function() show) async {
    _previewing++;
    try {
      return await show();
    } finally {
      _previewing--;
    }
  }

  static const _privacy = MethodChannel('famio/privacy');

  final SharedPreferences _prefs;
  final DeviceUnlock _device;
  final DateTime Function() _now;
  final TargetPlatform _platform;

  /// Whether this device can lock at all.
  late final Future<bool> available = _device.available;

  bool get enabled => _prefs.getBool(_key) ?? false;

  /// One of [delays].
  Duration get delay {
    final seconds = _prefs.getInt(_delayKey);
    for (final d in delays) {
      if (d.inSeconds == seconds) return d;
    }
    return defaultDelay;
  }

  /// Takes effect the next time Famio comes back.
  Future<void> setDelay(Duration value) async {
    if (!delays.contains(value)) throw ArgumentError.value(value, 'value');
    await _prefs.setInt(_delayKey, value.inSeconds);
    notifyListeners();
  }

  /// Waits for the device's unlock.
  var locked = false;

  /// Hidden while in the background, for the iPhone's app switcher. Android
  /// has the window flag for it, so its app does not flash when the
  /// notification shade comes down.
  var covered = false;

  /// The last attempt did not work: signing out is the way out then.
  var failed = false;

  DateTime? _left;

  /// Whether Famio went to the background for [picking].
  var _leftToPick = false;
  var _asking = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The system's own dialog sends the app to the background too.
    if (!enabled || _asking) return;
    final hide = _platform == TargetPlatform.iOS;
    // Flutter's view goes and comes with iOS's preview over it; leaving
    // Famio with the preview up the iPhone's cover reports (_cameBack).
    if (hide && _previewing > 0) return;
    switch (state) {
      case AppLifecycleState.resumed:
        final left = _left;
        final allowed = _leftToPick && delay < pickerDelay
            ? pickerDelay
            : delay;
        _forget();
        locked =
            locked ||
            (left != null &&
                (allowed == Duration.zero ||
                    _now().difference(left) >= allowed));
        if (locked) _pickingJudged();
        covered = false;
        if (hide) unawaited(_resumedOnIos());
      case AppLifecycleState.inactive:
        covered = hide;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Decided when leaving: the picker's answer may arrive before
        // Famio is told it is back.
        if (_left == null) {
          _left = _now();
          _leftToPick = _picking;
        }
        covered = hide;
    }
    notifyListeners();
  }

  /// The iPhone's cover asks when Famio comes back with something iOS shows
  /// over Flutter's view (a document's preview, the camera): Flutter itself
  /// hears nothing then. True if Famio is locked now; then the cover closes
  /// what lies over Famio, so the lock screen is what remains.
  bool _cameBack(Duration away) {
    if (!enabled) return false;
    final allowed = _picking && delay < pickerDelay ? pickerDelay : delay;
    if (!locked && (allowed == Duration.zero || away >= allowed)) {
      locked = true;
      _forget();
      notifyListeners();
    }
    if (locked) _pickingJudged();
    return locked;
  }

  /// Asks the device; true if it was its owner.
  Future<bool> unlock() async {
    if (_asking) return false;
    final ok = await _ask();
    if (ok) {
      _forget();
      locked = covered = false;
    }
    failed = !ok;
    notifyListeners();
    return ok;
  }

  /// Both ways need the device's unlock: it also shows that it works.
  Future<bool> setEnabled(bool value) async {
    if (value == enabled) return true;
    if (value && !await available) return false;
    if (!await _ask()) return false;
    await _prefs.setBool(_key, value);
    locked = covered = failed = false;
    _forget();
    await _applySecure();
    notifyListeners();
    return true;
  }

  /// Nothing left to hide after signing out.
  void signedOut() {
    locked = covered = failed = false;
    _forget();
    notifyListeners();
  }

  /// Just signed in: no second question for leaving Famio on the way.
  /// Finished while Famio is still away (single sign-on in the browser,
  /// polled in the background), the time away counts from the sign-in, as
  /// for a trip to the camera; otherwise a long stay in the browser after
  /// it would need no unlock (#397).
  void signedIn() {
    locked = failed = false;
    if (_left != null) {
      _left = _now();
      _leftToPick = true;
    } else {
      _forget();
    }
    notifyListeners();
  }

  void _forget() {
    _left = null;
    _leftToPick = false;
  }

  Future<bool> _ask() async {
    _asking = true;
    try {
      return await _device.unlock(tr.appLockReason);
    } finally {
      _asking = false;
      // Face ID makes Famio inactive for a moment, which puts the iPhone's
      // cover up; the answer takes it down again.
      if (_platform == TargetPlatform.iOS && !kIsWeb) {
        unawaited(_resumedOnIos());
      }
    }
  }

  /// Android: no screenshots and a blank tile in the app overview. iPhone:
  /// a cover over everything while Famio is away, also over documents open
  /// in iOS's preview, which Flutter's lock screen does not reach (#512).
  Future<void> _applySecure() async {
    if (kIsWeb ||
        (_platform != TargetPlatform.android &&
            _platform != TargetPlatform.iOS)) {
      return;
    }
    try {
      await _privacy.invokeMethod('setSecure', enabled);
    } on MissingPluginException {
      // Tests.
    }
  }

  /// Tells the iPhone's cover whether Famio came back locked: then what
  /// iOS shows over Famio (a document's preview) closes, and the lock
  /// screen is what remains.
  Future<void> _resumedOnIos() async {
    try {
      await _privacy.invokeMethod('resumed', {'locked': locked});
    } on MissingPluginException {
      // Tests, older builds.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

String appLockDelayLabel(Duration delay) => delay == Duration.zero
    ? tr.appLockImmediately
    : tr.appLockAfterMinutes(delay.inMinutes);

/// Settings: how long Famio may be in the background before [lock] asks.
class AppLockDelayTile extends StatelessWidget {
  const AppLockDelayTile({super.key, required this.lock});

  final AppLock lock;

  @override
  Widget build(BuildContext context) {
    final delay = lock.delay;
    return ListTile(
      leading: const Icon(AppIcons.timer),
      title: Text(tr.appLockDelay),
      subtitle: Text(
        [
          appLockDelayLabel(delay),
          if (delay < AppLock.pickerDelay) tr.appLockPickerNote,
        ].join('\n'),
      ),
      onTap: () async {
        final chosen = await showDialog<Duration>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(tr.appLockDelay),
            children: [
              RadioGroup<Duration>(
                groupValue: delay,
                onChanged: (value) => Navigator.pop(context, value),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final d in AppLock.delays)
                      RadioListTile<Duration>(
                        value: d,
                        title: Text(appLockDelayLabel(d)),
                        subtitle: d < AppLock.pickerDelay
                            ? Text(tr.appLockPickerNote)
                            : null,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        if (chosen != null) await lock.setDelay(chosen);
      },
    );
  }
}

/// Emergency screens that show over the lock: the countdown before an
/// alarm and the running alarm. An emergency needs no unlocking, and the
/// countdown must stay cancellable (#516). Only while such a screen is on
/// top; behind it the lock stays.
abstract final class EmergencyOverLock {
  static final shown = ValueNotifier(false);
  static final _owners = <Object>{};

  /// [owner] is on top ([on]) or no longer.
  static void set(Object owner, bool on) {
    if (on) {
      _owners.add(owner);
    } else {
      _owners.remove(owner);
    }
    shown.value = _owners.isNotEmpty;
  }
}

/// For the state of an emergency screen: shows it over the lock while its
/// route is the current one (see [EmergencyOverLock]). Call [overLock] in
/// `build`.
mixin OverLock<T extends StatefulWidget> on State<T> {
  bool? _onTop;

  void overLock(BuildContext context) {
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    if (onTop == _onTop) return;
    _onTop = onTop;
    // Not while building: the gate above would be marked during it.
    scheduleMicrotask(() => EmergencyOverLock.set(this, onTop && mounted));
  }

  @override
  void dispose() {
    final owner = this;
    scheduleMicrotask(() => EmergencyOverLock.set(owner, false));
    super.dispose();
  }
}

/// Puts [lock]'s screen over everything, dialogs included, while [active]
/// (somebody is signed in). [child] stays where it was underneath.
class AppLockGate extends StatelessWidget {
  const AppLockGate({
    super.key,
    required this.lock,
    required this.active,
    required this.onSignOut,
    required this.child,
  });

  final AppLock lock;
  final bool active;

  /// Signs out; asks through `proceed` (with the number of changes it
  /// would lose) whether to go on, as `AppState.signOut` does.
  final Future<void> Function(Future<bool> Function(int unsent) proceed)
  onSignOut;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([lock, EmergencyOverLock.shown]),
    child: child,
    builder: (context, child) {
      final shown =
          active &&
          (lock.locked || lock.covered) &&
          !EmergencyOverLock.shown.value;
      return Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            excluding: shown,
            child: ExcludeFocus(excluding: shown, child: child!),
          ),
          if (shown) _LockScreen(lock: lock, onSignOut: onSignOut),
        ],
      );
    },
  );
}

class _LockScreen extends StatefulWidget {
  const _LockScreen({required this.lock, required this.onSignOut});

  final AppLock lock;
  final Future<void> Function(Future<bool> Function(int unsent) proceed)
  onSignOut;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  var _asked = false;

  /// Changes a sign-out would lose (#337): asked here, as no page or
  /// dialog shows above this screen.
  int? _unsent;
  Completer<bool>? _answer;

  var _signingOut = false;

  Future<void> _signOut() async {
    if (_signingOut) return;
    _signingOut = true;
    try {
      await widget.onSignOut((unsent) {
        if (unsent == 0 || !mounted) return Future.value(unsent == 0);
        final answer = _answer = Completer<bool>();
        setState(() => _unsent = unsent);
        return answer.future;
      });
    } finally {
      _signingOut = false;
    }
  }

  void _answered(bool signOut) {
    _answer?.complete(signOut);
    _answer = null;
    if (mounted) setState(() => _unsent = null);
  }

  @override
  void initState() {
    super.initState();
    widget.lock.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void dispose() {
    widget.lock.removeListener(_changed);
    _answer?.complete(false);
    super.dispose();
  }

  /// Once each time it locks; after that the button asks.
  void _changed() {
    final lock = widget.lock;
    if (!lock.locked) _asked = false;
    if (!mounted || _asked || !lock.locked || lock.covered) return;
    _asked = true;
    unawaited(lock.unlock());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lock = widget.lock;
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.lockKey,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              if (lock.locked) ...[
                const SizedBox(height: 16),
                Text(tr.appLockLocked, style: theme.textTheme.titleLarge),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: lock.unlock,
                  child: Text(tr.appLockUnlock),
                ),
                if (_unsent case final unsent?) ...[
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      tr.signOutUnsentBody(unsent),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => _answered(false),
                        child: Text(tr.commonCancel),
                      ),
                      TextButton(
                        onPressed: () => _answered(true),
                        child: Text(tr.signOutAnyway),
                      ),
                    ],
                  ),
                ] else if (lock.failed) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _signOut,
                    child: Text(tr.settingsSignOut),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
