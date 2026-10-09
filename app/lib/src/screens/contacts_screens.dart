import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/birthday_field.dart';
import '../widgets/data_builder.dart';
import '../widgets/phone.dart';
import '../widgets/sync_status_icon.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

const _contactCollections = {
  Collections.contacts,
  Collections.children,
  'members',
};

IconData contactIcon(ContactRole role) => switch (role) {
  ContactRole.pediatrician || ContactRole.doctor => AppIcons.stethoscope,
  ContactRole.dentist => AppIcons.smiley,
  ContactRole.midwife => AppIcons.heart,
  ContactRole.clinic => AppIcons.ambulance,
  ContactRole.daycare => AppIcons.baby,
  ContactRole.school => AppIcons.backpack,
  ContactRole.babysitter => AppIcons.heart,
  ContactRole.family => AppIcons.usersThree,
  ContactRole.emergency => AppIcons.siren,
  ContactRole.other => AppIcons.contact,
};

/// Important numbers of the family: pediatrician, daycare, babysitter …
class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final color = FamioColors.of(context).strong(FamioSection.contacts);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.contacts,
      title: tr.sectionContacts,
      subtitle: tr.contactsPediatricianDaycareBabysitterCo,
      actions: const [SyncStatusIcon()],
      floating: AddButton(
        color: color,
        tooltip: tr.contactsAdd,
        onPressed: () => showContactEditor(context),
      ),
      body: DataBuilder(
        collections: _contactCollections,
        builder: (context, engine) {
          final contacts = engine.contacts;
          if (contacts.isEmpty) {
            return EmptyHint(
              icon: AppIcons.bookUser,
              color: color,
              text: tr.contactsImportantNumbersOnePlace,
              action: ColorButton(
                label: tr.contactsAdd,
                color: color,
                onPressed: () => showContactEditor(context),
              ),
            );
          }
          final roles = [
            for (final r in ContactRole.values)
              if (contacts.any((c) => c.role == r)) r,
          ];
          return ListView(
            padding: EdgeInsets.only(
              top: 4,
              bottom: listBottomPadding(context),
            ),
            children: [
              for (final role in roles) ...[
                ListHeading(role.label),
                for (final c in contacts.where((c) => c.role == role))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ContactCard(contact: c),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// A contact with call and mail buttons; tap to edit.
class ContactCard extends StatelessWidget {
  const ContactCard({super.key, required this.contact, this.color});

  final FamilyContact contact;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = AppScope.engineOf(context);
    final strong =
        color ?? FamioColors.of(context).strong(FamioSection.contacts);
    final kids = [for (final id in contact.childIds) ?engine.child(id)?.name];
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      onTap: () => showContactEditor(context, existing: contact),
      child: Row(
        children: [
          IconBlob(contactIcon(contact.role), color: strong),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contact.name, style: theme.textTheme.titleMedium),
                Text(
                  [
                    if (contact.phone.isNotEmpty) contact.phone,
                    if (kids.isNotEmpty) tr.contactsKids(kids.join(', ')),
                    if (contact.note.isNotEmpty) contact.note,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (contact.email.isNotEmpty)
            IconButton(
              icon: const Icon(AppIcons.paperPlaneRight),
              tooltip: tr.contactsWriteEmail,
              onPressed: () => writeMail(context, contact.email),
            ),
          if (contact.phone2.isNotEmpty)
            IconButton(
              icon: const Icon(AppIcons.smartphone),
              tooltip: tr.contactsCallPhone(contact.phone2),
              onPressed: () => callNumber(context, contact.phone2),
            ),
          if (contact.phone.isNotEmpty)
            IconButton.filledTonal(
              icon: const Icon(AppIcons.phone),
              tooltip: tr.contactsCallPhone(contact.phone),
              onPressed: () => callNumber(context, contact.phone),
            ),
        ],
      ),
    );
  }
}

/// Adds or edits a contact; returns the saved one.
Future<FamilyContact?> showContactEditor(
  BuildContext context, {
  FamilyContact? existing,
  ContactRole? role,
  String? childId,
}) => Navigator.of(context).push(
  MaterialPageRoute<FamilyContact>(
    builder: (_) =>
        _ContactEditor(existing: existing, role: role, childId: childId),
  ),
);

class _ContactEditor extends StatefulWidget {
  const _ContactEditor({this.existing, this.role, this.childId});

  final FamilyContact? existing;
  final ContactRole? role;
  final String? childId;

  @override
  State<_ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends State<_ContactEditor> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _phone = TextEditingController(text: widget.existing?.phone);
  late final _phone2 = TextEditingController(text: widget.existing?.phone2);
  late final _email = TextEditingController(text: widget.existing?.email);
  late final _address = TextEditingController(text: widget.existing?.address);
  late final _note = TextEditingController(text: widget.existing?.note);
  late var _role = widget.existing?.role ?? widget.role ?? ContactRole.other;
  late final _kids = {...?widget.existing?.childIds, ?widget.childId};
  late Birthday? _birthday = widget.existing?.birthday;

  @override
  void dispose() {
    for (final c in [_name, _phone, _phone2, _email, _address, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.contactsPleaseEnterName)));
      return;
    }
    final contact = FamilyContact(
      id: widget.existing?.id ?? newId(),
      name: _name.text.trim(),
      role: _role,
      phone: _phone.text.trim(),
      phone2: _phone2.text.trim(),
      email: _email.text.trim(),
      address: _address.text.trim(),
      note: _note.text.trim(),
      childIds: _kids.toList(),
      birthday: _birthday,
    );
    AppScope.engineOf(context).saveContact(contact);
    Navigator.pop(context, contact);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr.contactsDeleteName(widget.existing!.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final engine = AppScope.engineOf(context);
    deleteWithUndo(
      context,
      what: widget.existing!.name,
      collections: const {Collections.contacts},
      delete: () => engine.deleteContact(widget.existing!.id),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final color = FamioColors.of(context).strong(FamioSection.contacts);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.contacts,
      title: widget.existing == null ? tr.contactsNewContact : tr.commonContact,
      actions: [
        ColorButton(label: tr.commonSave, color: color, onPressed: _save),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          TextField(
            controller: _name,
            autofocus: widget.existing == null,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: tr.commonName,
              hintText: tr.contactsEGDrSommer,
            ),
          ),
          ListHeading(tr.contactsType),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in ContactRole.values)
                ChoiceChip(
                  avatar: Icon(contactIcon(r), size: 16),
                  label: Text(r.label),
                  selected: _role == r,
                  onSelected: (_) => setState(() => _role = r),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: tr.contactsPhone),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone2,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: tr.contactsOtherNumberOptional,
              hintText: tr.contactsMobileEmergencyPracticeCell,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(labelText: tr.contactsEmailOptional),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(labelText: tr.contactsAddressOptional),
          ),
          ListHeading(tr.commonBirthday),
          BirthdayField(
            value: _birthday,
            onChanged: (v) => setState(() => _birthday = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: tr.contactsNoteOptional,
              hintText: tr.contactsOfficeHoursCustomerNumber,
            ),
          ),
          if (engine.children.isNotEmpty) ...[
            ListHeading(tr.contactsBelongs),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in engine.children)
                  FilterChip(
                    label: Text(c.name),
                    selected: _kids.contains(c.id),
                    onSelected: (on) => setState(
                      () => on ? _kids.add(c.id) : _kids.remove(c.id),
                    ),
                  ),
              ],
            ),
          ],
          if (widget.existing != null) ...[
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.trash, size: 18),
                label: Text(tr.contactsDeleteContact),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: _delete,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
