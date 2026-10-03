part of '../kids_screens.dart';

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
        if (d.appointment case final a?)
          _TimelineItem(
            date: a.appointmentAt,
            title: d.isCheckup ? d.title : 'Impfung: ${d.title}',
            subtitle: a.date.isBefore(today)
                ? 'Termin war – erledigt?'
                : [
                    if (a.time != null) 'um ${a.time} Uhr',
                    'Termin',
                  ].join(' · '),
            icon: d.isCheckup ? AppIcons.stethoscope : AppIcons.syringe,
            color: const Color(0xFF3587D6),
            due: d,
            future: true,
          )
        else if (!d.optional &&
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
        if (!reached.contains(m.id) && milestoneIsUpcoming(m, ageMonths))
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
        if (!e.planned)
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
          // Booked appointments always, other suggestions only the next few.
          for (final item in [
            ...upcoming.where((i) => i.due?.appointment != null),
            ...upcoming.where((i) => i.due?.appointment == null).take(8),
          ]..sort((a, b) => a.date.compareTo(b.date)))
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
