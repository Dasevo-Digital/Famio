import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../design/app_icons.dart';
import '../l10n.dart';
import '../data/family_data.dart';
import 'data_builder.dart';

class AssignmentSettingsEditor extends StatelessWidget {
  const AssignmentSettingsEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.canRemind = true,
  });
  final AssignmentSettings value;
  final ValueChanged<AssignmentSettings> onChanged;
  final bool canRemind;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tr.assignmentRequire),
        subtitle: Text(tr.assignmentRequireHint),
        value: value.required,
        onChanged: (v) => onChanged(
          AssignmentSettings(required: v, remindMinutes: value.remindMinutes),
        ),
      ),
      if (value.required) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr.assignmentRemind),
          subtitle: canRemind ? null : Text(tr.assignmentReminderNeedsDue),
          value: value.remindMinutes != null,
          onChanged: !canRemind
              ? null
              : (v) => onChanged(
                  AssignmentSettings(
                    required: true,
                    remindMinutes: v ? 1440 : null,
                  ),
                ),
        ),
        if (value.remindMinutes != null)
          DropdownButtonFormField<int>(
            initialValue: value.remindMinutes,
            decoration: InputDecoration(labelText: tr.assignmentReminderLead),
            items: [
              for (final minutes in {60, 1440, 10080, value.remindMinutes!})
                DropdownMenuItem(
                  value: minutes,
                  child: Text(switch (minutes) {
                    60 => tr.event1HourBefore,
                    1440 => tr.event1DayBefore,
                    10080 => tr.deadlinesDaysDaysBefore(7),
                    _ => tr.assignmentMinutesBefore(minutes),
                  }),
                ),
            ],
            onChanged: (v) =>
                onChanged(AssignmentSettings(required: true, remindMinutes: v)),
          ),
      ],
    ],
  );
}

/// Each person confirms only their own responsibility. The surrounding
/// record editor remains available without granting rights to other replies.
class AssignmentPanel extends StatelessWidget {
  const AssignmentPanel({super.key, required this.target, this.occurrence});
  final SyncRecord target;
  final DateTime? occurrence;

  @override
  Widget build(BuildContext context) => DataBuilder(
    collections: {
      target.collection,
      Collections.assignmentResponses,
      'members',
    },
    builder: (context, engine) {
      final current = engine.record(target.collection, target.id);
      if (current == null) return const SizedBox.shrink();
      final requests = assignmentRequests(current, occurrence: occurrence);
      return Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final request in requests)
            Builder(
              builder: (context) {
                final decision = engine.assignmentDecision(request);
                final dirty =
                    engine.store
                        .get(Collections.assignmentResponses, request.id)
                        ?.dirty ??
                    false;
                final who =
                    engine.member(request.memberId)?.displayName ??
                    tr.commonMember;
                final kind = switch (request.kind) {
                  AssignmentKind.task => tr.assignmentTask,
                  AssignmentKind.bring => tr.eventDropsOff,
                  AssignmentKind.pick => tr.eventPicksUp,
                };
                final status = switch (decision) {
                  AssignmentDecision.accepted => tr.assignmentAccepted,
                  AssignmentDecision.declined => tr.assignmentDeclined,
                  null => tr.assignmentWaiting,
                };
                final label =
                    '$who · $kind · $status${dirty ? ' · ${tr.assignmentPendingSync}' : ''}';
                final icon = switch (decision) {
                  AssignmentDecision.accepted => AppIcons.check,
                  AssignmentDecision.declined => AppIcons.x,
                  null => AppIcons.clock,
                };
                if (request.memberId != engine.memberId) {
                  return Chip(avatar: Icon(icon, size: 18), label: Text(label));
                }
                return ActionChip(
                  avatar: Icon(icon, size: 18),
                  label: Text(label),
                  onPressed: () async {
                    final picked = await showDialog<String>(
                      context: context,
                      builder: (context) => SimpleDialog(
                        title: Text(tr.assignmentYourResponse),
                        children: [
                          for (final item in [
                            ('accept', tr.assignmentAccepted),
                            ('decline', tr.assignmentDeclined),
                            if (decision != null)
                              ('clear', tr.assignmentWithdraw),
                          ])
                            SimpleDialogOption(
                              onPressed: () => Navigator.pop(context, item.$1),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Text(item.$2),
                              ),
                            ),
                        ],
                      ),
                    );
                    if (picked == 'clear') {
                      engine.delete(
                        Collections.assignmentResponses,
                        request.id,
                      );
                    }
                    if (picked == 'accept' || picked == 'decline') {
                      engine.respondToAssignment(
                        request,
                        picked == 'accept'
                            ? AssignmentDecision.accepted
                            : AssignmentDecision.declined,
                      );
                    }
                  },
                );
              },
            ),
        ],
      );
    },
  );
}
