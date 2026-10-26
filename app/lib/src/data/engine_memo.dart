import 'dart:async';

import 'package:famio_client/famio_client.dart';

/// Results computed from some collections, kept until one of them changes.
///
/// The start page rebuilds on every change of the many collections it
/// shows – each location report of a family phone among them – and some
/// tiles look through years of data ("Heute vor einem Jahr": 12 ms with 600
/// appointments, more on a phone). Such a result is computed again only
/// when its own collections changed.
class EngineMemo {
  EngineMemo._(SyncEngine engine) {
    _changes = engine.changes.listen((changed) {
      _entries.removeWhere(
        (_, entry) => entry.collections.any(changed.contains),
      );
    });
  }

  static final _memos = Expando<EngineMemo>();

  static EngineMemo of(SyncEngine engine) =>
      _memos[engine] ??= EngineMemo._(engine);

  // Never cancelled: the memo lives as long as its engine.
  // ignore: unused_field
  late final StreamSubscription<Set<String>> _changes;
  final _entries = <String, ({Set<String> collections, Object? value})>{};

  /// The value for [key] (put the day and anything else it depends on into
  /// it), computed with [compute] unless it is still valid for
  /// [collections].
  T get<T>(String key, Set<String> collections, T Function() compute) {
    final entry = _entries[key];
    if (entry != null) return entry.value as T;
    final value = compute();
    _entries[key] = (collections: collections, value: value);
    return value;
  }
}
