import 'dart:convert';

import 'package:famio_client/famio_client.dart';

/// What an editor saves when the entry changed on another device while it
/// was open (#483): the stored entry as it is now ([current]), with only
/// the fields the editor changed ([edited] against [opened], its state
/// when it opened) put in. A step ticked off meanwhile stays ticked off, a
/// task done meanwhile stays done, when only the title was changed here.
///
/// Lists of entries with an `id` (checklist steps, photos) are merged per
/// entry the same way: steps added or removed on the other device are
/// kept, those added or removed here too; a list that is not there counts
/// as an empty one (a first step on both devices). Lists of plain values
/// (people, skipped dates of a series) merge as sets; a list that is not
/// there at all (no audience: everyone) is no empty set and is replaced as
/// a whole.
Map<String, Object?> mergeEdit({
  required Map<String, Object?> opened,
  required Map<String, Object?> edited,
  required Map<String, Object?> current,
}) {
  final result = {...current};
  // Who takes care of a task: the single `assigneeId` of older apps and
  // the list, as one (see Task.assigneesIn).
  final people = [
    opened,
    edited,
    current,
  ].any((d) => d.containsKey('assigneeId'));
  if (people) {
    final before = Task.assigneesIn(opened);
    final after = Task.assigneesIn(edited);
    if (!_same(before, after)) {
      final merged = _mergeSet(before, after, Task.assigneesIn(current));
      result['assigneeId'] = merged.firstOrNull;
      if (merged.length > 1) {
        result['assigneeIds'] = merged;
      } else {
        result.remove('assigneeIds');
      }
    }
  }
  for (final key in {...opened.keys, ...edited.keys}) {
    if (people && (key == 'assigneeId' || key == 'assigneeIds')) continue;
    final before = opened[key];
    final after = edited[key];
    if (_same(before, after)) continue;
    final now = current[key];
    final ids = _idLists(before, after, now);
    if (ids != null) {
      final merged = _mergeList(ids.$1, ids.$2, ids.$3);
      if (merged.isEmpty && !edited.containsKey(key)) {
        result.remove(key);
      } else {
        result[key] = merged;
      }
    } else if (_values(before) != null &&
        _values(after) != null &&
        _values(now) != null) {
      result[key] = _mergeSet(_values(before)!, _values(after)!, _values(now)!);
    } else if (edited.containsKey(key)) {
      result[key] = after;
    } else {
      result.remove(key);
    }
  }
  return result;
}

/// The three as lists of entries with ids, a missing one as empty; null
/// unless one of them is such a list and none is anything else.
(
  List<Map<String, Object?>>,
  List<Map<String, Object?>>,
  List<Map<String, Object?>>,
)?
_idLists(Object? before, Object? after, Object? now) {
  final lists = [before, after, now];
  if (!lists.any((l) => l is List && l.isNotEmpty && _idList(l) != null)) {
    return null;
  }
  if (lists.any((l) => l != null && _idList(l) == null)) return null;
  return (
    _idList(before) ?? const [],
    _idList(after) ?? const [],
    _idList(now) ?? const [],
  );
}

/// [value] as a list of plain values (strings, numbers), else null.
List<Object>? _values(Object? value) {
  if (value is! List) return null;
  if (value.any((e) => e is! String && e is! num && e is! bool)) return null;
  return value.cast<Object>();
}

/// What is there now, without what was taken out here, with what was
/// added here.
List<Object> _mergeSet(
  List<Object> opened,
  List<Object> edited,
  List<Object> current,
) {
  final removed = {...opened}..removeAll(edited);
  return [
    for (final v in current)
      if (!removed.contains(v)) v,
    for (final v in edited)
      if (!current.contains(v) && !opened.contains(v)) v,
  ];
}

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

/// [value] as a list of entries that all have an id, else null. An empty
/// list counts as one.
List<Map<String, Object?>>? _idList(Object? value) {
  if (value is! List) return null;
  final entries = <Map<String, Object?>>[];
  for (final e in value) {
    if (e is! Map || e['id'] is! String) return null;
    entries.add(e.cast<String, Object?>());
  }
  return entries;
}

List<Map<String, Object?>> _mergeList(
  List<Map<String, Object?>> opened,
  List<Map<String, Object?>> edited,
  List<Map<String, Object?>> current,
) {
  Map<String, Map<String, Object?>> byId(List<Map<String, Object?>> l) => {
    for (final e in l) e['id'] as String: e,
  };
  final before = byId(opened);
  final after = byId(edited);
  final now = byId(current);
  final result = <Map<String, Object?>>[];
  for (final e in edited) {
    final id = e['id'] as String;
    final was = before[id];
    final stored = now[id];
    if (was == null) {
      // Added here.
      result.add(e);
    } else if (stored == null) {
      // Gone on the other device: back only if it was changed here.
      if (!_same(was, e)) result.add(e);
    } else {
      result.add(mergeEdit(opened: was, edited: e, current: stored));
    }
  }
  // Added on the other device meanwhile.
  for (final e in current) {
    final id = e['id'] as String;
    if (!before.containsKey(id) && !after.containsKey(id)) result.add(e);
  }
  return result;
}

extension EditMerge on SyncEngine {
  /// The data to store when an editor opened on [opened] (null: a new
  /// entry) saves [data]; see [mergeEdit].
  Map<String, Object?> edited(
    String collection,
    String id,
    Map<String, Object?> data, {
    Map<String, Object?>? opened,
  }) {
    final now = opened == null ? null : record(collection, id);
    return now == null
        ? data
        : mergeEdit(opened: opened!, edited: data, current: now.data);
  }

  /// Stores [data] as an editor opened on [opened] saves it.
  void putEdited(
    String collection,
    String id,
    Map<String, Object?> data, {
    Map<String, Object?>? opened,
  }) => put(collection, id, edited(collection, id, data, opened: opened));
}
