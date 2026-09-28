import 'dart:async';
import 'dart:math' as math;

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/health_logic.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../design/theme.dart';
import '../widgets/member_avatar.dart';
import 'kids_screens.dart';

final _time = DateFormat('HH:mm', 'de');
final _day = DateFormat('EEEE, d. MMMM', 'de');

/// Look of each log kind: icon and color.
(IconData, Color) logLook(LogKind kind) => switch (kind) {
  LogKind.breast => (AppIcons.heart, const Color(0xFFDB4A7E)),
  LogKind.bottle => (AppIcons.milk, const Color(0xFF3587D6)),
  LogKind.solids => (AppIcons.soup, const Color(0xFFE89B1A)),
  LogKind.pumping => (AppIcons.glassWater, const Color(0xFF7B5BE0)),
  LogKind.sleep => (AppIcons.moon, const Color(0xFF5B6BE0)),
  LogKind.diaper => (AppIcons.droplets, const Color(0xFF2A9D6E)),
  LogKind.temperature => (AppIcons.thermometer, const Color(0xFFE0533A)),
  LogKind.medication => (AppIcons.pill, const Color(0xFF16927F)),
  LogKind.symptom => (AppIcons.bandage, const Color(0xFFE8703A)),
  LogKind.bath => (AppIcons.bath, const Color(0xFF3AA8C9)),
};

String _temp(double t) => '${t.toStringAsFixed(1).replaceAll('.', ',')} °C';

/// One line describing [l], e.g. "Fläschchen · 120 ml Pre-/Folgemilch".
String logText(ChildLog l, [DateTime? now]) => switch (l.kind) {
  LogKind.breast =>
    'Stillen ${l.side?.label ?? ''} · '
        '${l.running ? 'läuft seit ${durationLabel(l.duration(now))}' : durationLabel(l.duration())}',
  LogKind.sleep =>
    l.running
        ? 'Schläft seit ${durationLabel(l.duration(now))}'
        : 'Schlaf · ${durationLabel(l.duration())}',
  LogKind.bottle => [
    'Fläschchen',
    if (l.amountMl != null) '${l.amountMl} ml',
    ?l.milk?.label,
  ].join(' · '),
  LogKind.solids => l.note.isEmpty ? 'Beikost' : 'Beikost · ${l.note}',
  LogKind.pumping => [
    'Abgepumpt',
    if (l.amountMl != null) '${l.amountMl} ml',
    ?l.side?.label,
  ].join(' · '),
  LogKind.diaper => 'Windel ${l.diaper?.label ?? ''}'.trim(),
  LogKind.temperature =>
    l.temperatureC == null ? 'Temperatur' : _temp(l.temperatureC!),
  LogKind.medication => [
    l.medication.isEmpty ? 'Medikament' : l.medication,
    if (l.dose.isNotEmpty) l.dose,
  ].join(' · '),
  LogKind.symptom => l.symptom.isEmpty ? 'Symptom' : l.symptom,
  LogKind.bath => 'Gebadet',
};

/// Rebuilds every [interval]: the stopwatch of a running timer each
/// second, "vor 5 Min." labels each minute.
class _Ticker extends StatefulWidget {
  const _Ticker({
    this.interval = const Duration(seconds: 1),
    required this.builder,
  });

  final Duration interval;
  final WidgetBuilder builder;

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> {
  late final Timer _timer = Timer.periodic(
    widget.interval,
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _timer;
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// The child's daily log: quick buttons, running timers, today's totals, a
/// week chart and all entries by day.
class ChildLogView extends StatelessWidget {
  const ChildLogView({super.key, required this.child, required this.logs});

  final Child child;
  final List<ChildLog> logs;

  @override
  Widget build(BuildContext context) {
    final running = logs.where((l) => l.running).toList();
    // Only the stopwatch of a running timer ticks each second (see
    // _RunningCard); the rest of the log is refreshed once a minute.
    return _Ticker(
      interval: const Duration(minutes: 1),
      builder: (context) {
        final now = DateTime.now();
        final byDay = <DateTime, List<ChildLog>>{};
        for (final l in logs.take(400)) {
          byDay
              .putIfAbsent(
                DateTime(l.start.year, l.start.month, l.start.day),
                () => [],
              )
              .add(l);
        }
        return ListView(
          padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
          children: [
            for (final r in running) ...[
              _RunningCard(child: child, log: r),
              const SizedBox(height: 10),
            ],
            _QuickButtons(child: child, logs: logs),
            const SizedBox(height: 12),
            _StatusCard(child: child, logs: logs, now: now),
            const SizedBox(height: 12),
            _TodayCard(summary: summarize(logs, now, now)),
            const SizedBox(height: 12),
            _WeekChart(logs: logs, now: now),
            if (logs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Noch keine Einträge. Tippe oben auf Stillen, Fläschchen, '
                  'Schlaf oder Windel – beide Eltern sehen alles sofort.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            for (final entry in byDay.entries) ...[
              ListHeading(_dayLabel(entry.key, now)),
              for (final l in entry.value)
                _LogRow(child: child, log: l, now: now),
            ],
            const SizedBox(height: 12),
            Text(
              'Famio ersetzt keinen ärztlichen Rat. Dosierungen nur nach '
              'Kinderarzt oder Beipackzettel.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

String _dayLabel(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  return diff == 0
      ? 'Heute'
      : diff == 1
      ? 'Gestern'
      : _day.format(day);
}

class _RunningCard extends StatelessWidget {
  const _RunningCard({required this.child, required this.log});

  final Child child;
  final ChildLog log;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = logLook(log.kind);
    final engine = AppScope.engineOf(context);
    return SoftCard(
      color: color.withValues(alpha: 0.14),
      child: Row(
        children: [
          IconBlob(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  log.kind == LogKind.sleep
                      ? 'Schläft seit ${_time.format(log.start)}'
                      : 'Stillen ${log.side?.label ?? ''} seit ${_time.format(log.start)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                _Ticker(
                  builder: (context) {
                    final elapsed = log.duration(DateTime.now());
                    return Text(
                      '${elapsed.inHours > 0 ? '${elapsed.inHours}:' : ''}'
                      '${(elapsed.inMinutes % 60).toString().padLeft(elapsed.inHours > 0 ? 2 : 1, '0')}:'
                      '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: color,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    );
                  },
                ),
              ],
            ),
          ),
          if (log.kind == LogKind.breast)
            BubbleButton(
              icon: AppIcons.arrowsLeftRight,
              tooltip: 'Seite wechseln',
              onPressed: () {
                final at = DateTime.now();
                engine.saveChildLog(log.copyWith(end: at));
                engine.saveChildLog(
                  ChildLog(
                    id: newId(),
                    childId: child.id,
                    kind: LogKind.breast,
                    start: at,
                    side: log.side == BreastSide.left
                        ? BreastSide.right
                        : BreastSide.left,
                    by: engine.memberId,
                  ),
                );
              },
            ),
          const SizedBox(width: 8),
          ColorButton(
            label: 'Stopp',
            icon: AppIcons.stop,
            color: color,
            onPressed: () {
              final done = log.copyWith(end: DateTime.now());
              engine.saveChildLog(done);
              if (log.kind == LogKind.breast) {
                showLogEditor(
                  context,
                  child: child,
                  kind: log.kind,
                  existing: done,
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

class _QuickButtons extends StatelessWidget {
  const _QuickButtons({required this.child, required this.logs});

  final Child child;
  final List<ChildLog> logs;

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final sleeping = logs
        .where((l) => l.kind == LogKind.sleep && l.running)
        .firstOrNull;
    final nursing = logs
        .where((l) => l.kind == LogKind.breast && l.running)
        .firstOrNull;

    void quick(LogKind kind, {DiaperKind? diaper}) => engine.saveChildLog(
      ChildLog(
        id: newId(),
        childId: child.id,
        kind: kind,
        start: DateTime.now(),
        diaper: diaper,
        by: engine.memberId,
      ),
    );

    Future<void> breast() async {
      if (nursing != null) return;
      final next = nextBreastSide(logs);
      final side = await showModalBottomSheet<BreastSide>(
        context: context,
        // Above the floating navigation bar.
        useRootNavigator: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Stillen starten',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (next != null)
                  Text(
                    'Zuletzt ${next == BreastSide.left ? 'rechts' : 'links'} – heute zuerst ${next.label}.',
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    for (final s in BreastSide.values) ...[
                      Expanded(
                        child: s == next || next == null
                            ? FilledButton(
                                onPressed: () => Navigator.pop(context, s),
                                child: Text(
                                  s == BreastSide.left ? 'Links' : 'Rechts',
                                ),
                              )
                            : OutlinedButton(
                                onPressed: () => Navigator.pop(context, s),
                                child: Text(
                                  s == BreastSide.left ? 'Links' : 'Rechts',
                                ),
                              ),
                      ),
                      if (s == BreastSide.left) const SizedBox(width: 12),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    showLogEditor(context, child: child, kind: LogKind.breast);
                  },
                  child: const Text('Nachtragen'),
                ),
              ],
            ),
          ),
        ),
      );
      if (side == null) return;
      engine.saveChildLog(
        ChildLog(
          id: newId(),
          childId: child.id,
          kind: LogKind.breast,
          start: DateTime.now(),
          side: side,
          by: engine.memberId,
        ),
      );
    }

    Future<void> diaper() async {
      final kind = await showModalBottomSheet<DiaperKind>(
        context: context,
        // Above the floating navigation bar.
        useRootNavigator: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Windel', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final d in DiaperKind.values)
                      FilledButton.tonal(
                        onPressed: () => Navigator.pop(context, d),
                        child: Text(d.label),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      if (kind != null) quick(LogKind.diaper, diaper: kind);
    }

    void snack(String text) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );

    final buttons =
        <(LogKind?, String, IconData, Color, VoidCallback, VoidCallback?)>[
          (
            LogKind.breast,
            nursing == null ? 'Stillen' : 'Stillen läuft',
            logLook(LogKind.breast).$1,
            logLook(LogKind.breast).$2,
            breast,
            () => showLogEditor(context, child: child, kind: LogKind.breast),
          ),
          (
            LogKind.bottle,
            'Fläschchen',
            logLook(LogKind.bottle).$1,
            logLook(LogKind.bottle).$2,
            () => showLogEditor(context, child: child, kind: LogKind.bottle),
            null,
          ),
          (
            LogKind.sleep,
            sleeping == null ? 'Schlafen' : 'Aufgewacht',
            sleeping == null ? AppIcons.moon : AppIcons.sun,
            logLook(LogKind.sleep).$2,
            () {
              if (sleeping != null) {
                engine.saveChildLog(sleeping.copyWith(end: DateTime.now()));
              } else {
                quick(LogKind.sleep);
              }
            },
            () => showLogEditor(context, child: child, kind: LogKind.sleep),
          ),
          (
            LogKind.diaper,
            'Windel',
            logLook(LogKind.diaper).$1,
            logLook(LogKind.diaper).$2,
            diaper,
            null,
          ),
          (
            LogKind.solids,
            'Beikost',
            logLook(LogKind.solids).$1,
            logLook(LogKind.solids).$2,
            () => showLogEditor(context, child: child, kind: LogKind.solids),
            null,
          ),
          (
            LogKind.temperature,
            'Temperatur',
            logLook(LogKind.temperature).$1,
            logLook(LogKind.temperature).$2,
            () =>
                showLogEditor(context, child: child, kind: LogKind.temperature),
            null,
          ),
          (
            LogKind.medication,
            'Medikament',
            logLook(LogKind.medication).$1,
            logLook(LogKind.medication).$2,
            () =>
                showLogEditor(context, child: child, kind: LogKind.medication),
            null,
          ),
          (
            LogKind.symptom,
            'Symptom',
            logLook(LogKind.symptom).$1,
            logLook(LogKind.symptom).$2,
            () => showLogEditor(context, child: child, kind: LogKind.symptom),
            null,
          ),
          (
            LogKind.pumping,
            'Abpumpen',
            logLook(LogKind.pumping).$1,
            logLook(LogKind.pumping).$2,
            () => showLogEditor(context, child: child, kind: LogKind.pumping),
            null,
          ),
          (
            LogKind.bath,
            'Baden',
            logLook(LogKind.bath).$1,
            logLook(LogKind.bath).$2,
            () {
              quick(LogKind.bath);
              snack('Baden eingetragen');
            },
            () => showLogEditor(context, child: child, kind: LogKind.bath),
          ),
          (
            null,
            'Gewicht',
            AppIcons.ruler,
            const Color(0xFF2A9D6E),
            () => showEntryEditor(
              context,
              child: child,
              kind: ChildEntryKind.measurement,
            ),
            null,
          ),
        ];
    final c = FamioColors.of(context);
    // Readable on the tile's own tint with "Hoher Kontrast".
    Color ink(Color color) => c.readable(
      color,
      on: Color.alphaBlend(color.withValues(alpha: 0.13), c.background),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.max(3, (constraints.maxWidth / 110).floor());
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (_, label, icon, color, onTap, onLong) in buttons)
              SizedBox(
                width: width,
                child: Material(
                  color: color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: onTap,
                    onLongPress: onLong,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        children: [
                          Icon(icon, color: ink(color), size: 26),
                          const SizedBox(height: 4),
                          Text(
                            label,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: ink(color)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.child,
    required this.logs,
    required this.now,
  });

  final Child child;
  final List<ChildLog> logs;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final feeding = lastFeeding(logs);
    final diaper = lastOf(logs, LogKind.diaper);
    final temp = lastOf(logs, LogKind.temperature);
    final side = nextBreastSide(logs);
    final meds = recentMedications(
      logs,
    ).where((m) => now.difference(m.start).inHours < 48).toList();
    final lines = <(IconData, Color, String)>[
      if (feeding != null)
        (
          logLook(feeding.kind).$1,
          logLook(feeding.kind).$2,
          'Zuletzt gefüttert ${sinceLabel(feeding.end ?? feeding.start, now)} '
              '(${logText(feeding, now)})',
        ),
      if (side != null)
        (
          logLook(LogKind.breast).$1,
          logLook(LogKind.breast).$2,
          'Nächste Seite: ${side.label}',
        ),
      if (diaper != null)
        (
          logLook(LogKind.diaper).$1,
          logLook(LogKind.diaper).$2,
          'Windel ${sinceLabel(diaper.start, now)}',
        ),
      if (temp?.temperatureC != null &&
          now.difference(temp!.start).inHours < 48)
        (
          logLook(LogKind.temperature).$1,
          logLook(LogKind.temperature).$2,
          '${_temp(temp.temperatureC!)} ${sinceLabel(temp.start, now)}',
        ),
      for (final m in meds)
        () {
          final next = nextDoseAt(logs, m.medication);
          return (
            logLook(LogKind.medication).$1,
            logLook(LogKind.medication).$2,
            '${m.medication} ${sinceLabel(m.start, now)}'
                '${next == null
                    ? ''
                    : next.isAfter(now)
                    ? ' · wieder ab ${_time.format(next)}'
                    : ' · wieder möglich'}',
          );
        }(),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return SoftCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          for (final (icon, color, text) in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: FamioColors.of(context).readable(color),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(text, style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.summary});

  final DaySummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final theme = Theme.of(context);
    final items = <(String, String)>[
      ('Mahlzeiten', '${s.feedings}'),
      if (s.milkMl > 0) ('Milch', '${s.milkMl} ml'),
      if (s.breast > Duration.zero) ('Stillen', durationLabel(s.breast)),
      ('Schlaf', durationLabel(s.sleep)),
      ('Windeln', '${s.wet} nass · ${s.dirty} voll'),
      if (s.maxTemperature != null) ('Höchste Temp.', _temp(s.maxTemperature!)),
    ];
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Heute', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 18,
            runSpacing: 10,
            children: [
              for (final (label, value) in items)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: theme.textTheme.titleLarge),
                    Text(label, style: theme.textTheme.bodySmall),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _Series {
  milk('Milch', 'ml'),
  feedings('Mahlzeiten', ''),
  sleep('Schlaf', 'h'),
  diapers('Windeln', ''),
  temperature('Temperatur', '°C');

  const _Series(this.label, this.unit);

  final String label;
  final String unit;
}

class _WeekChart extends StatefulWidget {
  const _WeekChart({required this.logs, required this.now});

  final List<ChildLog> logs;
  final DateTime now;

  @override
  State<_WeekChart> createState() => _WeekChartState();
}

class _WeekChartState extends State<_WeekChart> {
  var _series = _Series.feedings;

  @override
  Widget build(BuildContext context) {
    final now = widget.now;
    final days = [
      for (var i = 6; i >= 0; i--) DateTime(now.year, now.month, now.day - i),
    ];
    final sums = [for (final d in days) summarize(widget.logs, d, now)];
    final values = [
      for (final s in sums)
        switch (_series) {
          _Series.milk => s.milkMl.toDouble(),
          _Series.feedings => s.feedings.toDouble(),
          _Series.sleep => s.sleep.inMinutes / 60,
          _Series.diapers => (s.wet + s.dirty).toDouble(),
          _Series.temperature => s.maxTemperature ?? 0,
        },
    ];
    final color = switch (_series) {
      _Series.milk => logLook(LogKind.bottle).$2,
      _Series.feedings => logLook(LogKind.solids).$2,
      _Series.sleep => logLook(LogKind.sleep).$2,
      _Series.diapers => logLook(LogKind.diaper).$2,
      _Series.temperature => logLook(LogKind.temperature).$2,
    };
    final c = FamioColors.of(context);
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Letzte 7 Tage',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              DropdownButton<_Series>(
                value: _series,
                underline: const SizedBox.shrink(),
                items: [
                  for (final s in _Series.values)
                    DropdownMenuItem(value: s, child: Text(s.label)),
                ],
                onChanged: (s) => setState(() => _series = s ?? _series),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 150,
            child: CustomPaint(
              size: Size.infinite,
              painter: _BarPainter(
                values: values,
                labels: [for (final d in days) DateFormat('E', 'de').format(d)],
                color: color,
                grid: c.line,
                label: c.inkSoft,
                format: (v) => _series == _Series.temperature
                    ? (v == 0 ? '–' : v.toStringAsFixed(1).replaceAll('.', ','))
                    : _series == _Series.sleep
                    ? v.toStringAsFixed(1).replaceAll('.', ',')
                    : v.round().toString(),
                baseline: _series == _Series.temperature ? 36 : 0,
              ),
            ),
          ),
          if (_series.unit.isNotEmpty)
            Text(
              'in ${_series.unit}${_series == _Series.temperature ? ' (Tageshöchstwert)' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.values,
    required this.labels,
    required this.color,
    required this.grid,
    required this.label,
    required this.format,
    this.baseline = 0,
  });

  final List<double> values;
  final List<String> labels;
  final Color color;
  final Color grid;
  final Color label;
  final String Function(double) format;
  final double baseline;

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 18.0, top = 16.0;
    final maxV = math.max(values.fold<double>(0, math.max), baseline + 1);
    final slot = size.width / values.length;
    final text = TextStyle(
      color: label,
      fontFamily: bodyFont,
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
    );
    canvas.drawLine(
      Offset(0, size.height - bottom),
      Offset(size.width, size.height - bottom),
      Paint()
        ..color = grid
        ..strokeWidth = 1.5,
    );
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      final h = v <= baseline
          ? 0.0
          : (v - baseline) / (maxV - baseline) * (size.height - bottom - top);
      final x = slot * i + slot * 0.2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, size.height - bottom - h, slot * 0.6, h),
        const Radius.circular(8),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = color.withValues(alpha: i == values.length - 1 ? 1 : 0.55),
      );
      final valuePainter = TextPainter(
        text: TextSpan(
          text: v <= baseline && baseline > 0 ? '–' : format(v),
          style: text,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      valuePainter.paint(
        canvas,
        Offset(
          slot * i + (slot - valuePainter.width) / 2,
          size.height - bottom - h - 14,
        ),
      );
      final dayPainter = TextPainter(
        text: TextSpan(text: labels[i], style: text),
        textDirection: TextDirection.ltr,
      )..layout();
      dayPainter.paint(
        canvas,
        Offset(slot * i + (slot - dayPainter.width) / 2, size.height - 14),
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.values != values || old.color != color;
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.child, required this.log, required this.now});

  final Child child;
  final ChildLog log;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = logLook(log.kind);
    final theme = Theme.of(context);
    final by = AppScope.engineOf(context).member(log.by);
    final fever = log.kind == LogKind.temperature && log.temperatureC != null
        ? feverAdvice(child, log.temperatureC!, at: log.start).level
        : null;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () =>
          showLogEditor(context, child: child, kind: log.kind, existing: log),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(
                _time.format(log.start),
                style: theme.textTheme.labelLarge,
              ),
            ),
            IconBlob(icon, color: color, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    logText(log, now),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color:
                          fever != null && fever.index >= FeverLevel.fever.index
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                  if (log.note.isNotEmpty && log.kind != LogKind.solids)
                    Text(log.note, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            if (by != null) MemberAvatar(by, radius: 11),
          ],
        ),
      ),
    );
  }
}

// --- editor ------------------------------------------------------------------

/// Adds or edits a log entry of [kind] for [child].
Future<void> showLogEditor(
  BuildContext context, {
  required Child child,
  required LogKind kind,
  ChildLog? existing,
}) => showModalBottomSheet<void>(
  context: context,
  // Above the floating navigation bar.
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _LogEditor(child: child, kind: kind, existing: existing),
);

const _symptoms = [
  'Husten',
  'Schnupfen',
  'Ausschlag',
  'Erbrechen',
  'Durchfall',
  'Bauchweh',
  'Zahnen',
  'Verletzung',
];

class _LogEditor extends StatefulWidget {
  const _LogEditor({required this.child, required this.kind, this.existing});

  final Child child;
  final LogKind kind;
  final ChildLog? existing;

  @override
  State<_LogEditor> createState() => _LogEditorState();
}

class _LogEditorState extends State<_LogEditor> {
  late final ChildLog? _old = widget.existing;
  late DateTime _start = _old?.start ?? DateTime.now();
  late DateTime? _end = _old?.end;
  late BreastSide? _side = _old?.side ?? BreastSide.left;
  late MilkKind? _milk = _old?.milk ?? MilkKind.formula;
  late DiaperKind _diaper = _old?.diaper ?? DiaperKind.wet;
  late final _amount = TextEditingController(
    text: _old?.amountMl?.toString() ?? '',
  );
  late final _temp = TextEditingController(
    text: _old?.temperatureC?.toStringAsFixed(1).replaceAll('.', ',') ?? '',
  );
  late final _medication = TextEditingController(text: _old?.medication ?? '');
  late final _dose = TextEditingController(text: _old?.dose ?? '');
  late final _interval = TextEditingController(
    text: _old?.minIntervalHours == null
        ? ''
        : _old!.minIntervalHours!
              .toStringAsFixed(_old.minIntervalHours! % 1 == 0 ? 0 : 1)
              .replaceAll('.', ','),
  );
  late final _symptom = TextEditingController(text: _old?.symptom ?? '');
  late final _note = TextEditingController(text: _old?.note ?? '');

  /// Hours until the reminder (feedings) or true for "when possible again"
  /// (medicines); null: none.
  late double? _remindHours = _old?.remindAt == null
      ? null
      : _old!.remindAt!.difference(_old.start).inMinutes / 60;
  late bool _remindDose = _old?.remindAt != null;

  @override
  void initState() {
    super.initState();
    // Past entries of timed kinds get a default duration.
    if (_old == null && widget.kind.timed) {
      _start = DateTime.now().subtract(
        Duration(minutes: widget.kind == LogKind.sleep ? 60 : 15),
      );
      _end = DateTime.now();
    }
  }

  @override
  void dispose() {
    for (final c in [
      _amount,
      _temp,
      _medication,
      _dose,
      _interval,
      _symptom,
      _note,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _parse(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<DateTime?> _pick(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: widget.child.birthDate.subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  bool get _feeding =>
      widget.kind == LogKind.bottle ||
      widget.kind == LogKind.breast ||
      widget.kind == LogKind.solids;

  void _save() {
    final engine = AppScope.engineOf(context);
    final kind = widget.kind;
    final temp = _parse(_temp);
    if (kind == LogKind.temperature &&
        (temp == null || temp < 30 || temp > 45)) {
      _snack('Bitte eine Temperatur zwischen 30 und 45 °C eingeben');
      return;
    }
    if (kind == LogKind.medication && _medication.text.trim().isEmpty) {
      _snack('Bitte das Medikament angeben');
      return;
    }
    if (kind.timed && _end != null && !_end!.isAfter(_start)) {
      _snack('Das Ende liegt vor dem Beginn');
      return;
    }
    final interval = _parse(_interval);
    DateTime? remindAt;
    if (_feeding && _remindHours != null) {
      remindAt = _start.add(Duration(minutes: (_remindHours! * 60).round()));
    } else if (kind == LogKind.medication && _remindDose && interval != null) {
      remindAt = _start.add(Duration(minutes: (interval * 60).round()));
    }
    final log = ChildLog(
      id: _old?.id ?? newId(),
      childId: widget.child.id,
      kind: kind,
      start: _start,
      end: kind.timed ? _end : null,
      side: kind == LogKind.breast || kind == LogKind.pumping ? _side : null,
      milk: kind == LogKind.bottle ? _milk : null,
      amountMl: kind == LogKind.bottle || kind == LogKind.pumping
          ? int.tryParse(_amount.text.trim())
          : null,
      diaper: kind == LogKind.diaper ? _diaper : null,
      temperatureC: kind == LogKind.temperature ? temp : null,
      medication: kind == LogKind.medication ? _medication.text.trim() : '',
      dose: kind == LogKind.medication ? _dose.text.trim() : '',
      minIntervalHours: kind == LogKind.medication ? interval : null,
      symptom: kind == LogKind.symptom ? _symptom.text.trim() : '',
      note: _note.text.trim(),
      remindAt: remindAt,
      by: _old?.by ?? engine.memberId,
    );
    engine.saveChildLog(log);
    Navigator.pop(context);
    if (kind == LogKind.temperature) {
      final advice = feverAdvice(
        widget.child,
        temp!,
        at: _start,
        logs: engine.childLogs(widget.child.id),
      );
      if (advice.level.index >= FeverLevel.fever.index) {
        showFeverAdvice(context, advice.level, advice.text);
      }
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = widget.kind;
    final (icon, color) = logLook(kind);
    final engine = AppScope.engineOf(context);
    final logs = engine.childLogs(widget.child.id);
    final dateTime = DateFormat('d.M. HH:mm', 'de');
    final temp = _parse(_temp);
    final advice =
        kind == LogKind.temperature && temp != null && temp >= 35 && temp <= 45
        ? feverAdvice(widget.child, temp, at: _start, logs: logs)
        : null;
    final nextDose =
        kind == LogKind.medication && _medication.text.trim().isNotEmpty
        ? nextDoseAt(
            logs.where((l) => l.id != _old?.id).toList(),
            _medication.text,
          )
        : null;

    Widget numberField(
      TextEditingController c,
      String label, {
      bool decimal = false,
      bool autofocus = false,
    }) => TextField(
      controller: c,
      autofocus: autofocus,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(labelText: label),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconBlob(icon, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${kind.label}${_old == null ? ' eintragen' : ''}',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (kind == LogKind.breast || kind == LogKind.pumping) ...[
              SegmentedButton<BreastSide>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: BreastSide.left, label: Text('Links')),
                  ButtonSegment(value: BreastSide.right, label: Text('Rechts')),
                ],
                selected: {?_side},
                emptySelectionAllowed: kind == LogKind.pumping,
                onSelectionChanged: (s) =>
                    setState(() => _side = s.firstOrNull),
              ),
              const SizedBox(height: 12),
            ],
            if (kind == LogKind.bottle) ...[
              SegmentedButton<MilkKind>(
                showSelectedIcon: false,
                segments: [
                  for (final m in MilkKind.values)
                    ButtonSegment(value: m, label: Text(m.label)),
                ],
                selected: {?_milk},
                onSelectionChanged: (s) =>
                    setState(() => _milk = s.firstOrNull),
              ),
              const SizedBox(height: 12),
            ],
            if (kind == LogKind.bottle || kind == LogKind.pumping) ...[
              numberField(_amount, 'Menge (ml)', autofocus: _old == null),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final ml in [60, 90, 120, 150, 180, 210])
                    ActionChip(
                      label: Text('$ml'),
                      onPressed: () => setState(() => _amount.text = '$ml'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (kind == LogKind.diaper) ...[
              SegmentedButton<DiaperKind>(
                showSelectedIcon: false,
                segments: [
                  for (final d in DiaperKind.values)
                    ButtonSegment(value: d, label: Text(d.label)),
                ],
                selected: {_diaper},
                onSelectionChanged: (s) => setState(() => _diaper = s.first),
              ),
              const SizedBox(height: 12),
            ],
            if (kind == LogKind.temperature) ...[
              numberField(
                _temp,
                'Temperatur (°C)',
                decimal: true,
                autofocus: _old == null,
              ),
              if (advice != null && advice.level != FeverLevel.normal) ...[
                const SizedBox(height: 8),
                _AdviceBox(level: advice.level, text: advice.text),
              ],
              const SizedBox(height: 12),
            ],
            if (kind == LogKind.medication) ...[
              TextField(
                controller: _medication,
                autofocus: _old == null,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Medikament',
                  hintText: 'z. B. Fiebersaft',
                ),
              ),
              if (_old == null)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final m in recentMedications(logs).take(5))
                      ActionChip(
                        label: Text(m.medication),
                        onPressed: () => setState(() {
                          _medication.text = m.medication;
                          _dose.text = m.dose;
                          _interval.text = m.minIntervalHours == null
                              ? ''
                              : m.minIntervalHours!
                                    .toStringAsFixed(
                                      m.minIntervalHours! % 1 == 0 ? 0 : 1,
                                    )
                                    .replaceAll('.', ',');
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _dose,
                      decoration: const InputDecoration(
                        labelText: 'Dosis',
                        hintText: 'laut Arzt/Beipackzettel',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: numberField(
                      _interval,
                      'Mindestabstand (h)',
                      decimal: true,
                    ),
                  ),
                ],
              ),
              if (nextDose != null && nextDose.isAfter(_start)) ...[
                const SizedBox(height: 8),
                _AdviceBox(
                  level: FeverLevel.doctor,
                  text:
                      '„${_medication.text.trim()}“ laut eingetragenem Mindestabstand '
                      'frühestens wieder ab '
                      '${dateTime.format(nextDose)}.',
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Erinnern, wenn wieder möglich'),
                subtitle: const Text('Braucht einen Mindestabstand'),
                value: _remindDose,
                onChanged: (v) => setState(() => _remindDose = v),
              ),
            ],
            if (kind == LogKind.symptom) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in _symptoms)
                    ChoiceChip(
                      label: Text(s),
                      selected: _symptom.text == s,
                      onSelected: (_) => setState(() => _symptom.text = s),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _symptom,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Symptom'),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                InputChip(
                  avatar: const Icon(AppIcons.clock, size: 18),
                  label: Text(
                    '${kind.timed ? 'Beginn' : 'Zeit'}: ${dateTime.format(_start)}',
                  ),
                  onPressed: () async {
                    final t = await _pick(_start);
                    if (t != null) setState(() => _start = t);
                  },
                ),
                if (kind.timed)
                  InputChip(
                    avatar: const Icon(AppIcons.stop, size: 18),
                    label: Text(
                      _end == null
                          ? 'Läuft noch'
                          : 'Ende: ${dateTime.format(_end!)}',
                    ),
                    onPressed: () async {
                      final t = await _pick(_end ?? DateTime.now());
                      if (t != null) setState(() => _end = t);
                    },
                  ),
                if (kind.timed && _end != null && _end!.isAfter(_start))
                  Chip(label: Text(durationLabel(_end!.difference(_start)))),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: kind == LogKind.solids
                    ? 'Was gab es?'
                    : 'Notiz (optional)',
              ),
            ),
            if (_feeding) ...[
              const SizedBox(height: 12),
              Text(
                'Erinnerung an die nächste Mahlzeit',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final h in [null, 2.0, 2.5, 3.0, 4.0])
                    ChoiceChip(
                      label: Text(
                        h == null
                            ? 'Keine'
                            : 'in ${h.toString().replaceAll('.0', '').replaceAll('.', ',')} h',
                      ),
                      selected: _remindHours == h,
                      onSelected: (_) => setState(() => _remindHours = h),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                if (_old != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: const Text('Löschen'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () {
                      engine.deleteChildLog(_old.id);
                      Navigator.pop(context);
                    },
                  ),
                const Spacer(),
                ColorButton(label: 'Speichern', color: color, onPressed: _save),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AdviceBox extends StatelessWidget {
  const _AdviceBox({required this.level, required this.text});

  final FeverLevel level;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = level.index >= FeverLevel.doctor.index
        ? theme.colorScheme.error
        : const Color(0xFFE8703A);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.warningCircle, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Shows the fever hint after saving a high temperature.
Future<void> showFeverAdvice(
  BuildContext context,
  FeverLevel level,
  String text,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    scrollable: true,
    icon: Icon(
      AppIcons.thermometer,
      color: level.index >= FeverLevel.doctor.index
          ? Theme.of(context).colorScheme.error
          : const Color(0xFFE8703A),
    ),
    title: Text(
      level == FeverLevel.urgent
          ? 'Bitte ärztliche Hilfe holen'
          : level == FeverLevel.doctor
          ? 'Kinderarzt kontaktieren'
          : 'Fieber',
    ),
    content: Text('$text\n\nFamio ersetzt keinen ärztlichen Rat.'),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Verstanden'),
      ),
    ],
  ),
);
