import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../api_exception.dart';
import '../i18n.dart';
import 'webauthn.dart';

/// A passkey of a member, as listed in the settings.
class PasskeyInfo {
  const PasskeyInfo({
    required this.id,
    required this.name,
    required this.createdAt,
    this.lastUsed,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime? lastUsed;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastUsed': lastUsed?.toUtc().toIso8601String(),
  };
}

typedef _Challenge = ({String? userId, String origin, DateTime expires});

/// Passkeys (WebAuthn): signing in with the fingerprint, face or PIN of a
/// device instead of a password. The device keeps the private key; the
/// server stores only the public key and checks a signature over a fresh
/// challenge. A passkey is bound to the address it was made for (the
/// relying party id is the host of the web app), so a look-alike site gets
/// nothing usable.
class Passkeys {
  Passkeys(this._db);

  final Database _db;
  final _random = Random.secure();
  final _challenges = <String, _Challenge>{};

  static const _timeout = Duration(minutes: 5);
  static const _maxPending = 500;

  /// The relying party id for [origin]: its host.
  static String rpId(String origin) => Uri.parse(origin).host;

  List<PasskeyInfo> list(String userId) => [
    for (final row in _db.select(
      'SELECT id, name, created_at, last_used FROM passkeys WHERE user_id = ?'
      ' ORDER BY created_at',
      [userId],
    ))
      PasskeyInfo(
        id: row['id'] as String,
        name: row['name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at'] as int,
        ),
        lastUsed: switch (row['last_used']) {
          final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
          _ => null,
        },
      ),
  ];

  bool hasAny(String userId) => _db.select(
    'SELECT 1 FROM passkeys WHERE user_id = ? LIMIT 1',
    [userId],
  ).isNotEmpty;

  void remove(String userId, String id) => _db.execute(
    'DELETE FROM passkeys WHERE user_id = ? AND id = ?',
    [userId, id],
  );

  void removeAll(String userId) =>
      _db.execute('DELETE FROM passkeys WHERE user_id = ?', [userId]);

  /// `PublicKeyCredentialCreationOptions` for a new passkey of [member].
  Map<String, Object?> registrationOptions(
    FamilyMember member, {
    required String origin,
  }) {
    final challenge = _newChallenge(userId: member.id, origin: origin);
    return {
      'challenge': challenge,
      'rp': {'id': rpId(origin), 'name': 'Famio'},
      'user': {
        'id': b64url(utf8.encode(member.id)),
        'name': member.username,
        'displayName': member.displayName,
      },
      'pubKeyCredParams': [
        {'type': 'public-key', 'alg': -7},
        {'type': 'public-key', 'alg': -257},
      ],
      'authenticatorSelection': {
        'residentKey': 'required',
        'requireResidentKey': true,
        'userVerification': 'required',
      },
      'attestation': 'none',
      'timeout': _timeout.inMilliseconds,
      'excludeCredentials': [
        for (final row in _db.select(
          'SELECT id FROM passkeys WHERE user_id = ? AND rp_id = ?',
          [member.id, rpId(origin)],
        ))
          {'type': 'public-key', 'id': row['id']},
      ],
    };
  }

  /// Checks the browser's answer to [registrationOptions] and stores the
  /// passkey.
  PasskeyInfo register(
    FamilyMember member,
    Map<String, Object?> credential, {
    required String name,
  }) {
    try {
      final response = _map(credential['response']);
      final clientData = unb64url(_text(response['clientDataJSON']));
      final challenge = _take(clientData, member.id);
      checkClientData(
        clientData,
        type: 'webauthn.create',
        challenge: challenge.key,
        origin: challenge.value.origin,
      );
      final rp = rpId(challenge.value.origin);
      final data = readAttestation(
        unb64url(_text(response['attestationObject'])),
      )..check(rp);
      final id = b64url(data.credentialId!);
      if (id != credential['id'] || id.length > 1400) {
        throw const WebAuthnException('id');
      }
      if (_db.select('SELECT 1 FROM passkeys WHERE id = ?', [id]).isNotEmpty) {
        throw const WebAuthnException('known');
      }
      final label = name.trim().isEmpty ? t('Passkey') : name.trim();
      final now = DateTime.now();
      _db.execute(
        'INSERT INTO passkeys (id, user_id, rp_id, public_key, sign_count,'
        ' name, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          member.id,
          rp,
          data.publicKey,
          data.signCount,
          label.length > 60 ? label.substring(0, 60) : label,
          now.millisecondsSinceEpoch,
        ],
      );
      return PasskeyInfo(id: id, name: label, createdAt: now);
    } on WebAuthnException {
      throw ApiException.badRequest(
        'passkey_invalid',
        t('Der Passkey konnte nicht geprüft werden. Bitte noch einmal.'),
      );
    }
  }

  /// `PublicKeyCredentialRequestOptions` for signing in at [origin]: no
  /// list of keys, the device offers the passkeys it has for this site.
  Map<String, Object?> loginOptions({required String origin}) => {
    'challenge': _newChallenge(origin: origin),
    'rpId': rpId(origin),
    'userVerification': 'required',
    'timeout': _timeout.inMilliseconds,
  };

  /// Checks a sign-in and returns the member's id.
  String login(Map<String, Object?> credential) {
    try {
      final response = _map(credential['response']);
      final clientData = unb64url(_text(response['clientDataJSON']));
      final challenge = _take(clientData, null);
      checkClientData(
        clientData,
        type: 'webauthn.get',
        challenge: challenge.key,
        origin: challenge.value.origin,
      );
      final rp = rpId(challenge.value.origin);
      final row = _db.select(
        'SELECT * FROM passkeys WHERE id = ? AND rp_id = ?',
        [_text(credential['id']), rp],
      ).firstOrNull;
      if (row == null) throw const WebAuthnException('unknown');
      final userHandle = response['userHandle'];
      if (userHandle is String &&
          userHandle.isNotEmpty &&
          utf8.decode(unb64url(userHandle), allowMalformed: true) !=
              row['user_id']) {
        throw const WebAuthnException('user');
      }
      final authenticatorData = unb64url(_text(response['authenticatorData']));
      final data = AuthenticatorData.parse(authenticatorData)..check(rp);
      checkSignature(
        publicKey: row['public_key'] as Uint8List,
        authenticatorData: authenticatorData,
        clientDataJson: clientData,
        signature: unb64url(_text(response['signature'])),
      );
      // A counter that does not go up: the key may have been copied.
      // (Synced passkeys always send 0.)
      final stored = row['sign_count'] as int;
      if ((stored != 0 || data.signCount != 0) && data.signCount <= stored) {
        throw const WebAuthnException('counter');
      }
      _db.execute(
        'UPDATE passkeys SET sign_count = ?, last_used = ? WHERE id = ?',
        [data.signCount, DateTime.now().millisecondsSinceEpoch, row['id']],
      );
      return row['user_id'] as String;
    } on WebAuthnException {
      throw ApiException(
        401,
        'passkey_invalid',
        t('Anmeldung mit Passkey fehlgeschlagen'),
      );
    }
  }

  String _newChallenge({String? userId, required String origin}) {
    final now = DateTime.now();
    _challenges.removeWhere((_, c) => c.expires.isBefore(now));
    if (_challenges.length >= _maxPending) {
      throw ApiException(
        429,
        'too_many_requests',
        t('Zu viele Versuche. Bitte kurz warten.'),
      );
    }
    final challenge = b64url(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    _challenges[challenge] = (
      userId: userId,
      origin: origin,
      expires: now.add(_timeout),
    );
    return challenge;
  }

  /// The challenge named in [clientData], once: registration ones only
  /// for their member ([userId]), sign-in ones only without.
  MapEntry<String, _Challenge> _take(Uint8List clientData, String? userId) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(clientData));
    } on FormatException {
      throw const WebAuthnException('clientData');
    }
    if (json is! Map || json['challenge'] is! String) {
      throw const WebAuthnException('clientData');
    }
    final key = json['challenge'] as String;
    final challenge = _challenges.remove(key);
    if (challenge == null ||
        challenge.expires.isBefore(DateTime.now()) ||
        challenge.userId != userId) {
      throw const WebAuthnException('challenge');
    }
    return MapEntry(key, challenge);
  }

  static Map<String, Object?> _map(Object? value) => value is Map
      ? value.cast<String, Object?>()
      : throw const WebAuthnException('response');

  static String _text(Object? value) =>
      value is String ? value : throw const WebAuthnException('field');
}
