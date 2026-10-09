import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';
import '../format.dart';

part 'chores/accounts.dart';
part 'chores/chore_editor.dart';
part 'chores/chores_tab.dart';
part 'chores/rewards.dart';
part 'chores/routine_editor.dart';
part 'chores/routines.dart';
part 'chores/today_tab.dart';

const _collections = {
  Collections.chores,
  Collections.routines,
  Collections.routineRuns,
  Collections.rewards,
  Collections.pointEntries,
  Collections.allowances,
  Collections.moneyEntries,
  'members',
};

enum _Tab {
  today,
  chores,
  routines,
  rewards,
  accounts;

  String get label => switch (this) {
    today => tr.commonToday,
    chores => tr.sectionChores,
    routines => tr.choresTabRoutines,
    rewards => tr.choresTabRewards,
    accounts => tr.settingsAccount,
  };
}

List<String> get _weekdayShort => weekdaysShort();

/// Chores with points, kids' routines, rewards and pocket money.
class ChoresScreen extends StatefulWidget {
  const ChoresScreen({super.key});

  @override
  State<ChoresScreen> createState() => _ChoresScreenState();
}

class _ChoresScreenState extends State<ChoresScreen> {
  var _tab = _Tab.today;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.chores);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.chores,
      title: tr.choresChoresPoints,
      subtitle: tr.choresHelpingOutPaysOff,
      actions: const [SyncStatusIcon()],
      floating: DataBuilder(
        collections: const {'members'},
        builder: (context, engine) {
          if (!engine.iAmAdult) return const SizedBox.shrink();
          return switch (_tab) {
            _Tab.chores || _Tab.today => AddButton(
              color: color,
              tooltip: tr.choresCreateChore,
              onPressed: () => showChoreEditor(context),
            ),
            _Tab.routines => AddButton(
              color: color,
              tooltip: tr.choresCreateRoutine,
              onPressed: () => showRoutineEditor(context),
            ),
            _Tab.rewards => AddButton(
              color: color,
              tooltip: tr.choresCreateReward,
              onPressed: () => showRewardEditor(context),
            ),
            _Tab.accounts => const SizedBox.shrink(),
          };
        },
      ),
      body: Column(
        children: [
          PillTabs<_Tab>(
            values: _Tab.values,
            selected: _tab,
            label: (t) => t.label,
            color: color,
            onChanged: (t) => setState(() => _tab = t),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: DataBuilder(
              collections: _collections,
              builder: (context, engine) => switch (_tab) {
                _Tab.today => _TodayTab(engine: engine),
                _Tab.chores => _ChoresTab(engine: engine),
                _Tab.routines => _RoutinesTab(engine: engine),
                _Tab.rewards => _RewardsTab(engine: engine),
                _Tab.accounts => _AccountsTab(engine: engine),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Members shown on "Heute": children see themselves, adults everyone
/// who collects points.
List<FamilyMember> _people(SyncEngine engine) {
  final me = engine.me;
  if (me != null && me.role == MemberRole.child) return [me];
  return engine.pointCollectors;
}

class _PointsChip extends StatelessWidget {
  const _PointsChip(this.points, {this.big = false});

  final int points;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: big ? 14 : 10,
        vertical: big ? 6 : 3,
      ),
      decoration: BoxDecoration(
        color: c.tint(FamioSection.chores),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '⭐ $points',
        style:
            (big
                    ? Theme.of(context).textTheme.titleMedium
                    : Theme.of(context).textTheme.labelLarge)
                ?.copyWith(color: c.strong(FamioSection.chores)),
      ),
    );
  }
}

// --- today -------------------------------------------------------------------
