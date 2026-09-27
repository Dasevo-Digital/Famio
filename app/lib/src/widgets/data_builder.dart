import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/widgets.dart';

import '../app_state.dart';

/// Rebuilds [builder] whenever one of [collections] changes, locally or
/// through sync. Use `'members'` to listen for family member updates.
class DataBuilder extends StatefulWidget {
  const DataBuilder({
    super.key,
    required this.collections,
    required this.builder,
  });

  final Set<String> collections;
  final Widget Function(BuildContext context, SyncEngine engine) builder;

  @override
  State<DataBuilder> createState() => _DataBuilderState();
}

class _DataBuilderState extends State<DataBuilder> {
  StreamSubscription<Set<String>>? _sub;
  SyncEngine? _engine;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final engine = AppScope.of(context).engine;
    if (engine != _engine) {
      _sub?.cancel();
      _engine = engine;
      _sub = engine?.changes.listen((changed) {
        if (changed.any(widget.collections.contains)) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    return engine == null
        ? const SizedBox.shrink()
        : widget.builder(context, engine);
  }
}
