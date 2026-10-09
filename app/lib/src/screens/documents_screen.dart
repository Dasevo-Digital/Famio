import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/files.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

(IconData, Color) categoryLook(DocumentCategory c) => switch (c) {
  DocumentCategory.identity => (
    AppIcons.identificationCard,
    const Color(0xFF3587D6),
  ),
  DocumentCategory.health => (AppIcons.firstAidKit, const Color(0xFFDB4A7E)),
  DocumentCategory.school => (AppIcons.backpack, const Color(0xFFE89B1A)),
  DocumentCategory.insurance => (AppIcons.umbrella, const Color(0xFF1AA3A3)),
  DocumentCategory.finance => (AppIcons.piggyBank, const Color(0xFF2A9D6E)),
  DocumentCategory.home => (AppIcons.houseLine, const Color(0xFFE8703A)),
  DocumentCategory.contracts => (AppIcons.signature, const Color(0xFF7B5BE0)),
  DocumentCategory.photos => (AppIcons.images, const Color(0xFFDB4A7E)),
  DocumentCategory.other => (AppIcons.folderOpen, const Color(0xFFB07A3C)),
};

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  DocumentCategory? _category;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final picked = await pickFile(context);
    if (picked == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DocumentEditor(picked: picked, category: _category),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.documents);
    return SectionPage(
      section: FamioSection.documents,
      title: 'Dokumente',
      subtitle: 'Wichtiges sicher an einem Ort',
      actions: const [SyncStatusIcon()],
      floating: AddButton(
        color: color,
        tooltip: 'Dokument hinzufügen',
        onPressed: _add,
      ),
      body: DataBuilder(
        collections: const {Collections.documents, 'members'},
        builder: (context, engine) {
          final all = engine.documents;
          final query = _search.text.trim().toLowerCase();
          final shown = all.where((d) {
            if (_category != null && d.category != _category) return false;
            if (query.isEmpty) return true;
            return d.title.toLowerCase().contains(query) ||
                d.notes.toLowerCase().contains(query) ||
                (d.file?.name.toLowerCase().contains(query) ?? false);
          }).toList();
          final used = {for (final d in all) d.category};

          return Column(
            children: [
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Suchen …',
                  prefixIcon: Icon(AppIcons.magnifyingGlass, size: 20),
                ),
              ),
              const SizedBox(height: 12),
              PillTabs<DocumentCategory?>(
                values: [null, ...DocumentCategory.values.where(used.contains)],
                selected: _category,
                label: (c) => c?.label ?? 'Alle (${all.length})',
                color: color,
                onChanged: (c) => setState(() => _category = c),
              ),
              Expanded(
                child: shown.isEmpty
                    ? EmptyHint(
                        icon: AppIcons.folderSimpleStar,
                        color: color,
                        text: all.isEmpty
                            ? 'Ausweise, Arztbriefe, Zeugnisse, Verträge –\nhier findet ihr alles wieder.'
                            : 'Nichts gefunden.',
                        action: all.isEmpty
                            ? ColorButton(
                                label: 'Erstes Dokument hinzufügen',
                                color: color,
                                onPressed: _add,
                              )
                            : null,
                      )
                    : ListView.separated(
                        padding: EdgeInsets.only(
                          top: 16,
                          bottom: listBottomPadding(context),
                        ),
                        itemCount: shown.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, i) =>
                            _DocumentCard(document: shown[i], engine: engine),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({required this.document, required this.engine});

  final FamilyDocument document;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final (icon, color) = categoryLook(document.category);
    final expires = document.expiresAt;
    final soon =
        expires != null &&
        expires.isBefore(DateTime.now().add(const Duration(days: 90)));
    final about = [for (final id in document.memberIds) ?engine.member(id)];
    final restricted = document.visibleTo != null;

    return SoftCard(
      padding: const EdgeInsets.all(14),
      onTap: () => _showDetails(context),
      child: Row(
        children: [
          document.file != null && document.file!.isImage
              ? SizedBox.square(
                  dimension: 52,
                  child: CachedImage(document.file!, thumb: 160, radius: 16),
                )
              : IconBlob(icon, color: color, size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        document.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    if (restricted)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Tooltip(
                          message:
                              'Sichtbar für: ${_names(engine, document.visibleTo!)}',
                          child: Icon(
                            AppIcons.lock,
                            size: 15,
                            color: c.inkSoft,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    document.category.label,
                    if (document.file != null)
                      fileSizeLabel(document.file!.size),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
                if (expires != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: soon
                            ? theme.colorScheme.errorContainer
                            : c.surfaceSoft,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${expires.isBefore(DateTime.now()) ? 'Abgelaufen am' : 'Gültig bis'} '
                        '${DateFormat.yMd(appLanguage).format(expires)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: soon
                              ? theme.colorScheme.onErrorContainer
                              : c.inkSoft,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (final m in about.take(3))
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: MemberAvatar(m, radius: 13),
            ),
        ],
      ),
    );
  }

  static String _names(SyncEngine engine, List<String> ids) =>
      [for (final id in ids) engine.member(id)?.displayName ?? '?'].join(', ');

  void _showDetails(BuildContext context) {
    final file = document.file;
    final (icon, color) = categoryLook(document.category);
    showModalBottomSheet<void>(
      context: context,
      // Above the floating navigation bar.
      useRootNavigator: true,
      isScrollControlled: true,
      // Below the status bar, so the handle stays reachable.
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconBlob(icon, color: color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      document.title,
                      style: Theme.of(sheet).textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (file != null && file.isImage)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: CachedImage(file, thumb: 1280, fit: BoxFit.contain),
                ),
              if (document.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(document.notes),
              ],
              const SizedBox(height: 12),
              Text(
                document.visibleTo == null
                    ? 'Sichtbar für die ganze Familie'
                    : 'Sichtbar für: ${_names(engine, document.visibleTo!)}',
                style: Theme.of(sheet).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (file != null)
                    ColorButton(
                      label: 'Öffnen',
                      icon: AppIcons.arrowSquareOut,
                      color: color,
                      onPressed: () => openFileRef(context, file),
                    ),
                  OutlinedButton.icon(
                    icon: const Icon(AppIcons.pencilSimple, size: 18),
                    label: const Text('Bearbeiten'),
                    onPressed: () {
                      Navigator.pop(sheet);
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DocumentEditor(existing: document),
                        ),
                      );
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: const Text('Löschen'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(sheet).colorScheme.error,
                    ),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: sheet,
                        builder: (d) => AlertDialog(
                          title: Text('„${document.title}“ löschen?'),
                          content: const Text(
                            'Das Dokument wird für alle entfernt.',
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
                      if (ok == true && sheet.mounted) {
                        deleteWithUndo(
                          sheet,
                          what: document.title,
                          collections: const {Collections.documents},
                          delete: () => engine.deleteDocument(document.id),
                        );
                        Navigator.pop(sheet);
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Visibility { family, me, selected }

/// Create (from a freshly picked file) or edit a document.
class DocumentEditor extends StatefulWidget {
  const DocumentEditor({super.key, this.picked, this.existing, this.category});

  final PickedFile? picked;
  final FamilyDocument? existing;
  final DocumentCategory? category;

  @override
  State<DocumentEditor> createState() => _DocumentEditorState();
}

class _DocumentEditorState extends State<DocumentEditor> {
  late final _title = TextEditingController(
    text: widget.existing?.title ?? _titleFromName(widget.picked?.name ?? ''),
  );
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late var _category =
      widget.existing?.category ?? widget.category ?? DocumentCategory.other;
  late final _about = {...?widget.existing?.memberIds};
  late DateTime? _expires = widget.existing?.expiresAt;
  late var _visibility = widget.existing?.visibleTo == null
      ? _Visibility.family
      : _Visibility.selected;
  late final _audience = {...?widget.existing?.visibleTo};
  var _saving = false;

  static String _titleFromName(String name) {
    final dot = name.lastIndexOf('.');
    return (dot > 0 ? name.substring(0, dot) : name)
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim();
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) return;
    final engine = AppScope.engineOf(context);
    setState(() => _saving = true);
    try {
      final file = widget.picked == null
          ? widget.existing?.file
          : await uploadPicked(context, widget.picked!);
      final visibleTo = switch (_visibility) {
        _Visibility.family => null,
        _Visibility.me => [engine.memberId],
        _Visibility.selected => {..._audience, engine.memberId}.toList(),
      };
      engine.saveDocument(
        FamilyDocument(
          id: widget.existing?.id ?? newId(),
          title: _title.text.trim(),
          category: _category,
          file: file,
          notes: _notes.text.trim(),
          memberIds: _about.toList(),
          expiresAt: _expires,
          visibleTo: visibleTo,
          createdAt: widget.existing?.createdAt ?? DateTime.now(),
        ),
      );
      if (mounted) Navigator.pop(context);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.documents);
    final theme = Theme.of(context);
    final others = engine.members
        .where((m) => m.id != engine.memberId)
        .toList();
    final fileName = widget.picked?.name ?? widget.existing?.file?.name;

    return SectionPage(
      section: FamioSection.documents,
      title: widget.existing == null ? 'Neues Dokument' : 'Dokument bearbeiten',
      subtitle: fileName,
      actions: [
        _saving
            ? const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              )
            : ColorButton(label: 'Speichern', color: color, onPressed: _save),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Titel'),
          ),
          const ListHeading('Kategorie'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final cat in DocumentCategory.values)
                ChoiceChip(
                  avatar: Icon(
                    categoryLook(cat).$1,
                    size: 18,
                    color: categoryLook(cat).$2,
                  ),
                  label: Text(cat.label),
                  selected: _category == cat,
                  selectedColor: categoryLook(cat).$2.withValues(alpha: 0.2),
                  onSelected: (_) => setState(() => _category = cat),
                ),
            ],
          ),
          const ListHeading('Wen betrifft es?'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in engine.members)
                FilterChip(
                  avatar: MemberAvatar(m, radius: 10),
                  label: Text(m.displayName),
                  selected: _about.contains(m.id),
                  onSelected: (on) => setState(
                    () => on ? _about.add(m.id) : _about.remove(m.id),
                  ),
                ),
            ],
          ),
          const ListHeading('Gültig bis (optional)'),
          Align(
            alignment: Alignment.centerLeft,
            child: InputChip(
              avatar: const Icon(AppIcons.calendarX, size: 18),
              label: Text(
                _expires == null
                    ? 'Kein Ablaufdatum'
                    : DateFormat.yMMMMd(appLanguage).format(_expires!),
              ),
              onPressed: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _expires ?? now.add(const Duration(days: 365)),
                  firstDate: DateTime(now.year - 10),
                  lastDate: DateTime(now.year + 30),
                );
                if (picked != null) setState(() => _expires = picked);
              },
              onDeleted: _expires == null
                  ? null
                  : () => setState(() => _expires = null),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Famio erinnert rechtzeitig vor dem Ablauf (z. B. beim Reisepass).',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const ListHeading('Wer darf es sehen?'),
          SoftCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: RadioGroup<_Visibility>(
              groupValue: _visibility,
              onChanged: (v) => setState(() => _visibility = v!),
              child: Column(
                children: [
                  const RadioListTile(
                    value: _Visibility.family,
                    title: Text('Ganze Familie'),
                    secondary: Icon(AppIcons.usersThree),
                  ),
                  const RadioListTile(
                    value: _Visibility.me,
                    title: Text('Nur ich'),
                    secondary: Icon(AppIcons.lockKey),
                  ),
                  if (others.isNotEmpty)
                    const RadioListTile(
                      value: _Visibility.selected,
                      title: Text('Ich und …'),
                      secondary: Icon(AppIcons.userList),
                    ),
                ],
              ),
            ),
          ),
          if (_visibility == _Visibility.selected) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in others)
                  FilterChip(
                    avatar: MemberAvatar(m, radius: 10),
                    label: Text(m.displayName),
                    selected: _audience.contains(m.id),
                    onSelected: (on) => setState(
                      () => on ? _audience.add(m.id) : _audience.remove(m.id),
                    ),
                  ),
              ],
            ),
          ],
          const ListHeading('Notizen'),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'z. B. Ausweisnummer, Ansprechpartner …',
            ),
          ),
        ],
      ),
    );
  }
}
