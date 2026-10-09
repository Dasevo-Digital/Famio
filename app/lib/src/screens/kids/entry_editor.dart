part of '../kids_screens.dart';

/// Records (or edits) a milestone, check-up, vaccination, memory or
/// measurement for [child].
Future<void> showEntryEditor(
  BuildContext context, {
  required Child child,
  required ChildEntryKind kind,
  ChildEntry? existing,
  String? refId,
  bool planned = false,
}) => showModalBottomSheet<void>(
  context: context,
  // Above the floating navigation bar.
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _EntryEditor(
    child: child,
    kind: kind,
    existing: existing,
    refId: refId ?? existing?.refId,
    planned: existing?.planned ?? planned,
  ),
);

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({
    required this.child,
    required this.kind,
    this.existing,
    this.refId,
    this.planned = false,
  });

  final Child child;
  final ChildEntryKind kind;
  final ChildEntry? existing;
  final String? refId;

  /// Opens on "Termin" (a booked appointment) instead of "Erledigt".
  final bool planned;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _note = TextEditingController(text: widget.existing?.note);
  late final _height = TextEditingController(
    text: widget.existing?.heightCm == null
        ? ''
        : _num(widget.existing!.heightCm!),
  );
  late final _weight = TextEditingController(
    text: widget.existing?.weightKg == null
        ? ''
        : _num(widget.existing!.weightKg!),
  );
  late final _head = TextEditingController(
    text: widget.existing?.headCm == null ? '' : _num(widget.existing!.headCm!),
  );
  late DateTime _date =
      widget.existing?.date ?? DateUtils.dateOnly(DateTime.now());
  late final _photos = [...?widget.existing?.photos];
  late var _dateUnknown = widget.existing?.dateUnknown ?? false;
  late var _planned = _datedItem && widget.planned;
  late TimeOfDay? _time = _parseTime(widget.existing?.time);
  var _uploading = false;

  static TimeOfDay? _parseTime(String? text) {
    final parts = text?.split(':');
    if (parts == null || parts.length != 2) return null;
    final h = int.tryParse(parts[0]), m = int.tryParse(parts[1]);
    return h == null || m == null ? null : TimeOfDay(hour: h, minute: m);
  }

  /// Done things lie in the past; appointments may lie years ahead.
  DateTime get _lastDate => _planned
      ? DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 365 * 5))
      : DateUtils.dateOnly(DateTime.now());

  DateTime get _firstDate => DateUtils.dateOnly(widget.child.birthDate);

  DateTime _clamp(DateTime d) => d.isBefore(_firstDate)
      ? _firstDate
      : d.isAfter(_lastDate)
      ? _lastDate
      : d;

  bool get _datedItem =>
      widget.kind == ChildEntryKind.checkup ||
      widget.kind == ChildEntryKind.vaccination;

  /// Check-ups can carry the measured values.
  bool get _withMeasurements =>
      widget.kind == ChildEntryKind.measurement ||
      (widget.kind == ChildEntryKind.checkup && !_planned);

  @override
  void dispose() {
    for (final c in [_title, _note, _height, _weight, _head]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _heading => switch (widget.kind) {
    ChildEntryKind.milestone =>
      milestoneById(widget.refId)?.title ?? 'Meilenstein',
    ChildEntryKind.checkup => checkupById(widget.refId)?.title ?? 'Vorsorge',
    ChildEntryKind.vaccination => () {
      final v = vaccinationById(widget.refId);
      return v == null ? 'Impfung' : '${v.title} – ${v.dose}';
    }(),
    ChildEntryKind.measurement => 'Messung',
    ChildEntryKind.memory =>
      widget.existing == null ? 'Erinnerung festhalten' : 'Erinnerung',
  };

  double? _parse(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<void> _addPhoto() async {
    final picked = await pickFile(context, imagesOnly: true);
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final ref = await uploadPicked(context, picked);
      setState(() => _photos.add(ref));
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _save() {
    if (widget.kind == ChildEntryKind.memory && _title.text.trim().isEmpty) {
      return;
    }
    if (widget.kind == ChildEntryKind.measurement &&
        _parse(_height) == null &&
        _parse(_weight) == null &&
        _parse(_head) == null) {
      return;
    }
    AppScope.engineOf(context).saveChildEntry(
      ChildEntry(
        id: widget.existing?.id ?? newId(),
        childId: widget.child.id,
        kind: widget.kind,
        date: _clamp(_date),
        refId: widget.refId,
        title: _title.text.trim(),
        note: _note.text.trim(),
        photos: _photos,
        heightCm: _withMeasurements ? _parse(_height) : null,
        weightKg: _withMeasurements ? _parse(_weight) : null,
        headCm: _withMeasurements ? _parse(_head) : null,
        dateUnknown: _datedItem && !_planned && _dateUnknown,
        planned: _planned,
        time: _planned && _time != null
            ? '${_time!.hour.toString().padLeft(2, '0')}:'
                  '${_time!.minute.toString().padLeft(2, '0')}'
            : null,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _entryLook(
      widget.kind,
      _childColor(context, widget.child),
    ).$2;
    // Check-ups and vaccinations: a photo of the booklet or vaccination card.
    final allowsPhotos = widget.kind != ChildEntryKind.measurement;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconBlob(_entryLook(widget.kind, color).$1, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_heading, style: theme.textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_datedItem) ...[
              PillTabs<bool>(
                values: const [false, true],
                selected: _planned,
                label: (p) => p ? 'Termin geplant' : 'Erledigt',
                color: color,
                onChanged: (p) => setState(() {
                  _planned = p;
                  // A done check-up cannot lie in the future.
                  _date = _clamp(_date);
                }),
              ),
              const SizedBox(height: 12),
            ],
            if (widget.kind == ChildEntryKind.memory) ...[
              TextField(
                controller: _title,
                autofocus: widget.existing == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Was ist passiert?',
                  hintText: 'z. B. Erstes Wort: „Mama“',
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_withMeasurements) ...[
              if (widget.kind == ChildEntryKind.checkup)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Messwerte der Untersuchung (optional)',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _height,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Größe (cm)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _weight,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Gewicht (kg)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _head,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: 'Kopf (cm)'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (_datedItem && !_planned)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Datum unbekannt'),
                value: _dateUnknown,
                onChanged: (v) => setState(() => _dateUnknown = v),
              ),
            if (!(_datedItem && !_planned && _dateUnknown))
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    InputChip(
                      avatar: const Icon(AppIcons.calendarBlank, size: 18),
                      label: Text(
                        'Am ${DateFormat('d. MMMM y', 'de').format(_date)}',
                      ),
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _clamp(_date),
                          firstDate: _firstDate,
                          lastDate: _lastDate,
                        );
                        if (picked != null) setState(() => _date = picked);
                      },
                    ),
                    if (_planned)
                      InputChip(
                        avatar: const Icon(AppIcons.clock, size: 18),
                        label: Text(
                          _time == null
                              ? 'Uhrzeit (optional)'
                              : 'Um ${_time!.format(context)} Uhr',
                        ),
                        onDeleted: _time == null
                            ? null
                            : () => setState(() => _time = null),
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime:
                                _time ?? const TimeOfDay(hour: 9, minute: 0),
                          );
                          if (picked != null) setState(() => _time = picked);
                        },
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Notiz (optional)'),
            ),
            if (allowsPhotos) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 84,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in _photos)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Stack(
                          children: [
                            SizedBox.square(
                              dimension: 84,
                              child: CachedImage(p, thumb: 160),
                            ),
                            Positioned(
                              right: 2,
                              top: 2,
                              child: BubbleButton(
                                icon: AppIcons.x,
                                tooltip: 'Foto entfernen',
                                size: 26,
                                onPressed: () =>
                                    setState(() => _photos.remove(p)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    _uploading
                        ? const SizedBox.square(
                            dimension: 84,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : SizedBox.square(
                            dimension: 84,
                            child: OutlinedButton(
                              onPressed: _addPhoto,
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.zero,
                              ),
                              // Read out by screen readers (icon only).
                              child: const Tooltip(
                                message: 'Foto hinzufügen',
                                child: Icon(AppIcons.imageSquare, size: 30),
                              ),
                            ),
                          ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                if (widget.existing != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: Text(
                      widget.existing!.planned
                          ? 'Termin löschen'
                          : widget.kind == ChildEntryKind.memory ||
                                widget.kind == ChildEntryKind.measurement
                          ? 'Löschen'
                          : 'Zurücksetzen',
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () {
                      AppScope.engineOf(
                        context,
                      ).deleteChildEntry(widget.existing!.id);
                      Navigator.pop(context);
                    },
                  ),
                const Spacer(),
                ColorButton(
                  label: _planned
                      ? 'Termin speichern'
                      : widget.existing == null &&
                            widget.kind != ChildEntryKind.memory &&
                            widget.kind != ChildEntryKind.measurement
                      ? 'Geschafft!'
                      : 'Speichern',
                  color: color,
                  onPressed: _uploading ? null : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
