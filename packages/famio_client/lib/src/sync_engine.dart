import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'local_store.dart';
import 'platform/net.dart';

enum SyncState { idle, syncing, offline, unauthorized }

class SyncStatus {
  const SyncStatus(this.state, {this.lastSync, this.message});

  final SyncState state;
  final DateTime? lastSync;
  final String? message;
}

/// Offline-first data access: every write lands in the [LocalStore] first and
/// is pushed in the background. Remote changes arrive through `/api/sync`,
/// triggered by WebSocket hints, a periodic timer and local writes.
class SyncEngine {
  SyncEngine({
    required this.store,
    required this.api,
    required this.memberId,
    this.pollInterval = const Duration(minutes: 1),
    this.connectedPollInterval = const Duration(minutes: 10),
  }) {
    _clockOffset = int.tryParse(store.getMeta('clockOffset') ?? '') ?? 0;
    final cached = store.getMeta('members');
    if (cached != null) {
      _members = [
        for (final m in jsonDecode(cached) as List)
          FamilyMember.fromJson((m as Map).cast()),
      ];
    }
  }

  final LocalStore store;
  final FamioApiClient api;

  /// The logged-in member, recorded as editor of local changes.
  final String memberId;

  /// How often to sync without the WebSocket (it tells about changes).
  final Duration pollInterval;

  /// Safety net while the WebSocket is up; its hints normally come first.
  final Duration connectedPollInterval;

  static const _pushBatch = 500;

  final _changes = StreamController<Set<String>>.broadcast();
  final _status = StreamController<SyncStatus>.broadcast();

  var _currentStatus = const SyncStatus(SyncState.idle);

  /// Collections the server does not know yet; their edits stay local until
  /// the server is updated (retried on the next app start).
  final _unsupported = <String>{};
  var _clockOffset = 0;
  var _members = <FamilyMember>[];
  Future<void>? _running;
  var _again = false;
  var _started = false;
  Timer? _poll;
  Timer? _reconnect;
  Timer? _debounce;
  WebSocketChannel? _socket;
  var _socketUp = false;
  var _lastSync = DateTime.fromMillisecondsSinceEpoch(0);
  var _reconnectDelay = const Duration(seconds: 2);

  /// Emits the set of collection names whose content changed.
  Stream<Set<String>> get changes => _changes.stream;

  Stream<SyncStatus> get statusChanges => _status.stream;
  SyncStatus get status => _currentStatus;

  /// The family: without service accounts (e.g. Home Assistant), which
  /// only show up as authors ([allMembers]).
  List<FamilyMember> get members => [
    for (final m in _members)
      if (!m.isService || m.id == memberId) m,
  ];

  List<FamilyMember> get allMembers => _members;

  int get lastRev => int.tryParse(store.getMeta('lastRev') ?? '') ?? 0;

  /// Current time on the server's clock, in ms since epoch.
  int get now => DateTime.now().millisecondsSinceEpoch + _clockOffset;

  // --- data access ----------------------------------------------------------

  /// Live (non-deleted) records of [collection].
  Iterable<SyncRecord> records(String collection) =>
      store.all(collection).map((r) => r.record).where((r) => !r.deleted);

  SyncRecord? record(String collection, String id) {
    final r = store.get(collection, id)?.record;
    return r == null || r.deleted ? null : r;
  }

  void put(String collection, String id, Map<String, Object?> data) =>
      _write(collection, id, data, deleted: false);

  void delete(String collection, String id) =>
      _write(collection, id, const {}, deleted: true);

  void _write(
    String collection,
    String id,
    Map<String, Object?> data, {
    required bool deleted,
  }) {
    final existing = store.get(collection, id)?.record;
    // Strictly increasing per record, even if the clock jumps backwards.
    final updatedAt = max(now, (existing?.updatedAt ?? 0) + 1);
    store.put(
      SyncRecord(
        collection: collection,
        id: id,
        data: deleted ? data : SyncRecord.keepExternal(data, existing),
        deleted: deleted,
        updatedAt: updatedAt,
        updatedBy: memberId,
        rev: existing?.rev ?? 0,
      ),
      dirty: true,
    );
    _changes.add({collection});
    // Batch quick successive edits (typing, ticking off items) into one push.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => sync());
  }

  // --- lifecycle ------------------------------------------------------------

  /// Starts background sync: WebSocket hints plus a periodic fallback.
  void start() {
    if (_started) return;
    _started = true;
    _poll = Timer.periodic(pollInterval, (_) {
      if (_socketUp &&
          DateTime.now().difference(_lastSync) < connectedPollInterval) {
        return;
      }
      sync();
    });
    _connect();
    refreshMembers();
    sync();
  }

  /// The app is in the foreground again: the phone may have cut the
  /// WebSocket meanwhile, so catch up now instead of on the next timer.
  void resumed() {
    if (!_started) return;
    if (!_socketUp) {
      _reconnect?.cancel();
      _reconnectDelay = const Duration(seconds: 2);
      if (_socket == null) _connect();
    }
    sync();
  }

  Future<void> stop() async {
    _started = false;
    _poll?.cancel();
    _reconnect?.cancel();
    _debounce?.cancel();
    await _socket?.sink.close();
    _socket = null;
    _socketUp = false;
    await _running;
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
    await _status.close();
  }

  Future<void> refreshMembers() async {
    try {
      _members = await api.members();
      store.setMeta(
        'members',
        jsonEncode([for (final m in _members) m.toJson()]),
      );
      _changes.add({'members'});
    } on ApiError catch (e) {
      if (e.isUnauthorized) _setStatus(SyncState.unauthorized, e.message);
    }
  }

  // --- sync -----------------------------------------------------------------

  /// Pushes local changes and pulls remote ones. Concurrent calls are merged:
  /// a call during a running sync schedules exactly one follow-up run.
  Future<void> sync() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _syncLoop().whenComplete(() => _running = null);
  }

  Future<void> _syncLoop() async {
    do {
      _again = false;
      await _syncOnce();
    } while (_again && _currentStatus.state == SyncState.idle);
  }

  Future<void> _syncOnce() async {
    _setStatus(SyncState.syncing);
    _lastSync = DateTime.now();
    try {
      bool more;
      // Downloading everything (first sync or after a reset): an old
      // revision on the next pages is no reason for another reset.
      var full = lastRev == 0;
      // After a reset: what the server still has, to drop the rest.
      Set<(String, String)>? received;
      do {
        final pushed = _pushable.take(_pushBatch).toList();
        final sentAt = DateTime.now().millisecondsSinceEpoch;
        final response = await api.sync(
          SyncRequest(
            since: lastRev,
            changes: pushed,
            resettable: true,
            full: full,
          ),
        );
        final receivedAt = DateTime.now().millisecondsSinceEpoch;
        _clockOffset = response.serverTime - (sentAt + receivedAt) ~/ 2;
        if (response.reset) {
          full = true;
          received = {};
        }
        if (received != null) {
          for (final r in [...response.changes, ...response.rejected]) {
            received.add((r.collection, r.id));
          }
        }
        _apply(pushed, response);
        _unsupported.addAll(response.unsupported);
        more = response.hasMore || _pushable.isNotEmpty;
        if (!response.hasMore && received != null) {
          _dropMissing(received);
          received = null;
        }
      } while (more);
      lastError = null;
      _setStatus(SyncState.idle, null, DateTime.now());
    } on ApiError catch (e) {
      lastError = e;
      _setStatus(
        e.isUnauthorized ? SyncState.unauthorized : SyncState.offline,
        e.message,
      );
    }
  }

  /// Why the last sync failed, e.g. `two_factor_required`.
  ApiError? lastError;

  Iterable<SyncRecord> get _pushable => store.dirty
      .map((r) => r.record)
      .where((r) => !_unsupported.contains(r.collection));

  void _apply(List<SyncRecord> pushed, SyncResponse response) {
    final changed = <String>{};
    store.transaction(() {
      for (final p in pushed) {
        if (response.unsupported.contains(p.collection)) continue;
        // Only if not edited again while the request was in flight.
        if (store.get(p.collection, p.id)?.record.updatedAt == p.updatedAt) {
          store.markClean(p.collection, p.id);
        }
      }
      for (final remote in [...response.rejected, ...response.changes]) {
        final local = store.get(remote.collection, remote.id);
        if (local != null && local.dirty && _newer(local.record, remote)) {
          continue; // Our pending edit will win on the next push.
        }
        if (remote.deleted) {
          // Nothing to keep of a deleted record.
          if (local != null) store.remove(remote.collection, remote.id);
        } else {
          store.put(remote, dirty: false);
        }
        changed.add(remote.collection);
      }
      store.setMeta('lastRev', '${response.rev}');
      store.setMeta('clockOffset', '$_clockOffset');
    });
    if (changed.isNotEmpty) _changes.add(changed);
  }

  /// After a full download: drops what the server no longer has (its
  /// deletion was cleaned up there), unless it waits to be pushed.
  void _dropMissing(Set<(String, String)> received) {
    final changed = <String>{};
    store.transaction(() {
      for (final (collection, id) in store.keys.toList()) {
        if (received.contains((collection, id))) continue;
        if (store.get(collection, id)?.dirty ?? true) continue;
        store.remove(collection, id);
        changed.add(collection);
      }
    });
    if (changed.isNotEmpty) _changes.add(changed);
  }

  /// Strictly newer under the server's last-writer-wins rule.
  static bool _newer(SyncRecord a, SyncRecord b) =>
      a.winsOver(b) &&
      !(a.updatedAt == b.updatedAt && a.updatedBy == b.updatedBy);

  void _setStatus(SyncState state, [String? message, DateTime? lastSync]) {
    _currentStatus = SyncStatus(
      state,
      lastSync: lastSync ?? _currentStatus.lastSync,
      message: message,
    );
    if (!_status.isClosed) _status.add(_currentStatus);
  }

  // --- websocket ------------------------------------------------------------

  /// While [_connect] waits for a browser ticket.
  var _connecting = false;

  Future<void> _connect() async {
    if (!_started || _connecting) return;
    final WebSocketChannel socket;
    try {
      _connecting = true;
      final Uri url;
      try {
        url = await api.webSocketConnectUrl();
      } finally {
        _connecting = false;
      }
      if (!_started || _socket != null) return;
      socket = platformWebSocket(
        url,
        headers: api.authHeaders,
        pin: api.pinnedCertificate,
        // Notices a dead connection (sleeping laptop, lost Wi-Fi) within a
        // minute, so its hints can replace frequent polling.
        pingInterval: const Duration(seconds: 30),
      );
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _socket = socket;
    socket.ready.then((_) {
      if (_socket == socket) _socketUp = true;
      _reconnectDelay = const Duration(seconds: 2);
    }, onError: (_) {});
    socket.stream.listen(
      (message) {
        final json = jsonDecode(message as String) as Map;
        switch (json['type']) {
          case 'rev' when (json['rev'] as int) != lastRev:
            sync();
          case 'members':
            refreshMembers();
        }
      },
      onDone: _scheduleReconnect,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _scheduleReconnect() {
    _socket = null;
    _socketUp = false;
    if (!_started) return;
    _reconnect?.cancel();
    _reconnect = Timer(_reconnectDelay, _connect);
    _reconnectDelay = Duration(seconds: min(_reconnectDelay.inSeconds * 2, 60));
  }
}
