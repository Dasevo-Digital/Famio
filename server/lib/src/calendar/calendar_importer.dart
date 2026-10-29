import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

import '../record_store.dart';
import '../remote_url_policy.dart';
import 'calendar_access.dart';
import 'ics_import.dart';
import '../i18n.dart';

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
    this.fetchTimeout = const Duration(seconds: 30),
    RemoteUrlPolicy? urlPolicy,
  }) : _http = client ?? http.Client(),
       _urlPolicy = urlPolicy ?? const RemoteUrlPolicy();

  final RecordStore records;

  /// Who sees which subscription's events; null: the whole family.
  final CalendarAccess? access;

  /// The family's time zone for floating times; may change at runtime.
  final tz.Location Function() location;

  /// Called after imported data changed, e.g. to notify connected clients.
  final void Function() onChanged;
  final Duration interval;
  final Duration fetchTimeout;
  final http.Client _http;
  final RemoteUrlPolicy _urlPolicy;

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
      final response = await _get(
        url,
        etag: !full && cached?.$1 == sub.url ? cached?.$2 : null,
      );
      if (response.statusCode == 304) {
      } else if (response.statusCode != 200) {
        throw _ImportError(switch (response.statusCode) {
          401 || 403 => t(
            'Zugriff verweigert (HTTP {status}). Ist es die geheime/öffentliche ICS-Adresse?',
            {'status': response.statusCode},
          ),
          404 => t('Kalender nicht gefunden (HTTP 404)'),
          final code => t('Abruf fehlgeschlagen (HTTP {code})', {'code': code}),
        });
      } else {
        final text = utf8.decode(response.bodyBytes, allowMalformed: true);
        if (!text.contains('BEGIN:VCALENDAR')) {
          throw _ImportError(
            t('Unter dieser Adresse liegt keine Kalenderdatei (ICS)'),
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
      error = t('Zeitüberschreitung beim Abruf');
    } on SocketException catch (e) {
      error = t('Server nicht erreichbar ({message})', {'message': e.message});
    } on FormatException catch (e) {
      error = t('Ungültige Adresse oder Daten: {message}', {
        'message': e.message,
      });
    } catch (e) {
      error = t('Import fehlgeschlagen: {error}', {'error': e});
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
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw _ImportError(
        t('Adresse muss mit https:// oder webcal:// beginnen'),
      );
    }
    return uri;
  }

  /// One budget includes DNS validation, redirects and every response body.
  Future<http.Response> _get(Uri start, {String? etag}) async {
    final cancellation = TransferCancellation();
    final expired = Completer<void>();
    final budget = Timer(fetchTimeout, () {
      cancellation.cancel();
      if (!expired.isCompleted) expired.complete();
    });
    var target = start;
    try {
      for (var hop = 0; hop < 6; hop++) {
        await Future.any<void>([
          _urlPolicy.check(target),
          expired.future.then(
            (_) => throw TimeoutException('Calendar deadline'),
          ),
        ]);
        if (cancellation.cancelled) throw TimeoutException('Calendar deadline');
        final response = await httpTransfer(
          client: _http,
          method: 'GET',
          url: target,
          followRedirects: false,
          timeout: fetchTimeout,
          cancellation: cancellation,
          headers: {
            'accept': 'text/calendar, */*',
            'user-agent': 'Famio calendar import',
            'if-none-match': ?etag,
          },
          consume: (response, stream) async {
            final limit = response.statusCode == 200 ? _maxBytes : 64 * 1024;
            if ((response.contentLength ?? 0) > limit) throw TransferTooLarge();
            return http.Response.bytes(
              await readTransferBytes(stream, maxBytes: limit),
              response.statusCode,
              headers: response.headers,
            );
          },
        );
        final next = response.headers['location'];
        if (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            next != null) {
          target = target.resolve(next);
          continue;
        }
        return response;
      }
      throw _ImportError(t('Zu viele Weiterleitungen beim Kalenderabruf'));
    } on TransferCancelled {
      throw TimeoutException('Calendar deadline');
    } on TransferTooLarge {
      throw _ImportError(t('Kalenderdatei ist größer als 10 MB'));
    } finally {
      budget.cancel();
      cancellation.cancel();
    }
  }
}

class _ImportError implements Exception {
  _ImportError(this.message);

  final String message;
}
