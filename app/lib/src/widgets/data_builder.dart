import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/widgets.dart';

import '../app_state.dart';
import 'section_shown.dart';

/// Rebuilds [builder] whenever one of [collections] changes, locally or
/// through sync. Use `'members'` to listen for family member updates.
/// In a section that is not shown (the start page behind the open chat) it
/// only notes the change and rebuilds once it is shown again.
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
  var _shown = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Shown again: the dependency change rebuilds with what came meanwhile.
    _shown = SectionShown.of(context);
    final engine = AppScope.of(context).engine;
    if (engine != _engine) {
      _sub?.cancel();
      _engine = engine;
      _sub = engine?.changes.listen((changed) {
        if (_shown && changed.any(widget.collections.contains)) {
          setState(() {});
        }
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
