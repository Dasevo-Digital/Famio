import 'dart:convert';

import 'package:http/http.dart' as http;

import 'list_provider.dart';
import '../i18n.dart';

/// Microsoft To Do through Microsoft Graph.
///
/// The family registers its own app in Microsoft Entra (free, for personal
/// and work accounts) and enters its client id. Signing in uses the device
/// code flow: the member opens a Microsoft page and types a code, so the
/// Famio server needs no public address for a redirect.
class MsTodoProvider implements ListProvider {
  MsTodoProvider(
    this._client,
    this._credentials, {
    required this.timeZone,
    Uri? graph,
    Uri? login,
  }) : _graph = graph ?? defaultGraph,
       _login = login ?? defaultLogin;

  static final defaultGraph = Uri.parse('https://graph.microsoft.com/v1.0/');
  static final defaultLogin = Uri.parse(
    'https://login.microsoftonline.com/common/oauth2/v2.0/',
  );
  static const scope = 'Tasks.ReadWrite offline_access';

  final http.Client _client;
  final Uri _graph;
  final Uri _login;

  /// IANA zone for due dates, e.g. `Europe/Berlin`.
  final String timeZone;
  Map<String, Object?> _credentials;

  @override
  String get kind => 'mstodo';

  @override
  bool get oneEntryPerTitle => false;

  @override
  bool get hasDueDates => true;

  @override
  Map<String, Object?> get credentials => _credentials;

  /// Starts the device code flow: the member enters `user_code` at
  /// `verification_uri`.
  static Future<Map<String, Object?>> startDeviceLogin(
    http.Client client, {
    required String clientId,
    Uri? login,
  }) async {
    final response = await client.post(
      (login ?? defaultLogin).resolve('devicecode'),
      body: {'client_id': clientId, 'scope': scope},
    );
    final json = _json(response);
    if (response.statusCode >= 300) {
      throw ListProviderException(
        t(
          'Microsoft lehnt die Anmeldung ab: {error}. Stimmt die Client-ID, und sind öffentliche Clients erlaubt?',
          {
            'error':
                json['error_description'] ??
                json['error'] ??
                response.statusCode,
          },
        ),
      );
    }
    return json;
  }

  /// Asks whether the member finished signing in: null while pending,
  /// otherwise the credentials to keep.
  static Future<Map<String, Object?>?> pollDeviceLogin(
    http.Client client, {
    required String clientId,
    required String deviceCode,
    Uri? login,
  }) async {
    final response = await client.post(
      (login ?? defaultLogin).resolve('token'),
      body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'client_id': clientId,
        'device_code': deviceCode,
      },
    );
    final json = _json(response);
    final error = json['error'];
    if (error == 'authorization_pending' || error == 'slow_down') return null;
    if (error != null || response.statusCode >= 300) {
      throw ListProviderException(
        error == 'expired_token'
            ? t('Der Code ist abgelaufen. Bitte neu beginnen.')
            : t('Microsoft hat die Anmeldung nicht bestätigt ({error}).', {
                'error':
                    json['error_description'] ?? error ?? response.statusCode,
              }),
        signedOut: true,
      );
    }
    return _tokens(json, clientId: clientId);
  }

  static Map<String, Object?> _tokens(
    Map<String, Object?> json, {
    required String clientId,
    String? previousRefresh,
  }) => {
    'clientId': clientId,
    'token': json['access_token'],
    'refresh': json['refresh_token'] ?? previousRefresh,
    'expires': DateTime.now()
        .add(Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600))
        .millisecondsSinceEpoch,
  };

  static Map<String, Object?> _json(http.Response response) {
    if (response.body.isEmpty) return const {};
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      return json is Map ? json.cast<String, Object?>() : const {};
    } on FormatException {
      return const {};
    }
  }

  Future<Map<String, String>> _auth() async {
    final expires = _credentials['expires'] as int? ?? 0;
    if (DateTime.now().millisecondsSinceEpoch > expires - 300000) {
      final clientId = '${_credentials['clientId']}';
      final response = await _client.post(
        _login.resolve('token'),
        body: {
          'grant_type': 'refresh_token',
          'client_id': clientId,
          'refresh_token': '${_credentials['refresh']}',
          'scope': scope,
        },
      );
      if (response.statusCode >= 400) {
        throw ListProviderException(
          t('Die Anmeldung bei Microsoft ist abgelaufen. Bitte neu verbinden.'),
          signedOut: true,
        );
      }
      _credentials = _tokens(
        _json(response),
        clientId: clientId,
        previousRefresh: _credentials['refresh'] as String?,
      );
    }
    return {'authorization': 'Bearer ${_credentials['token']}'};
  }

  Future<Map<String, Object?>> _call(
    String method,
    Uri url, [
    Map<String, Object?>? body,
  ]) async {
    final request = http.Request(method, url)..headers.addAll(await _auth());
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    if (response.statusCode == 401) {
      throw ListProviderException(
        t('Microsoft hat den Zugriff abgelehnt. Bitte neu verbinden.'),
        signedOut: true,
      );
    }
    if (response.statusCode >= 300) {
      throw ListProviderException(
        t('Microsoft To Do antwortet mit Fehler {status}.', {
          'status': response.statusCode,
        }),
      );
    }
    return _json(response);
  }

  Uri _tasks(String listId) =>
      _graph.resolve('me/todo/lists/${Uri.encodeComponent(listId)}/tasks');

  @override
  Future<List<RemoteList>> lists() async {
    final json = await _call('GET', _graph.resolve('me/todo/lists'));
    return [
      for (final l in (json['value'] as List?) ?? const [])
        if (l is Map)
          RemoteList(id: '${l['id']}', name: '${l['displayName'] ?? ''}'),
    ];
  }

  @override
  Future<List<RemoteItem>> items(String listId) async {
    final items = <RemoteItem>[];
    Uri? next = _tasks(listId).replace(queryParameters: {r'$top': '100'});
    while (next != null) {
      final json = await _call('GET', next);
      for (final t in (json['value'] as List?) ?? const []) {
        if (t is Map) items.add(_item(t.cast<String, Object?>()));
      }
      final link = json['@odata.nextLink'];
      next = link is String ? Uri.parse(link) : null;
    }
    return items;
  }

  static RemoteItem _item(Map<String, Object?> t) {
    final body = (t['body'] as Map?) ?? const {};
    var note = '${body['content'] ?? ''}';
    if ('${body['contentType']}'.toLowerCase() == 'html') {
      note = note
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(RegExp('<[^>]*>'), '')
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&amp;', '&');
    }
    final due = (t['dueDateTime'] as Map?)?['dateTime'] as String?;
    final dueDay = due == null ? null : DateTime.tryParse(due.substring(0, 10));
    return RemoteItem(
      id: '${t['id']}',
      title: '${t['title'] ?? ''}',
      note: note.trim(),
      done: t['status'] == 'completed',
      due: dueDay == null
          ? null
          : DateTime(dueDay.year, dueDay.month, dueDay.day),
      modified: DateTime.tryParse('${t['lastModifiedDateTime']}'),
    );
  }

  Map<String, Object?> _body(ItemDraft item) => {
    'title': item.title,
    'body': {'content': item.note, 'contentType': 'text'},
    'status': item.done ? 'completed' : 'notStarted',
    'dueDateTime': item.due == null
        ? null
        : {
            'dateTime':
                '${item.due!.toIso8601String().substring(0, 10)}T00:00:00',
            'timeZone': timeZone,
          },
  };

  @override
  Future<RemoteItem> create(String listId, ItemDraft item) async =>
      _item(await _call('POST', _tasks(listId), _body(item)));

  @override
  Future<void> update(String listId, RemoteItem previous, ItemDraft item) =>
      _call(
        'PATCH',
        _tasks(listId).resolve('tasks/${Uri.encodeComponent(previous.id)}'),
        _body(item),
      );

  @override
  Future<void> delete(String listId, RemoteItem item) => _call(
    'DELETE',
    _tasks(listId).resolve('tasks/${Uri.encodeComponent(item.id)}'),
  );
}
