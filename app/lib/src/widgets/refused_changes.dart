import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Tells once when the server turned down own edits (#539): this account
/// may not make them, and the stored version is back on the device. Or
/// kept them only partly (#550): what this account may not change there
/// stayed as it was.
/// The server's code for an edit it kept only partly.
const partlyKept = 'partly_kept';

class RefusedChangesNotice extends StatefulWidget {
  const RefusedChangesNotice({
    super.key,
    required this.engine,
    required this.child,
  });

  final SyncEngine engine;
  final Widget child;

  @override
  State<RefusedChangesNotice> createState() => _RefusedChangesNoticeState();
}

class _RefusedChangesNoticeState extends State<RefusedChangesNotice> {
  StreamSubscription<void>? _listening;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant RefusedChangesNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      unawaited(_listening?.cancel());
      _listen();
    }
  }

  void _listen() {
    _listening = widget.engine.refusedChanges.listen((_) => _tell());
    // Turned down before this was shown, e.g. in the first sync.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tell());
  }

  void _tell() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final issues = widget.engine.takeRefusedChanges();
    if (issues.isEmpty) return;
    final partly = issues.where((i) => i.code == partlyKept).length;
    final refused = issues.length - partly;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          [
            if (refused > 0) tr.syncChangesRefused(refused),
            if (partly > 0) tr.syncChangesPartlyKept(partly),
          ].join('\n'),
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_listening?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
