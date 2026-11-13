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
/// kept, those added or removed here too.
Map<String, Object?> mergeEdit({
  required Map<String, Object?> opened,
  required Map<String, Object?> edited,
  required Map<String, Object?> current,
}) {
  final result = {...current};
  for (final key in {...opened.keys, ...edited.keys}) {
    final before = opened[key];
    final after = edited[key];
    if (_same(before, after)) continue;
    final now = current[key];
    if (_idList(before) != null &&
        _idList(after) != null &&
        (now == null || _idList(now) != null)) {
      result[key] = _mergeList(
        _idList(before)!,
        _idList(after)!,
        _idList(now) ?? const [],
      );
    } else if (edited.containsKey(key)) {
      result[key] = after;
    } else {
      result.remove(key);
    }
  }
  return result;
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
