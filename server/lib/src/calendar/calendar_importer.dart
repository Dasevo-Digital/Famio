import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

import '../record_store.dart';
import 'calendar_access.dart';
import 'ics_import.dart';

/// Keeps `external_events` in line with the members' calendar subscriptions
/// by fetching each ICS address periodically and on every change.
class CalendarImporter {
  CalendarImporter({
    required this.records,
    required this.location,
    required this.onChanged,
    this.access,
    http.Client? client,
    this.interval = const Duration(minutes: 30),
  }) : _http = client ?? http.Client();

  final RecordStore records;

  /// Who sees which subscription's events; null: the whole family.
  final CalendarAccess? access;

  /// The family's time zone for floating times; may change at runtime.
  final tz.Location Function() location;

  /// Called after imported data changed, e.g. to notify connected clients.
  final void Function() onChanged;
  final Duration interval;
  final http.Client _http;

  static const _maxBytes = 10 * 1024 * 1024;
  static const _pastWindow = Duration(days: 90);
  static const _futureWindow = Duration(days: 400);

  /// Re-import even unchanged feeds this often, so the window moves along.
  static const _fullImportEvery = Duration(hours: 12);

  final _etags = <String, (String url, String etag)>{};
  final _lastFull = <String, DateTime>{};
  Timer? _timer;
  Timer? _debounce;
  Future<void> _running = Future.value();

  void start() {
    _timer = Timer.periodic(interval, (_) => refreshAll());
    _debounce = Timer(const Duration(seconds: 3), refreshAll);
  }

  void stop() {
    _timer?.cancel();
    _debounce?.cancel();
    _http.close();
  }

  /// A subscription was added, edited or removed by a client.
  void subscriptionsChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), refreshAll);
  }

  /// Imports all subscriptions and removes data of deleted ones. Runs are
  /// serialised; a call during a run waits for it and then runs again.
  Future<void> refreshAll() => _running = _running.then((_) async {
    final subs = [
      for (final r in records.all(Collections.calendarSubscriptions))
        CalendarSubscription.fromRecord(r),
    ];
    var changed = false;
    for (final sub in subs) {
      changed |= await _import(sub);
    }
    changed |= _removeOrphans({for (final s in subs) s.id});
    // Sharing may have changed without new data (HTTP 304).
    changed |= access?.reapply() ?? false;
    if (changed) onChanged();
  });

  /// Imports one subscription now and returns its new status.
  Future<SubscriptionStatus?> refresh(String id) async {
    await (_running = _running.then((_) async {
      final r = records
          .all(Collections.calendarSubscriptions)
          .where((r) => r.id == id)
          .firstOrNull;
      if (r == null) return;
      _etags.remove(id);
      if (await _import(CalendarSubscription.fromRecord(r))) onChanged();
    }));
    final status = records
        .all(Collections.calendarSyncStatus)
        .where((r) => r.id == id)
        .firstOrNull;
    return status == null ? null : SubscriptionStatus.fromRecord(status);
  }

  Future<bool> _import(CalendarSubscription sub) async {
    final now = DateTime.now();
    String? error;
    var count = _existing(sub.id).length;
    var changed = false;
    try {
      final url = _normalize(sub.url);
      final full =
          now.difference(_lastFull[sub.id] ?? DateTime(0)) > _fullImportEvery;
      final cached = _etags[sub.id];
      final request = http.Request('GET', url)
        ..headers['accept'] = 'text/calendar, */*'
        ..headers['user-agent'] = 'Famio calendar import';
      if (!full && cached != null && cached.$1 == sub.url) {
        request.headers['if-none-match'] = cached.$2;
      }
      final response = await _http
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 304) {
        await response.stream.drain<void>();
      } else if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw _ImportError(switch (response.statusCode) {
          401 || 403 =>
            'Zugriff verweigert (HTTP ${response.statusCode}). '
                'Ist es die geheime/öffentliche ICS-Adresse?',
          404 => 'Kalender nicht gefunden (HTTP 404)',
          final code => 'Abruf fehlgeschlagen (HTTP $code)',
        });
      } else {
        final text = await _readLimited(response.stream);
        if (!text.contains('BEGIN:VCALENDAR')) {
          throw _ImportError(
            'Unter dieser Adresse liegt keine Kalenderdatei (ICS)',
          );
        }
        final events = importIcs(
          text,
          sourceId: sub.id,
          fallback: location(),
          from: now.subtract(_pastWindow),
          to: now.add(_futureWindow),
        );
        changed = _store(sub.id, events);
        count = events.length;
        _lastFull[sub.id] = now;
        final etag = response.headers['etag'];
        if (etag != null) {
          _etags[sub.id] = (sub.url, etag);
        } else {
          _etags.remove(sub.id);
        }
      }
    } on _ImportError catch (e) {
      error = e.message;
    } on TimeoutException {
      error = 'Zeitüberschreitung beim Abruf';
    } on SocketException catch (e) {
      error = 'Server nicht erreichbar (${e.message})';
    } on FormatException catch (e) {
      error = 'Ungültige Adresse oder Daten: ${e.message}';
    } catch (e) {
      error = 'Import fehlgeschlagen: $e';
    }

    final status = SubscriptionStatus(
      id: sub.id,
      lastSync: now,
      error: error,
      eventCount: count,
    );
    final statusChanged = records.writeAsServer([
      SyncRecord(
        collection: Collections.calendarSyncStatus,
        id: sub.id,
        data: {
          ...status.toData(),
          SyncRecord.visibilityKey: ?access?.audience(sub.id),
        },
        updatedAt: 0,
      ),
    ]);
    return statusChanged || changed;
  }

  bool _store(String sourceId, List<CalendarEvent> events) {
    final wanted = {for (final e in events) e.id: e};
    final audience = access?.audience(sourceId);
    return records.writeAsServer([
      for (final e in events)
        SyncRecord(
          collection: Collections.externalEvents,
          id: e.id,
          data: {...e.toData(), SyncRecord.visibilityKey: ?audience},
          updatedAt: 0,
        ),
      for (final r in _existing(sourceId))
        if (!wanted.containsKey(r.id))
          SyncRecord(
            collection: Collections.externalEvents,
            id: r.id,
            data: const {},
            updatedAt: 0,
            deleted: true,
          ),
    ]);
  }

  /// Removes imported events and status of deleted subscriptions.
  bool _removeOrphans(Set<String> subscriptionIds) {
    return records.writeAsServer([
      for (final r in records.all(Collections.externalEvents))
        if (!subscriptionIds.contains(r.data['sourceId']) &&
            // Read-only events of CalDAV accounts are managed there.
            !(r.data['sourceId'] as String? ?? '').startsWith('caldav:'))
          SyncRecord(
            collection: r.collection,
            id: r.id,
            data: const {},
            updatedAt: 0,
            deleted: true,
          ),
      for (final r in records.all(Collections.calendarSyncStatus))
        if (!subscriptionIds.contains(r.id))
          SyncRecord(
            collection: r.collection,
            id: r.id,
            data: const {},
            updatedAt: 0,
            deleted: true,
          ),
    ]);
  }

  List<SyncRecord> _existing(String sourceId) => [
    for (final r in records.all(Collections.externalEvents))
      if (r.data['sourceId'] == sourceId) r,
  ];

  /// Accepts `webcal://` (as Apple and Google share them) and plain https.
  static Uri _normalize(String input) {
    var uri = Uri.parse(input.trim());
    if (uri.scheme == 'webcal' || uri.scheme == 'webcals') {
      uri = uri.replace(scheme: 'https');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https' || uri.host.isEmpty) {
      throw _ImportError('Adresse muss mit https:// oder webcal:// beginnen');
    }
    return uri;
  }

  static Future<String> _readLimited(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      bytes.add(chunk);
      if (bytes.length > _maxBytes) {
        throw _ImportError('Kalenderdatei ist größer als 10 MB');
      }
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
}

class _ImportError implements Exception {
  _ImportError(this.message);

  final String message;
}
