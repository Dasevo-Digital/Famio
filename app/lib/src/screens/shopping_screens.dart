import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../data/shopping_history.dart';
import '../data/shopping_text.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import 'list_templates.dart';
import 'pantry_screens.dart';
import 'purchase_dialog.dart';
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
  // Who sees the budget, for "Einkauf ins Haushaltsbuch".
  Collections.budgetSettings,
  Collections.shoppingHistory,
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
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: FamioColors.of(context).text(color),
                              ),
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
  void initState() {
    super.initState();
    // Suggestions follow what is typed.
    _input.addListener(() => setState(() {}));
    // Staples that are due go back on the list when someone opens one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final added = AppScope.engineOf(context).addDueStaples();
      if (added > 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr.shoppingStaplesAdded(added))));
      }
    });
  }

  /// A suggestion becomes an item, with the amount bought last time.
  void _pick(SyncEngine engine, BoughtItem b) {
    engine.saveShoppingItem(
      newShoppingItem(
        engine,
        widget.listId,
        b.name,
      ).copyWith(quantity: b.quantity),
    );
    _input.clear();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add(SyncEngine engine) {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    engine.saveShoppingItem(
      newShoppingItem(engine, widget.listId, text, memberId: _who),
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

  /// The phones and the Mac have a share sheet; elsewhere (Windows, Linux,
  /// the browser) the text goes to the clipboard.
  static bool get _canShare =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// The open items as text for someone without Famio.
  Future<void> _shareText(SyncEngine engine, ShoppingList list) async {
    final text = shoppingListText(engine, list);
    if (!_canShare) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr.shoppingTextCopied)));
      }
      return;
    }
    // The iPad and the Mac anchor the share sheet to a place on screen.
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: text,
        subject: list.name,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
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
        final canBook =
            !list.packing &&
            done.isNotEmpty &&
            canBookPurchase(AppScope.of(context), engine);

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
                'budget' => bookPurchase(context, list, done),
                'share' => _shareText(engine, list),
                'staples' => showStaples(context),
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
                if (canBook)
                  PopupMenuItem(value: 'budget', child: Text(tr.purchaseTitle)),
                if (!list.packing)
                  PopupMenuItem(
                    value: 'staples',
                    child: Text(tr.shoppingStaples),
                  ),
                PopupMenuItem(
                  value: 'share',
                  enabled: open.isNotEmpty,
                  child: Text(
                    _canShare ? tr.shoppingShareText : tr.shoppingCopyText,
                  ),
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
              if (!list.packing)
                _Suggestions(
                  items: engine.shoppingSuggestions(
                    list.id,
                    typed: _input.text,
                  ),
                  typing: _input.text.trim().isNotEmpty,
                  onPick: (b) => _pick(engine, b),
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
                      if (canBook)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            icon: const Icon(AppIcons.receipt, size: 18),
                            label: Text(tr.purchaseButton),
                            onPressed: () => bookPurchase(context, list, done),
                          ),
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
          onTap: () => _setChecked(engine, item, !item.checked),
          child: Row(
            children: [
              RoundCheck(
                label: item.name,
                value: item.checked,
                color: c.strong(FamioSection.shopping),
                onChanged: (checked) => _setChecked(engine, item, checked),
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

/// Ticks [item] on or off; ticking off counts it as bought (suggestions,
/// staples).
void _setChecked(SyncEngine engine, ShoppingItem item, bool checked) {
  engine.saveShoppingItem(item.copyWith(checked: checked));
  if (checked && !item.checked) engine.noteBought(item);
}

/// What the family buys: quick picks under the input, or what matches the
/// typed text.
class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.items,
    required this.typing,
    required this.onPick,
  });

  final List<BoughtItem> items;
  final bool typing;
  final ValueChanged<BoughtItem> onPick;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox(height: 4);
    final c = FamioColors.of(context);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(top: 8),
        children: [
          if (!typing)
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 8),
              child: Text(
                tr.shoppingFrequent,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: c.inkSoft),
              ),
            ),
          for (final b in items)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar: Icon(
                  b.everyDays == null ? AppIcons.plus : AppIcons.repeat,
                  size: 16,
                ),
                label: Text(b.name),
                onPressed: () => onPick(b),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Stammartikel": what the family bought, with a rhythm after which an
/// article goes back on the list by itself.
Future<void> showStaples(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  builder: (_) => const _StaplesSheet(),
);

class _StaplesSheet extends StatelessWidget {
  const _StaplesSheet();

  static const _rhythms = [null, 7, 14, 28];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateFormat.MMMd(appLanguage);
    return DataBuilder(
      collections: const {Collections.shoppingHistory},
      builder: (context, engine) {
        final items = engine.boughtItems
          ..sort((a, b) {
            // Staples first, then by how often.
            if ((a.everyDays == null) != (b.everyDays == null)) {
              return a.everyDays == null ? 1 : -1;
            }
            return b.count.compareTo(a.count);
          });
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.8,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
              children: [
                Text(tr.shoppingStaples, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(tr.shoppingStaplesHint, style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(tr.shoppingStaplesEmpty),
                  ),
                for (final b in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      b.quantity.isEmpty ? b.name : '${b.quantity} ${b.name}',
                    ),
                    subtitle: Text(
                      [
                        tr.shoppingBoughtTimes(b.count),
                        if (b.nextDue case final due?)
                          tr.shoppingNextOn(date.format(due)),
                      ].join(' · '),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButton<int?>(
                          value: _rhythms.contains(b.everyDays)
                              ? b.everyDays
                              : null,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final days in _rhythms)
                              DropdownMenuItem(
                                value: days,
                                child: Text(switch (days) {
                                  null => tr.shoppingRhythmNone,
                                  7 => tr.shoppingRhythmWeekly,
                                  _ => tr.shoppingRhythmWeeks(days ~/ 7),
                                }),
                              ),
                          ],
                          onChanged: (days) => engine.saveBoughtItem(
                            b.copyWith(everyDays: () => days),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(AppIcons.trash),
                          tooltip: tr.shoppingForget,
                          onPressed: () => deleteWithUndo(
                            context,
                            what: b.name,
                            collections: const {Collections.shoppingHistory},
                            delete: () => engine.forgetBoughtItem(b.key),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A new item for [listId] from typed or shared text. A leading count
/// becomes the quantity: "3 Äpfel", "3x Äpfel". [memberId]: whose thing it
/// is on a packing list.
ShoppingItem newShoppingItem(
  SyncEngine engine,
  String listId,
  String text, {
  String? memberId,
}) {
  final match = RegExp(r'^(\d+)\s*[xX]?\s+(.+)$').firstMatch(text);
  final name = match?.group(2) ?? text;
  final packing = engine.shoppingList(listId)?.packing ?? false;
  return ShoppingItem(
    id: newId(),
    listId: listId,
    name: name,
    quantity: match?.group(1) ?? '',
    // Packing lists have no aisles.
    category: packing
        ? ''
        : guessShoppingCategory(
            name,
            learned: engine.learnedShoppingCategories,
          ),
    memberId: packing ? memberId : null,
  );
}
