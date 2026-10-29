import 'package:famio_client/famio_client.dart';
import 'package:intl/intl.dart';

import 'family_data.dart';
import 'family_extras.dart';
import 'waste.dart';
import '../l10n.dart';

/// An appointment on the printed week plan: "8:00", "Schwimmen", "Mia ·
/// bringt Papa". [time] is null for all-day entries and on the following
/// days of longer ones.
typedef WeekPlanEvent = ({String? time, String title, String people});

/// A chore and who does it (empty: anyone).
typedef WeekPlanChore = ({String title, List<String> who});

/// One day of the week plan.
class WeekPlanDay {
  const WeekPlanDay({
    required this.day,
    this.holiday,
    this.events = const [],
    this.meals = const [],
    this.chores = const [],
    this.waste = const [],
  });

  final DateTime day;

  /// The family holiday's title, if the day falls into one.
  final String? holiday;
  final List<WeekPlanEvent> events;
  final List<({MealSlot slot, String title})> meals;
  final List<WeekPlanChore> chores;

  /// Bins that are collected, and who puts them out.
  final List<({WasteKind kind, List<String> who})> waste;

  bool get isEmpty =>
      holiday == null &&
      events.isEmpty &&
      meals.isEmpty &&
      chores.isEmpty &&
      waste.isEmpty;
}

/// The family's week for the fridge: appointments, meals, chores and bins
/// of the week starting on [monday].
class WeekPlan {
  const WeekPlan({
    required this.monday,
    required this.days,
    this.everyDay = const [],
    this.weekly = const [],
  });

  final DateTime monday;
  final List<WeekPlanDay> days;

  /// Chores due every day of the week by the same people: listed once
  /// instead of seven times.
  final List<WeekPlanChore> everyDay;

  /// Chores to do once during the week.
  final List<WeekPlanChore> weekly;

  bool get isEmpty =>
      days.every((d) => d.isEmpty) && everyDay.isEmpty && weekly.isEmpty;
}

/// Monday of [day]'s week, local midnight.
DateTime weekPlanMonday(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - 1));

/// Everything the device knows of the week starting on [monday]: only what
/// the member may see (the server sends nothing else).
WeekPlan buildWeekPlan(SyncEngine engine, DateTime monday) {
  final days = [
    for (var i = 0; i < 7; i++)
      DateTime(monday.year, monday.month, monday.day + i),
  ];
  final end = DateTime(monday.year, monday.month, monday.day + 7);
  String name(String id) => engine.member(id)?.displayName ?? '';
  List<String> names(Iterable<String> ids) => [
    for (final id in ids)
      if (name(id) case final n when n.isNotEmpty) n,
  ];

  // The bins' entries come as bins, not as appointments (see
  // `WasteSettings.pickups`).
  final waste = engine.wasteConfigured ? engine.wasteSettings : null;
  final events = <DateTime, List<(Occurrence, bool)>>{};
  for (final o in engine.occurrencesForDays(monday, end)) {
    if (waste != null &&
        (waste.sourceId != null
            ? o.event.sourceId == waste.sourceId
            : o.event.allDay && WasteKind.of(o.event.title) != null)) {
      continue;
    }
    final first = DateTime(o.start.year, o.start.month, o.start.day);
    // End is exclusive; a timed entry ending at midnight stays on its day.
    final lastMoment = o.end.isAfter(o.start)
        ? o.end.subtract(const Duration(milliseconds: 1))
        : o.start;
    final last = DateTime(lastMoment.year, lastMoment.month, lastMoment.day);
    for (final day in days) {
      if (day.isBefore(first) || day.isAfter(last)) continue;
      events.putIfAbsent(day, () => []).add((o, day == first));
    }
  }
  for (final list in events.values) {
    // All-day ones (and continued ones) first.
    list.sort((a, b) {
      final aTimed = !a.$1.event.allDay && a.$2;
      final bTimed = !b.$1.event.allDay && b.$2;
      if (aTimed != bTimed) return aTimed ? 1 : -1;
      return a.$1.start.compareTo(b.$1.start);
    });
  }
  final time = DateFormat.jm(appLanguage);
  WeekPlanEvent line(Occurrence o, bool firstDay) {
    final e = o.event;
    final everyone = e.memberIds.isEmpty;
    return (
      time: e.allDay || !firstDay ? null : time.format(o.start),
      title: e.title,
      people: [
        if (!everyone) names(e.memberIds).join(', '),
        if (e.bringerId != null && name(e.bringerId!).isNotEmpty)
          tr.weekPlanBrings(name(e.bringerId!)),
        if (e.pickerId != null && name(e.pickerId!).isNotEmpty)
          tr.weekPlanPicksUp(name(e.pickerId!)),
      ].where((p) => p.isNotEmpty).join(' · '),
    );
  }

  final meals = engine.plannedMeals(monday, end);

  final chores = engine.chores.where((c) => !c.paused).toList();
  List<String> choreWho(Chore c, DateTime day) => switch (c.assigneeOn(day)) {
    final id? => names([id]),
    null => names(c.memberIds),
  };
  final everyDay = <WeekPlanChore>[];
  final weekly = <WeekPlanChore>[];
  final perDay = <DateTime, List<WeekPlanChore>>{};
  for (final c in chores) {
    final due = [
      for (final d in days)
        if (engine.choreDue(c, d)) d,
    ];
    if (due.isEmpty) continue;
    if (c.repeat == ChoreRepeat.weekly) {
      weekly.add((title: c.title, who: choreWho(c, due.first)));
      continue;
    }
    final sameEveryDay =
        c.repeat == ChoreRepeat.daily &&
        due.length == 7 &&
        days.every((d) => c.assigneeOn(d) == c.assigneeOn(monday));
    if (sameEveryDay) {
      everyDay.add((title: c.title, who: choreWho(c, monday)));
      continue;
    }
    for (final d in due) {
      perDay.putIfAbsent(d, () => []).add((
        title: c.title,
        who: choreWho(c, d),
      ));
    }
  }

  final pickups = waste == null
      ? const <WastePickup>[]
      : engine.wastePickups(monday, end);

  return WeekPlan(
    monday: monday,
    everyDay: everyDay,
    weekly: weekly,
    days: [
      for (final day in days)
        WeekPlanDay(
          day: day,
          holiday: engine.holidayOn(day)?.title,
          events: [
            for (final (o, firstDay)
                in events[day] ?? const <(Occurrence, bool)>[])
              line(o, firstDay),
          ],
          meals: [
            for (final m in meals)
              if (m.date == day)
                (
                  slot: m.slot,
                  title: engine.recipe(m.recipeId)?.title ?? m.title,
                ),
          ],
          chores: perDay[day] ?? const [],
          waste: [
            for (final p in pickups)
              if (p.day == day)
                for (final kind in p.kinds)
                  (
                    kind: kind,
                    // Without names it is every adult: no need to print.
                    who: waste!.memberIds.isEmpty
                        ? const []
                        : [
                            for (final m in engine.wasteResponsible(p))
                              m.displayName,
                          ],
                  ),
          ],
        ),
    ],
  );
}
