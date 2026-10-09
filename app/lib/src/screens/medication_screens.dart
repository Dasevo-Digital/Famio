import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

const _collections = {
  Collections.medications,
  Collections.medicationIntakes,
  Collections.shoppingLists,
  'members',
};

List<String> get _weekdayShort => weekdaysShort();

/// Medication plans: today's doses to tick off, supplies and refills.
class MedicationScreen extends StatelessWidget {
  const MedicationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.health);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.health,
      title: tr.commonMedications,
      subtitle: tr.medsDosesViewSupplyUnder,
      actions: const [SyncStatusIcon()],
      floating: AddButton(
        color: color,
        tooltip: tr.medsAddMedication,
        onPressed: () => showMedicationEditor(context),
      ),
      body: DataBuilder(
        collections: _collections,
        builder: (context, engine) {
          final meds = engine.medications;
          final now = DateTime.now();
          final today = DateUtils.dateOnly(now);
          final doses = [
            for (final m in meds)
              for (final at in m.dosesOn(today)) (m, at),
          ]..sort((a, b) => a.$2.compareTo(b.$2));
          return ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              const _Disclaimer(),
              if (meds.isEmpty)
                EmptyHint(
                  icon: AppIcons.pillBottle,
                  color: color,
                  text: tr.medsNoMedicationsYetFamio,
                ),
              if (doses.isNotEmpty) ...[
                ListHeading(tr.commonToday, color: color),
                for (final (m, at) in doses)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _DoseTile(medication: m, at: at, engine: engine),
                  ),
              ],
              if (meds.isNotEmpty) ListHeading(tr.medsAllMedications),
              for (final m in meds)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _MedicationCard(medication: m, engine: engine),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SoftCard(
        color: c.tint(FamioSection.health),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(AppIcons.info, color: c.strong(FamioSection.health)),
            const SizedBox(width: 12),
            Expanded(child: Text(tr.medsFamioOnlyRemindsYou)),
          ],
        ),
      ),
    );
  }
}

class _DoseTile extends StatelessWidget {
  const _DoseTile({
    required this.medication,
    required this.at,
    required this.engine,
  });

  final Medication medication;
  final DateTime at;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final intake = engine.intakeAt(medication, at);
    final overdue =
        intake == null &&
        DateTime.now().isAfter(at.add(const Duration(minutes: 30)));
    final status = intake == null
        ? (overdue ? tr.medsStillOpen : null)
        : intake.skipped
        ? tr.medsSkipped
        : tr.medsTakenTime(
            timeLabel(intake.at),
            intake.byId != engine.memberId
                ? ' · ${engine.member(intake.byId)?.displayName ?? ''}'
                : '',
          );
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              timeLabel(at),
              style: theme.textTheme.titleMedium?.copyWith(
                color: overdue ? c.danger : null,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    medication.name,
                    if (medication.personName.isNotEmpty) medication.personName,
                  ].join(' · '),
                  style: theme.textTheme.titleSmall?.copyWith(
                    decoration: intake != null
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                Text(
                  [
                    if (medication.dose.isNotEmpty) medication.dose,
                    ?status,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: overdue ? c.danger : null,
                  ),
                ),
              ],
            ),
          ),
          if (intake == null) ...[
            TextButton(
              onPressed: () =>
                  engine.recordIntake(medication, scheduled: at, skipped: true),
              child: Text(tr.medsSkip),
            ),
            IconButton.filled(
              tooltip: tr.medsTaken,
              style: IconButton.styleFrom(
                backgroundColor: c.strong(FamioSection.health),
              ),
              icon: const Icon(AppIcons.check, color: Colors.white),
              onPressed: () => engine.recordIntake(medication, scheduled: at),
            ),
          ] else
            IconButton(
              tooltip: tr.commonUndo,
              icon: const Icon(AppIcons.rotateCcw),
              onPressed: () => engine.deleteIntake(intake.id),
            ),
        ],
      ),
    );
  }
}

class _MedicationCard extends StatelessWidget {
  const _MedicationCard({required this.medication, required this.engine});

  final Medication medication;
  final SyncEngine engine;

  void _toShopping(BuildContext context) {
    final lists = engine.shoppingLists;
    if (lists.isEmpty) return;
    engine.addToShoppingList(lists.first.id, [
      Ingredient(name: '${medication.name} (Apotheke)'),
    ]);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr.medsList(lists.first.name))));
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final m = medication;
    final taken = engine.takenSinceCount(m);
    final left = m.left(taken);
    final days = m.daysLeft(taken);
    final low =
        left != null && (left <= 0 || (days != null && days <= m.refillDays));
    final last = m.asNeeded ? engine.intakes(m.id).firstOrNull : null;
    final schedule = m.asNeeded
        ? tr.medsNeeded
        : [
            m.times.join(', '),
            if (m.weekdays.isNotEmpty && m.weekdays.length < 7)
              (m.weekdays.toList()..sort())
                  .map((d) => _weekdayShort[d - 1])
                  .join(', '),
            if (m.end != null)
              'bis ${DateFormat.yMd(appLanguage).format(m.end!)}',
          ].join(' · ');
    return SoftCard(
      onTap: () => showMedicationEditor(context, medication: m),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBlob(
                AppIcons.pill,
                color: c.strong(FamioSection.health),
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name, style: theme.textTheme.titleMedium),
                    Text(
                      [
                        if (m.personName.isNotEmpty) m.personName,
                        if (m.dose.isNotEmpty) m.dose,
                        schedule,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              for (final id in m.careIds.take(3))
                if (engine.member(id) case final member?)
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: MemberAvatar(member, radius: 11),
                  ),
            ],
          ),
          if (left != null || m.asNeeded) const SizedBox(height: 8),
          if (left != null)
            Row(
              children: [
                Icon(
                  low ? AppIcons.warningCircle : AppIcons.package,
                  size: 18,
                  color: low ? c.danger : c.inkSoft,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    left <= 0
                        ? tr.medsSupplyUsedUp
                        : tr.medsCountLeftLasts(
                            _amount(left),
                            days == null ? '' : tr.medsLastsAboutDaysDays(days),
                          ),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: low ? c.danger : null,
                    ),
                  ),
                ),
                if (low && engine.shoppingLists.isNotEmpty)
                  TextButton(
                    onPressed: () => _toShopping(context),
                    child: Text(tr.medsBuyMore),
                  ),
              ],
            ),
          if (m.asNeeded)
            Row(
              children: [
                Expanded(
                  child: Text(
                    last == null
                        ? tr.medsNotTakenYet
                        : tr.medsLastTime(dateTimeLabel(last.at)),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(AppIcons.check, size: 18),
                  label: Text(tr.medsTakenNow),
                  onPressed: () => engine.recordIntake(m),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String _amount(double v) => v == v.roundToDouble()
    ? v.toInt().toString()
    : v.toStringAsFixed(1).replaceAll('.', ',');

Future<void> showMedicationEditor(
  BuildContext context, {
  Medication? medication,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => _MedicationEditor(medication: medication),
  ),
);

class _MedicationEditor extends StatefulWidget {
  const _MedicationEditor({this.medication});

  final Medication? medication;

  @override
  State<_MedicationEditor> createState() => _MedicationEditorState();
}

class _MedicationEditorState extends State<_MedicationEditor> {
  late final Medication? _old = widget.medication;
  late final _name = TextEditingController(text: _old?.name);
  late final _person = TextEditingController(text: _old?.personName);
  late final _dose = TextEditingController(text: _old?.dose);
  late final _perDose = TextEditingController(
    text: _amount(_old?.perDose ?? 1),
  );
  late final _notes = TextEditingController(text: _old?.notes);
  late final _stock = TextEditingController(
    text: _old?.stock == null
        ? ''
        : _amount(
            _old!.left(AppScope.engineOf(context).takenSinceCount(_old)) ?? 0,
          ),
  );
  late final _stockBefore = _stock.text;
  late var _refillDays = _old?.refillDays ?? 7;
  late final _times = [...?_old?.times];
  late var _weekdays = {...?_old?.weekdays};
  late var _start = _old?.start ?? DateUtils.dateOnly(DateTime.now());
  late DateTime? _end = _old?.end;
  late var _asNeeded = _old?.asNeeded ?? false;
  late final List<String> _careIds = [
    ...?_old?.careIds,
    if (_old == null) AppScope.engineOf(context).memberId,
  ];

  @override
  void dispose() {
    for (final c in [_name, _person, _dose, _perDose, _notes, _stock]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _number(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final engine = AppScope.engineOf(context);
    // Only a changed count restarts the stock calculation.
    final stock = _number(_stock.text);
    final recount = _stock.text != _stockBefore;
    engine.saveMedication(
      Medication(
        id: _old?.id ?? newId(),
        name: name,
        personName: _person.text.trim(),
        dose: _dose.text.trim(),
        perDose: _number(_perDose.text) ?? 1,
        times: _asNeeded ? const [] : (_times..sort()),
        weekdays: _weekdays,
        start: _start,
        end: _end,
        stock: stock,
        stockAt: stock == null
            ? null
            : recount || _old?.stockAt == null
            ? DateTime.now()
            : _old!.stockAt,
        refillDays: _refillDays,
        notes: _notes.text.trim(),
        careIds: _careIds,
        asNeeded: _asNeeded,
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _addTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
    );
    if (picked == null) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    if (!_times.contains(text)) setState(() => _times.add(text));
  }

  Future<DateTime?> _pickDay(DateTime initial) => showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(initial.year - 2),
    lastDate: DateTime(initial.year + 3),
  );

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final c = FamioColors.of(context);
    final tint = c.tint(FamioSection.health);
    final day = DateFormat.yMd(appLanguage);
    final people = {
      for (final m in engine.members.where((m) => !m.isGuest)) m.displayName,
      for (final child in engine.children) child.name,
    }.toList();
    return SectionPage(
      maxBodyWidth: 720,
      section: FamioSection.health,
      title: _old == null ? tr.medsNewMedication : _old.name,
      actions: [
        if (_old != null)
          BubbleButton(
            icon: AppIcons.trash,
            tooltip: tr.commonDelete,
            color: c.danger,
            onPressed: () {
              deleteWithUndo(
                context,
                what: _old.name,
                collections: const {
                  Collections.medications,
                  Collections.medicationIntakes,
                },
                delete: () => engine.deleteMedication(_old.id),
              );
              Navigator.pop(context);
            },
          ),
        BubbleButton(
          icon: AppIcons.check,
          tooltip: tr.commonSave,
          color: Colors.white,
          background: c.strong(FamioSection.health),
          onPressed: _save,
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          TextField(
            controller: _name,
            autofocus: _old == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: tr.kidsLogMedication),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _person,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr.medsWhom),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in people)
                ActionChip(
                  label: Text(p),
                  onPressed: () => setState(() => _person.text = p),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dose,
            decoration: InputDecoration(
              labelText: tr.medsDosePrescribed,
              hintText: tr.medsEG1Tablet,
              helperText: tr.medsPrescribedDoctorPackageLeaflet,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr.medsOnlyNeeded),
            subtitle: Text(tr.medsWithoutFixedTimesReminders),
            value: _asNeeded,
            onChanged: (v) => setState(() => _asNeeded = v),
          ),
          if (!_asNeeded) ...[
            ListHeading(tr.medsTimesTakeReminder),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in _times..sort())
                  InputChip(
                    avatar: const Icon(AppIcons.alarm, size: 18),
                    label: Text(t),
                    onDeleted: () => setState(() => _times.remove(t)),
                  ),
                ActionChip(
                  avatar: const Icon(AppIcons.plus, size: 18),
                  label: Text(tr.commonTime),
                  onPressed: _addTime,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    label: Text(_weekdayShort[d - 1]),
                    showCheckmark: false,
                    selectedColor: tint,
                    selected: _weekdays.isEmpty || _weekdays.contains(d),
                    onSelected: (on) {
                      final days = _weekdays.isEmpty
                          ? {1, 2, 3, 4, 5, 6, 7}
                          : {..._weekdays};
                      on ? days.add(d) : days.remove(d);
                      if (days.isEmpty) return;
                      setState(() => _weekdays = days.length == 7 ? {} : days);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                InputChip(
                  label: Text(tr.medsDate(day.format(_start))),
                  onPressed: () async {
                    final d = await _pickDay(_start);
                    if (d != null) setState(() => _start = d);
                  },
                ),
                InputChip(
                  label: Text(
                    _end == null
                        ? tr.medsPermanently
                        : tr.medsUntilDate(day.format(_end!)),
                  ),
                  onPressed: () async {
                    final d = await _pickDay(_end ?? _start);
                    if (d != null) setState(() => _end = d);
                  },
                  onDeleted: _end == null
                      ? null
                      : () => setState(() => _end = null),
                ),
              ],
            ),
          ],
          ListHeading(tr.conflictsPantry),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _stock,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: tr.medsPiecesStock,
                    helperText: tr.medsLeaveEmptyIfDoesn,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _perDose,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(labelText: tr.medsPiecesPerDose),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text(tr.medsWarnWhenSupplyLasts)),
              DropdownButton<int>(
                value: _refillDays,
                items: [
                  for (final d in [3, 5, 7, 10, 14, 21])
                    DropdownMenuItem(
                      value: d,
                      child: Text(tr.commonDaysCount(d)),
                    ),
                ],
                onChanged: (v) => setState(() => _refillDays = v ?? 7),
              ),
            ],
          ),
          ListHeading(tr.medsWhoSeesGetsReminded),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in engine.members.where((m) => !m.isGuest))
                FilterChip(
                  avatar: MemberAvatar(m, radius: 10),
                  label: Text(m.displayName),
                  selectedColor: tint,
                  selected: _careIds.contains(m.id),
                  onSelected: (on) => setState(
                    () => on ? _careIds.add(m.id) : _careIds.remove(m.id),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            tr.medsHealthDataOnlyThose,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: tr.commonNotes,
              hintText: tr.medsEGFoodPrescribed,
            ),
          ),
          if (_old != null) ...[
            ListHeading(tr.pregnancyHistory),
            for (final i in engine.intakes(_old.id).take(20))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  i.skipped ? AppIcons.x : AppIcons.check,
                  color: i.skipped ? c.inkSoft : c.strong(FamioSection.health),
                ),
                title: Text(
                  i.skipped
                      ? tr.medsSkippedTime(timeLabel(i.scheduled ?? i.at))
                      : tr.medsTakenTime2(dateTimeLabel(i.at)),
                ),
                subtitle: Text(engine.member(i.byId)?.displayName ?? ''),
              ),
          ],
        ],
      ),
    );
  }
}
