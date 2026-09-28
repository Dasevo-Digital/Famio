import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import 'list_templates.dart';
import 'pantry_screens.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/dispose_with.dart';
import '../widgets/sync_status_icon.dart';

const _shopping = {
  Collections.shoppingLists,
  Collections.shoppingItems,
  Collections.pantryItems,
};

class ShoppingListsScreen extends StatelessWidget {
  const ShoppingListsScreen({super.key});

  Future<void> _create(BuildContext context) async {
    final name = await _askName(context, title: 'Neue Einkaufsliste');
    if (name == null || !context.mounted) return;
    final engine = AppScope.engineOf(context);
    final list = ShoppingList(
      id: newId(),
      name: name,
      sort: engine.shoppingLists.length,
    );
    engine.saveShoppingList(list);
    _open(context, list.id);
  }

  void _open(BuildContext context, String listId) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ShoppingListScreen(listId: listId)),
  );

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.shopping);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.shopping,
      title: 'Einkauf',
      subtitle: 'Was brauchen wir?',
      actions: [
        BubbleButton(
          icon: AppIcons.template,
          tooltip: 'Liste aus Vorlage',
          onPressed: () => showTemplatePicker(context),
        ),
        const SyncStatusIcon(),
      ],
      floating: AddButton(
        color: color,
        tooltip: 'Neue Liste',
        onPressed: () => _create(context),
      ),
      body: DataBuilder(
        collections: _shopping,
        builder: (context, engine) {
          final lists = engine.shoppingLists;
          if (lists.isEmpty) {
            return ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: PantryCard(),
                ),
                EmptyHint(
                  icon: AppIcons.basket,
                  color: color,
                  text: 'Noch keine Einkaufsliste.',
                  action: ColorButton(
                    label: 'Erste Liste anlegen',
                    color: color,
                    onPressed: () => _create(context),
                  ),
                ),
              ],
            );
          }
          return ListView.separated(
            padding: EdgeInsets.only(
              top: 8,
              bottom: listBottomPadding(context),
            ),
            itemCount: lists.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              if (i == 0) return const PantryCard();
              final list = lists[i - 1];
              final items = engine.shoppingItems(list.id);
              final open = items.where((i) => !i.checked).length;
              return SoftCard(
                onTap: () => _open(context, list.id),
                child: Row(
                  children: [
                    IconBlob(
                      AppIcons.shoppingCartSimple,
                      color: color,
                      size: 52,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            list.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            open == 0
                                ? (items.isEmpty ? 'Leer' : 'Alles im Wagen ✓')
                                : '$open offen',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (open > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: c.tint(FamioSection.shopping),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '$open',
                          style: Theme.of(
                            context,
                          ).textTheme.labelLarge?.copyWith(color: color),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ShoppingListScreen extends StatefulWidget {
  const ShoppingListScreen({super.key, required this.listId});

  final String listId;

  @override
  State<ShoppingListScreen> createState() => _ShoppingListScreenState();
}

class _ShoppingListScreenState extends State<ShoppingListScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// A leading count becomes the quantity: "3 Äpfel", "3x Äpfel".
  void _add(SyncEngine engine) {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final match = RegExp(r'^(\d+)\s*[xX]?\s+(.+)$').firstMatch(text);
    engine.saveShoppingItem(
      ShoppingItem(
        id: newId(),
        listId: widget.listId,
        name: match?.group(2) ?? text,
        quantity: match?.group(1) ?? '',
      ),
    );
    _input.clear();
    _focus.requestFocus();
  }

  Future<void> _rename(SyncEngine engine, ShoppingList list) async {
    final name = await _askName(
      context,
      title: 'Liste umbenennen',
      initial: list.name,
    );
    if (name != null) engine.saveShoppingList(list.copyWith(name: name));
  }

  void _saveTemplate(SyncEngine engine, ShoppingList list) {
    engine.templateFromList(list);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('„${list.name}“ als Vorlage gespeichert')),
    );
  }

  Future<void> _deleteList(SyncEngine engine, ShoppingList list) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('„${list.name}“ löschen?'),
        content: const Text('Die Liste und alle Einträge werden gelöscht.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.pop(context);
    engine.deleteShoppingList(list.id);
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.shopping);
    return DataBuilder(
      collections: _shopping,
      builder: (context, engine) {
        final list = engine.shoppingList(widget.listId);
        if (list == null) {
          return const SectionPage(
            maxBodyWidth: 960,
            section: FamioSection.shopping,
            title: 'Einkauf',
            body: Center(child: Text('Diese Liste gibt es nicht mehr.')),
          );
        }
        final items = engine.shoppingItems(list.id);
        final open = items.where((i) => !i.checked).toList();
        final done = items.where((i) => i.checked).toList();

        return SectionPage(
          maxBodyWidth: 960,
          section: FamioSection.shopping,
          title: list.name,
          subtitle: open.isEmpty ? 'Alles erledigt' : '${open.length} offen',
          actions: [
            const SyncStatusIcon(),
            PopupMenuButton<String>(
              tooltip: 'Mehr',
              icon: const Icon(AppIcons.dotsThreeVertical),
              onSelected: (action) => switch (action) {
                'clear' => [
                  for (final i in done) engine.deleteShoppingItem(i.id),
                ],
                'uncheck' => [
                  for (final i in done)
                    engine.saveShoppingItem(i.copyWith(checked: false)),
                ],
                'template' => _saveTemplate(engine, list),
                'rename' => _rename(engine, list),
                'delete' => _deleteList(engine, list),
                _ => null,
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'clear',
                  enabled: done.isNotEmpty,
                  child: const Text('Erledigte entfernen'),
                ),
                PopupMenuItem(
                  value: 'uncheck',
                  enabled: done.isNotEmpty,
                  child: const Text('Alle Haken entfernen'),
                ),
                PopupMenuItem(
                  value: 'template',
                  enabled: items.isNotEmpty,
                  child: const Text('Als Vorlage speichern'),
                ),
                const PopupMenuItem(value: 'rename', child: Text('Umbenennen')),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Liste löschen'),
                ),
              ],
            ),
          ],
          body: Column(
            children: [
              TextField(
                controller: _input,
                focusNode: _focus,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Artikel hinzufügen, z. B. „2 Milch“',
                  prefixIcon: const Icon(AppIcons.plus, size: 20),
                  suffixIcon: Padding(
                    padding: const EdgeInsets.all(6),
                    child: BubbleButton(
                      icon: AppIcons.arrowUp,
                      tooltip: 'Hinzufügen',
                      color: Colors.white,
                      background: color,
                      size: 38,
                      onPressed: () => _add(engine),
                    ),
                  ),
                ),
                onSubmitted: (_) => _add(engine),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.only(
                    top: 12,
                    bottom: listBottomPadding(context),
                  ),
                  children: [
                    for (final item in open)
                      _ItemTile(item: item, engine: engine),
                    if (done.isNotEmpty) ...[
                      ListHeading('Im Wagen (${done.length})', color: color),
                      for (final item in done)
                        _ItemTile(item: item, engine: engine),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.engine});

  final ShoppingItem item;
  final SyncEngine engine;

  Future<void> _edit(BuildContext context) async {
    final name = TextEditingController(text: item.name);
    final quantity = TextEditingController(text: item.quantity);
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => DisposeWith(
        controllers: [name, quantity],
        child: AlertDialog(
          title: const Text('Artikel bearbeiten'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Artikel'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: quantity,
                decoration: const InputDecoration(
                  labelText: 'Menge',
                  hintText: 'z. B. 2, 500 g, 1 Packung',
                ),
                onSubmitted: (_) => Navigator.pop(context, true),
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
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    if (save == true && name.text.trim().isNotEmpty) {
      engine.saveShoppingItem(
        item.copyWith(name: name.text.trim(), quantity: quantity.text.trim()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey(item.id),
        direction: DismissDirection.endToStart,
        background: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(26),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Icon(
            AppIcons.trash,
            color: theme.colorScheme.onErrorContainer,
          ),
        ),
        onDismissed: (_) => engine.deleteShoppingItem(item.id),
        child: SoftCard(
          padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
          color: item.checked ? c.surfaceSoft : null,
          onTap: () =>
              engine.saveShoppingItem(item.copyWith(checked: !item.checked)),
          child: Row(
            children: [
              RoundCheck(
                value: item.checked,
                color: c.strong(FamioSection.shopping),
                onChanged: (checked) =>
                    engine.saveShoppingItem(item.copyWith(checked: checked)),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  item.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    decoration: item.checked
                        ? TextDecoration.lineThrough
                        : null,
                    color: item.checked ? c.inkSoft : null,
                  ),
                ),
              ),
              if (item.quantity.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: c.tint(FamioSection.shopping),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    item.quantity,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              IconButton(
                icon: Icon(AppIcons.pencilSimple, size: 18, color: c.inkSoft),
                tooltip: 'Bearbeiten',
                onPressed: () => _edit(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> _askName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => DisposeWith(
      controllers: [controller],
      child: AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'z. B. Wocheneinkauf, Drogerie',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    ),
  );
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
