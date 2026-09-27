import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
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
import 'budget_screens.dart';
import 'location_screens.dart';
import '../weather/weather_tile.dart';

/// Family dashboard: what matters today, one colorful tile per area.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static String _greeting(DateTime now) => switch (now.hour) {
    < 5 => 'Gute Nacht',
    < 11 => 'Guten Morgen',
    < 17 => 'Hallo',
    < 22 => 'Guten Abend',
    _ => 'Gute Nacht',
  };

  @override
  Widget build(BuildContext context) {
    final me = AppScope.of(context).me!;
    final now = DateTime.now();
    return SectionPage(
      section: FamioSection.home,
      title: '${_greeting(now)}, ${me.displayName}!',
      subtitle: DateFormat('EEEE, d. MMMM', 'de').format(now),
      actions: [const SyncStatusIcon(), MemberAvatar(me, radius: 22)],
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
          'members',
        },
        builder: (context, engine) => LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1100
                ? 3
                : (constraints.maxWidth >= 640 ? 2 : 1);
            final tiles = [
              _TodayTile(engine: engine),
              WeatherTile(engine: engine),
              _TasksTile(engine: engine),
              _ShoppingTile(engine: engine),
              if (engine
                  .plannedMeals(
                    DateUtils.dateOnly(now),
                    DateUtils.dateOnly(now).add(const Duration(days: 2)),
                  )
                  .isNotEmpty)
                _MealsTile(engine: engine),
              _ChatTile(engine: engine),
              _WhereTile(engine: engine),
              _KidsTile(engine: engine),
              if (upcomingBirthdays(engine, now).isNotEmpty)
                _BirthdaysTile(engine: engine),
              _DocumentsTile(engine: engine),
              if (engine.budgetEntries.isNotEmpty) _BudgetTile(engine: engine),
            ];
            const gap = 16.0;
            final width =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            return SingleChildScrollView(
              padding: EdgeInsets.only(
                top: 8,
                bottom: listBottomPadding(context),
              ),
              child: Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final t in tiles) SizedBox(width: width, child: t),
                ],
              ),
            );
          },
        ),
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
  });

  final FamioSection section;
  final String title;
  final Widget child;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    return SoftCard(
      color: c.tint(section),
      onTap: () => FamioNav.of(context).go(section),
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
                      color: Colors.white,
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
      title: 'Heute',
      badge: todays.isEmpty ? null : '${todays.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (todays.isEmpty)
            const _Line('Heute steht nichts an. 🌤', dim: true),
          for (final o in todays.take(4))
            _Line(
              o.event.title,
              leading: _Dot(c.strong(FamioSection.calendar)),
              trailing: o.event.allDay ? 'ganztägig' : timeLabel(o.start),
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
      title: 'Aufgaben',
      badge: open.isEmpty ? null : '${open.length}',
      child: Column(
        children: [
          if (open.isEmpty)
            const _Line('Alles erledigt – super! 🎉', dim: true),
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
      title: 'Einkauf',
      badge: total == 0 ? null : '$total',
      child: Column(
        children: [
          if (lists.isEmpty)
            const _Line('Noch keine Einkaufsliste.', dim: true),
          for (final l in lists.take(4))
            _Line(
              l.name,
              leading: Icon(
                AppIcons.basket,
                size: 18,
                color: c.strong(FamioSection.shopping),
              ),
              trailing:
                  '${engine.shoppingItems(l.id).where((i) => !i.checked).length} offen',
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
      title: 'Chat',
      badge: unread == 0 ? null : '$unread neu',
      child: last == null
          ? const _Line('Noch keine Nachrichten.', dim: true)
          : _Line(
              last.text.isNotEmpty
                  ? last.text
                  : '📎 ${last.attachment?.name ?? 'Anhang'}',
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
      title: 'Wo ist wer?',
      child: Column(
        children: [
          if (sharing.isEmpty)
            const _Line('Noch teilt niemand seinen Standort.', dim: true),
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
      title: 'Kinder',
      child: Column(
        children: [
          for (final p in engine.activePregnancies)
            _Line(
              '${p.name.isEmpty ? 'Schwangerschaft' : p.name} · SSW ${weekLabel(p)}',
              leading: Icon(
                AppIcons.heart,
                size: 18,
                color: c.strong(FamioSection.kids),
              ),
              trailing: 'noch ${daysToGo(p)} Tage',
            ),
          if (kids.isEmpty && engine.activePregnancies.isEmpty)
            const _Line(
              'Lege ein Kind an, um die Entwicklung festzuhalten.',
              dim: true,
            ),
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
                  ? 'schläft seit ${timeLabel(sleeping.start)}'
                  : school != null
                  ? 'Schule bis $school'
                  : fed != null &&
                        DateTime.now().difference(fed.start).inHours < 12
                  ? 'gefüttert ${sinceLabel(fed.end ?? fed.start)}'
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
                    : next.open
                    ? '${next.isCheckup ? next.id : 'Impfung'} fällig'
                    : '${next.id} ab ${DateFormat('d.M.', 'de').format(next.from)}',
              );
            }(),
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
      title: 'Dokumente',
      badge: expiring.isEmpty ? null : '${expiring.length} läuft ab',
      child: Column(
        children: [
          if (expiring.isEmpty)
            _Line(
              docs.isEmpty
                  ? 'Noch keine Dokumente.'
                  : '${docs.length} Dokumente sicher abgelegt.',
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
                  'bis ${DateFormat('d.M.yy', 'de').format(d.expiresAt!)}',
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
      title: 'Geburtstage',
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
                  ? 'heute 🎉'
                  : day.difference(today).inDays == 1
                  ? 'morgen'
                  : DateFormat('E d.M.', 'de').format(day),
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
      title: 'Essen',
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
                  '${m.date == today ? 'heute' : 'morgen'} · ${m.slot.label}',
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
      title: 'Finanzen',
      badge: over.isEmpty ? null : '${over.length} über Limit',
      child: Column(
        children: [
          _Line(
            'Ausgaben ${DateFormat('MMMM', 'de').format(now)}',
            trailing: formatEuro(m.expenses),
          ),
          _Line('Saldo', trailing: formatEuro(m.balance)),
          for (final cat in over.take(2)) _Line('$cat über Limit', dim: true),
        ],
      ),
    );
  }
}
