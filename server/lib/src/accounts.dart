import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import 'api_exception.dart';
import 'auth/password_rules.dart';
import 'i18n.dart';

/// User accounts and login sessions.
class Accounts {
  final _ingressPairingEpochs = <String, int>{};

  /// Ingress has no bearer session. Family administrators can still revoke
  /// its pending pairing approvals by signing the account out everywhere.
  void invalidateIngressPairings(String userId) =>
      _ingressPairingEpochs[userId] = (_ingressPairingEpochs[userId] ?? 0) + 1;
  Accounts(this._db);

  final Database _db;
  final _random = Random.secure();

  /// PBKDF2 rounds for new hashes; older hashes are upgraded at login.
  static const iterations = 310000;

  /// Sessions unused for this long are signed out.
  static const sessionIdleTimeout = Duration(days: 90);

  bool get hasUsers => _db.select('SELECT 1 FROM users LIMIT 1').isNotEmpty;

  List<FamilyMember> members() => [
    for (final row in _db.select(
      'SELECT * FROM users ORDER BY display_name COLLATE NOCASE',
    ))
      _member(row),
  ];

  /// The app language of [id] for push messages (German if unknown).
  String languageOf(String id) => _languages[id] ??=
      _db.select('SELECT language FROM users WHERE id = ?', [
            id,
          ]).firstOrNull?['language']
          as String? ??
      'de';

  final _languages = <String, String>{};

  /// Remembers the language [id]'s app asked in.
  void noteLanguage(String id, String language) {
    if (languageOf(id) == language) return;
    _db.execute('UPDATE users SET language = ? WHERE id = ?', [language, id]);
    _languages[id] = language;
  }

  /// App versions of the sessions as stored, so that only a change writes.
  final _appVersions = <String, String>{};

  /// Remembers the Famio version and platform the app of [token] runs,
  /// e.g. "2.0.1 android".
  void noteAppVersion(String token, String version) {
    final hash = _tokenHash(token);
    if (_appVersions[hash] == version) return;
    _db.execute('UPDATE sessions SET app_version = ? WHERE token_hash = ?', [
      version,
      hash,
    ]);
    _appVersions[hash] = version;
  }

  /// Profile ends of the sessions as stored, so that only a change writes.
  final _profileEnds = <String, int>{};

  /// Remembers when the iPhone app of [token] stops opening.
  void noteProfileExpiry(String token, DateTime expires) {
    final hash = _tokenHash(token);
    final ms = expires.millisecondsSinceEpoch;
    if (_profileEnds[hash] == ms) return;
    _db.execute(
      'UPDATE sessions SET profile_expires = ? WHERE token_hash = ?',
      [ms, hash],
    );
    _profileEnds[hash] = ms;
  }

  /// Active sessions whose app stops opening before [until] (and did not
  /// stop more than a day ago) that nobody was told about yet.
  List<({String session, String member, String device, DateTime expires})>
  expiringProfiles(DateTime until) => [
    for (final row in _db.select(
      'SELECT token_hash, user_id, device, profile_expires FROM sessions'
      ' WHERE scope IS NULL AND last_seen > ? AND profile_expires <= ?'
      ' AND profile_expires > ?'
      ' AND (profile_noticed IS NULL OR profile_noticed != profile_expires)',
      [
        _idleCutoff,
        until.millisecondsSinceEpoch,
        DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch,
      ],
    ))
      (
        session: row['token_hash'] as String,
        member: row['user_id'] as String,
        device: row['device'] as String? ?? '',
        expires: DateTime.fromMillisecondsSinceEpoch(
          row['profile_expires'] as int,
        ),
      ),
  ];

  /// [expiringProfiles] told about.
  void markProfileNoticed(String session, DateTime expires) => _db.execute(
    'UPDATE sessions SET profile_noticed = ? WHERE token_hash = ?',
    [expires.millisecondsSinceEpoch, session],
  );

  FamilyMember? byId(String id) {
    final rows = _db.select('SELECT * FROM users WHERE id = ?', [id]);
    return rows.isEmpty ? null : _member(rows.first);
  }

  bool hasPassword(String userId) => _db.select(
    'SELECT 1 FROM users WHERE id = ? AND password_hash IS NOT NULL',
    [userId],
  ).isNotEmpty;

  FamilyMember create({
    required String username,
    required String displayName,
    String? passwordHash,
    bool isAdmin = false,
    String? haUserId,
    MemberRole role = MemberRole.adult,
  }) {
    _checkAdminRole(role, isAdmin);
    username = username.trim();
    displayName = displayName.trim();
    _checkUsername(username);
    if (displayName.isEmpty) displayName = username;
    if (_db.select('SELECT 1 FROM users WHERE username = ?', [
      username,
    ]).isNotEmpty) {
      throw ApiException(409, 'username_taken', t('Benutzername ist vergeben'));
    }
    final id = newId();
    _db.execute(
      'INSERT INTO users (id, username, display_name, password_hash, is_admin,'
      ' color, ha_user_id, created_at, role) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        username,
        displayName,
        passwordHash,
        isAdmin ? 1 : 0,
        _palette[members().length % _palette.length],
        haUserId,
        DateTime.now().millisecondsSinceEpoch,
        role.name,
      ],
    );
    return byId(id)!;
  }

  void delete(String userId) {
    _db.execute('DELETE FROM users WHERE id = ?', [userId]);
  }

  /// [check]: false only when the stored hash of a password already in
  /// use is renewed (see [verify]); it is not checked against newer rules.
  Future<void> setPassword(
    String userId,
    String password, {
    bool check = true,
  }) async {
    final hash = check ? await hashPassword(password) : await _hash(password);
    _db.execute('UPDATE users SET password_hash = ? WHERE id = ?', [
      hash,
      userId,
    ]);
  }

  /// Checks the password rules and hashes it off the main isolate, so a
  /// login never stalls sync for everybody else. [personal]: the names of
  /// the new member (the family's names are added).
  Future<String> hashPassword(
    String password, {
    Iterable<String> personal = const [],
  }) {
    _checkPassword(password, [...personal, ..._personal()]);
    return _hash(password);
  }

  /// Names and user names of every member: a password made of one of
  /// them is quickly guessed by whoever knows the family.
  List<String> _personal() => [
    'famio',
    for (final row in _db.select('SELECT username, display_name FROM users'))
      for (final key in ['username', 'display_name']) row[key] as String,
  ];

  /// Hashes another secret (e.g. the parents' code) like a password.
  Future<String> hashSecret(String secret) => _hash(secret);

  Future<bool> matchesSecret(String secret, String hash) =>
      _matches(secret, hash);

  /// Changes profile fields of a member; null leaves a field unchanged.
  /// At least one administrator always remains.
  FamilyMember update(
    String userId, {
    String? username,
    String? displayName,
    bool? isAdmin,
    int? color,
    Object? birthday = _keep,
    MemberRole? role,
    ServiceAccess? serviceAccess,
  }) {
    final current = byId(userId);
    if (current == null) {
      throw ApiException(404, 'not_found', t('Mitglied nicht gefunden'));
    }
    if (username != null) {
      username = username.trim();
      _checkUsername(username);
      if (_db.select('SELECT 1 FROM users WHERE username = ? AND id != ?', [
        username,
        userId,
      ]).isNotEmpty) {
        throw ApiException(
          409,
          'username_taken',
          t('Benutzername ist vergeben'),
        );
      }
    }
    if (displayName != null && displayName.trim().isEmpty) {
      throw ApiException.badRequest('invalid_name', t('Der Name fehlt'));
    }
    _checkAdminRole(role ?? current.role, isAdmin ?? current.isAdmin);
    if (isAdmin == false && current.isAdmin && adminCount <= 1) {
      throw ApiException.badRequest(
        'last_admin',
        t('Es muss mindestens einen Administrator geben'),
      );
    }
    if (birthday != _keep) {
      final parsed = birthday == null || birthday == ''
          ? null
          : Birthday.tryParse(birthday);
      if (birthday != null && birthday != '' && parsed == null) {
        throw ApiException.badRequest(
          'invalid_birthday',
          t('Geburtstag als JJJJ-MM-TT oder --MM-TT angeben'),
        );
      }
      _db.execute('UPDATE users SET birthday = ? WHERE id = ?', [
        parsed?.toString(),
        userId,
      ]);
    }
    _db.execute(
      'UPDATE users SET username = COALESCE(?, username),'
      ' display_name = COALESCE(?, display_name),'
      ' is_admin = COALESCE(?, is_admin), color = COALESCE(?, color),'
      ' role = COALESCE(?, role),'
      ' service_access = COALESCE(?, service_access)'
      ' WHERE id = ?',
      [
        username,
        displayName?.trim(),
        isAdmin == null ? null : (isAdmin ? 1 : 0),
        color,
        role?.name,
        serviceAccess?.name,
        userId,
      ],
    );
    return byId(userId)!;
  }

  static void _checkAdminRole(MemberRole role, bool isAdmin) {
    if (!isAdmin) return;
    if (role == MemberRole.guest) {
      throw ApiException.badRequest(
        'guest_admin',
        t('Gäste können keine Administratoren sein'),
      );
    }
    if (role == MemberRole.service) {
      throw ApiException.badRequest(
        'service_admin',
        t('Dienstkonten können keine Administratoren sein'),
      );
    }
  }

  /// The member's role; adult for unknown ids (e.g. the server itself).
  MemberRole roleOf(String userId) {
    final rows = _db.select('SELECT role FROM users WHERE id = ?', [userId]);
    return rows.isEmpty
        ? MemberRole.adult
        : MemberRole.parse(rows.first.columnAt(0));
  }

  /// What a service account may change; full for everyone else.
  ServiceAccess accessOf(String userId) {
    final rows = _db.select(
      'SELECT role, service_access FROM users WHERE id = ?',
      [userId],
    );
    if (rows.isEmpty || rows.first['role'] != MemberRole.service.name) {
      return ServiceAccess.full;
    }
    return ServiceAccess.parse(rows.first['service_access']);
  }

  /// Ids of the adults (managing chores and pocket money).
  List<String> adultIds() => [
    for (final row in _db.select(
      "SELECT id FROM users WHERE role = 'adult' ORDER BY created_at",
    ))
      row.columnAt(0) as String,
  ];

  /// Device names of each member's signed-in apps ("ios (Lenas-iPhone)"),
  /// The app version each active device reports (`<version> <os>`), as
  /// (member, version) pairs; devices that never sent one are left out.
  List<(String, String)> appVersions() => [
    for (final row in _db.select(
      'SELECT user_id, app_version FROM sessions'
      ' WHERE scope IS NULL AND app_version IS NOT NULL AND last_seen > ?',
      [_idleCutoff],
    ))
      (row['user_id'] as String, row['app_version'] as String),
  ];

  /// without the narrow sessions for notifications or locations.
  Map<String, List<String>> appDevices() {
    final devices = <String, List<String>>{};
    for (final row in _db.select(
      'SELECT user_id, device FROM sessions'
      ' WHERE scope IS NULL AND last_seen > ?',
      [_idleCutoff],
    )) {
      (devices[row['user_id'] as String] ??= []).add(
        row['device'] as String? ?? '',
      );
    }
    return devices;
  }

  int get adminCount =>
      _db
              .select('SELECT COUNT(*) FROM users WHERE is_admin = 1')
              .first
              .columnAt(0)
          as int;

  /// All members with account details and devices, for user management.
  /// [currentToken] marks the caller's own session.
  /// Members with their devices; with [serverVersion] older apps are
  /// marked.
  List<AdminUser> adminUsers({String? currentToken, String? serverVersion}) {
    final current = currentToken == null ? null : _tokenHash(currentToken);
    final sessions = <String, List<DeviceSession>>{};
    for (final row in _db.select(
      'SELECT * FROM sessions ORDER BY last_seen DESC',
    )) {
      final hash = row['token_hash'] as String;
      (sessions[row['user_id'] as String] ??= []).add(
        DeviceSession(
          id: hash.substring(0, 16),
          device: row['device'] as String?,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['created_at'] as int,
          ),
          lastSeen: DateTime.fromMillisecondsSinceEpoch(
            row['last_seen'] as int,
          ),
          current: hash == current,
          appVersion: row['app_version'] as String?,
          profileExpires: switch (row['profile_expires']) {
            final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
            _ => null,
          },
          outdated: switch ((row['app_version'] as String?, serverVersion)) {
            (final String app, final String server) =>
              compareVersions(app.split(' ').first, server) < 0,
            _ => false,
          },
        ),
      );
    }
    final linked = {
      for (final row in _db.select('SELECT DISTINCT user_id FROM sso_links'))
        row.columnAt(0) as String,
    };
    return [
      for (final row in _db.select(
        'SELECT * FROM users ORDER BY display_name COLLATE NOCASE',
      ))
        AdminUser(
          member: _member(row),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['created_at'] as int,
          ),
          hasPassword: row['password_hash'] != null,
          homeAssistant: row['ha_user_id'] != null,
          twoFactor: row['totp_secret'] != null,
          singleSignOn: linked.contains(row['id']),
          sessions: sessions[row['id']] ?? const [],
        ),
    ];
  }

  int get sessionCount =>
      _db.select('SELECT COUNT(*) FROM sessions').first.columnAt(0) as int;

  /// Signs a member out on one device ([sessionId]) or on all devices,
  /// optionally keeping the session of [exceptToken]. Returns the count.
  int deleteSessions(String userId, {String? sessionId, String? exceptToken}) {
    if (sessionId == null) invalidateIngressPairings(userId);
    _db.execute(
      'DELETE FROM sessions WHERE user_id = ?'
      ' AND (? IS NULL OR substr(token_hash, 1, 16) = ?)'
      ' AND (? IS NULL OR token_hash != ?)',
      [
        userId,
        sessionId,
        sessionId,
        exceptToken == null ? null : _tokenHash(exceptToken),
        exceptToken == null ? null : _tokenHash(exceptToken),
      ],
    );
    return _db.updatedRows;
  }

  /// Returns the member if [password] matches, otherwise null.
  Future<FamilyMember?> verify(String username, String password) async {
    final rows = _db.select('SELECT * FROM users WHERE username = ?', [
      username.trim(),
    ]);
    if (rows.isEmpty) {
      await _hash(password); // Same work either way: timing reveals nothing.
      return null;
    }
    final row = rows.first;
    final stored = row['password_hash'] as String?;
    if (stored == null || !await _matches(password, stored)) return null;
    if (_rounds(stored) < iterations) {
      await setPassword(row['id'] as String, password, check: false);
    }
    return _member(row);
  }

  Future<bool> checkPassword(String userId, String password) async {
    final rows = _db.select('SELECT password_hash FROM users WHERE id = ?', [
      userId,
    ]);
    final stored = rows.isEmpty ? null : rows.first.columnAt(0) as String?;
    return stored != null && await _matches(password, stored);
  }

  /// Finds or creates the member linked to a Home Assistant user.
  /// The very first member becomes admin.
  FamilyMember fromHomeAssistant({
    required String haUserId,
    required String haUsername,
    required String displayName,
  }) {
    final rows = _db.select('SELECT * FROM users WHERE ha_user_id = ?', [
      haUserId,
    ]);
    if (rows.isNotEmpty) return _member(rows.first);
    var username = haUsername.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    if (username.length < 2) username = 'ha_${haUserId.substring(0, 6)}';
    var candidate = username;
    for (var n = 2; _usernameTaken(candidate); n++) {
      candidate = '$username$n';
    }
    return create(
      username: candidate,
      displayName: displayName,
      isAdmin: !hasUsers,
      haUserId: haUserId,
    );
  }

  /// Creates a session and returns its bearer token (only stored hashed).
  /// A [scope] limits the session to one purpose, see [userForToken].
  /// [method] tells how the member signed in: password, totp or sso.
  /// Whether [userId] is signed in somewhere already (not counting the
  /// phones' scoped location tokens).
  bool hasSessions(String userId) => _db.select(
    'SELECT 1 FROM sessions WHERE user_id = ? AND scope IS NULL'
    ' AND last_seen > ? LIMIT 1',
    [userId, _idleCutoff],
  ).isNotEmpty;

  String createSession(
    String userId, {
    String? device,
    String? scope,
    String? method,
  }) {
    final token = base64Url
        .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO sessions'
      ' (token_hash, user_id, device, created_at, last_seen, scope, method)'
      ' VALUES (?, ?, ?, ?, ?, ?, ?)',
      [_tokenHash(token), userId, device, now, now, scope, method],
    );
    return token;
  }

  /// The member of a session token. Scoped sessions (e.g. a phone's
  /// location reports) only work where that [scope] is asked for.
  FamilyMember? userForToken(String token, {String? scope}) {
    final hash = _tokenHash(token);
    final rows = _db.select(
      'SELECT u.*, s.last_seen AS session_seen FROM sessions s'
      ' JOIN users u ON u.id = s.user_id'
      ' WHERE s.token_hash = ? AND s.last_seen > ? AND s.scope IS ?',
      [hash, _idleCutoff, scope],
    );
    if (rows.isEmpty) return null;
    // Not a database write on every request: minutes are precise enough
    // for "last used" and the idle timeout of months.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (rows.first['session_seen'] as int) > 60 * 1000) {
      _db.execute('UPDATE sessions SET last_seen = ? WHERE token_hash = ?', [
        now,
        hash,
      ]);
    }
    return _member(rows.first);
  }

  /// How the session of [token] signed in (password, totp, sso, passkey,
  /// device pairing or null for sessions of older versions).
  String? sessionMethod(String token) =>
      _db.select('SELECT method FROM sessions WHERE token_hash = ?', [
            _tokenHash(token),
          ]).firstOrNull?['method']
          as String?;

  /// A pairing is valid only while its approving session and password
  /// remain current. Only digests leave this method.
  String? pairingAuthorization(String sessionHash) {
    final rows = _db.select(
      'SELECT u.password_hash FROM sessions s JOIN users u ON u.id = s.user_id'
      ' WHERE s.token_hash = ? AND s.scope IS NULL AND s.last_seen > ?',
      [sessionHash, _idleCutoff],
    );
    if (rows.isEmpty) return null;
    return sha256
        .convert(utf8.encode('${rows.first['password_hash']}'))
        .toString();
  }

  String? ingressPairingAuthorization(String userId) {
    final rows = _db.select('SELECT password_hash FROM users WHERE id = ?', [
      userId,
    ]);
    if (rows.isEmpty) return null;
    return sha256
        .convert(
          utf8.encode(
            '${rows.first['password_hash']}:${_ingressPairingEpochs[userId] ?? 0}',
          ),
        )
        .toString();
  }

  /// The session proved a second factor (e.g. after setting it up).
  void setSessionMethod(String token, String method) => _db.execute(
    'UPDATE sessions SET method = ? WHERE token_hash = ?',
    [method, _tokenHash(token)],
  );

  /// Removes sessions past [sessionIdleTimeout]; returns how many.
  int deleteExpiredSessions() {
    _db.execute('DELETE FROM sessions WHERE last_seen <= ?', [_idleCutoff]);
    return _db.updatedRows;
  }

  int get _idleCutoff =>
      DateTime.now().subtract(sessionIdleTimeout).millisecondsSinceEpoch;

  void deleteSession(String token) {
    _db.execute('DELETE FROM sessions WHERE token_hash = ?', [
      _tokenHash(token),
    ]);
  }

  // --- app passwords (CalDAV) ---------------------------------------------

  /// Creates a password for one calendar app and returns it; only its hash
  /// is stored. 80 random bits, grouped for typing on a phone.
  (AppPassword, String) createAppPassword(
    String userId, {
    required String name,
    bool includeConfidential = false,
  }) {
    name = name.trim();
    if (name.isEmpty || name.length > 60) {
      throw ApiException.badRequest(
        'invalid_name',
        t('Bitte einen Namen angeben (höchstens 60 Zeichen)'),
      );
    }
    const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
    final chars = [
      for (var i = 0; i < 16; i++) alphabet[_random.nextInt(alphabet.length)],
    ];
    final secret = [
      for (var i = 0; i < 16; i += 4) chars.sublist(i, i + 4).join(),
    ].join('-');
    final id = newId();
    _db.execute(
      'INSERT INTO app_passwords'
      ' (id, user_id, name, secret_hash, include_confidential, created_at)'
      ' VALUES (?, ?, ?, ?, ?, ?)',
      [
        id,
        userId,
        name,
        _tokenHash(_normalizeSecret(secret)),
        includeConfidential ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return (appPasswords(userId).firstWhere((p) => p.id == id), secret);
  }

  List<AppPassword> appPasswords(String userId) => [
    for (final row in _db.select(
      'SELECT * FROM app_passwords WHERE user_id = ? ORDER BY created_at',
      [userId],
    ))
      _appPassword(row),
  ];

  void deleteAppPassword(String userId, String id) => _db.execute(
    'DELETE FROM app_passwords WHERE user_id = ? AND id = ?',
    [userId, id],
  );

  /// The member and app password for CalDAV credentials, or null.
  (FamilyMember, AppPassword)? appPasswordLogin(
    String username,
    String secret,
  ) {
    final rows = _db.select(
      'SELECT p.*, u.id AS uid FROM app_passwords p'
      ' JOIN users u ON u.id = p.user_id'
      ' WHERE p.secret_hash = ? AND u.username = ?',
      [_tokenHash(_normalizeSecret(secret)), username.trim()],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Written at most every few minutes: calendar apps poll often.
    if (now - (row['last_used'] as int? ?? 0) > 5 * 60 * 1000) {
      _db.execute('UPDATE app_passwords SET last_used = ? WHERE id = ?', [
        now,
        row['id'],
      ]);
    }
    return (byId(row['uid'] as String)!, _appPassword(row));
  }

  static String _normalizeSecret(String secret) =>
      secret.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static AppPassword _appPassword(Row row) => AppPassword(
    id: row['id'] as String,
    name: row['name'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    lastUsed: row['last_used'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['last_used'] as int),
    includeConfidential: row['include_confidential'] == 1,
  );

  bool _usernameTaken(String username) => _db.select(
    'SELECT 1 FROM users WHERE username = ?',
    [username],
  ).isNotEmpty;

  void _checkUsername(String username) {
    if (!RegExp(r'^[A-Za-z0-9._-]{2,32}$').hasMatch(username)) {
      throw ApiException.badRequest(
        'invalid_username',
        t('Benutzername: 2–32 Zeichen, nur Buchstaben, Ziffern, . _ -'),
      );
    }
  }

  void _checkPassword(String password, Iterable<String> personal) {
    if (password.length < 8) {
      throw ApiException.badRequest(
        'weak_password',
        t('Das Passwort muss mindestens 8 Zeichen haben'),
      );
    }
    if (password.length > 256) {
      throw ApiException.badRequest(
        'weak_password',
        t('Das Passwort darf höchstens 256 Zeichen haben'),
      );
    }
    if (PasswordRules.isWeak(password, personal: personal)) {
      throw ApiException.badRequest(
        'weak_password',
        t(
          'Dieses Passwort ist zu leicht zu erraten. Gut sind drei oder vier zufällige Wörter, etwa mit Bindestrichen dazwischen.',
        ),
      );
    }
  }

  String _tokenHash(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  Future<String> _hash(String password) async {
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => _random.nextInt(256)),
    );
    final key = await _pbkdf2Async(utf8.encode(password), salt, iterations);
    return 'pbkdf2_sha256\$$iterations\$${base64.encode(salt)}'
        '\$${base64.encode(key)}';
  }

  static int _rounds(String stored) =>
      int.tryParse(stored.split(r'$').elementAtOrNull(1) ?? '') ?? 0;

  Future<bool> _matches(String password, String stored) async {
    final parts = stored.split(r'$');
    if (parts.length != 4 || parts[0] != 'pbkdf2_sha256') return false;
    final expected = base64.decode(parts[3]);
    final actual = await _pbkdf2Async(
      utf8.encode(password),
      base64.decode(parts[2]),
      int.parse(parts[1]),
    );
    var diff = expected.length ^ actual.length;
    for (var i = 0; i < min(expected.length, actual.length); i++) {
      diff |= expected[i] ^ actual[i];
    }
    return diff == 0;
  }

  static Future<List<int>> _pbkdf2Async(
    List<int> password,
    List<int> salt,
    int rounds,
  ) => Isolate.run(() => _pbkdf2(password, salt, rounds));

  /// PBKDF2-HMAC-SHA256 with a single 32 byte output block.
  static List<int> _pbkdf2(List<int> password, List<int> salt, int rounds) {
    final hmac = Hmac(sha256, password);
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = List<int>.of(u);
    for (var i = 1; i < rounds; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }

  static FamilyMember _member(Row row) => FamilyMember(
    id: row['id'] as String,
    username: row['username'] as String,
    displayName: row['display_name'] as String,
    isAdmin: row['is_admin'] == 1,
    color: row['color'] as int?,
    birthday: Birthday.tryParse(row['birthday']),
    role: MemberRole.parse(row['role']),
    serviceAccess: ServiceAccess.parse(row['service_access']),
  );

  /// Default of [update]'s birthday: leave it as it is.
  static const keep = Object();
  static const _keep = keep;

  /// Same friendly colors as the app's palette.
  static const _palette = [
    0xFF3587D6,
    0xFFE8703A,
    0xFF2A9D6E,
    0xFFDB4A7E,
    0xFF7B5BE0,
    0xFFE89B1A,
    0xFF1AA3A3,
    0xFFB07A3C,
  ];
}
