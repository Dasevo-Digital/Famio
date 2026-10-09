import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

import '../api_exception.dart';
import '../family/repeating_tasks.dart';
import '../record_store.dart';
import 'bring.dart';
import 'list_provider.dart';
import 'ms_todo.dart';
import '../i18n.dart';

/// Keeps Famio's tasks and shopping lists in sync with lists in other apps
/// (Bring!, Microsoft To Do), in both directions. Each member connects their
/// own account and picks which Famio list goes with which list there.
///
/// Per entry the server remembers a fingerprint of the state both sides
/// last agreed on. Whichever side differs from it changed: its state wins
/// and goes to the other side. If both changed, the newer change wins (Famio
/// wins if the other app does not tell when it changed). Deletions travel
/// both ways. Writing the agreed state back prevents echoes.
class ListSync {
  ListSync({
    required this.db,
    required this.records,
    required this.timeZone,
    required this.onChanged,
    required this.enabled,
    this.location,
    http.Client? client,
    this.interval = const Duration(minutes: 5),
    this.providerFor,
    this.bringBase,
    this.graphBase,
    this.loginBase,
    this.log,
  }) : _client = client ?? http.Client();

  final Database db;
  final RecordStore records;

  /// The family's zone, for due dates sent to Microsoft To Do.
  final String Function() timeZone;

  /// Called after Famio data changed.
  final void Function() onChanged;

  /// Whether the family uses list connections at all (server setting).
  final bool Function() enabled;

  /// The family's zone, for advancing repeating tasks ticked off there.
  final tz.Location Function()? location;
  final Duration interval;

  /// Tests replace the providers; otherwise Bring! or Microsoft To Do.
  final ListProvider Function(String kind, Map<String, Object?> credentials)?
  providerFor;
  final Uri? bringBase;
  final Uri? graphBase;
  final Uri? loginBase;

  /// Writes a line to the server log (what a sync did, errors).
  final void Function(String line)? log;
  final http.Client _client;

  Timer? _timer;
  Timer? _poke;
  final _running = <String, Future<void>>{};

  /// Pending Microsoft sign-ins: flow id → member, client id, device code.
  final _deviceLogins =
      <
        String,
        ({
          String memberId,
          String clientId,
          String deviceCode,
          DateTime expires,
        })
      >{};

  static const tasksList = 'tasks';

  void start() {
    _timer ??= Timer.periodic(interval, (_) => syncAll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _poke?.cancel();
  }

  /// Famio tasks or shopping items changed: sync soon (batched).
  void poke() {
    if (!enabled()) return;
    _poke?.cancel();
    _poke = Timer(const Duration(seconds: 5), syncAll);
  }

  Future<void> syncAll() async {
    if (!enabled()) return;
    for (final row in db.select('SELECT id FROM list_accounts')) {
      await syncAccount(row['id'] as String);
    }
  }

  // --- accounts --------------------------------------------------------------

  void _checkEnabled() {
    if (!enabled()) {
      throw ApiException(
        403,
        'lists_disabled',
        t('Listen-Anbindungen sind in der Server-Verwaltung ausgeschaltet.'),
      );
    }
  }

  /// The member's connected accounts with their links and status.
  List<Map<String, Object?>> accounts(String memberId) => [
    for (final row in db.select(
      'SELECT * FROM list_accounts WHERE user_id = ? ORDER BY created_at',
      [memberId],
    ))
      _accountJson(row),
  ];

  Map<String, Object?> _accountJson(Row row) => {
    'id': row['id'],
    'provider': row['provider'],
    'name': row['name'],
    'lastSync': row['last_sync'],
    'lastError': row['last_error'],
    'links': [
      for (final l in db.select(
        'SELECT famio_list, remote_list, remote_name FROM list_links'
        ' WHERE account_id = ? ORDER BY famio_list',
        [row['id']],
      ))
        {
          'famioList': l['famio_list'],
          'remoteList': l['remote_list'],
          'remoteName': l['remote_name'],
        },
    ],
  };

  Row _account(String id, String memberId) {
    final row = db.select(
      'SELECT * FROM list_accounts WHERE id = ? AND user_id = ?',
      [id, memberId],
    ).firstOrNull;
    if (row == null) {
      throw ApiException(404, 'not_found', t('Verbindung nicht gefunden'));
    }
    return row;
  }

  Map<String, Object?> _store(
    String memberId,
    String provider,
    String name,
    Map<String, Object?> credentials,
  ) {
    final id = newId();
    db.execute(
      'INSERT INTO list_accounts (id, user_id, provider, name, credentials,'
      ' created_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        id,
        memberId,
        provider,
        name,
        jsonEncode(credentials),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return _accountJson(
      db.select('SELECT * FROM list_accounts WHERE id = ?', [id]).first,
    );
  }

  Future<Map<String, Object?>> connectBring(
    String memberId, {
    required String email,
    required String password,
  }) async {
    _checkEnabled();
    try {
      final credentials = await BringProvider.signIn(
        _client,
        email: email.trim(),
        password: password,
        base: bringBase,
      );
      return _store(memberId, 'bring', 'Bring! (${email.trim()})', credentials);
    } on ListProviderException catch (e) {
      throw ApiException(400, 'provider_error', e.message);
    }
  }

  /// First step of signing in to Microsoft: what the member has to do.
  Future<Map<String, Object?>> startMicrosoft(
    String memberId, {
    required String clientId,
  }) async {
    _checkEnabled();
    final id = clientId.trim();
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)) {
      throw ApiException.badRequest(
        'invalid_client_id',
        t(
          'Die Client-ID (Anwendungs-ID) hat die Form 00000000-0000-0000-0000-000000000000.',
        ),
      );
    }
    try {
      final json = await MsTodoProvider.startDeviceLogin(
        _client,
        clientId: id,
        login: loginBase,
      );
      final flow = newId();
      _deviceLogins.removeWhere((_, f) => f.expires.isBefore(DateTime.now()));
      _deviceLogins[flow] = (
        memberId: memberId,
        clientId: id,
        deviceCode: '${json['device_code']}',
        expires: DateTime.now().add(
          Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 900),
        ),
      );
      return {
        'flow': flow,
        'userCode': json['user_code'],
        'verificationUri': json['verification_uri'],
        'interval': json['interval'] ?? 5,
      };
    } on ListProviderException catch (e) {
      throw ApiException(400, 'provider_error', e.message);
    }
  }

  /// Second step: `{status: pending}` until the member confirmed, then the
  /// new account.
  Future<Map<String, Object?>> pollMicrosoft(
    String memberId,
    String flow,
  ) async {
    final login = _deviceLogins[flow];
    if (login == null || login.memberId != memberId) {
      throw ApiException(404, 'not_found', t('Anmeldung nicht gefunden'));
    }
    try {
      final credentials = await MsTodoProvider.pollDeviceLogin(
        _client,
        clientId: login.clientId,
        deviceCode: login.deviceCode,
        login: loginBase,
      );
      if (credentials == null) return {'status': 'pending'};
      _deviceLogins.remove(flow);
      return {
        'status': 'done',
        'account': _store(memberId, 'mstodo', 'Microsoft To Do', credentials),
      };
    } on ListProviderException catch (e) {
      _deviceLogins.remove(flow);
      throw ApiException(400, 'provider_error', e.message);
    }
  }

  void disconnect(String id, String memberId) {
    _account(id, memberId);
    db.execute('DELETE FROM list_accounts WHERE id = ?', [id]);
  }

  ListProvider _provider(Row account) {
    final kind = account['provider'] as String;
    final credentials = (jsonDecode(account['credentials'] as String) as Map)
        .cast<String, Object?>();
    if (providerFor case final factory?) return factory(kind, credentials);
    return switch (kind) {
      'bring' => BringProvider(_client, credentials, base: bringBase),
      _ => MsTodoProvider(
        _client,
        credentials,
        timeZone: timeZone(),
        graph: graphBase,
        login: loginBase,
      ),
    };
  }

  void _keepCredentials(String id, ListProvider provider) => db.execute(
    'UPDATE list_accounts SET credentials = ? WHERE id = ?',
    [jsonEncode(provider.credentials), id],
  );

  Future<List<Map<String, Object?>>> remoteLists(
    String id,
    String memberId,
  ) async {
    _checkEnabled();
    final account = _account(id, memberId);
    final provider = _provider(account);
    try {
      final lists = await provider.lists();
      _keepCredentials(id, provider);
      return [for (final l in lists) l.toJson()];
    } on ListProviderException catch (e) {
      throw ApiException(400, 'provider_error', e.message);
    }
  }

  /// Which Famio list goes with which list there. [links]: `{famioList:
  /// 'tasks' or a shopping list id, remoteList, remoteName}`.
  void setLinks(String id, String memberId, List<Object?> links) {
    _checkEnabled();
    final account = _account(id, memberId);
    final bring = account['provider'] == 'bring';
    final wanted = <String, (String, String)>{};
    for (final l in links) {
      if (l is! Map) continue;
      final famio = l['famioList'];
      final remote = l['remoteList'];
      if (famio is! String || remote is! String || remote.isEmpty) continue;
      if (famio == tasksList) {
        if (bring) {
          throw ApiException.badRequest(
            'invalid_link',
            t('Bring! kennt nur Einkaufslisten.'),
          );
        }
      } else {
        final list = records.get(Collections.shoppingLists, famio);
        if (list == null ||
            list.deleted ||
            !RecordStore.canSee(list, memberId)) {
          throw ApiException.badRequest(
            'invalid_link',
            t('Diese Einkaufsliste gibt es nicht.'),
          );
        }
      }
      wanted[famio] = (remote, '${l['remoteName'] ?? ''}');
    }
    db.execute('BEGIN');
    try {
      for (final row in db.select(
        'SELECT famio_list, remote_list FROM list_links WHERE account_id = ?',
        [id],
      )) {
        final famio = row['famio_list'] as String;
        if (wanted[famio]?.$1 != row['remote_list']) {
          // Another list there: start over, nothing is deleted.
          db.execute(
            'DELETE FROM list_links WHERE account_id = ? AND famio_list = ?',
            [id, famio],
          );
          db.execute(
            'DELETE FROM list_items WHERE account_id = ? AND famio_list = ?',
            [id, famio],
          );
        }
      }
      for (final MapEntry(key: famio, value: (remote, name))
          in wanted.entries) {
        db.execute(
          'INSERT INTO list_links (account_id, famio_list, remote_list,'
          ' remote_name) VALUES (?, ?, ?, ?) ON CONFLICT DO UPDATE SET'
          ' remote_name = excluded.remote_name',
          [id, famio, remote, name],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // --- syncing ---------------------------------------------------------------

  /// Syncs one account; runs of the same account never overlap.
  /// [report]: log the outcome even if nothing changed (a member asked).
  Future<void> syncAccount(String id, {bool report = false}) {
    final previous = _running[id] ?? Future<void>.value();
    final next = previous.then((_) => _syncAccount(id, report: report));
    _running[id] = next;
    return next.whenComplete(() {
      if (identical(_running[id], next)) _running.remove(id);
    });
  }

  Future<void> _syncAccount(String id, {bool report = false}) async {
    if (!enabled()) return;
    final account = db.select('SELECT * FROM list_accounts WHERE id = ?', [
      id,
    ]).firstOrNull;
    if (account == null) return;
    final memberId = account['user_id'] as String;
    final provider = _provider(account);
    String? error;
    var changed = false;
    final links = db.select('SELECT * FROM list_links WHERE account_id = ?', [
      id,
    ]);
    if (report && links.isEmpty) {
      log?.call('[listen] ${_label(provider)}: keine Liste zugeordnet');
    }
    for (final link in links) {
      final stats = _SyncStats();
      final name = '${_label(provider)} „${link['remote_name']}“';
      try {
        changed |= await _syncLink(
          id,
          memberId,
          provider,
          link['famio_list'] as String,
          link['remote_list'] as String,
          stats,
        );
        if (report || stats.changes > 0) log?.call('[listen] $name: $stats');
      } on ListProviderException catch (e) {
        error = e.message;
        log?.call('[listen] $name: $error');
        if (e.signedOut) break;
      } on http.ClientException catch (e) {
        error = t('Keine Verbindung zu {provider}.', {
          'provider': _label(provider),
        });
        log?.call('[listen] $name: $error (${e.message})');
      }
    }
    _keepCredentials(id, provider);
    db.execute(
      'UPDATE list_accounts SET last_sync = ?, last_error = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, error, id],
    );
    if (changed) onChanged();
  }

  static String _label(ListProvider p) =>
      p.kind == 'bring' ? 'Bring!' : 'Microsoft To Do';

  /// Syncs [famioList] with [remoteList]; true if Famio data changed.
  Future<bool> _syncLink(
    String accountId,
    String memberId,
    ListProvider provider,
    String famioList,
    String remoteList,
    _SyncStats stats,
  ) async {
    final isTasks = famioList == tasksList;
    final collection = isTasks ? Collections.tasks : Collections.shoppingItems;
    if (!isTasks) {
      final list = records.get(Collections.shoppingLists, famioList);
      if (list == null || list.deleted) {
        stats.missing = true;
        return false;
      }
    }

    final remote = {for (final r in await provider.items(remoteList)) r.id: r};
    stats.remote = remote.length;
    final links = {
      for (final row in db.select(
        'SELECT item_id, remote_id, hash FROM list_items'
        ' WHERE account_id = ? AND famio_list = ?',
        [accountId, famioList],
      ))
        row['item_id'] as String: (
          remote: row['remote_id'] as String,
          hash: row['hash'] as String,
        ),
    };
    final famio = {
      for (final r in records.all(collection, visibleToMember: memberId))
        if (isTasks || r.data['listId'] == famioList) r.id: r,
    };
    stats.famio = famio.length;
    final dueDates = isTasks && provider.hasDueDates;

    String hashOf(_State? s) => s == null ? '' : s.hash;
    _State? famioState(SyncRecord? r) =>
        r == null || r.deleted ? null : _State.ofRecord(r, isTasks, dueDates);
    _State remoteState(RemoteItem r) => _State.ofRemote(r, dueDates);

    final famioWrites = <SyncRecord>[];
    void link(String itemId, String remoteId, _State state) => db.execute(
      'INSERT INTO list_items (account_id, famio_list, item_id, remote_id,'
      ' hash) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO UPDATE SET'
      ' remote_id = excluded.remote_id, hash = excluded.hash',
      [accountId, famioList, itemId, remoteId, state.hash],
    );
    void unlink(String itemId) => db.execute(
      'DELETE FROM list_items WHERE account_id = ? AND famio_list = ?'
      ' AND item_id = ?',
      [accountId, famioList, itemId],
    );
    Future<void> push(String itemId, _State state, RemoteItem? there) async {
      stats.sent++;
      if (there == null) {
        final created = await provider.create(remoteList, state.draft);
        link(itemId, created.id, state);
      } else {
        await provider.update(remoteList, there, state.draft);
        link(itemId, provider.oneEntryPerTitle ? state.title : there.id, state);
      }
    }

    void pull(String itemId, RemoteItem there) {
      stats.taken++;
      final previous = records.get(collection, itemId);
      famioWrites.add(
        _record(collection, itemId, there, previous, famioList, isTasks),
      );
      link(itemId, there.id, remoteState(there));
    }

    final linkedRemote = <String>{};
    for (final MapEntry(key: itemId, value: l) in links.entries) {
      final record = famio[itemId] ?? records.get(collection, itemId);
      // No longer visible to this member: neither sent nor deleted.
      if (record != null &&
          !record.deleted &&
          !RecordStore.canSee(record, memberId)) {
        continue;
      }
      final here = famioState(
        record != null && (isTasks || record.data['listId'] == famioList)
            ? record
            : null,
      );
      final there = remote[l.remote];
      linkedRemote.add(l.remote);
      final thereState = there == null ? null : remoteState(there);
      final hereChanged = hashOf(here) != l.hash;
      final thereChanged = hashOf(thereState) != l.hash;
      if (here == null && thereState == null) {
        unlink(itemId);
        continue;
      }
      if (!hereChanged && !thereChanged) continue;
      final famioWins =
          hereChanged &&
          (!thereChanged ||
              there?.modified == null ||
              (record?.updatedAt ?? 0) >=
                  there!.modified!.millisecondsSinceEpoch);
      if (famioWins) {
        if (here == null) {
          await provider.delete(remoteList, there!);
          stats.deleted++;
          unlink(itemId);
        } else {
          await push(itemId, here, there);
        }
      } else if (there == null) {
        if (record != null && !record.deleted) {
          famioWrites.add(_tombstone(record));
          stats.deleted++;
        }
        unlink(itemId);
      } else {
        pull(itemId, there);
      }
    }

    // New on either side. Apps with one entry per name first pair up
    // entries of the same name, so a first sync creates no duplicates.
    // Done entries that are new on one side stay there: otherwise
    // connecting would copy all of Bring's "recently bought" or every
    // completed task over as ticked off clutter.
    final unlinkedRemote = [
      for (final r in remote.values)
        if (!linkedRemote.contains(r.id)) r,
    ];
    final byTitle = <String, RemoteItem>{
      if (provider.oneEntryPerTitle)
        for (final r in unlinkedRemote) r.title.trim().toLowerCase(): r,
    };
    final paired = <String>{};
    for (final record in famio.values) {
      if (links.containsKey(record.id)) continue;
      final here = famioState(record)!;
      final same = byTitle[here.title.trim().toLowerCase()];
      if (same != null && paired.add(same.id)) {
        // Still needed on one side beats bought long ago on the other.
        if (here.done && !same.done) {
          pull(record.id, same);
        } else {
          await push(record.id, here, same);
        }
      } else if (!here.done) {
        await push(record.id, here, null);
      }
    }
    for (final there in unlinkedRemote) {
      if (paired.contains(there.id) || there.done) continue;
      pull(newId(), there);
    }

    if (famioWrites.isEmpty) return false;
    records.writeAs(memberId, famioWrites);
    if (isTasks) {
      advanceRepeatingTasks(records, [
        for (final w in famioWrites) w.id,
      ], location: location?.call() ?? tz.local);
    }
    return true;
  }

  static SyncRecord _tombstone(SyncRecord r) => SyncRecord(
    collection: r.collection,
    id: r.id,
    data: const {},
    deleted: true,
    updatedAt: _after(r),
  );

  static int _after(SyncRecord? r) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return r == null || r.updatedAt < now ? now : r.updatedAt + 1;
  }

  static SyncRecord _record(
    String collection,
    String id,
    RemoteItem there,
    SyncRecord? previous,
    String famioList,
    bool isTasks,
  ) {
    final live = previous != null && !previous.deleted ? previous : null;
    final Map<String, Object?> data;
    if (isTasks) {
      final task = live == null ? null : Task.fromRecord(live);
      data = (task ?? Task(id: id, title: '', createdAt: DateTime.now()))
          .copyWith(
            title: there.title,
            notes: there.note,
            done: there.done,
            due: there.due ?? (live == null ? null : task!.due),
            completedAt: there.done
                ? (task?.completedAt ?? DateTime.now())
                : null,
          )
          .toData();
    } else {
      final item = live == null ? null : ShoppingItem.fromRecord(live);
      data = ShoppingItem(
        id: id,
        listId: famioList,
        name: there.title,
        quantity: there.note,
        checked: there.done,
        category: item?.category ?? '',
        memberId: item?.memberId,
      ).toData();
    }
    return SyncRecord(
      collection: collection,
      id: id,
      data: {
        ...SyncRecord.keepExternal(data, live),
        SyncRecord.visibilityKey: ?live?.visibleTo,
      },
      updatedAt: _after(previous),
    );
  }
}

/// What one sync of a link did, for the server log.
class _SyncStats {
  int famio = 0;
  int remote = 0;
  int sent = 0;
  int taken = 0;
  int deleted = 0;
  bool missing = false;

  int get changes => sent + taken + deleted;

  @override
  String toString() => missing
      ? t('die Famio-Liste gibt es nicht mehr')
      : t(
          'Famio {famio}, dort {remote} Einträge; {sent} gesendet, {taken} übernommen, {deleted} gelöscht',
          {
            'famio': famio,
            'remote': remote,
            'sent': sent,
            'taken': taken,
            'deleted': deleted,
          },
        );
}

/// What both sides compare: title, note (quantity), done, due day.
class _State {
  _State(this.title, this.note, this.done, this.due);

  factory _State.ofRecord(SyncRecord r, bool isTasks, bool dueDates) {
    if (isTasks) {
      final t = Task.fromRecord(r);
      return _State(t.title, t.notes, t.done, dueDates ? t.due : null);
    }
    final i = ShoppingItem.fromRecord(r);
    return _State(i.name, i.quantity, i.checked, null);
  }

  factory _State.ofRemote(RemoteItem r, bool dueDates) =>
      _State(r.title, r.note, r.done, dueDates ? r.due : null);

  final String title;
  final String note;
  final bool done;
  final DateTime? due;

  String get hash => sha1
      .convert(
        utf8.encode(
          jsonEncode([
            title.trim(),
            note.trim(),
            done,
            due?.toIso8601String().substring(0, 10),
          ]),
        ),
      )
      .toString();

  ItemDraft get draft =>
      ItemDraft(title: title, note: note, done: done, due: due);
}
