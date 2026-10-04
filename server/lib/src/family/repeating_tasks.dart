import 'package:famio_shared/famio_shared.dart';
import 'package:timezone/timezone.dart' as tz;

import '../record_store.dart';

/// Repeating tasks ticked off elsewhere (Home Assistant, a reminder app,
/// Microsoft To Do, an older app) come back open with their next due date,
/// as the app does it itself. Returns true if any task changed.
bool advanceRepeatingTasks(
  RecordStore records,
  Iterable<String> ids, {
  required tz.Location location,
}) {
  final now = tz.TZDateTime.now(location);
  final today = DateTime(now.year, now.month, now.day);
  return records.writeAsServer([
    for (final id in {...ids})
      if (records.get(Collections.tasks, id) case final r?
          when !r.deleted && r.data['done'] == true && r.data['repeat'] != null)
        r.copyWith(
          data: {
            ...r.data,
            ...Task.fromRecord(r).completed(today: today).toData(),
          },
        ),
  ]);
}
