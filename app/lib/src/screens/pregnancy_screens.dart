import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/kids_logic.dart';
import '../data/pregnancy_logic.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import 'contacts_screens.dart';
import 'kids_screens.dart';

const _color = Color(0xFFB45BD6);
final _date = DateFormat('d. MMM y', 'de');
final _short = DateFormat('d.M.', 'de');

/// Card at the top of the children's list.
class PregnancyCard extends StatelessWidget {
  const PregnancyCard({super.key, required this.pregnancy});

  final Pregnancy pregnancy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = pregnancy;
    final (w, _) = p.weekOn(DateTime.now());
    final week = pregnancyWeek(w);
    final left = daysToGo(p);
    return SoftCard(
      color: _color.withValues(alpha: 0.12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PregnancyScreen(pregnancyId: p.id),
        ),
      ),
      child: Row(
        children: [
          const IconBlob(AppIcons.heart, color: _color, size: 64),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name.isEmpty ? 'Schwangerschaft' : p.name,
                  style: theme.textTheme.headlineSmall,
                ),
                Text(
                  'SSW ${weekLabel(p)} · '
                  '${left > 0
                      ? 'noch $left Tage'
                      : left == 0
                      ? 'heute ist ET'
                      : '${-left} Tage über ET'}',
                  style: theme.textTheme.bodyMedium,
                ),
                if (week != null)
                  Text(
                    'So groß wie ${week.like}',
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: (280 - left).clamp(0, 280) / 280,
                    minHeight: 8,
                    color: _color,
                    backgroundColor: _color.withValues(alpha: 0.15),
                  ),
                ),
              ],
            ),
          ),
          const Icon(AppIcons.caretRight),
        ],
      ),
    );
  }
}

enum _Tab {
  week('Woche'),
  tasks('Termine'),
  lists('Checklisten'),
  contractions('Wehen');

  const _Tab(this.label);

  final String label;
}

class PregnancyScreen extends StatefulWidget {
  const PregnancyScreen({super.key, required this.pregnancyId});

  final String pregnancyId;

  @override
  State<PregnancyScreen> createState() => _PregnancyScreenState();
}

class _PregnancyScreenState extends State<PregnancyScreen> {
  _Tab? _tab;

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {Collections.pregnancies, Collections.contacts},
      builder: (context, engine) {
        final p = engine.pregnancy(widget.pregnancyId);
        if (p == null) {
          return const SectionPage(
            section: FamioSection.kids,
            title: 'Schwangerschaft',
            body: SizedBox.shrink(),
          );
        }
        final (w, _) = p.weekOn(DateTime.now());
        // Late in pregnancy the contraction timer is what matters.
        final tab = _tab ?? (w >= 36 ? _Tab.contractions : _Tab.week);
        return SectionPage(
          section: FamioSection.kids,
          title: p.name.isEmpty ? 'Schwangerschaft' : p.name,
          subtitle: 'SSW ${weekLabel(p)} · ET ${_date.format(p.dueDate)}',
          actions: [
            BubbleButton(
              icon: AppIcons.pencilSimple,
              tooltip: 'Bearbeiten',
              onPressed: () => showPregnancyEditor(context, existing: p),
            ),
          ],
          body: Column(
            children: [
              PillTabs<_Tab>(
                values: _Tab.values,
                selected: tab,
                label: (t) => t.label,
                color: _color,
                onChanged: (t) => setState(() => _tab = t),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: switch (tab) {
                  _Tab.week => _WeekView(pregnancy: p),
                  _Tab.tasks => _TasksView(pregnancy: p),
                  _Tab.lists => _ChecklistsView(pregnancy: p),
                  _Tab.contractions => _ContractionsView(pregnancy: p),
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WeekView extends StatelessWidget {
  const _WeekView({required this.pregnancy});

  final Pregnancy pregnancy;

  @override
  Widget build(BuildContext context) {
    final p = pregnancy;
    final theme = Theme.of(context);
    final (w, d) = p.weekOn(DateTime.now());
    final week = pregnancyWeek(w);
    final next = [
      for (final t in pregnancyTasks)
        if (taskState(p, t) case DueState.due || DueState.late) t,
      for (final t in pregnancyTasks)
        if (taskState(p, t) == DueState.upcoming) t,
    ];
    final left = daysToGo(p);
    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        SoftCard(
          color: _color.withValues(alpha: 0.12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SSW $w+$d', style: theme.textTheme.displaySmall),
              Text(
                '${w + 1}. Schwangerschaftswoche · ${trimester(p)}. Drittel · '
                '${left > 0 ? 'noch $left Tage' : 'ET erreicht'}',
              ),
              if (week != null) ...[
                const SizedBox(height: 16),
                Text(
                  'Euer Baby ist ungefähr so groß wie ${week.like}',
                  style: theme.textTheme.titleMedium,
                ),
                if (week.weightG > 0)
                  Text(
                    'etwa ${week.lengthCm.toStringAsFixed(week.lengthCm < 10 ? 1 : 0).replaceAll('.', ',')} cm · '
                    '${week.weightG >= 1000 ? '${(week.weightG / 1000).toStringAsFixed(1).replaceAll('.', ',')} kg' : '${week.weightG} g'}',
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                Text(week.info),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final t in next.take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _TaskCard(pregnancy: p, task: t),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(
              avatar: const Icon(AppIcons.calendarBlank, size: 16),
              label: Text('Mutterschutz ab ${_date.format(maternityLeave(p))}'),
            ),
            Chip(
              avatar: const Icon(AppIcons.star, size: 16),
              label: Text('ET ${_date.format(p.dueDate)}'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (w >= 20)
          Align(
            alignment: Alignment.centerLeft,
            child: ColorButton(
              label: 'Baby ist da!',
              icon: AppIcons.baby,
              color: _color,
              onPressed: () => _babyArrived(context, p),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          'Größenangaben sind Durchschnittswerte. Maßgeblich sind Hebamme, '
          'Frauenarzt und Mutterpass.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.pregnancy, required this.task});

  final Pregnancy pregnancy;
  final PregnancyTask task;

  @override
  Widget build(BuildContext context) {
    final p = pregnancy;
    final t = task;
    final theme = Theme.of(context);
    final state = taskState(p, t);
    final done = state == DueState.done;
    final (label, color) = switch (state) {
      DueState.done => ('erledigt', const Color(0xFF2A9D6E)),
      DueState.due => ('jetzt', theme.colorScheme.error),
      DueState.late => ('überfällig', const Color(0xFFE8703A)),
      _ => ('demnächst', FamioColors.of(context).inkSoft),
    };
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(8, 10, 16, 10),
      child: Row(
        children: [
          RoundCheck(
            label: t.title,
            value: done,
            color: const Color(0xFF2A9D6E),
            onChanged: (v) => AppScope.engineOf(context).savePregnancy(
              p.copyWith(
                done: v ? {...p.done, t.id} : ({...p.done}..remove(t.id)),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.title, style: theme.textTheme.titleMedium),
                Text(
                  'SSW ${t.fromWeek}–${t.toWeek} · '
                  '${_short.format(p.dayOf(t.fromWeek))} – '
                  '${_short.format(p.dayOf(t.toWeek, 6))}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(t.info, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _TasksView extends StatelessWidget {
  const _TasksView({required this.pregnancy});

  final Pregnancy pregnancy;

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
    children: [
      Text(
        'Dazu kommen die regelmäßigen Vorsorgen: bis SSW 32 alle 4 Wochen, '
        'danach alle 2 Wochen.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      for (final t in pregnancyTasks)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _TaskCard(pregnancy: pregnancy, task: t),
        ),
    ],
  );
}

class _ChecklistsView extends StatelessWidget {
  const _ChecklistsView({required this.pregnancy});

  final Pregnancy pregnancy;

  @override
  Widget build(BuildContext context) {
    final p = pregnancy;
    final engine = AppScope.engineOf(context);
    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        for (final list in pregnancyChecklists)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SoftCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ExpansionTile(
                shape: const Border(),
                initiallyExpanded: list.id == 'bag',
                title: Text(list.title),
                subtitle: Text(
                  '${list.items.where((i) => p.done.contains(i.id)).length} '
                  'von ${list.items.length}',
                ),
                children: [
                  for (final item in list.items)
                    CheckboxListTile(
                      value: p.done.contains(item.id),
                      title: Text(item.title),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (v) => engine.savePregnancy(
                        p.copyWith(
                          done: v == true
                              ? {...p.done, item.id}
                              : ({...p.done}..remove(item.id)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ContractionsView extends StatefulWidget {
  const _ContractionsView({required this.pregnancy});

  final Pregnancy pregnancy;

  @override
  State<_ContractionsView> createState() => _ContractionsViewState();
}

class _ContractionsViewState extends State<_ContractionsView> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.pregnancy.contractions.any((c) => c.end == null)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _mmss(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final p = widget.pregnancy;
    final theme = Theme.of(context);
    final engine = AppScope.engineOf(context);
    final now = DateTime.now();
    final list = p.contractions;
    final running = list.isNotEmpty && list.last.end == null;
    final stats = contractionStats(list, at: now);
    final call = timeToCall(list, at: now);
    final contacts = engine.contacts
        .where(
          (c) => c.role == ContactRole.midwife || c.role == ContactRole.clinic,
        )
        .toList();
    void toggle() {
      final t = DateTime.now();
      engine.savePregnancy(
        p.copyWith(
          contractions: running
              ? [...list.take(list.length - 1), Contraction(list.last.start, t)]
              : [...list, Contraction(t)],
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        SizedBox(
          height: 150,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: running ? theme.colorScheme.error : _color,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(32),
              ),
            ),
            onPressed: toggle,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  running ? 'Wehe vorbei' : 'Wehe beginnt',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                  ),
                ),
                if (running)
                  Text(
                    _mmss(now.difference(list.last.start)),
                    style: theme.textTheme.displaySmall?.copyWith(
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        SoftCard(
          color: call ? theme.colorScheme.error.withValues(alpha: 0.14) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Letzte Stunde', style: theme.textTheme.titleMedium),
              Text(
                '${stats.count} Wehen'
                '${stats.length == null ? '' : ' · je ${_mmss(stats.length!)} min'}'
                '${stats.interval == null ? '' : ' · alle ${_mmss(stats.interval!)} min'}',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 8),
              Text(
                call
                    ? 'Wehen alle 5 Minuten seit einer Stunde: jetzt Klinik '
                          'oder Hebamme anrufen.'
                    : 'Faustregel: alle 5 Minuten, je etwa 1 Minute, seit '
                          'einer Stunde → Klinik oder Hebamme anrufen. '
                          'Sofort bei Blasensprung, Blutung, starken '
                          'Schmerzen oder weniger Kindsbewegungen.',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: call ? FontWeight.w800 : null,
                ),
              ),
            ],
          ),
        ),
        for (final c in contacts) ...[
          const SizedBox(height: 8),
          ContactCard(contact: c),
        ],
        if (contacts.isEmpty)
          TextButton.icon(
            icon: const Icon(AppIcons.plus, size: 18),
            label: const Text('Hebamme oder Klinik als Kontakt anlegen'),
            onPressed: () =>
                showContactEditor(context, role: ContactRole.midwife),
          ),
        if (list.isNotEmpty) ...[
          const ListHeading('Verlauf'),
          for (var i = list.length - 1; i >= 0 && i >= list.length - 20; i--)
            ListTile(
              dense: true,
              leading: Text(
                DateFormat('HH:mm:ss').format(list[i].start),
                style: theme.textTheme.labelLarge,
              ),
              title: Text(
                list[i].length == null
                    ? 'läuft'
                    : 'Dauer ${_mmss(list[i].length!)}',
              ),
              trailing: i == 0
                  ? null
                  : Text(
                      'Abstand ${_mmss(list[i].start.difference(list[i - 1].start))}',
                    ),
            ),
          TextButton(
            onPressed: () => engine.savePregnancy(p.copyWith(contractions: [])),
            child: const Text('Verlauf leeren'),
          ),
        ],
      ],
    );
  }
}

/// Creates the child from the pregnancy and opens it.
Future<void> _babyArrived(BuildContext context, Pregnancy p) async {
  final name = TextEditingController(text: p.name);
  var born = DateUtils.dateOnly(DateTime.now());
  ChildSex? sex;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        scrollable: true,
        title: const Text('Herzlichen Glückwunsch! 🎉'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            InputChip(
              avatar: const Icon(AppIcons.cake, size: 18),
              label: Text('Geboren am ${_date.format(born)}'),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: born,
                  firstDate: p.dayOf(20),
                  lastDate: DateTime.now(),
                );
                if (picked != null) setState(() => born = picked);
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final (v, l) in [
                  (ChildSex.female, 'Mädchen'),
                  (ChildSex.male, 'Junge'),
                ])
                  ChoiceChip(
                    label: Text(l),
                    selected: sex == v,
                    onSelected: (on) => setState(() => sex = on ? v : null),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Kind anlegen'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || name.text.trim().isEmpty || !context.mounted) return;
  final engine = AppScope.engineOf(context);
  final child = Child(
    id: newId(),
    name: name.text.trim(),
    birthDate: born,
    sex: sex,
    color: 0xFFB45BD6,
    guardianIds: p.guardianIds.isEmpty ? [engine.memberId] : p.guardianIds,
  );
  engine
    ..saveChild(child)
    ..savePregnancy(p.copyWith(childId: child.id));
  Navigator.of(context).pushReplacement(
    MaterialPageRoute<void>(builder: (_) => ChildScreen(childId: child.id)),
  );
}

/// Adds or edits a pregnancy.
Future<void> showPregnancyEditor(BuildContext context, {Pregnancy? existing}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _PregnancyEditor(existing: existing),
      ),
    );

class _PregnancyEditor extends StatefulWidget {
  const _PregnancyEditor({this.existing});

  final Pregnancy? existing;

  @override
  State<_PregnancyEditor> createState() => _PregnancyEditorState();
}

class _PregnancyEditorState extends State<_PregnancyEditor> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late DateTime? _due = widget.existing?.dueDate;
  late String? _mother = widget.existing?.motherId;
  late final _guardians = {
    ...?widget.existing?.guardianIds,
    if (widget.existing == null) ?AppScope.read(context).me?.id,
  };

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (_due == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte den errechneten Termin angeben')),
      );
      return;
    }
    final engine = AppScope.engineOf(context);
    final base = widget.existing ?? Pregnancy(id: newId(), dueDate: _due!);
    engine.savePregnancy(
      base.copyWith(
        dueDate: _due,
        name: _name.text.trim(),
        motherId: _mother,
        guardianIds: _guardians.toList(),
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Schwangerschaft entfernen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    AppScope.engineOf(context).deletePregnancy(widget.existing!.id);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final now = DateTime.now();
    return SectionPage(
      section: FamioSection.kids,
      title: widget.existing == null ? 'Schwangerschaft' : 'Bearbeiten',
      actions: [
        ColorButton(label: 'Speichern', color: _color, onPressed: _save),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name oder Spitzname (optional)',
              hintText: 'z. B. Krümel',
            ),
          ),
          const ListHeading('Errechneter Termin (ET)'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              InputChip(
                avatar: const Icon(AppIcons.calendarBlank, size: 18),
                label: Text(
                  _due == null ? 'Datum wählen' : _date.format(_due!),
                ),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _due ?? now.add(const Duration(days: 200)),
                    firstDate: now.subtract(const Duration(days: 60)),
                    lastDate: now.add(const Duration(days: 300)),
                  );
                  if (picked != null) setState(() => _due = picked);
                },
              ),
              ActionChip(
                avatar: const Icon(AppIcons.calendarDot, size: 18),
                label: const Text('Aus letzter Periode berechnen'),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    helpText: 'Erster Tag der letzten Periode',
                    initialDate: now.subtract(const Duration(days: 56)),
                    firstDate: now.subtract(const Duration(days: 300)),
                    lastDate: now,
                  );
                  if (picked != null) {
                    setState(
                      () => _due = DateTime(
                        picked.year,
                        picked.month,
                        picked.day + 280,
                      ),
                    );
                  }
                },
              ),
            ],
          ),
          if (_due != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'Heute: SSW ${weekLabel(Pregnancy(id: '', dueDate: _due!))}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const ListHeading('Wer ist schwanger?'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in engine.members)
                ChoiceChip(
                  avatar: MemberAvatar(m, radius: 10),
                  label: Text(m.displayName),
                  selected: _mother == m.id,
                  onSelected: (on) =>
                      setState(() => _mother = on ? m.id : null),
                ),
            ],
          ),
          const ListHeading('Wer sieht es?'),
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
              'Nur sie sehen die Schwangerschaft und werden an Termine '
              'erinnert – gut, wenn es noch eine Überraschung ist.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (widget.existing != null) ...[
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.trash, size: 18),
                label: const Text('Entfernen'),
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
