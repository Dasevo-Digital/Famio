part of '../kids_screens.dart';

Future<void> showChildEditor(BuildContext context, {Child? existing}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _ChildEditor(existing: existing)),
    );

class _ChildEditor extends StatefulWidget {
  const _ChildEditor({this.existing});

  final Child? existing;

  @override
  State<_ChildEditor> createState() => _ChildEditorState();
}

class _ChildEditorState extends State<_ChildEditor> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late DateTime? _birth = widget.existing?.birthDate;
  late int _color = widget.existing?.color ?? 0xFFDB4A7E;
  late FileRef? _photo = widget.existing?.photo;
  late ChildSex? _sex = widget.existing?.sex;
  // New children start private to their creator; other parents are added
  // right below.
  late final _guardians = {
    ...?widget.existing?.guardianIds,
    if (widget.existing == null) ?AppScope.read(context).me?.id,
  };
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final picked = await pickFile(context, imagesOnly: true);
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final ref = await uploadPicked(context, picked);
      setState(() => _photo = ref);
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    if (_name.text.trim().isEmpty || _birth == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte Name und Geburtstag angeben')),
      );
      return;
    }
    AppScope.engineOf(context).saveChild(
      Child(
        id: widget.existing?.id ?? newId(),
        name: _name.text.trim(),
        birthDate: _birth!,
        color: _color,
        photo: _photo,
        guardianIds: _guardians.toList(),
        sex: _sex,
        emergency: widget.existing?.emergency ?? const EmergencyInfo(),
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${widget.existing!.name} entfernen?'),
        content: const Text(
          'Alle Einträge, Meilensteine und Messungen dieses Kindes werden gelöscht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    AppScope.engineOf(context).deleteChild(widget.existing!.id);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final preview = Child(
      id: '',
      name: _name.text,
      birthDate: _birth ?? DateTime.now(),
      color: _color,
      photo: _photo,
    );
    return SectionPage(
      section: FamioSection.kids,
      title: widget.existing == null ? 'Kind hinzufügen' : 'Profil bearbeiten',
      actions: [
        ColorButton(
          label: 'Speichern',
          color: Color(_color),
          onPressed: _busy ? null : _save,
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          Center(
            child: GestureDetector(
              onTap: _busy ? null : _pickPhoto,
              child: Stack(
                children: [
                  _ChildPhoto(child: preview, size: 120),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: BubbleButton(
                      icon: AppIcons.camera,
                      tooltip: 'Foto wählen',
                      onPressed: _busy ? null : _pickPhoto,
                      size: 38,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const ListHeading('Geburtstag'),
          Align(
            alignment: Alignment.centerLeft,
            child: InputChip(
              avatar: const Icon(AppIcons.cake, size: 18),
              label: Text(
                _birth == null
                    ? 'Datum wählen'
                    : DateFormat('d. MMMM y', 'de').format(_birth!),
              ),
              onPressed: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _birth ?? now,
                  firstDate: DateTime(now.year - 25),
                  lastDate: now,
                );
                if (picked != null) setState(() => _birth = picked);
              },
            ),
          ),
          const ListHeading('Geschlecht'),
          Wrap(
            spacing: 8,
            children: [
              for (final (value, label) in [
                (ChildSex.female, 'Mädchen'),
                (ChildSex.male, 'Junge'),
                (null, 'Keine Angabe'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _sex == value,
                  onSelected: (_) => setState(() => _sex = value),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Nur für die WHO-Wachstumskurven.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const ListHeading('Farbe'),
          Wrap(
            spacing: 10,
            children: [
              for (final c in famioPalette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Color(c),
                    child: c == _color
                        ? const Icon(
                            AppIcons.check,
                            color: Colors.white,
                            size: 18,
                          )
                        : null,
                  ),
                ),
            ],
          ),
          const ListHeading('Sorgeberechtigte'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in engine.members)
                FilterChip(
                  avatar: MemberAvatar(m, radius: 10),
                  label: Text(m.displayName),
                  selected: _guardians.contains(m.id),
                  onSelected: (on) => setState(
                    () => on ? _guardians.add(m.id) : _guardians.remove(m.id),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Nur sie sehen Entwicklung, Vorsorge, Impfungen und Fotos und '
              'werden erinnert. Niemand ausgewählt: die ganze Familie.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (widget.existing != null) ...[
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.trash, size: 18),
                label: const Text('Kind entfernen'),
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
