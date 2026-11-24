import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

import '../accounts.dart';
import '../api_exception.dart';
import '../record_store.dart';
import '../i18n.dart';

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
    Duration Function()? retention,
    bool Function()? enabled,
  }) : _clock = clock ?? DateTime.now,
       _retention = retention ?? (() => defaultRetention),
       _enabled = enabled ?? (() => true);

  /// False while an admin has hidden the location module: phones pause and
  /// nothing is kept.
  final bool Function() _enabled;

  final Database db;
  final RecordStore records;
  final Accounts accounts;

  /// Called after records changed, e.g. to notify connected apps.
  final void Function() onChanged;

  /// A member arrived at a place marked as a shop (see [Place.shop]).
  void Function(String memberId, Place place)? onShopArrival;

  /// The battery level of a report that is shared with the family: none
  /// while location is hidden, paused or outside the time window, and
  /// none of a device that does not count (see [report]).
  void Function(FamilyMember member, int battery)? onBattery;
  final DateTime Function() _clock;
  final Duration Function() _retention;

  static const defaultRetention = Duration(days: 7);

  /// The administrator-controlled retention, bounded by [SettingsStore].
  Duration get retention => _retention();

  /// False while an admin has hidden the location module.
  bool get enabled => _enabled();

  /// How often phones report while sharing.
  static const reportInterval = Duration(minutes: 2);

  /// The current position is republished at least this often, so the family
  /// sees the device is alive, and otherwise only on real movement.
  static const _heartbeat = Duration(minutes: 5);
  static const _minMove = 30.0;

  /// Fixes less precise than this never enter a place (cell towers) …
  static const _placeAccuracy = 250.0;

  /// … and leave one only from this far away, plus twice their uncertainty:
  /// an iPhone on the move often reports nothing but cell fixes, and 6 km
  /// away is not at home whatever the accuracy, while 1 km off with ±500 m
  /// may well be a poor fix indoors.
  static const _coarseLeave = 1000.0;

  /// A device sharing its location that has not reported for this long is
  /// silent: an iPhone lying still reports nothing for hours, but not for
  /// days – then the app no longer runs (see [newlySilent]).
  static const silentAfter = Duration(hours: 48);
  static const _silentKey = 'locationSilent';

  /// A second device that reported this recently is named to the family.
  static const _otherDeviceRecent = Duration(hours: 1);

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
        t('Der Code braucht 4 bis 32 Zeichen ohne Leerzeichen'),
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
        t(
          'Es ist noch kein Eltern-Code festgelegt. Ein Administrator kann ihn unter Einstellungen → Server festlegen.',
        ),
      );
    }
    return accounts.matchesSecret(code, stored);
  }

  // --- reports ---------------------------------------------------------------

  /// Stores the positions a device measured and returns what it should do.
  ///
  /// [deviceKey] tells the member's devices apart (the session of the
  /// phone), [enabledAt] is when sharing was switched on there: of several
  /// devices sharing at once only the one switched on last counts (#576).
  LocationReportResult report(
    FamilyMember member, {
    required List<LocationFix> fixes,
    SharingState state = SharingState.active,
    String? device,
    String? platform,
    String? deviceKey,
    DateTime? enabledAt,
  }) {
    final now = _clock().toUtc();
    var status = _state(member.id);
    if (status.paused &&
        status.pausedUntil != null &&
        !now.isBefore(status.pausedUntil!)) {
      _endPause(member.id, status.pausedUntil!);
      status = _state(member.id);
    }
    final previous = _current(member.id);

    // The family switched location off altogether: the phone pauses, and
    // neither this nor the last position stays visible.
    if (!_enabled()) {
      if (_publish(
        member.id,
        previous,
        MemberLocation(
          memberId: member.id,
          state: SharingState.paused,
          lastContact: now,
        ),
      )) {
        onChanged();
      }
      return LocationReportResult(paused: true, intervalSeconds: 15 * 60);
    }

    final paused = status.paused;
    final result = paused
        ? LocationReportResult(
            paused: true,
            pausedUntil: status.pausedUntil?.toLocal(),
            intervalSeconds: 15 * 60,
          )
        : LocationReportResult(
            paused: false,
            intervalSeconds: reportInterval.inSeconds,
          );

    // An old phone at home and the new one along, both sharing: their
    // places would take turns and every report would tell the family of an
    // arrival. Only the device switched on last counts; the family sees
    // that another one shares too (#576).
    final key = deviceKey ?? 'name:${device ?? ''}';
    _noteDevice(
      member.id,
      key: key,
      name: device,
      enabledAt: enabledAt ?? now,
      now: now,
      sentFixes: fixes.isNotEmpty,
    );
    if (_lead(member.id, now)?.key != key) {
      _markOtherDevice(member.id, previous, now);
      return result;
    }

    // A schedule is a privacy boundary, not merely a UI preference: while it
    // is inactive, nothing of the device is exposed. The phone keeps its
    // existing low-power reporting behaviour. Sharing resumes only with the
    // next server contact, so an old coordinate never becomes visible merely
    // because a window began.
    final window = _window(member.id);
    final open = window.activeAt(_clock());

    // A phone that was offline sends what it measured meanwhile: what it
    // measured outside the schedule or during a pause stays private too,
    // what it measured before counts even if it arrives later (#577). Of a
    // schedule changed since, both have to allow it (#398).
    final pauses = _pausesSince(member.id, now.subtract(retention));
    final earlier = _schedulesSince(member.id, now.subtract(retention));
    bool allowedThen(DateTime at) {
      for (final s in earlier) {
        if (!at.isBefore(s.until)) continue;
        final raw = s.schedule;
        if (raw == null) return true;
        try {
          return LocationSchedule.fromJson(
            (jsonDecode(raw) as Map).cast(),
          ).activeAt(_onClock(at));
        } on Object {
          return false; // A broken value never exposes a position.
        }
      }
      return true;
    }

    // Of the pause going on, only what was measured before it began (for
    // pauses begun before that was recorded: nothing).
    final pausedSince = paused ? status.pausedSince : null;
    final valid = [
      for (final f in fixes)
        if (f.valid &&
            (f.accuracy ?? 0) <= 5000 &&
            f.at.isAfter(now.subtract(retention)) &&
            allowedThen(f.at) &&
            f.at.isBefore(now.add(const Duration(minutes: 2))) &&
            window.activeAt(_onClock(f.at)) &&
            (!paused || (pausedSince != null && f.at.isBefore(pausedSince))) &&
            !pauses.any(
              (p) => !f.at.isBefore(p.start) && f.at.isBefore(p.until),
            ))
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
    var placeUnknown = status.placeUnknown;
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
      if (status.lastFix != null && !f.at.isAfter(status.lastFix!)) {
        continue; // Already evaluated (sent again after a lost answer).
      }
      final accuracy = f.accuracy ?? 0;
      final precise = accuracy <= _placeAccuracy;
      if (placeUnknown) {
        // The phone that measured where the member was signed out: the
        // first precise position of this one tells where they are, it is
        // no arrival or departure – nobody moved (#594).
        if (!precise) continue;
        final here = _placeAt(f, places.values);
        placeId = here?.id;
        placeSince = here == null ? null : f.at;
        placeUnknown = false;
        continue;
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
        final margin = precise
            ? max(50.0, accuracy)
            : max(_coarseLeave, 2 * accuracy);
        if (distance <= current.radius + margin) {
          // A smaller place within this one (the Kita in the home street):
          // arriving there counts too; leaving it again comes back here
          // (#577).
          final inner = precise ? _innerPlace(f, current, places.values) : null;
          if (inner == null) continue;
          alerts
            ..add(_alert(member.id, current, arrived: false, at: f.at))
            ..add(_alert(member.id, inner, arrived: true, at: f.at));
          placeId = inner.id;
          placeSince = f.at;
          continue;
        }
        alerts.add(_alert(member.id, current, arrived: false, at: f.at));
        placeId = null;
        placeSince = null;
      }
      if (!precise) continue;
      final nearest = _placeAt(f, places.values);
      if (nearest != null) {
        alerts.add(_alert(member.id, nearest, arrived: true, at: f.at));
        placeId = nearest.id;
        placeSince = f.at;
      }
    }
    final lastFix = valid.lastOrNull?.at;
    if (placeId != status.placeId ||
        placeUnknown != status.placeUnknown ||
        (lastFix != null &&
            (status.lastFix == null || lastFix.isAfter(status.lastFix!)))) {
      db.execute(
        'INSERT INTO location_state'
        ' (member_id, place_id, place_since, last_fix, place_unknown)'
        ' VALUES (?, ?, ?, ?, ?)'
        ' ON CONFLICT(member_id) DO UPDATE SET'
        ' place_id = excluded.place_id, place_since = excluded.place_since,'
        ' last_fix = MAX(COALESCE(last_fix, 0), excluded.last_fix),'
        ' place_unknown = excluded.place_unknown',
        [
          member.id,
          placeId,
          placeSince?.millisecondsSinceEpoch,
          lastFix?.millisecondsSinceEpoch ??
              status.lastFix?.millisecondsSinceEpoch,
          placeUnknown ? 1 : 0,
        ],
      );
    }

    final MemberLocation next;
    if (!open) {
      // Outside the window what was measured inside it is kept and told,
      // but nothing of the device is shown now.
      next = MemberLocation(
        memberId: member.id,
        state: paused ? SharingState.paused : SharingState.scheduled,
        pausedUntil: paused ? status.pausedUntil : null,
      );
    } else {
      final latest = valid.lastOrNull;
      final useLatest =
          latest != null &&
          (previous?.at == null || latest.at.isAfter(previous!.at!.toUtc()));
      final pin = useLatest ? _pinFor(latest, valid, previous) : null;
      next = MemberLocation(
        memberId: member.id,
        state: paused
            ? SharingState.paused
            : state == SharingState.paused
            ? SharingState.active
            : state,
        latitude: pin != null ? pin.latitude : previous?.latitude,
        longitude: pin != null ? pin.longitude : previous?.longitude,
        accuracy: pin != null ? pin.accuracy : previous?.accuracy,
        at: useLatest ? latest.at : previous?.at,
        lastContact: now,
        pausedUntil: paused ? status.pausedUntil : null,
        placeId: placeId,
        placeSince: placeSince,
        battery: paused
            ? previous?.battery
            : latest?.battery ?? previous?.battery,
        device: device ?? previous?.device,
        platform: platform ?? previous?.platform,
        otherDevice: _otherDevice(member.id, key, now),
      );
    }
    final changed = _publish(member.id, previous, next);
    final notified = _sendAlerts(member.id, alerts);
    _arrived(member.id, alerts);
    for (final a in alerts) {
      final place = places[a.placeId];
      if (a.arrived && place != null && place.shop) {
        onShopArrival?.call(member.id, place);
      }
    }
    if (changed || notified) onChanged();
    // The battery as the phone sends it (the stored position is only
    // rewritten after a real move), and only while it is shared.
    if (!paused && open) {
      final battery = [
        for (final f in fixes)
          if (f.battery != null) f.battery!,
      ].lastOrNull;
      if (battery != null) onBattery?.call(member, battery);
    }
    return result;
  }

  /// The place of [places] that holds [f] with the nearest centre, if any.
  Place? _placeAt(LocationFix f, Iterable<Place> places) {
    Place? nearest;
    var best = double.infinity;
    for (final p in places) {
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
    return nearest;
  }

  /// The nearest place smaller than [current] that lies within it and
  /// holds [f], if any.
  Place? _innerPlace(LocationFix f, Place current, Iterable<Place> places) {
    Place? inner;
    var best = double.infinity;
    for (final p in places) {
      if (p.id == current.id || p.radius >= current.radius) continue;
      final apart = distanceMeters(
        p.latitude,
        p.longitude,
        current.latitude,
        current.longitude,
      );
      if (apart > current.radius) continue;
      final d = distanceMeters(
        f.latitude,
        f.longitude,
        p.latitude,
        p.longitude,
      );
      if (d <= p.radius && d < best) {
        inner = p;
        best = d;
      }
    }
    return inner;
  }

  // --- devices ---------------------------------------------------------------

  /// Notes that [key] of [memberId] reported.
  void _noteDevice(
    String memberId, {
    required String key,
    String? name,
    required DateTime enabledAt,
    required DateTime now,
    required bool sentFixes,
  }) {
    final known = db.select(
      'SELECT 1 FROM location_devices WHERE member_id = ? AND device_key = ?',
      [memberId, key],
    ).isNotEmpty;
    if (!known && name != null) {
      // Sharing switched on again gives a phone a new token: what was
      // switched on before under its name is that phone too.
      db.execute(
        'DELETE FROM location_devices'
        ' WHERE member_id = ? AND name = ? AND enabled_at <= ?',
        [memberId, name, enabledAt.millisecondsSinceEpoch],
      );
    }
    db.execute(
      'INSERT INTO location_devices'
      ' (member_id, device_key, name, enabled_at, last_report, sent_fixes)'
      ' VALUES (?, ?, ?, ?, ?, ?)'
      ' ON CONFLICT(member_id, device_key) DO UPDATE SET'
      ' name = COALESCE(excluded.name, name),'
      ' last_report = MAX(last_report, excluded.last_report),'
      ' sent_fixes = MAX(sent_fixes, excluded.sent_fixes)',
      [
        memberId,
        key,
        name,
        enabledAt.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
        sentFixes ? 1 : 0,
      ],
    );
  }

  /// The device of [memberId] that counts: of those that sent positions
  /// within [silentAfter] the one switched on last, so a switch to a new
  /// phone holds while the old one keeps reporting from a drawer. One
  /// silent that long no longer runs (see [newlySilent]) and gives way.
  /// Without any, the device that reported last (e.g. one without GPS).
  ({String key, DateTime lastReport})? _lead(String memberId, DateTime now) {
    final row =
        db.select(
          'SELECT device_key, last_report FROM location_devices'
          ' WHERE member_id = ? AND sent_fixes = 1 AND last_report > ?'
          ' ORDER BY enabled_at DESC, last_report DESC, device_key LIMIT 1',
          [memberId, now.subtract(silentAfter).millisecondsSinceEpoch],
        ).firstOrNull ??
        db.select(
          'SELECT device_key, last_report FROM location_devices'
          ' WHERE member_id = ? ORDER BY last_report DESC, device_key LIMIT 1',
          [memberId],
        ).firstOrNull;
    if (row == null) return null;
    return (
      key: row['device_key'] as String,
      lastReport: DateTime.fromMillisecondsSinceEpoch(
        row['last_report'] as int,
        isUtc: true,
      ),
    );
  }

  /// The name of another device of [memberId] than [leader] that shares
  /// too ('' if it has none), or null.
  String? _otherDevice(String memberId, String? leader, DateTime now) {
    final row = db.select(
      'SELECT name FROM location_devices'
      ' WHERE member_id = ? AND device_key IS NOT ? AND sent_fixes = 1'
      ' AND last_report > ? ORDER BY last_report DESC LIMIT 1',
      [
        memberId,
        leader,
        now.subtract(_otherDeviceRecent).millisecondsSinceEpoch,
      ],
    ).firstOrNull;
    return row == null ? null : row['name'] as String? ?? '';
  }

  /// Keeps the family's note about another sharing device of [memberId]
  /// current. Returns whether it changed.
  bool _markOtherDevice(
    String memberId,
    MemberLocation? previous,
    DateTime now,
  ) {
    // Outside the window nothing of the devices is shown.
    if (previous == null ||
        previous.state == SharingState.scheduled ||
        !_window(memberId).activeAt(_clock())) {
      return false;
    }
    final other = _otherDevice(memberId, _lead(memberId, now)?.key, now);
    if (other == previous.otherDevice) return false;
    final changed = _write(memberId, previous.withOtherDevice(other));
    if (changed) onChanged();
    return changed;
  }

  /// [key] of [memberId] stopped sharing: Famio was signed out on that phone
  /// (it signs its location token out), or the session was signed out
  /// elsewhere (#594). Was it the member's last sharing device, nothing of
  /// their location stays visible and nobody is told two days later that
  /// the phone is silent (#577); a pause stays. Returns the name the
  /// device reported, if known.
  String? deviceSignedOut(String memberId, String key) {
    final now = _clock().toUtc();
    final wasLead = _lead(memberId, now)?.key == key;
    final name =
        db.select(
              'SELECT name FROM location_devices'
              ' WHERE member_id = ? AND device_key = ?',
              [memberId, key],
            ).firstOrNull?['name']
            as String?;
    db.execute(
      'DELETE FROM location_devices WHERE member_id = ? AND device_key = ?',
      [memberId, key],
    );
    if (wasLead) {
      // Where the member is was measured by this phone: another one tells
      // it with its next precise position, without notices of an arrival
      // or departure nobody made (#594).
      db.execute(
        'INSERT INTO location_state (member_id, place_unknown) VALUES (?, 1)'
        ' ON CONFLICT(member_id) DO UPDATE SET place_id = NULL,'
        ' place_since = NULL, place_unknown = 1',
        [memberId],
      );
    }
    final previous = _current(memberId);
    if (previous == null) return name;
    final others = db.select(
      'SELECT 1 FROM location_devices WHERE member_id = ? AND sent_fixes = 1'
      ' AND last_report > ? LIMIT 1',
      [memberId, now.subtract(silentAfter).millisecondsSinceEpoch],
    ).isNotEmpty;
    final bool changed;
    if (others || _state(memberId).paused) {
      final lead = _lead(memberId, now);
      // Outside the window nothing of the devices is shown.
      final outside =
          previous.state == SharingState.scheduled ||
          !_window(memberId).activeAt(_clock());
      var next = previous.withOtherDevice(
        outside ? null : _otherDevice(memberId, lead?.key, now),
      );
      // What this phone measured is no longer shown (#587): another phone
      // reports its own soon, and a pause stays without a position. The
      // last contact is the one of the device that counts now, so the
      // family hears when that one falls silent too (#594).
      if (wasLead || !others) {
        next = next.withoutPosition(
          lastContact: outside ? null : lead?.lastReport,
        );
      }
      changed = _write(memberId, next);
    } else {
      changed = _delete(memberId);
    }
    if (changed) onChanged();
    return name;
  }

  /// Where the map shows the member after [latest], the newest of [fixes].
  ///
  /// Places are decided by precise fixes only, but phones in balanced mode
  /// mostly send coarse Wi-Fi/cell fixes in between (indoors often 1–2 km
  /// off). Such a fix whose uncertainty still covers the last precise
  /// position confirms that position instead of moving the pin, otherwise
  /// the map shows somebody at home while the place says "at work".
  _Pin _pinFor(
    LocationFix latest,
    List<LocationFix> fixes,
    MemberLocation? previous,
  ) {
    final own = (
      latitude: latest.latitude,
      longitude: latest.longitude,
      accuracy: latest.accuracy,
    );
    final coarse = latest.accuracy;
    if (coarse == null || coarse <= _placeAccuracy) return own;
    _Pin? anchor;
    for (final f in fixes.reversed) {
      if (f != latest && (f.accuracy ?? 0) <= _placeAccuracy) {
        anchor = (
          latitude: f.latitude,
          longitude: f.longitude,
          accuracy: f.accuracy,
        );
        break;
      }
    }
    if (anchor == null &&
        previous != null &&
        previous.hasPosition &&
        (previous.accuracy ?? 0) <= _placeAccuracy) {
      anchor = (
        latitude: previous.latitude!,
        longitude: previous.longitude!,
        accuracy: previous.accuracy,
      );
    }
    if (anchor == null) return own;
    final distance = distanceMeters(
      latest.latitude,
      latest.longitude,
      anchor.latitude,
      anchor.longitude,
    );
    return distance <= coarse ? anchor : own;
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

  /// "Bin unterwegs" ends when the member reaches the place it was for.
  void _arrived(String memberId, List<LocationAlert> alerts) {
    final r = records.get(Collections.trips, memberId);
    if (r == null || r.deleted) return;
    final trip = Trip.fromRecord(r);
    // An arrival measured before the trip began (sent late) is not its end
    // (#577); two minutes allow for clocks that differ.
    final since = trip.startedAt.subtract(const Duration(minutes: 2));
    if (!alerts.any(
      (a) => a.arrived && a.placeId == trip.placeId && !a.at.isBefore(since),
    )) {
      return;
    }
    records.writeAsServer([
      SyncRecord(
        collection: Collections.trips,
        id: memberId,
        data: const {},
        deleted: true,
        updatedAt: 0,
      ),
    ]);
  }

  /// The target's time window, or null when sharing is not scheduled.
  /// A stored value that cannot be read gives null here too, but shares
  /// nothing (see [_window]).
  LocationSchedule? scheduleFor(String memberId) => _window(memberId).schedule;

  /// The time window of [memberId] as stored. A value that cannot be read
  /// – broken JSON, or JSON that is no window – must never expose a
  /// location: it shares never (#577).
  _Window _window(String memberId) {
    final row = db.select(
      'SELECT sharing_schedule FROM location_state WHERE member_id = ?',
      [memberId],
    ).firstOrNull;
    final raw = row?['sharing_schedule'] as String?;
    if (raw == null) return _Window.always;
    try {
      return _Window(
        LocationSchedule.fromJson((jsonDecode(raw) as Map).cast()),
      );
    } on Object {
      return _Window.never;
    }
  }

  /// Time moves on without a report: a pause runs out, a time window
  /// closes or opens, a second device stops. The family's view follows
  /// within a minute (the server calls this every minute) instead of with
  /// the phone's next report, which may never come: an iPhone lying still
  /// reports nothing for hours (#576). Returns whether anything changed.
  bool followClock({DateTime? now}) {
    if (!_enabled()) return false;
    final at = (now ?? _clock()).toUtc();
    final local = _onClock(at);
    var changed = false;
    for (final row in db.select(
      'SELECT member_id, paused, paused_until FROM location_state'
      ' WHERE paused = 1 OR sharing_schedule IS NOT NULL',
    )) {
      final id = row['member_id'] as String;
      final paused = row['paused'] == 1;
      final until = switch (row['paused_until']) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        _ => null,
      };
      if (paused && until != null && !at.isBefore(until)) {
        _endPause(id, until);
        _republishState(id, at: at);
        changed = true;
        continue;
      }
      final previous = _current(id);
      if (previous == null) continue;
      if (!_window(id).activeAt(local)) {
        // No position, place, battery or device outside the window, also
        // not while paused.
        changed =
            _write(
              id,
              MemberLocation(
                memberId: id,
                state: paused ? SharingState.paused : SharingState.scheduled,
                pausedUntil: paused ? until : null,
              ),
            ) ||
            changed;
      } else if (!paused && previous.state == SharingState.scheduled) {
        // Sharing again, but no position before the phone sends one; its
        // last contact (also outside the window) tells whether it runs.
        // Without any phone left there is nothing to share (#587).
        final lead = _lead(id, at);
        changed =
            (lead == null
                ? _delete(id)
                : _write(
                    id,
                    MemberLocation(
                      memberId: id,
                      state: SharingState.active,
                      lastContact: lead.lastReport,
                    ),
                  )) ||
            changed;
      }
    }
    // A second device that stopped reporting is no longer named.
    for (final r in records.all(Collections.memberLocations)) {
      if (r.deleted || r.data['otherDevice'] == null) continue;
      final l = MemberLocation.fromRecord(r);
      final other = _otherDevice(l.memberId, _lead(l.memberId, at)?.key, at);
      if (other != l.otherDevice) {
        changed = _write(l.memberId, l.withOtherDevice(other)) || changed;
      }
    }
    if (changed) onChanged();
    return changed;
  }

  bool _delete(String memberId) => records.writeAsServer([
    SyncRecord(
      collection: Collections.memberLocations,
      id: memberId,
      data: const {},
      deleted: true,
      updatedAt: 0,
    ),
  ]);

  bool _write(String memberId, MemberLocation location) =>
      records.writeAsServer([
        SyncRecord(
          collection: Collections.memberLocations,
          id: memberId,
          data: location.toData(),
          updatedAt: 0,
        ),
      ]);

  /// Sets or removes a recurring schedule and immediately removes a visible
  /// location if the new schedule is inactive now.
  void setSchedule(String memberId, LocationSchedule? schedule) {
    final json = schedule == null ? null : jsonEncode(schedule.toJson());
    final before = db.select(
      'SELECT sharing_schedule FROM location_state WHERE member_id = ?',
      [memberId],
    ).firstOrNull?['sharing_schedule'];
    if (before != json) {
      // Kept for positions measured until now and sent later (#398).
      db.execute(
        'INSERT INTO location_schedules (member_id, until, schedule)'
        ' VALUES (?, ?, ?)',
        [memberId, _clock().toUtc().millisecondsSinceEpoch, before],
      );
      db.execute(
        'INSERT INTO location_state (member_id, sharing_schedule) VALUES (?, ?)'
        ' ON CONFLICT(member_id) DO UPDATE SET'
        ' sharing_schedule = excluded.sharing_schedule',
        [memberId, json],
      );
    }
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

  /// The family hid location: no last position, place or battery stays
  /// visible, also of phones that have stopped reporting (the others pause
  /// with their next report). Returns whether anything changed.
  bool followModule() {
    if (_enabled()) return false;
    var changed = false;
    for (final r in records.all(Collections.memberLocations)) {
      if (r.deleted) continue;
      final l = MemberLocation.fromRecord(r);
      if (l.state == SharingState.paused &&
          !l.hasPosition &&
          l.placeId == null &&
          l.battery == null &&
          l.device == null) {
        continue;
      }
      changed =
          records.writeAsServer([
            SyncRecord(
              collection: Collections.memberLocations,
              id: l.memberId,
              data: MemberLocation(
                memberId: l.memberId,
                state: SharingState.paused,
                lastContact: l.lastContact,
              ).toData(),
              updatedAt: 0,
            ),
          ]) ||
          changed;
    }
    if (changed) onChanged();
    return changed;
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
        previous.otherDevice == next.otherDevice &&
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
    final now = _clock().toUtc();
    var was = _state(memberId);
    // A pause that ran out without a report since: it ended then, and the
    // time between is no pause (#398).
    if (was.paused &&
        was.pausedUntil != null &&
        !now.isBefore(was.pausedUntil!)) {
      _endPause(memberId, was.pausedUntil!);
      was = _state(memberId);
    }
    _setPause(
      memberId,
      paused: true,
      until: duration == null ? null : now.add(duration),
      by: byMember,
      // A longer pause keeps its beginning.
      since: was.paused ? was.pausedSince ?? now : now,
    );
    _republishState(memberId);
  }

  void resume(String memberId) {
    final now = _clock().toUtc();
    final s = _state(memberId);
    final until = s.pausedUntil;
    _endPause(memberId, until != null && until.isBefore(now) ? until : now);
    _republishState(memberId);
  }

  /// Ends the pause of [memberId] at [until] and remembers it.
  void _endPause(String memberId, DateTime until) {
    final s = _state(memberId);
    final start = s.pausedSince;
    if (s.paused && start != null && until.isAfter(start)) {
      db.execute(
        'INSERT INTO location_pauses (member_id, start, until) VALUES (?, ?, ?)',
        [memberId, start.millisecondsSinceEpoch, until.millisecondsSinceEpoch],
      );
    }
    _setPause(memberId, paused: false);
  }

  /// Pauses of [memberId] that ended after [from].
  List<({DateTime start, DateTime until})> _pausesSince(
    String memberId,
    DateTime from,
  ) => [
    for (final row in db.select(
      'SELECT start, until FROM location_pauses'
      ' WHERE member_id = ? AND until > ?',
      [memberId, from.millisecondsSinceEpoch],
    ))
      (
        start: DateTime.fromMillisecondsSinceEpoch(
          row['start'] as int,
          isUtc: true,
        ),
        until: DateTime.fromMillisecondsSinceEpoch(
          row['until'] as int,
          isUtc: true,
        ),
      ),
  ];

  /// Schedules (as stored) of [memberId] that applied until a change after
  /// [from], earliest first.
  List<({DateTime until, String? schedule})> _schedulesSince(
    String memberId,
    DateTime from,
  ) => [
    for (final row in db.select(
      'SELECT until, schedule FROM location_schedules'
      ' WHERE member_id = ? AND until > ? ORDER BY until',
      [memberId, from.millisecondsSinceEpoch],
    ))
      (
        until: DateTime.fromMillisecondsSinceEpoch(
          row['until'] as int,
          isUtc: true,
        ),
        schedule: row['schedule'] as String?,
      ),
  ];

  /// [at] on the clock schedules are read on (the family's time zone).
  DateTime _onClock(DateTime at) {
    final now = _clock();
    if (now is tz.TZDateTime) return tz.TZDateTime.from(at, now.location);
    return now.isUtc ? at.toUtc() : at.toLocal();
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
    DateTime? since,
  }) => db.execute(
    'INSERT INTO location_state'
    ' (member_id, paused, paused_until, paused_by, paused_at)'
    ' VALUES (?, ?, ?, ?, ?) ON CONFLICT(member_id) DO UPDATE SET'
    ' paused = excluded.paused, paused_until = excluded.paused_until,'
    ' paused_by = excluded.paused_by, paused_at = excluded.paused_at',
    [
      memberId,
      paused ? 1 : 0,
      until?.millisecondsSinceEpoch,
      by,
      paused ? since?.millisecondsSinceEpoch : null,
    ],
  );

  void _republishState(String memberId, {DateTime? at}) {
    final s = _state(memberId);
    final previous = _current(memberId);
    final scheduledOff = !_window(
      memberId,
    ).activeAt(at == null ? _clock() : _onClock(at));
    final lead = _lead(memberId, (at ?? _clock()).toUtc());
    if (!s.paused && lead == null) {
      // No phone of the member shares any more (the last one signed out
      // during the pause): nothing to show, and no "sharing" entry that
      // never falls silent (#587).
      if (previous != null && _delete(memberId)) onChanged();
      return;
    }
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
          // Without one (its phone signed out), the one that counts now.
          lastContact: scheduledOff
              ? null
              : previous?.lastContact ?? lead?.lastReport,
          pausedUntil: s.paused ? s.pausedUntil : null,
          // No place without a position (the phone that measured it
          // signed out, #587).
          placeId: scheduledOff || previous?.hasPosition != true
              ? null
              : s.placeId,
          placeSince: scheduledOff || previous?.hasPosition != true
              ? null
              : s.placeSince,
          battery: scheduledOff ? null : previous?.battery,
          device: scheduledOff ? null : previous?.device,
          platform: scheduledOff ? null : previous?.platform,
          otherDevice: scheduledOff ? null : previous?.otherDevice,
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
      pausedSince: time(row?['paused_at']),
      placeId: row?['place_id'] as String?,
      placeSince: time(row?['place_since']),
      placeUnknown: row?['place_unknown'] == 1,
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

  /// Members whose sharing is on but whose device has been silent for
  /// [silentAfter], with their last contact – each silence only once; a
  /// report from the device ends it.
  ///
  /// A pause that ran out ends first and a time window that opened shares
  /// again (see [followClock]): a phone that stopped then is silent too
  /// (#577). Outside its window or while paused nobody is told, but a
  /// silence told before stays told.
  List<(FamilyMember, DateTime)> newlySilent({DateTime? now}) {
    // Location is hidden: a phone that stopped reporting is no news.
    if (!_enabled()) return const [];
    now ??= _clock();
    followClock(now: now);
    final rows = db.select('SELECT value FROM settings WHERE key = ?', [
      _silentKey,
    ]);
    final told = rows.isEmpty
        ? const <String, Object?>{}
        : (jsonDecode(rows.first.columnAt(0) as String) as Map)
              .cast<String, Object?>();
    final silent = <String, int>{};
    final fresh = <(FamilyMember, DateTime)>[];
    for (final r in records.all(Collections.memberLocations)) {
      if (r.deleted) continue;
      final l = MemberLocation.fromRecord(r);
      final last = l.lastContact ?? l.at;
      if (l.state != SharingState.active) {
        // Only a report ends a silence, not the window closing.
        if (told[l.memberId] case final int ms) silent[l.memberId] = ms;
        continue;
      }
      if (last == null || now.difference(last) < silentAfter) {
        continue;
      }
      final member = accounts.byId(l.memberId);
      if (member == null) continue;
      silent[l.memberId] = last.millisecondsSinceEpoch;
      if (told[l.memberId] != last.millisecondsSinceEpoch) {
        fresh.add((member, last));
      }
    }
    db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?)'
      ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [_silentKey, jsonEncode(silent)],
    );
    return fresh;
  }

  /// Deletes positions and notices older than [retention]; returns whether
  /// synced records changed.
  bool collectGarbage({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(retention);
    db.execute('DELETE FROM location_points WHERE at < ?', [
      cutoff.millisecondsSinceEpoch,
    ]);
    db.execute('DELETE FROM location_pauses WHERE until < ?', [
      cutoff.millisecondsSinceEpoch,
    ]);
    db.execute('DELETE FROM location_schedules WHERE until < ?', [
      cutoff.millisecondsSinceEpoch,
    ]);
    db.execute('DELETE FROM location_devices WHERE last_report < ?', [
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
    db.execute('DELETE FROM location_pauses');
    db.execute('DELETE FROM location_schedules');
    db.execute('DELETE FROM location_devices');
  }

  /// Removes everything about a deleted member.
  void memberDeleted(String memberId) {
    db.execute('DELETE FROM location_points WHERE member_id = ?', [memberId]);
    db.execute('DELETE FROM location_state WHERE member_id = ?', [memberId]);
    db.execute('DELETE FROM location_pauses WHERE member_id = ?', [memberId]);
    db.execute('DELETE FROM location_schedules WHERE member_id = ?', [
      memberId,
    ]);
    db.execute('DELETE FROM location_devices WHERE member_id = ?', [memberId]);
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
    this.pausedSince,
    this.placeId,
    this.placeSince,
    this.placeUnknown = false,
    this.lastFix,
  });

  /// Newest position already evaluated for places.
  final DateTime? lastFix;
  final bool paused;
  final DateTime? pausedUntil;

  /// When the current pause began (unknown for pauses begun before this
  /// was recorded).
  final DateTime? pausedSince;
  final String? placeId;
  final DateTime? placeSince;

  /// The phone that measured [placeId] signed out: the next precise
  /// position tells it without notices (#594).
  final bool placeUnknown;
}

typedef _Pin = ({double latitude, double longitude, double? accuracy});

/// A member's time window for sharing as stored: none ([always]), one, or
/// a value the server cannot read ([never]).
class _Window {
  const _Window(this.schedule) : _never = false;
  const _Window._never() : schedule = null, _never = true;

  static const always = _Window(null);
  static const never = _Window._never();

  final LocationSchedule? schedule;
  final bool _never;

  bool activeAt(DateTime local) =>
      !_never && (schedule == null || schedule!.activeAt(local));
}
