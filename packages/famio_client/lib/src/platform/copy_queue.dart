import 'package:famio_shared/famio_shared.dart';

/// One ordered lifetime per copy, shared by old and newly opened stores.
/// Clearing invalidates all old writers before the final deletion is queued.
class CopyQueue {
  static final _queues = <String, CopyQueue>{};
  static CopyQueue named(String name) => _queues.putIfAbsent(name, CopyQueue._);
  CopyQueue._();

  Future<void> _tail = Future.value();
  String? _lease;
  String enable() => _lease = newId();
  bool owns(String? lease) => lease != null && _lease == lease;
  Future<void> get idle => _tail;

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> clear(Future<void> Function() remove) {
    _lease = null;
    return run(remove);
  }
}
