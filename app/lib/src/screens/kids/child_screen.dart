part of '../kids_screens.dart';

enum _Tab {
  timeline,
  log,
  milestones,
  checkups,
  vaccinations,
  growth,
  timetable;

  String get label => switch (this) {
    timeline => tr.kidsTabTimeline,
    log => tr.kidsTabLog,
    milestones => tr.kidsTabMilestones,
    checkups => tr.kidsTabCheckups,
    vaccinations => tr.kidsTabVaccinations,
    growth => tr.kidsTabGrowth,
    timetable => tr.commonTimetable,
  };
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
          return SectionPage(
            section: FamioSection.kids,
            title: tr.commonChild,
            body: Center(child: Text(tr.kidsChildNoLongerExists)),
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
          subtitle: tr.kidsAgeBornBorn2(
            ageLabel(child),
            _date.format(child.birthDate),
          ),
          actions: [
            BubbleButton(
              icon: AppIcons.siren,
              tooltip: tr.kidsEmergencyTitle,
              color: Theme.of(context).colorScheme.error,
              onPressed: () => showEmergency(context, child),
            ),
            const SizedBox(width: 8),
            BubbleButton(
              icon: AppIcons.pencilSimple,
              tooltip: tr.commonEdit,
              onPressed: () => showChildEditor(context, existing: child),
            ),
          ],
          floating: AddButton(
            color: color,
            tooltip: tr.kidsCaptureMemory,
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
                    hint: tr.kidsPeriodsGermanChildHealth,
                  ),
                  _Tab.vaccinations => _DueList(
                    child: child,
                    items: vaccinationPlan(child, entries),
                    kind: ChildEntryKind.vaccination,
                    hint: tr.kidsBasedStikoVaccinationCalendar,
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
  ChildEntryKind.checkup => tr.kidsWhatDone(
    checkupById(e.refId)?.title ?? e.refId,
  ),
  ChildEntryKind.vaccination => () {
    final v = vaccinationById(e.refId);
    return v == null ? e.title : tr.kidsVaccinationTitleDose(v.title, v.dose);
  }(),
  ChildEntryKind.measurement => [
    if (e.heightCm != null) '${_num(e.heightCm!)} cm',
    if (e.weightKg != null) '${_num(e.weightKg!)} kg',
    if (e.headCm != null) tr.kidsHeadSizeCm(_num(e.headCm!)),
  ].join(' · '),
  ChildEntryKind.memory => e.title,
};

String _num(double v) => decimal(v, v % 1 == 0 ? 0 : 1);
