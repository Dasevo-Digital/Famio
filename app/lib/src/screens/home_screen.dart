import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../data/birthdays.dart';
import '../data/health_logic.dart';
import '../data/kids_logic.dart';
import '../data/pregnancy_logic.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import 'home_shell.dart';
import 'kiosk_screen.dart';
import 'budget_screens.dart';
import 'location_screens.dart';
import 'settings_screen.dart';
import '../weather/weather_tile.dart';
import 'search_screen.dart';
import 'notes_screen.dart';
import 'wishes_screen.dart';
import 'waste_screen.dart';
import '../data/waste.dart';
import '../data/deadlines.dart';
import 'deadlines_screen.dart';
import 'conflicts_screen.dart';
import '../widgets/setup_checklist.dart';
import 'sos_screens.dart';
import '../l10n.dart';

/// Family dashboard: what matters today, one colorful tile per area.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static String _greeting(DateTime now) => switch (now.hour) {
    < 5 => tr.homeGoodNight,
    < 11 => tr.homeGoodMorning,
    < 17 => tr.homeHello,
    < 22 => tr.homeGoodEvening,
    _ => tr.homeGoodNight,
  };

  @override
  Widget build(BuildContext context) {
    final me = AppScope.of(context).me!;
    final now = DateTime.now();
    return SectionPage(
      section: FamioSection.home,
      title: '${_greeting(now)}, ${me.displayName}!',
      subtitle: DateFormat.MMMMEEEEd(appLanguage).format(now),
      actions: [
        // Children get the big button on the page itself.
        if (!me.isGuest && !me.isService && !me.isChild)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: SosHoldButton(),
          ),
        BubbleButton(
          icon: AppIcons.magnifyingGlass,
          tooltip: tr.commonSearch,
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
        ),
        BubbleButton(
          icon: AppIcons.tv,
          tooltip: tr.homeWallDisplay,
          onPressed: () => openKiosk(context),
        ),
        const SyncStatusIcon(),
        MemberAvatar(
          me,
          radius: 22,
          tooltip: tr.settingsMyProfile,
          onTap: () => showProfileEditor(context),
        ),
      ],
      body: DataBuilder(
        collections: const {
          Collections.events,
          Collections.externalEvents,
          Collections.calendarSubscriptions,
          Collections.tasks,
          Collections.shoppingLists,
          Collections.shoppingItems,
          Collections.chatMessages,
          Collections.chatReads,
          Collections.children,
          Collections.childEntries,
          Collections.childLogs,
          Collections.contacts,
          Collections.pregnancies,
          Collections.timetables,
          Collections.recipes,
          Collections.mealPlan,
          Collections.budgetEntries,
          Collections.documents,
          Collections.places,
          Collections.memberLocations,
          Collections.chores,
          Collections.routines,
          Collections.routineRuns,
          Collections.pointEntries,
          Collections.medications,
          Collections.medicationIntakes,
          Collections.notes,
          Collections.wishes,
          Collections.wasteSettings,
          Collections.deadlines,
          Collections.conflicts,
          'members',
        },
        builder: (context, engine) => LayoutBuilder(
          builder: (context, constraints) {
            final guest = engine.iAmGuest;
            final columns = constraints.maxWidth >= 1100
                ? 3
                : (constraints.maxWidth >= 640 ? 2 : 1);
            // Areas the family switched off get no tile either.
            final hidden = AppScope.of(context).hiddenModules;
            bool on(FamioSection s) => !hidden.contains(s.name);
            final tiles = [
              if (on(FamioSection.calendar)) _TodayTile(engine: engine),
              WeatherTile(engine: engine),
              if (on(FamioSection.calendar) &&
                  engine.countdowns(now).isNotEmpty)
                _CountdownTile(engine: engine),
              if (engine.nextWastePickup(now) != null)
                _WasteTile(engine: engine),
              if (on(FamioSection.tasks)) _TasksTile(engine: engine),
              if (!guest && engine.deadlinesSoon(now).isNotEmpty)
                _DeadlinesTile(engine: engine),
              if (on(FamioSection.shopping)) _ShoppingTile(engine: engine),
              if (on(FamioSection.meals) &&
                  engine
                      .plannedMeals(
                        DateUtils.dateOnly(now),
                        DateUtils.dateOnly(now).add(const Duration(days: 2)),
                      )
                      .isNotEmpty)
                _MealsTile(engine: engine),
              if (on(FamioSection.chores) &&
                  (engine.chores.isNotEmpty || engine.routines.isNotEmpty))
                _ChoresTile(engine: engine),
              if (on(FamioSection.chat)) _ChatTile(engine: engine),
              if (!guest && on(FamioSection.location))
                _WhereTile(engine: engine),
              if (on(FamioSection.health) && engine.medications.isNotEmpty)
                _MedsTile(engine: engine),
              if (!guest && on(FamioSection.kids)) _KidsTile(engine: engine),
              if (on(FamioSection.calendar) &&
                  upcomingBirthdays(engine, now).isNotEmpty)
                _BirthdaysTile(engine: engine),
              if (!guest && on(FamioSection.documents))
                _DocumentsTile(engine: engine),
              if (on(FamioSection.budget) && engine.budgetEntries.isNotEmpty)
                _BudgetTile(engine: engine),
              _NotesTile(engine: engine),
              if (!guest &&
                  (engine.wishes.isNotEmpty ||
                      upcomingBirthdays(engine, now).isNotEmpty))
                _WishesTile(engine: engine),
            ];
            const gap = 16.0;
            // Tiles of a row share its height, so the grid has no holes.
            return SingleChildScrollView(
              padding: EdgeInsets.only(
                top: 8,
                bottom: listBottomPadding(context),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (engine.me?.isChild ?? false) ...[
                    const SosCard(),
                    const SizedBox(height: gap),
                  ],
                  if (me.isAdmin) const SetupBanner(),
                  if (engine.conflicts case final open
                      when open.isNotEmpty) ...[
                    _ConflictBanner(count: open.length),
                    const SizedBox(height: gap),
                  ],
                  for (var i = 0; i < tiles.length; i += columns) ...[
                    if (i > 0) const SizedBox(height: gap),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var j = i; j < i + columns; j++) ...[
                            if (j > i) const SizedBox(width: gap),
                            Expanded(
                              child: j < tiles.length
                                  ? tiles[j]
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ChoresTile extends StatelessWidget {
  const _ChoresTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final me = engine.me;
    final people = me != null && me.isChild ? [me] : engine.pointCollectors;
    final pending = engine.iAmAdult ? engine.pendingPoints.length : 0;
    return _Tile(
      section: FamioSection.chores,
      title: tr.sectionChores,
      badge: pending > 0 ? tr.commonOpenCount(pending) : null,
      child: Column(
        children: [
          for (final p in people.take(4))
            () {
              final open = [
                for (final ch in engine.chores)
                  if (ch.dueOn(today) &&
                      ch.isFor(p.id, today) &&
                      ch.memberIds.isNotEmpty &&
                      engine.choreCompletion(ch, today) == null)
                    ch,
              ];
              return _Line(
                open.isEmpty
                    ? tr.homeNameAllDone(p.displayName)
                    : '${p.displayName}: ${open.map((c) => '${c.emoji} ${c.title}').join(', ')}',
                leading: MemberAvatar(p, radius: 11),
                trailing: '⭐ ${engine.pointBalance(p.id)}',
              );
            }(),
        ],
      ),
    );
  }
}

class _MedsTile extends StatelessWidget {
  const _MedsTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final doses = [
      for (final m in engine.medications)
        for (final at in m.dosesOn(now))
          if (engine.intakeAt(m, at) == null) (m, at),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    final low = [
      for (final m in engine.medications)
        if (m.daysLeft(engine.takenSinceCount(m)) case final d?
            when d <= m.refillDays)
          m,
    ];
    return _Tile(
      section: FamioSection.health,
      title: tr.commonMedications,
      badge: doses.isEmpty ? null : tr.commonOpenCount(doses.length),
      child: Column(
        children: [
          if (doses.isEmpty) _Line(tr.homeAllTakenToday, dim: true),
          for (final (m, at) in doses.take(3))
            _Line(
              [m.name, if (m.personName.isNotEmpty) m.personName].join(' · '),
              trailing: timeLabel(at),
            ),
          for (final m in low.take(2)) _Line(tr.homeNameBuyMoreSoon(m.name)),
        ],
      ),
    );
  }
}

/// Common frame of a dashboard tile.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.section,
    required this.title,
    required this.child,
    this.badge,
    this.icon,
    this.onTap,
  });

  final FamioSection section;
  final String title;
  final Widget child;
  final String? badge;

  /// Instead of the section's icon and page (e.g. the pinboard).
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    return SoftCard(
      color: c.tint(section),
      onTap: onTap ?? () => FamioNav.of(context).go(section),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBlob(
                icon ?? section.icon,
                color: c.strong(section),
                background: c.surface.withValues(alpha: 0.7),
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: c.strong(section),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    badge!,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: c.onStrong,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.text, {this.leading, this.trailing, this.dim = false});

  final String text;
  final Widget? leading;
  final String? trailing;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: dim ? c.inkSoft : c.ink);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 10)],
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: c.inkSoft),
            ),
        ],
      ),
    );
  }
}

class _TodayTile extends StatelessWidget {
  const _TodayTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final todays = engine.occurrences(
      today,
      today.add(const Duration(days: 1)),
    );
    final upcoming = todays.isEmpty
        ? engine
              .occurrences(
                today.add(const Duration(days: 1)),
                today.add(const Duration(days: 8)),
              )
              .take(3)
              .toList()
        : const <Occurrence>[];
    final c = FamioColors.of(context);
    return _Tile(
      section: FamioSection.calendar,
      title: tr.commonToday,
      badge: todays.isEmpty ? null : '${todays.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (todays.isEmpty) _Line(tr.homeNothingPlannedToday, dim: true),
          for (final o in todays.take(4))
            _Line(
              // My lift today stands out.
              o.event.bringerId == engine.memberId ||
                      o.event.pickerId == engine.memberId
                  ? '🚗 ${o.event.title}'
                  : o.event.title,
              leading: _Dot(c.strong(FamioSection.calendar)),
              trailing: o.event.allDay
                  ? tr.commonAllDayLower
                  : timeLabel(o.start),
            ),
          if (upcoming.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final o in upcoming)
              _Line(
                o.event.title,
                leading: _Dot(c.inkSoft),
                trailing: dayLabel(o.start),
                dim: true,
              ),
          ],
        ],
      ),
    );
  }
}

/// Looking forward: the next marked event big, a few more below.
class _CountdownTile extends StatelessWidget {
  const _CountdownTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final all = engine.countdowns(now);
    final first = all.first;
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final accent = c.strong(FamioSection.calendar);
    return _Tile(
      section: FamioSection.calendar,
      title: tr.homeCountdown,
      icon: AppIcons.partyPopper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (first.days > 1)
                Text(
                  '${first.days}',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontFamily: 'Fredoka',
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              if (first.days > 1) const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    first.days > 1
                        ? tr.homeDaysUntilTitle(first.occurrence.event.title)
                        : '${first.occurrence.event.title}: '
                              '${countdownLabel(first.occurrence, first.days, now)}! 🎉',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
            ],
          ),
          for (final e in all.skip(1).take(3))
            _Line(
              e.occurrence.event.title,
              leading: _Dot(c.inkSoft),
              trailing: countdownLabel(e.occurrence, e.days, now),
              dim: true,
            ),
        ],
      ),
    );
  }
}

/// Which bins go out today or tomorrow, and whose turn it is.
class _WasteTile extends StatelessWidget {
  const _WasteTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final pickup = engine.nextWastePickup(now)!;
    final who = engine.wasteSettings.memberIds.isEmpty
        ? const <FamilyMember>[]
        : engine.wasteResponsible(pickup);
    final mine = who.any((m) => m.id == engine.memberId);
    return _Tile(
      section: FamioSection.chores,
      title: tr.homeBins,
      icon: AppIcons.recycle,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const WasteScreen())),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Line(wasteHeadline(pickup, now)),
          if (who.isNotEmpty)
            _Line(
              mine
                  ? tr.homeSTurn
                  : tr.homeNamesSTurn(who.map((m) => m.displayName).join(', ')),
              leading: MemberAvatar(who.first, radius: 10),
              dim: true,
            ),
        ],
      ),
    );
  }
}

/// Changes that crossed and wait for a decision.
class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return SoftCard(
      color: c.tint(FamioSection.home),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const ConflictsScreen())),
      child: Row(
        children: [
          Icon(AppIcons.arrowsLeftRight, color: c.strong(FamioSection.home)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              count == 1
                  ? tr.homeChangeOverlappedPleaseTake
                  : tr.homeCountChangesOverlappedPlease(count),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Icon(AppIcons.caretRight, color: c.inkSoft),
        ],
      ),
    );
  }
}

/// TÜV, boiler service & co. that are due soon or overdue.
class _DeadlinesTile extends StatelessWidget {
  const _DeadlinesTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final soon = engine.deadlinesSoon(now);
    final c = FamioColors.of(context);
    return _Tile(
      section: FamioSection.tasks,
      title: tr.commonDeadlines,
      icon: AppIcons.wrench,
      badge: '${soon.length}',
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const DeadlinesScreen())),
      child: Column(
        children: [
          for (final d in soon.take(4))
            _Line(
              '${d.area.emoji} ${d.label}',
              leading: _Dot(
                d.daysLeft(now) < 0
                    ? Theme.of(context).colorScheme.error
                    : c.strong(FamioSection.tasks),
              ),
              trailing: deadlineWhen(d, now),
            ),
        ],
      ),
    );
  }
}

class _TasksTile extends StatelessWidget {
  const _TasksTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final open = engine.tasks.where((t) => !t.done).toList()
      ..sort((a, b) {
        // Mine first, then by due date.
        final mine =
            (b.assigneeId == engine.memberId ? 1 : 0) -
            (a.assigneeId == engine.memberId ? 1 : 0);
        if (mine != 0) return mine;
        return (a.due ?? DateTime(9999)).compareTo(b.due ?? DateTime(9999));
      });
    final c = FamioColors.of(context);
    return _Tile(
      section: FamioSection.tasks,
      title: tr.sectionTasks,
      badge: open.isEmpty ? null : '${open.length}',
      child: Column(
        children: [
          if (open.isEmpty) _Line(tr.homeAllDoneGreat, dim: true),
          for (final t in open.take(4))
            _Line(
              t.title,
              leading: Icon(
                AppIcons.circle,
                size: 14,
                color: c.strong(FamioSection.tasks),
              ),
              trailing: t.due == null ? null : dayLabel(t.due!),
            ),
        ],
      ),
    );
  }
}

class _ShoppingTile extends StatelessWidget {
  const _ShoppingTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final lists = engine.shoppingLists;
    final c = FamioColors.of(context);
    final total = lists.fold(
      0,
      (n, l) => n + engine.shoppingItems(l.id).where((i) => !i.checked).length,
    );
    return _Tile(
      section: FamioSection.shopping,
      title: tr.sectionShopping,
      badge: total == 0 ? null : '$total',
      child: Column(
        children: [
          if (lists.isEmpty) _Line(tr.homeNoShoppingListYet, dim: true),
          for (final l in lists.take(4))
            _Line(
              l.name,
              leading: Icon(
                AppIcons.basket,
                size: 18,
                color: c.strong(FamioSection.shopping),
              ),
              trailing: tr.commonOpenCount(
                engine.shoppingItems(l.id).where((i) => !i.checked).length,
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final unread = engine.totalUnread;
    final all =
        engine
            .records(Collections.chatMessages)
            .map(ChatMessage.fromRecord)
            .toList()
          ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
    final last = all.firstOrNull;
    final author = engine.member(last?.authorId);
    return _Tile(
      section: FamioSection.chat,
      title: tr.sectionChat,
      badge: unread == 0 ? null : tr.homeCountNew(unread),
      child: last == null
          ? _Line(tr.homeNoMessagesYet, dim: true)
          : _Line(
              last.text.isNotEmpty
                  ? last.text
                  : '📎 ${last.attachment?.name ?? tr.commonAttachment}',
              leading: author == null ? null : MemberAvatar(author, radius: 12),
              trailing: timeLabel(last.sentAt),
            ),
    );
  }
}

/// Who is where, from the phones that share their location.
class _WhereTile extends StatelessWidget {
  const _WhereTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final locations = engine.memberLocations;
    final sharing = [
      for (final m in engine.members)
        if (locations[m.id] != null) (m, locations[m.id]!),
    ];
    return _Tile(
      section: FamioSection.location,
      title: tr.homeWhoWhere,
      child: Column(
        children: [
          if (sharing.isEmpty)
            _Line(tr.homeNobodySharesTheirLocation, dim: true),
          for (final (m, l) in sharing.take(5))
            _Line(
              '${m.displayName}: '
              '${sharingLabel(l, engine.place(l.placeId))}',
              leading: MemberAvatar(m, radius: 12),
              dim: l.state != SharingState.active,
            ),
        ],
      ),
    );
  }
}

class _KidsTile extends StatelessWidget {
  const _KidsTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final kids = engine.children;
    final c = FamioColors.of(context);
    return _Tile(
      section: FamioSection.kids,
      title: tr.sectionKids,
      child: Column(
        children: [
          for (final p in engine.activePregnancies)
            _Line(
              tr.homeNameWeekWeek(
                p.name.isEmpty ? tr.commonPregnancy : p.name,
                weekLabel(p),
              ),
              leading: Icon(
                AppIcons.heart,
                size: 18,
                color: c.strong(FamioSection.kids),
              ),
              trailing: tr.commonDaysLeft(daysToGo(p)),
            ),
          if (kids.isEmpty && engine.activePregnancies.isEmpty)
            _Line(tr.homeAddChildKeepTrack, dim: true),
          for (final k in kids)
            () {
              final next = nextDue(k, engine.childEntries(k.id));
              // Babies: what the daily log says right now.
              final logs = k.ageInMonths(DateTime.now()) < 24
                  ? engine.childLogs(k.id)
                  : const <ChildLog>[];
              final sleeping = logs
                  .where((l) => l.kind == LogKind.sleep && l.running)
                  .firstOrNull;
              final fed = lastFeeding(logs);
              final now = DateTime.now();
              final school = now.weekday <= 5
                  ? engine.timetable(k.id)?.endOf(now.weekday)
                  : null;
              final status = sleeping != null
                  ? tr.homeAsleepSinceTime(timeLabel(sleeping.start))
                  : school != null
                  ? tr.homeSchoolUntilUntil(school)
                  : fed != null &&
                        DateTime.now().difference(fed.start).inHours < 12
                  ? tr.homeFedSince(sinceLabel(fed.end ?? fed.start))
                  : null;
              return _Line(
                status == null
                    ? '${k.name} · ${ageLabel(k)}'
                    : '${k.name} · $status',
                leading: Icon(
                  AppIcons.baby,
                  size: 18,
                  color: c.strong(FamioSection.kids),
                ),
                trailing: next == null
                    ? null
                    : next.appointment != null
                    ? tr.homeWhatDate(
                        next.isCheckup ? next.id : tr.commonVaccination,
                        DateFormat.Md(
                          appLanguage,
                        ).format(next.appointment!.date),
                      )
                    : next.open
                    ? tr.homeWhatDue(
                        next.isCheckup ? next.id : tr.commonVaccination,
                      )
                    : '${next.id} ab ${DateFormat.Md(appLanguage).format(next.from)}',
              );
            }(),
        ],
      ),
    );
  }
}

class _WishesTile extends StatelessWidget {
  const _WishesTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final open = engine.wishes.where((w) => !w.received).toList();
    final mine = open.where((w) => w.ownerId == engine.memberId).length;
    final others = open.length - mine;
    return _Tile(
      section: FamioSection.home,
      title: tr.settingsWishes,
      icon: AppIcons.gift,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const WishesScreen())),
      child: Column(
        children: [
          _Line(
            open.isEmpty
                ? tr.homeWhatDoYouWish
                : [
                    if (mine > 0) tr.homeYouCountWishes(mine),
                    if (others > 0) tr.homeFamilyCountWishes(others),
                  ].join(' · '),
            dim: open.isEmpty,
          ),
        ],
      ),
    );
  }
}

class _NotesTile extends StatelessWidget {
  const _NotesTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final notes = engine.notes;
    final pinned = notes.where((n) => n.pinned).toList();
    return _Tile(
      section: FamioSection.home,
      title: tr.commonPinboard,
      icon: AppIcons.note,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const NotesScreen())),
      child: Column(
        children: [
          if (pinned.isEmpty)
            _Line(
              notes.isEmpty
                  ? tr.homeNotesEveryoneWiFi
                  : tr.homeCountNotes(notes.length),
              dim: true,
            ),
          for (final n in pinned.take(3))
            _Line(
              n.text.isEmpty
                  ? n.title
                  : '${n.title}: ${n.text.split('\n').first}',
            ),
        ],
      ),
    );
  }
}

class _DocumentsTile extends StatelessWidget {
  const _DocumentsTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final docs = engine.documents;
    final soon = DateTime.now().add(const Duration(days: 90));
    final expiring =
        docs
            .where((d) => d.expiresAt != null && d.expiresAt!.isBefore(soon))
            .toList()
          ..sort((a, b) => a.expiresAt!.compareTo(b.expiresAt!));
    final c = FamioColors.of(context);
    return _Tile(
      section: FamioSection.documents,
      title: tr.sectionDocuments,
      badge: expiring.isEmpty ? null : tr.homeCountExpiring(expiring.length),
      child: Column(
        children: [
          if (expiring.isEmpty)
            _Line(
              docs.isEmpty
                  ? tr.homeNoDocumentsYet
                  : tr.homeCountDocumentsStoredSafely(docs.length),
              dim: true,
            ),
          for (final d in expiring.take(3))
            _Line(
              d.title,
              leading: Icon(
                AppIcons.warningCircle,
                size: 18,
                color: c.strong(FamioSection.documents),
              ),
              trailing:
                  'bis ${DateFormat.yMd(appLanguage).format(d.expiresAt!)}',
            ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _BirthdaysTile extends StatelessWidget {
  const _BirthdaysTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateUtils.dateOnly(now);
    final c = FamioColors.of(context);
    return _Tile(
      section: FamioSection.calendar,
      title: tr.commonBirthdays,
      child: Column(
        children: [
          for (final (b, day) in upcomingBirthdays(engine, now).take(4))
            _Line(
              b.headline(day),
              leading: Icon(
                AppIcons.cake,
                size: 18,
                color: c.strong(FamioSection.calendar),
              ),
              trailing: day == today
                  ? tr.homeToday
                  : day.difference(today).inDays == 1
                  ? tr.commonTomorrowLower
                  : DateFormat.MEd(appLanguage).format(day),
            ),
        ],
      ),
    );
  }
}

class _MealsTile extends StatelessWidget {
  const _MealsTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final c = FamioColors.of(context);
    final meals = engine.plannedMeals(
      today,
      today.add(const Duration(days: 2)),
    );
    return _Tile(
      section: FamioSection.meals,
      title: tr.sectionMeals,
      child: Column(
        children: [
          for (final m in meals.take(4))
            _Line(
              engine.recipe(m.recipeId)?.title ?? m.title,
              leading: Icon(
                AppIcons.cookingPot,
                size: 18,
                color: c.strong(FamioSection.meals),
              ),
              trailing:
                  '${m.date == today ? tr.commonTodayLower : tr.commonTomorrowLower} · ${m.slot.label}',
            ),
        ],
      ),
    );
  }
}

class _BudgetTile extends StatelessWidget {
  const _BudgetTile({required this.engine});

  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final m = BudgetMonth(engine.budgetEntries, now);
    final limits = engine.budgetSettings.limits;
    final over = [
      for (final e in limits.entries)
        if ((m.byCategory[e.key] ?? 0) > e.value) e.key,
    ];
    return _Tile(
      section: FamioSection.budget,
      title: tr.sectionBudget,
      badge: over.isEmpty ? null : tr.homeCountOverLimit(over.length),
      child: Column(
        children: [
          _Line(
            tr.homeSpendingMonth(DateFormat.MMMM(appLanguage).format(now)),
            trailing: formatEuro(m.expenses),
          ),
          _Line(tr.homeBalance, trailing: formatEuro(m.balance)),
          for (final cat in over.take(2))
            _Line(tr.homeCategoryOverLimit(categoryLabel(cat)), dim: true),
        ],
      ),
    );
  }
}
