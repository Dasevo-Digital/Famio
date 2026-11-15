import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../data/recipe_import.dart';
import '../data/shopping_history.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';
import '../widgets/data_builder.dart';
import '../widgets/dispose_with.dart';
import '../widgets/files.dart';
import '../widgets/undo_delete.dart';
import 'documents_screen.dart' show categoryLook;
import 'meals_screens.dart' show showRecipeEditor;
import 'shopping_screens.dart' show newShoppingItem;

/// Unsorted family material: capture now, decide what it becomes later.
class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final color = FamioColors.of(context).strong(FamioSection.home);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.home,
      title: tr.inboxTitle,
      subtitle: tr.inboxSubtitle,
      floating: AddButton(
        color: color,
        tooltip: tr.inboxAdd,
        onPressed: () => _add(context),
      ),
      body: DataBuilder(
        collections: const {Collections.inbox, 'members'},
        builder: (context, engine) {
          final items = engine.inboxItems;
          if (items.isEmpty) {
            return EmptyHint(
              icon: AppIcons.clipboardList,
              color: color,
              text: tr.inboxEmpty,
              action: ColorButton(
                label: tr.inboxAdd,
                icon: AppIcons.plus,
                color: color,
                onPressed: () => _add(context),
              ),
            );
          }
          return ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SoftCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(AppIcons.clipboardList, color: color),
                      title: Text(item.title),
                      subtitle: Text(
                        [
                          if (item.text.isNotEmpty) item.text,
                          if (item.files.isNotEmpty)
                            tr.inboxFiles(item.files.length),
                          if (item.createdAt != null)
                            DateFormat.yMMMd(
                              appLanguage,
                            ).add_jm().format(item.createdAt!),
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<_InboxAction>(
                        tooltip: tr.inboxFileAs,
                        onSelected: (action) =>
                            _apply(context, engine, item, action),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: _InboxAction.task,
                            child: Text(tr.commonTask),
                          ),
                          if (item.files.isEmpty) ...[
                            PopupMenuItem(
                              value: _InboxAction.event,
                              child: Text(tr.commonEvent),
                            ),
                            PopupMenuItem(
                              value: _InboxAction.note,
                              child: Text(tr.commonNote),
                            ),
                          ],
                          if (item.files.isEmpty &&
                              _recipeLink(item) != null &&
                              !AppScope.read(
                                context,
                              ).hiddenModules.contains(FamioSection.meals.name))
                            PopupMenuItem(
                              value: _InboxAction.recipe,
                              child: Text(tr.commonRecipe),
                            ),
                          if (item.files.isNotEmpty)
                            PopupMenuItem(
                              value: _InboxAction.document,
                              child: Text(tr.commonDocument),
                            ),
                          if (item.files.isEmpty && item.text.trim().isEmpty)
                            PopupMenuItem(
                              value: _InboxAction.shopping,
                              child: Text(tr.inboxShoppingItem),
                            ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: _InboxAction.delete,
                            child: Text(tr.commonDelete),
                          ),
                        ],
                      ),
                      onTap: item.files.isEmpty
                          ? null
                          : () => openFileRef(
                              context,
                              item.files.first,
                              gallery: item.files,
                            ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static Future<void> _add(BuildContext context) async {
    final title = TextEditingController();
    final text = TextEditingController();
    PickedFile? picked;
    // Scanned letters are often about health or money: children see an
    // entry only when it is shared with them (GRU-084).
    var forChildren = false;
    final engine = AppScope.read(context).engine!;
    final children = engine.members.any(
      (m) => m.isChild && m.id != engine.memberId,
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => DisposeWith(
        controllers: [title, text],
        child: StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            scrollable: true,
            title: Text(tr.inboxAdd),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  autofocus: true,
                  decoration: InputDecoration(labelText: tr.commonTitle),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: text,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(labelText: tr.commonNotes),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(AppIcons.paperclip),
                  label: Text(picked?.name ?? tr.filesChooseFilePhoto),
                  onPressed: () async {
                    final file = await pickFile(context);
                    if (file != null) setState(() => picked = file);
                  },
                ),
                if (children)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr.inboxForChildren),
                    subtitle: Text(tr.inboxForChildrenHint),
                    value: forChildren,
                    onChanged: (on) => setState(() => forChildren = on),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr.commonCancel),
              ),
              // Nothing typed and no file: no empty entry (GRU-074).
              ListenableBuilder(
                listenable: Listenable.merge([title, text]),
                builder: (context, _) => FilledButton(
                  onPressed:
                      picked == null &&
                          title.text.trim().isEmpty &&
                          text.text.trim().isEmpty
                      ? null
                      : () => Navigator.pop(context, true),
                  child: Text(tr.commonSave),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true && context.mounted) {
      final state = AppScope.read(context);
      final messenger = ScaffoldMessenger.of(context);
      final typed = title.text.trim().isNotEmpty || text.text.trim().isNotEmpty;
      if (!typed && picked == null) return;
      final files = <FileRef>[];
      if (picked != null) {
        try {
          files.add(await uploadPicked(context, picked!));
        } on ApiError catch (e) {
          // What was typed stays, only the attachment is missing.
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                typed ? tr.inboxFileNotUploaded(e.message) : e.message,
              ),
            ),
          );
          if (!typed) return;
        }
      }
      final heading = title.text.trim().isNotEmpty
          ? title.text.trim()
          : _fallbackTitle(text.text, picked?.name);
      state.engine!.saveInboxItem(
        InboxItem(
          id: newId(),
          title: heading,
          text: text.text.trim(),
          files: files,
          createdAt: DateTime.now(),
          createdBy: state.me!.id,
          forChildren: forChildren,
        ),
      );
    }
  }

  static Future<void> _apply(
    BuildContext context,
    SyncEngine engine,
    InboxItem item,
    _InboxAction action,
  ) async {
    switch (action) {
      case _InboxAction.task:
        engine.saveTask(
          Task(
            id: newId(),
            title: item.title,
            notes: item.text,
            photos: item.files,
            createdAt: DateTime.now(),
          ),
        );
      case _InboxAction.event:
        final day = await showFamioDatePicker(
          context: context,
          initialDate: DateTime.now(),
          firstDate: DateTime.now().subtract(const Duration(days: 365)),
          lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
          helpText: tr.inboxEventDate,
        );
        if (day == null) return;
        final start = DateTime(day.year, day.month, day.day);
        engine.saveEvent(
          CalendarEvent(
            id: newId(),
            title: item.title,
            notes: item.text,
            start: start,
            end: start.add(const Duration(days: 1)),
            allDay: true,
          ),
        );
      case _InboxAction.note:
        engine.saveNote(
          FamilyNote(id: newId(), title: item.title, text: item.text),
        );
      case _InboxAction.recipe:
        // Stays in the inbox unless the recipe is saved.
        final saved = await showRecipeEditor(
          context,
          importFrom: _recipeLink(item),
        );
        if (!saved) return;
      case _InboxAction.document:
        // Its category and who sees it are decided here; it starts with
        // whom the inbox entry reached (GRU-079).
        final chosen = await showDialog<_DocumentChoice>(
          context: context,
          builder: (_) => _DocumentDialog(engine: engine, item: item),
        );
        if (chosen == null) return;
        for (final file in item.files) {
          engine.saveDocument(
            FamilyDocument(
              id: newId(),
              title: item.files.length == 1 ? item.title : file.name,
              category: chosen.category,
              file: file,
              notes: item.text,
              visibleTo: chosen.visibleTo,
              createdAt: DateTime.now(),
            ),
          );
        }
      case _InboxAction.shopping:
        if (item.text.trim().isNotEmpty || item.files.isNotEmpty) return;
        final list = await _pickShoppingList(context, engine);
        if (list == null) return;
        // Ticked off already: comes back instead of a second entry.
        engine.putOnList(newShoppingItem(engine, list.id, item.title));
      case _InboxAction.delete:
        // Gone at once, but "Rückgängig" brings it back (GRU-082).
        deleteWithUndo(
          context,
          what: item.title,
          collections: const {Collections.inbox},
          delete: () => engine.deleteInboxItem(item.id),
        );
        return;
    }
    engine.deleteInboxItem(item.id);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.inboxFiled)));
    }
  }
}

enum _InboxAction { task, event, note, recipe, document, shopping, delete }

typedef _DocumentChoice = ({
  DocumentCategory category,
  List<String>? visibleTo,
});

enum _Audience { family, adults, me }

/// Category and audience of the documents an inbox entry becomes.
class _DocumentDialog extends StatefulWidget {
  const _DocumentDialog({required this.engine, required this.item});

  final SyncEngine engine;
  final InboxItem item;

  @override
  State<_DocumentDialog> createState() => _DocumentDialogState();
}

class _DocumentDialogState extends State<_DocumentDialog> {
  var _category = DocumentCategory.other;

  /// Whom the entry reached: everyone when shared with the children, else
  /// the adults (and the child who filed it).
  late var _audience = widget.item.forChildren
      ? _Audience.family
      : _Audience.adults;
  var _chosen = false;

  SyncEngine get _engine => widget.engine;

  /// A child keeps health documents among the people it chooses; the
  /// server refuses them for the whole family.
  bool get _familyAllowed =>
      !(_engine.myRole == MemberRole.child &&
          _category == DocumentCategory.health);

  List<String>? get _visibleTo => switch (_audience) {
    _Audience.family => null,
    _Audience.me => [_engine.memberId],
    _Audience.adults => {
      for (final m in _engine.members)
        if (m.isAdult) m.id,
      _engine.memberId,
      if (_engine.member(widget.item.createdBy ?? '') case final m?
          when m.isChild)
        m.id,
    }.toList(),
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(tr.inboxDocumentTitle),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListHeading(tr.commonCategory),
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
                onSelected: (_) => setState(() {
                  _category = cat;
                  // A letter from the doctor starts out as the author's, as
                  // in the document editor.
                  if (!_chosen && cat == DocumentCategory.health) {
                    _audience = _Audience.me;
                  }
                  if (!_familyAllowed && _audience == _Audience.family) {
                    _audience = _Audience.me;
                  }
                }),
              ),
          ],
        ),
        ListHeading(tr.commonWhoMaySee),
        RadioGroup<_Audience>(
          groupValue: _audience,
          onChanged: (v) => setState(() {
            _audience = v!;
            _chosen = true;
          }),
          child: Column(
            children: [
              RadioListTile(
                value: _Audience.family,
                enabled: _familyAllowed,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.commonWholeFamily),
                secondary: const Icon(AppIcons.usersThree),
              ),
              RadioListTile(
                value: _Audience.adults,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.inboxDocumentAdults),
                secondary: const Icon(AppIcons.userList),
              ),
              RadioListTile(
                value: _Audience.me,
                contentPadding: EdgeInsets.zero,
                title: Text(tr.docsOnlyMe),
                secondary: const Icon(AppIcons.lockKey),
              ),
            ],
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr.commonCancel),
      ),
      FilledButton(
        onPressed: () => Navigator.pop<_DocumentChoice>(context, (
          category: _category,
          visibleTo: _visibleTo,
        )),
        child: Text(tr.commonSave),
      ),
    ],
  );
}

Uri? _recipeLink(InboxItem item) => linkIn('${item.title}\n${item.text}');

String _fallbackTitle(String text, String? fileName) {
  final line = text.trim().split(RegExp(r'\r?\n')).firstOrNull ?? '';
  if (line.isNotEmpty) {
    return line.length <= 100 ? line : '${line.substring(0, 99)}…';
  }
  if (fileName != null && fileName.isNotEmpty) return fileName;
  return tr.inboxUntitled;
}

Future<ShoppingList?> _pickShoppingList(
  BuildContext context,
  SyncEngine engine,
) {
  final lists = engine.shoppingLists.where((list) => !list.packing).toList();
  if (lists.isEmpty) {
    final list = ShoppingList(id: newId(), name: tr.sectionShopping);
    engine.saveShoppingList(list);
    return Future.value(list);
  }
  if (lists.length == 1) return Future.value(lists.single);
  return showDialog<ShoppingList>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(tr.shareWhichList),
      children: [
        for (final list in lists)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, list),
            child: Text(list.name),
          ),
      ],
    ),
  );
}
