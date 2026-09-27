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

  /// Nullable fields are cleared by passing `null` explicitly.
  Task copyWith({
    String? title,
    String? notes,
    bool? done,
    Object? due = _keep,
    Object? assigneeId = _keep,
    Object? completedAt = _keep,
    Object? remindAt = _keep,
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
  );

  Map<String, Object?> toData() => {
    'title': title,
    'notes': notes,
    'done': done,
    'due': due?.toIso8601String(),
    'assigneeId': assigneeId,
    'completedAt': completedAt?.toIso8601String(),
    'createdAt': createdAt?.toIso8601String(),
    'remindAt': remindAt?.toUtc().toIso8601String(),
  };
}

const _keep = Object();

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
