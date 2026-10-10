import 'dart:async';
import 'dart:convert';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import '../accounts.dart';
import '../api_exception.dart';
import '../i18n.dart';
import '../record_store.dart';

/// The connection to a PaperBuddy (or Paperless-ngx) server, set by an
/// admin. The token belongs to a PaperBuddy user who may read the family's
/// documents; it never leaves the Famio server.
class PaperBuddyConfig {
  const PaperBuddyConfig({
    required this.url,
    required this.token,
    this.tag = 'Familie',
    this.memberIds = const [],
  });

  factory PaperBuddyConfig.fromJson(Map<String, Object?> json) =>
      PaperBuddyConfig(
        url: json['url'] as String? ?? '',
        token: json['token'] as String? ?? '',
        tag: json['tag'] as String? ?? 'Familie',
        memberIds: [
          for (final m in json['memberIds'] as List? ?? const []) '$m',
        ],
      );

  /// E.g. `http://192.168.1.20:8000`.
  final String url;
  final String token;

  /// Documents with this tag appear in Famio.
  final String tag;

  /// Who sees them in Famio; empty: every adult.
  final List<String> memberIds;

  Map<String, Object?> toJson() => {
    'url': url,
    'token': token,
    'tag': tag,
    'memberIds': memberIds,
  };
}

/// Documents of a PaperBuddy server with the family's tag, shown in
/// Famio's documents (collection `external_documents`, read-only) with
/// their deadlines. Filing and full text stay in PaperBuddy; Famio keeps
/// title, dates and the next deadline, and fetches a file only when a
/// member opens it.
class PaperBuddyLink {
  PaperBuddyLink({
    required this.db,
    required this.records,
    required this.accounts,
    required this.onChanged,
    http.Client? client,
    this.interval = const Duration(minutes: 30),
  }) : _http = client ?? http.Client();

  final Database db;
  final RecordStore records;
  final Accounts accounts;

  /// Called after the documents changed, to notify connected apps.
  final void Function() onChanged;
  final Duration interval;
  final http.Client _http;
  Timer? _timer;
  Future<void>? _running;

  static const _key = 'paperbuddy';
  static const _statusKey = 'paperbuddy.status';
  static const idPrefix = 'pb-';

  void start() {
    _timer ??= Timer.periodic(interval, (_) => sync());
    if (config != null) unawaited(sync());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  PaperBuddyConfig? get config {
    final raw = _setting(_key);
    return raw == null
        ? null
        : PaperBuddyConfig.fromJson((raw as Map).cast<String, Object?>());
  }

  /// What the admin screen shows; never the token.
  Map<String, Object?> info() {
    final c = config;
    return {
      'connected': c != null,
      if (c != null) ...{'url': c.url, 'tag': c.tag, 'memberIds': c.memberIds},
      ...?(_setting(_statusKey) as Map?)?.cast<String, Object?>(),
    };
  }

  /// Saves the connection (keeping the stored token if [token] is null) and
  /// syncs right away; null removes it and its documents.
  Future<Map<String, Object?>> configure(Map<String, Object?>? body) async {
    if (body == null) {
      db.execute('DELETE FROM settings WHERE key IN (?, ?)', [
        _key,
        _statusKey,
      ]);
      if (_store(const [])) onChanged();
      return info();
    }
    final token =
        body['token'] is String && (body['token'] as String).isNotEmpty
        ? (body['token'] as String).trim()
        : config?.token;
    if (token == null || token.isEmpty) {
      throw ApiException.badRequest(
        'token_required',
        t('Bitte das Token eines PaperBuddy-Benutzers eintragen.'),
      );
    }
    final c = PaperBuddyConfig(
      url: _url('${body['url'] ?? ''}'),
      token: token,
      tag: switch ('${body['tag'] ?? ''}'.trim()) {
        '' => 'Familie',
        final tag => tag,
      },
      memberIds: [
        for (final m in body['memberIds'] as List? ?? const [])
          if (accounts.byId('$m') != null) '$m',
      ],
    );
    // Only working connections are kept.
    try {
      await _documents(c);
    } on ApiException {
      rethrow;
    } on Exception catch (e) {
      throw ApiException.badRequest(
        'paperbuddy_unreachable',
        t('Keine Verbindung zu PaperBuddy ({error}).', {'error': '$e'}),
      );
    }
    _put(_key, c.toJson());
    await sync();
    return info();
  }

  /// `http(s)://host[:port][/path]` without a trailing slash. PaperBuddy
  /// usually runs in the home network: only admins set it.
  static String _url(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ApiException.badRequest(
        'invalid_url',
        t('Die Adresse von PaperBuddy beginnt mit http:// oder https://.'),
      );
    }
    final text = uri.replace(query: '', fragment: '').toString();
    return text
        .replaceAll(RegExp(r'[?#]+$'), '')
        .replaceAll(RegExp(r'/+$'), '');
  }

  /// Fetches the tagged documents and their deadlines; runs never overlap.
  Future<void> sync() =>
      _running ??= _sync().whenComplete(() => _running = null);

  Future<void> _sync() async {
    final c = config;
    if (c == null) return;
    try {
      final documents = await _documents(c);
      if (_store(documents, config: c)) onChanged();
      _put(_statusKey, {
        'lastSync': DateTime.now().toUtc().toIso8601String(),
        'count': documents.length,
        'lastError': null,
      });
    } on ApiException catch (e) {
      _status(e.message);
    } on Exception catch (e) {
      _status(t('Keine Verbindung zu PaperBuddy ({error}).', {'error': '$e'}));
    }
  }

  void _status(String error) => _put(_statusKey, {
    ...?(_setting(_statusKey) as Map?)?.cast<String, Object?>(),
    'lastError': error,
  });

  // --- PaperBuddy API ------------------------------------------------------

  Map<String, String> _headers(PaperBuddyConfig c) => {
    'authorization': 'Token ${c.token}',
    'accept': 'application/json; version=9',
  };

  Future<Map<String, Object?>> _get(PaperBuddyConfig c, Uri url) async {
    final response = await _http
        .get(url, headers: _headers(c))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ApiException.badRequest(
        'paperbuddy_denied',
        t('PaperBuddy lehnt das Token ab.'),
      );
    }
    if (response.statusCode != 200) {
      throw ApiException.badRequest(
        'paperbuddy_error',
        t('PaperBuddy antwortet mit Fehler {status}.', {
          'status': response.statusCode,
        }),
      );
    }
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map) return json.cast();
    } on FormatException {
      // Below.
    }
    throw ApiException.badRequest(
      'paperbuddy_error',
      t('Unter dieser Adresse antwortet kein PaperBuddy.'),
    );
  }

  /// All pages of a list.
  Future<List<Map<String, Object?>>> _all(
    PaperBuddyConfig c,
    String path,
    Map<String, String> query,
  ) async {
    final out = <Map<String, Object?>>[];
    Uri? next = Uri.parse(
      '${c.url}$path',
    ).replace(queryParameters: {...query, 'page_size': '100'});
    for (var page = 0; next != null && page < 50; page++) {
      final json = await _get(c, next);
      for (final r in json['results'] as List? ?? const []) {
        if (r is Map) out.add(r.cast());
      }
      final link = json['next'];
      next = link is String && link.isNotEmpty ? Uri.parse(link) : null;
      // Some servers answer with their internal address: keep ours.
      if (next != null) {
        next = Uri.parse(c.url).replace(path: next.path, query: next.query);
      }
    }
    return out;
  }

  Future<List<_Document>> _documents(PaperBuddyConfig c) async {
    final tags = await _all(c, '/api/tags/', {'name__iexact': c.tag});
    final tag = tags
        .where((t) => '${t['name']}'.toLowerCase() == c.tag.toLowerCase())
        .firstOrNull;
    if (tag == null) {
      throw ApiException.badRequest(
        'paperbuddy_tag',
        t('In PaperBuddy gibt es den Tag „{tag}“ nicht.', {'tag': c.tag}),
      );
    }
    final docs = await _all(c, '/api/documents/', {
      'tags__id__all': '${tag['id']}',
      'ordering': '-created',
      'truncate_content': 'true',
    });
    Future<Map<int, String>> names(String path) async => {
      for (final r in await _all(c, path, const {}))
        if (r['id'] is int) r['id'] as int: '${r['name'] ?? ''}',
    };
    final correspondents = await names('/api/correspondents/');
    final types = await names('/api/document_types/');
    // Deadlines are PaperBuddy's own extension; Paperless-ngx has none.
    final due = <int, (String, String)>{};
    try {
      for (final r in await _all(c, '/api/reminders/', {'done': 'false'})) {
        final doc = r['document'];
        final day = '${r['due'] ?? ''}';
        if (doc is! int || day.length < 10) continue;
        final before = due[doc];
        if (before == null || day.compareTo(before.$1) < 0) {
          due[doc] = (day.substring(0, 10), '${r['note'] ?? ''}'.trim());
        }
      }
    } on ApiException {
      // No deadlines then.
    }
    return [
      for (final d in docs)
        if (d['id'] is int)
          _Document(
            id: d['id'] as int,
            title: '${d['title'] ?? ''}',
            created: '${d['created_date'] ?? d['created'] ?? ''}',
            modified: '${d['modified'] ?? ''}',
            fileName:
                (d['archived_file_name'] ?? d['original_file_name'] ?? '')
                    as String,
            mime: d['archived_file_name'] != null
                ? 'application/pdf'
                : '${d['mime_type'] ?? 'application/pdf'}',
            correspondent: correspondents[d['correspondent']] ?? '',
            type: types[d['document_type']] ?? '',
            due: due[d['id']],
          ),
    ];
  }

  // --- Famio records ---------------------------------------------------------

  /// Writes [documents] (and removes the ones no longer tagged); true if
  /// anything changed.
  bool _store(List<_Document> documents, {PaperBuddyConfig? config}) {
    final audience = switch (config?.memberIds ?? const <String>[]) {
      final ids when ids.isNotEmpty => ids,
      _ => [
        for (final m in accounts.members())
          if (m.isAdult) m.id,
      ],
    };
    final wanted = {for (final d in documents) '$idPrefix${d.id}': d};
    return records.writeAsServer([
      for (final MapEntry(key: id, value: d) in wanted.entries)
        SyncRecord(
          collection: Collections.externalDocuments,
          id: id,
          data: {...d.toData(id), SyncRecord.visibilityKey: audience},
          updatedAt: 0,
        ),
      for (final r in records.all(Collections.externalDocuments))
        if (!wanted.containsKey(r.id))
          SyncRecord(
            collection: r.collection,
            id: r.id,
            data: const {},
            updatedAt: 0,
            deleted: true,
          ),
    ]);
  }

  /// The file of the document a member may see: [fileId] as in its record
  /// (it changes with a new version, so apps never show a stale copy).
  Future<http.StreamedResponse?> download(
    String fileId,
    String memberId,
  ) async {
    final c = config;
    final match = RegExp(r'^pb-(\d+)\.').firstMatch(fileId);
    if (c == null || match == null) return null;
    final record = records.get(
      Collections.externalDocuments,
      '$idPrefix${match[1]}',
    );
    if (record == null ||
        record.deleted ||
        !RecordStore.canSee(record, memberId) ||
        FileRef.fromJson(record.data['file'])?.id != fileId) {
      return null;
    }
    final request = http.Request(
      'GET',
      Uri.parse('${c.url}/api/documents/${match[1]}/download/'),
    )..headers.addAll(_headers(c));
    final response = await _http.send(request);
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw ApiException(
        502,
        'paperbuddy_error',
        t('PaperBuddy antwortet mit Fehler {status}.', {
          'status': response.statusCode,
        }),
      );
    }
    return response;
  }

  // --- settings ------------------------------------------------------------

  Object? _setting(String key) {
    final row = db.select('SELECT value FROM settings WHERE key = ?', [
      key,
    ]).firstOrNull;
    return row == null ? null : jsonDecode(row['value'] as String);
  }

  void _put(String key, Object? value) => db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?)'
    ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, jsonEncode(value)],
  );
}

class _Document {
  const _Document({
    required this.id,
    required this.title,
    required this.created,
    required this.modified,
    required this.fileName,
    required this.mime,
    required this.correspondent,
    required this.type,
    this.due,
  });

  final int id;
  final String title;
  final String created;
  final String modified;
  final String fileName;
  final String mime;
  final String correspondent;
  final String type;

  /// The next open deadline: day and note.
  final (String, String)? due;

  /// Famio's category from PaperBuddy's document type.
  DocumentCategory get category {
    final t = type.toLowerCase();
    bool has(List<String> words) => words.any(t.contains);
    if (has(['ausweis', 'pass', 'führerschein', 'identity'])) {
      return DocumentCategory.identity;
    }
    if (has(['arzt', 'befund', 'gesundheit', 'impf', 'kranken', 'rezept'])) {
      return DocumentCategory.health;
    }
    if (has(['schule', 'kita', 'zeugnis', 'kindergarten'])) {
      return DocumentCategory.school;
    }
    if (has(['versicherung', 'police', 'insurance'])) {
      return DocumentCategory.insurance;
    }
    if (has(['steuer', 'rechnung', 'konto', 'bank', 'gehalt', 'lohn'])) {
      return DocumentCategory.finance;
    }
    if (has(['miet', 'haus', 'wohnung', 'nebenkosten', 'grundbuch'])) {
      return DocumentCategory.home;
    }
    if (has(['vertrag', 'kündigung', 'contract'])) {
      return DocumentCategory.contracts;
    }
    return DocumentCategory.other;
  }

  Map<String, Object?> toData(String recordId) {
    final version = modified.replaceAll(RegExp(r'[^0-9]'), '');
    final name = fileName.isEmpty ? '$title.pdf' : fileName;
    return {
      'title': title,
      'category': category.name,
      'file': FileRef(
        id: '$recordId.${version.isEmpty ? '0' : version}',
        name: name,
        mime: mime,
        size: 0,
      ).toJson(),
      'notes': [
        if (correspondent.isNotEmpty) correspondent,
        if (type.isNotEmpty) type,
        if (due?.$2 case final note? when note.isNotEmpty) note,
      ].join(' · '),
      'memberIds': const <String>[],
      'expiresAt': due?.$1,
      'createdAt': created.isEmpty ? null : created,
      'source': 'paperbuddy',
    };
  }
}
