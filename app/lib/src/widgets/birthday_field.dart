import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../design/app_icons.dart';
import '../l10n.dart';

/// "12. Juni 1985" or "12. Juni".
String birthdayLabel(Birthday b) {
  final date = b.inYear(b.year ?? 2000);
  return b.year == null
      ? DateFormat.MMMMd(appLanguage).format(date)
      : DateFormat.yMMMMd(appLanguage).format(date);
}

/// Picks a birthday; the year may stay unknown.
class BirthdayField extends StatelessWidget {
  const BirthdayField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final Birthday? value;
  final ValueChanged<Birthday?> onChanged;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate:
          value?.inYear(value!.year ?? now.year - 30) ??
          DateTime(now.year - 30, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'Geburtstag',
    );
    if (picked == null) return;
    onChanged(
      value != null && value!.year == null
          ? Birthday(picked.month, picked.day)
          : Birthday.ofDate(picked),
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = value;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        InputChip(
          avatar: const Icon(AppIcons.cake, size: 18),
          label: Text(b == null ? 'Geburtstag wählen' : birthdayLabel(b)),
          onPressed: () => _pick(context),
          onDeleted: b == null ? null : () => onChanged(null),
        ),
        if (b != null)
          FilterChip(
            label: const Text('Jahr unbekannt'),
            selected: b.year == null,
            onSelected: (unknown) => onChanged(
              unknown
                  ? Birthday(b.month, b.day)
                  : Birthday(b.month, b.day, DateTime.now().year - 30),
            ),
          ),
      ],
    );
  }
}
