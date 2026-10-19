import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';
import '../widgets/data_builder.dart';
import 'contacts_screens.dart';
import 'kids_emergency_screens.dart';

/// The emergency page of an adult ([memberId]): numbers, emergency
/// contact, family doctor and the facts helpers need. Works offline from
/// the local copy; only adults have it (see `Collections.adultReadable`).
Future<void> showMemberEmergency(BuildContext context, String memberId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemberEmergencyScreen(memberId: memberId),
      ),
    );

class MemberEmergencyScreen extends StatelessWidget {
  const MemberEmergencyScreen({super.key, required this.memberId});

  final String memberId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DataBuilder(
      collections: const {
        Collections.memberEmergency,
        Collections.contacts,
        'members',
      },
      builder: (context, engine) {
        final own = memberId == engine.memberId;
        final name = engine.member(memberId)?.displayName ?? tr.commonSomeone;
        final e =
            engine.memberEmergency(memberId) ??
            MemberEmergency(memberId: memberId);
        final info = e.info;
        final contact = engine.contact(e.contactId);
        final doctor = engine.contact(info.doctorContactId);
        void edit() => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _MemberEmergencyEditor(current: e),
          ),
        );
        return SectionPage(
          section: FamioSection.health,
          title: own ? tr.memberEmergencyMine : tr.memberEmergencyOf(name),
          subtitle: tr.kidsAlsoWorksWithoutInternet,
          actions: [
            if (own)
              BubbleButton(
                icon: AppIcons.pencilSimple,
                tooltip: tr.memberEmergencyEdit,
                onPressed: edit,
              ),
          ],
          body: ListView(
            padding: EdgeInsets.only(
              top: 4,
              bottom: listBottomPadding(context),
            ),
            children: [
              ...emergencyNumberCards(context),
              if (contact != null) ...[
                ListHeading(tr.memberEmergencyContact),
                ContactCard(contact: contact, color: theme.colorScheme.error),
              ],
              if (doctor != null) ...[
                ListHeading(tr.memberEmergencyDoctor),
                ContactCard(contact: doctor),
              ],
              const SizedBox(height: 12),
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 6),
                    EmergencyFact(
                      tr.kidsAllergies,
                      info.allergies,
                      important: true,
                    ),
                    EmergencyFact(
                      tr.kidsPreexisting,
                      info.conditions,
                      important: true,
                    ),
                    EmergencyFact(tr.kidsLongTermMedication, info.medications),
                    EmergencyFact(tr.kidsBloodType, info.bloodType),
                    EmergencyFact(tr.kidsInsurance, info.insurance),
                    EmergencyFact(tr.kidsInsuranceNo, info.insuranceNumber),
                    EmergencyFact(tr.memberEmergencyDocuments, e.documents),
                    EmergencyFact(tr.kidsNotes, info.note),
                    if (e.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: own
                            ? FilledButton.tonalIcon(
                                icon: const Icon(AppIcons.pencilSimple),
                                label: Text(tr.memberEmergencyAdd),
                                onPressed: edit,
                              )
                            : Text(tr.memberEmergencyNone),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(tr.memberEmergencyVisible, style: theme.textTheme.bodySmall),
            ],
          ),
        );
      },
    );
  }
}

class _MemberEmergencyEditor extends StatefulWidget {
  const _MemberEmergencyEditor({required this.current});

  final MemberEmergency current;

  @override
  State<_MemberEmergencyEditor> createState() => _MemberEmergencyEditorState();
}

class _MemberEmergencyEditorState extends State<_MemberEmergencyEditor> {
  late final EmergencyInfo _info = widget.current.info;
  late final _allergies = TextEditingController(text: _info.allergies);
  late final _conditions = TextEditingController(text: _info.conditions);
  late final _medications = TextEditingController(text: _info.medications);
  late final _blood = TextEditingController(text: _info.bloodType);
  late final _insurance = TextEditingController(text: _info.insurance);
  late final _insuranceNumber = TextEditingController(
    text: _info.insuranceNumber,
  );
  late final _documents = TextEditingController(text: widget.current.documents);
  late final _note = TextEditingController(text: _info.note);
  late String? _doctor = _info.doctorContactId;
  late String? _contact = widget.current.contactId;

  List<TextEditingController> get _fields => [
    _allergies,
    _conditions,
    _medications,
    _blood,
    _insurance,
    _insuranceNumber,
    _documents,
    _note,
  ];

  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    AppScope.engineOf(context).saveMemberEmergency(
      MemberEmergency(
        memberId: widget.current.memberId,
        info: EmergencyInfo(
          allergies: _allergies.text.trim(),
          conditions: _conditions.text.trim(),
          medications: _medications.text.trim(),
          bloodType: _blood.text.trim(),
          insurance: _insurance.text.trim(),
          insuranceNumber: _insuranceNumber.text.trim(),
          doctorContactId: _doctor,
          note: _note.text.trim(),
        ),
        contactId: _contact,
        documents: _documents.text.trim(),
      ),
    );
    Navigator.pop(context);
  }

  /// Contacts to pick from ([selected] always), and a chip for a new one.
  Widget _contactChoice({
    required List<FamilyContact> contacts,
    required String? selected,
    required ContactRole newRole,
    required ValueChanged<String?> onChanged,
  }) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final c in contacts)
        ChoiceChip(
          label: Text(c.name),
          selected: selected == c.id,
          onSelected: (on) => onChanged(on ? c.id : null),
        ),
      ActionChip(
        avatar: const Icon(AppIcons.plus, size: 16),
        label: Text(tr.commonNew),
        onPressed: () async {
          final created = await showContactEditor(context, role: newRole);
          if (created != null) onChanged(created.id);
        },
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final all = engine.contacts;
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
      section: FamioSection.health,
      title: tr.memberEmergencyMine,
      actions: [
        ColorButton(
          label: tr.commonSave,
          color: FamioColors.of(context).strong(FamioSection.health),
          onPressed: _save,
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          ListHeading(tr.memberEmergencyContact),
          _contactChoice(
            contacts: [
              for (final c in all)
                if (c.role == ContactRole.family ||
                    c.role == ContactRole.other ||
                    c.id == _contact)
                  c,
            ],
            selected: _contact,
            newRole: ContactRole.family,
            onChanged: (id) => setState(() => _contact = id),
          ),
          ListHeading(tr.memberEmergencyDoctor),
          _contactChoice(
            contacts: [
              for (final c in all)
                if (c.role == ContactRole.doctor || c.id == _doctor) c,
            ],
            selected: _doctor,
            newRole: ContactRole.doctor,
            onChanged: (id) => setState(() => _doctor = id),
          ),
          const SizedBox(height: 16),
          field(_allergies, tr.kidsAllergies, hint: tr.kidsEGPeanutsPenicillin),
          field(_conditions, tr.kidsPreexisting, hint: tr.kidsEGAsthmaHeart),
          field(_medications, tr.kidsLongTermMedication),
          field(_blood, tr.kidsBloodType),
          field(_insurance, tr.kidsInsurance),
          field(_insuranceNumber, tr.kidsInsuranceNumber),
          field(
            _documents,
            tr.memberEmergencyDocuments,
            hint: tr.memberEmergencyDocumentsHint,
          ),
          field(_note, tr.kidsOtherNotes),
          Text(
            tr.memberEmergencyVisible,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
