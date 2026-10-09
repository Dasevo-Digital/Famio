import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/kids_logic.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/phone.dart';
import 'contacts_screens.dart';
import 'kids_log_screens.dart';
import '../format.dart';
import '../l10n.dart';

/// Numbers that work everywhere in Germany.
List<(String, String, String)> get emergencyNumbers => [
  ('112', tr.kidsEmergency, tr.kidsAmbulanceFireBrigade),
  ('116117', tr.kidsOutHoursMedicalService, tr.kids116117WhenPractice),
  ('03019240', tr.kidsPoisonControl, tr.kids03019240ReachableNationwide),
];

/// The emergency page of [child]: works offline from the local copy.
Future<void> showEmergency(BuildContext context, Child child) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmergencyScreen(childId: child.id),
      ),
    );

class EmergencyScreen extends StatelessWidget {
  const EmergencyScreen({super.key, required this.childId});

  final String childId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = theme.colorScheme.error;
    return DataBuilder(
      collections: const {
        Collections.children,
        Collections.childEntries,
        Collections.childLogs,
        Collections.contacts,
      },
      builder: (context, engine) {
        final child = engine.child(childId);
        if (child == null) {
          return SectionPage(
            section: FamioSection.kids,
            title: tr.kidsEmergencyTitle,
            body: SizedBox.shrink(),
          );
        }
        final info = child.emergency;
        final weight = engine
            .childEntries(child.id)
            .where((e) => e.weightKg != null && !e.dateUnknown)
            .lastOrNull;
        final logs = engine.childLogs(child.id);
        final now = DateTime.now();
        final recentMeds = logs
            .where(
              (l) =>
                  l.kind == LogKind.medication &&
                  now.difference(l.start).inHours < 24,
            )
            .toList();
        final lastTemp = logs
            .where(
              (l) =>
                  l.kind == LogKind.temperature &&
                  now.difference(l.start).inHours < 24,
            )
            .firstOrNull;
        final doctor = engine.contact(info.doctorContactId);
        final others = engine.contacts
            .where((c) => c.childIds.contains(child.id) && c.id != doctor?.id)
            .toList();
        final time = DateFormat.Md(appLanguage).add_jm();

        Widget fact(String label, String value, {bool important = false}) =>
            value.trim().isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(label, style: theme.textTheme.bodySmall),
                    ),
                    Expanded(
                      child: Text(
                        value,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: important ? FontWeight.w800 : null,
                          color: important ? danger : null,
                        ),
                      ),
                    ),
                  ],
                ),
              );

        return SectionPage(
          section: FamioSection.kids,
          title: tr.kidsEmergencyName(child.name),
          subtitle: tr.kidsAlsoWorksWithoutInternet,
          actions: [
            BubbleButton(
              icon: AppIcons.pencilSimple,
              tooltip: tr.kidsEditEmergencyData,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _EmergencyEditor(child: child),
                ),
              ),
            ),
          ],
          body: ListView(
            padding: EdgeInsets.only(
              top: 4,
              bottom: listBottomPadding(context),
            ),
            children: [
              for (final (number, title, subtitle) in emergencyNumbers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SoftCard(
                    color: number == '112'
                        ? danger
                        : danger.withValues(alpha: 0.12),
                    onTap: () => callNumber(context, number),
                    padding: EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: number == '112' ? 18 : 12,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          number == '112' ? AppIcons.siren : AppIcons.phoneCall,
                          color: number == '112' ? Colors.white : danger,
                          size: number == '112' ? 34 : 24,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                number == '112' ? '112 – $title' : title,
                                style:
                                    (number == '112'
                                            ? theme.textTheme.headlineSmall
                                            : theme.textTheme.titleMedium)
                                        ?.copyWith(
                                          color: number == '112'
                                              ? Colors.white
                                              : null,
                                        ),
                              ),
                              Text(
                                subtitle,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: number == '112'
                                      ? Colors.white.withValues(alpha: 0.9)
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (doctor != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ContactCard(contact: doctor, color: danger),
                ),
              const SizedBox(height: 4),
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr.kidsPhone5WQuestions,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    for (final (w, text) in [
                      (tr.kidsWhere, tr.kidsDidHappenAddressFloor),
                      (tr.kidsWhat, tr.kidsHappened),
                      (tr.kidsHowMany, tr.kidsAffected),
                      (tr.kidsWhich, tr.kidsInjuriesSymptoms),
                      (tr.kidsWait, tr.kidsQuestionsDoNotHang),
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '$w ',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              TextSpan(text: text),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(child.name, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 6),
                    fact(
                      tr.kidsAge,
                      tr.kidsAgeBornBorn(
                        ageLabel(child),
                        DateFormat.yMd(appLanguage).format(child.birthDate),
                      ),
                    ),
                    if (weight != null)
                      fact(
                        tr.kidsLogWeight,
                        tr.kidsWeightKgDate(
                          decimal(weight.weightKg!),
                          DateFormat.yMd(appLanguage).format(weight.date),
                        ),
                      ),
                    fact(tr.kidsAllergies, info.allergies, important: true),
                    fact(tr.kidsPreexisting, info.conditions, important: true),
                    fact(tr.kidsLongTermMedication, info.medications),
                    fact(tr.kidsBloodType, info.bloodType),
                    fact(tr.kidsInsurance, info.insurance),
                    fact(tr.kidsInsuranceNo, info.insuranceNumber),
                    fact(tr.kidsNotes, info.note),
                    if (lastTemp?.temperatureC != null)
                      fact(
                        tr.kidsLogTemperature,
                        tr.commonAtTime(
                          logText(lastTemp!),
                          time.format(lastTemp.start),
                        ),
                      ),
                    for (final m in recentMeds)
                      fact(
                        tr.kidsLastGiven,
                        tr.commonAtTime(logText(m), time.format(m.start)),
                        important: true,
                      ),
                    if (info.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FilledButton.tonalIcon(
                          icon: const Icon(AppIcons.pencilSimple),
                          label: Text(tr.kidsAddAllergiesPediatricianCo),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _EmergencyEditor(child: child),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (others.isNotEmpty) ...[
                ListHeading(tr.kidsOtherContacts),
                for (final c in others)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ContactCard(contact: c),
                  ),
              ],
              const SizedBox(height: 12),
              Text(
                tr.kidsFirstAidChildrenBest,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmergencyEditor extends StatefulWidget {
  const _EmergencyEditor({required this.child});

  final Child child;

  @override
  State<_EmergencyEditor> createState() => _EmergencyEditorState();
}

class _EmergencyEditorState extends State<_EmergencyEditor> {
  late final EmergencyInfo _info = widget.child.emergency;
  late final _allergies = TextEditingController(text: _info.allergies);
  late final _conditions = TextEditingController(text: _info.conditions);
  late final _medications = TextEditingController(text: _info.medications);
  late final _blood = TextEditingController(text: _info.bloodType);
  late final _insurance = TextEditingController(text: _info.insurance);
  late final _insuranceNumber = TextEditingController(
    text: _info.insuranceNumber,
  );
  late final _note = TextEditingController(text: _info.note);
  late String? _doctor = _info.doctorContactId;

  @override
  void dispose() {
    for (final c in [
      _allergies,
      _conditions,
      _medications,
      _blood,
      _insurance,
      _insuranceNumber,
      _note,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final engine = AppScope.engineOf(context);
    final current = engine.child(widget.child.id) ?? widget.child;
    engine.saveChild(
      Child(
        id: current.id,
        name: current.name,
        birthDate: current.birthDate,
        color: current.color,
        photo: current.photo,
        guardianIds: current.guardianIds,
        sex: current.sex,
        emergency: EmergencyInfo(
          allergies: _allergies.text.trim(),
          conditions: _conditions.text.trim(),
          medications: _medications.text.trim(),
          bloodType: _blood.text.trim(),
          insurance: _insurance.text.trim(),
          insuranceNumber: _insuranceNumber.text.trim(),
          doctorContactId: _doctor,
          note: _note.text.trim(),
        ),
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final doctors = engine.contacts
        .where(
          (c) =>
              c.role == ContactRole.pediatrician ||
              c.role == ContactRole.doctor ||
              c.id == _doctor,
        )
        .toList();
    Widget field(TextEditingController c, String label, {String? hint}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: c,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: label, hintText: hint),
          ),
        );
    return SectionPage(
      section: FamioSection.kids,
      title: tr.kidsEmergencyData,
      subtitle: widget.child.name,
      actions: [
        ColorButton(
          label: tr.commonSave,
          color: FamioColors.of(context).strong(FamioSection.kids),
          onPressed: _save,
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          ListHeading(tr.kidsPediatrician),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final d in doctors)
                ChoiceChip(
                  label: Text(d.name),
                  selected: _doctor == d.id,
                  onSelected: (on) =>
                      setState(() => _doctor = on ? d.id : null),
                ),
              ActionChip(
                avatar: const Icon(AppIcons.plus, size: 16),
                label: Text(tr.commonNew),
                onPressed: () async {
                  final created = await showContactEditor(
                    context,
                    role: ContactRole.pediatrician,
                    childId: widget.child.id,
                  );
                  if (created != null) setState(() => _doctor = created.id);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          field(_allergies, tr.kidsAllergies, hint: tr.kidsEGPeanutsPenicillin),
          field(_conditions, tr.kidsPreexisting, hint: tr.kidsEGAsthmaHeart),
          field(_medications, tr.kidsLongTermMedication),
          field(_blood, tr.kidsBloodType),
          field(_insurance, tr.kidsInsurance),
          field(_insuranceNumber, tr.kidsInsuranceNumber),
          field(_note, tr.kidsOtherNotes, hint: tr.kidsEGVaccinationRecord),
          Text(
            tr.kidsVisibleChildSGuardians,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
