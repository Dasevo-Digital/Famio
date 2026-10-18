part of '../chores_screens.dart';

/// Family holidays (see Vacation): adults add them, everyone sees them.
class _VacationsScreen extends StatelessWidget {
  const _VacationsScreen();

  static String _range(DateTime from, DateTime to) {
    final f = DateFormat.yMMMd(appLanguage);
    return '${f.format(from)} – ${f.format(to)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = FamioColors.of(context).strong(FamioSection.chores);
    return DataBuilder(
      collections: const {Collections.vacations, 'members'},
      builder: (context, engine) {
        final today = DateUtils.dateOnly(DateTime.now());
        final upcoming = [
          for (final v in engine.vacations)
            if (!v.to.isBefore(today)) v,
        ];
        return SectionPage(
          section: FamioSection.chores,
          title: tr.vacationTitle,
          subtitle: tr.vacationSubtitle,
          body: ListView(
            padding: EdgeInsets.only(
              top: 4,
              bottom: listBottomPadding(context),
            ),
            children: [
              SoftCard(child: Text(tr.vacationHint)),
              const SizedBox(height: 12),
              if (upcoming.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(tr.vacationNone),
                ),
              for (final v in upcoming)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SoftCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(AppIcons.palm, color: color),
                      title: Text(
                        v.title.isEmpty ? _range(v.from, v.to) : v.title,
                      ),
                      subtitle: Text(
                        [
                          if (v.title.isNotEmpty) _range(v.from, v.to),
                          if (v.allowance) tr.vacationAllowancePaused,
                        ].join(' · '),
                      ),
                      trailing: engine.iAmAdult
                          ? IconButton(
                              icon: const Icon(AppIcons.trash),
                              tooltip: tr.commonDelete,
                              onPressed: () => engine.deleteVacation(v.id),
                            )
                          : null,
                      onTap: engine.iAmAdult
                          ? () => _edit(context, engine, v)
                          : null,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (engine.iAmAdult)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ColorButton(
                    label: tr.vacationAdd,
                    icon: AppIcons.plus,
                    color: color,
                    onPressed: () => _edit(context, engine, null),
                  ),
                )
              else
                Text(tr.vacationOnlyAdults),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _edit(
    BuildContext context,
    SyncEngine engine,
    Vacation? existing,
  ) async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      initialDateRange: existing == null
          ? null
          : DateTimeRange(start: existing.from, end: existing.to),
      helpText: tr.vacationDates,
    );
    if (range == null || !context.mounted) return;
    final title = TextEditingController(text: existing?.title);
    var allowance = existing?.allowance ?? false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr.vacationTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_range(range.start, range.end)),
              const SizedBox(height: 12),
              TextField(
                controller: title,
                decoration: InputDecoration(labelText: tr.vacationName),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr.vacationPauseAllowance),
                subtitle: Text(tr.vacationPauseAllowanceHint),
                value: allowance,
                onChanged: (v) => setState(() => allowance = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.commonSave),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      engine.saveVacation(
        Vacation(
          id: existing?.id ?? newId(),
          from: DateUtils.dateOnly(range.start),
          to: DateUtils.dateOnly(range.end),
          title: title.text.trim(),
          allowance: allowance,
        ),
      );
    }
    title.dispose();
  }
}

/// On a holiday: a note on top of today's chores.
class _HolidayBanner extends StatelessWidget {
  const _HolidayBanner({required this.holiday});

  final Vacation holiday;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SoftCard(
        color: c.tint(FamioSection.chores),
        child: Row(
          children: [
            Icon(AppIcons.palm, color: c.strong(FamioSection.chores)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr.vacationBanner(
                  DateFormat.MMMEd(appLanguage).format(holiday.to),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
