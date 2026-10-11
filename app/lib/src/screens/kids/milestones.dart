part of '../kids_screens.dart';

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
    final all = milestonesFor(child.sex);
    final age =
        child.ageInMonths(DateTime.now()) +
        DateTime.now()
                .difference(child.ageDate(child.ageInMonths(DateTime.now())))
                .inDays /
            30.4;
    // Keep reached memories, current steps and the near future. Unfinished
    // steps whose time has passed are folded away instead of making a
    // toddler's family confirm baby skills again.
    final visible = all.where(
      (m) => byMilestone.containsKey(m.id) || milestoneIsRelevant(m, age),
    );
    final past = [
      for (final m in all)
        if (!byMilestone.containsKey(m.id) && milestoneIsPast(m, age)) m,
    ];
    final phases = developmentPhasesFor(child.sex);
    final current = [
      for (final p in phases)
        if (phaseIsCurrent(p, age)) p,
    ];
    final next = [
      for (final p in phases)
        if (phaseIsUpcoming(p, age, 12)) p,
    ].take(2);
    // Puberty differs between girls and boys: without the sex in the
    // child's profile both windows are shown together.
    final askSex =
        child.sex == null &&
        ([...current, ...next].any((p) => p.bySex) ||
            visible.any(
              (m) => m.only != null || m.female != null || m.male != null,
            ));
    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        _Disclaimer(tr.milestonesGuideValuesMostChildren),
        if (askSex) ...[
          const SizedBox(height: 8),
          _Disclaimer(tr.milestonesSexHint),
        ],
        if (current.isNotEmpty || next.isNotEmpty) ...[
          ListHeading(tr.milestonesPhases),
          for (final p in [...current, ...next])
            _PhaseCard(phase: p, age: age, color: color),
        ],
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
        if (past.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 8),
              childrenPadding: EdgeInsets.zero,
              title: Text(tr.milestonesReachedEarlierAdd),
              subtitle: Text(
                past.length == 1
                    ? tr.milestones1MilestoneWhosePeriod
                    : tr.milestonesCountMilestonesWhosePeriod(past.length),
              ),
              children: [
                for (final m in past)
                  _MilestoneRow(
                    milestone: m,
                    entry: null,
                    age: age,
                    child: child,
                    color: color,
                  ),
              ],
            ),
          ),
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
                    from: milestone.fromMonth,
                    to: milestone.toMonth,
                    age: age,
                    color: color,
                    reachedAt: done
                        ? child.ageInMonths(entry!.date).toDouble()
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    done
                        ? tr.milestonesReachedDateAge(
                            _date.format(entry!.date),
                            ageLabel(child, entry!.date),
                          )
                        : tr.milestonesUsuallyBetweenHint(
                            _months(milestone.fromMonth),
                            _months(milestone.toMonth),
                            milestone.hint.isEmpty
                                ? ''
                                : ' · ${milestone.hint}',
                          ),
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
    required this.from,
    required this.to,
    required this.age,
    required this.color,
    this.reachedAt,
  });

  /// The typical window in months of age.
  final double from;
  final double to;
  final double age;
  final Color color;
  final double? reachedAt;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final start = math.max(0.0, from - (to - from) * 0.5);
    final end = to + (to - from) * 0.5;
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
                left: pos(from) * w,
                width: (pos(to) - pos(from)) * w,
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

/// A development phase going on now or coming soon: what it is about, not
/// something to tick off.
class _PhaseCard extends StatelessWidget {
  const _PhaseCard({
    required this.phase,
    required this.age,
    required this.color,
  });

  final DevelopmentPhase phase;
  final double age;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final from = _phaseAge(phase.fromMonth);
    final to = _months(phase.toMonth);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(phase.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            _WindowBar(
              from: phase.fromMonth,
              to: phase.toMonth,
              age: age,
              color: color,
            ),
            const SizedBox(height: 4),
            Text(
              phaseIsCurrent(phase, age)
                  ? tr.milestonesPhaseNow(from, to)
                  : tr.milestonesPhaseNext(from, to),
              style: theme.textTheme.bodySmall?.copyWith(
                color: FamioColors.of(context).inkSoft,
              ),
            ),
            const SizedBox(height: 8),
            Text(phase.info, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// The start of a phase: "Geburt" instead of "0 Mon.".
String _phaseAge(double months) =>
    months == 0 ? tr.milestonesBirth : _months(months);

/// A coming phase from the timeline, explained.
Future<void> _showPhaseInfo(BuildContext context, String title, String info) =>
    showModalBottomSheet<void>(
      context: context,
      // Above the floating navigation bar.
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(info, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );

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
