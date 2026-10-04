import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

/// Runs [delete] and offers to bring back for a few seconds everything it
/// removed from [collections] (e.g. a shopping list with its items), as it
/// was: visibility and fields from other apps included.
///
/// [what] names it in the message („Milch“ gelöscht); [message] replaces
/// the whole message (e.g. for several items).
void deleteWithUndo(
  BuildContext context, {
  required Set<String> collections,
  required void Function() delete,
  String what = '',
  String? message,
}) {
  final engine = AppScope.read(context).engine!;
  final messenger = ScaffoldMessenger.of(context);
  final before = [for (final c in collections) ...engine.records(c)];
  delete();
  final gone = [
    for (final r in before)
      if (engine.record(r.collection, r.id) == null) r,
  ];
  if (gone.isEmpty) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message ?? (what.isEmpty ? 'Gelöscht' : '„$what“ gelöscht'),
        ),
        action: SnackBarAction(
          label: 'Rückgängig',
          onPressed: () => restoreRecords(engine, gone),
        ),
      ),
    );
}

/// Writes [records] back as they were before they were deleted.
void restoreRecords(SyncEngine engine, Iterable<SyncRecord> records) {
  for (final r in records) {
    engine.put(r.collection, r.id, r.data);
  }
}
