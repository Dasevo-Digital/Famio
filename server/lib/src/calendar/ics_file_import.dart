import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:timezone/timezone.dart' as tz;

import 'event_ics.dart';
import 'ics.dart';
import 'ics_import.dart';

/// What a calendar file (`.ics`) brings into the family calendar.
class IcsFileContent {
  const IcsFileContent({
    required this.events,
    required this.skipped,
    this.expanded = 0,
  });

  /// Ordinary Famio events, series as series. Their ids come from the UID,
  /// so importing the same file again updates instead of duplicating.
  final List<CalendarEvent> events;

  /// Entries that cannot be taken over: title and why.
  final List<({String title, String reason})> skipped;

  /// Series with a rule Famio cannot repeat, taken over as single events.
  final int expanded;
}

/// Reads a calendar file, e.g. a school year exported from another
/// calendar or an invitation from an e-mail. Nothing is saved: the app shows
/// the events and saves those the member picks.
IcsFileContent readIcsFile(
  String text, {
  required tz.Location location,
  DateTime? now,
  int maxEvents = 2000,
}) {
  final root = parseIcs(text);
  final calendars = root.components('VCALENDAR').toList();
  final vevents = [
    for (final c in calendars.isEmpty ? [root] : calendars)
      ...c.components('VEVENT'),
  ];

  // The VEVENTs of one UID: a series with its changed occurrences.
  final groups = <String, List<IcsComponent>>{};
  var anonymous = 0;
  for (final v in vevents) {
    final uid = v.property('UID')?.value.trim() ?? '';
    final key = uid.isNotEmpty
        ? uid
        // Without a UID the summary and start keep a re-import stable.
        : 'no-uid|${v.property('SUMMARY')?.value}|'
              '${v.property('DTSTART')?.value}|${anonymous++}';
    (groups[key] ??= []).add(v);
  }

  final today = now ?? DateTime.now();
  final events = <CalendarEvent>[];
  final skipped = <({String title, String reason})>[];
  var expanded = 0;
  for (final MapEntry(key: key, value: group) in groups.entries) {
    if (events.length >= maxEvents) break;
    final title =
        group.first.property('SUMMARY')?.text.trim().isNotEmpty ?? false
        ? group.first.property('SUMMARY')!.text.trim()
        : '(Ohne Titel)';
    final id = sha1
        .convert(utf8.encode('ics-file|$key'))
        .toString()
        .substring(0, 32);
    final parsed = parseEventComponents(group, id: id, location: location);
    if (parsed.event case final event?) {
      events
        ..add(event)
        ..addAll(parsed.detached);
      continue;
    }
    // A rule Famio cannot repeat (or only changed occurrences): the
    // occurrences of the last year and the next two as single events.
    final singles = importIcs(
      _calendar(group),
      sourceId: 'ics-file|$key',
      fallback: location,
      from: today.subtract(const Duration(days: 365)),
      to: today.add(const Duration(days: 730)),
      maxEvents: 500,
    );
    if (singles.isEmpty) {
      skipped.add((title: title, reason: parsed.unsupported ?? ''));
      continue;
    }
    expanded++;
    events.addAll([
      for (final e in singles)
        // Plain family events, not entries of a subscription.
        CalendarEvent(
          id: e.id,
          title: e.title,
          start: e.start,
          end: e.end,
          allDay: e.allDay,
          location: e.location,
          notes: e.notes,
        ),
    ]);
  }
  return IcsFileContent(
    events: events.take(maxEvents).toList(),
    skipped: skipped,
    expanded: expanded,
  );
}

/// [vevents] as a calendar of their own.
String _calendar(List<IcsComponent> vevents) {
  final w = IcsWriter()
    ..begin('VCALENDAR')
    ..line('VERSION', '2.0');
  void write(IcsComponent c) {
    w.begin(c.name);
    for (final p in c.properties) {
      w.line(p.name, p.value, {
        for (final e in p.params.entries)
          e.key: RegExp(r'[:;,]').hasMatch(e.value) ? '"${e.value}"' : e.value,
      });
    }
    c.children.forEach(write);
    w.end(c.name);
  }

  vevents.forEach(write);
  w.end('VCALENDAR');
  return w.toString();
}
