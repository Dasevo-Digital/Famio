import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/birthdays.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../weather/weather_tile.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import 'chores_screens.dart';

/// Opens the wall display (kitchen tablet).
Future<void> openKiosk(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const KioskScreen(),
      ),
    );

const _collections = {
  Collections.events,
  Collections.externalEvents,
  Collections.calendarSubscriptions,
  Collections.chores,
  Collections.routines,
  Collections.routineRuns,
  Collections.pointEntries,
  Collections.shoppingLists,
  Collections.shoppingItems,
  Collections.mealPlan,
  Collections.recipes,
  Collections.places,
  'members',
};

/// The family's day at a glance, big and always on: clock, weather,
/// appointments, chores the kids tick off right there, shopping list and
/// meals.
class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key});

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  late Timer _clock;
  var _now = DateTime.now();

  static bool get _mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WakelockPlus.enable().catchError((Object _) {});
    if (_mobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    _clock.cancel();
    WakelockPlus.disable().catchError((Object _) {});
    if (_mobile) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        child: DataBuilder(
          collections: _collections,
          builder: (context, engine) => LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1200
                  ? 3
                  : constraints.maxWidth >= 760
                  ? 2
                  : 1;
              final panels = [
                _EventsPanel(engine: engine, now: _now),
                _ChoresPanel(engine: engine, now: _now),
                WeatherTile(engine: engine),
                _ShoppingPanel(engine: engine),
                _MealsPanel(engine: engine, now: _now),
              ];
              const gap = 16.0;
              final width =
                  (constraints.maxWidth - 40 - gap * (columns - 1)) / columns;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          DateFormat.Hm('de').format(_now),
                          style: theme.textTheme.displayLarge?.copyWith(
                            fontFamily: 'Fredoka',
                            fontWeight: FontWeight.w600,
                            color: c.ink,
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              DateFormat('EEEE, d. MMMM', 'de').format(_now),
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: c.inkSoft,
                              ),
                            ),
                          ),
                        ),
                        BubbleButton(
                          icon: AppIcons.x,
                          tooltip: 'Wandanzeige beenden',
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    for (final (b, day) in upcomingBirthdays(
                      engine,
                      _now,
                      days: 1,
                    ))
                      if (DateUtils.isSameDay(day, _now))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SoftCard(
                            color: c.tint(FamioSection.kids),
                            child: Text(
                              '🎂 Heute: ${b.headline(day)}',
                              style: theme.textTheme.headlineSmall,
                            ),
                          ),
                        ),
                    const SizedBox(height: 8),
                    // Columns instead of rows: no gaps under short panels.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var col = 0; col < columns; col++) ...[
                          if (col > 0) const SizedBox(width: gap),
                          SizedBox(
                            width: width,
                            child: Column(
                              children: [
                                for (
                                  var i = col;
                                  i < panels.length;
                                  i += columns
                                )
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: gap),
                                    child: panels[i],
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.section,
    required this.title,
    required this.children,
  });

  final FamioSection section;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return SoftCard(
      color: c.tint(section),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBlob(
                section.icon,
                color: c.strong(section),
                background: c.surface.withValues(alpha: 0.7),
                size: 42,
              ),
              const SizedBox(width: 12),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _BigLine extends StatelessWidget {
  const _BigLine(this.text, {this.leading, this.trailing, this.dim = false});

  final String text;
  final Widget? leading;
  final Widget? trailing;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: dim ? c.inkSoft : c.ink,
                fontSize: 18,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _EventsPanel extends StatelessWidget {
  const _EventsPanel({required this.engine, required this.now});

  final SyncEngine engine;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(now);
    final tomorrow = today.add(const Duration(days: 1));
    List<Widget> day(DateTime d, String label) {
      final items = engine
          .occurrences(d, d.add(const Duration(days: 1)))
          .where((o) => o.event.allDay || o.end.isAfter(now))
          .toList();
      return [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        if (items.isEmpty) const _BigLine('Nichts geplant', dim: true),
        for (final o in items.take(6))
          _BigLine(
            o.event.title,
            leading: SizedBox(
              width: 56,
              child: Text(
                o.event.allDay ? 'ganz.' : timeLabel(o.start),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final id in o.event.memberIds.take(3))
                  if (engine.member(id) case final m?)
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: MemberAvatar(m, radius: 12),
                    ),
              ],
            ),
          ),
      ];
    }

    return _Panel(
      section: FamioSection.calendar,
      title: 'Termine',
      children: [...day(today, 'Heute'), ...day(tomorrow, 'Morgen')],
    );
  }
}

class _ChoresPanel extends StatelessWidget {
  const _ChoresPanel({required this.engine, required this.now});

  final SyncEngine engine;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final today = DateUtils.dateOnly(now);
    final people = engine.pointCollectors;
    final canTick = !engine.iAmGuest;
    return _Panel(
      section: FamioSection.chores,
      title: 'Ämter & Routinen',
      children: [
        if (engine.chores.isEmpty && engine.routines.isEmpty)
          const _BigLine('Noch keine Ämter', dim: true),
        for (final p in people) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Row(
              children: [
                MemberAvatar(p, radius: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  '⭐ ${engine.pointBalance(p.id)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
          for (final r in engine.routinesFor(p.id, today))
            () {
              final run = engine.routineRun(r, today, p.id);
              final done = r.steps.where((s) => run.done.contains(s.id)).length;
              return InkWell(
                onTap: () => openRoutine(context, r, p.id),
                child: _BigLine(
                  '${r.emoji} ${r.title}',
                  trailing: Text(
                    done == r.steps.length ? '🎉' : '$done/${r.steps.length}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              );
            }(),
          for (final ch in engine.chores)
            if (ch.dueOn(today) &&
                ch.memberIds.isNotEmpty &&
                ch.isFor(p.id, today))
              () {
                final done = engine.choreCompletion(ch, today);
                return _BigLine(
                  '${ch.emoji} ${ch.title}',
                  dim: done != null,
                  trailing: RoundCheck(
                    value: done != null,
                    size: 34,
                    color: done?.status == PointStatus.pending
                        ? c.inkSoft
                        : c.strong(FamioSection.chores),
                    onChanged: (_) {
                      if (!canTick) return;
                      if (done == null) {
                        // Shared screen: adults confirm the points.
                        engine.completeChore(ch, today, p.id, asRequest: true);
                      } else if (done.status == PointStatus.pending) {
                        engine.undoChore(ch, today);
                      }
                    },
                  ),
                );
              }(),
        ],
      ],
    );
  }
}

class _ShoppingPanel extends StatelessWidget {
  const _ShoppingPanel({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final list = engine.shoppingLists.firstOrNull;
    final open = list == null
        ? <ShoppingItem>[]
        : engine.shoppingItems(list.id).where((i) => !i.checked).toList();
    return _Panel(
      section: FamioSection.shopping,
      title: list?.name ?? 'Einkauf',
      children: [
        if (open.isEmpty) const _BigLine('Nichts zu besorgen ✓', dim: true),
        for (final i in open.take(10))
          _BigLine(
            i.quantity.isEmpty ? i.name : '${i.quantity} ${i.name}',
            leading: const Text('•', style: TextStyle(fontSize: 18)),
          ),
        if (open.length > 10)
          _BigLine('… und ${open.length - 10} mehr', dim: true),
      ],
    );
  }
}

class _MealsPanel extends StatelessWidget {
  const _MealsPanel({required this.engine, required this.now});

  final SyncEngine engine;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(now);
    final meals = engine.plannedMeals(
      today,
      today.add(const Duration(days: 1)),
    );
    return _Panel(
      section: FamioSection.meals,
      title: 'Essen heute',
      children: [
        if (meals.isEmpty) const _BigLine('Noch nichts geplant', dim: true),
        for (final m in meals)
          _BigLine(
            engine.recipe(m.recipeId)?.title ?? m.title,
            leading: SizedBox(
              width: 90,
              child: Text(
                m.slot.label,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
      ],
    );
  }
}
