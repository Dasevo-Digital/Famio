import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../l10n.dart';

/// One row of the "Famio heute" widget: [kind] picks the section color
/// (event, meal, tasks, shopping, sleep), [lead] is a time or a symbol.
typedef WidgetLine = ({String kind, String lead, String text});

/// The date and up to five rows for the "Famio heute" widget: today's
/// events, meals, own tasks, shopping and a sleeping baby. Nothing more
/// private – a home screen can be seen by others: an appointment that is
/// confidential or only some see says it is one, as on the wall display.
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
      text: engine.wallTitle(o.event),
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
  // What there is to buy: packing lists are things to pack, not to buy.
  var open = 0;
  for (final l in engine.shoppingLists) {
    if (l.packing) continue;
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
///
/// The rows go to Android's encrypted store of "Famio heute" (see
/// `WidgetData.kt`), and only while such a widget is on the home screen:
/// they name appointments, meals and a sleeping child. A widget placed
/// meanwhile gets them when Famio is back in front.
class HomeWidgetSync {
  HomeWidgetSync._(this._engine);

  static HomeWidgetSync? _current;
  static const _channel = MethodChannel('famio/widget');

  final SyncEngine _engine;
  StreamSubscription<Set<String>>? _sub;
  AppLifecycleListener? _lifecycle;
  Timer? _debounce;
  Timer? _midnight;

  static bool get supported =>
      debugSupported ?? (!kIsWeb && Platform.isAndroid);

  /// Tests on another platform: as if it were Android.
  @visibleForTesting
  static bool? debugSupported;

  static void attach(SyncEngine engine) {
    if (!supported) return;
    _current?._stop();
    _current = HomeWidgetSync._(engine).._start();
  }

  /// Signed out: the widget shows nothing, and nothing is kept for it.
  static Future<void> clear() async {
    _current?._stop();
    _current = null;
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('clear');
    } catch (_) {
      // No widget support on this device.
    }
  }

  /// Whether a "Famio heute" widget is on the home screen.
  @visibleForTesting
  static Future<bool> placed() async =>
      await _channel.invokeMethod<bool>('placed') ?? false;

  /// What the widget shows now: its date (null: not filled) and rows.
  @visibleForTesting
  static Future<(String?, List<WidgetLine>)> stored() async {
    final data = await _channel.invokeMapMethod<String, Object?>('read');
    return (
      data?['date'] as String?,
      [
        for (final row in (data?['rows'] as List?) ?? const [])
          (
            kind: (row as Map)['kind'] as String? ?? '',
            lead: row['lead'] as String? ?? '',
            text: row['text'] as String? ?? '',
          ),
      ],
    );
  }

  void _start() {
    _sub = _engine.changes.listen((_) => _schedule());
    _lifecycle = AppLifecycleListener(onResume: _schedule);
    _schedule();
  }

  void _stop() {
    _sub?.cancel();
    _lifecycle?.dispose();
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
      await _channel.invokeMethod<bool>('save', {
        'date': date,
        'rows': [
          for (final l in lines)
            {'kind': l.kind, 'lead': l.lead, 'text': l.text},
        ],
      });
    } catch (_) {
      // No widget support on this device.
    }
  }
}
