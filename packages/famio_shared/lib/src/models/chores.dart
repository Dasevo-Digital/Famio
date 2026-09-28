import '../sync_record.dart';

/// `2026-09-28` for the local calendar day of [d].
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Monday of the week of [d].
DateTime weekStart(DateTime d) =>
    _day(d).subtract(Duration(days: d.weekday - 1));

/// Whole calendar days from [a] to [b] (DST safe).
int daysBetween(DateTime a, DateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

enum ChoreRepeat {
  once('Einmalig'),
  daily('Täglich'),
  weekly('Einmal pro Woche');

  const ChoreRepeat(this.label);

  final String label;

  static ChoreRepeat parse(Object? name) =>
      values.where((r) => r.name == name).firstOrNull ?? daily;
}

/// A household chore (Amt), stored in `Collections.chores`.
///
/// With [rotate] the members in [memberIds] take turns (per day or week);
/// otherwise any of them (everyone if empty) may do it.
class Chore {
  const Chore({
    required this.id,
    required this.title,
    this.emoji = '🧹',
    this.points = 1,
    this.memberIds = const [],
    this.rotate = false,
    this.repeat = ChoreRepeat.daily,
    this.weekdays = const {},
    this.date,
    required this.start,
    this.paused = false,
  });

  factory Chore.fromRecord(SyncRecord r) => Chore(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    emoji: r.data['emoji'] as String? ?? '🧹',
    points: (r.data['points'] as num?)?.toInt() ?? 1,
    memberIds: [
      for (final m in r.data['memberIds'] as List? ?? []) m as String,
    ],
    rotate: r.data['rotate'] as bool? ?? false,
    repeat: ChoreRepeat.parse(r.data['repeat']),
    weekdays: {
      for (final d in r.data['weekdays'] as List? ?? []) (d as num).toInt(),
    },
    date: _parseDay(r.data['date']),
    start: _parseDay(r.data['start']) ?? DateTime(2026),
    paused: r.data['paused'] as bool? ?? false,
  );

  final String id;
  final String title;
  final String emoji;
  final int points;
  final List<String> memberIds;
  final bool rotate;
  final ChoreRepeat repeat;

  /// For daily chores: the weekdays (1 = Monday); empty means every day.
  final Set<int> weekdays;

  /// The day of a one-off chore.
  final DateTime? date;

  /// Anchor of the rotation: whoever is first in [memberIds] starts here.
  final DateTime start;
  final bool paused;

  bool dueOn(DateTime day) {
    if (paused || _day(day).isBefore(_day(start))) return false;
    return switch (repeat) {
      ChoreRepeat.once => date != null && daysBetween(date!, day) == 0,
      ChoreRepeat.daily => weekdays.isEmpty || weekdays.contains(day.weekday),
      ChoreRepeat.weekly => true,
    };
  }

  /// Identifies the day or week a completion counts for.
  String periodKey(DateTime day) => switch (repeat) {
    ChoreRepeat.once => 'once',
    ChoreRepeat.daily => dayKey(day),
    ChoreRepeat.weekly => 'w${dayKey(weekStart(day))}',
  };

  /// Whose turn it is on [day]; null if anyone (of [memberIds]) may do it.
  String? assigneeOn(DateTime day) {
    if (!rotate || memberIds.isEmpty) return null;
    return memberIds[_turn(day) % memberIds.length];
  }

  /// Number of due periods between [start] and [day].
  int _turn(DateTime day) {
    switch (repeat) {
      case ChoreRepeat.once:
        return 0;
      case ChoreRepeat.weekly:
        return daysBetween(weekStart(start), weekStart(day)) ~/ 7;
      case ChoreRepeat.daily:
        final days = daysBetween(start, day);
        if (days <= 0) return 0;
        if (weekdays.isEmpty) return days;
        // Only due days count: whole weeks plus the rest.
        final perWeek = weekdays.length;
        var turns = days ~/ 7 * perWeek;
        for (var i = days - days % 7; i < days; i++) {
          if (weekdays.contains(start.add(Duration(days: i)).weekday)) turns++;
        }
        return turns;
    }
  }

  /// Whether [memberId] may tick it off on [day].
  bool isFor(String memberId, DateTime day) {
    final turn = assigneeOn(day);
    if (turn != null) return turn == memberId;
    return memberIds.isEmpty || memberIds.contains(memberId);
  }

  /// Id of the point entry for doing it in the period of [day].
  String completionId(DateTime day) => 'c-$id-${periodKey(day)}';

  Map<String, Object?> toData() => {
    'title': title,
    'emoji': emoji,
    'points': points,
    'memberIds': memberIds,
    'rotate': rotate,
    'repeat': repeat.name,
    'weekdays': weekdays.toList()..sort(),
    'date': date == null ? null : dayKey(date!),
    'start': dayKey(start),
    'paused': paused,
  };

  Chore copyWith({
    String? title,
    String? emoji,
    int? points,
    List<String>? memberIds,
    bool? rotate,
    ChoreRepeat? repeat,
    Set<int>? weekdays,
    Object? date = _keep,
    DateTime? start,
    bool? paused,
  }) => Chore(
    id: id,
    title: title ?? this.title,
    emoji: emoji ?? this.emoji,
    points: points ?? this.points,
    memberIds: memberIds ?? this.memberIds,
    rotate: rotate ?? this.rotate,
    repeat: repeat ?? this.repeat,
    weekdays: weekdays ?? this.weekdays,
    date: date == _keep ? this.date : date as DateTime?,
    start: start ?? this.start,
    paused: paused ?? this.paused,
  );
}

enum PointKind { chore, routine, bonus, reward, payout }

enum PointStatus {
  /// Waiting for an adult (children's completions, reward wishes).
  pending,
  approved,
  rejected;

  static PointStatus parse(Object? name) =>
      values.where((s) => s.name == name).firstOrNull ?? approved;
}

/// Points earned (positive) or spent (negative), in
/// `Collections.pointEntries`. Only approved entries count.
class PointEntry {
  const PointEntry({
    required this.id,
    required this.memberId,
    required this.points,
    required this.title,
    required this.kind,
    required this.at,
    this.status = PointStatus.approved,
    this.refId,
    this.decidedBy,
  });

  factory PointEntry.fromRecord(SyncRecord r) => PointEntry(
    id: r.id,
    memberId: r.data['memberId'] as String? ?? '',
    points: (r.data['points'] as num?)?.toInt() ?? 0,
    title: r.data['title'] as String? ?? '',
    kind:
        PointKind.values.where((k) => k.name == r.data['kind']).firstOrNull ??
        PointKind.bonus,
    at:
        DateTime.tryParse(r.data['at'] as String? ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(r.updatedAt),
    status: PointStatus.parse(r.data['status']),
    refId: r.data['refId'] as String?,
    decidedBy: r.data['decidedBy'] as String?,
  );

  final String id;
  final String memberId;
  final int points;
  final String title;
  final PointKind kind;
  final DateTime at;
  final PointStatus status;

  /// The chore, routine or reward.
  final String? refId;

  /// The adult who confirmed or declined it.
  final String? decidedBy;

  bool get counts => status == PointStatus.approved;

  PointEntry decide(PointStatus status, String by) => PointEntry(
    id: id,
    memberId: memberId,
    points: points,
    title: title,
    kind: kind,
    at: at,
    status: status,
    refId: refId,
    decidedBy: by,
  );

  Map<String, Object?> toData() => {
    'memberId': memberId,
    'points': points,
    'title': title,
    'kind': kind.name,
    'at': at.toUtc().toIso8601String(),
    'status': status.name,
    'refId': refId,
    'decidedBy': decidedBy,
  };
}

/// Something points can buy, in `Collections.rewards`.
class Reward {
  const Reward({
    required this.id,
    required this.title,
    this.emoji = '🎁',
    this.cost = 10,
  });

  factory Reward.fromRecord(SyncRecord r) => Reward(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    emoji: r.data['emoji'] as String? ?? '🎁',
    cost: (r.data['cost'] as num?)?.toInt() ?? 10,
  );

  final String id;
  final String title;
  final String emoji;
  final int cost;

  Map<String, Object?> toData() => {
    'title': title,
    'emoji': emoji,
    'cost': cost,
  };
}

/// Pocket money of one child, in `Collections.allowances` (id = member id).
class Allowance {
  const Allowance({
    required this.memberId,
    this.weeklyCents = 0,
    this.payday = DateTime.saturday,
    required this.since,
    this.centsPerPoint = 0,
  });

  factory Allowance.fromRecord(SyncRecord r) => Allowance(
    memberId: r.id,
    weeklyCents: (r.data['weeklyCents'] as num?)?.toInt() ?? 0,
    payday: (r.data['payday'] as num?)?.toInt() ?? DateTime.saturday,
    since: _parseDay(r.data['since']) ?? DateTime(2026),
    centsPerPoint: (r.data['centsPerPoint'] as num?)?.toInt() ?? 0,
  );

  final String memberId;
  final int weeklyCents;

  /// Weekday (1 = Monday) the weekly amount is booked.
  final int payday;

  /// First day that counts; no back pay before it.
  final DateTime since;

  /// Points can be exchanged into money at this rate; 0 = not at all.
  final int centsPerPoint;

  /// Paydays in `[from, to]` (whole days), not before [since].
  Iterable<DateTime> paydays(DateTime from, DateTime to) sync* {
    var d = _day(from.isBefore(since) ? since : from);
    d = d.add(Duration(days: (payday - d.weekday + 7) % 7));
    while (!d.isAfter(_day(to))) {
      yield d;
      d = DateTime(d.year, d.month, d.day + 7);
    }
  }

  /// Id of the weekly booking on [payday].
  String bookingId(DateTime payday) => 'allow-$memberId-${dayKey(payday)}';

  Map<String, Object?> toData() => {
    'weeklyCents': weeklyCents,
    'payday': payday,
    'since': dayKey(since),
    'centsPerPoint': centsPerPoint,
  };
}

enum MoneyKind {
  allowance('Taschengeld'),
  points('Punkte eingetauscht'),
  spent('Ausgegeben'),
  gift('Geschenkt'),
  other('Sonstiges');

  const MoneyKind(this.label);

  final String label;

  static MoneyKind parse(Object? name) =>
      values.where((k) => k.name == name).firstOrNull ?? other;
}

/// A booking on a child's pocket money account (`Collections.moneyEntries`).
class MoneyEntry {
  const MoneyEntry({
    required this.id,
    required this.memberId,
    required this.cents,
    required this.at,
    this.kind = MoneyKind.other,
    this.note = '',
  });

  factory MoneyEntry.fromRecord(SyncRecord r) => MoneyEntry(
    id: r.id,
    memberId: r.data['memberId'] as String? ?? '',
    cents: (r.data['cents'] as num?)?.toInt() ?? 0,
    at:
        DateTime.tryParse(r.data['at'] as String? ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(r.updatedAt),
    kind: MoneyKind.parse(r.data['kind']),
    note: r.data['note'] as String? ?? '',
  );

  final String id;
  final String memberId;

  /// Positive = in, negative = out.
  final int cents;
  final DateTime at;
  final MoneyKind kind;
  final String note;

  Map<String, Object?> toData() => {
    'memberId': memberId,
    'cents': cents,
    'at': at.toUtc().toIso8601String(),
    'kind': kind.name,
    'note': note,
  };
}

/// One step of a [Routine].
class RoutineStep {
  const RoutineStep({required this.id, required this.title, this.emoji = ''});

  factory RoutineStep.fromJson(Map<String, Object?> json) => RoutineStep(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    emoji: json['emoji'] as String? ?? '',
  );

  final String id;
  final String title;
  final String emoji;

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'emoji': emoji};
}

/// A child's checklist, e.g. the morning routine, in `Collections.routines`.
class Routine {
  const Routine({
    required this.id,
    required this.title,
    this.emoji = '☀️',
    this.memberId,
    this.weekdays = const {},
    this.time,
    this.steps = const [],
    this.points = 0,
  });

  factory Routine.fromRecord(SyncRecord r) => Routine(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    emoji: r.data['emoji'] as String? ?? '☀️',
    memberId: r.data['memberId'] as String?,
    weekdays: {
      for (final d in r.data['weekdays'] as List? ?? []) (d as num).toInt(),
    },
    time: r.data['time'] as String?,
    steps: [
      for (final s in r.data['steps'] as List? ?? [])
        RoutineStep.fromJson((s as Map).cast()),
    ],
    points: (r.data['points'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String title;
  final String emoji;

  /// Whose routine it is; null for everyone.
  final String? memberId;

  /// 1 = Monday; empty means every day.
  final Set<int> weekdays;

  /// `HH:mm` of the reminder, or null.
  final String? time;
  final List<RoutineStep> steps;

  /// Points for finishing all steps.
  final int points;

  bool dueOn(DateTime day) =>
      weekdays.isEmpty || weekdays.contains(day.weekday);

  /// The reminder on [day], if [time] is set.
  DateTime? reminderOn(DateTime day) {
    final parts = time?.split(':');
    if (parts == null || parts.length != 2) return null;
    final h = int.tryParse(parts[0]), m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return DateTime(day.year, day.month, day.day, h, m);
  }

  String runId(DateTime day, String memberId) =>
      'rr-$id-${dayKey(day)}-${memberId.substring(0, memberId.length.clamp(0, 8))}';

  String pointsId(DateTime day, String memberId) =>
      'r-$id-${dayKey(day)}-${memberId.substring(0, memberId.length.clamp(0, 8))}';

  Map<String, Object?> toData() => {
    'title': title,
    'emoji': emoji,
    'memberId': memberId,
    'weekdays': weekdays.toList()..sort(),
    'time': time,
    'steps': [for (final s in steps) s.toJson()],
    'points': points,
  };
}

/// Progress of a routine on one day, in `Collections.routineRuns`.
class RoutineRun {
  const RoutineRun({
    required this.id,
    required this.routineId,
    required this.memberId,
    required this.day,
    this.done = const {},
  });

  factory RoutineRun.fromRecord(SyncRecord r) => RoutineRun(
    id: r.id,
    routineId: r.data['routineId'] as String? ?? '',
    memberId: r.data['memberId'] as String? ?? '',
    day: _parseDay(r.data['day']) ?? DateTime(2000),
    done: {for (final s in r.data['done'] as List? ?? []) s as String},
  );

  final String id;
  final String routineId;
  final String memberId;
  final DateTime day;
  final Set<String> done;

  Map<String, Object?> toData() => {
    'routineId': routineId,
    'memberId': memberId,
    'day': dayKey(day),
    'done': done.toList(),
  };
}

const _keep = Object();

DateTime? _parseDay(Object? v) {
  if (v is! String) return null;
  final d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}
