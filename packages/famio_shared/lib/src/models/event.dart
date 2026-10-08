import '../sync_record.dart';

enum RecurrenceFrequency { daily, weekly, monthly, yearly }

/// Repetition rule of a series. Occurrences are computed in local time, so a
/// weekly 19:00 appointment stays at 19:00 across daylight saving changes.
class Recurrence {
  const Recurrence(
    this.frequency, {
    this.interval = 1,
    this.until,
    this.weekdays = const [],
  });

  static Recurrence? fromJson(Object? json) {
    if (json is! Map) return null;
    final frequency = RecurrenceFrequency.values
        .where((f) => f.name == json['frequency'])
        .firstOrNull;
    if (frequency == null) return null;
    return Recurrence(
      frequency,
      interval: (json['interval'] as int? ?? 1).clamp(1, 999),
      until: _parseDate(json['until']),
      weekdays: frequency == RecurrenceFrequency.weekly
          ? normalizeWeekdays([
              for (final d in json['weekdays'] as List? ?? const [])
                if (d is int) d,
            ])
          : const [],
    );
  }

  /// Sorted, distinct weekdays (1 = Monday … 7 = Sunday).
  static List<int> normalizeWeekdays(Iterable<int> days) => ({
    for (final d in days)
      if (d >= 1 && d <= 7) d,
  }.toList()..sort());

  final RecurrenceFrequency frequency;
  final int interval;

  /// Last day (inclusive) on which an occurrence may start.
  final DateTime? until;

  /// Weekly series only: the days of the week (1 = Monday … 7 = Sunday) on
  /// which it repeats, e.g. Tuesday and Thursday. Empty means the weekday of
  /// the first occurrence.
  final List<int> weekdays;

  Map<String, Object?> toJson() => {
    'frequency': frequency.name,
    'interval': interval,
    'until': until == null ? null : _formatDate(until!),
    if (weekdays.isNotEmpty) 'weekdays': weekdays,
  };

  @override
  bool operator ==(Object other) =>
      other is Recurrence &&
      other.frequency == frequency &&
      other.interval == interval &&
      other.until == until &&
      _sameList(other.weekdays, weekdays);

  @override
  int get hashCode =>
      Object.hash(frequency, interval, until, Object.hashAll(weekdays));
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One concrete appearance of an event (a series expands into many).
class Occurrence {
  const Occurrence(this.event, this.start, this.end);

  final CalendarEvent event;
  final DateTime start;
  final DateTime end;

  /// Stable key of this occurrence, e.g. for notification ids.
  String get key => '${event.id}@${start.toIso8601String()}';
}

/// A calendar entry, stored in `Collections.events`.
///
/// Timed events are stored as UTC instants, all-day events as plain dates
/// (`yyyy-MM-dd`, [end] exclusive), so they show on the same day everywhere.
class CalendarEvent {
  CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location = '',
    this.notes = '',
    this.memberIds = const [],
    this.recurrence,
    this.exceptions = const {},
    this.reminderMinutes,
    this.sourceId,
    this.confidential = false,
    this.icalUid,
    this.bringerId,
    this.pickerId,
    this.countdown = false,
  });

  factory CalendarEvent.fromRecord(SyncRecord r) {
    final allDay = r.data['allDay'] as bool? ?? false;
    final start = _parseInstant(r.data['start']) ?? DateTime(2000);
    var end = _parseInstant(r.data['end']) ?? start;
    if (end.isBefore(start)) end = start;
    return CalendarEvent(
      id: r.id,
      title: r.data['title'] as String? ?? '',
      start: start,
      end: end,
      allDay: allDay,
      location: r.data['location'] as String? ?? '',
      notes: r.data['notes'] as String? ?? '',
      memberIds: [
        for (final m in r.data['memberIds'] as List? ?? const []) m as String,
      ],
      recurrence: Recurrence.fromJson(r.data['recurrence']),
      exceptions: {
        for (final d in r.data['exceptions'] as List? ?? const [])
          ?_parseDate(d),
      },
      reminderMinutes: r.data['reminderMinutes'] as int?,
      sourceId: r.data['sourceId'] as String?,
      confidential: r.data['confidential'] as bool? ?? false,
      icalUid: r.data['icalUid'] as String?,
      bringerId: r.data['bringerId'] as String?,
      pickerId: r.data['pickerId'] as String?,
      countdown: r.data['countdown'] as bool? ?? false,
    );
  }

  /// Counted down to on the start page and the wall display ("noch 12
  /// Tage"), e.g. holidays, a birthday party or the first day at school.
  final bool countdown;

  /// Who takes the children there and who picks them up (member ids);
  /// they get their own reminders.
  final String? bringerId;
  final String? pickerId;

  /// Reminder for the one who brings: this long before the start.
  static const bringLead = Duration(minutes: 30);

  /// Reminder for the one who picks up: this long before the end.
  static const pickLead = Duration(minutes: 15);

  final String id;
  final String title;

  /// Local time. For all-day events midnight of the first day.
  final DateTime start;

  /// Local time, exclusive. For all-day events midnight after the last day.
  final DateTime end;
  final bool allDay;
  final String location;
  final String notes;

  /// Participants; empty means the whole family.
  final List<String> memberIds;
  final Recurrence? recurrence;

  /// Dates (midnight) of skipped occurrences of a series.
  final Set<DateTime> exceptions;

  /// Remind this many minutes before the start; null for no reminder.
  /// Negative values remind after the start, e.g. -480 is 8:00 on the day of
  /// an all-day event.
  final int? reminderMinutes;

  /// Id of the calendar subscription this event was imported from; null for
  /// Famio's own events. Imported events are read-only.
  final String? sourceId;

  /// Kept out of calendar subscriptions (Google, Apple …), e.g. doctor's
  /// appointments: those services store what they fetch.
  final bool confidential;

  /// UID given by another calendar app (CalDAV) when it created the event;
  /// kept so that app recognises it. Null for events created in Famio.
  final String? icalUid;

  /// The iCalendar UID other calendar apps know this event by.
  String get uid => icalUid ?? '$id@famio';

  Duration get duration => end.difference(start);

  bool involves(String memberId) =>
      memberIds.isEmpty || memberIds.contains(memberId);

  /// Occurrences overlapping `[from, to)`, in chronological order.
  List<Occurrence> occurrencesBetween(DateTime from, DateTime to) {
    final rule = recurrence;
    if (rule == null) {
      return _overlaps(start, from, to) ? [Occurrence(this, start, end)] : [];
    }

    final result = <Occurrence>[];
    final until = rule.until == null
        ? null
        : DateTime(rule.until!.year, rule.until!.month, rule.until!.day + 1);
    // Skip ahead to shortly before the window instead of walking the whole
    // history of a long-running series.
    var guard = 0;
    for (final s in _starts(rule, _firstCandidate(rule, from))) {
      if (++guard > 5000) break;
      if (s == null) continue; // e.g. the 31st in a 30-day month
      if (!s.isBefore(to) || (until != null && !s.isBefore(until))) break;
      if (exceptions.contains(DateTime(s.year, s.month, s.day))) continue;
      if (_overlaps(s, from, to)) result.add(Occurrence(this, s, _endFor(s)));
    }
    return result;
  }

  /// Starts of the series from its [n]th period on, in order; null for
  /// periods without an occurrence.
  Iterable<DateTime?> _starts(Recurrence rule, int n) sync* {
    final days = rule.weekdays;
    if (rule.frequency != RecurrenceFrequency.weekly || days.isEmpty) {
      for (; ; n++) {
        yield _nth(rule, n);
      }
    }
    final s = start;
    // Weeks run Monday to Sunday.
    final monday = DateTime(s.year, s.month, s.day - (s.weekday - 1));
    for (; ; n++) {
      final week = 7 * n * rule.interval;
      for (final d in days) {
        final t = DateTime(
          monday.year,
          monday.month,
          monday.day + week + d - 1,
          s.hour,
          s.minute,
          s.second,
        );
        if (!t.isBefore(s)) yield t;
      }
      yield null;
    }
  }

  /// Start of the [count]th occurrence of the series ignoring [exceptions]
  /// (as iCalendar's COUNT counts), or null if it has fewer.
  DateTime? nthStart(int count) {
    final rule = recurrence;
    if (rule == null || count < 1) return count == 1 ? start : null;
    var seen = 0;
    var guard = 0;
    for (final s in _starts(rule, 0)) {
      if (++guard > 100000) return null;
      if (s == null) continue;
      if (rule.until != null &&
          s.isAfter(
            DateTime(rule.until!.year, rule.until!.month, rule.until!.day + 1),
          )) {
        return null;
      }
      if (++seen == count) return s;
    }
    return null;
  }

  bool _overlaps(DateTime s, DateTime from, DateTime to) {
    final e = _endFor(s);
    // Zero-length events are shown at their start.
    return s.isBefore(to) && (e.isAfter(from) || (e == s && !s.isBefore(from)));
  }

  /// End of an occurrence starting at [s]. All-day events keep their length
  /// in days; timed events keep their duration.
  DateTime _endFor(DateTime s) {
    if (!allDay) return s.add(duration);
    final days = DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    return DateTime(s.year, s.month, s.day + days);
  }

  DateTime? _nth(Recurrence rule, int n) {
    final k = n * rule.interval;
    final s = start;
    DateTime at(int y, int m, int d) =>
        DateTime(y, m, d, s.hour, s.minute, s.second);
    switch (rule.frequency) {
      case RecurrenceFrequency.daily:
        return at(s.year, s.month, s.day + k);
      case RecurrenceFrequency.weekly:
        return at(s.year, s.month, s.day + 7 * k);
      case RecurrenceFrequency.monthly:
        final d = at(s.year, s.month + k, s.day);
        return d.day == s.day ? d : null;
      case RecurrenceFrequency.yearly:
        final d = at(s.year + k, s.month, s.day);
        return d.day == s.day ? d : null;
    }
  }

  int _firstCandidate(Recurrence rule, DateTime from) {
    final lookBack = from.subtract(duration).subtract(const Duration(days: 1));
    if (!lookBack.isAfter(start)) return 0;
    final int periods = switch (rule.frequency) {
      RecurrenceFrequency.daily => _days(start, lookBack),
      RecurrenceFrequency.weekly => _days(start, lookBack) ~/ 7,
      RecurrenceFrequency.monthly =>
        (lookBack.year - start.year) * 12 + lookBack.month - start.month,
      RecurrenceFrequency.yearly => lookBack.year - start.year,
    };
    return (periods ~/ rule.interval - 1).clamp(0, 1 << 30);
  }

  static int _days(DateTime a, DateTime b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  CalendarEvent copyWith({
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? location,
    String? notes,
    List<String>? memberIds,
    Object? recurrence = _keep,
    Set<DateTime>? exceptions,
    Object? reminderMinutes = _keep,
    bool? confidential,
    Object? bringerId = _keep,
    Object? pickerId = _keep,
    bool? countdown,
  }) => CalendarEvent(
    id: id,
    title: title ?? this.title,
    start: start ?? this.start,
    end: end ?? this.end,
    allDay: allDay ?? this.allDay,
    location: location ?? this.location,
    notes: notes ?? this.notes,
    memberIds: memberIds ?? this.memberIds,
    recurrence: recurrence == _keep
        ? this.recurrence
        : recurrence as Recurrence?,
    exceptions: exceptions ?? this.exceptions,
    reminderMinutes: reminderMinutes == _keep
        ? this.reminderMinutes
        : reminderMinutes as int?,
    sourceId: sourceId,
    confidential: confidential ?? this.confidential,
    icalUid: icalUid,
    bringerId: bringerId == _keep ? this.bringerId : bringerId as String?,
    pickerId: pickerId == _keep ? this.pickerId : pickerId as String?,
    countdown: countdown ?? this.countdown,
  );

  /// A copy with a new [id], e.g. to detach one occurrence from a series.
  CalendarEvent withId(String id) => CalendarEvent(
    id: id,
    title: title,
    start: start,
    end: end,
    allDay: allDay,
    location: location,
    notes: notes,
    memberIds: memberIds,
    recurrence: recurrence,
    exceptions: exceptions,
    reminderMinutes: reminderMinutes,
    sourceId: sourceId,
    confidential: confidential,
    countdown: countdown,
  );

  Map<String, Object?> toData() => {
    'title': title,
    'start': allDay ? _formatDate(start) : start.toUtc().toIso8601String(),
    'end': allDay ? _formatDate(end) : end.toUtc().toIso8601String(),
    'allDay': allDay,
    'location': location,
    'notes': notes,
    'memberIds': memberIds,
    'recurrence': recurrence?.toJson(),
    'exceptions': [for (final d in exceptions) _formatDate(d)]..sort(),
    'reminderMinutes': reminderMinutes,
    'sourceId': ?sourceId,
    if (confidential) 'confidential': true,
    'icalUid': ?icalUid,
    'bringerId': ?bringerId,
    'pickerId': ?pickerId,
    if (countdown) 'countdown': true,
  };
}

const _keep = Object();

/// Parses a UTC instant to local time, or a plain date to local midnight.
DateTime? _parseInstant(Object? v) {
  if (v is! String) return null;
  final parsed = DateTime.tryParse(v);
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

DateTime? _parseDate(Object? v) {
  if (v is! String) return null;
  final d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
