import 'package:sqlite3/sqlite3.dart';

/// Which steps of task checklists calendar apps were shown as to-dos of
/// their own (see `CalDavServer`), and when they disappeared: a
/// sync-collection (RFC 6578) has to name every resource that is gone, but
/// a removed step leaves no deletion mark in the records.
class DavStepMarks {
  DavStepMarks(Database db) : _db = db;

  DavStepMarks._none() : _db = null;

  /// Remembers nothing (tests and tools without a database): removed steps
  /// then only disappear with a full listing.
  static final none = DavStepMarks._none();

  final Database? _db;

  /// Notes the current steps of tasks (task id → its revision and step
  /// ids). Known steps no longer there count as removed at that revision.
  void note(Map<String, (int, Iterable<String>)> tasks) {
    final db = _db;
    if (db == null || tasks.isEmpty) return;
    final known = <String, Set<String>>{};
    for (final row in db.select(
      'SELECT task_id, step_id FROM dav_steps WHERE removed_rev IS NULL',
    )) {
      (known[row['task_id'] as String] ??= {}).add(row['step_id'] as String);
    }
    final removed = <(String, String, int)>[];
    final added = <(String, String)>[];
    for (final MapEntry(key: task, value: (rev, steps)) in tasks.entries) {
      final now = steps.toSet();
      final before = known[task] ?? const <String>{};
      for (final id in before.difference(now)) {
        removed.add((task, id, rev));
      }
      for (final id in now.difference(before)) {
        added.add((task, id));
      }
    }
    if (removed.isEmpty && added.isEmpty) return;
    db.execute('BEGIN');
    try {
      for (final (task, step, rev) in removed) {
        db.execute(
          'UPDATE dav_steps SET removed_rev = ? WHERE task_id = ? AND step_id = ?',
          [rev, task, step],
        );
      }
      for (final (task, step) in added) {
        db.execute(
          'INSERT INTO dav_steps (task_id, step_id) VALUES (?, ?)'
          ' ON CONFLICT DO UPDATE SET removed_rev = NULL',
          [task, step],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Steps removed after [rev].
  List<String> removedSince(int rev) => [
    for (final row
        in _db?.select('SELECT step_id FROM dav_steps WHERE removed_rev > ?', [
              rev,
            ]) ??
            const <Row>[])
      row['step_id'] as String,
  ];

  /// Every step ever shown of [taskId] (for a task a member lost access to).
  List<String> of(String taskId) => [
    for (final row
        in _db?.select('SELECT step_id FROM dav_steps WHERE task_id = ?', [
              taskId,
            ]) ??
            const <Row>[])
      row['step_id'] as String,
  ];

  /// Forgets removals older than any sync token still accepted.
  void purge(int belowRev) => _db?.execute(
    'DELETE FROM dav_steps WHERE removed_rev IS NOT NULL AND removed_rev < ?',
    [belowRev],
  );
}
