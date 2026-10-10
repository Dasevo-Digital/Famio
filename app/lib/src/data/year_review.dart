import 'package:famio_client/famio_client.dart';

import 'family_data.dart';
import 'family_extras.dart';

/// A trip or several-day outing from the family calendar.
typedef ReviewTrip = ({String title, DateTime start, DateTime end});

/// What a child reached in the year.
typedef ReviewChild = ({
  Child child,
  List<String> milestones,

  /// Centimetres grown between the first and last measurement of the year.
  double? grownCm,
});

/// What the family did in one year: numbers, the children's milestones,
/// trips, photos from the chat and who did the most chores.
class YearReview {
  const YearReview({
    required this.year,
    required this.events,
    required this.tasksDone,
    required this.choresDone,
    required this.messages,
    required this.meals,
    required this.kids,
    required this.trips,
    required this.photos,
    required this.photoCount,
    required this.chores,
  });

  final int year;

  /// Days with family events (own calendar, not subscriptions).
  final int events;
  final int tasksDone;
  final int choresDone;
  final int messages;
  final int meals;
  final List<ReviewChild> kids;
  final List<ReviewTrip> trips;

  /// Up to twelve photos spread over the year.
  final List<FileRef> photos;
  final int photoCount;

  /// Chores done per member, most first.
  final List<({FamilyMember member, int count})> chores;

  bool get isEmpty =>
      events == 0 &&
      tasksDone == 0 &&
      choresDone == 0 &&
      messages == 0 &&
      kids.every((k) => k.milestones.isEmpty);
}

/// The year a review is about: until the 1st of December the past one.
int reviewYear(DateTime now) => now.month == 12 ? now.year : now.year - 1;

YearReview yearReview(SyncEngine engine, int year) {
  final from = DateTime(year);
  final to = DateTime(year + 1);
  bool inYear(DateTime? d) => d != null && !d.isBefore(from) && d.isBefore(to);

  var events = 0;
  final trips = <ReviewTrip>[];
  for (final e in engine.events) {
    for (final o in e.occurrencesBetween(from, to)) {
      events++;
      // All-day events end the day after: three days are two nights.
      final days = DateTime.utc(o.end.year, o.end.month, o.end.day)
          .difference(DateTime.utc(o.start.year, o.start.month, o.start.day))
          .inDays;
      // Away for at least two nights, or counted down to.
      if ((e.allDay && days >= 3) || e.countdown) {
        trips.add((title: e.title, start: o.start, end: o.end));
      }
    }
  }
  trips.sort((a, b) => a.start.compareTo(b.start));

  final messages = [
    for (final r in engine.records(Collections.chatMessages))
      ChatMessage.fromRecord(r),
  ].where((m) => inYear(m.sentAt)).toList();
  final images = [
    for (final m in messages..sort((a, b) => a.sentAt.compareTo(b.sentAt)))
      if (m.attachment case final a? when a.isImage) a,
  ];
  // Spread over the year rather than the twelve of one birthday party.
  final photos = images.length <= 12
      ? images
      : [for (var i = 0; i < 12; i++) images[i * images.length ~/ 12]];

  final done = [
    for (final p in engine.pointEntries)
      if (p.kind == PointKind.chore &&
          p.status == PointStatus.approved &&
          inYear(p.at))
        p,
  ];
  final perMember = <String, int>{};
  for (final p in done) {
    perMember[p.memberId] = (perMember[p.memberId] ?? 0) + 1;
  }

  return YearReview(
    year: year,
    events: events,
    tasksDone: engine.tasks.where((t) => inYear(t.completedAt)).length,
    choresDone: done.length,
    messages: messages.length,
    meals: engine
        .plannedMeals(from, to.subtract(const Duration(days: 1)))
        .length,
    kids: [
      for (final child in engine.children)
        _child(child, engine.childEntries(child.id), inYear),
    ],
    trips: trips,
    photos: photos,
    photoCount: images.length,
    chores: [
      for (final e in perMember.entries)
        if (engine.member(e.key) case final m?) (member: m, count: e.value),
    ]..sort((a, b) => b.count.compareTo(a.count)),
  );
}

ReviewChild _child(
  Child child,
  List<ChildEntry> entries,
  bool Function(DateTime?) inYear,
) {
  final mine = [
    for (final e in entries)
      if (!e.planned && !e.dateUnknown && inYear(e.date)) e,
  ]..sort((a, b) => a.date.compareTo(b.date));
  final heights = [
    for (final e in mine)
      if (e.kind == ChildEntryKind.measurement) ?e.heightCm,
  ];
  return (
    child: child,
    milestones: [
      for (final e in mine)
        if (e.kind == ChildEntryKind.milestone)
          e.title.isNotEmpty
              ? e.title
              : milestoneById(e.refId)?.title ?? e.title,
    ].where((t) => t.isNotEmpty).toList(),
    grownCm: heights.length < 2 || heights.last <= heights.first
        ? null
        : heights.last - heights.first,
  );
}
