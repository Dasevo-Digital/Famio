import '../sync_record.dart';

/// A family task (Aufgabe), stored in `Collections.tasks`.
class Task {
  const Task({
    required this.id,
    required this.title,
    this.notes = '',
    this.done = false,
    this.due,
    this.assigneeId,
    this.completedAt,
    this.createdAt,
    this.remindAt,
    this.repeat,
    this.repeatEvery = 1,
  });

  factory Task.fromRecord(SyncRecord r) => Task(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    notes: r.data['notes'] as String? ?? '',
    done: r.data['done'] as bool? ?? false,
    due: _date(r.data['due']),
    assigneeId: r.data['assigneeId'] as String?,
    completedAt: _date(r.data['completedAt']),
    createdAt: _date(r.data['createdAt']),
    remindAt: _date(r.data['remindAt'])?.toLocal(),
    repeat: TaskRepeat.parse(r.data['repeat']),
    repeatEvery: (r.data['repeatEvery'] as num?)?.toInt().clamp(1, 99) ?? 1,
  );

  final String id;
  final String title;
  final String notes;
  final bool done;
  final DateTime? due;
  final String? assigneeId;
  final DateTime? completedAt;
  final DateTime? createdAt;

  /// When to notify the assignee (everyone if unassigned).
  final DateTime? remindAt;

  /// How often it comes back; null: once.
  final TaskRepeat? repeat;

  /// Every how many [repeat] periods (2: every other week).
  final int repeatEvery;

  /// Nullable fields are cleared by passing `null` explicitly.
  Task copyWith({
    String? title,
    String? notes,
    bool? done,
    Object? due = _keep,
    Object? assigneeId = _keep,
    Object? completedAt = _keep,
    Object? remindAt = _keep,
    Object? repeat = _keep,
    int? repeatEvery,
  }) => Task(
    id: id,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    done: done ?? this.done,
    due: due == _keep ? this.due : due as DateTime?,
    assigneeId: assigneeId == _keep ? this.assigneeId : assigneeId as String?,
    completedAt: completedAt == _keep
        ? this.completedAt
        : completedAt as DateTime?,
    createdAt: createdAt,
    remindAt: remindAt == _keep ? this.remindAt : remindAt as DateTime?,
    repeat: repeat == _keep ? this.repeat : repeat as TaskRepeat?,
    repeatEvery: repeatEvery ?? this.repeatEvery,
  );

  /// Ticked off: a repeating task comes back open with its next due date
  /// (and reminder), the next one from [today] on; others are done.
  Task completed({DateTime? today}) {
    final now = today ?? DateTime.now();
    final r = repeat;
    if (r == null) return copyWith(done: true, completedAt: now);
    final day = DateTime(now.year, now.month, now.day);
    final from = due ?? day;
    var next = r.after(from, repeatEvery);
    while (next.isBefore(day)) {
      next = r.after(next, repeatEvery);
    }
    final shift = DateTime(
      next.year,
      next.month,
      next.day,
    ).difference(DateTime(from.year, from.month, from.day));
    return copyWith(
      due: next,
      remindAt: remindAt?.add(shift),
      done: false,
      completedAt: null,
    );
  }

  Map<String, Object?> toData() => {
    'title': title,
    'notes': notes,
    'done': done,
    'due': due?.toIso8601String(),
    'assigneeId': assigneeId,
    'completedAt': completedAt?.toIso8601String(),
    'createdAt': createdAt?.toIso8601String(),
    'remindAt': remindAt?.toUtc().toIso8601String(),
    'repeat': repeat?.name,
    'repeatEvery': repeat == null ? null : repeatEvery,
  };
}

/// How often a task comes back.
enum TaskRepeat {
  daily,
  weekly,
  monthly,
  yearly;

  static TaskRepeat? parse(Object? v) =>
      values.where((r) => r.name == v).firstOrNull;

  /// [every] periods after [from]; month ends stay month ends (31.1. →
  /// 28.2.).
  DateTime after(DateTime from, int every) => switch (this) {
    daily => DateTime(from.year, from.month, from.day + every),
    weekly => DateTime(from.year, from.month, from.day + 7 * every),
    monthly => _addMonths(from, every),
    yearly => _addMonths(from, 12 * every),
  };

  static DateTime _addMonths(DateTime from, int months) {
    final first = DateTime(from.year, from.month + months);
    final last = DateTime(first.year, first.month + 1, 0).day;
    return DateTime(first.year, first.month, from.day > last ? last : from.day);
  }

  /// "täglich", "alle 2 Wochen" …
  String label(int every) => switch (this) {
    daily => every == 1 ? 'täglich' : 'alle $every Tage',
    weekly => every == 1 ? 'wöchentlich' : 'alle $every Wochen',
    monthly => every == 1 ? 'monatlich' : 'alle $every Monate',
    yearly => every == 1 ? 'jährlich' : 'alle $every Jahre',
  };
}

const _keep = Object();

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
