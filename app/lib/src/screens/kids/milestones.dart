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
    final age =
        child.ageInMonths(DateTime.now()) +
        DateTime.now()
                .difference(child.ageDate(child.ageInMonths(DateTime.now())))
                .inDays /
            30.4;
    // Keep reached memories, current steps and the near future. Unfinished
    // baby steps vanish after a six-month look-back window instead of making
    // a toddler's family confirm foundational skills again.
    final visible = milestones.where(
      (m) => byMilestone.containsKey(m.id) || milestoneIsRelevant(m, age),
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
