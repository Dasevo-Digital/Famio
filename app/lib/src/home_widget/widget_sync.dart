import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';

/// Title and up to five lines for the "Famio heute" widget: today's events,
/// meals, own tasks, shopping and a sleeping baby. Nothing more private –
/// a home screen can be seen by others.
(String, List<String>) widgetLines(SyncEngine engine, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));
  final time = DateFormat('HH:mm', 'de');
  final lines = <String>[];
  final events = engine
      .occurrences(today, tomorrow)
      .where((o) => o.event.allDay || o.end.isAfter(now))
      .take(2);
  for (final o in events) {
    lines.add(
      o.event.allDay
          ? '📅 ${o.event.title}'
          : '${time.format(o.start)} ${o.event.title}',
    );
  }
  for (final m in engine.plannedMeals(today, tomorrow).take(1)) {
    lines.add('🍽 ${engine.recipe(m.recipeId)?.title ?? m.title}');
  }
  final tasks = engine.tasks
      .where(
        (t) =>
            !t.done &&
            (t.assigneeId == null || t.assigneeId == engine.memberId) &&
            t.due != null &&
            t.due!.isBefore(tomorrow),
      )
      .length;
  if (tasks > 0) {
    lines.add('✅ $tasks ${tasks == 1 ? 'Aufgabe' : 'Aufgaben'} heute');
  }
  var open = 0;
  for (final l in engine.shoppingLists) {
    open += engine.shoppingItems(l.id).where((i) => !i.checked).length;
  }
  if (open > 0) {
    lines.add('🛒 $open ${open == 1 ? 'Sache' : 'Sachen'} einkaufen');
  }
  for (final k in engine.children) {
    final sleeping = engine
        .childLogs(k.id)
        .where((l) => l.kind == LogKind.sleep && l.running)
        .firstOrNull;
    if (sleeping != null) {
      lines.add('🌙 ${k.name} schläft seit ${time.format(sleeping.start)}');
    }
  }
  return (
    'Famio · ${DateFormat('E d.M.', 'de').format(now)}',
    lines.take(5).toList(),
  );
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
    await _write('Famio', const []);
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
    final (title, lines) = widgetLines(_engine, now);
    await _write(title, lines);
    // A new day needs new lines even without changes.
    _midnight?.cancel();
    _midnight = Timer(
      DateTime(now.year, now.month, now.day + 1, 0, 1).difference(now),
      _update,
    );
  }

  static Future<void> _write(String title, List<String> lines) async {
    try {
      await HomeWidget.saveWidgetData<String>('title', title);
      for (var i = 0; i < 5; i++) {
        await HomeWidget.saveWidgetData<String>(
          'line$i',
          i < lines.length ? lines[i] : null,
        );
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
