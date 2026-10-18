import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import '../api_exception.dart';
import '../i18n.dart';
import '../remote_url_policy.dart';
import 'push_service.dart';
import 'web_push_crypto.dart';

/// A browser that gets Famio's notices while the web app is closed.
class WebPushSubscription {
  const WebPushSubscription({
    required this.id,
    required this.device,
    required this.host,
    required this.createdAt,
    this.lastError,
  });

  final String id;
  final String device;

  /// The browser's push service, e.g. fcm.googleapis.com.
  final String host;
  final DateTime createdAt;
  final String? lastError;

  Map<String, Object?> toJson() => {
    'id': id,
    'device': device,
    'host': host,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastError': lastError,
  };
}

/// Web Push (RFC 8030) for the web app: the browser hands over an address
/// at its push service (Google, Mozilla, Apple, Microsoft), the server
/// sends each notice there, encrypted for that browser alone (RFC 8291)
/// and signed with the server's VAPID key (RFC 8292). No account at a
/// push service is needed; the services only see ciphertext.
class WebPush {
  WebPush(
    this._db, {
    http.Client? client,
    required this._publicUrl,
    this._urlPolicy = const RemoteUrlPolicy(),
    this.onSent,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Database _db;
  final http.Client _client;
  final bool _ownsClient;
  final String? Function() _publicUrl;
  final RemoteUrlPolicy _urlPolicy;

  /// Called after each attempt (for the metrics).
  final void Function({required bool ok})? onSent;

  static const _keysKey = 'webPush.vapid';

  /// Push services of the browsers; the server sends nowhere else, so a
  /// member cannot make it post to any address.
  static const _services = [
    'fcm.googleapis.com',
    'android.googleapis.com',
    'updates.push.services.mozilla.com',
    'push.services.mozilla.com',
    'push.apple.com',
    'notify.windows.com',
  ];

  VapidKeys? _keys;

  /// The server's VAPID key, created on first use.
  VapidKeys get keys => _keys ??= _loadKeys();

  VapidKeys _loadKeys() {
    String? stored() =>
        _db
                .select('SELECT value FROM settings WHERE key = ?', [_keysKey])
                .firstOrNull
                ?.columnAt(0)
            as String?;
    if (stored() == null) {
      _db.execute(
        'INSERT INTO settings (key, value) VALUES (?, ?)'
        ' ON CONFLICT(key) DO NOTHING',
        [_keysKey, jsonEncode(VapidKeys.generate().toJson())],
      );
    }
    // Browsers subscribed with this key: it must never change.
    return VapidKeys.fromJson((jsonDecode(stored()!) as Map).cast());
  }

  /// Closes only a client this service created itself.
  void close() {
    if (_ownsClient) _client.close();
  }

  /// The browsers' `applicationServerKey`.
  String get publicKey => b64(keys.publicKey);

  List<WebPushSubscription> subscriptions(String memberId) => [
    for (final row in _db.select(
      'SELECT * FROM web_push_subscriptions WHERE member_id = ?'
      ' ORDER BY created_at',
      [memberId],
    ))
      WebPushSubscription(
        id: row['id'] as String,
        device: row['device'] as String,
        host: Uri.parse(row['endpoint'] as String).host,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at'] as int,
        ),
        lastError: row['last_error'] as String?,
      ),
  ];

  /// Stores the subscription a browser made (again: the same endpoint
  /// replaces the old keys) and returns its id.
  Future<String> subscribe(
    String memberId, {
    required String endpoint,
    required String p256dh,
    required String auth,
    String device = '',
  }) async {
    final uri = Uri.tryParse(endpoint);
    final host = uri?.host.toLowerCase() ?? '';
    if (uri == null ||
        !uri.isScheme('https') ||
        !_services.any((s) => host == s || host.endsWith('.$s'))) {
      throw ApiException.badRequest(
        'invalid_endpoint',
        t('Dieser Browser nutzt einen unbekannten Push-Dienst'),
      );
    }
    await _urlPolicy.check(uri);
    final Uint8List key;
    final Uint8List secret;
    try {
      key = unb64(p256dh);
      secret = unb64(auth);
    } on FormatException {
      throw ApiException.badRequest('invalid_keys', t('Ungültige Schlüssel'));
    }
    if (key.length != 65 || key.first != 4 || secret.length != 16) {
      throw ApiException.badRequest('invalid_keys', t('Ungültige Schlüssel'));
    }
    final existing = _db.select(
      'SELECT id, member_id FROM web_push_subscriptions WHERE endpoint = ?',
      [uri.toString()],
    ).firstOrNull;
    if (existing == null &&
        _db
                    .select(
                      'SELECT COUNT(*) FROM web_push_subscriptions'
                      ' WHERE member_id = ?',
                      [memberId],
                    )
                    .first
                    .columnAt(0)
                as int >=
            10) {
      throw ApiException.badRequest('too_many', t('Höchstens 10 Geräte'));
    }
    final id = existing?['id'] as String? ?? newId();
    final name = device.trim().isEmpty ? t('Browser') : device.trim();
    // A browser used by someone else now belongs to the new member.
    _db.execute(
      'INSERT INTO web_push_subscriptions (id, member_id, endpoint, p256dh,'
      ' auth, device, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)'
      ' ON CONFLICT(endpoint) DO UPDATE SET member_id = excluded.member_id,'
      ' p256dh = excluded.p256dh, auth = excluded.auth,'
      ' device = excluded.device, last_error = NULL',
      [
        id,
        memberId,
        uri.toString(),
        b64(key),
        b64(secret),
        name.length > 80 ? name.substring(0, 80) : name,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return id;
  }

  void unsubscribe(String memberId, {String? id, String? endpoint}) =>
      _db.execute(
        'DELETE FROM web_push_subscriptions WHERE member_id = ?'
        ' AND (id = ? OR endpoint = ?)',
        [memberId, id, endpoint],
      );

  /// Sends a test notice to one of [memberId]'s browsers; the error, if any.
  Future<String?> test(String memberId, String id) async {
    final row = _db.select(
      'SELECT * FROM web_push_subscriptions WHERE member_id = ? AND id = ?',
      [memberId, id],
    ).firstOrNull;
    if (row == null) {
      throw ApiException(404, 'not_found', t('Gerät nicht gefunden'));
    }
    return send(
      row,
      PushNotice(
        to: {},
        title: 'Famio',
        body: t('Benachrichtigungen funktionieren 🎉'),
        brief: t('Benachrichtigungen funktionieren 🎉'),
        tag: 'tada',
      ),
    );
  }

  /// The subscriptions of [memberIds].
  ResultSet rowsFor(List<String> memberIds) => _db.select(
    'SELECT * FROM web_push_subscriptions WHERE member_id IN '
    '(${List.filled(memberIds.length, '?').join(', ')})',
    memberIds,
  );

  /// Encrypts [notice] for the browser of [row] and hands it to its push
  /// service; returns the error text, if any. A subscription the service
  /// no longer knows (404, 410) is removed.
  Future<String?> send(Row row, PushNotice notice, {bool quiet = false}) async {
    final endpoint = Uri.parse(row['endpoint'] as String);
    final body = notice.body.length > 1000
        ? '${notice.body.substring(0, 999)}…'
        : notice.body;
    final payload = utf8.encode(
      jsonEncode({
        'title': notice.title,
        'body': body,
        'tag': notice.tag,
        if (quiet) 'quiet': true,
        if (notice.urgent) 'urgent': true,
      }),
    );
    String? error;
    try {
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers.addAll({
          'content-type': 'application/octet-stream',
          'content-encoding': 'aes128gcm',
          'authorization': keys.authorization(endpoint, subject: _subject()),
          // Kept a day for a browser that is offline.
          'ttl': notice.urgent ? '3600' : '86400',
          'urgency': notice.urgent
              ? 'high'
              : quiet
              ? 'low'
              : 'normal',
        })
        ..bodyBytes = encryptPush(
          payload,
          uaPublic: unb64(row['p256dh'] as String),
          authSecret: unb64(row['auth'] as String),
        );
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      await response.stream.drain<void>();
      final status = response.statusCode;
      if (status == 404 || status == 410) {
        _db.execute('DELETE FROM web_push_subscriptions WHERE id = ?', [
          row['id'],
        ]);
        onSent?.call(ok: false);
        return t('Der Browser hat die Benachrichtigungen abbestellt');
      }
      if (status >= 300) {
        error = t('Push-Server antwortet {status}', {'status': status});
      }
    } catch (_) {
      error = t('Push-Server nicht erreichbar');
    }
    _db.execute(
      'UPDATE web_push_subscriptions SET last_error = ? WHERE id = ?',
      [error, row['id']],
    );
    onSent?.call(ok: error == null);
    return error;
  }

  /// How the push service can reach the operator (RFC 8292): the
  /// server's public address, else the project page.
  String _subject() {
    final url = _publicUrl();
    if (url != null && url.startsWith('https://')) return url;
    return 'https://github.com/Dasevo-Digital/Famio';
  }
}
