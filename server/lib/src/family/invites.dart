import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../accounts.dart';
import '../api_exception.dart';

/// An open invitation: whoever has the code becomes a member with [role]
/// and chooses their own username and password. Only a hash of the code
/// is stored.
class Invite {
  const Invite({
    required this.id,
    required this.role,
    required this.displayName,
    required this.expiresAt,
    this.createdBy,
  });

  final String id;
  final MemberRole role;

  /// Suggested name (the newcomer may change it).
  final String displayName;
  final DateTime expiresAt;
  final String? createdBy;

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role.name,
    'displayName': displayName,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

/// Invitations instead of passwords handed over: an admin creates one, the
/// app shows it as a QR code or text, the newcomer redeems it once.
class Invites {
  Invites(this._db, this.accounts);

  final Database _db;
  final Accounts accounts;
  final _random = Random.secure();

  static const validFor = Duration(hours: 48);

  /// No 0/O and 1/I/L: easy to read out and type.
  static const _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  static String normalize(String code) =>
      code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static String _hash(String code) =>
      sha256.convert(utf8.encode(normalize(code))).toString();

  Invite _invite(Row row) => Invite(
    id: row['id'] as String,
    role: MemberRole.parse(row['role']),
    displayName: row['display_name'] as String,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int),
    createdBy: row['created_by'] as String?,
  );

  /// A new invitation and its code ("ABCD-EFGH"), shown once.
  (Invite, String) create({
    required MemberRole role,
    required String createdBy,
    String displayName = '',
    Duration valid = validFor,
  }) {
    if (role == MemberRole.service) {
      throw ApiException.badRequest(
        'invalid_role',
        'Dienstkonten legt ein Admin direkt an',
      );
    }
    final raw = String.fromCharCodes([
      for (var i = 0; i < 8; i++)
        _alphabet.codeUnitAt(_random.nextInt(_alphabet.length)),
    ]);
    final code = '${raw.substring(0, 4)}-${raw.substring(4)}';
    final now = DateTime.now();
    final invite = Invite(
      id: newId(),
      role: role,
      displayName: displayName.trim(),
      expiresAt: now.add(valid),
      createdBy: createdBy,
    );
    _db.execute(
      'INSERT INTO invites (id, code_hash, role, display_name, created_by,'
      ' created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        invite.id,
        _hash(code),
        role.name,
        invite.displayName,
        createdBy,
        now.millisecondsSinceEpoch,
        invite.expiresAt.millisecondsSinceEpoch,
      ],
    );
    return (invite, code);
  }

  /// Open (unused, not expired) invitations, newest first.
  List<Invite> open() => [
    for (final row in _db.select(
      'SELECT * FROM invites WHERE used_at IS NULL AND expires_at > ?'
      ' ORDER BY created_at DESC',
      [DateTime.now().millisecondsSinceEpoch],
    ))
      _invite(row),
  ];

  /// Forgets invitations that expired or were used more than 30 days ago.
  void collectGarbage() {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 30))
        .millisecondsSinceEpoch;
    _db.execute(
      'DELETE FROM invites WHERE expires_at < ?1 OR used_at < ?1',
      [cutoff],
    );
  }

  void revoke(String id) =>
      _db.execute('DELETE FROM invites WHERE id = ? AND used_at IS NULL', [id]);

  /// The open invitation for [code], or null.
  Invite? find(String code) {
    final row = _db.select(
      'SELECT * FROM invites WHERE code_hash = ? AND used_at IS NULL'
      ' AND expires_at > ?',
      [_hash(code), DateTime.now().millisecondsSinceEpoch],
    ).firstOrNull;
    return row == null ? null : _invite(row);
  }

  /// Creates the member for [code]; the invitation is used up.
  Future<FamilyMember> redeem(
    String code, {
    required String username,
    required String displayName,
    required String password,
  }) async {
    final invite = find(code);
    if (invite == null) {
      throw ApiException(
        404,
        'invalid_invite',
        'Diese Einladung gibt es nicht oder sie ist abgelaufen.',
      );
    }
    // Checked before anything is stored: a weak password keeps the code.
    final hash = await accounts.hashPassword(password);
    final name = displayName.trim().isEmpty
        ? invite.displayName
        : displayName.trim();
    _db.execute('BEGIN');
    try {
      // Used up first: two phones with the same code cannot both join.
      _db.execute(
        'UPDATE invites SET used_at = ? WHERE id = ? AND used_at IS NULL',
        [DateTime.now().millisecondsSinceEpoch, invite.id],
      );
      if (_db.updatedRows == 0) {
        throw ApiException(
          404,
          'invalid_invite',
          'Diese Einladung wurde gerade schon benutzt.',
        );
      }
      final member = accounts.create(
        username: username,
        displayName: name.isEmpty ? username : name,
        passwordHash: hash,
        role: invite.role,
      );
      _db.execute('UPDATE invites SET used_by = ? WHERE id = ?', [
        member.id,
        invite.id,
      ]);
      _db.execute('COMMIT');
      return member;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}
