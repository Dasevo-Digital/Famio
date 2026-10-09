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
import '../data/deadlines.dart';
import '../data/waste.dart';
import '../data/week_preview.dart';
import '../format.dart';
import '../location/location_sharing.dart';
import '../environment.dart';
import '../l10n.dart';

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
        settings: InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          macOS: DarwinInitializationSettings(),
          linux: LinuxInitializationSettings(defaultActionName: tr.commonOpen),
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
      debugPrint(tr.remindersNotificationsNotAvailableError(e));
      return null;
    }
  }

  final FlutterLocalNotificationsPlugin _plugin;
  final SharedPreferences _prefs;
  var _exactAlarms = false;

  static const _window = Duration(days: 14);
  static const _maxScheduled = 48;
  static const _prefsKey = 'reminders.scheduled';

  static NotificationDetails get _details => NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      tr.remindersChannel,
      channelDescription: tr.remindersEventsTasks,
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

  /// Whether this device shows the week ahead on Sunday evening.
  bool Function()? weekPreview;

  /// Plans again, e.g. after a setting changed.
  void refresh() => _reschedule();

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
        (Object e) => debugPrint(tr.remindersPlanningRemindersFailedError(e)),
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
      if (weekPreview?.call() ?? true)
        for (final (at, monday) in weekPreviewTimes(now, now.add(_window)))
          if (buildWeekPreview(engine, monday) case final p?)
            DueReminder(
              key: 'week:${dayKey(monday)}',
              at: at,
              title: p.title,
              body: p.body,
            ),
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
    Collections.externalEvents,
    Collections.wasteSettings,
    Collections.deadlines,
    Collections.shoppingLists,
    Collections.shoppingItems,
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
        title: ChatIds.isDirect(m.chatId)
            ? author
            : tr.remindersAuthorFamily(author),
        body: m.poll != null
            ? '📊 ${m.poll!.question}'
            : m.text.isNotEmpty
            ? m.text
            : '📎 ${m.attachment?.name ?? tr.commonAttachment}',
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
        body: a.text(
          engine.member(a.memberId)?.displayName ?? tr.commonSomeone,
        ),
        notificationDetails: _quiet(place: true)
            ? _quietDetails
            : _placeDetails,
      );
    }
  }

  static NotificationDetails get _placeDetails => NotificationDetails(
    android: AndroidNotificationDetails(
      'famio_places',
      tr.remindersPlaces,
      channelDescription: tr.remindersWhoArrivedWhereLeft,
      visibility: NotificationVisibility.private,
    ),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );

  static NotificationDetails get _chatDetails => NotificationDetails(
    android: AndroidNotificationDetails(
      'chat',
      tr.sectionChat,
      channelDescription: tr.remindersNewMessagesFamily,
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
  static NotificationDetails get _alarmDetails => NotificationDetails(
    android: AndroidNotificationDetails(
      'sos',
      tr.remindersEmergencySos,
      channelDescription: tr.remindersWhenSomeonePressesEmergency,
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
    android: AndroidNotificationDetails(
      'quiet',
      tr.pushQuietTime2,
      channelDescription: tr.remindersNoticesDuringQuietTime,
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
          ? tr.remindersDayAllDay(dayLabel(o.start))
          : dateTimeLabel(o.start);
      final location = o.event.location;
      return location.isEmpty ? when : '$when · $location';
    }
    final due = r.task?.due;
    return due == null ? tr.commonTask : tr.remindersTaskDueDue(dayLabel(due));
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
      final what = d.isCheckup ? d.id : tr.remindersVaccinationTitle(d.title);
      final appointment = d.appointment;
      if (appointment != null) {
        // A booked appointment replaces the "please book" reminders.
        final at = appointment.appointmentAt;
        final clock = appointment.time == null
            ? ''
            : tr.remindersTime(appointment.time!);
        final dayBefore = at.subtract(const Duration(days: 1));
        add(
          'kid:${child.id}:${d.id}:appt:${appointment.date.toIso8601String()}',
          DateTime(dayBefore.year, dayBefore.month, dayBefore.day, 18),
          tr.remindersTomorrowWhatName(what, child.name),
          tr.remindersAppointmentDateClockBring(
            DateFormat.yMd(appLanguage).format(at),
            clock,
          ),
        );
        if (appointment.time != null) {
          add(
            'kid:${child.id}:${d.id}:apptsoon:${at.toIso8601String()}',
            at.subtract(const Duration(hours: 1)),
            tr.remindersWhatNameClock(what, child.name, clock),
            tr.remindersAppointmentOneHour,
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
          tr.remindersBookCheckupAppointmentName(d.id, child.name),
          tr.remindersPeriodDatePracticesOften(
            DateFormat.yMd(appLanguage).format(d.from),
          ),
        );
      }
      add(
        'kid:${child.id}:${d.id}:start',
        nineOn(d.from),
        tr.remindersWhatName(what, child.name),
        d.isCheckup
            ? tr.remindersPeriodPeriodBookAppointment(d.subtitle)
            : d.subtitle,
      );
      if (d.isCheckup) {
        add(
          'kid:${child.id}:${d.id}:end',
          nineOn(d.to.subtract(const Duration(days: 7))),
          tr.remindersWhatNameOneWeek(what, child.name),
          tr.remindersPeriodEndsSoon,
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
    final who = p.name.isEmpty ? tr.commonPregnancy : p.name;
    for (final t in pregnancyTasks) {
      if (p.done.contains(t.id)) continue;
      add(
        'preg:${p.id}:${t.id}',
        nineOn(p.dayOf(t.fromWeek)),
        '$who: ${t.title}',
        tr.remindersWeekFromweekToweekInfo(t.fromWeek, t.toWeek, t.info),
      );
    }
    add(
      'preg:${p.id}:leave',
      nineOn(maternityLeave(p).subtract(const Duration(days: 14))),
      tr.remindersWhoMaternityLeaveStarts(who),
      tr.remindersDate(DateFormat.yMd(appLanguage).format(maternityLeave(p))),
    );
  }
  for (final b in familyBirthdays(engine)) {
    final day = b.next(from);
    add(
      'bday:${b.sourceId}:${day.year}:eve',
      DateTime(day.year, day.month, day.day - 1, 18),
      tr.remindersTomorrowWhat(b.headline(day)),
      tr.remindersDonTForgetPresent,
    );
    add(
      'bday:${b.sourceId}:${day.year}',
      DateTime(day.year, day.month, day.day, 8),
      tr.remindersTodayWhat(b.headline(day)),
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
        tr.remindersCountStepsPoints(
          r.steps.length,
          r.points > 0 ? ' · +${r.points} ⭐' : '',
        ),
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
          m.personName.isEmpty
              ? m.name
              : tr.remindersMedicationPerson(m.name, m.personName),
          m.dose.isEmpty ? tr.budgetIncome2 : m.dose,
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
      tr.remindersBuyMedicationAgainSoon(m.name),
      tr.remindersSupplyLastsAboutDays(early ? max(0, days - 1) : m.refillDays),
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
        tr.remindersUseUpItemSoon(item.name),
        tr.remindersBestBeforeTomorrowLatest,
      );
    }
  }
  // Deadlines (car, house, pets): ahead of time and on the day.
  for (final d in engine.deadlines) {
    if (d.done || !engine.deadlineIsMine(d)) continue;
    final when = DateFormat.yMd(appLanguage).format(d.due);
    if (d.leadDays > 0) {
      add(
        'deadline:${d.id}:${dayKey(d.due)}:lead',
        nineOn(d.due.subtract(Duration(days: d.leadDays))),
        tr.remindersEmojiLabelDaysDays(d.area.emoji, d.label, d.leadDays),
        tr.remindersDueDateMakeAppointment(when),
      );
    }
    add(
      'deadline:${d.id}:${dayKey(d.due)}',
      nineOn(d.due),
      tr.remindersEmojiDueTodayLabel(d.area.emoji, d.label),
      d.note.isEmpty ? tr.remindersMarkDoneFamio : d.note,
    );
  }
  // Packing lists: the evening before the trip, while I still have to pack.
  final events = {for (final e in engine.events) e.id: e};
  for (final list in engine.shoppingLists) {
    final trip = events[list.eventId];
    if (!list.packing || trip == null) continue;
    final start = trip
        .occurrencesBetween(from, to.add(const Duration(days: 1)))
        .where((o) => !o.start.isBefore(from))
        .firstOrNull
        ?.start;
    if (start == null) continue;
    final left = engine
        .shoppingItems(list.id)
        .where(
          (i) =>
              !i.checked &&
              (i.memberId == engine.memberId ||
                  (i.memberId == null && trip.involves(engine.memberId))),
        )
        .length;
    if (left == 0) continue;
    add(
      'pack:${list.id}:${dayKey(start)}',
      DateTime(start.year, start.month, start.day - 1, 18),
      tr.remindersTomorrowTrip(trip.title),
      left == 1
          ? tr.reminders1ThingLeftPack
          : tr.remindersLeftThingsLeftPack(left),
    );
  }
  // Bins: the evening before, for whoever's turn it is.
  if (engine.wasteConfigured) {
    final hour = engine.wasteSettings.remindHour;
    for (final p in engine.wastePickups(
      from,
      to.add(const Duration(days: 1)),
    )) {
      if (!engine.wasteIsMine(p)) continue;
      add(
        'waste:${dayKey(p.day)}',
        DateTime(p.day.year, p.day.month, p.day.day - 1, hour),
        tr.remindersTomorrowBin(p.label),
        tr.remindersTurnPleasePutOut,
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
        tr.remindersTitleExpires(doc.title),
        tr.remindersValidUntilDateRenew(
          DateFormat.yMd(appLanguage).format(expires),
        ),
      );
    }
  }
  return result;
}

/// Reminders set in a child's log: the next feeding (only for the latest
/// one) and "medicine possible again" (latest dose per medicine).
List<DueReminder> logReminders(Child child, List<ChildLog> logs) {
  final result = <DueReminder>[];
  final time = DateFormat.jm(appLanguage);
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
        title: tr.remindersNextMealName(child.name),
        body: tr.remindersLastMealTime(time.format(feeding.start)),
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
          title: tr.remindersMedicationPossibleAgainName(
            l.medication,
            child.name,
          ),
          body: tr.remindersLastDoseTimeAccording(time.format(l.start)),
        ),
      );
    }
  }
  return result;
}
