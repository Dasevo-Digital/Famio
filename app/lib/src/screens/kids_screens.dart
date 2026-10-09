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
import '../widgets/undo_delete.dart';
import '../l10n.dart';
import '../format.dart';

part 'kids/child_editor.dart';
part 'kids/child_screen.dart';
part 'kids/due_list.dart';
part 'kids/entry_editor.dart';
part 'kids/growth.dart';
part 'kids/milestones.dart';
part 'kids/timeline.dart';

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

DateFormat get _date => DateFormat.yMMMd(appLanguage);

Color _childColor(BuildContext context, Child child) => child.color == null
    ? FamioColors.of(context).strong(FamioSection.kids)
    : Color(child.color!);

String _months(double m) {
  if (m < 36) {
    return tr.kidsAgeMonthsShort(decimal(m, m % 1 == 0 ? 0 : 1));
  }
  final years = m / 12;
  return tr.kidsAgeYearsShort(decimal(years, years % 1 == 0 ? 0 : 1));
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
      title: tr.sectionKids,
      subtitle: tr.kidsGrowingUpStepStep,
      actions: const [SyncStatusIcon()],
      floating: AddButton(
        color: color,
        tooltip: tr.kidsAddChildPregnancy,
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
              text: tr.kidsKeepTrackHowKids,
              action: ColorButton(
                label: tr.commonAdd,
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
              title: Text(tr.kidsAddChild),
              onTap: () => Navigator.pop(context, 'child'),
            ),
            ListTile(
              leading: const Icon(AppIcons.heart),
              title: Text(tr.commonPregnancy),
              subtitle: Text(tr.kidsWeekAppointmentsChecklistsContraction),
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
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _Chip(
                      icon: AppIcons.star,
                      text: tr.kidsCountMilestones(reached),
                      color: _childColor(context, child),
                    ),
                    if (next != null)
                      GestureDetector(
                        onTap: () => showDueActions(context, child, next),
                        behavior: HitTestBehavior.opaque,
                        // The chip stays small; the finger may land around it.
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Center(
                            widthFactor: 1,
                            child: _Chip(
                              icon: next.isCheckup
                                  ? AppIcons.stethoscope
                                  : AppIcons.syringe,
                              text: next.open
                                  ? tr.kidsWhatNow(
                                      next.isCheckup
                                          ? next.id
                                          : tr.commonVaccination,
                                    )
                                  : '${next.id} ab ${DateFormat.Md(appLanguage).format(next.from)}',
                              color: next.open
                                  ? theme.colorScheme.error
                                  : c.inkSoft,
                            ),
                          ),
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
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final tint = Color.alphaBlend(color.withValues(alpha: 0.13), c.surface);
    final ink = c.readable(color, on: tint);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: ink),
          const SizedBox(width: 5),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: ink),
          ),
        ],
      ),
    );
  }
}
