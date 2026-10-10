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
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';
import 'list_connect_screen.dart';
import '../widgets/preppsuite_import.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

const _shopping = {
  Collections.shoppingLists,
  Collections.shoppingItems,
  Collections.pantryItems,
};

class ShoppingListsScreen extends StatelessWidget {
  const ShoppingListsScreen({super.key});

  Future<void> _create(BuildContext context) async {
    final name = await _askName(context, title: tr.shoppingNewShoppingList);
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
      title: tr.sectionShopping,
      subtitle: tr.shoppingWhatDoWeNeed,
      actions: [
        BubbleButton(
          icon: AppIcons.template,
          tooltip: tr.shoppingListTemplate,
          onPressed: () => showTemplatePicker(context),
        ),
        if (canConnectLists(AppScope.of(context)))
          BubbleButton(
            icon: AppIcons.arrowsLeftRight,
            tooltip: tr.commonConnectOtherApps,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ListConnectScreen(),
              ),
            ),
          ),
        const SyncStatusIcon(),
      ],
      floating: AddButton(
        color: color,
        tooltip: tr.shoppingNewList,
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
                  text: tr.homeNoShoppingListYet,
                  action: ColorButton(
                    label: tr.shoppingCreateFirstList,
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
                                ? (items.isEmpty
                                      ? tr.shoppingEmpty
                                      : tr.shoppingEverythingCart)
                                : tr.commonOpenCount(open),
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

  /// Packing lists: only this member's things (null: everyone's).
  String? _who;

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
    final name = match?.group(2) ?? text;
    final packing = engine.shoppingList(widget.listId)?.packing ?? false;
    engine.saveShoppingItem(
      ShoppingItem(
        id: newId(),
        listId: widget.listId,
        name: name,
        quantity: match?.group(1) ?? '',
        // Packing lists have no aisles.
        category: packing
            ? ''
            : guessShoppingCategory(
                name,
                learned: engine.learnedShoppingCategories,
              ),
        memberId: packing ? _who : null,
      ),
    );
    _input.clear();
    _focus.requestFocus();
  }

  Future<void> _rename(SyncEngine engine, ShoppingList list) async {
    final name = await _askName(
      context,
      title: tr.shoppingRenameList,
      initial: list.name,
    );
    if (name != null) engine.saveShoppingList(list.copyWith(name: name));
  }

  void _saveTemplate(SyncEngine engine, ShoppingList list) {
    engine.templateFromList(list);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr.shoppingNameSavedTemplate(list.name))),
    );
  }

  Future<void> _deleteList(SyncEngine engine, ShoppingList list) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.commonDeleteName(list.name)),
        content: Text(tr.shoppingListAllItsEntries),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    deleteWithUndo(
      context,
      what: list.name,
      collections: const {Collections.shoppingLists, Collections.shoppingItems},
      delete: () => engine.deleteShoppingList(list.id),
    );
    Navigator.pop(context);
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
          return SectionPage(
            maxBodyWidth: 960,
            section: FamioSection.shopping,
            title: tr.sectionShopping,
            body: Center(child: Text(tr.shoppingListNoLongerExists)),
          );
        }
        final all = engine.shoppingItems(list.id);
        final owners = [
          for (final m in engine.members)
            if (all.any((i) => i.memberId == m.id)) m,
        ];
        final who = owners.any((m) => m.id == _who) ? _who : null;
        // A member's view of a packing list: theirs and everyone's things.
        final items = [
          for (final i in all)
            if (who == null || i.memberId == null || i.memberId == who) i,
        ];
        final open = items.where((i) => !i.checked).toList();
        final done = items.where((i) => i.checked).toList();
        // Open items by aisle, in the order of a walk through the store.
        final learned = engine.learnedShoppingCategories;
        final byAisle = <String, List<ShoppingItem>>{
          for (final c in shoppingCategories) c.key: [],
        };
        for (final i in open) {
          byAisle[engine.shoppingCategoryOf(i, learned)]!.add(i);
        }
        final aisles = byAisle.entries.where((e) => e.value.isNotEmpty);

        return SectionPage(
          maxBodyWidth: 960,
          section: FamioSection.shopping,
          title: list.name,
          subtitle: list.packing
              ? tr.shoppingDoneTotalPacked(done.length, items.length)
              : open.isEmpty
              ? tr.shoppingAllDone
              : tr.commonOpenCount(open.length),
          actions: [
            const SyncStatusIcon(),
            PopupMenuButton<String>(
              tooltip: tr.navMore,
              icon: const Icon(AppIcons.dotsThreeVertical),
              onSelected: (action) => switch (action) {
                'clear' => deleteWithUndo(
                  context,
                  message: done.length == 1
                      ? tr.shopping1CheckedItemRemoved
                      : tr.shoppingCountCheckedItemsRemoved(done.length),
                  collections: const {Collections.shoppingItems},
                  delete: () {
                    for (final i in done) {
                      engine.deleteShoppingItem(i.id);
                    }
                  },
                ),
                'uncheck' => [
                  for (final i in done)
                    engine.saveShoppingItem(i.copyWith(checked: false)),
                ],
                'template' => _saveTemplate(engine, list),
                'preppsuite' => importFromPreppSuite(context, engine, list),
                'rename' => _rename(engine, list),
                'delete' => _deleteList(engine, list),
                _ => null,
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'clear',
                  enabled: done.isNotEmpty,
                  child: Text(tr.shoppingRemoveCheckedItems),
                ),
                PopupMenuItem(
                  value: 'uncheck',
                  enabled: done.isNotEmpty,
                  child: Text(tr.shoppingRemoveAllCheckmarks),
                ),
                PopupMenuItem(
                  value: 'template',
                  enabled: items.isNotEmpty,
                  child: Text(tr.shoppingSaveTemplate),
                ),
                PopupMenuItem(
                  value: 'preppsuite',
                  child: Text(tr.shoppingPreppSuiteMenu),
                ),
                PopupMenuItem(value: 'rename', child: Text(tr.commonRename)),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(tr.shoppingDeleteList),
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
                  hintText: list.packing
                      ? tr.shoppingAddEGDiving
                      : tr.shoppingAddItemEG,
                  prefixIcon: const Icon(AppIcons.plus, size: 20),
                  suffixIcon: BubbleButton(
                    icon: AppIcons.arrowUp,
                    tooltip: tr.commonAdd,
                    color: Colors.white,
                    background: color,
                    size: 38,
                    onPressed: () => _add(engine),
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
                    if (list.packing && owners.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ChoiceChip(
                              label: Text(tr.commonEveryone),
                              selected: who == null,
                              onSelected: (_) => setState(() => _who = null),
                            ),
                            for (final m in owners)
                              ChoiceChip(
                                avatar: MemberAvatar(m, radius: 10),
                                label: Text(
                                  m.id == engine.memberId
                                      ? tr.shoppingMe
                                      : m.displayName,
                                ),
                                selected: who == m.id,
                                onSelected: (_) => setState(() => _who = m.id),
                              ),
                          ],
                        ),
                      ),
                    if (list.packing)
                      for (final (heading, group) in _packingGroups(
                        engine,
                        open,
                      )) ...[
                        if (heading != null) _AisleHeading(heading),
                        for (final item in group)
                          _ItemTile(item: item, engine: engine, packing: true),
                      ]
                    // One aisle needs no heading.
                    else if (aisles.length < 2)
                      for (final item in open)
                        _ItemTile(item: item, engine: engine)
                    else
                      for (final aisle in aisles) ...[
                        _AisleHeading(shoppingCategory(aisle.key)!.label),
                        for (final item in aisle.value)
                          _ItemTile(item: item, engine: engine),
                      ],
                    if (done.isNotEmpty) ...[
                      ListHeading(
                        list.packing
                            ? tr.shoppingPackedCount(done.length)
                            : tr.shoppingCartCount(done.length),
                        color: color,
                      ),
                      for (final item in done)
                        _ItemTile(
                          item: item,
                          engine: engine,
                          packing: list.packing,
                        ),
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

/// Open things of a packing list: everyone's first, then per member, each
/// sorted by category; one group needs no heading.
List<(String?, List<ShoppingItem>)> _packingGroups(
  SyncEngine engine,
  List<ShoppingItem> open,
) {
  int byCategory(ShoppingItem a, ShoppingItem b) {
    final c = a.category.compareTo(b.category);
    return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  final groups = <(String?, List<ShoppingItem>)>[
    (
      tr.shoppingEveryone,
      [
        for (final i in open)
          if (i.memberId == null) i,
      ],
    ),
    for (final m in engine.members)
      (
        m.id == engine.memberId ? tr.shoppingMyThings : m.displayName,
        [
          for (final i in open)
            if (i.memberId == m.id) i,
        ],
      ),
  ].where((g) => g.$2.isNotEmpty).toList();
  for (final g in groups) {
    g.$2.sort(byCategory);
  }
  if (groups.length == 1) return [(null, groups.single.$2)];
  return groups;
}

class _AisleHeading extends StatelessWidget {
  const _AisleHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
    child: Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(color: FamioColors.of(context).inkSoft),
    ),
  );
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.engine,
    this.packing = false,
  });

  final ShoppingItem item;
  final SyncEngine engine;

  /// On a packing list: no aisles.
  final bool packing;

  Future<void> _edit(BuildContext context) async {
    final name = TextEditingController(text: item.name);
    final quantity = TextEditingController(text: item.quantity);
    var category = engine.shoppingCategoryOf(item);
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => DisposeWith(
        controllers: [name, quantity],
        child: AlertDialog(
          title: Text(tr.shoppingEditItem),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: InputDecoration(labelText: tr.shoppingItem),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: quantity,
                decoration: InputDecoration(
                  labelText: tr.commonQuantity,
                  hintText: tr.shoppingEG2500,
                ),
                onSubmitted: (_) => Navigator.pop(context, true),
              ),
              if (!packing) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: InputDecoration(labelText: tr.shoppingAisle),
                  items: [
                    for (final c in shoppingCategories)
                      DropdownMenuItem(value: c.key, child: Text(c.label)),
                  ],
                  // Remembered: next time this article lands there.
                  onChanged: (v) => category = v ?? category,
                ),
              ],
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
    if (save == true && name.text.trim().isNotEmpty) {
      if (packing) {
        engine.saveShoppingItem(
          item.copyWith(name: name.text.trim(), quantity: quantity.text.trim()),
        );
        return;
      }
      if (category != engine.shoppingCategoryOf(item)) {
        engine.rememberShoppingCategory(name.text.trim(), category);
      }
      engine.saveShoppingItem(
        item.copyWith(
          name: name.text.trim(),
          quantity: quantity.text.trim(),
          category: category,
        ),
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
        onDismissed: (_) => deleteWithUndo(
          context,
          what: item.name,
          collections: const {Collections.shoppingItems},
          delete: () => engine.deleteShoppingItem(item.id),
        ),
        child: SoftCard(
          padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
          color: item.checked ? c.surfaceSoft : null,
          onTap: () =>
              engine.saveShoppingItem(item.copyWith(checked: !item.checked)),
          child: Row(
            children: [
              RoundCheck(
                label: item.name,
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
                tooltip: tr.commonEdit,
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
          decoration: InputDecoration(
            labelText: tr.commonName,
            hintText: tr.shoppingEGWeeklyShopping,
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(tr.commonOk),
          ),
        ],
      ),
    ),
  );
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
