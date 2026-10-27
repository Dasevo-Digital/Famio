part of '../chores_screens.dart';

/// Personal absences and the member who stands in for ordinary tasks and
/// chores. Adults manage them; everyone can see them.
class _AbsencesScreen extends StatelessWidget {
  const _AbsencesScreen();

  static String _range(DateTime from, DateTime to) {
    final format = DateFormat.yMMMd(appLanguage);
    return '${format.format(from)} – ${format.format(to)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = FamioColors.of(context).strong(FamioSection.chores);
    return DataBuilder(
      collections: const {Collections.absences, 'members'},
      builder: (context, engine) {
        final today = DateUtils.dateOnly(DateTime.now());
        final absences = [
          for (final absence in engine.absences)
            if (!absence.to.isBefore(today)) absence,
        ];
        return SectionPage(
          section: FamioSection.chores,
          title: tr.absenceTitle,
          subtitle: tr.absenceSubtitle,
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              SoftCard(child: Text(tr.absenceHint)),
              const SizedBox(height: 12),
              if (absences.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(tr.absenceNone),
                ),
              for (final absence in absences)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SoftCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: MemberAvatar(
                        engine.member(absence.memberId) ?? engine.me!,
                      ),
                      title: Text(
                        absence.title.isNotEmpty
                            ? absence.title
                            : engine.member(absence.memberId)?.displayName ??
                                  tr.absenceUnknownMember,
                      ),
                      subtitle: Text(
                        [
                          _range(absence.from, absence.to),
                          if (absence.substituteId != null)
                            tr.absenceSubstituteName(
                              engine
                                      .member(absence.substituteId!)
                                      ?.displayName ??
                                  tr.absenceUnknownMember,
                            ),
                        ].join(' · '),
                      ),
                      trailing: engine.iAmAdult
                          ? IconButton(
                              icon: const Icon(AppIcons.trash),
                              tooltip: tr.commonDelete,
                              onPressed: () => engine.deleteAbsence(absence.id),
                            )
                          : null,
                      onTap: engine.iAmAdult
                          ? () => _edit(context, engine, absence)
                          : null,
                    ),
                  ),
                ),
              if (engine.iAmAdult)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ColorButton(
                    label: tr.absenceAdd,
                    icon: AppIcons.plus,
                    color: color,
                    onPressed: () => _edit(context, engine, null),
                  ),
                )
              else
                Text(tr.absenceOnlyAdults),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _edit(
    BuildContext context,
    SyncEngine engine,
    MemberAbsence? existing,
  ) async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      initialDateRange: existing == null
          ? null
          : DateTimeRange(start: existing.from, end: existing.to),
      helpText: tr.absenceDates,
    );
    if (range == null || !context.mounted) return;
    final people = engine.members.where((member) => !member.isService).toList();
    if (people.isEmpty) return;
    var memberId = existing?.memberId ?? people.first.id;
    var substituteId = existing?.substituteId;
    final title = TextEditingController(text: existing?.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final substitutes = people.where((m) => m.id != memberId).toList();
          if (!substitutes.any((m) => m.id == substituteId)) {
            substituteId = null;
          }
          // One absence per person and day: the substitute must be clear.
          final planned = MemberAbsence(
            id: existing?.id ?? '',
            memberId: memberId,
            from: DateUtils.dateOnly(range.start),
            to: DateUtils.dateOnly(range.end),
          );
          final overlap = engine.absences.any(planned.overlaps);
          return AlertDialog(
            title: Text(tr.absenceTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_range(range.start, range.end)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: memberId,
                  decoration: InputDecoration(labelText: tr.absencePerson),
                  items: [
                    for (final member in people)
                      DropdownMenuItem(
                        value: member.id,
                        child: Text(member.displayName),
                      ),
                  ],
                  onChanged: (value) => setState(() => memberId = value!),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: substituteId ?? '',
                  decoration: InputDecoration(labelText: tr.absenceSubstitute),
                  items: [
                    DropdownMenuItem(value: '', child: Text(tr.commonNone)),
                    for (final member in substitutes)
                      DropdownMenuItem(
                        value: member.id,
                        child: Text(member.displayName),
                      ),
                  ],
                  onChanged: (value) => setState(
                    () => substituteId = value == null || value.isEmpty
                        ? null
                        : value,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: title,
                  decoration: InputDecoration(labelText: tr.absenceReason),
                ),
                if (overlap) ...[
                  const SizedBox(height: 12),
                  Text(
                    tr.absenceOverlap,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr.commonCancel),
              ),
              FilledButton(
                onPressed: overlap ? null : () => Navigator.pop(context, true),
                child: Text(tr.commonSave),
              ),
            ],
          );
        },
      ),
    );
    if (ok == true) {
      engine.saveAbsence(
        MemberAbsence(
          id: existing?.id ?? newId(),
          memberId: memberId,
          from: DateUtils.dateOnly(range.start),
          to: DateUtils.dateOnly(range.end),
          substituteId: substituteId,
          title: title.text.trim(),
        ),
      );
    }
    title.dispose();
  }
}
