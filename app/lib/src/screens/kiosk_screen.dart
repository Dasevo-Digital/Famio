import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_state.dart';
import '../data/birthdays.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../data/waste.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../weather/weather_tile.dart';
import '../widgets/data_builder.dart';
import '../widgets/files.dart';
import '../widgets/member_avatar.dart';
import 'chores_screens.dart';
import '../l10n.dart';

/// Opens the wall display (kitchen tablet).
Future<void> openKiosk(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const KioskScreen(),
      ),
    );

const _collections = {
  Collections.documents,
  Collections.tasks,
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
  Collections.wasteSettings,
  'members',
};

/// The family's day at a glance, big and always on: clock, weather,
/// appointments, chores the kids tick off right there, shopping list and
/// meals – by topic, or one column per member ("nach Personen").
class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key});

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  late Timer _clock;
  var _now = DateTime.now();

  /// After this long without a touch the photos start.
  static const idle = Duration(minutes: 2);
  static const _tick = Duration(seconds: 15);

  /// Clock ticks since the last touch (not wall time: the clock may jump).
  var _idleTicks = 0;
  var _photos = false;

  static bool get _mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() {
        _now = DateTime.now();
        _idleTicks++;
        if (_tick * _idleTicks >= idle) _photos = true;
      });
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
    return Listener(
      // Any touch counts as use and ends the photos.
      onPointerDown: (_) {
        _idleTicks = 0;
        if (_photos) setState(() => _photos = false);
      },
      child: Scaffold(
        backgroundColor: c.background,
        body: SafeArea(
          child: DataBuilder(
            collections: _collections,
            builder: (context, engine) {
              final photos = familyPhotos(engine);
              if (_photos &&
                  photos.isNotEmpty &&
                  AppScope.of(context).kioskPhotos) {
                return PhotoSlideshow(
                  photos: photos,
                  now: _now,
                  engine: engine,
                );
              }
              return LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 1200
                      ? 3
                      : constraints.maxWidth >= 760
                      ? 2
                      : 1;
                  // Areas the family switched off stay off here too.
                  final state = AppScope.of(context);
                  final hidden = state.hiddenModules;
                  final byPerson = state.kioskByPerson;
                  bool on(FamioSection s) => !hidden.contains(s.name);
                  final panels = [
                    if (on(FamioSection.calendar))
                      _EventsPanel(engine: engine, now: _now),
                    if (on(FamioSection.chores))
                      _ChoresPanel(engine: engine, now: _now),
                    WeatherTile(engine: engine),
                    if (on(FamioSection.shopping))
                      _ShoppingPanel(engine: engine),
                    if (on(FamioSection.meals))
                      _MealsPanel(engine: engine, now: _now),
                  ];
                  const gap = 16.0;
                  final width =
                      (constraints.maxWidth - 40 - gap * (columns - 1)) /
                      columns;
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              DateFormat.jm(appLanguage).format(_now),
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
                                  DateFormat.MMMMEEEEd(
                                    appLanguage,
                                  ).format(_now),
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(color: c.inkSoft),
                                ),
                              ),
                            ),
                            BubbleButton(
                              icon: byPerson
                                  ? AppIcons.layoutGrid
                                  : AppIcons.usersThree,
                              tooltip: byPerson
                                  ? tr.kioskShowTopic
                                  : tr.kioskShowPerson,
                              onPressed: () =>
                                  state.setKioskByPerson(!byPerson),
                            ),
                            const SizedBox(width: 8),
                            if (photos.isNotEmpty) ...[
                              BubbleButton(
                                icon: state.kioskPhotos
                                    ? AppIcons.image
                                    : AppIcons.imageBroken,
                                tooltip: state.kioskPhotos
                                    ? tr.kioskShowNoPhotos
                                    : tr.kioskShowPhotosWhenNobody,
                                onPressed: () =>
                                    state.setKioskPhotos(!state.kioskPhotos),
                              ),
                              const SizedBox(width: 8),
                            ],
                            BubbleButton(
                              icon: AppIcons.x,
                              tooltip: tr.kioskCloseWallDisplay,
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
                                  tr.kioskTodayWhat(b.headline(day)),
                                  style: theme.textTheme.headlineSmall,
                                ),
                              ),
                            ),
                        if (engine.nextWastePickup(_now) case final pickup?)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: SoftCard(
                              color: c.tint(FamioSection.chores),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 12,
                              ),
                              child: Text(
                                [
                                  wasteHeadline(pickup, _now),
                                  if (engine.wasteSettings.memberIds.isNotEmpty)
                                    engine
                                        .wasteResponsible(pickup)
                                        .map((m) => m.displayName)
                                        .join(', '),
                                ].join(' · '),
                                style: theme.textTheme.titleLarge,
                              ),
                            ),
                          ),
                        if (on(FamioSection.calendar))
                          if (engine.countdowns(_now) case final counts
                              when counts.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  for (final e in counts.take(4))
                                    SoftCard(
                                      color: c.tint(FamioSection.calendar),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 12,
                                      ),
                                      child: Text(
                                        '🎉 ${e.occurrence.event.title}: '
                                        '${countdownLabel(e.occurrence, e.days, _now)}',
                                        style: theme.textTheme.titleLarge,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        const SizedBox(height: 8),
                        if (byPerson)
                          _PeopleBoard(
                            engine: engine,
                            now: _now,
                            width: constraints.maxWidth - 40,
                            hidden: hidden,
                          )
                        else
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
                                          padding: const EdgeInsets.only(
                                            bottom: gap,
                                          ),
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
        if (items.isEmpty) _BigLine(tr.kioskNothingPlanned, dim: true),
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
      title: tr.commonEvents,
      children: [
        ...day(today, tr.commonToday),
        ...day(tomorrow, tr.commonTomorrow),
      ],
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
      title: tr.kioskChoresRoutines,
      children: [
        if (engine.chores.isEmpty && engine.routines.isEmpty)
          _BigLine(tr.kioskNoChoresYet, dim: true),
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
                    label: ch.title,
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
      title: list?.name ?? tr.sectionShopping,
      children: [
        if (open.isEmpty) _BigLine(tr.kioskNothingBuy, dim: true),
        for (final i in open.take(10))
          _BigLine(
            i.quantity.isEmpty ? i.name : '${i.quantity} ${i.name}',
            leading: const Text('•', style: TextStyle(fontSize: 18)),
          ),
        if (open.length > 10)
          _BigLine(tr.kioskCountMore(open.length - 10), dim: true),
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
      title: tr.kioskMealsToday,
      children: [
        if (meals.isEmpty) _BigLine(tr.kioskNothingPlannedYet, dim: true),
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

/// One column per member: today's appointments, open tasks, chores and
/// routines – plus one for the whole family (appointments without anyone,
/// tasks without assignee). Each device shows only what its member may see,
/// signed in as the Home Assistant service account the whole family.
class _PeopleBoard extends StatelessWidget {
  const _PeopleBoard({
    required this.engine,
    required this.now,
    required this.width,
    required this.hidden,
  });

  final SyncEngine engine;
  final DateTime now;
  final double width;
  final Set<String> hidden;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final today = DateUtils.dateOnly(now);
    final tomorrow = today.add(const Duration(days: 1));
    bool on(FamioSection s) => !hidden.contains(s.name);
    final occurrences = on(FamioSection.calendar)
        ? engine
              .occurrences(today, tomorrow)
              .where((o) => o.event.allDay || o.end.isAfter(now))
              .toList()
        : <Occurrence>[];
    final openTasks = on(FamioSection.tasks)
        ? (engine.tasks.where((t) => !t.done).toList()..sort((a, b) {
            final da = a.due, db = b.due;
            if (da == null || db == null) return da == null ? 1 : -1;
            return da.compareTo(db);
          }))
        : <Task>[];
    final members = engine.members.where((m) => !m.isService).toList();
    final ids = {for (final m in members) m.id};

    const gap = 16.0;
    final columns = (width / 300).floor().clamp(1, 6);
    final cardWidth = (width - gap * (columns - 1)) / columns;

    Widget taskLine(Task t) {
      final due = t.due;
      final late = due != null && DateUtils.dateOnly(due).isBefore(today);
      return _BigLine(
        t.title,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (due != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  late
                      ? tr.pregnancyOverdue
                      : DateUtils.isSameDay(due, today)
                      ? tr.commonTodayLower
                      : DateFormat.MEd(appLanguage).format(due),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: late ? c.danger : c.inkSoft,
                  ),
                ),
              ),
            RoundCheck(
              label: t.title,
              value: false,
              size: 30,
              color: c.strong(FamioSection.tasks),
              onChanged: (_) => engine.saveTask(t.completed()),
            ),
          ],
        ),
      );
    }

    Widget eventLine(Occurrence o) => _BigLine(
      o.event.title,
      leading: SizedBox(
        width: 56,
        child: Text(
          o.event.allDay ? 'ganz.' : timeLabel(o.start),
          style: theme.textTheme.titleMedium,
        ),
      ),
    );

    Widget card({
      required Widget header,
      required Color color,
      required List<Occurrence> events,
      required List<Task> tasks,
      List<Widget> extra = const [],
    }) => SizedBox(
      width: cardWidth,
      child: SoftCard(
        color: color,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            const SizedBox(height: 8),
            if (events.isEmpty && tasks.isEmpty && extra.isEmpty)
              _BigLine(tr.kioskFreeToday, dim: true),
            for (final o in events.take(6)) eventLine(o),
            if (events.isNotEmpty && (tasks.isNotEmpty || extra.isNotEmpty))
              const Divider(height: 16),
            ...extra,
            for (final t in tasks.take(6)) taskLine(t),
            if (tasks.length > 6)
              _BigLine(tr.kioskCountMore2(tasks.length - 6), dim: true),
          ],
        ),
      ),
    );

    final cards = <Widget>[
      card(
        color: c.tint(FamioSection.home),
        header: Row(
          children: [
            IconBlob(
              AppIcons.usersThree,
              color: c.strong(FamioSection.home),
              background: c.surface.withValues(alpha: 0.7),
              size: 38,
            ),
            const SizedBox(width: 10),
            Text(tr.commonEveryone, style: theme.textTheme.titleLarge),
          ],
        ),
        events: [
          for (final o in occurrences)
            if (!o.event.memberIds.any(ids.contains)) o,
        ],
        tasks: [
          for (final t in openTasks)
            if (t.assigneeId == null || !ids.contains(t.assigneeId)) t,
        ],
      ),
      for (final m in members)
        card(
          // A light wash of the member's own color.
          color: Color.alphaBlend(
            Color(m.color ?? 0xFF607D8B).withValues(alpha: 0.16),
            c.surface,
          ),
          header: Row(
            children: [
              MemberAvatar(m, radius: 19),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  m.displayName,
                  style: theme.textTheme.titleLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (on(FamioSection.chores) &&
                  engine.pointCollectors.any((p) => p.id == m.id))
                Text(
                  '⭐ ${engine.pointBalance(m.id)}',
                  style: theme.textTheme.titleMedium,
                ),
            ],
          ),
          events: [
            for (final o in occurrences)
              if (o.event.memberIds.contains(m.id)) o,
          ],
          tasks: [
            for (final t in openTasks)
              if (t.assigneeId == m.id) t,
          ],
          extra: [
            if (on(FamioSection.chores)) ...[
              for (final r in engine.routinesFor(m.id, today))
                () {
                  final run = engine.routineRun(r, today, m.id);
                  final done = r.steps
                      .where((s) => run.done.contains(s.id))
                      .length;
                  return InkWell(
                    onTap: () => openRoutine(context, r, m.id),
                    child: _BigLine(
                      '${r.emoji} ${r.title}',
                      trailing: Text(
                        done == r.steps.length
                            ? '🎉'
                            : '$done/${r.steps.length}',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  );
                }(),
              for (final ch in engine.chores)
                if (ch.dueOn(today) &&
                    ch.memberIds.isNotEmpty &&
                    ch.isFor(m.id, today))
                  () {
                    final done = engine.choreCompletion(ch, today);
                    return _BigLine(
                      '${ch.emoji} ${ch.title}',
                      dim: done != null,
                      trailing: RoundCheck(
                        label: ch.title,
                        value: done != null,
                        size: 30,
                        color: done?.status == PointStatus.pending
                            ? c.inkSoft
                            : c.strong(FamioSection.chores),
                        onChanged: (_) {
                          if (engine.iAmGuest) return;
                          if (done == null) {
                            engine.completeChore(
                              ch,
                              today,
                              m.id,
                              asRequest: true,
                            );
                          } else if (done.status == PointStatus.pending) {
                            engine.undoChore(ch, today);
                          }
                        },
                      ),
                    );
                  }(),
            ],
          ],
        ),
    ];
    return Wrap(spacing: gap, runSpacing: gap, children: cards);
  }
}

/// Images in the documents category "Fotos" the member may see.
List<FileRef> familyPhotos(SyncEngine engine) => [
  for (final d in engine.documents)
    if (d.category == DocumentCategory.photos &&
        d.file != null &&
        d.file!.mime.startsWith('image/'))
      d.file!,
];

/// The wall display while nobody uses it: one family photo after the
/// other, with the time and the next appointment. A touch ends it.
class PhotoSlideshow extends StatefulWidget {
  const PhotoSlideshow({
    super.key,
    required this.photos,
    required this.now,
    required this.engine,
  });

  final List<FileRef> photos;
  final DateTime now;
  final SyncEngine engine;

  static const every = Duration(seconds: 20);

  @override
  State<PhotoSlideshow> createState() => _PhotoSlideshowState();
}

class _PhotoSlideshowState extends State<PhotoSlideshow> {
  late final _order = [...widget.photos]..shuffle();
  var _index = 0;
  late final Timer _next = Timer.periodic(PhotoSlideshow.every, (_) {
    if (mounted) setState(() => _index = (_index + 1) % _order.length);
  });

  @override
  void initState() {
    super.initState();
    _next;
  }

  @override
  void dispose() {
    _next.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = widget.now;
    final next = widget.engine
        .occurrences(now, now.add(const Duration(days: 2)))
        .where((o) => !o.event.allDay && o.start.isAfter(now))
        .firstOrNull;
    const shadow = [Shadow(blurRadius: 12, color: Colors.black54)];
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(seconds: 2),
            child: CachedImage(
              _order[_index % _order.length],
              key: ValueKey(_order[_index % _order.length].id),
              thumb: 1920,
              fit: BoxFit.contain,
              radius: 0,
            ),
          ),
          Positioned(
            left: 32,
            bottom: 24,
            right: 32,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat.jm(appLanguage).format(now),
                  style: theme.textTheme.displayMedium?.copyWith(
                    color: Colors.white,
                    fontFamily: 'Fredoka',
                    fontWeight: FontWeight.w600,
                    shadows: shadow,
                  ),
                ),
                if (next != null)
                  Text(
                    '${DateFormat.jm(appLanguage).format(next.start)} ${next.event.title}',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      shadows: shadow,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
