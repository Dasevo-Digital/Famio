import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/palette.dart';
import '../l10n.dart';
import '../platform/opened_files.dart';
import '../widgets/files.dart';
import 'documents_screen.dart';
import 'notes_screen.dart';
import 'shopping_screens.dart';
import 'tasks_screen.dart';

enum _Target { shopping, task, note, document, chat }

/// "Teilen an Famio": text, a link or files from another app go to the
/// shopping list (one item per line), a new task or note, the documents
/// or the family chat. [go] switches to a section, [navigatorOf] gives its
/// page stack.
Future<void> showShareTarget(
  BuildContext context,
  SharedContent share, {
  required void Function(FamioSection section) go,
  required NavigatorState? Function(FamioSection section) navigatorOf,
}) async {
  final state = AppScope.read(context);
  final me = state.me;
  final engine = state.engine;
  if (me == null || engine == null) return;
  final lines = shareLines(share.text);
  final files = share.files;
  final target = await showModalBottomSheet<_Target>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (context) {
      final c = FamioColors.of(context);
      ListTile option(
        _Target t,
        IconData icon,
        FamioSection s,
        String title, [
        String? subtitle,
      ]) => ListTile(
        leading: Icon(icon, color: c.strong(s)),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        onTap: () => Navigator.pop(context, t),
      );
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  tr.shareTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  [
                    if (share.subject.isNotEmpty) share.subject,
                    if (share.text.isNotEmpty) share.text,
                    ...files.map((f) => '📎 ${f.name}'),
                  ].join('\n'),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (files.isEmpty && lines.isNotEmpty)
                option(
                  _Target.shopping,
                  AppIcons.basket,
                  FamioSection.shopping,
                  tr.shareToShopping,
                  tr.shareItems(lines.length),
                ),
              option(
                _Target.task,
                AppIcons.checkSquareOffset,
                FamioSection.tasks,
                tr.shareAsTask,
              ),
              if (files.isEmpty)
                option(
                  _Target.note,
                  AppIcons.note,
                  FamioSection.home,
                  tr.shareAsNote,
                ),
              if (files.isNotEmpty && !me.isGuest)
                option(
                  _Target.document,
                  AppIcons.folderSimpleStar,
                  FamioSection.documents,
                  tr.shareAsDocument,
                  tr.shareFiles(files.length),
                ),
              option(
                _Target.chat,
                AppIcons.chatsCircle,
                FamioSection.chat,
                tr.shareToChat,
              ),
            ],
          ),
        ),
      );
    },
  );
  if (target == null || !context.mounted) {
    _cleanUp(files);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  try {
    switch (target) {
      case _Target.shopping:
        final list = await _pickList(context, engine);
        if (list == null) break;
        for (final line in lines) {
          engine.saveShoppingItem(newShoppingItem(engine, list.id, line));
        }
        go(FamioSection.shopping);
        messenger.showSnackBar(
          SnackBar(content: Text(tr.shareAddedToList(lines.length, list.name))),
        );
      case _Target.task:
        final refs = await _upload(context, files);
        if (refs == null || !context.mounted) break;
        final (title, notes) = _titleAndNotes(share);
        go(FamioSection.tasks);
        await WidgetsBinding.instance.endOfFrame;
        if (!context.mounted) break;
        await showTaskEditor(
          context,
          draft: Task(
            id: newId(),
            title: title,
            notes: notes,
            photos: refs,
            createdAt: DateTime.now(),
          ),
        );
      case _Target.note:
        final (title, text) = _titleAndNotes(share);
        await showNoteEditor(
          context,
          draft: FamilyNote(id: newId(), title: title, text: text),
        );
      case _Target.document:
        go(FamioSection.documents);
        await WidgetsBinding.instance.endOfFrame;
        for (final f in files) {
          final bytes = await File(f.path).readAsBytes();
          final navigator = navigatorOf(FamioSection.documents);
          if (navigator == null) break;
          await navigator.push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  DocumentEditor(picked: PickedFile(bytes, f.name, f.mime)),
            ),
          );
        }
      case _Target.chat:
        final refs = await _upload(context, files);
        if (refs == null) break;
        final text = [
          share.subject,
          share.text,
        ].where((s) => s.trim().isNotEmpty).join('\n');
        if (refs.isEmpty) {
          engine.sendChatMessage(ChatIds.family, text: text);
        }
        for (final (i, ref) in refs.indexed) {
          engine.sendChatMessage(
            ChatIds.family,
            text: i == 0 ? text : '',
            attachment: ref,
          );
        }
        go(FamioSection.chat);
        messenger.showSnackBar(SnackBar(content: Text(tr.shareSent)));
    }
  } on ApiError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } finally {
    _cleanUp(files);
  }
}

/// One shopping item per line, without bullets, numbering or check boxes
/// ("- Milch", "2. Brot", "[ ] Eier", "☐ Butter").
List<String> shareLines(String text) => [
  for (final line in text.split(RegExp(r'\r?\n')))
    if (line
            .replaceFirst(
              RegExp(r'^\s*(?:[-*•·▪◦–]|\d+[.)]|\[[ xX]?\]|[☐☑✓✔])\s*'),
              '',
            )
            .trim()
        case final item when item.isNotEmpty)
      item,
].take(100).toList();

/// The subject or the first line as title, the rest as notes.
(String, String) _titleAndNotes(SharedContent share) {
  final text = share.text.trim();
  if (share.subject.trim().isNotEmpty) return (share.subject.trim(), text);
  final lines = text.split(RegExp(r'\r?\n'));
  final first = lines.first.trim();
  if (first.isNotEmpty) {
    final rest = lines.skip(1).join('\n').trim();
    return first.length <= 100
        ? (first, rest)
        : ('${first.substring(0, 99)}…', text);
  }
  if (share.files.isNotEmpty) {
    final name = share.files.first.name;
    final dot = name.lastIndexOf('.');
    return (dot > 0 ? name.substring(0, dot) : name, '');
  }
  return (tr.shareShared, '');
}

Future<ShoppingList?> _pickList(BuildContext context, SyncEngine engine) {
  final lists = [
    for (final l in engine.shoppingLists)
      if (!l.packing) l,
  ];
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
        for (final l in lists)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, l),
            child: Text(l.name),
          ),
      ],
    ),
  );
}

/// Uploads the shared files behind a progress dialog; null on failure.
Future<List<FileRef>?> _upload(
  BuildContext context,
  List<SharedFile> files,
) async {
  if (files.isEmpty) return const [];
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: Text(tr.shareUploading)),
        ],
      ),
    ),
  );
  final state = AppScope.read(context);
  try {
    return [for (final f in files) await _uploadOne(state, f)];
  } finally {
    navigator.pop();
  }
}

/// Like uploadPicked, keeping a local copy so it opens instantly.
Future<FileRef> _uploadOne(AppState state, SharedFile f) async {
  final bytes = await File(f.path).readAsBytes();
  final ref = await state.engine!.api.uploadFile(
    bytes: bytes,
    name: f.name,
    mime: f.mime,
  );
  state.files?.put(ref, bytes);
  return ref;
}

void _cleanUp(List<SharedFile> files) {
  for (final f in files) {
    try {
      File(f.path).deleteSync();
    } on FileSystemException {
      // Already gone; the cache is cleaned by Android anyway.
    }
  }
}
