import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';
import '../widgets/data_builder.dart';
import '../widgets/files.dart';
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
                          if (item.files.isNotEmpty)
                            PopupMenuItem(
                              value: _InboxAction.document,
                              child: Text(tr.commonDocument),
                            ),
                          if (item.files.isEmpty)
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
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
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.commonSave),
            ),
          ],
        ),
      ),
    );
    if (ok == true && context.mounted) {
      final state = AppScope.read(context);
      final files = [if (picked != null) await uploadPicked(context, picked!)];
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
        ),
      );
    }
    title.dispose();
    text.dispose();
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
        final day = await showDatePicker(
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
      case _InboxAction.document:
        for (final file in item.files) {
          engine.saveDocument(
            FamilyDocument(
              id: newId(),
              title: item.files.length == 1 ? item.title : file.name,
              category: DocumentCategory.other,
              file: file,
              notes: item.text,
              createdAt: DateTime.now(),
            ),
          );
        }
      case _InboxAction.shopping:
        final list = await _pickShoppingList(context, engine);
        if (list == null) return;
        engine.saveShoppingItem(newShoppingItem(engine, list.id, item.title));
      case _InboxAction.delete:
        engine.deleteInboxItem(item.id);
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

enum _InboxAction { task, event, note, document, shopping, delete }

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
