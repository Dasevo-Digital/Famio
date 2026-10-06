import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/birthdays.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
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

  /// True while this device gets Famio's own push notifications.
  bool Function()? ownPushActive;

  /// The member's quiet time (see QuietHours); reminders the member set
  /// themselves stay loud.
  QuietHours Function()? quietHours;

  bool _quiet({bool place = false}) {
    final quiet = quietHours?.call();
    if (quiet == null || (place && quiet.placesLoud)) return false;
    return quiet.isQuietAt(DateTime.now());
  }

  /// A notification of Famio's own push (see OwnPush).
  Future<void> showNotice(Notice notice, {required bool details}) =>
      _plugin.show(
        id: 800000 + notice.id % 100000,
        title: details ? notice.title : AppEnv.appName,
        body: details ? notice.body : notice.brief,
        notificationDetails: notice.alarm
            ? _alarmDetails
            : notice.quiet
            ? _quietDetails
            : _chatDetails,
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
      // With Famio's own push the server tells about these (see OwnPush).
      final ownPush = ownPushActive?.call() ?? false;
      if (changed.contains(Collections.chatMessages) && !ownPush) {
        _notifyChat(engine);
      }
      if (changed.contains(Collections.locationAlerts) && !ownPush) {
        _notifyPlaces(engine);
      }
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
    Collections.routines,
    Collections.routineRuns,
    Collections.medications,
    Collections.medicationIntakes,
    Collections.pantryItems,
    'members',
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
        body: m.poll != null
            ? '📊 ${m.poll!.question}'
            : m.text.isNotEmpty
            ? m.text
            : '📎 ${m.attachment?.name ?? 'Anhang'}',
        notificationDetails: _quiet() ? _quietDetails : _chatDetails,
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
    final sharing =
        LocationSharing.supported && (await LocationSharing.status()).enabled;
    for (final a in fresh.where((a) => !sharing || a.checkIn != null).take(5)) {
      await _plugin.show(
        id: int.tryParse(a.id.substring(0, 7), radix: 16) ?? a.id.hashCode,
        title: AppEnv.appName,
        body: a.text(engine.member(a.memberId)?.displayName ?? 'Jemand'),
        notificationDetails: _quiet(place: true)
            ? _quietDetails
            : _placeDetails,
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

  /// An emergency (SOS): loud like an alarm clock, over the lock screen.
  static const _alarmDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'sos',
      'Notfall (SOS)',
      channelDescription: 'Wenn jemand den Notfallknopf drückt',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      visibility: NotificationVisibility.public,
    ),
    macOS: DarwinNotificationDetails(
      interruptionLevel: InterruptionLevel.timeSensitive,
    ),
    linux: LinuxNotificationDetails(urgency: LinuxNotificationUrgency.critical),
    windows: WindowsNotificationDetails(
      scenario: WindowsNotificationScenario.urgent,
    ),
  );

  /// In the quiet time: listed, but no sound and no pop-up.
  static final _quietDetails = NotificationDetails(
    android: const AndroidNotificationDetails(
      'quiet',
      'Ruhezeit',
      channelDescription: 'Hinweise während der Ruhezeit, ohne Ton',
      importance: Importance.low,
      priority: Priority.low,
      playSound: false,
      enableVibration: false,
      visibility: NotificationVisibility.private,
    ),
    macOS: const DarwinNotificationDetails(
      presentSound: false,
      presentBanner: false,
    ),
    linux: const LinuxNotificationDetails(suppressSound: true),
    windows: WindowsNotificationDetails(
      audio: WindowsNotificationAudio.silent(),
    ),
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
      final appointment = d.appointment;
      if (appointment != null) {
        // A booked appointment replaces the "please book" reminders.
        final at = appointment.appointmentAt;
        final clock = appointment.time == null
            ? ''
            : ' um ${appointment.time} Uhr';
        final dayBefore = at.subtract(const Duration(days: 1));
        add(
          'kid:${child.id}:${d.id}:appt:${appointment.date.toIso8601String()}',
          DateTime(dayBefore.year, dayBefore.month, dayBefore.day, 18),
          'Morgen: $what für ${child.name}',
          'Termin am ${DateFormat('d.M.y', 'de').format(at)}$clock. '
              'Gelbes Heft bzw. Impfpass mitnehmen.',
        );
        if (appointment.time != null) {
          add(
            'kid:${child.id}:${d.id}:apptsoon:${at.toIso8601String()}',
            at.subtract(const Duration(hours: 1)),
            '$what für ${child.name}$clock',
            'Termin in einer Stunde.',
          );
        }
        continue;
      }
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
  // Routines of the member (children's checklists), until done.
  for (var d = 0; d < to.difference(from).inDays + 1; d++) {
    final day = DateTime(from.year, from.month, from.day + d);
    for (final r in engine.routinesFor(engine.memberId, day)) {
      final at = r.reminderOn(day);
      if (at == null) continue;
      final run = engine.routineRun(r, day, engine.memberId);
      if (r.steps.isNotEmpty && r.steps.every((s) => run.done.contains(s.id))) {
        continue;
      }
      add(
        'routine:${r.id}:${dayKey(day)}',
        at,
        '${r.emoji} ${r.title}',
        '${r.steps.length} Schritte${r.points > 0 ? ' · +${r.points} ⭐' : ''}',
      );
    }
    // Doses for the members caring for them, unless already recorded.
    for (final m in engine.medications) {
      if (m.careIds.isNotEmpty && !m.careIds.contains(engine.memberId)) {
        continue;
      }
      for (final at in m.dosesOn(day)) {
        if (engine.intakeAt(m, at) != null) continue;
        add(
          'med:${m.id}:${at.toIso8601String()}',
          at,
          m.personName.isEmpty ? m.name : '${m.name} für ${m.personName}',
          m.dose.isEmpty ? 'Einnahme' : m.dose,
        );
      }
    }
  }
  for (final m in engine.medications) {
    if (m.careIds.isNotEmpty && !m.careIds.contains(engine.memberId)) {
      continue;
    }
    final days = m.daysLeft(engine.takenSinceCount(m));
    if (days == null || m.stockAt == null) continue;
    final early = days <= m.refillDays;
    add(
      'med-refill:${m.id}:${m.stockAt!.millisecondsSinceEpoch}',
      early
          ? nineOn(from.add(const Duration(days: 1)))
          : nineOn(from.add(Duration(days: days - m.refillDays))),
      '${m.name} bald nachkaufen',
      'Der Vorrat reicht noch etwa ${early ? max(0, days - 1) : m.refillDays} Tage.',
    );
  }
  // Best-before dates, for the adults.
  if (engine.iAmAdult) {
    for (final item in engine.pantryItems) {
      final best = item.bestBefore;
      if (best == null || item.amount <= 0) continue;
      add(
        'pantry:${item.id}:${dayKey(best)}',
        DateTime(best.year, best.month, best.day - 1, 17),
        '${item.name} bald verbrauchen',
        'Mindestens haltbar bis morgen.',
      );
    }
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
