import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

import '../api_exception.dart';
import '../calendar/calendar_access.dart';
import '../calendar/event_ics.dart';
import '../calendar/ics_import.dart';
import '../record_store.dart';
import '../remote_url_policy.dart';
import 'dav_client.dart';
import 'google_oauth.dart';
import '../calendar/ics.dart';

/// Keeps Famio events and calendars on other CalDAV servers (iCloud,
/// Nextcloud, mailbox.org …) in sync, in both directions.
///
/// * Famio events a member may see go to their calendar there, except
///   confidential ones (those services store what they get).
/// * Events from there appear in Famio and can be edited in Famio. Events
///   Famio cannot represent exactly (e.g. "every 2nd Tuesday", edited single
///   occurrences) are shown read-only, so nothing gets lost by writing back.
/// * If both sides changed an event, the newer change wins.
class CalDavSync {
  CalDavSync({
    required this.db,
    required this.records,
    required this.location,
    required this.onChanged,
    this.access,
    http.Client? client,
    this.interval = const Duration(minutes: 15),
    GoogleOAuth? google,
    RemoteUrlPolicy? urlPolicy,
  }) : _http = client ?? http.Client() {
    this.google = google ?? GoogleOAuth(_http);
    this.urlPolicy = urlPolicy ?? const RemoteUrlPolicy();
  }

  /// Google accounts use OAuth instead of a password.
  late final GoogleOAuth google;

  final Database db;
  final RecordStore records;

  /// Who sees events coming from an account; null: owner's sharing only.
  final CalendarAccess? access;
  final tz.Location Function() location;

  /// Called after Famio data changed, e.g. to notify connected apps.
  final void Function() onChanged;
  final Duration interval;
  final http.Client _http;
  late final RemoteUrlPolicy urlPolicy;

  /// Remote events that ended longer ago are not imported.
  static const _history = Duration(days: 90);

  /// Read-only events are expanded this far ahead.
  static const _readOnlyWindow = Duration(days: 400);

  /// Prefix of `sourceId` of read-only events from CalDAV accounts.
  static const sourcePrefix = 'caldav:';

  Timer? _timer;
  Timer? _debounce;
  Future<void> _running = Future.value();

  void start() {
    _timer = Timer.periodic(interval, (_) => syncAll());
    _debounce = Timer(const Duration(seconds: 10), syncAll);
  }

  void stop() {
    _timer?.cancel();
    _debounce?.cancel();
    _http.close();
  }

  /// Famio events changed: push them soon.
  void eventsChanged() {
    if (_timer == null) return; // Not started (tests call sync directly).
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), syncAll);
  }

  // --- accounts -------------------------------------------------------------

  Future<List<CalDavCalendarInfo>> discover({
    required String url,
    required String username,
    required String password,
  }) async {
    final start = _normalize(url);
    try {
      final calendars = await DavClient(
        _http,
        username: username,
        password: password,
        verifyUrl: urlPolicy.check,
      ).discover(start);
      if (calendars.isEmpty) {
        throw ApiException.badRequest(
          'no_calendars',
          'Keine Kalender für Termine gefunden',
        );
      }
      return calendars;
    } on DavException catch (e) {
      throw ApiException.badRequest('caldav', e.message);
    }
  }

  List<CalDavAccount> forUser(String userId) => [
    for (final row in db.select(
      'SELECT a.*, (SELECT COUNT(*) FROM caldav_links l'
      "  WHERE l.account_id = a.id AND l.mode != 'ignored') AS linked"
      ' FROM caldav_accounts a WHERE user_id = ? ORDER BY created_at',
      [userId],
    ))
      _account(row),
  ];

  CalDavAccount create(
    String userId, {
    required String name,
    required String serverUrl,
    required String username,
    required String password,
    required String calendarUrl,
    required String calendarName,
    bool onlyMine = false,
    CalendarSharing sharing = const CalendarSharing.family(),
    GoogleGrant? googleGrant,
  }) {
    final calendar = _normalize(calendarUrl);
    if (googleGrant != null) {
      username = googleGrant.email ?? 'Google';
      password = '';
      serverUrl = google.caldavBase.toString();
    } else if (username.trim().isEmpty || password.isEmpty) {
      throw ApiException.badRequest(
        'invalid_login',
        'Benutzername und Passwort angeben',
      );
    }
    final id = newId();
    db.execute(
      'INSERT INTO caldav_accounts (id, user_id, name, server_url, username,'
      ' password, calendar_url, calendar_name, only_mine, private_import,'
      ' created_at, oauth, shared_with)'
      ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        userId,
        name.trim().isEmpty ? calendarName : name.trim(),
        serverUrl.trim(),
        username.trim(),
        password,
        calendar.toString(),
        calendarName,
        onlyMine ? 1 : 0,
        sharing.private ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
        googleGrant == null ? null : jsonEncode(googleGrant.toJson()),
        _sharingJson(sharing, userId),
      ],
    );
    return forUser(userId).firstWhere((a) => a.id == id);
  }

  CalDavAccount update(
    String userId,
    String id, {
    String? password,
    bool? onlyMine,
    CalendarSharing? sharing,
    GoogleGrant? googleGrant,
  }) {
    if (googleGrant != null) {
      db.execute(
        'UPDATE caldav_accounts SET oauth = ? WHERE id = ? AND user_id = ?'
        ' AND oauth IS NOT NULL',
        [jsonEncode(googleGrant.toJson()), id, userId],
      );
    }
    db.execute(
      'UPDATE caldav_accounts SET password = COALESCE(?, password),'
      ' only_mine = COALESCE(?, only_mine), last_error = NULL,'
      ' ctag = NULL WHERE id = ? AND user_id = ?',
      [
        password == null || password.isEmpty ? null : password,
        onlyMine == null ? null : (onlyMine ? 1 : 0),
        id,
        userId,
      ],
    );
    if (sharing != null) {
      db.execute(
        'UPDATE caldav_accounts SET shared_with = ?, private_import = ?'
        ' WHERE id = ? AND user_id = ?',
        [_sharingJson(sharing, userId), sharing.private ? 1 : 0, id, userId],
      );
      if (access?.reapply() ?? false) onChanged();
    }
    final account = forUser(userId).where((a) => a.id == id).firstOrNull;
    if (account == null) {
      throw ApiException(404, 'not_found', 'Verbindung nicht gefunden');
    }
    return account;
  }

  /// Removes the connection. Events that came from there disappear from
  /// Famio; the other calendar keeps everything.
  Future<void> delete(String userId, String id) =>
      _running = _running.then((_) {
        final rows = db.select(
          'SELECT 1 FROM caldav_accounts WHERE id = ? AND user_id = ?',
          [id, userId],
        );
        if (rows.isEmpty) return;
        final links = _links(id);
        final changes = <SyncRecord>[];
        for (final link in links.values) {
          if (link.mode == 'sync' && link.origin == 'remote') {
            final r = records.get(Collections.events, link.eventId!);
            if (r != null && !r.deleted) {
              changes.add(_tombstone(r));
            }
          }
        }
        if (changes.isNotEmpty) records.writeAs(userId, changes);
        final removed = records.writeAsServer([
          for (final r in records.all(Collections.externalEvents))
            if ((r.data['sourceId'] as String? ?? '').startsWith(
              '$sourcePrefix$id:',
            ))
              _deleted(r),
        ]);
        db.execute('DELETE FROM caldav_accounts WHERE id = ?', [id]);
        if (changes.isNotEmpty || removed) onChanged();
      });

  /// Forgets all connections without touching the other calendars (all
  /// Famio data is about to be deleted; that must not reach them).
  Future<void> disconnectAll() => _running = _running.then((_) {
    db.execute('DELETE FROM caldav_links');
    db.execute('DELETE FROM caldav_accounts');
  });

  /// Stops one member's connections before their account is removed. Waiting
  /// for the serialized queue prevents an in-flight sync from recreating
  /// calendar data after deletion.
  Future<void> disconnectUser(String userId) => _running = _running.then((_) {
    db.execute('DELETE FROM caldav_accounts WHERE user_id = ?', [userId]);
  });

  /// Syncs one account of [userId] now and returns its state.
  Future<CalDavAccount> syncNow(String userId, String id) async {
    await (_running = _running.then((_) async {
      final row = db.select(
        'SELECT * FROM caldav_accounts WHERE id = ? AND user_id = ?',
        [id, userId],
      ).firstOrNull;
      if (row != null) await _syncGuarded(row);
    }));
    final account = forUser(userId).where((a) => a.id == id).firstOrNull;
    if (account == null) {
      throw ApiException(404, 'not_found', 'Verbindung nicht gefunden');
    }
    return account;
  }

  /// Syncs all accounts, one after the other.
  Future<void> syncAll() => _running = _running.then((_) async {
    for (final row in db.select('SELECT * FROM caldav_accounts')) {
      await _syncGuarded(row);
    }
  });

  Future<void> _syncGuarded(Row row) async {
    final id = row['id'] as String;
    String? error;
    try {
      await _sync(row);
    } on DavException catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Abgleich fehlgeschlagen: $e';
    }
    db.execute(
      'UPDATE caldav_accounts SET last_sync = ?, last_error = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, error, id],
    );
  }

  // --- sync -----------------------------------------------------------------

  Future<void> _sync(Row row) async {
    final accountId = row['id'] as String;
    final owner = row['user_id'] as String;
    final onlyMine = row['only_mine'] == 1;
    final audience = _audience(row);
    final calendar = Uri.parse(row['calendar_url'] as String);
    final client = _client(row);
    final links = _links(accountId);
    var changed = false;

    // 1. Pull, unless the calendar is unchanged since the last time.
    final ctag = await client.changeTag(calendar);
    if (ctag == null || ctag != row['ctag']) {
      final remote = await client.etags(calendar);
      final wanted = [
        for (final MapEntry(key: path, value: etag) in remote.entries)
          if (links[path]?.etag != etag) path,
      ];
      final fetched = await client.fetch(calendar, wanted);
      for (final path in wanted) {
        final item = fetched[path];
        if (item == null) continue;
        changed |= _pull(
          accountId,
          owner,
          path,
          item.$1,
          item.$2,
          links[path],
          audience: audience,
        );
      }
      // Gone on the other side (links as they are now: a resource that
      // turned up under another address was re-linked above).
      for (final link in _links(accountId).values.toList()) {
        if (remote.containsKey(link.path)) continue;
        changed |= _removeLocal(accountId, owner, link);
      }
    }

    // 2. Push Famio changes.
    final current = _links(accountId);
    final byEvent = {
      for (final l in current.values)
        if (l.mode == 'sync' && l.eventId != null) l.eventId!: l,
    };
    var pushed = false;
    final cutoff = DateTime.now().subtract(_history);
    for (final r in records.all(Collections.events)) {
      final link = byEvent.remove(r.id);
      final inScope = _inScope(r, owner, onlyMine);
      if (link == null) {
        if (!inScope) continue;
        final event = CalendarEvent.fromRecord(r);
        if (event.recurrence == null && event.end.isBefore(cutoff)) continue;
        final path = calendar.resolve('${Uri.encodeComponent(r.id)}.ics').path;
        if (current.containsKey(path)) continue; // Linked to another event.
        try {
          final etag = await client.put(
            calendar.resolve(path),
            _ics(r),
            create: true,
          );
          _saveLink(
            accountId,
            path,
            eventId: r.id,
            etag: etag ?? await client.etagOf(calendar.resolve(path)),
            rev: r.rev,
            origin: 'local',
            mode: 'sync',
          );
          pushed = true;
        } on DavConflict {
          // Exists there already; the next pull links it.
        }
      } else if (!inScope) {
        await client.delete(calendar.resolve(link.path), ifMatch: link.etag);
        _dropLink(accountId, link.path);
        pushed = true;
      } else if (r.rev > link.rev) {
        try {
          final etag = await client.put(
            calendar.resolve(link.path),
            _ics(r),
            ifMatch: link.etag,
          );
          _saveLink(
            accountId,
            link.path,
            eventId: r.id,
            etag: etag ?? await client.etagOf(calendar.resolve(link.path)),
            rev: r.rev,
            origin: link.origin,
            mode: 'sync',
          );
          pushed = true;
        } on DavConflict {
          // Changed there meanwhile: the next pull decides who wins.
          db.execute('UPDATE caldav_accounts SET ctag = NULL WHERE id = ?', [
            accountId,
          ]);
          continue;
        }
      }
    }
    // Deleted in Famio.
    for (final link in byEvent.values) {
      await client.delete(calendar.resolve(link.path), ifMatch: link.etag);
      _dropLink(accountId, link.path);
      pushed = true;
    }

    final tag = pushed ? await client.changeTag(calendar) : ctag;
    db.execute('UPDATE caldav_accounts SET ctag = ? WHERE id = ?', [
      tag,
      accountId,
    ]);
    if (changed) onChanged();
  }

  bool _inScope(SyncRecord r, String owner, bool onlyMine) {
    if (r.deleted || !RecordStore.canSee(r, owner)) return false;
    if (r.data['confidential'] == true) return false;
    return !onlyMine || CalendarEvent.fromRecord(r).involves(owner);
  }

  /// Applies one new or changed remote resource. Returns whether Famio data
  /// changed.
  bool _pull(
    String accountId,
    String owner,
    String path,
    String etag,
    String data,
    _Link? link, {
    required List<String>? audience,
  }) {
    final eventId =
        link?.eventId ??
        _eventIdFor(path) ??
        _eventIdForUid(accountId, data) ??
        _remoteId(accountId, path);
    final stored = records.get(Collections.events, eventId);
    final live = stored != null && !stored.deleted;
    final existing = live ? CalendarEvent.fromRecord(stored) : null;
    final parsed = parseEventIcs(
      data,
      id: eventId,
      location: location(),
      existing: existing,
      allowConfidential: false,
    );
    final event = parsed.event;

    if (event == null || parsed.hasOverrides) {
      if (parsed.unsupported == 'Kein Termin (VEVENT) enthalten') {
        _saveLink(
          accountId,
          path,
          etag: etag,
          origin: 'remote',
          mode: 'ignored',
        );
        return link?.mode == 'sync' && _removeLocal(accountId, owner, link!);
      }
      // Shown read-only: Famio would lose details when writing it back.
      var changed = false;
      if (link?.mode == 'sync') {
        changed |= _removeLocal(accountId, owner, link!);
      }
      changed |= _importReadOnly(accountId, path, data, audience);
      _saveLink(
        accountId,
        path,
        etag: etag,
        origin: 'remote',
        mode: 'readonly',
      );
      return changed;
    }

    if (link?.mode == 'readonly') _removeReadOnly(accountId, path);
    if (link == null &&
        !live &&
        event.recurrence == null &&
        event.end.isBefore(DateTime.now().subtract(_history))) {
      _saveLink(accountId, path, etag: etag, origin: 'remote', mode: 'ignored');
      return false;
    }

    // Both sides changed since the last sync: the newer change wins.
    if (live && link != null && stored.rev > link.rev) {
      final remoteTime = parsed.lastModified?.millisecondsSinceEpoch ?? 0;
      if (stored.updatedAt >= remoteTime) {
        // Famio wins: keep the link's revision so the push sends it.
        _saveLink(
          accountId,
          path,
          eventId: eventId,
          etag: etag,
          rev: link.rev,
          origin: link.origin,
          mode: 'sync',
        );
        return false;
      }
    }
    if (live && !RecordStore.canSee(stored, owner)) return false;
    // Events that came from there follow the account's sharing; Famio's own
    // events keep who may see them.
    final fromThere = (link?.origin ?? (live ? 'local' : 'remote')) == 'remote';
    final visibleTo = fromThere ? audience : stored?.visibleTo;
    final record = SyncRecord(
      collection: Collections.events,
      id: eventId,
      data: {...event.toData(), SyncRecord.visibilityKey: ?visibleTo},
      updatedAt: max(
        DateTime.now().millisecondsSinceEpoch,
        (stored?.updatedAt ?? 0) + 1,
      ),
    );
    final unchanged =
        live && jsonEncode(stored.data) == jsonEncode(record.data);
    if (!unchanged) records.writeAs(owner, [record]);
    _saveLink(
      accountId,
      path,
      eventId: eventId,
      etag: etag,
      rev: records.get(Collections.events, eventId)!.rev,
      origin: link?.origin ?? (live ? 'local' : 'remote'),
      mode: 'sync',
    );
    return !unchanged;
  }

  /// The resource was deleted on the other side.
  bool _removeLocal(String accountId, String owner, _Link link) {
    _dropLink(accountId, link.path);
    if (link.mode == 'readonly') return _removeReadOnly(accountId, link.path);
    if (link.mode != 'sync') return false;
    final r = records.get(Collections.events, link.eventId!);
    if (r == null || r.deleted || !RecordStore.canSee(r, owner)) return false;
    records.writeAs(owner, [_tombstone(r)]);
    return true;
  }

  bool _importReadOnly(
    String accountId,
    String path,
    String data,
    List<String>? audience,
  ) {
    final sourceId = _readOnlySource(accountId, path);
    final now = DateTime.now();
    final events = importIcs(
      data,
      sourceId: sourceId,
      fallback: location(),
      from: now.subtract(_history),
      to: now.add(_readOnlyWindow),
    );
    final wanted = {for (final e in events) e.id};
    return records.writeAsServer([
      for (final e in events)
        SyncRecord(
          collection: Collections.externalEvents,
          id: e.id,
          data: {...e.toData(), SyncRecord.visibilityKey: ?audience},
          updatedAt: 0,
        ),
      for (final r in records.all(Collections.externalEvents))
        if (r.data['sourceId'] == sourceId && !wanted.contains(r.id))
          _deleted(r),
    ]);
  }

  bool _removeReadOnly(String accountId, String path) {
    final sourceId = _readOnlySource(accountId, path);
    return records.writeAsServer([
      for (final r in records.all(Collections.externalEvents))
        if (r.data['sourceId'] == sourceId) _deleted(r),
    ]);
  }

  // --- helpers --------------------------------------------------------------

  DavClient _client(Row row) {
    final oauth = row['oauth'] as String?;
    if (oauth == null) {
      return DavClient(
        _http,
        username: row['username'] as String,
        password: row['password'] as String,
        verifyUrl: urlPolicy.check,
      );
    }
    final grant = GoogleGrant.fromJson((jsonDecode(oauth) as Map).cast());
    final id = row['id'] as String;
    return DavClient(
      _http,
      verifyUrl: urlPolicy.check,
      bearer: ({bool force = false}) async {
        final token = await google.accessToken(grant, force: force);
        db.execute('UPDATE caldav_accounts SET oauth = ? WHERE id = ?', [
          jsonEncode(grant.toJson()),
          id,
        ]);
        return token;
      },
    );
  }

  /// A new resource carrying the UID of a Famio event already linked under
  /// another address (some servers, e.g. Google, rename what they get): it
  /// belongs to that event, and the old link is dropped.
  String? _eventIdForUid(String accountId, String data) {
    final uid = parseIcs(data)
        .components('VCALENDAR')
        .firstOrNull
        ?.components('VEVENT')
        .firstOrNull
        ?.property('UID')
        ?.value;
    if (uid == null) return null;
    String? eventId;
    if (uid.endsWith('@famio')) {
      eventId = uid.substring(0, uid.length - 6);
    } else {
      eventId = records
          .all(Collections.events)
          .where((r) => r.data['icalUid'] == uid)
          .firstOrNull
          ?.id;
    }
    if (eventId == null) return null;
    final r = records.get(Collections.events, eventId);
    if (r == null || r.deleted) return null;
    db.execute(
      'DELETE FROM caldav_links WHERE account_id = ? AND event_id = ?',
      [accountId, eventId],
    );
    return eventId;
  }

  String _ics(SyncRecord r) => eventToIcs(
    CalendarEvent.fromRecord(r),
    location: location(),
    updatedAt: r.updatedAt,
  );

  /// Famio events pushed earlier are stored as `<event id>.ics`; if such a
  /// resource shows up unlinked, it belongs to that event.
  String? _eventIdFor(String path) {
    final name = Uri.decodeComponent(path.split('/').last);
    if (!name.endsWith('.ics')) return null;
    final id = name.substring(0, name.length - 4);
    final r = records.get(Collections.events, id);
    return r != null && !r.deleted ? id : null;
  }

  static String _remoteId(String accountId, String path) =>
      sha1.convert(utf8.encode('$accountId|$path')).toString().substring(0, 32);

  static String _readOnlySource(String accountId, String path) =>
      '$sourcePrefix$accountId:'
      '${sha1.convert(utf8.encode(path)).toString().substring(0, 16)}';

  static SyncRecord _tombstone(SyncRecord r) => SyncRecord(
    collection: r.collection,
    id: r.id,
    data: const {},
    deleted: true,
    updatedAt: max(DateTime.now().millisecondsSinceEpoch, r.updatedAt + 1),
  );

  static SyncRecord _deleted(SyncRecord r) => SyncRecord(
    collection: r.collection,
    id: r.id,
    data: const {},
    updatedAt: 0,
    deleted: true,
  );

  Map<String, _Link> _links(String accountId) => {
    for (final row in db.select(
      'SELECT * FROM caldav_links WHERE account_id = ?',
      [accountId],
    ))
      row['href'] as String: _Link(
        row['href'] as String,
        row['event_id'] as String?,
        row['etag'] as String?,
        row['rev'] as int,
        row['origin'] as String,
        row['mode'] as String,
      ),
  };

  void _saveLink(
    String accountId,
    String path, {
    String? eventId,
    String? etag,
    int rev = 0,
    required String origin,
    required String mode,
  }) => db.execute(
    'INSERT OR REPLACE INTO caldav_links'
    ' (account_id, href, event_id, etag, rev, origin, mode)'
    ' VALUES (?, ?, ?, ?, ?, ?, ?)',
    [accountId, path, eventId, etag, rev, origin, mode],
  );

  void _dropLink(String accountId, String path) => db.execute(
    'DELETE FROM caldav_links WHERE account_id = ? AND href = ?',
    [accountId, path],
  );

  static Uri _normalize(String input) {
    var text = input.trim();
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        uri.host.isEmpty) {
      throw ApiException.badRequest(
        'invalid_url',
        'Bitte eine Adresse wie https://caldav.icloud.com angeben',
      );
    }
    return uri;
  }

  static CalendarSharing _sharing(Row row) {
    final json = row['shared_with'] as String?;
    return CalendarSharing.fromJson(json == null ? null : jsonDecode(json));
  }

  /// Stored without the owner, who always sees their own calendar.
  static String? _sharingJson(CalendarSharing sharing, String owner) =>
      sharing.family
      ? null
      : jsonEncode([
          for (final m in sharing.members!)
            if (m != owner) m,
        ]);

  /// Audience of events coming from the account of [row].
  List<String>? _audience(Row row) => switch (access) {
    final access? => access.audience(
      CalendarAccess.caldavSource(row['id'] as String),
    ),
    null => _sharing(row).audience(row['user_id'] as String),
  };

  static CalDavAccount _account(Row row) => CalDavAccount(
    id: row['id'] as String,
    name: row['name'] as String,
    serverUrl: row['server_url'] as String,
    username: row['username'] as String,
    calendarUrl: row['calendar_url'] as String,
    calendarName: row['calendar_name'] as String,
    onlyMine: row['only_mine'] == 1,
    privateImport: _sharing(row).private,
    sharing: _sharing(row),
    lastSync: row['last_sync'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['last_sync'] as int),
    error: row['last_error'] as String?,
    linkedEvents: row['linked'] as int? ?? 0,
    google: row['oauth'] != null,
  );
}

class _Link {
  _Link(this.path, this.eventId, this.etag, this.rev, this.origin, this.mode);

  final String path;
  final String? eventId;
  final String? etag;

  /// Famio revision of the event when it was last in sync.
  final int rev;

  /// Where the event was created first: `remote` or `local` (Famio).
  final String origin;

  /// `sync` (two-way), `readonly` (shown as imported) or `ignored`.
  final String mode;
}
