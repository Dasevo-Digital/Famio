import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
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

  static final _auth = LocalAuthentication();

  /// The plugin has nothing for Linux and browsers.
  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform != TargetPlatform.linux;

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
      return await _auth.authenticate(localizedReason: reason);
    } on Exception catch (e) {
      // Nothing set up (any more), or too many attempts.
      debugPrint('Famio: unlock failed: $e');
      return false;
    }
  }
}

/// Optional lock of this device's app: after [grace] away it asks for the
/// device's own unlock, and while locked or in the background it hides what
/// is on screen. For phones the family shares; the data is encrypted either
/// way. The setting stays on the device.
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
  }

  static const _key = 'appLock.enabled';

  /// Coming back from the camera or a file picker needs no second unlock.
  static const grace = Duration(minutes: 1);

  static const _privacy = MethodChannel('famio/privacy');

  final SharedPreferences _prefs;
  final DeviceUnlock _device;
  final DateTime Function() _now;
  final TargetPlatform _platform;

  /// Whether this device can lock at all.
  late final Future<bool> available = _device.available;

  bool get enabled => _prefs.getBool(_key) ?? false;

  /// Waits for the device's unlock.
  var locked = false;

  /// Hidden while in the background, for the iPhone's app switcher. Android
  /// has the window flag for it, so its app does not flash when the
  /// notification shade comes down.
  var covered = false;

  /// The last attempt did not work: signing out is the way out then.
  var failed = false;

  DateTime? _left;
  var _asking = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The system's own dialog sends the app to the background too.
    if (!enabled || _asking) return;
    final hide = _platform == TargetPlatform.iOS;
    switch (state) {
      case AppLifecycleState.resumed:
        final left = _left;
        _left = null;
        locked = locked || (left != null && _now().difference(left) >= grace);
        covered = false;
      case AppLifecycleState.inactive:
        covered = hide;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _left ??= _now();
        covered = hide;
    }
    notifyListeners();
  }

  /// Asks the device; true if it was its owner.
  Future<bool> unlock() async {
    if (_asking) return false;
    final ok = await _ask();
    if (ok) {
      _left = null;
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
    _left = null;
    await _applySecure();
    notifyListeners();
    return true;
  }

  /// Nothing left to hide after signing out.
  void signedOut() {
    locked = covered = failed = false;
    _left = null;
    notifyListeners();
  }

  Future<bool> _ask() async {
    _asking = true;
    try {
      return await _device.unlock(tr.appLockReason);
    } finally {
      _asking = false;
    }
  }

  /// Android: no screenshots and a blank tile in the app overview.
  Future<void> _applySecure() async {
    if (kIsWeb || _platform != TargetPlatform.android) return;
    try {
      await _privacy.invokeMethod('setSecure', enabled);
    } on MissingPluginException {
      // Tests.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
  final VoidCallback onSignOut;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: lock,
    child: child,
    builder: (context, child) {
      final shown = active && (lock.locked || lock.covered);
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
  final VoidCallback onSignOut;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  var _asked = false;

  @override
  void initState() {
    super.initState();
    widget.lock.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void dispose() {
    widget.lock.removeListener(_changed);
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
                if (lock.failed) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: widget.onSignOut,
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
