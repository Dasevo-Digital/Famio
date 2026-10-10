import 'package:famio_shared/famio_shared.dart';
import 'package:timezone/timezone.dart' as tz;

import 'ics.dart';

/// Famio tasks and shopping items as iCalendar to-dos (VTODO, RFC 5545),
/// for reminder apps connected via CalDAV (Apple Reminders, Thunderbird,
/// Tasks.org with DAVx5).
///
/// What Famio has no field for (priority, repetition, subtasks, Apple's
/// sort order …) is kept as it came and written back, so editing in Famio
/// loses nothing.

/// Properties of the to-do Famio did not interpret, as
/// `[{n: name, v: raw value, p: params}]`.
const icalExtraKey = '${SyncRecord.externalPrefix}ical';

/// The DUE property as sent, when it had a time of day (Famio's due date is
/// only a day): written back as long as the day stays the same.
const icalDueKey = '${SyncRecord.externalPrefix}due';

const _handled = {
  'UID',
  'DTSTAMP',
  'SUMMARY',
  'DESCRIPTION',
  'DUE',
  'STATUS',
  'COMPLETED',
  'PERCENT-COMPLETE',
  'CREATED',
  'LAST-MODIFIED',
  'SEQUENCE',
  'CATEGORIES',
};

/// What a to-do sent by an app says, in Famio's terms.
class ParsedTodo {
  ParsedTodo({
    required this.title,
    required this.description,
    required this.done,
    this.completedAt,
    this.due,
    this.dueRaw,
    this.remindAt,
    this.categories = '',
    this.extra = const [],
    this.repeat,
    this.repeatEvery = 1,
    this.parent,
  });

  final String title;
  final String description;
  final bool done;
  final DateTime? completedAt;

  /// The due day (local date at midnight).
  final DateTime? due;
  final Map<String, Object?>? dueRaw;
  final DateTime? remindAt;
  final String categories;
  final List<Map<String, Object?>> extra;

  /// A simple repetition Famio can represent (others stay in [extra]).
  final TaskRepeat? repeat;
  final int repeatEvery;

  /// The UID of the to-do this one is a subtask of (`RELATED-TO`, by
  /// default of type PARENT), as Apple Reminders writes subtasks.
  final String? parent;
}

/// FREQ and INTERVAL only, e.g. `FREQ=WEEKLY;INTERVAL=2`; anything else
/// (BYDAY, COUNT, UNTIL …) is not Famio's.
(TaskRepeat, int)? _simpleRule(String value) {
  final parts = {
    for (final p in value.split(';'))
      if (p.contains('='))
        p.substring(0, p.indexOf('=')).toUpperCase(): p.substring(
          p.indexOf('=') + 1,
        ),
  };
  if (parts.keys.any((k) => k != 'FREQ' && k != 'INTERVAL' && k != 'WKST')) {
    return null;
  }
  final repeat = switch (parts['FREQ']?.toUpperCase()) {
    'DAILY' => TaskRepeat.daily,
    'WEEKLY' => TaskRepeat.weekly,
    'MONTHLY' => TaskRepeat.monthly,
    'YEARLY' => TaskRepeat.yearly,
    _ => null,
  };
  final every = int.tryParse(parts['INTERVAL'] ?? '1') ?? 0;
  if (repeat == null || every < 1 || every > 99) return null;
  return (repeat, every);
}

/// Reads the first VTODO of [text]; null if there is none.
ParsedTodo? parseTodoIcs(String text, {required tz.Location location}) {
  final todo = parseIcs(
    text,
  ).components('VCALENDAR').expand((c) => c.components('VTODO')).firstOrNull;
  if (todo == null) return null;

  final dueProp = todo.property('DUE');
  final due = parseIcsTime(dueProp, location);
  DateTime? dueDay;
  Map<String, Object?>? dueRaw;
  if (due != null) {
    if (due.dateOnly) {
      dueDay = DateTime(due.wall.year, due.wall.month, due.wall.day);
    } else {
      final local = tz.TZDateTime.from(due.instant, location);
      dueDay = DateTime(local.year, local.month, local.day);
      dueRaw = _raw(dueProp!);
    }
  }

  final rrule = todo.property('RRULE');
  final rule = rrule == null ? null : _simpleRule(rrule.value);
  final status = todo.property('STATUS')?.value.trim().toUpperCase();
  final completed = parseIcsTime(todo.property('COMPLETED'), tz.UTC);
  final done = status == 'COMPLETED' || (status == null && completed != null);

  return ParsedTodo(
    title: todo.property('SUMMARY')?.text.trim() ?? '',
    description: todo.property('DESCRIPTION')?.text.trim() ?? '',
    done: done,
    completedAt: done ? (completed?.instant ?? DateTime.now().toUtc()) : null,
    due: dueDay,
    dueRaw: dueRaw,
    remindAt: _alarm(todo, due),
    categories: [
      for (final p in todo.all('CATEGORIES'))
        for (final c in _splitList(p.value))
          if (c.trim().isNotEmpty) unescapeText(c.trim()),
    ].join(', '),
    extra: [
      for (final p in todo.properties)
        if (!_handled.contains(p.name) && !(p.name == 'RRULE' && rule != null))
          _raw(p),
    ],
    repeat: rule?.$1,
    repeatEvery: rule?.$2 ?? 1,
    parent: [
      for (final p in todo.all('RELATED-TO'))
        if ((p.params['RELTYPE'] ?? 'PARENT').toUpperCase() == 'PARENT' &&
            p.value.trim().isNotEmpty)
          p.value.trim(),
    ].firstOrNull,
  );
}

/// The point in time of the first reminder: absolute, or relative to DUE.
DateTime? _alarm(IcsComponent todo, IcsTime? due) {
  for (final alarm in todo.components('VALARM')) {
    final trigger = alarm.property('TRIGGER');
    if (trigger == null) continue;
    if (trigger.params['VALUE'] == 'DATE-TIME') {
      final at = parseIcsTime(trigger, tz.UTC);
      if (at != null) return at.instant.toLocal();
      continue;
    }
    final offset = parseIcsDuration(trigger.value);
    if (offset != null && due != null) {
      return due.instant.add(offset).toLocal();
    }
  }
  return null;
}

/// Comma separated values, honouring escaped commas.
List<String> _splitList(String value) => value.split(RegExp(r'(?<!\\),'));

Map<String, Object?> _raw(IcsProperty p) => {
  'n': p.name,
  'v': p.value,
  if (p.params.isNotEmpty) 'p': p.params,
};

void _writeRaw(IcsWriter w, Object? raw) {
  if (raw is! Map) return;
  final name = raw['n'];
  final value = raw['v'];
  if (name is! String || value is! String || name.isEmpty) return;
  final params = <String, String>{
    for (final e in ((raw['p'] as Map?) ?? const {}).entries)
      '${e.key}': _quoteParam('${e.value}'),
  };
  w.line(name, value, params);
}

String _quoteParam(String v) => v.contains(RegExp('[:;,]')) ? '"$v"' : v;

/// The VTODO of a Famio task.
String taskToIcs(SyncRecord r, {required tz.Location location}) {
  final task = Task.fromRecord(r);
  final repeat = task.repeat;
  return _todo(
    r,
    location: location,
    title: task.title,
    description: task.notes,
    done: task.done,
    completedAt: task.completedAt,
    due: task.due,
    remindAt: task.remindAt,
    createdAt: task.createdAt,
    rule: repeat == null
        ? null
        : 'FREQ=${repeat.name.toUpperCase()}'
              '${task.repeatEvery > 1 ? ';INTERVAL=${task.repeatEvery}' : ''}',
  );
}

/// The VTODO of an item on a shopping list: the quantity as its note.
String shoppingItemToIcs(SyncRecord r, {required tz.Location location}) {
  final item = ShoppingItem.fromRecord(r);
  return _todo(
    r,
    location: location,
    title: item.name,
    description: item.quantity,
    done: item.checked,
    categories: item.category,
  );
}

String _todo(
  SyncRecord r, {
  required tz.Location location,
  required String title,
  required String description,
  required bool done,
  DateTime? completedAt,
  DateTime? due,
  DateTime? remindAt,
  DateTime? createdAt,
  String categories = '',
  String? rule,
}) {
  final modified = DateTime.fromMillisecondsSinceEpoch(
    r.updatedAt,
    isUtc: true,
  );
  final w = IcsWriter()
    ..begin('VCALENDAR')
    ..line('VERSION', '2.0')
    ..line('PRODID', '-//Famio//Famio Server//DE')
    ..begin('VTODO')
    ..line('UID', r.id)
    ..line('DTSTAMP', formatIcsTime(modified, utc: true))
    ..line('LAST-MODIFIED', formatIcsTime(modified, utc: true))
    ..text('SUMMARY', title)
    ..text('DESCRIPTION', description);
  if (createdAt != null) {
    w.line('CREATED', formatIcsTime(createdAt.toUtc(), utc: true));
  }
  if (due != null) {
    final raw = r.data[icalDueKey];
    if (raw is Map && _sameDay(raw, due, location)) {
      _writeRaw(w, raw);
    } else {
      w.line('DUE', formatIcsTime(due, dateOnly: true), {'VALUE': 'DATE'});
    }
  }
  if (done) {
    w
      ..line('STATUS', 'COMPLETED')
      ..line('PERCENT-COMPLETE', '100')
      ..line(
        'COMPLETED',
        formatIcsTime((completedAt ?? modified).toUtc(), utc: true),
      );
  } else {
    w.line('STATUS', 'NEEDS-ACTION');
  }
  if (categories.isNotEmpty) w.text('CATEGORIES', categories);
  // Famio's own repetition replaces one an app stored before.
  if (rule != null) w.line('RRULE', rule);
  for (final raw in (r.data[icalExtraKey] as List?) ?? const []) {
    if (rule != null && raw is Map && raw['n'] == 'RRULE') continue;
    _writeRaw(w, raw);
  }
  if (remindAt != null) {
    w
      ..begin('VALARM')
      ..line('ACTION', 'DISPLAY')
      ..text('DESCRIPTION', title.isEmpty ? 'Erinnerung' : title)
      ..line('TRIGGER', formatIcsTime(remindAt.toUtc(), utc: true), {
        'VALUE': 'DATE-TIME',
      })
      ..end('VALARM');
  }
  w
    ..end('VTODO')
    ..end('VCALENDAR');
  return w.toString();
}

/// A step of [task]'s checklist as a to-do of its own whose parent is the
/// task: reminder apps show it as a subtask.
String stepToIcs(SyncRecord task, TaskStep step) {
  final modified = DateTime.fromMillisecondsSinceEpoch(
    task.updatedAt,
    isUtc: true,
  );
  final w = IcsWriter()
    ..begin('VCALENDAR')
    ..line('VERSION', '2.0')
    ..line('PRODID', '-//Famio//Famio Server//DE')
    ..begin('VTODO')
    ..line('UID', step.id)
    ..line('DTSTAMP', formatIcsTime(modified, utc: true))
    ..line('LAST-MODIFIED', formatIcsTime(modified, utc: true))
    ..text('SUMMARY', step.text)
    ..line('RELATED-TO', task.id, {'RELTYPE': 'PARENT'});
  if (step.done) {
    w
      ..line('STATUS', 'COMPLETED')
      ..line('PERCENT-COMPLETE', '100')
      ..line('COMPLETED', formatIcsTime(modified, utc: true));
  } else {
    w.line('STATUS', 'NEEDS-ACTION');
  }
  w
    ..end('VTODO')
    ..end('VCALENDAR');
  return w.toString();
}

/// Whether the stored DUE with a time still falls on [due]'s day.
bool _sameDay(Map raw, DateTime due, tz.Location location) {
  final value = raw['v'];
  if (value is! String) return false;
  final params = <String, String>{
    for (final e in ((raw['p'] as Map?) ?? const {}).entries)
      '${e.key}': '${e.value}',
  };
  final time = parseIcsTime(IcsProperty('DUE', value, params), location);
  if (time == null) return false;
  final local = tz.TZDateTime.from(time.instant, location);
  return local.year == due.year &&
      local.month == due.month &&
      local.day == due.day;
}

/// The data of a task after an app sent [todo], on top of [existing]
/// (assignee and visibility are Famio's own and stay).
Map<String, Object?> taskDataFrom(ParsedTodo todo, Task? existing) => {
  ...(existing?.copyWith(
            title: todo.title,
            notes: todo.description,
            done: todo.done,
            due: todo.due,
            completedAt: todo.completedAt,
            remindAt: todo.remindAt,
            repeat: todo.repeat,
            repeatEvery: todo.repeatEvery,
          ) ??
          Task(
            id: '',
            title: todo.title,
            notes: todo.description,
            done: todo.done,
            due: todo.due,
            completedAt: todo.completedAt,
            createdAt: DateTime.now(),
            remindAt: todo.remindAt,
            repeat: todo.repeat,
            repeatEvery: todo.repeatEvery,
          ))
      .toData(),
  ..._external(todo),
};

/// The data of a shopping item on [listId] after an app sent [todo].
Map<String, Object?> shoppingItemDataFrom(
  ParsedTodo todo,
  String listId,
  ShoppingItem? existing,
) => {
  ...ShoppingItem(
    id: '',
    listId: listId,
    name: todo.title,
    quantity: todo.description.split('\n').first.trim(),
    checked: todo.done,
    category: todo.categories.isNotEmpty
        ? todo.categories
        : existing?.category ?? '',
    // Other apps know nothing of whose thing it is (packing lists).
    memberId: existing?.memberId,
  ).toData(),
  ..._external(todo),
};

Map<String, Object?> _external(ParsedTodo todo) => {
  icalExtraKey: todo.extra.isEmpty ? null : todo.extra,
  icalDueKey: todo.dueRaw,
};
