import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'environment.dart';

/// Secrets of this device: the session token, the key of the local
/// database and file cache, and the pinned server certificate.
///
/// They live in the operating system's keystore (Keychain, Android
/// Keystore, Windows DPAPI, Secret Service/KWallet on Linux). Where that is
/// not available (e.g. Linux without a keyring, tests), the app still works
/// with plain preferences and [secure] tells the settings screen so.
///
/// All secrets share one keystore entry. On macOS without an Apple team
/// signature, "Immer erlauben" only lasts until the next update, so every
/// entry would ask again after each update – one entry asks once.
class SecureVault {
  SecureVault._(this._prefs, this._storage, {required this.secure})
    : _memory = null;

  /// The web app keeps secrets only in memory, for the open page: the
  /// session belongs to Home Assistant (or is signed in again next time).
  SecureVault.memory(this._prefs)
    : _storage = null,
      secure = true,
      _memory = {};

  final Map<String, String>? _memory;

  /// Both builds share the login keychain on macOS: separate entries keep
  /// development away from the family's secrets.
  static const _entry = AppEnv.isDev ? 'famio-dev' : 'famio';

  static Future<SecureVault> open(SharedPreferences prefs) async {
    const storage = FlutterSecureStorage(
      // Legacy keychain on macOS: needs no Keychain Sharing entitlement or
      // provisioning, so ad-hoc signed builds work.
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      // iOS starts the app in the background for location events, also
      // while the phone is locked: readable after the first unlock, and
      // never moved to another device.
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    // Only Linux may lack a keystore. Elsewhere a failure means "not yet"
    // (locked phone, keychain busy): falling back would lose the session
    // and the key of the local database, so wait instead.
    final mayFallBack = kIsWeb || Platform.isLinux;
    for (var attempt = 0; ; attempt++) {
      try {
        // A keyring may ask the user to unlock or create it (KWallet); give
        // them time, but never block the app forever.
        const wait = Duration(minutes: 2);
        await storage.write(key: '_probe', value: '1').timeout(wait);
        final ok = await storage.read(key: '_probe').timeout(wait) == '1';
        await storage.delete(key: '_probe').timeout(wait);
        if (ok) {
          final vault = SecureVault._(prefs, storage, secure: true);
          await vault._migrate();
          return vault;
        }
      } catch (_) {
        // Not available (yet).
      }
      // Phones wait as long as it takes (e.g. until the first unlock after
      // a restart); desktops give up after half an hour.
      final phone = Platform.isIOS || Platform.isAndroid;
      if (mayFallBack || (!phone && attempt >= 360)) break;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    final vault = SecureVault._(prefs, null, secure: false);
    await vault._migrate();
    return vault;
  }

  final SharedPreferences _prefs;
  final FlutterSecureStorage? _storage;

  /// Whether secrets are in the OS keystore (not plain preferences).
  final bool secure;

  static const _keys = ['token', 'deviceKey', 'certPin'];

  /// The shared keystore entry, read once.
  Map<String, String> _secrets = {};

  Future<String?> read(String key) async => _memory != null
      ? _memory[key]
      : _storage == null
      ? _prefs.getString('vault.$key')
      : _secrets[key];

  Future<void> write(String key, String? value) async {
    if (_memory case final memory?) {
      value == null ? memory.remove(key) : memory[key] = value;
      return;
    }
    final storage = _storage;
    if (storage == null) {
      value == null
          ? await _prefs.remove('vault.$key')
          : await _prefs.setString('vault.$key', value);
      return;
    }
    if (_secrets[key] == value) return;
    final next = {..._secrets};
    value == null ? next.remove(key) : next[key] = value;
    await storage.write(key: _entry, value: jsonEncode(next));
    _secrets = next;
  }

  /// Key for the encrypted local database and file cache (created once).
  Future<String> deviceKey() async {
    final existing = await read('deviceKey');
    if (existing != null) return existing;
    final random = Random.secure();
    final key = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await write('deviceKey', key);
    return key;
  }

  /// Version 0.5 kept the token in plain preferences under `token`, up to
  /// 0.11 every secret had its own keystore entry.
  Future<void> _migrate() async {
    final storage = _storage;
    if (storage != null) {
      final stored = await storage.read(key: _entry);
      if (stored != null) {
        _secrets = (jsonDecode(stored) as Map).cast();
      } else if (!AppEnv.isDev) {
        final old = <String, String>{};
        for (final key in _keys) {
          final value = await storage.read(key: key);
          if (value != null) old[key] = value;
        }
        if (old.isNotEmpty) {
          await storage.write(key: _entry, value: jsonEncode(old));
          _secrets = old;
          for (final key in old.keys) {
            await storage.delete(key: key);
          }
        }
      }
    }
    final legacy = _prefs.getString('token');
    if (legacy != null) {
      await write('token', legacy);
      await _prefs.remove('token');
    }
    if (_storage == null) return;
    // Secrets written while no keystore was available.
    for (final key in _keys) {
      final plain = _prefs.getString('vault.$key');
      if (plain != null) {
        await write(key, plain);
        await _prefs.remove('vault.$key');
      }
    }
  }
}
