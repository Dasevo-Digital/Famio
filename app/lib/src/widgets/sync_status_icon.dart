import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// Cloud bubble showing the sync state; tapping it syncs immediately.
class SyncStatusIcon extends StatelessWidget {
  const SyncStatusIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final c = FamioColors.of(context);
    return StreamBuilder<SyncStatus>(
      stream: engine.statusChanges,
      initialData: engine.status,
      builder: (context, snapshot) {
        final status = snapshot.data!;
        final pending = engine.store.dirty.length;
        final (icon, color, text) = switch (status.state) {
          SyncState.syncing => (
            AppIcons.cloudArrowUp,
            c.inkSoft,
            'Synchronisiere …',
          ),
          SyncState.offline => (
            AppIcons.cloudSlash,
            Theme.of(context).colorScheme.error,
            'Offline – $pending Änderung(en) warten\n${status.message ?? ''}',
          ),
          _ when pending > 0 => (
            AppIcons.cloudArrowUp,
            c.inkSoft,
            '$pending Änderung(en) warten',
          ),
          _ => (
            AppIcons.cloudCheck,
            FamioSection.tasks.strong,
            status.lastSync == null
                ? 'Synchronisiert'
                : 'Synchronisiert um ${DateFormat.jm(appLanguage).format(status.lastSync!)}',
          ),
        };
        return BubbleButton(
          icon: icon,
          color: color,
          tooltip: text.trim(),
          onPressed: engine.sync,
        );
      },
    );
  }
}
