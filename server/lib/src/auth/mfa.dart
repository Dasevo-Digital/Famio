import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../api_exception.dart';
import 'totp.dart';
import '../i18n.dart';

/// Two-factor login: an authenticator app (TOTP) plus one-time recovery
/// codes for a lost phone.
class Mfa {
  Mfa(this._db);

  final Database _db;
  final _random = Random.secure();

  static const recoveryCount = 10;

  bool hasTotp(String userId) => _db.select(
    'SELECT 1 FROM users WHERE id = ? AND totp_secret IS NOT NULL',
    [userId],
  ).isNotEmpty;

  int recoveryCodesLeft(String userId) =>
      _db
              .select('SELECT COUNT(*) FROM recovery_codes WHERE user_id = ?', [
                userId,
              ])
              .first
              .columnAt(0)
          as int;

  /// Members with two-factor login switched on.
  Set<String> enabledUsers() => {
    for (final row in _db.select(
      'SELECT id FROM users WHERE totp_secret IS NOT NULL',
    ))
      row.columnAt(0) as String,
  };

  /// Starts the setup: a new secret the member scans. Active only after
  /// [confirm] with a code from the app.
  String begin(String userId) {
    final secret = Totp.newSecret();
    _db.execute('UPDATE users SET totp_pending = ? WHERE id = ?', [
      secret,
      userId,
    ]);
    return secret;
  }

  /// Activates the pending secret if [code] matches it and returns fresh
  /// recovery codes (shown once).
  List<String> confirm(String userId, String code) {
    final row = _db.select('SELECT totp_pending FROM users WHERE id = ?', [
      userId,
    ]).firstOrNull;
    final pending = row?['totp_pending'] as String?;
    if (pending == null) {
      throw ApiException.badRequest(
        'no_setup',
        t('Bitte die Einrichtung neu beginnen'),
      );
    }
    final step = Totp.verify(pending, code);
    if (step == null) {
      throw ApiException.badRequest(
        'invalid_code',
        t('Der Code stimmt nicht. Uhrzeit von Handy und Server prüfen.'),
      );
    }
    _db.execute(
      'UPDATE users SET totp_secret = totp_pending, totp_pending = NULL,'
      ' totp_last_step = ? WHERE id = ?',
      [step, userId],
    );
    return newRecoveryCodes(userId);
  }

  /// Whether [code] – from the authenticator app or a recovery code –
  /// proves the second factor. Each code works only once.
  bool check(String userId, String code) {
    final row = _db.select(
      'SELECT totp_secret, totp_last_step FROM users WHERE id = ?',
      [userId],
    ).firstOrNull;
    final secret = row?['totp_secret'] as String?;
    if (secret == null) return false;
    final step = Totp.verify(
      secret,
      code,
      usedStep: row!['totp_last_step'] as int?,
    );
    if (step != null) {
      _db.execute('UPDATE users SET totp_last_step = ? WHERE id = ?', [
        step,
        userId,
      ]);
      return true;
    }
    _db.execute(
      'DELETE FROM recovery_codes WHERE user_id = ? AND code_hash = ?',
      [userId, _hash(code)],
    );
    return _db.updatedRows > 0;
  }

  /// Replaces the recovery codes and returns the new ones.
  List<String> newRecoveryCodes(String userId) {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    String part() => [
      for (var i = 0; i < 5; i++) alphabet[_random.nextInt(alphabet.length)],
    ].join();
    final codes = [
      for (var i = 0; i < recoveryCount; i++) '${part()}-${part()}',
    ];
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM recovery_codes WHERE user_id = ?', [userId]);
      for (final code in codes) {
        _db.execute(
          'INSERT INTO recovery_codes (user_id, code_hash) VALUES (?, ?)',
          [userId, _hash(code)],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return codes;
  }

  /// Switches two-factor login off (also used by admins for a lost phone).
  void disable(String userId) {
    _db.execute(
      'UPDATE users SET totp_secret = NULL, totp_pending = NULL,'
      ' totp_last_step = NULL WHERE id = ?',
      [userId],
    );
    _db.execute('DELETE FROM recovery_codes WHERE user_id = ?', [userId]);
  }

  /// Recovery codes are typed by hand: case, spaces and dashes don't count.
  static String _hash(String code) => sha256
      .convert(
        utf8.encode(code.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')),
      )
      .toString();
}
