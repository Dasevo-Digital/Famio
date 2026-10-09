part of '../kids_screens.dart';

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
      DueState.done => (tr.commonDoneLower, const Color(0xFF2A9D6E)),
      DueState.due => (tr.dueDueNow, theme.colorScheme.error),
      DueState.late => (tr.dueCanStillDone, const Color(0xFFE8703A)),
      DueState.missed => (
        kind == ChildEntryKind.vaccination
            ? tr.dueNotRecorded
            : tr.duePeriodOver,
        c.inkSoft,
      ),
      DueState.upcoming => (tr.pregnancySoon, c.inkSoft),
      DueState.planned => (tr.commonEvent, const Color(0xFF3587D6)),
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
                tr.dueAddCountEarlierWhat(
                  past.length,
                  kind == ChildEntryKind.checkup
                      ? tr.dueCheckups
                      : tr.dueVaccinations,
                ),
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
                          d.appointment != null
                              ? _appointmentLabel(d.appointment!)
                              : d.state == DueState.done
                              ? d.entry!.dateUnknown
                                    ? tr.dueDoneDateUnknown
                                    : tr.kidsDate(_date.format(d.entry!.date))
                              : kind == ChildEntryKind.checkup
                              ? '${d.subtitle} · ${DateFormat.yMd(appLanguage).format(d.from)} – ${DateFormat.yMd(appLanguage).format(d.to)}'
                              : tr.dueRecommendedDateNote(
                                  DateFormat.yMd(appLanguage).format(d.from),
                                  vaccinationById(d.id)?.note.isNotEmpty ??
                                          false
                                      ? ' · ${vaccinationById(d.id)!.note}'
                                      : '',
                                ),
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

/// "Termin am 7. Oktober 2026 um 9:30 Uhr".
String _appointmentLabel(ChildEntry e) => tr.dueAppointmentDateTime(
  _date.format(e.date),
  e.time == null ? '' : tr.remindersTime(e.time),
);

/// What to do with a check-up or vaccination: mark as done today, on
/// another day or without a known date, or book an appointment; done ones
/// open the editor.
Future<void> showDueActions(
  BuildContext context,
  Child child,
  DueItem item,
) async {
  final kind = item.isCheckup
      ? ChildEntryKind.checkup
      : ChildEntryKind.vaccination;
  if (item.appointment != null) {
    return _showAppointmentActions(context, child, item, item.appointment!);
  }
  if (item.entry != null) {
    return showEntryEditor(
      context,
      child: child,
      kind: kind,
      existing: item.entry,
    );
  }
  final engine = AppScope.engineOf(context);
  final title = item.isCheckup ? item.title : tr.dueVaccination(item.title);
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
              label: Text(tr.dueDoneToday),
              onPressed: () => Navigator.pop(context, 'today'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(AppIcons.calendarBlank),
              label: Text(tr.dueOtherDateMeasurementsNote),
              onPressed: () => Navigator.pop(context, 'editor'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(AppIcons.clock),
              label: Text(tr.dueAddAppointment),
              onPressed: () => Navigator.pop(context, 'appointment'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context, 'unknown'),
              child: Text(tr.dueDoneDateUnknown2),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'editor' || choice == 'appointment') {
    return showEntryEditor(
      context,
      child: child,
      kind: kind,
      refId: item.id,
      planned: choice == 'appointment',
    );
  }
  final today = DateUtils.dateOnly(DateTime.now());
  engine.saveChildEntry(
    ChildEntry(
      id: newId(),
      childId: child.id,
      kind: kind,
      date: choice == 'today' || item.from.isAfter(today) ? today : item.from,
      refId: item.id,
      dateUnknown: choice == 'unknown',
    ),
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr.kidsWhatDone(item.isCheckup ? item.id : item.title)),
      ),
    );
  }
}

/// A booked appointment: mark it as done, move it or cancel it.
Future<void> _showAppointmentActions(
  BuildContext context,
  Child child,
  DueItem item,
  ChildEntry appointment,
) async {
  final engine = AppScope.engineOf(context);
  final today = DateUtils.dateOnly(DateTime.now());
  // Done on the appointment day, unless it still lies ahead.
  final doneOn = appointment.date.isAfter(today) ? today : appointment.date;
  final title = item.isCheckup ? item.title : tr.dueVaccination(item.title);
  final choice = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            Text(
              _appointmentLabel(appointment),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(AppIcons.check),
              label: Text(
                doneOn == today
                    ? tr.dueDoneToday
                    : tr.dueDoneDate(DateFormat.Md(appLanguage).format(doneOn)),
              ),
              onPressed: () => Navigator.pop(context, 'done'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(AppIcons.calendarBlank),
              label: Text(tr.dueChangeAppointment),
              onPressed: () => Navigator.pop(context, 'editor'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: Text(tr.dueCancelAppointment),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'editor':
      return showEntryEditor(
        context,
        child: child,
        kind: appointment.kind,
        existing: appointment,
      );
    case 'cancel':
      deleteWithUndo(
        context,
        message: tr.dueWhatCanceled(_appointmentLabel(appointment)),
        collections: const {Collections.childEntries},
        delete: () => engine.deleteChildEntry(appointment.id),
      );
    case 'done':
      engine.saveChildEntry(
        ChildEntry(
          id: appointment.id,
          childId: appointment.childId,
          kind: appointment.kind,
          date: doneOn,
          refId: appointment.refId,
          note: appointment.note,
          photos: appointment.photos,
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr.kidsWhatDone(item.isCheckup ? item.id : item.title)),
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
              ? tr.dueAddEarlierCheckups
              : tr.dueAddEarlierVaccinations,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr.dueRecordDoneWithoutExact),
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
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.dueAddCount(selected.length)),
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
