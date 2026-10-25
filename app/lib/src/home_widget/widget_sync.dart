import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../l10n.dart';

/// One row of the "Famio heute" widget: [kind] picks the section color
/// (event, meal, tasks, shopping, sleep), [lead] is a time or a symbol.
typedef WidgetLine = ({String kind, String lead, String text});

/// The date and up to five rows for the "Famio heute" widget: today's
/// events, meals, own tasks, shopping and a sleeping baby. Nothing more
/// private – a home screen can be seen by others.
(String, List<WidgetLine>) widgetLines(SyncEngine engine, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  // Not today + 24 h: on the day the clocks change that is 23:00 or 01:00.
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final time = DateFormat.jm(appLanguage);
  final lines = <WidgetLine>[];
  final events = engine
      .occurrences(today, tomorrow)
      .where((o) => o.event.allDay || o.end.isAfter(now))
      .take(2);
  for (final o in events) {
    lines.add((
      kind: 'event',
      lead: o.event.allDay ? '📅' : time.format(o.start),
      text: o.event.title,
    ));
  }
  for (final m in engine.plannedMeals(today, tomorrow).take(1)) {
    lines.add((
      kind: 'meal',
      lead: '🍽',
      text: engine.recipe(m.recipeId)?.title ?? m.title,
    ));
  }
  final tasks = engine.tasks
      .where(
        (t) =>
            !t.done &&
            (t.assigneeIds.isEmpty ||
                engine.taskIsAssignedTo(t, engine.memberId, on: today)) &&
            t.due != null &&
            t.due!.isBefore(tomorrow),
      )
      .length;
  if (tasks > 0) {
    lines.add((kind: 'tasks', lead: '✅', text: tr.widgetTasksToday(tasks)));
  }
  var open = 0;
  for (final l in engine.shoppingLists) {
    open += engine.shoppingItems(l.id).where((i) => !i.checked).length;
  }
  if (open > 0) {
    lines.add((kind: 'shopping', lead: '🛒', text: tr.widgetThingsToBuy(open)));
  }
  for (final k in engine.children) {
    final sleeping = engine
        .childLogs(k.id)
        .where((l) => l.kind == LogKind.sleep && l.running)
        .firstOrNull;
    if (sleeping != null) {
      lines.add((
        kind: 'sleep',
        lead: '🌙',
        text: tr.widgetNameAsleepSinceTime(k.name, time.format(sleeping.start)),
      ));
    }
  }
  return (DateFormat.MMMEd(appLanguage).format(now), lines.take(5).toList());
}

/// Keeps the Android home screen widget up to date while the app runs.
class HomeWidgetSync {
  HomeWidgetSync._(this._engine);

  static HomeWidgetSync? _current;

  final SyncEngine _engine;
  StreamSubscription<Set<String>>? _sub;
  Timer? _debounce;
  Timer? _midnight;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static void attach(SyncEngine engine) {
    if (!supported) return;
    _current?._stop();
    _current = HomeWidgetSync._(engine).._start();
  }

  /// Signed out: the widget shows nothing.
  static Future<void> clear() async {
    _current?._stop();
    _current = null;
    if (!supported) return;
    await _write('', const []);
  }

  void _start() {
    _sub = _engine.changes.listen((_) => _schedule());
    _schedule();
  }

  void _stop() {
    _sub?.cancel();
    _debounce?.cancel();
    _midnight?.cancel();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), _update);
  }

  Future<void> _update() async {
    final now = DateTime.now();
    final (date, lines) = widgetLines(_engine, now);
    await _write(date, lines);
    // A new day needs new lines even without changes.
    _midnight?.cancel();
    _midnight = Timer(
      DateTime(now.year, now.month, now.day + 1, 0, 1).difference(now),
      _update,
    );
  }

  static Future<void> _write(String date, List<WidgetLine> lines) async {
    try {
      await HomeWidget.saveWidgetData<String>('date', date);
      for (var i = 0; i < 5; i++) {
        final line = i < lines.length ? lines[i] : null;
        await HomeWidget.saveWidgetData<String>('kind$i', line?.kind);
        await HomeWidget.saveWidgetData<String>('lead$i', line?.lead);
        await HomeWidget.saveWidgetData<String>('text$i', line?.text);
        // The single line of apps before 2.0.5.
        await HomeWidget.saveWidgetData<String>('line$i', null);
      }
      // Qualified: "Famio Dev" has another application id than the package.
      await HomeWidget.updateWidget(
        qualifiedAndroidName: 'de.status403.famio.FamioWidgetProvider',
      );
    } catch (_) {
      // No widget support on this device.
    }
  }
}
