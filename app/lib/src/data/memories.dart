import 'package:famio_client/famio_client.dart';

import 'engine_memo.dart';
import 'family_data.dart';
import '../l10n.dart';

/// One memory of this calendar day in an earlier year.
typedef MemoryLine = ({int yearsAgo, String text});

/// "Heute vor einem Jahr": what happened on [Memories.day]'s date in
/// earlier years – the children's milestones, trips, photos of the chat
/// and of PhotoVault.
class Memories {
  const Memories({required this.lines, required this.photos});

  /// Newest first.
  final List<MemoryLine> lines;

  /// Photos of the chat and of PhotoVault from those days, newest first.
  final List<FileRef> photos;

  bool get isEmpty => lines.isEmpty && photos.isEmpty;

  /// Every memory is from exactly one year ago.
  bool get oneYearAgo =>
      lines.every((l) => l.yearsAgo == 1) &&
      (lines.isNotEmpty || photos.isNotEmpty);
}

/// Whether [d] fell on [today]'s date in an earlier year. On 28 February
/// of a common year, 29 February counts too.
bool _onThisDay(DateTime d, DateTime today) {
  if (d.year >= today.year) return false;
  if (d.month == today.month && d.day == today.day) return true;
  final leap = DateTime(today.year, 2, 29).month == 2;
  return !leap &&
      today.month == 2 &&
      today.day == 28 &&
      d.month == 2 &&
      d.day == 29;
}

/// What [memoriesOn] reads.
const _memoryCollections = {
  Collections.childEntries,
  Collections.children,
  Collections.events,
  Collections.chatMessages,
  Collections.externalPhotos,
};

/// [memoriesOn] for the start page: computed once per day and language
/// until one of its collections changes (see [EngineMemo]).
Memories memoriesToday(SyncEngine engine, DateTime now) =>
    EngineMemo.of(engine).get(
      'memories ${dayKey(engine.calendar.today(now))} $appLanguage',
      _memoryCollections,
      () => memoriesOn(engine, engine.calendar.today(now)),
    );

/// The memories of [today] in the last [years] years: only what the device
/// may see (the server sends nothing else).
Memories memoriesOn(SyncEngine engine, DateTime today, {int years = 10}) {
  final lines = <MemoryLine>[];
  int ago(DateTime d) => today.year - d.year;

  final children = {for (final c in engine.children) c.id: c.name};
  for (final r in engine.records(Collections.childEntries)) {
    final e = ChildEntry.fromRecord(r);
    if (e.kind != ChildEntryKind.milestone || e.planned || e.dateUnknown) {
      continue;
    }
    if (!_onThisDay(e.date, today) || ago(e.date) > years) continue;
    final title = e.title.isNotEmpty
        ? e.title
        : milestoneById(e.refId)?.title ?? '';
    if (title.isEmpty) continue;
    final name = children[e.childId];
    lines.add((
      yearsAgo: ago(e.date),
      text: name == null ? title : tr.memoriesMilestone(name, title),
    ));
  }

  // Trips and holidays (several days, or with a countdown) of that day.
  for (var n = 1; n <= years; n++) {
    final day = DateTime(today.year - n, today.month, today.day);
    final next = DateTime(day.year, day.month, day.day + 1);
    final seen = <String>{};
    for (final e in engine.events) {
      for (final o in e.occurrencesBetween(
        engine.calendar.day(day),
        engine.calendar.day(next),
      )) {
        final days = DateTime.utc(o.end.year, o.end.month, o.end.day)
            .difference(DateTime.utc(o.start.year, o.start.month, o.start.day))
            .inDays;
        if (((e.allDay && days >= 3) || e.countdown) && seen.add(e.id)) {
          lines.add((yearsAgo: n, text: e.title));
        }
      }
    }
  }

  final photos = <(DateTime, FileRef)>[];
  for (final r in engine.records(Collections.chatMessages)) {
    final m = ChatMessage.fromRecord(r);
    final sent = m.sentAt.toLocal();
    if (m.attachment case final a?
        when a.isImage && _onThisDay(sent, today) && ago(sent) <= years) {
      photos.add((sent, a));
    }
  }
  // What PhotoVault remembers for today (the server fetches it).
  for (final r in engine.records(Collections.externalPhotos)) {
    if (r.data['memoryOf'] != dayKey(today)) continue;
    final taken = DateTime.tryParse('${r.data['takenAt'] ?? ''}')?.toLocal();
    if (FileRef.fromJson(r.data['file']) case final f? when taken != null) {
      photos.add((taken, f));
    }
  }
  photos.sort((a, b) => b.$1.compareTo(a.$1));
  lines.sort((a, b) => a.yearsAgo.compareTo(b.yearsAgo));
  return Memories(lines: lines, photos: [for (final (_, f) in photos) f]);
}
