import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Keeps blocked edits visible and lets the member retry after a new share,
/// or identify the entry to repair in its usual editor.
Future<void> showSyncIssues(BuildContext context, SyncEngine engine) async {
  final records = engine.blockedChanges;
  if (records.isEmpty) {
    await engine.sync();
    return;
  }
  final retry = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr.syncBlockedTitle(records.length)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.syncBlockedFileBody),
              const SizedBox(height: 12),
              for (final r in records)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    [r.data['title'], r.data['name'], r.data['text']]
                            .whereType<String>()
                            .where((s) => s.trim().isNotEmpty)
                            .firstOrNull ??
                        tr.commonEntry,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr.commonClose),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr.commonRetry),
        ),
      ],
    ),
  );
  if (retry == true) await engine.retryBlockedChanges();
}
