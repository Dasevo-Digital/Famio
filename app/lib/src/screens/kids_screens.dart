import 'dart:math' as math;

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/kids_logic.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../design/theme.dart';
import '../widgets/data_builder.dart';
import '../widgets/files.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import 'kids_emergency_screens.dart';
import 'kids_log_screens.dart';
import 'pregnancy_screens.dart';
import 'timetable_view.dart';

const _kidsCollections = {
  Collections.children,
  Collections.childEntries,
  Collections.childLogs,
  Collections.contacts,
  Collections.pregnancies,
  Collections.timetables,
  'members',
};

/// The child's color (or the section color).
Color childColorOf(BuildContext context, Child child) =>
    _childColor(context, child);

final _date = DateFormat('d. MMM y', 'de');

Color _childColor(BuildContext context, Child child) => child.color == null
    ? FamioColors.of(context).strong(FamioSection.kids)
    : Color(child.color!);

String _months(double m) {
  if (m < 36) {
    return '${m % 1 == 0 ? m.toInt() : m.toStringAsFixed(1).replaceAll('.', ',')} Mon.';
  }
  final years = m / 12;
  return '${years % 1 == 0 ? years.toInt() : years.toStringAsFixed(1).replaceAll('.', ',')} J.';
}

/// All children of the family.
class KidsScreen extends StatelessWidget {
  const KidsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.kids);
    return SectionPage(
      section: FamioSection.kids,
      title: 'Kinder',
      subtitle: 'Groß werden – Schritt für Schritt',
      actions: const [SyncStatusIcon()],
      floating: AddButton(
        color: color,
        tooltip: 'Kind oder Schwangerschaft hinzufügen',
        onPressed: () => _add(context),
      ),
      body: DataBuilder(
        collections: _kidsCollections,
        builder: (context, engine) {
          final kids = engine.children;
          final expecting = engine.activePregnancies;
          if (kids.isEmpty && expecting.isEmpty) {
            return EmptyHint(
              icon: AppIcons.baby,
              color: color,
              text:
                  'Halte fest, wie eure Kinder wachsen:\nerste Schritte, erste Wörter, U-Untersuchungen –\noder begleitet schon die Schwangerschaft.',
              action: ColorButton(
                label: 'Hinzufügen',
                color: color,
                onPressed: () => _add(context),
              ),
            );
          }
          final cards = [
            for (final p in expecting) PregnancyCard(pregnancy: p),
            for (final k in kids) _ChildCard(child: k, engine: engine),
          ];
          return ListView.separated(
            padding: EdgeInsets.only(
              top: 8,
              bottom: listBottomPadding(context),
            ),
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(height: 14),
            itemBuilder: (context, i) => cards[i],
          );
        },
      ),
    );
  }
}

Future<void> _add(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(AppIcons.baby),
              title: const Text('Kind hinzufügen'),
              onTap: () => Navigator.pop(context, 'child'),
            ),
            ListTile(
              leading: const Icon(AppIcons.heart),
              title: const Text('Schwangerschaft'),
              subtitle: const Text('SSW, Termine, Checklisten, Wehen-Timer'),
              onTap: () => Navigator.pop(context, 'pregnancy'),
            ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  if (choice == 'child') {
    await showChildEditor(context);
  } else if (choice == 'pregnancy') {
    await showPregnancyEditor(context);
  }
}

class _ChildPhoto extends StatelessWidget {
  const _ChildPhoto({required this.child, this.size = 72});

  final Child child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = _childColor(context, child);
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.36),
      ),
      child: child.photo == null
          ? Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(size * 0.32),
              ),
              child: Icon(AppIcons.baby, color: color, size: size * 0.5),
            )
          : CachedImage(child.photo!, thumb: 480, radius: size * 0.32),
    );
  }
}

class _ChildCard extends StatelessWidget {
  const _ChildCard({required this.child, required this.engine});

  final Child child;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final entries = engine.childEntries(child.id);
    final next = nextDue(child, entries);
    final reached = entries
        .where((e) => e.kind == ChildEntryKind.milestone)
        .length;
    return SoftCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ChildScreen(childId: child.id)),
      ),
      child: Row(
        children: [
          _ChildPhoto(child: child),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(child.name, style: theme.textTheme.headlineSmall),
                Text(
                  ageLabel(child),
                  style: theme.textTheme.bodyMedium?.copyWith(color: c.inkSoft),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Chip(
                      icon: AppIcons.star,
                      text: '$reached Meilensteine',
                      color: _childColor(context, child),
                    ),
                    if (next != null)
                      GestureDetector(
                        onTap: () => showDueActions(context, child, next),
                        child: _Chip(
                          icon: next.isCheckup
                              ? AppIcons.stethoscope
                              : AppIcons.syringe,
                          text: next.open
                              ? '${next.isCheckup ? next.id : 'Impfung'} jetzt'
                              : '${next.id} ab ${DateFormat('d.M.', 'de').format(next.from)}',
                          color: next.open
                              ? theme.colorScheme.error
                              : c.inkSoft,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Icon(AppIcons.caretRight, color: c.inkSoft),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: color),
        ),
      ],
    ),
  );
}

enum _Tab {
  timeline('Zeitstrahl'),
  log('Protokoll'),
  milestones('Meilensteine'),
  checkups('Vorsorge'),
  vaccinations('Impfungen'),
  growth('Wachstum'),
  timetable('Stundenplan');

  const _Tab(this.label);

  final String label;
}

/// One child's development: timeline, milestones, check-ups, vaccinations,
/// growth.
class ChildScreen extends StatefulWidget {
  const ChildScreen({super.key, required this.childId});

  final String childId;

  @override
  State<ChildScreen> createState() => _ChildScreenState();
}

class _ChildScreenState extends State<ChildScreen> {
  _Tab? _tab;

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: _kidsCollections,
      builder: (context, engine) {
        final child = engine.child(widget.childId);
        if (child == null) {
          return const SectionPage(
            section: FamioSection.kids,
            title: 'Kind',
            body: Center(child: Text('Dieses Kind gibt es nicht mehr.')),
          );
        }
        final entries = engine.childEntries(child.id);
        final color = _childColor(context, child);
        // Babies and toddlers open on their daily log.
        final tab =
            _tab ??
            (child.ageInMonths(DateTime.now()) < 24 ? _Tab.log : _Tab.timeline);
        return SectionPage(
          section: FamioSection.kids,
          title: child.name,
          subtitle:
              '${ageLabel(child)} · geboren am ${_date.format(child.birthDate)}',
          actions: [
            BubbleButton(
              icon: AppIcons.siren,
              tooltip: 'Notfall',
              color: Theme.of(context).colorScheme.error,
              onPressed: () => showEmergency(context, child),
            ),
            const SizedBox(width: 8),
            BubbleButton(
              icon: AppIcons.pencilSimple,
              tooltip: 'Bearbeiten',
              onPressed: () => showChildEditor(context, existing: child),
            ),
          ],
          floating: AddButton(
            color: color,
            tooltip: 'Erinnerung festhalten',
            icon: AppIcons.sparkle,
            onPressed: () => showEntryEditor(
              context,
              child: child,
              kind: ChildEntryKind.memory,
            ),
          ),
          body: Column(
            children: [
              PillTabs<_Tab>(
                // The timetable from school age on (or once filled in).
                values: [
                  for (final t in _Tab.values)
                    if (switch (t) {
                      // Timetable from school age, daily log for small
                      // children – or whenever one has entries.
                      _Tab.timetable =>
                        child.ageInMonths(DateTime.now()) >= 60 ||
                            engine.timetable(child.id) != null,
                      _Tab.log =>
                        child.ageInMonths(DateTime.now()) < 48 ||
                            engine.childLogs(child.id).isNotEmpty,
                      _ => true,
                    })
                      t,
                ],
                selected: tab,
                label: (t) => t.label,
                color: color,
                onChanged: (t) => setState(() => _tab = t),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: switch (tab) {
                  _Tab.timeline => _Timeline(
                    child: child,
                    entries: entries,
                    color: color,
                  ),
                  _Tab.log => ChildLogView(
                    child: child,
                    logs: engine.childLogs(child.id),
                  ),
                  _Tab.milestones => _MilestonesView(
                    child: child,
                    entries: entries,
                    color: color,
                  ),
                  _Tab.checkups => _DueList(
                    child: child,
                    items: checkupPlan(child, entries),
                    kind: ChildEntryKind.checkup,
                    hint:
                        'Zeiträume laut gelbem Kinderuntersuchungsheft. Den Termin '
                        'am besten früh beim Kinderarzt vereinbaren.',
                  ),
                  _Tab.vaccinations => _DueList(
                    child: child,
                    items: vaccinationPlan(child, entries),
                    kind: ChildEntryKind.vaccination,
                    hint:
                        'Orientierung nach dem STIKO-Impfkalender (Stand 2025). '
                        'Maßgeblich sind Kinderarzt und Impfpass.',
                  ),
                  _Tab.growth => _GrowthView(
                    child: child,
                    entries: entries,
                    color: color,
                  ),
                  _Tab.timetable => TimetableView(child: child),
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// --- timeline ----------------------------------------------------------------

class _TimelineItem {
  const _TimelineItem({
    required this.date,
    required this.title,
    required this.icon,
    required this.color,
    this.subtitle,
    this.photos = const [],
    this.entry,
    this.due,
    this.future = false,
  });

  final DateTime date;
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color color;
  final List<FileRef> photos;
  final ChildEntry? entry;

  /// An open or upcoming check-up/vaccination, tappable to mark as done.
  final DueItem? due;
  final bool future;
}

(IconData, Color) _entryLook(ChildEntryKind kind, Color childColor) =>
    switch (kind) {
      ChildEntryKind.milestone => (AppIcons.star, const Color(0xFFE89B1A)),
      ChildEntryKind.memory => (AppIcons.heart, childColor),
      ChildEntryKind.measurement => (AppIcons.ruler, const Color(0xFF2A9D6E)),
      ChildEntryKind.checkup => (AppIcons.stethoscope, const Color(0xFF3587D6)),
      ChildEntryKind.vaccination => (AppIcons.syringe, const Color(0xFF7B5BE0)),
    };

String _entryTitle(ChildEntry e) => switch (e.kind) {
  ChildEntryKind.milestone => milestoneById(e.refId)?.title ?? e.title,
  ChildEntryKind.checkup =>
    '${checkupById(e.refId)?.title ?? e.refId} erledigt',
  ChildEntryKind.vaccination => () {
    final v = vaccinationById(e.refId);
    return v == null ? e.title : 'Impfung: ${v.title} (${v.dose})';
  }(),
  ChildEntryKind.measurement => [
    if (e.heightCm != null) '${_num(e.heightCm!)} cm',
    if (e.weightKg != null) '${_num(e.weightKg!)} kg',
    if (e.headCm != null) 'Kopf ${_num(e.headCm!)} cm',
  ].join(' · '),
  ChildEntryKind.memory => e.title,
};

String _num(double v) =>
    (v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1)).replaceAll(
      '.',
      ',',
    );

class _Timeline extends StatelessWidget {
  const _Timeline({
    required this.child,
    required this.entries,
    required this.color,
  });

  final Child child;
  final List<ChildEntry> entries;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final horizon = today.add(const Duration(days: 183));
    final ageMonths = child.ageInMonths(now);
    final reached = {
      for (final e in entries)
        if (e.kind == ChildEntryKind.milestone) e.refId,
    };

    final upcoming = <_TimelineItem>[
      for (final d in [
        ...checkupPlan(child, entries, now),
        ...vaccinationPlan(child, entries, now),
      ])
        if (!d.optional &&
            (d.open ||
                (d.state == DueState.upcoming && d.from.isBefore(horizon))))
          _TimelineItem(
            date: d.from,
            title: d.isCheckup ? d.title : 'Impfung: ${d.title}',
            subtitle: d.open ? 'Jetzt fällig · ${d.subtitle}' : d.subtitle,
            icon: d.isCheckup ? AppIcons.stethoscope : AppIcons.syringe,
            color: d.open
                ? Theme.of(context).colorScheme.error
                : FamioColors.of(context).inkSoft,
            due: d,
            future: true,
          ),
      for (final m in milestones)
        if (!reached.contains(m.id) &&
            m.fromMonth > ageMonths - 1 &&
            m.fromMonth <= ageMonths + 6)
          _TimelineItem(
            date: child.ageDate(m.fromMonth),
            title: m.title,
            subtitle:
                'Typisch zwischen ${_months(m.fromMonth)} und ${_months(m.toMonth)}',
            icon: AppIcons.star,
            color: FamioColors.of(context).inkSoft,
            future: true,
          ),
    ]..sort((a, b) => a.date.compareTo(b.date));

    final past = [
      for (final e in entries)
        () {
          final (icon, c) = _entryLook(e.kind, color);
          return _TimelineItem(
            date: e.date,
            title: _entryTitle(e),
            subtitle: e.note.isEmpty ? null : e.note,
            icon: icon,
            color: c,
            photos: e.photos,
            entry: e,
          );
        }(),
    ]..sort((a, b) => b.date.compareTo(a.date));

    return ListView(
      padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
      children: [
        if (upcoming.isNotEmpty) ...[
          const ListHeading('Demnächst'),
          for (final item in upcoming.take(8))
            _TimelineRow(item: item, child: child),
        ],
        _TodayMarker(color: color, label: 'Heute · ${ageLabel(child)}'),
        if (past.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(44, 8, 16, 8),
            child: Text(
              'Noch keine Einträge. Tippe auf ✨, um eine Erinnerung festzuhalten, '
              'oder hake unter „Meilensteine“ ab, was schon klappt.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (final (i, item) in past.indexed) ...[
          if (i == 0 || _ageGroup(past[i - 1].date) != _ageGroup(item.date))
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 14, 0, 4),
              child: Text(
                _ageGroup(item.date),
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: color),
              ),
            ),
          _TimelineRow(item: item, child: child),
        ],
        _TimelineRow(
          item: _TimelineItem(
            date: child.birthDate,
            title: 'Geburt 🎉',
            subtitle: 'Willkommen, ${child.name}!',
            icon: AppIcons.babyCarriage,
            color: color,
          ),
          child: child,
          last: true,
        ),
      ],
    );
  }

  String _ageGroup(DateTime date) {
    final months = child.ageInMonths(date);
    if (months < 1) return 'Die ersten Wochen';
    if (months < 12) return 'Mit $months ${months == 1 ? 'Monat' : 'Monaten'}';
    final years = months ~/ 12;
    return years == 1 ? 'Im 2. Lebensjahr' : 'Mit $years Jahren';
  }
}

class _TodayMarker extends StatelessWidget {
  const _TodayMarker({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: const Icon(AppIcons.sun, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: color),
          ),
        ),
      ],
    ),
  );
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.item,
    required this.child,
    this.last = false,
  });

  final _TimelineItem item;
  final Child child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final entry = item.entry;
    final due = item.due;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: item.future
                        ? c.surface
                        : item.color.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                    border: item.future
                        ? Border.all(color: c.line, width: 2)
                        : null,
                  ),
                  child: Icon(item.icon, size: 17, color: item.color),
                ),
                if (!last) Expanded(child: Container(width: 3, color: c.line)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: GestureDetector(
                onTap: entry != null
                    ? () => showEntryEditor(
                        context,
                        child: child,
                        kind: entry.kind,
                        existing: entry,
                      )
                    : due != null
                    ? () => showDueActions(context, child, due)
                    : null,
                child: Opacity(
                  opacity: item.future ? 0.75 : 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, style: theme.textTheme.titleMedium),
                      Text(
                        [
                          entry?.dateUnknown == true
                              ? 'Datum unbekannt'
                              : _date.format(item.date),
                          ?item.subtitle,
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                      if (item.photos.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 110,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: item.photos.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, i) => GestureDetector(
                              onTap: () => openFileRef(context, item.photos[i]),
                              child: SizedBox(
                                width: 110,
                                child: CachedImage(item.photos[i], thumb: 480),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- milestones --------------------------------------------------------------

class _MilestonesView extends StatelessWidget {
  const _MilestonesView({
    required this.child,
    required this.entries,
    required this.color,
  });

  final Child child;
  final List<ChildEntry> entries;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final byMilestone = {
      for (final e in entries)
        if (e.kind == ChildEntryKind.milestone) e.refId: e,
    };
    final age =
        child.ageInMonths(DateTime.now()) +
        DateTime.now()
                .difference(child.ageDate(child.ageInMonths(DateTime.now())))
                .inDays /
            30.4;
    // Only what is relevant for this age: reached ones, the current window
    // and what comes next; far-future items stay hidden.
    final visible = milestones.where(
      (m) => byMilestone.containsKey(m.id) || m.fromMonth <= age + 12,
    );
    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        _Disclaimer(
          'Richtwerte: Die meisten Kinder erreichen diese Schritte im angegebenen '
          'Zeitraum – manche früher, manche später. Jedes Kind hat sein eigenes '
          'Tempo. Bei Fragen hilft die Kinderärztin oder der Kinderarzt.',
        ),
        for (final area in MilestoneArea.values)
          if (visible.any((m) => m.area == area)) ...[
            ListHeading(area.label),
            for (final m in visible.where((m) => m.area == area))
              _MilestoneRow(
                milestone: m,
                entry: byMilestone[m.id],
                age: age,
                child: child,
                color: color,
              ),
          ],
      ],
    );
  }
}

class _MilestoneRow extends StatelessWidget {
  const _MilestoneRow({
    required this.milestone,
    required this.entry,
    required this.age,
    required this.child,
    required this.color,
  });

  final Milestone milestone;
  final ChildEntry? entry;
  final double age;
  final Child child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final done = entry != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(8, 10, 16, 12),
        onTap: () => done
            ? showEntryEditor(
                context,
                child: child,
                kind: ChildEntryKind.milestone,
                existing: entry,
              )
            : showEntryEditor(
                context,
                child: child,
                kind: ChildEntryKind.milestone,
                refId: milestone.id,
              ),
        child: Row(
          children: [
            RoundCheck(
              label: milestone.title,
              value: done,
              color: const Color(0xFFE89B1A),
              onChanged: (_) => done
                  ? showEntryEditor(
                      context,
                      child: child,
                      kind: ChildEntryKind.milestone,
                      existing: entry,
                    )
                  : showEntryEditor(
                      context,
                      child: child,
                      kind: ChildEntryKind.milestone,
                      refId: milestone.id,
                    ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(milestone.title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  _WindowBar(
                    milestone: milestone,
                    age: age,
                    color: color,
                    reachedAt: done
                        ? child.ageInMonths(entry!.date).toDouble()
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    done
                        ? 'Geschafft am ${_date.format(entry!.date)} (mit ${ageLabel(child, entry!.date)})'
                        : 'Meist zwischen ${_months(milestone.fromMonth)} und ${_months(milestone.toMonth)}'
                              '${milestone.hint.isEmpty ? '' : ' · ${milestone.hint}'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: done ? c.ink : c.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the typical window on an age axis and where the child is now.
class _WindowBar extends StatelessWidget {
  const _WindowBar({
    required this.milestone,
    required this.age,
    required this.color,
    this.reachedAt,
  });

  final Milestone milestone;
  final double age;
  final Color color;
  final double? reachedAt;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final start = math.max(
      0.0,
      milestone.fromMonth - (milestone.toMonth - milestone.fromMonth) * 0.5,
    );
    final end =
        milestone.toMonth + (milestone.toMonth - milestone.fromMonth) * 0.5;
    double pos(double m) => ((m - start) / (end - start)).clamp(0.0, 1.0);
    final marker = reachedAt ?? age;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        return SizedBox(
          height: 16,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 6,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Positioned(
                left: pos(milestone.fromMonth) * w,
                width: (pos(milestone.toMonth) - pos(milestone.fromMonth)) * w,
                top: 4,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Positioned(
                left: pos(marker) * w - 8,
                top: 0,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: reachedAt != null ? const Color(0xFFE89B1A) : color,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.surface, width: 3),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surfaceSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.info, color: c.inkSoft, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

// --- check-ups & vaccinations ------------------------------------------------

class _DueList extends StatelessWidget {
  const _DueList({
    required this.child,
    required this.items,
    required this.kind,
    required this.hint,
  });

  final Child child;
  final List<DueItem> items;
  final ChildEntryKind kind;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    (String, Color) look(DueState s) => switch (s) {
      DueState.done => ('erledigt', const Color(0xFF2A9D6E)),
      DueState.due => ('jetzt fällig', theme.colorScheme.error),
      DueState.late => ('noch nachholbar', const Color(0xFFE8703A)),
      DueState.missed => (
        kind == ChildEntryKind.vaccination
            ? 'nicht eingetragen'
            : 'Zeitraum vorbei',
        c.inkSoft,
      ),
      DueState.upcoming => ('demnächst', c.inkSoft),
    };
    // Hide far-future items for small children to keep the list short.
    final horizon = DateTime.now().add(const Duration(days: 730));
    final shown = items
        .where((d) => d.state != DueState.upcoming || d.from.isBefore(horizon))
        .toList();

    final past = items.where((d) => d.state == DueState.missed).toList();
    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        _Disclaimer(hint),
        if (past.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(AppIcons.checkSquareOffset, size: 18),
              label: Text(
                '${past.length} frühere ${kind == ChildEntryKind.checkup ? 'Vorsorgen' : 'Impfungen'} nachtragen',
              ),
              onPressed: () => _markPast(context, child, kind, past),
            ),
          ),
        ],
        const SizedBox(height: 12),
        for (final d in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SoftCard(
              padding: const EdgeInsets.fromLTRB(8, 10, 16, 10),
              onTap: () => d.entry != null
                  ? showEntryEditor(
                      context,
                      child: child,
                      kind: kind,
                      existing: d.entry,
                    )
                  : showEntryEditor(
                      context,
                      child: child,
                      kind: kind,
                      refId: d.id,
                    ),
              child: Row(
                children: [
                  RoundCheck(
                    label: d.title,
                    value: d.state == DueState.done,
                    color: const Color(0xFF2A9D6E),
                    onChanged: (_) => showDueActions(context, child, d),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kind == ChildEntryKind.vaccination
                              ? '${d.title} – ${vaccinationById(d.id)?.dose ?? ''}'
                              : d.title,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          d.state == DueState.done
                              ? d.entry!.dateUnknown
                                    ? 'Erledigt · Datum unbekannt'
                                    : 'Am ${_date.format(d.entry!.date)}'
                              : kind == ChildEntryKind.checkup
                              ? '${d.subtitle} · ${DateFormat('d.M.y', 'de').format(d.from)} – ${DateFormat('d.M.y', 'de').format(d.to)}'
                              : 'Empfohlen ab ${DateFormat('d.M.y', 'de').format(d.from)}'
                                    '${vaccinationById(d.id)?.note.isNotEmpty ?? false ? ' · ${vaccinationById(d.id)!.note}' : ''}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: look(d.state).$2.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      look(d.state).$1,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: look(d.state).$2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// What to do with a check-up or vaccination: mark as done today, on
/// another day or without a known date; done ones open the editor.
Future<void> showDueActions(
  BuildContext context,
  Child child,
  DueItem item,
) async {
  final kind = item.isCheckup
      ? ChildEntryKind.checkup
      : ChildEntryKind.vaccination;
  if (item.entry != null) {
    return showEntryEditor(
      context,
      child: child,
      kind: kind,
      existing: item.entry,
    );
  }
  final engine = AppScope.engineOf(context);
  final title = item.isCheckup ? item.title : 'Impfung: ${item.title}';
  final choice = await showModalBottomSheet<String>(
    context: context,
    // Above the floating navigation bar.
    useRootNavigator: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            Text(item.subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(AppIcons.check),
              label: const Text('Heute erledigt'),
              onPressed: () => Navigator.pop(context, 'today'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(AppIcons.calendarBlank),
              label: const Text('Anderes Datum, Messwerte, Notiz …'),
              onPressed: () => Navigator.pop(context, 'editor'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context, 'unknown'),
              child: const Text('Erledigt, Datum unbekannt'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'editor') {
    return showEntryEditor(context, child: child, kind: kind, refId: item.id);
  }
  final today = DateUtils.dateOnly(DateTime.now());
  engine.saveChildEntry(
    ChildEntry(
      id: newId(),
      childId: child.id,
      kind: kind,
      date: choice == 'today' ? today : item.from,
      refId: item.id,
      dateUnknown: choice == 'unknown',
    ),
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${item.isCheckup ? item.id : item.title} erledigt'),
      ),
    );
  }
}

/// Records several past check-ups or vaccinations at once (date unknown).
Future<void> _markPast(
  BuildContext context,
  Child child,
  ChildEntryKind kind,
  List<DueItem> items,
) async {
  final selected = {for (final d in items) d.id};
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        scrollable: true,
        title: Text(
          kind == ChildEntryKind.checkup
              ? 'Frühere Vorsorgen nachtragen'
              : 'Frühere Impfungen nachtragen',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Als erledigt eintragen, ohne genaues Datum. Das Datum lässt '
              'sich später einzeln ergänzen (z. B. aus dem gelben Heft oder '
              'dem Impfpass).',
            ),
            const SizedBox(height: 8),
            for (final d in items)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: selected.contains(d.id),
                title: Text(
                  kind == ChildEntryKind.checkup
                      ? d.title
                      : '${d.title} – ${vaccinationById(d.id)?.dose ?? ''}',
                ),
                onChanged: (v) => setState(
                  () => v == true ? selected.add(d.id) : selected.remove(d.id),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('${selected.length} eintragen'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  final engine = AppScope.engineOf(context);
  for (final d in items.where((d) => selected.contains(d.id))) {
    engine.saveChildEntry(
      ChildEntry(
        id: newId(),
        childId: child.id,
        kind: kind,
        date: d.from,
        refId: d.id,
        dateUnknown: true,
      ),
    );
  }
}

// --- growth ------------------------------------------------------------------

class _GrowthView extends StatelessWidget {
  const _GrowthView({
    required this.child,
    required this.entries,
    required this.color,
  });

  final Child child;
  final List<ChildEntry> entries;
  final Color color;

  /// Age in months with fractions (for the WHO curves).
  double _age(DateTime d) => d.difference(child.birthDate).inDays / 30.4375;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Measurements, also those taken at check-ups.
    final measured = entries
        .where(
          (e) => e.heightCm != null || e.weightKg != null || e.headCm != null,
        )
        .toList();
    List<(double, double)> series(double? Function(ChildEntry) value) => [
      for (final e in measured)
        if (value(e) != null && !e.dateUnknown) (_age(e.date), value(e)!),
    ];
    final charts = [
      (
        'Größe (cm)',
        GrowthMeasure.length,
        series((e) => e.heightCm),
        const Color(0xFF3587D6),
      ),
      (
        'Gewicht (kg)',
        GrowthMeasure.weight,
        series((e) => e.weightKg),
        const Color(0xFFE8703A),
      ),
      (
        'Kopfumfang (cm)',
        GrowthMeasure.head,
        series((e) => e.headCm),
        const Color(0xFF7B5BE0),
      ),
    ];
    final sex = child.sex;
    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: ColorButton(
            label: 'Messung eintragen',
            icon: AppIcons.ruler,
            color: const Color(0xFF2A9D6E),
            onPressed: () => showEntryEditor(
              context,
              child: child,
              kind: ChildEntryKind.measurement,
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (final (title, measure, points, lineColor) in charts)
          if (points.length >= 2 ||
              (points.isNotEmpty && sex != null && points.last.$1 <= 24)) ...[
            _ChartCard(
              title: title,
              points: points,
              color: lineColor,
              reference: sex == null
                  ? null
                  : (x) => growthReference(sex, measure, x),
              percentile: sex == null || points.isEmpty
                  ? null
                  : () {
                      final (x, y) = points.reduce(
                        (a, b) => a.$1 > b.$1 ? a : b,
                      );
                      final lms = growthReference(sex, measure, x);
                      return lms == null ? null : growthPercentile(lms, y);
                    }(),
            ),
            const SizedBox(height: 12),
          ],
        if (charts.every((c) => c.$3.length < 2))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Ab zwei Messungen erscheint hier eine Kurve. Die Werte aus dem '
              'U-Heft eignen sich gut dafür – sie lassen sich auch direkt bei '
              'der Vorsorge eintragen.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        Text(
          sex == null
              ? 'Mit dem Geschlecht im Profil zeigt Famio die WHO-Kurven '
                    '(0–24 Monate) zum Vergleich.'
              : 'Grau: WHO-Wachstumsstandards, 3., 50. und 97. Perzentile '
                    '(0–24 Monate). Wichtig ist der Verlauf, nicht ein '
                    'einzelner Wert – Fragen gern beim Kinderarzt.',
          style: theme.textTheme.bodySmall,
        ),
        const ListHeading('Alle Messungen'),
        for (final e in measured.reversed)
          ListTile(
            leading: Icon(
              e.kind == ChildEntryKind.checkup
                  ? AppIcons.stethoscope
                  : AppIcons.ruler,
            ),
            title: Text(
              [
                if (e.heightCm != null) '${_num(e.heightCm!)} cm',
                if (e.weightKg != null) '${_num(e.weightKg!)} kg',
                if (e.headCm != null) 'Kopf ${_num(e.headCm!)} cm',
              ].join(' · '),
            ),
            subtitle: Text(
              [
                if (e.kind == ChildEntryKind.checkup)
                  checkupById(e.refId)?.id ?? 'Vorsorge',
                e.dateUnknown ? 'Datum unbekannt' : _date.format(e.date),
                if (!e.dateUnknown) 'mit ${ageLabel(child, e.date)}',
              ].join(' · '),
            ),
            onTap: () => showEntryEditor(
              context,
              child: child,
              kind: e.kind,
              existing: e,
            ),
          ),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.points,
    required this.color,
    this.reference,
    this.percentile,
  });

  final String title;
  final List<(double, double)> points;
  final Color color;

  /// WHO reference at an age in months (null outside 0–24).
  final Lms? Function(double months)? reference;

  /// Percentile of the latest value.
  final double? percentile;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final xs = points.map((p) => p.$1);
    final minX = math.max(0.0, xs.reduce(math.min) - 1).floorToDouble();
    final maxX = math.max(xs.reduce(math.max) + 1, minX + 3).ceilToDouble();
    final bands = <(double, double, double, double)>[];
    if (reference != null) {
      for (var x = minX; x <= maxX + 0.01; x += 0.5) {
        final lms = reference!(x);
        if (lms != null) {
          bands.add((
            x,
            lms.valueAt(-1.881),
            lms.valueAt(0),
            lms.valueAt(1.881),
          ));
        }
      }
    }
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (percentile != null)
                Text(
                  'Perzentile ${percentile!.round().clamp(1, 99)}',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: color),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 170,
            child: CustomPaint(
              size: Size.infinite,
              painter: _LinePainter(
                points: points,
                color: color,
                grid: c.line,
                label: c.inkSoft,
                bands: bands,
                minX: bands.isEmpty ? null : minX,
                maxX: bands.isEmpty ? null : maxX,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.points,
    required this.color,
    required this.grid,
    required this.label,
    this.bands = const [],
    this.minX,
    this.maxX,
  });

  final List<(double, double)> points;
  final Color color;
  final Color grid;
  final Color label;

  /// Reference curves: (age, P3, P50, P97).
  final List<(double, double, double, double)> bands;
  final double? minX;
  final double? maxX;

  @override
  void paint(Canvas canvas, Size size) {
    final sorted = [...points]..sort((a, b) => a.$1.compareTo(b.$1));
    final x0 = minX ?? sorted.first.$1;
    final x1 = maxX ?? math.max(sorted.last.$1, sorted.first.$1 + 1);
    final ys = [
      ...sorted.map((p) => p.$2),
      for (final b in bands) ...[b.$2, b.$4],
    ];
    final minY = ys.reduce(math.min) * 0.95, maxY = ys.reduce(math.max) * 1.05;
    const left = 36.0, bottom = 20.0;
    Offset at((double, double) p) => Offset(
      left + (p.$1 - x0) / (x1 - x0) * (size.width - left - 8),
      (size.height - bottom) -
          (p.$2 - minY) / (maxY - minY) * (size.height - bottom - 8),
    );
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1.5;
    final text = TextStyle(
      color: label,
      fontFamily: bodyFont,
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
    );
    for (var i = 0; i <= 3; i++) {
      final y = (size.height - bottom) * i / 3 + 4;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), gridPaint);
      final value = maxY - (maxY - minY) * i / 3;
      (TextPainter(
        text: TextSpan(text: _num(value), style: text),
        textDirection: TextDirection.ltr,
      )..layout()).paint(canvas, Offset(0, y - 7));
    }
    for (final x in [x0, x1]) {
      (TextPainter(
        text: TextSpan(text: _months(x), style: text),
        textDirection: TextDirection.ltr,
      )..layout()).paint(
        canvas,
        Offset(at((x, minY)).dx - 12, size.height - 14),
      );
    }
    if (bands.length >= 2) {
      final area = Path()
        ..moveTo(
          at((bands.first.$1, bands.first.$2)).dx,
          at((bands.first.$1, bands.first.$2)).dy,
        );
      for (final b in bands.skip(1)) {
        area.lineTo(at((b.$1, b.$2)).dx, at((b.$1, b.$2)).dy);
      }
      for (final b in bands.reversed) {
        area.lineTo(at((b.$1, b.$4)).dx, at((b.$1, b.$4)).dy);
      }
      area.close();
      canvas.drawPath(area, Paint()..color = label.withValues(alpha: 0.10));
      final median = Path()
        ..moveTo(
          at((bands.first.$1, bands.first.$3)).dx,
          at((bands.first.$1, bands.first.$3)).dy,
        );
      for (final b in bands.skip(1)) {
        median.lineTo(at((b.$1, b.$3)).dx, at((b.$1, b.$3)).dy);
      }
      canvas.drawPath(
        median,
        Paint()
          ..color = label.withValues(alpha: 0.45)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }
    final path = Path()..moveTo(at(sorted.first).dx, at(sorted.first).dy);
    for (final p in sorted.skip(1)) {
      path.lineTo(at(p).dx, at(p).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 3.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    for (final p in sorted) {
      canvas.drawCircle(at(p), 5, Paint()..color = color);
      canvas.drawCircle(at(p), 2.5, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.points != points || old.color != color || old.bands != bands;
}

// --- editors -----------------------------------------------------------------

Future<void> showChildEditor(BuildContext context, {Child? existing}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _ChildEditor(existing: existing)),
    );

class _ChildEditor extends StatefulWidget {
  const _ChildEditor({this.existing});

  final Child? existing;

  @override
  State<_ChildEditor> createState() => _ChildEditorState();
}

class _ChildEditorState extends State<_ChildEditor> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late DateTime? _birth = widget.existing?.birthDate;
  late int _color = widget.existing?.color ?? 0xFFDB4A7E;
  late FileRef? _photo = widget.existing?.photo;
  late ChildSex? _sex = widget.existing?.sex;
  // New children start private to their creator; other parents are added
  // right below.
  late final _guardians = {
    ...?widget.existing?.guardianIds,
    if (widget.existing == null) ?AppScope.read(context).me?.id,
  };
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final picked = await pickFile(context, imagesOnly: true);
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final ref = await uploadPicked(context, picked);
      setState(() => _photo = ref);
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    if (_name.text.trim().isEmpty || _birth == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte Name und Geburtstag angeben')),
      );
      return;
    }
    AppScope.engineOf(context).saveChild(
      Child(
        id: widget.existing?.id ?? newId(),
        name: _name.text.trim(),
        birthDate: _birth!,
        color: _color,
        photo: _photo,
        guardianIds: _guardians.toList(),
        sex: _sex,
        emergency: widget.existing?.emergency ?? const EmergencyInfo(),
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${widget.existing!.name} entfernen?'),
        content: const Text(
          'Alle Einträge, Meilensteine und Messungen dieses Kindes werden gelöscht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    AppScope.engineOf(context).deleteChild(widget.existing!.id);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final preview = Child(
      id: '',
      name: _name.text,
      birthDate: _birth ?? DateTime.now(),
      color: _color,
      photo: _photo,
    );
    return SectionPage(
      section: FamioSection.kids,
      title: widget.existing == null ? 'Kind hinzufügen' : 'Profil bearbeiten',
      actions: [
        ColorButton(
          label: 'Speichern',
          color: Color(_color),
          onPressed: _busy ? null : _save,
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          Center(
            child: GestureDetector(
              onTap: _busy ? null : _pickPhoto,
              child: Stack(
                children: [
                  _ChildPhoto(child: preview, size: 120),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: BubbleButton(
                      icon: AppIcons.camera,
                      tooltip: 'Foto wählen',
                      onPressed: _busy ? null : _pickPhoto,
                      size: 38,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const ListHeading('Geburtstag'),
          Align(
            alignment: Alignment.centerLeft,
            child: InputChip(
              avatar: const Icon(AppIcons.cake, size: 18),
              label: Text(
                _birth == null
                    ? 'Datum wählen'
                    : DateFormat('d. MMMM y', 'de').format(_birth!),
              ),
              onPressed: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _birth ?? now,
                  firstDate: DateTime(now.year - 25),
                  lastDate: now,
                );
                if (picked != null) setState(() => _birth = picked);
              },
            ),
          ),
          const ListHeading('Geschlecht'),
          Wrap(
            spacing: 8,
            children: [
              for (final (value, label) in [
                (ChildSex.female, 'Mädchen'),
                (ChildSex.male, 'Junge'),
                (null, 'Keine Angabe'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _sex == value,
                  onSelected: (_) => setState(() => _sex = value),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Nur für die WHO-Wachstumskurven.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const ListHeading('Farbe'),
          Wrap(
            spacing: 10,
            children: [
              for (final c in famioPalette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Color(c),
                    child: c == _color
                        ? const Icon(
                            AppIcons.check,
                            color: Colors.white,
                            size: 18,
                          )
                        : null,
                  ),
                ),
            ],
          ),
          const ListHeading('Sorgeberechtigte'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in engine.members)
                FilterChip(
                  avatar: MemberAvatar(m, radius: 10),
                  label: Text(m.displayName),
                  selected: _guardians.contains(m.id),
                  onSelected: (on) => setState(
                    () => on ? _guardians.add(m.id) : _guardians.remove(m.id),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Nur sie sehen Entwicklung, Vorsorge, Impfungen und Fotos und '
              'werden erinnert. Niemand ausgewählt: die ganze Familie.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (widget.existing != null) ...[
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.trash, size: 18),
                label: const Text('Kind entfernen'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: _delete,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Records (or edits) a milestone, check-up, vaccination, memory or
/// measurement for [child].
Future<void> showEntryEditor(
  BuildContext context, {
  required Child child,
  required ChildEntryKind kind,
  ChildEntry? existing,
  String? refId,
}) => showModalBottomSheet<void>(
  context: context,
  // Above the floating navigation bar.
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _EntryEditor(
    child: child,
    kind: kind,
    existing: existing,
    refId: refId ?? existing?.refId,
  ),
);

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({
    required this.child,
    required this.kind,
    this.existing,
    this.refId,
  });

  final Child child;
  final ChildEntryKind kind;
  final ChildEntry? existing;
  final String? refId;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _note = TextEditingController(text: widget.existing?.note);
  late final _height = TextEditingController(
    text: widget.existing?.heightCm == null
        ? ''
        : _num(widget.existing!.heightCm!),
  );
  late final _weight = TextEditingController(
    text: widget.existing?.weightKg == null
        ? ''
        : _num(widget.existing!.weightKg!),
  );
  late final _head = TextEditingController(
    text: widget.existing?.headCm == null ? '' : _num(widget.existing!.headCm!),
  );
  late DateTime _date =
      widget.existing?.date ?? DateUtils.dateOnly(DateTime.now());
  late final _photos = [...?widget.existing?.photos];
  late var _dateUnknown = widget.existing?.dateUnknown ?? false;
  var _uploading = false;

  bool get _datedItem =>
      widget.kind == ChildEntryKind.checkup ||
      widget.kind == ChildEntryKind.vaccination;

  /// Check-ups can carry the measured values.
  bool get _withMeasurements =>
      widget.kind == ChildEntryKind.measurement ||
      widget.kind == ChildEntryKind.checkup;

  @override
  void dispose() {
    for (final c in [_title, _note, _height, _weight, _head]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _heading => switch (widget.kind) {
    ChildEntryKind.milestone =>
      milestoneById(widget.refId)?.title ?? 'Meilenstein',
    ChildEntryKind.checkup => checkupById(widget.refId)?.title ?? 'Vorsorge',
    ChildEntryKind.vaccination => () {
      final v = vaccinationById(widget.refId);
      return v == null ? 'Impfung' : '${v.title} – ${v.dose}';
    }(),
    ChildEntryKind.measurement => 'Messung',
    ChildEntryKind.memory =>
      widget.existing == null ? 'Erinnerung festhalten' : 'Erinnerung',
  };

  double? _parse(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<void> _addPhoto() async {
    final picked = await pickFile(context, imagesOnly: true);
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final ref = await uploadPicked(context, picked);
      setState(() => _photos.add(ref));
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _save() {
    if (widget.kind == ChildEntryKind.memory && _title.text.trim().isEmpty) {
      return;
    }
    if (widget.kind == ChildEntryKind.measurement &&
        _parse(_height) == null &&
        _parse(_weight) == null &&
        _parse(_head) == null) {
      return;
    }
    AppScope.engineOf(context).saveChildEntry(
      ChildEntry(
        id: widget.existing?.id ?? newId(),
        childId: widget.child.id,
        kind: widget.kind,
        date: _date,
        refId: widget.refId,
        title: _title.text.trim(),
        note: _note.text.trim(),
        photos: _photos,
        heightCm: _parse(_height),
        weightKg: _parse(_weight),
        headCm: _parse(_head),
        dateUnknown: _datedItem && _dateUnknown,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _entryLook(
      widget.kind,
      _childColor(context, widget.child),
    ).$2;
    // Check-ups and vaccinations: a photo of the booklet or vaccination card.
    final allowsPhotos = widget.kind != ChildEntryKind.measurement;
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
                IconBlob(_entryLook(widget.kind, color).$1, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_heading, style: theme.textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (widget.kind == ChildEntryKind.memory) ...[
              TextField(
                controller: _title,
                autofocus: widget.existing == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Was ist passiert?',
                  hintText: 'z. B. Erstes Wort: „Mama“',
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_withMeasurements) ...[
              if (widget.kind == ChildEntryKind.checkup)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Messwerte der Untersuchung (optional)',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _height,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Größe (cm)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _weight,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Gewicht (kg)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _head,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: 'Kopf (cm)'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (_datedItem)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Datum unbekannt'),
                value: _dateUnknown,
                onChanged: (v) => setState(() => _dateUnknown = v),
              ),
            if (!(_datedItem && _dateUnknown))
              Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  avatar: const Icon(AppIcons.calendarBlank, size: 18),
                  label: Text(
                    'Am ${DateFormat('d. MMMM y', 'de').format(_date)}',
                  ),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: widget.child.birthDate,
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Notiz (optional)'),
            ),
            if (allowsPhotos) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 84,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in _photos)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Stack(
                          children: [
                            SizedBox.square(
                              dimension: 84,
                              child: CachedImage(p, thumb: 160),
                            ),
                            Positioned(
                              right: 2,
                              top: 2,
                              child: BubbleButton(
                                icon: AppIcons.x,
                                tooltip: 'Foto entfernen',
                                size: 26,
                                onPressed: () =>
                                    setState(() => _photos.remove(p)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    _uploading
                        ? const SizedBox.square(
                            dimension: 84,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : SizedBox.square(
                            dimension: 84,
                            child: OutlinedButton(
                              onPressed: _addPhoto,
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.zero,
                              ),
                              child: const Icon(AppIcons.imageSquare, size: 30),
                            ),
                          ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                if (widget.existing != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: Text(
                      widget.kind == ChildEntryKind.memory ||
                              widget.kind == ChildEntryKind.measurement
                          ? 'Löschen'
                          : 'Zurücksetzen',
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () {
                      AppScope.engineOf(
                        context,
                      ).deleteChildEntry(widget.existing!.id);
                      Navigator.pop(context);
                    },
                  ),
                const Spacer(),
                ColorButton(
                  label:
                      widget.existing == null &&
                          widget.kind != ChildEntryKind.memory &&
                          widget.kind != ChildEntryKind.measurement
                      ? 'Geschafft!'
                      : 'Speichern',
                  color: color,
                  onPressed: _uploading ? null : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
