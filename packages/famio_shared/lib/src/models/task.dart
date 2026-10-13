import '../sync_record.dart';
import '../texts.dart';
import 'chat.dart' show FileRef;

/// A family task (Aufgabe), stored in `Collections.tasks`.
class Task {
  const Task({
    required this.id,
    required this.title,
    this.notes = '',
    this.done = false,
    this.due,
    this.assigneeIds = const [],
    this.visibleTo,
    this.completedAt,
    this.createdAt,
    this.remindAt,
    this.repeat,
    this.repeatEvery = 1,
    this.checklist = const [],
    this.photos = const [],
  });

  factory Task.fromRecord(SyncRecord r) => Task(
    id: r.id,
    title: r.data['title'] as String? ?? '',
    notes: r.data['notes'] as String? ?? '',
    done: r.data['done'] as bool? ?? false,
    due: _date(r.data['due']),
    assigneeIds: assigneesIn(r.data),
    visibleTo: r.visibleTo,
    completedAt: _date(r.data['completedAt']),
    createdAt: _date(r.data['createdAt']),
    remindAt: _date(r.data['remindAt'])?.toLocal(),
    repeat: TaskRepeat.parse(r.data['repeat']),
    repeatEvery: (r.data['repeatEvery'] as num?)?.toInt().clamp(1, 99) ?? 1,
    checklist: [
      for (final i in r.data['checklist'] as List? ?? const [])
        if (i is Map) TaskStep.fromJson(i.cast()),
    ],
    photos: [
      for (final p in r.data['photos'] as List? ?? const [])
        ?FileRef.fromJson(p),
    ],
  );

  final String id;
  final String title;
  final String notes;
  final bool done;
  final DateTime? due;

  /// Who takes care of it; empty: everyone.
  final List<String> assigneeIds;

  /// Who may see it (see [SyncRecord.visibleTo]); null: the whole family
  /// apart from guests, who only see tasks assigned or shown to them.
  final List<String>? visibleTo;

  final DateTime? completedAt;
  final DateTime? createdAt;

  /// When to notify the assignee (everyone if unassigned).
  final DateTime? remindAt;

  /// How often it comes back; null: once.
  final TaskRepeat? repeat;

  /// Every how many [repeat] periods (2: every other week).
  final int repeatEvery;

  /// Steps to tick off (a packing list …); the task itself is ticked off
  /// separately.
  final List<TaskStep> checklist;

  /// Photos and other files for the task (what to buy, how it should look,
  /// the form to fill in). Stored as `photos`, the name from 2.0.1, when
  /// only images were possible: apps before 2.0.4 keep the other files when
  /// they save the task.
  final List<FileRef> photos;

  /// The first of [assigneeIds], all that apps before 2.0.3 know.
  String? get assigneeId => assigneeIds.firstOrNull;

  bool isAssignedTo(String memberId) => assigneeIds.contains(memberId);

  /// Who takes care of the task stored as [data]: `assigneeIds`, or the
  /// single `assigneeId` of apps before 2.0.3. When such an app changed
  /// the person, its `assigneeId` no longer leads the list and wins.
  static List<String> assigneesIn(Map<String, Object?> data) {
    final first = data['assigneeId'];
    final ids = [
      for (final id in data['assigneeIds'] as List? ?? const [])
        if (id is String) id,
    ];
    if (ids.isNotEmpty && ids.first == first) return ids;
    return [if (first is String) first];
  }

  /// "2/5" for the list.
  String? get checklistProgress => checklist.isEmpty
      ? null
      : '${checklist.where((i) => i.done).length}/${checklist.length}';

  /// Nullable fields are cleared by passing `null` explicitly.
  Task copyWith({
    String? title,
    String? notes,
    bool? done,
    Object? due = _keep,
    List<String>? assigneeIds,
    Object? visibleTo = _keep,
    Object? completedAt = _keep,
    Object? remindAt = _keep,
    Object? repeat = _keep,
    int? repeatEvery,
    List<TaskStep>? checklist,
    List<FileRef>? photos,
  }) => Task(
    id: id,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    done: done ?? this.done,
    due: due == _keep ? this.due : due as DateTime?,
    assigneeIds: assigneeIds ?? this.assigneeIds,
    visibleTo: visibleTo == _keep ? this.visibleTo : visibleTo as List<String>?,
    completedAt: completedAt == _keep
        ? this.completedAt
        : completedAt as DateTime?,
    createdAt: createdAt,
    remindAt: remindAt == _keep ? this.remindAt : remindAt as DateTime?,
    repeat: repeat == _keep ? this.repeat : repeat as TaskRepeat?,
    repeatEvery: repeatEvery ?? this.repeatEvery,
    checklist: checklist ?? this.checklist,
    photos: photos ?? this.photos,
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
      // Next time the list starts over.
      checklist: [for (final i in checklist) i.copyWith(done: false)],
    );
  }

  Map<String, Object?> toData() => {
    'title': title,
    'notes': notes,
    'done': done,
    'due': due?.toIso8601String(),
    'assigneeId': assigneeId,
    if (assigneeIds.length > 1) 'assigneeIds': assigneeIds,
    // Always written, also as null: the server keeps the audience only
    // when older apps, which do not know it, leave it out.
    SyncRecord.visibilityKey: visibleTo,
    'completedAt': completedAt?.toIso8601String(),
    'createdAt': createdAt?.toIso8601String(),
    'remindAt': remindAt?.toUtc().toIso8601String(),
    'repeat': repeat?.name,
    'repeatEvery': repeat == null ? null : repeatEvery,
    if (checklist.isNotEmpty)
      'checklist': [for (final i in checklist) i.toJson()],
    if (photos.isNotEmpty) 'photos': [for (final p in photos) p.toJson()],
  };
}

/// One step of a task's checklist.
class TaskStep {
  const TaskStep({required this.id, required this.text, this.done = false});

  factory TaskStep.fromJson(Map<String, Object?> json) => TaskStep(
    id: json['id'] as String? ?? '',
    text: json['text'] as String? ?? '',
    done: json['done'] as bool? ?? false,
  );

  final String id;
  final String text;
  final bool done;

  TaskStep copyWith({String? text, bool? done}) =>
      TaskStep(id: id, text: text ?? this.text, done: done ?? this.done);

  Map<String, Object?> toJson() => {'id': id, 'text': text, 'done': done};
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
  String label(int every) {
    String t(String german) =>
        sharedText('Recurrence|$german', german, {'every': every});
    return switch (this) {
      daily => every == 1 ? t('täglich') : t('alle {every} Tage'),
      weekly => every == 1 ? t('wöchentlich') : t('alle {every} Wochen'),
      monthly => every == 1 ? t('monatlich') : t('alle {every} Monate'),
      yearly => every == 1 ? t('jährlich') : t('alle {every} Jahre'),
    };
  }
}

const _keep = Object();

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
