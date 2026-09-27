import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../data/family_data.dart';
import 'member_avatar.dart';

/// "Ganze Familie", "Nur ich" or the names of the chosen members.
String sharingLabel(SyncEngine engine, CalendarSharing sharing) {
  if (sharing.family) return 'Ganze Familie';
  final names = [
    for (final id in sharing.members!)
      if (id != engine.memberId) ?engine.member(id)?.displayName,
  ];
  return names.isEmpty ? 'Nur ich' : 'Ich, ${names.join(', ')}';
}

/// Chooses who besides the owner sees a connected calendar.
class CalendarSharingPicker extends StatelessWidget {
  const CalendarSharingPicker({
    super.key,
    required this.engine,
    required this.value,
    required this.onChanged,
  });

  final SyncEngine engine;
  final CalendarSharing value;
  final ValueChanged<CalendarSharing> onChanged;

  @override
  Widget build(BuildContext context) {
    final others = [
      for (final m in engine.members)
        if (m.id != engine.memberId) m,
    ];
    final chosen = value.members ?? const <String>[];
    final selected = !value.family && chosen.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Ganze Familie'),
              selected: value.family,
              onSelected: (_) => onChanged(const CalendarSharing.family()),
            ),
            if (others.isNotEmpty)
              ChoiceChip(
                label: const Text('Ausgewählte'),
                selected: selected,
                onSelected: (_) => onChanged(
                  CalendarSharing.only(
                    selected ? chosen : [for (final m in others) m.id],
                  ),
                ),
              ),
            ChoiceChip(
              label: const Text('Nur ich'),
              selected: value.private,
              onSelected: (_) => onChanged(const CalendarSharing.private()),
            ),
          ],
        ),
        if (selected) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in others)
                FilterChip(
                  avatar: MemberAvatar(m, radius: 10),
                  label: Text(m.displayName),
                  selected: chosen.contains(m.id),
                  onSelected: (on) => onChanged(
                    CalendarSharing.only([
                      for (final id in chosen)
                        if (id != m.id) id,
                      if (on) m.id,
                    ]),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Asks who should see [title]; null if cancelled.
Future<CalendarSharing?> showSharingDialog(
  BuildContext context, {
  required SyncEngine engine,
  required String title,
  required CalendarSharing initial,
}) {
  var value = initial;
  return showDialog<CalendarSharing>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('„$title“ teilen'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Wer sieht die Termine dieses Kalenders in Famio?'),
              const SizedBox(height: 12),
              CalendarSharingPicker(
                engine: engine,
                value: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  );
}
