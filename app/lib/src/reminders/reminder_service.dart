import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/birthdays.dart';
import '../data/family_data.dart';
import '../data/kids_logic.dart';
import '../data/pregnancy_logic.dart';
import '../format.dart';
import '../location/location_sharing.dart';
import '../environment.dart';

/// Turns calendar and task reminders into local notifications on this device.
///
/// Android, macOS and Windows get real scheduled notifications that also fire
/// while the app is closed. Linux cannot schedule, so there a timer shows the
/// next reminder while the app is running.
class ReminderService {
  ReminderService._(this._plugin, this._prefs);

  /// Returns null where notifications are unavailable (web, tests, errors).
  static Future<ReminderService?> create(SharedPreferences prefs) async {
    if (kIsWeb) return null;
    final plugin = FlutterLocalNotificationsPlugin();
    try {
      final ok = await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          macOS: DarwinInitializationSettings(),
          linux: LinuxInitializationSettings(defaultActionName: 'Öffnen'),
          windows: WindowsInitializationSettings(
            appName: AppEnv.appName,
            appUserModelId: AppEnv.isDev
                ? 'de.status403.famio.dev'
                : 'de.status403.famio',
            guid: '5b0c7a3e-2f7d-4f5e-9a57-3c1d0d2f6e41',
          ),
        ),
      );
      if (ok == false) return null;
      final android = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.requestNotificationsPermission();
      final exact = await android?.canScheduleExactNotifications() ?? false;
      return ReminderService._(plugin, prefs).._exactAlarms = exact;
    } catch (e) {
      debugPrint('Benachrichtigungen nicht verfügbar: $e');
      return null;
    }
  }

  final FlutterLocalNotificationsPlugin _plugin;
  final SharedPreferences _prefs;
  var _exactAlarms = false;

  static const _window = Duration(days: 14);
  static const _maxScheduled = 48;
  static const _prefsKey = 'reminders.scheduled';

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Erinnerungen',
      channelDescription: 'Termine und Aufgaben',
      importance: Importance.high,
      priority: Priority.high,
      // Lock screen shows only "Famio", not e.g. a child's check-up.
      visibility: NotificationVisibility.private,
    ),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );

  SyncEngine? _engine;
  StreamSubscription<Set<String>>? _sub;
  Timer? _debounce;
  Timer? _refresh;
  Timer? _next;
  final _shown = <String>{};
  Future<void> _pending = Future.value();

  bool get _canSchedule => !Platform.isLinux;

  void attach(SyncEngine engine) {
    detach();
    _engine = engine;
    _chatSeen = DateTime.now();
    _placesSeen = DateTime.now();
    _sub = engine.changes.listen((changed) {
      if (changed.contains(Collections.chatMessages)) _notifyChat(engine);
      if (changed.contains(Collections.locationAlerts)) _notifyPlaces(engine);
      if (changed.any(_scheduledCollections.contains)) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 2), _reschedule);
      }
    });
    // Extend the scheduling window as time passes.
    _refresh = Timer.periodic(const Duration(hours: 6), (_) => _reschedule());
    _reschedule();
  }

  void detach() {
    _sub?.cancel();
    _debounce?.cancel();
    _refresh?.cancel();
    _next?.cancel();
    _engine = null;
  }

  /// Removes everything scheduled for the signed-out member.
  Future<void> clear() async {
    detach();
    await _pending;
    for (final id in _scheduled().keys) {
      await _plugin.cancel(id: id);
    }
    await _prefs.remove(_prefsKey);
  }

  /// Serialised so overlapping triggers cannot interleave cancel/schedule.
  void _reschedule() => _pending = _pending
      .then((_) => _apply())
      .catchError(
        (Object e) => debugPrint('Erinnerungen planen fehlgeschlagen: $e'),
      );

  Future<void> _apply() async {
    final engine = _engine;
    if (engine == null) return;
    final now = DateTime.now();
    final due = [
      ...upcomingReminders(
        events: engine.events,
        tasks: engine.tasks,
        memberId: engine.memberId,
        from: now,
        to: now.add(_window),
        limit: _maxScheduled,
      ),
      ...familyReminders(engine, from: now, to: now.add(_window)),
    ]..sort((a, b) => a.at.compareTo(b.at));
    if (due.length > _maxScheduled) due.removeRange(_maxScheduled, due.length);
    if (_canSchedule) {
      await _schedule(due);
    } else {
      _armTimer(due);
    }
  }

  Future<void> _schedule(List<DueReminder> due) async {
    final previous = _scheduled();
    final wanted = {for (final r in due) r.notificationId: _signature(r)};

    for (final id in previous.keys) {
      if (wanted[id] != previous[id]) await _plugin.cancel(id: id);
    }
    for (final r in due) {
      if (previous[r.notificationId] == wanted[r.notificationId]) continue;
      await _plugin.zonedSchedule(
        id: r.notificationId,
        // Plain UTC instants: we expand repetitions ourselves, so the
        // platform never needs to know the local time zone.
        scheduledDate: tz.TZDateTime.from(r.at.toUtc(), tz.UTC),
        notificationDetails: _details,
        androidScheduleMode: _exactAlarms
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        title: r.title,
        body: _body(r),
      );
    }
    await _prefs.setString(
      _prefsKey,
      jsonEncode({for (final e in wanted.entries) '${e.key}': e.value}),
    );
  }

  void _armTimer(List<DueReminder> due) {
    _next?.cancel();
    final next = due.where((r) => !_shown.contains(r.key)).firstOrNull;
    if (next == null) return;
    _next = Timer(next.at.difference(DateTime.now()), () async {
      _shown.add(next.key);
      await _plugin.show(
        id: next.notificationId,
        title: next.title,
        body: _body(next),
        notificationDetails: _details,
      );
      _reschedule();
    });
  }

  Map<int, String> _scheduled() {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null) return {};
    return {
      for (final e in (jsonDecode(raw) as Map).entries)
        int.parse(e.key as String): e.value as String,
    };
  }

  static String _signature(DueReminder r) =>
      '${r.at.millisecondsSinceEpoch}|${r.title}|${_body(r)}';

  static const _scheduledCollections = {
    Collections.events,
    Collections.tasks,
    Collections.children,
    Collections.childEntries,
    Collections.childLogs,
    Collections.contacts,
    Collections.pregnancies,
    Collections.documents,
  };

  var _chatSeen = DateTime.now();

  /// New messages from others while the app is in the background.
  void _notifyChat(SyncEngine engine) {
    final fresh =
        [
              for (final r in engine.records(Collections.chatMessages))
                ChatMessage.fromRecord(r),
            ]
            .where(
              (m) =>
                  m.authorId != engine.memberId && m.sentAt.isAfter(_chatSeen),
            )
            .toList()
          ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
    if (fresh.isEmpty) return;
    _chatSeen = fresh.last.sentAt;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.resumed) return;
    for (final m in fresh.take(3)) {
      final author = engine.member(m.authorId)?.displayName ?? 'Famio';
      _plugin.show(
        id: DueReminder(
          key: 'chat:${m.id}',
          at: m.sentAt,
          title: '',
        ).notificationId,
        title: ChatIds.isDirect(m.chatId) ? author : '$author · Familie',
        body: m.text.isNotEmpty
            ? m.text
            : '📎 ${m.attachment?.name ?? 'Anhang'}',
        notificationDetails: _chatDetails,
      );
    }
  }

  var _placesSeen = DateTime.now();

  /// "Mia ist bei „Schule“ angekommen" for members who asked for it.
  Future<void> _notifyPlaces(SyncEngine engine) async {
    final fresh = engine.locationAlerts
        .where((a) => a.at.isAfter(_placesSeen))
        .toList()
        .reversed
        .toList();
    if (fresh.isEmpty) return;
    _placesSeen = fresh.last.at;
    // A sharing Android phone gets them from its location service, also
    // with the app closed; it uses the same notification ids.
    if (LocationSharing.supported && (await LocationSharing.status()).enabled) {
      return;
    }
    for (final a in fresh.take(5)) {
      await _plugin.show(
        id: int.tryParse(a.id.substring(0, 7), radix: 16) ?? a.id.hashCode,
        title: AppEnv.appName,
        body: a.text(engine.member(a.memberId)?.displayName ?? 'Jemand'),
        notificationDetails: _placeDetails,
      );
    }
  }

  static const _placeDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'famio_places',
      'Orte',
      channelDescription: 'Wer ist wo angekommen oder losgegangen',
      visibility: NotificationVisibility.private,
    ),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );

  static const _chatDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'chat',
      'Chat',
      channelDescription: 'Neue Nachrichten der Familie',
      importance: Importance.high,
      priority: Priority.high,
      // Lock screen shows only "Famio", not e.g. a child's check-up.
      visibility: NotificationVisibility.private,
    ),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );

  static String _body(DueReminder r) {
    if (r.body != null) return r.body!;
    final o = r.occurrence;
    if (o != null) {
      final when = o.event.allDay
          ? '${dayLabel(o.start)}, ganztägig'
          : dateTimeLabel(o.start);
      final location = o.event.location;
      return location.isEmpty ? when : '$when · $location';
    }
    final due = r.task?.due;
    return due == null ? 'Aufgabe' : 'Aufgabe · fällig ${dayLabel(due)}';
  }
}

/// Reminders beyond calendar and tasks: children's check-ups and
/// vaccinations (for their guardians) and expiring documents.
List<DueReminder> familyReminders(
  SyncEngine engine, {
  required DateTime from,
  required DateTime to,
}) {
  DateTime nineOn(DateTime d) => DateTime(d.year, d.month, d.day, 9);
  final result = <DueReminder>[];
  void add(String key, DateTime at, String title, String body) {
    if (!at.isBefore(from) && at.isBefore(to)) {
      result.add(DueReminder(key: key, at: at, title: title, body: body));
    }
  }

  for (final child in engine.children) {
    if (child.guardianIds.isNotEmpty &&
        !child.guardianIds.contains(engine.memberId)) {
      continue;
    }
    final entries = engine.childEntries(child.id);
    for (final d in [
      ...checkupPlan(child, entries, from),
      ...vaccinationPlan(child, entries, from),
    ]) {
      if (d.state == DueState.done ||
          d.state == DueState.missed ||
          d.optional) {
        continue;
      }
      final what = d.isCheckup ? d.id : 'Impfung ${d.title}';
      // Pediatricians are booked out for weeks: remind to call in time.
      final book = nineOn(d.from.subtract(const Duration(days: 28)));
      if (d.isCheckup &&
          book.isAfter(child.birthDate.add(const Duration(days: 14)))) {
        add(
          'kid:${child.id}:${d.id}:book',
          book,
          'Termin für die ${d.id} von ${child.name} vereinbaren',
          'Zeitraum ab ${DateFormat('d.M.y', 'de').format(d.from)} – '
              'Praxen sind oft Wochen im Voraus ausgebucht.',
        );
      }
      add(
        'kid:${child.id}:${d.id}:start',
        nineOn(d.from),
        '$what für ${child.name}',
        d.isCheckup
            ? 'Zeitraum: ${d.subtitle}. Termin beim Kinderarzt vereinbaren.'
            : d.subtitle,
      );
      if (d.isCheckup) {
        add(
          'kid:${child.id}:${d.id}:end',
          nineOn(d.to.subtract(const Duration(days: 7))),
          '$what für ${child.name} – noch eine Woche',
          'Der Zeitraum endet bald.',
        );
      }
    }
  }
  for (final child in engine.children) {
    if (child.guardianIds.isNotEmpty &&
        !child.guardianIds.contains(engine.memberId)) {
      continue;
    }
    for (final r in logReminders(child, engine.childLogs(child.id))) {
      add(r.key, r.at, r.title, r.body ?? '');
    }
  }
  for (final p in engine.activePregnancies) {
    if (p.guardianIds.isNotEmpty && !p.guardianIds.contains(engine.memberId)) {
      continue;
    }
    final who = p.name.isEmpty ? 'Schwangerschaft' : p.name;
    for (final t in pregnancyTasks) {
      if (p.done.contains(t.id)) continue;
      add(
        'preg:${p.id}:${t.id}',
        nineOn(p.dayOf(t.fromWeek)),
        '$who: ${t.title}',
        'SSW ${t.fromWeek}–${t.toWeek}. ${t.info}',
      );
    }
    add(
      'preg:${p.id}:leave',
      nineOn(maternityLeave(p).subtract(const Duration(days: 14))),
      '$who: Mutterschutz beginnt in 2 Wochen',
      'Ab ${DateFormat('d.M.y', 'de').format(maternityLeave(p))}.',
    );
  }
  for (final b in familyBirthdays(engine)) {
    final day = b.next(from);
    add(
      'bday:${b.sourceId}:${day.year}:eve',
      DateTime(day.year, day.month, day.day - 1, 18),
      'Morgen: ${b.headline(day)}',
      'Geschenk oder Anruf nicht vergessen 🎁',
    );
    add(
      'bday:${b.sourceId}:${day.year}',
      DateTime(day.year, day.month, day.day, 8),
      'Heute: ${b.headline(day)} 🎂',
      '',
    );
  }
  for (final doc in engine.documents) {
    final expires = doc.expiresAt;
    if (expires == null) continue;
    for (final days in [60, 7]) {
      add(
        'doc:${doc.id}:$days',
        nineOn(expires.subtract(Duration(days: days))),
        '${doc.title} läuft ab',
        'Gültig bis ${DateFormat('d.M.y', 'de').format(expires)} – rechtzeitig erneuern.',
      );
    }
  }
  return result;
}

/// Reminders set in a child's log: the next feeding (only for the latest
/// one) and "medicine possible again" (latest dose per medicine).
List<DueReminder> logReminders(Child child, List<ChildLog> logs) {
  final result = <DueReminder>[];
  final time = DateFormat('HH:mm', 'de');
  final feeding = logs
      .where(
        (l) =>
            l.kind == LogKind.breast ||
            l.kind == LogKind.bottle ||
            l.kind == LogKind.solids,
      )
      .firstOrNull;
  if (feeding?.remindAt case final at?) {
    result.add(
      DueReminder(
        key: 'log:${feeding!.id}',
        at: at,
        title: 'Nächste Mahlzeit für ${child.name}',
        body: 'Letzte Mahlzeit um ${time.format(feeding.start)}.',
      ),
    );
  }
  final seen = <String>{};
  for (final l in logs) {
    if (l.kind != LogKind.medication ||
        !seen.add(l.medication.trim().toLowerCase())) {
      continue;
    }
    if (l.remindAt case final at?) {
      result.add(
        DueReminder(
          key: 'log:${l.id}',
          at: at,
          title: '${l.medication} für ${child.name} wieder möglich',
          body:
              'Letzte Gabe um ${time.format(l.start)} – laut eingetragenem '
              'Mindestabstand.',
        ),
      );
    }
  }
  return result;
}
