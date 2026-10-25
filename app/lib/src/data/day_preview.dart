import 'package:famio_client/famio_client.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import '../weather/weather.dart';
import 'birthdays.dart';
import 'family_extras.dart';
import 'family_data.dart';
import 'waste.dart';

/// The morning look at one day for one member: the weather, their
/// appointments and lifts, birthdays, the bins, the meal and their tasks
/// that are due. Opt-in in the notification settings.
class DayPreview {
  const DayPreview({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  static const maxLines = 8;

  String get body => lines.join('\n');
}

/// The preview of [day] (local midnight), or null if nothing is planned
/// for the member (the weather alone is no reason to ring).
DayPreview? buildDayPreview(
  SyncEngine engine,
  DateTime day, {
  WeatherForecast? weather,
}) {
  final end = DateTime(day.year, day.month, day.day + 1);
  final me = engine.memberId;
  final time = DateFormat.jm(appLanguage);
  final events = [
    for (final o in engine.occurrences(day, end))
      if (!o.start.isBefore(day) &&
          (o.event.involves(me) ||
              o.event.bringerId == me ||
              o.event.pickerId == me))
        o,
  ];
  final tasks = [
    for (final t in engine.tasks)
      if (!t.done &&
          t.due != null &&
          t.due!.isBefore(end) &&
          (t.assigneeIds.isEmpty || engine.taskIsAssignedTo(t, me, on: day)))
        t,
  ];
  final birthdays = upcomingBirthdays(engine, day, days: 1);
  final waste = engine.wasteConfigured && engine.holidayOn(day) == null
      ? engine.wastePickups(day, end)
      : const <WastePickup>[];
  final meals = [
    for (final m in engine.plannedMeals(day, end))
      engine.recipe(m.recipeId)?.title ?? m.title,
  ].where((t) => t.trim().isNotEmpty).toList();
  if (events.isEmpty &&
      tasks.isEmpty &&
      birthdays.isEmpty &&
      waste.isEmpty &&
      meals.isEmpty) {
    return null;
  }
  final lines = [
    ?_weatherLine(weather, day),
    for (final o in events)
      [
        if (!o.event.allDay) time.format(o.start),
        if (o.event.bringerId == me)
          tr.weekPreviewDropOffTitle(o.event.title)
        else if (o.event.pickerId == me)
          tr.weekPreviewPickUpTitle(o.event.title)
        else
          o.event.title,
      ].join(' '),
    for (final (b, _) in birthdays) tr.dayPreviewBirthday(b.name),
    for (final p in waste) tr.dayPreviewWaste(p.label),
    if (meals.isNotEmpty) tr.dayPreviewMeal(meals.join(', ')),
    if (tasks.isNotEmpty)
      tr.dayPreviewTasks(
        tasks.length,
        [
          ...tasks.take(3).map((t) => t.title),
          if (tasks.length > 3) '…',
        ].join(', '),
      ),
  ];
  return DayPreview(
    title: [
      tr.dayPreviewTitle,
      if (events.isNotEmpty) tr.dayPreviewEvents(events.length),
    ].join(' · '),
    lines: lines.length > DayPreview.maxLines
        ? lines.take(DayPreview.maxLines).toList()
        : lines,
  );
}

/// "⛅ Teils bewölkt, 8–14 °C, Regen 60 %" for the daytime of [day], if
/// the cached forecast reaches that far.
String? _weatherLine(WeatherForecast? weather, DateTime day) {
  final hours = [
    for (final h in weather?.hours ?? const <WeatherHour>[])
      if (h.time.year == day.year &&
          h.time.month == day.month &&
          h.time.day == day.day &&
          h.time.hour >= 7 &&
          h.time.hour <= 20)
        h,
  ];
  if (hours.length < 6) return null;
  final temps = hours.map((h) => h.temperature);
  final noon = hours.reduce(
    (a, b) => (a.time.hour - 13).abs() <= (b.time.hour - 13).abs() ? a : b,
  );
  final rain = hours
      .map((h) => h.precipitationProbability ?? 0)
      .reduce((a, b) => a > b ? a : b);
  return [
    tr.dayPreviewWeather(
      weatherEmoji(noon.code),
      weatherText(noon.code),
      temps.reduce((a, b) => a < b ? a : b).round(),
      temps.reduce((a, b) => a > b ? a : b).round(),
    ),
    if (rain >= 40) tr.dayPreviewRain(rain),
  ].join(', ');
}

/// [minutes] after midnight on every day within `[from, to)`, each with
/// its day.
Iterable<(DateTime at, DateTime day)> dayPreviewTimes(
  DateTime from,
  DateTime to,
  int minutes,
) sync* {
  for (
    var day = DateTime(from.year, from.month, from.day);
    day.isBefore(to);
    day = DateTime(day.year, day.month, day.day + 1)
  ) {
    final at = DateTime(
      day.year,
      day.month,
      day.day,
      minutes ~/ 60,
      minutes % 60,
    );
    if (!at.isBefore(from) && at.isBefore(to)) yield (at, day);
  }
}
