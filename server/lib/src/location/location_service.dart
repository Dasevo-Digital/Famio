import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../accounts.dart';
import '../api_exception.dart';
import '../record_store.dart';

/// Family location sharing: positions from the members' phones, places
/// with arrival/departure notices, pauses protected by the parents' code
/// and a short history that deletes itself.
///
/// Positions are kept for [retention] only. The current position of each
/// member is published to the family as a server-owned record in
/// `Collections.memberLocations`; the history is only served on request.
class LocationService {
  LocationService({
    required this.db,
    required this.records,
    required this.accounts,
    required this.onChanged,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Database db;
  final RecordStore records;
  final Accounts accounts;

  /// Called after records changed, e.g. to notify connected apps.
  final void Function() onChanged;
  final DateTime Function() _clock;

  static const retention = Duration(days: 7);

  /// How often phones report while sharing.
  static const reportInterval = Duration(minutes: 2);

  /// The current position is republished at least this often, so the family
  /// sees the device is alive, and otherwise only on real movement.
  static const _heartbeat = Duration(minutes: 5);
  static const _minMove = 30.0;

  /// Fixes less precise than this never change the place (cell towers).
  static const _placeAccuracy = 250.0;

  static const _codeKey = 'locationCode';

  // --- parents' code ---------------------------------------------------------

  bool get codeSet => _storedCode != null;

  String? get _storedCode {
    final rows = db.select('SELECT value FROM settings WHERE key = ?', [
      _codeKey,
    ]);
    return rows.isEmpty ? null : jsonDecode(rows.first.columnAt(0) as String);
  }

  /// Sets the code parents need to pause sharing; null removes it.
  Future<void> setCode(String? code) async {
    if (code == null || code.isEmpty) {
      db.execute('DELETE FROM settings WHERE key = ?', [_codeKey]);
      return;
    }
    if (!RegExp(r'^\S{4,32}$').hasMatch(code)) {
      throw ApiException.badRequest(
        'invalid_code',
        'Der Code braucht 4 bis 32 Zeichen ohne Leerzeichen',
      );
    }
    final hash = await accounts.hashSecret(code);
    db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?)'
      ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [_codeKey, jsonEncode(hash)],
    );
  }

  Future<bool> checkCode(String code) async {
    final stored = _storedCode;
    if (stored == null) {
      throw ApiException(
        409,
        'no_code',
        'Es ist noch kein Eltern-Code festgelegt. Ein Administrator kann ihn '
            'unter Einstellungen → Server festlegen.',
      );
    }
    return accounts.matchesSecret(code, stored);
  }

  // --- reports ---------------------------------------------------------------

  /// Stores the positions a device measured and returns what it should do.
  LocationReportResult report(
    FamilyMember member, {
    required List<LocationFix> fixes,
    SharingState state = SharingState.active,
    String? device,
    String? platform,
  }) {
    final now = _clock().toUtc();
    var status = _state(member.id);
    if (status.paused &&
        status.pausedUntil != null &&
        !now.isBefore(status.pausedUntil!)) {
      _setPause(member.id, paused: false);
      status = _state(member.id);
    }
    final previous = _current(member.id);

    if (status.paused) {
      _publish(
        member.id,
        previous,
        MemberLocation(
          memberId: member.id,
          state: SharingState.paused,
          latitude: previous?.latitude,
          longitude: previous?.longitude,
          accuracy: previous?.accuracy,
          at: previous?.at,
          lastContact: now,
          pausedUntil: status.pausedUntil,
          placeId: status.placeId,
          placeSince: status.placeSince,
          battery: previous?.battery,
          device: device ?? previous?.device,
          platform: platform ?? previous?.platform,
        ),
      );
      return LocationReportResult(
        paused: true,
        pausedUntil: status.pausedUntil?.toLocal(),
        intervalSeconds: 15 * 60,
      );
    }

    // A schedule is a privacy boundary, not merely a UI preference: while it
    // is inactive, incoming positions are neither stored nor exposed. The
    // phone keeps its existing low-power reporting behaviour. Sharing resumes
    // only with the next server contact, so an old coordinate never becomes
    // visible merely because a window began.
    final schedule = scheduleFor(member.id);
    if (schedule != null && !schedule.activeAt(_clock())) {
      final changed = _publish(
        member.id,
        previous,
        MemberLocation(memberId: member.id, state: SharingState.scheduled),
      );
      if (changed) onChanged();
      return LocationReportResult(
        paused: false,
        intervalSeconds: reportInterval.inSeconds,
      );
    }

    final valid = [
      for (final f in fixes)
        if (f.valid &&
            (f.accuracy ?? 0) <= 5000 &&
            f.at.isAfter(now.subtract(retention)) &&
            f.at.isBefore(now.add(const Duration(minutes: 2))))
          f,
    ]..sort((a, b) => a.at.compareTo(b.at));
    if (valid.isNotEmpty) {
      db.execute('BEGIN');
      try {
        final insert = db.prepare(
          'INSERT OR IGNORE INTO location_points'
          ' (member_id, at, latitude, longitude, accuracy)'
          ' VALUES (?, ?, ?, ?, ?)',
        );
        for (final f in valid) {
          insert.execute([
            member.id,
            f.at.millisecondsSinceEpoch,
            f.latitude,
            f.longitude,
            f.accuracy,
          ]);
        }
        insert.close();
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }

    // Places: every precise fix may enter or leave one, in order.
    var placeId = status.placeId;
    var placeSince = status.placeSince;
    final places = {
      for (final r in records.all(Collections.places))
        r.id: Place.fromRecord(r),
    };
    if (placeId != null && !places.containsKey(placeId)) {
      placeId = null; // The place was deleted.
      placeSince = null;
    }
    final alerts = <LocationAlert>[];
    for (final f in valid) {
      if ((f.accuracy ?? 0) > _placeAccuracy) continue;
      if (status.lastFix != null && !f.at.isAfter(status.lastFix!)) {
        continue; // Already evaluated (sent again after a lost answer).
      }
      final current = placeId == null ? null : places[placeId];
      if (current != null) {
        final distance = distanceMeters(
          f.latitude,
          f.longitude,
          current.latitude,
          current.longitude,
        );
        // Leaving needs a margin, so GPS jitter at the edge stays quiet.
        if (distance <= current.radius + max(50, f.accuracy ?? 0)) continue;
        alerts.add(_alert(member.id, current, arrived: false, at: f.at));
        placeId = null;
        placeSince = null;
      }
      Place? nearest;
      var best = double.infinity;
      for (final p in places.values) {
        final d = distanceMeters(
          f.latitude,
          f.longitude,
          p.latitude,
          p.longitude,
        );
        if (d <= p.radius && d < best) {
          nearest = p;
          best = d;
        }
      }
      if (nearest != null) {
        alerts.add(_alert(member.id, nearest, arrived: true, at: f.at));
        placeId = nearest.id;
        placeSince = f.at;
      }
    }
    final lastFix = valid.lastOrNull?.at;
    if (placeId != status.placeId ||
        (lastFix != null &&
            (status.lastFix == null || lastFix.isAfter(status.lastFix!)))) {
      db.execute(
        'INSERT INTO location_state'
        ' (member_id, place_id, place_since, last_fix) VALUES (?, ?, ?, ?)'
        ' ON CONFLICT(member_id) DO UPDATE SET'
        ' place_id = excluded.place_id, place_since = excluded.place_since,'
        ' last_fix = MAX(COALESCE(last_fix, 0), excluded.last_fix)',
        [
          member.id,
          placeId,
          placeSince?.millisecondsSinceEpoch,
          lastFix?.millisecondsSinceEpoch ??
              status.lastFix?.millisecondsSinceEpoch,
        ],
      );
    }

    final latest = valid.lastOrNull;
    final useLatest =
        latest != null &&
        (previous?.at == null || latest.at.isAfter(previous!.at!.toUtc()));
    final changed = _publish(
      member.id,
      previous,
      MemberLocation(
        memberId: member.id,
        state: state == SharingState.paused ? SharingState.active : state,
        latitude: useLatest ? latest.latitude : previous?.latitude,
        longitude: useLatest ? latest.longitude : previous?.longitude,
        accuracy: useLatest ? latest.accuracy : previous?.accuracy,
        at: useLatest ? latest.at : previous?.at,
        lastContact: now,
        placeId: placeId,
        placeSince: placeSince,
        battery: latest?.battery ?? previous?.battery,
        device: device ?? previous?.device,
        platform: platform ?? previous?.platform,
      ),
    );
    final notified = _sendAlerts(member.id, alerts);
    if (changed || notified) onChanged();
    return LocationReportResult(
      paused: false,
      intervalSeconds: reportInterval.inSeconds,
    );
  }

  LocationAlert _alert(
    String memberId,
    Place place, {
    required bool arrived,
    required DateTime at,
  }) => LocationAlert(
    id: newId(),
    memberId: memberId,
    placeId: place.id,
    placeName: place.name,
    arrived: arrived,
    at: at,
  );

  bool _sendAlerts(String memberId, List<LocationAlert> alerts) {
    if (alerts.isEmpty) return false;
    final places = {
      for (final r in records.all(Collections.places))
        r.id: Place.fromRecord(r),
    };
    return records.writeAsServer([
      for (final a in alerts)
        for (final recipient in places[a.placeId]?.notifyMemberIds ?? [])
          if (recipient != memberId)
            SyncRecord(
              collection: Collections.locationAlerts,
              // One record per recipient, so each sees only their own.
              id: '${a.id}.${recipient.substring(0, min(8, recipient.length))}',
              data: {
                ...a.toData(),
                SyncRecord.visibilityKey: [recipient],
              },
              updatedAt: 0,
            ),
    ]);
  }

  /// The target's time window, or null when sharing is not scheduled.
  LocationSchedule? scheduleFor(String memberId) {
    final row = db.select(
      'SELECT sharing_schedule FROM location_state WHERE member_id = ?',
      [memberId],
    ).firstOrNull;
    final raw = row?['sharing_schedule'] as String?;
    if (raw == null) return null;
    try {
      return LocationSchedule.fromJson((jsonDecode(raw) as Map).cast());
    } on FormatException {
      // A broken legacy value must never accidentally expose a location.
      return null;
    }
  }

  /// Sets or removes a recurring schedule and immediately removes a visible
  /// location if the new schedule is inactive now.
  void setSchedule(String memberId, LocationSchedule? schedule) {
    db.execute(
      'INSERT INTO location_state (member_id, sharing_schedule) VALUES (?, ?)'
      ' ON CONFLICT(member_id) DO UPDATE SET'
      ' sharing_schedule = excluded.sharing_schedule',
      [memberId, schedule == null ? null : jsonEncode(schedule.toJson())],
    );
    if (schedule != null && !schedule.activeAt(_clock())) {
      final previous = _current(memberId);
      final changed = _publish(
        memberId,
        previous,
        MemberLocation(memberId: memberId, state: SharingState.scheduled),
      );
      if (changed) onChanged();
    } else {
      // Removing a schedule must immediately restore the normal sharing
      // state; waiting for the next phone heartbeat would leave the UI stuck
      // on "scheduled".
      _republishState(memberId);
    }
  }

  /// Publishes [next] unless it only differs from [previous] by a small
  /// move or a recent heartbeat. Returns whether anything was written.
  bool _publish(
    String memberId,
    MemberLocation? previous,
    MemberLocation next,
  ) {
    if (previous != null &&
        previous.state == next.state &&
        previous.placeId == next.placeId &&
        previous.pausedUntil == next.pausedUntil &&
        previous.lastContact != null &&
        next.lastContact != null &&
        next.lastContact!.difference(previous.lastContact!) < _heartbeat) {
      final moved = previous.hasPosition && next.hasPosition
          ? distanceMeters(
              previous.latitude!,
              previous.longitude!,
              next.latitude!,
              next.longitude!,
            )
          : (previous.hasPosition == next.hasPosition ? 0 : double.infinity);
      if (moved < _minMove) return false;
    }
    return records.writeAsServer([
      SyncRecord(
        collection: Collections.memberLocations,
        id: memberId,
        data: next.toData(),
        updatedAt: 0,
      ),
    ]);
  }

  MemberLocation? _current(String memberId) {
    final r = records.get(Collections.memberLocations, memberId);
    return r == null || r.deleted ? null : MemberLocation.fromRecord(r);
  }

  // --- pause ---------------------------------------------------------------

  /// Pauses sharing of [memberId] for [duration] (null: until resumed).
  void pause(String memberId, {Duration? duration, required String byMember}) {
    _setPause(
      memberId,
      paused: true,
      until: duration == null ? null : _clock().toUtc().add(duration),
      by: byMember,
    );
    _republishState(memberId);
  }

  void resume(String memberId) {
    _setPause(memberId, paused: false);
    _republishState(memberId);
  }

  /// Whether [memberId] is paused right now (expired pauses end here).
  bool isPaused(String memberId) {
    final s = _state(memberId);
    return s.paused &&
        (s.pausedUntil == null || _clock().toUtc().isBefore(s.pausedUntil!));
  }

  void _setPause(
    String memberId, {
    required bool paused,
    DateTime? until,
    String? by,
  }) => db.execute(
    'INSERT INTO location_state (member_id, paused, paused_until, paused_by)'
    ' VALUES (?, ?, ?, ?) ON CONFLICT(member_id) DO UPDATE SET'
    ' paused = excluded.paused, paused_until = excluded.paused_until,'
    ' paused_by = excluded.paused_by',
    [memberId, paused ? 1 : 0, until?.millisecondsSinceEpoch, by],
  );

  void _republishState(String memberId) {
    final s = _state(memberId);
    final previous = _current(memberId);
    final scheduledOff = scheduleFor(memberId)?.activeAt(_clock()) == false;
    records.writeAsServer([
      SyncRecord(
        collection: Collections.memberLocations,
        id: memberId,
        data: MemberLocation(
          memberId: memberId,
          state: s.paused
              ? SharingState.paused
              : scheduledOff
              ? SharingState.scheduled
              : (previous?.state == SharingState.paused ||
                        previous?.state == SharingState.scheduled
                    ? SharingState.active
                    : previous?.state ?? SharingState.active),
          latitude: scheduledOff ? null : previous?.latitude,
          longitude: scheduledOff ? null : previous?.longitude,
          accuracy: scheduledOff ? null : previous?.accuracy,
          at: scheduledOff ? null : previous?.at,
          lastContact: scheduledOff ? null : previous?.lastContact,
          pausedUntil: s.paused ? s.pausedUntil : null,
          placeId: scheduledOff ? null : s.placeId,
          placeSince: scheduledOff ? null : s.placeSince,
          battery: scheduledOff ? null : previous?.battery,
          device: scheduledOff ? null : previous?.device,
          platform: scheduledOff ? null : previous?.platform,
        ).toData(),
        updatedAt: 0,
      ),
    ]);
    onChanged();
  }

  _State _state(String memberId) {
    final row = db.select('SELECT * FROM location_state WHERE member_id = ?', [
      memberId,
    ]).firstOrNull;
    DateTime? time(Object? ms) => ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms as int, isUtc: true);
    return _State(
      paused: row?['paused'] == 1,
      pausedUntil: time(row?['paused_until']),
      placeId: row?['place_id'] as String?,
      placeSince: time(row?['place_since']),
      lastFix: time(row?['last_fix']),
    );
  }

  // --- history and housekeeping ----------------------------------------------

  /// Positions of [memberId] in `[from, to)`, thinned to at most [limit].
  List<LocationFix> history(
    String memberId, {
    required DateTime from,
    required DateTime to,
    int limit = 3000,
  }) {
    final rows = db.select(
      'SELECT * FROM location_points WHERE member_id = ? AND at >= ? AND at < ?'
      ' ORDER BY at',
      [memberId, from.millisecondsSinceEpoch, to.millisecondsSinceEpoch],
    );
    final step = max(1, (rows.length / limit).ceil());
    return [
      for (var i = 0; i < rows.length; i += step)
        LocationFix(
          latitude: rows[i]['latitude'] as double,
          longitude: rows[i]['longitude'] as double,
          accuracy: rows[i]['accuracy'] as double?,
          at: DateTime.fromMillisecondsSinceEpoch(
            rows[i]['at'] as int,
            isUtc: true,
          ),
        ),
    ];
  }

  /// Deletes positions and notices older than [retention]; returns whether
  /// synced records changed.
  bool collectGarbage({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(retention);
    db.execute('DELETE FROM location_points WHERE at < ?', [
      cutoff.millisecondsSinceEpoch,
    ]);
    final members = {for (final m in accounts.members()) m.id};
    final changed = records.writeAsServer([
      for (final r in records.all(Collections.locationAlerts))
        if (LocationAlert.fromRecord(r).at.isBefore(cutoff) ||
            // About or for somebody no longer in the family.
            !members.contains(LocationAlert.fromRecord(r).memberId) ||
            !(r.visibleTo ?? const []).every(members.contains))
          SyncRecord(
            collection: r.collection,
            id: r.id,
            data: const {},
            deleted: true,
            updatedAt: 0,
          ),
    ]);
    if (changed) onChanged();
    return changed;
  }

  /// Deletes all positions and places reached (all data is deleted).
  void deleteAll() {
    db.execute('DELETE FROM location_points');
    db.execute('DELETE FROM location_state');
  }

  /// Removes everything about a deleted member.
  void memberDeleted(String memberId) {
    db.execute('DELETE FROM location_points WHERE member_id = ?', [memberId]);
    db.execute('DELETE FROM location_state WHERE member_id = ?', [memberId]);
    final located = records.writeAsServer([
      SyncRecord(
        collection: Collections.memberLocations,
        id: memberId,
        data: const {},
        deleted: true,
        updatedAt: 0,
      ),
    ]);
    // Notices about them, and theirs.
    if (!collectGarbage() && located) onChanged();
  }
}

class _State {
  _State({
    required this.paused,
    this.pausedUntil,
    this.placeId,
    this.placeSince,
    this.lastFix,
  });

  /// Newest position already evaluated for places.
  final DateTime? lastFix;
  final bool paused;
  final DateTime? pausedUntil;
  final String? placeId;
  final DateTime? placeSince;
}
