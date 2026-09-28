import 'dart:async';
import 'dart:convert';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

import '../accounts.dart';
import '../api_exception.dart';
import '../record_store.dart';

/// A notification for some members, with and without details.
class PushNotice {
  const PushNotice({
    required this.to,
    required this.title,
    required this.body,
    required this.brief,
    this.tag = 'house',
  });

  final Set<String> to;
  final String title;
  final String body;

  /// Shown instead when the target wants no details.
  final String brief;

  /// ntfy emoji tag.
  final String tag;
}

/// Real push notifications while the apps are closed: the server publishes
/// to each member's ntfy topic (https://ntfy.sh or a self-hosted ntfy),
/// and the ntfy app on the phone shows them.
///
/// Without "details" only a hint like "Neue Nachricht" leaves the server.
class PushService {
  PushService({
    required this._db,
    required this.records,
    required this.accounts,
    required this.location,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Database _db;
  final RecordStore records;
  final Accounts accounts;
  final tz.Location Function() location;
  final http.Client _client;

  /// Sends still running (tests wait for them).
  final _pending = <Future<void>>{};

  Future<void> get idle => Future.wait(_pending.toList());

  // --- targets -------------------------------------------------------------

  List<PushTarget> targets(String memberId) => [
    for (final row in _db.select(
      'SELECT * FROM push_targets WHERE member_id = ? ORDER BY created_at',
      [memberId],
    ))
      _target(row),
  ];

  PushTarget add(
    String memberId, {
    required String name,
    required String url,
    String? token,
    bool details = false,
  }) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        uri.host.isEmpty ||
        uri.pathSegments.where((s) => s.isNotEmpty).isEmpty ||
        uri.hasQuery ||
        uri.userInfo.isNotEmpty) {
      throw ApiException.badRequest(
        'invalid_url',
        'Bitte die Adresse des ntfy-Themas angeben, z. B. '
            'https://ntfy.sh/famio-geheimer-name',
      );
    }
    if (_db
                .select(
                  'SELECT COUNT(*) FROM push_targets WHERE member_id = ?',
                  [memberId],
                )
                .first
                .columnAt(0)
            as int >=
        10) {
      throw ApiException.badRequest('too_many', 'Höchstens 10 Geräte');
    }
    final id = newId();
    _db.execute(
      'INSERT INTO push_targets (id, member_id, name, url, token, details,'
      ' created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        memberId,
        name.trim().isEmpty ? 'Gerät' : name.trim(),
        uri.toString(),
        token == null || token.trim().isEmpty ? null : token.trim(),
        details ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return targets(memberId).firstWhere((t) => t.id == id);
  }

  void remove(String memberId, String id) => _db.execute(
    'DELETE FROM push_targets WHERE member_id = ? AND id = ?',
    [memberId, id],
  );

  /// Sends a test message and returns the error, if any.
  Future<String?> test(String memberId, String id) async {
    final row = _db.select(
      'SELECT * FROM push_targets WHERE member_id = ? AND id = ?',
      [memberId, id],
    );
    if (row.isEmpty) {
      throw ApiException(404, 'not_found', 'Gerät nicht gefunden');
    }
    return _send(
      row.first,
      const PushNotice(
        to: {},
        title: 'Famio',
        body: 'Push-Benachrichtigungen funktionieren 🎉',
        brief: 'Push-Benachrichtigungen funktionieren 🎉',
        tag: 'tada',
      ),
    );
  }

  // --- what happened ----------------------------------------------------------

  /// Changes members synced (see [RecordStore.onStored]).
  void stored(String userId, List<(SyncRecord, SyncRecord?)> changes) {
    final names = {for (final m in accounts.members()) m.id: m.displayName};
    String name(String? id) => names[id] ?? 'Jemand';
    for (final (r, before) in changes) {
      if (r.deleted) continue;
      final fresh = before == null || before.deleted;
      final notice = switch (r.collection) {
        Collections.chatMessages when fresh => _chat(r, userId, name),
        Collections.tasks => _task(r, before, userId),
        Collections.eventComments when fresh => _comment(r, userId, name),
        Collections.events when fresh => _event(r, userId),
        Collections.pointEntries => _points(r, before, userId, name),
        _ => null,
      };
      if (notice != null) deliver(notice, r);
    }
  }

  /// Records the server wrote itself (arrival notices).
  void serverStored(Iterable<SyncRecord> changes) {
    final names = {for (final m in accounts.members()) m.id: m.displayName};
    for (final r in changes) {
      if (r.deleted || r.collection != Collections.locationAlerts) continue;
      final alert = LocationAlert.fromRecord(r);
      final to = r.visibleTo?.toSet() ?? {};
      if (to.isEmpty) continue;
      deliver(
        PushNotice(
          to: to,
          title: 'Famio',
          body: alert.text(names[alert.memberId] ?? 'Jemand'),
          brief: 'Neue Ortsmeldung',
          tag: 'round_pushpin',
        ),
        r,
      );
    }
  }

  PushNotice? _chat(
    SyncRecord r,
    String author,
    String Function(String?) name,
  ) {
    final m = ChatMessage.fromRecord(r);
    final body = m.poll != null
        ? '📊 ${m.poll!.question}'
        : m.text.isNotEmpty
        ? m.text
        : '📎 ${m.attachment?.name ?? 'Anhang'}';
    return PushNotice(
      to: _everyone(r, except: author),
      title: ChatIds.isDirect(m.chatId)
          ? name(author)
          : '${name(author)} · Familie',
      body: body,
      brief: 'Neue Nachricht',
      tag: 'speech_balloon',
    );
  }

  PushNotice? _task(SyncRecord r, SyncRecord? before, String editor) {
    final task = Task.fromRecord(r);
    final assignee = task.assigneeId;
    if (assignee == null || assignee == editor || task.done) return null;
    if (before != null &&
        !before.deleted &&
        before.data['assigneeId'] == assignee) {
      return null;
    }
    return PushNotice(
      to: {assignee},
      title: 'Neue Aufgabe für dich',
      body: task.title,
      brief: 'Neue Aufgabe für dich',
      tag: 'white_check_mark',
    );
  }

  PushNotice? _comment(
    SyncRecord r,
    String author,
    String Function(String?) name,
  ) {
    final c = EventComment.fromRecord(r);
    final eventRecord = records.get(Collections.events, c.eventId);
    if (eventRecord == null || eventRecord.deleted) return null;
    final event = CalendarEvent.fromRecord(eventRecord);
    final to = event.memberIds.isEmpty
        ? _everyone(r, except: author)
        : event.memberIds.toSet().difference({author});
    return PushNotice(
      to: to,
      title: 'Kommentar zu „${event.title}“',
      body: '${name(author)}: ${c.text}',
      brief: 'Neuer Kommentar zu einem Termin',
      tag: 'calendar',
    );
  }

  PushNotice? _event(SyncRecord r, String author) {
    final event = CalendarEvent.fromRecord(r);
    if (event.memberIds.isEmpty || event.sourceId != null) return null;
    final to = event.memberIds.toSet().difference({author});
    if (to.isEmpty) return null;
    return PushNotice(
      to: to,
      title: 'Neuer Termin: ${event.title}',
      body: _when(event),
      brief: 'Neuer Termin für dich',
      tag: 'calendar',
    );
  }

  PushNotice? _points(
    SyncRecord r,
    SyncRecord? before,
    String editor,
    String Function(String?) name,
  ) {
    final e = PointEntry.fromRecord(r);
    final was = before == null || before.deleted
        ? null
        : PointEntry.fromRecord(before).status;
    if (e.status == PointStatus.pending && was != PointStatus.pending) {
      final what = e.kind == PointKind.reward
          ? '${name(e.memberId)} wünscht sich: ${e.title} (${e.points} Punkte)'
          : '${name(e.memberId)}: ${e.title} erledigt (+${e.points})';
      return PushNotice(
        to: accounts.adultIds().toSet().difference({editor}),
        title: 'Bitte bestätigen',
        body: what,
        brief: 'Eine Anfrage bei den Ämtern wartet',
        tag: 'star',
      );
    }
    if (was == PointStatus.pending &&
        e.status != PointStatus.pending &&
        e.memberId != editor) {
      final ok = e.status == PointStatus.approved;
      return PushNotice(
        to: {e.memberId},
        title: ok ? 'Bestätigt 👍' : 'Leider abgelehnt',
        body: e.kind == PointKind.reward
            ? e.title
            : '${e.title} (${ok ? '+' : ''}${e.points} Punkte)',
        brief: ok
            ? 'Deine Anfrage wurde bestätigt'
            : 'Deine Anfrage wurde abgelehnt',
        tag: ok ? 'star' : 'no_entry',
      );
    }
    return null;
  }

  Set<String> _everyone(SyncRecord r, {required String except}) =>
      (r.visibleTo ?? [for (final m in accounts.members()) m.id])
          .toSet()
          .difference({except});

  static const _weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

  String _when(CalendarEvent e) {
    final start = e.allDay ? e.start : tz.TZDateTime.from(e.start, location());
    String two(int n) => n.toString().padLeft(2, '0');
    final day =
        '${_weekdays[start.weekday - 1]}, ${two(start.day)}.${two(start.month)}.';
    return e.allDay
        ? '$day ganztägig'
        : '$day ${two(start.hour)}:${two(start.minute)} Uhr';
  }

  // --- delivery --------------------------------------------------------------

  /// Sends [notice] to the targets of its members who may see [about].
  void deliver(PushNotice notice, SyncRecord about) {
    if (notice.to.isEmpty) return;
    final allowed = [
      for (final id in notice.to)
        if (records.canAccess(about, id)) id,
    ];
    if (allowed.isEmpty) return;
    final rows = _db.select(
      'SELECT * FROM push_targets WHERE member_id IN '
      '(${List.filled(allowed.length, '?').join(', ')})',
      allowed,
    );
    for (final row in rows) {
      late final Future<void> f;
      f = _send(
        row,
        notice,
      ).then((_) {}).whenComplete(() => _pending.remove(f));
      _pending.add(f);
    }
  }

  /// Publishes via ntfy's JSON API; returns the error text, if any.
  Future<String?> _send(Row row, PushNotice notice) async {
    final uri = Uri.parse(row['url'] as String);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final topic = segments.last;
    final base = uri.replace(
      pathSegments: segments.sublist(0, segments.length - 1),
    );
    final details = row['details'] == 1;
    final token = row['token'] as String?;
    String? error;
    try {
      final response = await _client
          .post(
            base.replace(path: base.path.isEmpty ? '/' : base.path),
            headers: {
              'content-type': 'application/json',
              'authorization': ?(token == null ? null : 'Bearer $token'),
            },
            body: jsonEncode({
              'topic': topic,
              'title': details ? notice.title : 'Famio',
              'message': details ? notice.body : notice.brief,
              'tags': [notice.tag],
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode >= 300) {
        error = 'Push-Server antwortet ${response.statusCode}';
      }
    } catch (e) {
      error = 'Push-Server nicht erreichbar';
    }
    _db.execute('UPDATE push_targets SET last_error = ? WHERE id = ?', [
      error,
      row['id'],
    ]);
    return error;
  }

  static PushTarget _target(Row row) => PushTarget(
    id: row['id'] as String,
    name: row['name'] as String,
    url: row['url'] as String,
    details: row['details'] == 1,
    hasToken: row['token'] != null,
    lastError: row['last_error'] as String?,
  );
}
