part of '../location_screens.dart';

/// Configures a privacy-preserving recurring sharing window. The server
/// checks the parents' code and drops positions outside the selected times.
Future<LocationSchedule?> showLocationScheduleDialog(
  BuildContext context, {
  LocationSchedule? initial,
}) async {
  final code = TextEditingController();
  final days = {...?initial?.weekdays};
  var start = TimeOfDay(
    hour: (initial?.startMinute ?? 7 * 60) ~/ 60,
    minute: (initial?.startMinute ?? 7 * 60) % 60,
  );
  var end = TimeOfDay(
    hour: (initial?.endMinute ?? 18 * 60) ~/ 60,
    minute: (initial?.endMinute ?? 18 * 60) % 60,
  );
  var busy = false;
  String? error;
  LocationSchedule? result = initial;
  final labels = weekdaysShort();

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> save(LocationSchedule? schedule) async {
          setState(() {
            busy = true;
            error = null;
          });
          try {
            result = await AppScope.read(context).engine!.api
                .setLocationSchedule(code: code.text, schedule: schedule);
            if (context.mounted) Navigator.pop(context);
          } on ApiError catch (e) {
            setState(() => error = e.message);
          } finally {
            if (context.mounted) setState(() => busy = false);
          }
        }

        final startMinute = start.hour * 60 + start.minute;
        final endMinute = end.hour * 60 + end.minute;
        final valid = days.isNotEmpty && startMinute != endMinute;
        return AlertDialog(
          scrollable: true,
          title: Text(tr.locationLocationSchedule),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr.locationOutsideTimeWindowFamio),
                const SizedBox(height: 16),
                Text(tr.locationDays),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var day = 1; day <= 7; day++)
                      FilterChip(
                        label: Text(labels[day - 1]),
                        selected: days.contains(day),
                        onSelected: busy
                            ? null
                            : (selected) => setState(() {
                                if (selected) {
                                  days.add(day);
                                } else {
                                  days.remove(day);
                                }
                              }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(AppIcons.clock),
                      label: Text(tr.locationTime(start.format(context))),
                      onPressed: busy
                          ? null
                          : () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: start,
                              );
                              if (picked != null) {
                                setState(() => start = picked);
                              }
                            },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(AppIcons.clock),
                      label: Text(tr.locationUntilTime(end.format(context))),
                      onPressed: busy
                          ? null
                          : () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: end,
                              );
                              if (picked != null) {
                                setState(() => end = picked);
                              }
                            },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                PasswordReveal(
                  builder: (_, obscure, toggle) => TextField(
                    controller: code,
                    autofocus: true,
                    obscureText: obscure,
                    contextMenuBuilder: PasswordReveal.contextMenu,
                    decoration: InputDecoration(
                      labelText: tr.adminParentsCode,
                      prefixIcon: const Icon(AppIcons.lockKey),
                      suffixIcon: toggle,
                    ),
                  ),
                ),
                if (!valid)
                  Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(tr.locationChooseLeastOneDay),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (initial != null)
              TextButton(
                onPressed: busy ? null : () => save(null),
                child: Text(tr.locationRemoveSchedule),
              ),
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: Text(tr.commonCancel),
            ),
            FilledButton(
              onPressed: busy || !valid
                  ? null
                  : () => save(
                      LocationSchedule(
                        weekdays: days.toList()..sort(),
                        startMinute: startMinute,
                        endMinute: endMinute,
                      ),
                    ),
              child: Text(tr.commonSave),
            ),
          ],
        );
      },
    ),
  );
  code.dispose();
  return result;
}
