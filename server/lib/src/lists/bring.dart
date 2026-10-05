import 'dart:convert';

import 'package:http/http.dart' as http;

import 'list_provider.dart';

/// Bring! shopping lists through the interface of Bring's own apps. Bring!
/// offers no public interface; this is the one the Home Assistant
/// integration uses too, and it may change without notice. Famio keeps the
/// login token, never the password.
///
/// Bring! keeps one entry per article name: the article is [RemoteItem.id]
/// (the stable per-entry uuid is not kept everywhere), the specification
/// is the quantity, and ticked off entries move to "recently bought".
class BringProvider implements ListProvider {
  BringProvider(this._client, this._credentials, {Uri? base})
    : _base = base ?? defaultBase;

  static final defaultBase = Uri.parse('https://api.getbring.com/rest/v2/');

  /// The key of Bring's web app, sent by every client of this interface.
  static const _apiKey = 'cof4Nc6D8saplXjE3h3HXqHH8m7VU2i1Gs0g85Sp';

  final http.Client _client;
  final Uri _base;
  Map<String, Object?> _credentials;

  @override
  String get kind => 'bring';

  @override
  bool get oneEntryPerTitle => true;

  @override
  bool get hasDueDates => false;

  @override
  Map<String, Object?> get credentials => _credentials;

  /// Signs in and returns the credentials to keep (no password).
  static Future<Map<String, Object?>> signIn(
    http.Client client, {
    required String email,
    required String password,
    Uri? base,
  }) async {
    final response = await client.post(
      (base ?? defaultBase).resolve('bringauth'),
      headers: _headers(),
      body: {'email': email, 'password': password},
    );
    if (response.statusCode == 401 || response.statusCode == 404) {
      throw ListProviderException(
        'Bring! hat E-Mail-Adresse oder Passwort nicht angenommen.',
        signedOut: true,
      );
    }
    final json = _decode(response);
    return {
      'email': email,
      'user': json['uuid'],
      'token': json['access_token'],
      'refresh': json['refresh_token'],
      'expires': _expiry(json['expires_in']),
    };
  }

  static Map<String, String> _headers({String? user, String? token}) => {
    'X-BRING-API-KEY': _apiKey,
    'X-BRING-CLIENT': 'webApp',
    'X-BRING-APPLICATION': 'bring',
    'X-BRING-COUNTRY': 'DE',
    'X-BRING-USER-UUID': ?user,
    'Authorization': ?(token == null ? null : 'Bearer $token'),
  };

  static int _expiry(Object? seconds) => DateTime.now()
      .add(Duration(seconds: (seconds as num?)?.toInt() ?? 3600))
      .millisecondsSinceEpoch;

  static Map<String, Object?> _decode(http.Response response) {
    if (response.statusCode >= 300) {
      throw ListProviderException(
        'Bring! antwortet mit Fehler ${response.statusCode}.',
        signedOut: response.statusCode == 401,
      );
    }
    if (response.body.isEmpty) return const {};
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    return json is Map ? json.cast<String, Object?>() : const {};
  }

  /// Renews the token a few minutes before it expires.
  Future<Map<String, String>> _auth() async {
    final expires = _credentials['expires'] as int? ?? 0;
    if (DateTime.now().millisecondsSinceEpoch > expires - 300000) {
      final response = await _client.post(
        _base.resolve('bringauth/token'),
        headers: _headers(),
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': '${_credentials['refresh']}',
        },
      );
      if (response.statusCode >= 400 && response.statusCode < 500) {
        throw ListProviderException(
          'Die Anmeldung bei Bring! ist abgelaufen. Bitte neu verbinden.',
          signedOut: true,
        );
      }
      final json = _decode(response);
      _credentials = {
        ..._credentials,
        'token': json['access_token'],
        'refresh': json['refresh_token'] ?? _credentials['refresh'],
        'expires': _expiry(json['expires_in']),
      };
    }
    return _headers(
      user: _credentials['user'] as String?,
      token: _credentials['token'] as String?,
    );
  }

  @override
  Future<List<RemoteList>> lists() async {
    final json = _decode(
      await _client.get(
        _base.resolve('bringusers/${_credentials['user']}/lists'),
        headers: await _auth(),
      ),
    );
    return [
      for (final l in (json['lists'] as List?) ?? const [])
        if (l is Map)
          RemoteList(id: '${l['listUuid']}', name: '${l['name'] ?? 'Bring!'}'),
    ];
  }

  @override
  Future<List<RemoteItem>> items(String listId) async {
    final json = _decode(
      await _client.get(
        _base.resolve('bringlists/${Uri.encodeComponent(listId)}'),
        headers: await _auth(),
      ),
    );
    // Current answer: {items: {purchase, recently}}; older ones have both
    // lists at the top and call the article "name".
    final items = json['items'] is Map ? json['items'] as Map : json;
    if (items['purchase'] is! List && items['recently'] is! List) {
      // Never read an unknown answer as an empty list: the sync would
      // then do nothing without telling anyone.
      throw ListProviderException(
        'Bring! hat die Liste in einem unbekannten Format geliefert '
        '(Felder: ${json.keys.join(', ')}).',
      );
    }
    RemoteItem? item(Object? e, {required bool done}) {
      if (e is! Map) return null;
      final name = '${e['itemId'] ?? e['name'] ?? ''}'.trim();
      if (name.isEmpty) return null;
      return RemoteItem(
        id: name,
        title: name,
        note: '${e['specification'] ?? ''}',
        done: done,
      );
    }

    return [
      for (final e in (items['purchase'] as List?) ?? const [])
        ?item(e, done: false),
      for (final e in (items['recently'] as List?) ?? const [])
        ?item(e, done: true),
    ];
  }

  Future<void> _change(
    String listId,
    List<({String name, String spec, String operation})> changes,
  ) async {
    _decode(
      await _client.put(
        _base.resolve('bringlists/${Uri.encodeComponent(listId)}/items'),
        headers: {...await _auth(), 'content-type': 'application/json'},
        body: jsonEncode({
          'changes': [
            for (final c in changes)
              {
                'accuracy': '0.0',
                'altitude': '0.0',
                'latitude': '0.0',
                'longitude': '0.0',
                'itemId': c.name,
                'spec': c.spec,
                'uuid': '',
                'operation': c.operation,
              },
          ],
          'sender': '',
        }),
      ),
    );
  }

  static String _operation(bool done) => done ? 'TO_RECENTLY' : 'TO_PURCHASE';

  @override
  Future<RemoteItem> create(String listId, ItemDraft item) async {
    await _change(listId, [
      (name: item.title, spec: item.note, operation: _operation(item.done)),
    ]);
    return RemoteItem(
      id: item.title,
      title: item.title,
      note: item.note,
      done: item.done,
    );
  }

  @override
  Future<void> update(String listId, RemoteItem previous, ItemDraft item) =>
      _change(listId, [
        // A new name is a different article.
        if (previous.title != item.title)
          (name: previous.title, spec: '', operation: 'REMOVE'),
        (name: item.title, spec: item.note, operation: _operation(item.done)),
      ]);

  @override
  Future<void> delete(String listId, RemoteItem item) =>
      _change(listId, [(name: item.title, spec: '', operation: 'REMOVE')]);
}
