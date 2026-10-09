import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

/// Paper colours of the pinboard.
const noteColors = [
  0xFFFFF3B0, // yellow
  0xFFFFD6E4, // pink
  0xFFD3EBFF, // blue
  0xFFD9F0E4, // green
  0xFFE6DDF7, // lilac
];

/// The family's pinboard: notes everyone (or who is chosen) can read,
/// pinned ones also on the start page.
class NotesScreen extends StatelessWidget {
  const NotesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {Collections.notes, 'members'},
      builder: (context, engine) {
        final notes = engine.notes;
        final canWrite = !engine.iAmGuest;
        final c = FamioColors.of(context);
        return SectionPage(
          section: FamioSection.home,
          title: tr.commonPinboard,
          subtitle: tr.notesNotesFamily,
          maxBodyWidth: 960,
          floating: canWrite
              ? AddButton(
                  color: c.strong(FamioSection.home),
                  tooltip: tr.notesAddNote,
                  icon: AppIcons.plus,
                  onPressed: () => showNoteEditor(context),
                )
              : null,
          body: notes.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(tr.notesNoNotesYetExample),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 900
                        ? 3
                        : constraints.maxWidth >= 560
                        ? 2
                        : 1;
                    return GridView.count(
                      crossAxisCount: columns,
                      childAspectRatio: columns == 1 ? 2.2 : 1.2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      padding: EdgeInsets.only(
                        top: 8,
                        bottom: listBottomPadding(context),
                      ),
                      children: [
                        for (final n in notes)
                          _NoteCard(note: n, canWrite: canWrite),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, required this.canWrite});

  final FamilyNote note;
  final bool canWrite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final paper = Color(note.color ?? noteColors.first);
    return Material(
      color: dark ? Color.lerp(paper, Colors.black, 0.6) : paper,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: canWrite ? () => showNoteEditor(context, note: note) : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (note.pinned) const Icon(AppIcons.note, size: 18),
                  if (note.visibleTo != null) ...[
                    const SizedBox(width: 4),
                    const Icon(AppIcons.lockKey, size: 16),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: SelectableText(
                  note.text,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showNoteEditor(BuildContext context, {FamilyNote? note}) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => _NoteEditor(note: note),
    );

enum _Audience { family, me, selected }

class _NoteEditor extends StatefulWidget {
  const _NoteEditor({this.note});

  final FamilyNote? note;

  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  late final _title = TextEditingController(text: widget.note?.title);
  late final _text = TextEditingController(text: widget.note?.text);
  late var _pinned = widget.note?.pinned ?? true;
  late var _color = widget.note?.color ?? noteColors.first;
  late var _audience = widget.note?.visibleTo == null
      ? _Audience.family
      : _Audience.selected;
  late final _members = {...?widget.note?.visibleTo};

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final engine = AppScope.engineOf(context);
    engine.saveNote(
      FamilyNote(
        id: widget.note?.id ?? newId(),
        title: title,
        text: _text.text.trim(),
        pinned: _pinned,
        color: _color,
        visibleTo: switch (_audience) {
          _Audience.family => null,
          _Audience.me => [engine.memberId],
          _Audience.selected => {..._members, engine.memberId}.toList(),
        },
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final others = [
      for (final m in engine.members)
        if (m.id != engine.memberId) m,
    ];
    final note = widget.note;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              note == null ? tr.notesNewNote : tr.notesEditNote,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: note == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: tr.commonTitle,
                hintText: tr.notesEGWiFi,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 3,
              maxLines: 10,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr.commonText),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final color in noteColors)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _color = color),
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: Color(color),
                        child: _color == color
                            ? const Icon(
                                AppIcons.check,
                                size: 16,
                                color: Colors.black87,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr.notesPinStartPage),
              value: _pinned,
              onChanged: (v) => setState(() => _pinned = v),
            ),
            ListHeading(tr.commonWhoMaySee),
            RadioGroup<_Audience>(
              groupValue: _audience,
              onChanged: (v) => setState(() => _audience = v!),
              child: Column(
                children: [
                  RadioListTile(
                    value: _Audience.family,
                    title: Text(tr.notesWholeFamilyGuestsToo),
                  ),
                  RadioListTile(
                    value: _Audience.me,
                    title: Text(tr.docsOnlyMe),
                  ),
                  if (others.isNotEmpty)
                    RadioListTile(
                      value: _Audience.selected,
                      title: Text(tr.docsMe),
                    ),
                ],
              ),
            ),
            if (_audience == _Audience.selected)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in others)
                    FilterChip(
                      avatar: MemberAvatar(m, radius: 10),
                      label: Text(m.displayName),
                      selected: _members.contains(m.id),
                      onSelected: (on) => setState(
                        () => on ? _members.add(m.id) : _members.remove(m.id),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (note != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash),
                    label: Text(tr.commonDelete),
                    onPressed: () {
                      Navigator.pop(context);
                      deleteWithUndo(
                        context,
                        what: note.title,
                        collections: const {Collections.notes},
                        delete: () => engine.deleteNote(note.id),
                      );
                    },
                  ),
                const Spacer(),
                FilledButton(onPressed: _save, child: Text(tr.commonSave)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
