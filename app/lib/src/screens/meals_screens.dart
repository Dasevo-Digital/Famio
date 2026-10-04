import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/recipe_import.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/files.dart';
import '../widgets/sync_status_icon.dart';
import '../widgets/undo_delete.dart';

const _collections = {
  Collections.recipes,
  Collections.mealPlan,
  Collections.shoppingLists,
  Collections.shoppingItems,
};

DateTime _monday(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return DateTime(day.year, day.month, day.day - (day.weekday - 1));
}

enum _Tab {
  week('Wochenplan'),
  recipes('Rezepte');

  const _Tab(this.label);

  final String label;
}

/// Recipes and the weekly meal plan.
class MealsScreen extends StatefulWidget {
  const MealsScreen({super.key});

  @override
  State<MealsScreen> createState() => _MealsScreenState();
}

class _MealsScreenState extends State<MealsScreen> {
  var _tab = _Tab.week;
  var _week = _monday(DateTime.now());
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = FamioColors.of(context).strong(FamioSection.meals);
    return SectionPage(
      section: FamioSection.meals,
      title: 'Essen',
      subtitle: 'Wochenplan und Familienrezepte',
      actions: const [SyncStatusIcon()],
      floating: AddButton(
        color: color,
        tooltip: _tab == _Tab.week ? 'Essen planen' : 'Rezept hinzufügen',
        onPressed: () => _tab == _Tab.week
            ? showMealEditor(context, day: DateUtils.dateOnly(DateTime.now()))
            : showRecipeEditor(context),
      ),
      body: Column(
        children: [
          PillTabs<_Tab>(
            values: _Tab.values,
            selected: _tab,
            label: (t) => t.label,
            color: color,
            onChanged: (t) => setState(() => _tab = t),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: DataBuilder(
              collections: _collections,
              builder: (context, engine) => switch (_tab) {
                _Tab.week => _WeekPlan(
                  engine: engine,
                  week: _week,
                  onWeek: (w) => setState(() => _week = w),
                ),
                _Tab.recipes => _RecipeList(engine: engine, search: _search),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekPlan extends StatelessWidget {
  const _WeekPlan({
    required this.engine,
    required this.week,
    required this.onWeek,
  });

  final SyncEngine engine;
  final DateTime week;
  final ValueChanged<DateTime> onWeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final end = DateTime(week.year, week.month, week.day + 7);
    final meals = engine.plannedMeals(week, end);
    final today = DateUtils.dateOnly(DateTime.now());
    final withRecipes = meals.where((m) => engine.recipe(m.recipeId) != null);
    return ListView(
      padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(AppIcons.caretLeft),
              tooltip: 'Vorige Woche',
              onPressed: () =>
                  onWeek(DateTime(week.year, week.month, week.day - 7)),
            ),
            Expanded(
              child: Text(
                '${DateFormat('d. MMM', 'de').format(week)} – '
                '${DateFormat('d. MMM', 'de').format(end.subtract(const Duration(days: 1)))}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(AppIcons.caretRight),
              tooltip: 'Nächste Woche',
              onPressed: () =>
                  onWeek(DateTime(week.year, week.month, week.day + 7)),
            ),
          ],
        ),
        if (withRecipes.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(AppIcons.basket, size: 18),
              label: const Text('Zutaten der Woche auf die Einkaufsliste'),
              onPressed: () => _toShopping(context, engine, [
                for (final m in withRecipes)
                  ..._scaled(engine.recipe(m.recipeId)!, m.servings),
              ]),
            ),
          ),
        for (var i = 0; i < 7; i++)
          () {
            final day = DateTime(week.year, week.month, week.day + i);
            final ofDay = meals.where((m) => m.date == day).toList();
            final isToday = day == today;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SoftCard(
                color: isToday ? c.tint(FamioSection.meals) : null,
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            DateFormat('EEEE, d.M.', 'de').format(day),
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(AppIcons.plus),
                          tooltip: 'Essen planen',
                          onPressed: () => showMealEditor(context, day: day),
                        ),
                      ],
                    ),
                    if (ofDay.isEmpty)
                      Text('–', style: theme.textTheme.bodySmall),
                    for (final m in ofDay)
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => engine.recipe(m.recipeId) != null
                            ? Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => RecipeScreen(
                                    recipeId: m.recipeId!,
                                    servings: m.servings,
                                  ),
                                ),
                              )
                            : showMealEditor(context, day: day, existing: m),
                        onLongPress: () =>
                            showMealEditor(context, day: day, existing: m),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 96,
                                child: Text(
                                  m.slot.label,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: c.inkSoft,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  engine.recipe(m.recipeId)?.title ?? m.title,
                                  style: theme.textTheme.bodyLarge,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  AppIcons.pencilSimple,
                                  size: 18,
                                ),
                                tooltip: 'Ändern',
                                onPressed: () => showMealEditor(
                                  context,
                                  day: day,
                                  existing: m,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }(),
      ],
    );
  }
}

List<Ingredient> _scaled(Recipe r, int? servings) {
  final factor = (servings ?? r.servings) / r.servings;
  return [
    for (final i in r.ingredients)
      Ingredient(
        name: i.name,
        amount: i.amount == null ? null : i.amount! * factor,
        unit: i.unit,
      ),
  ];
}

/// Asks for the shopping list and adds [items].
Future<void> _toShopping(
  BuildContext context,
  SyncEngine engine,
  List<Ingredient> items,
) async {
  final lists = engine.shoppingLists;
  final messenger = ScaffoldMessenger.of(context);
  ShoppingList? list;
  if (lists.length == 1) {
    list = lists.single;
  } else if (lists.isEmpty) {
    list = ShoppingList(id: newId(), name: 'Einkauf');
    engine.saveShoppingList(list);
  } else {
    list = await showModalBottomSheet<ShoppingList>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Auf welche Liste?')),
            for (final l in lists)
              ListTile(
                leading: const Icon(AppIcons.basket),
                title: Text(l.name),
                onTap: () => Navigator.pop(context, l),
              ),
          ],
        ),
      ),
    );
  }
  if (list == null) return;
  final added = engine.addToShoppingList(list.id, items);
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        '${items.length} Zutaten auf „${list.name}“'
        '${added < items.length ? ' (${items.length - added} ergänzt)' : ''}',
      ),
    ),
  );
}

class _RecipeList extends StatelessWidget {
  const _RecipeList({required this.engine, required this.search});

  final SyncEngine engine;
  final TextEditingController search;

  @override
  Widget build(BuildContext context) {
    final color = FamioColors.of(context).strong(FamioSection.meals);
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) {
        final q = search.text.trim().toLowerCase();
        final recipes = engine.recipes
            .where(
              (r) =>
                  q.isEmpty ||
                  r.title.toLowerCase().contains(q) ||
                  r.tags.any((t) => t.toLowerCase().contains(q)) ||
                  r.ingredients.any((i) => i.name.toLowerCase().contains(q)),
            )
            .toList();
        if (engine.recipes.isEmpty) {
          return EmptyHint(
            icon: AppIcons.cookingPot,
            color: color,
            text:
                'Sammelt eure Lieblingsrezepte – selbst geschrieben oder\n'
                'von Chefkoch & Co. übernommen.',
            action: ColorButton(
              label: 'Rezept hinzufügen',
              color: color,
              onPressed: () => showRecipeEditor(context),
            ),
          );
        }
        return ListView(
          padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
          children: [
            TextField(
              controller: search,
              decoration: const InputDecoration(
                prefixIcon: Icon(AppIcons.magnifyingGlass),
                hintText: 'Rezept oder Zutat suchen',
              ),
            ),
            const SizedBox(height: 12),
            for (final r in recipes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SoftCard(
                  padding: const EdgeInsets.all(12),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RecipeScreen(recipeId: r.id),
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 56,
                        child: r.photo == null
                            ? IconBlob(
                                AppIcons.cookingPot,
                                color: color,
                                size: 56,
                              )
                            : CachedImage(r.photo!, thumb: 160, radius: 16),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              r.title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              [
                                '${r.ingredients.length} Zutaten',
                                if (r.minutes != null) '${r.minutes} min',
                                ...r.tags,
                              ].join(' · '),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      if (r.favorite)
                        const Icon(AppIcons.heart, color: Color(0xFFDB4A7E)),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One recipe with a servings calculator.
class RecipeScreen extends StatefulWidget {
  const RecipeScreen({super.key, required this.recipeId, this.servings});

  final String recipeId;
  final int? servings;

  @override
  State<RecipeScreen> createState() => _RecipeScreenState();
}

class _RecipeScreenState extends State<RecipeScreen> {
  int? _servings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = FamioColors.of(context).strong(FamioSection.meals);
    return DataBuilder(
      collections: _collections,
      builder: (context, engine) {
        final r = engine.recipe(widget.recipeId);
        if (r == null) {
          return const SectionPage(
            section: FamioSection.meals,
            title: 'Rezept',
            body: SizedBox.shrink(),
          );
        }
        final servings = _servings ?? widget.servings ?? r.servings;
        final factor = servings / r.servings;
        final steps = r.steps
            .split('\n')
            .where((s) => s.trim().isNotEmpty)
            .toList();
        return SectionPage(
          section: FamioSection.meals,
          title: r.title,
          subtitle: [
            if (r.minutes != null) '${r.minutes} min',
            if (r.source.isNotEmpty) r.source,
          ].join(' · '),
          actions: [
            BubbleButton(
              icon: AppIcons.heart,
              color: r.favorite ? const Color(0xFFDB4A7E) : null,
              tooltip: r.favorite ? 'Kein Favorit mehr' : 'Favorit',
              onPressed: () =>
                  engine.saveRecipe(r.copyWith(favorite: !r.favorite)),
            ),
            const SizedBox(width: 8),
            BubbleButton(
              icon: AppIcons.pencilSimple,
              tooltip: 'Bearbeiten',
              onPressed: () => showRecipeEditor(context, existing: r),
            ),
          ],
          body: ListView(
            padding: EdgeInsets.only(
              top: 4,
              bottom: listBottomPadding(context),
            ),
            children: [
              if (r.photo != null)
                SizedBox(
                  height: 200,
                  child: CachedImage(r.photo!, thumb: 960, radius: 24),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('Portionen', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton.filledTonal(
                    icon: const Text('−', style: TextStyle(fontSize: 20)),
                    tooltip: 'Weniger',
                    onPressed: servings <= 1
                        ? null
                        : () => setState(() => _servings = servings - 1),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '$servings',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton.filledTonal(
                    icon: const Icon(AppIcons.plus),
                    tooltip: 'Mehr',
                    onPressed: () => setState(() => _servings = servings + 1),
                  ),
                ],
              ),
              const ListHeading('Zutaten'),
              SoftCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Column(
                  children: [
                    for (final i in r.ingredients)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 90,
                              child: Text(
                                i.quantity(factor),
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            Expanded(child: Text(i.name)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ColorButton(
                    label: 'Auf die Einkaufsliste',
                    icon: AppIcons.basket,
                    color: color,
                    onPressed: () =>
                        _toShopping(context, engine, _scaled(r, servings)),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(AppIcons.calendarBlank),
                    label: const Text('Einplanen'),
                    onPressed: () => showMealEditor(
                      context,
                      day: DateUtils.dateOnly(DateTime.now()),
                      recipe: r,
                      servings: servings,
                    ),
                  ),
                ],
              ),
              if (steps.isNotEmpty) ...[
                const ListHeading('Zubereitung'),
                for (final (n, step) in steps.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 13,
                          backgroundColor: color.withValues(alpha: 0.15),
                          child: Text(
                            '${n + 1}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: color,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(step.trim())),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Plans a meal on [day] (a recipe or free text).
Future<void> showMealEditor(
  BuildContext context, {
  required DateTime day,
  PlannedMeal? existing,
  Recipe? recipe,
  int? servings,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _MealEditor(
    day: day,
    existing: existing,
    recipe: recipe,
    servings: servings,
  ),
);

class _MealEditor extends StatefulWidget {
  const _MealEditor({
    required this.day,
    this.existing,
    this.recipe,
    this.servings,
  });

  final DateTime day;
  final PlannedMeal? existing;
  final Recipe? recipe;
  final int? servings;

  @override
  State<_MealEditor> createState() => _MealEditorState();
}

class _MealEditorState extends State<_MealEditor> {
  late DateTime _day = widget.existing?.date ?? widget.day;
  late MealSlot _slot = widget.existing?.slot ?? MealSlot.dinner;
  late String? _recipeId = widget.existing?.recipeId ?? widget.recipe?.id;
  late final _title = TextEditingController(text: widget.existing?.title);
  late int? _servings = widget.existing?.servings ?? widget.servings;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    if (_recipeId == null && _title.text.trim().isEmpty) return;
    AppScope.engineOf(context).saveMeal(
      PlannedMeal(
        id: widget.existing?.id ?? newId(),
        date: _day,
        slot: _slot,
        recipeId: _recipeId,
        title: _recipeId == null ? _title.text.trim() : '',
        servings: _servings,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.engineOf(context);
    final theme = Theme.of(context);
    final color = FamioColors.of(context).strong(FamioSection.meals);
    final recipes = engine.recipes;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Essen planen', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                InputChip(
                  avatar: const Icon(AppIcons.calendarBlank, size: 18),
                  label: Text(DateFormat('EEEE, d.M.', 'de').format(_day)),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _day,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setState(() => _day = picked);
                  },
                ),
                for (final s in MealSlot.values)
                  ChoiceChip(
                    label: Text(s.label),
                    selected: _slot == s,
                    onSelected: (_) => setState(() => _slot = s),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _recipeId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Rezept'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('Kein Rezept – nur Text'),
                ),
                for (final r in recipes)
                  DropdownMenuItem(value: r.id, child: Text(r.title)),
              ],
              onChanged: (v) => setState(() => _recipeId = v),
            ),
            if (_recipeId == null) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                autofocus: widget.existing == null && widget.recipe == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Was gibt es?',
                  hintText: 'z. B. Reste, Pizza bestellen',
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Portionen'),
                  const Spacer(),
                  for (final n in [2, 3, 4, 5, 6])
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: ChoiceChip(
                        label: Text('$n'),
                        selected:
                            (_servings ?? engine.recipe(_recipeId)?.servings) ==
                            n,
                        onSelected: (_) => setState(() => _servings = n),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                if (widget.existing != null)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: const Text('Entfernen'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () {
                      deleteWithUndo(
                        context,
                        what: widget.existing!.title,
                        collections: const {Collections.mealPlan},
                        delete: () => engine.deleteMeal(widget.existing!.id),
                      );
                      Navigator.pop(context);
                    },
                  ),
                const Spacer(),
                ColorButton(label: 'Speichern', color: color, onPressed: _save),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Adds or edits a recipe; can take one from a web page.
Future<void> showRecipeEditor(BuildContext context, {Recipe? existing}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RecipeEditor(existing: existing),
      ),
    );

class _RecipeEditor extends StatefulWidget {
  const _RecipeEditor({this.existing});

  final Recipe? existing;

  @override
  State<_RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends State<_RecipeEditor> {
  late final _id = widget.existing?.id ?? newId();
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _servings = TextEditingController(
    text: '${widget.existing?.servings ?? 4}',
  );
  late final _minutes = TextEditingController(
    text: widget.existing?.minutes?.toString() ?? '',
  );
  late final _ingredients = TextEditingController(
    text: widget.existing?.ingredients.join('\n'),
  );
  late final _steps = TextEditingController(text: widget.existing?.steps);
  late final _source = TextEditingController(text: widget.existing?.source);
  late final _tags = TextEditingController(
    text: widget.existing?.tags.join(', '),
  );
  late FileRef? _photo = widget.existing?.photo;
  var _busy = false;

  @override
  void dispose() {
    for (final c in [
      _title,
      _servings,
      _minutes,
      _ingredients,
      _steps,
      _source,
      _tags,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _import() async {
    final url = TextEditingController(text: _source.text);
    final address = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Rezept von einer Webseite'),
        content: TextField(
          controller: url,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Adresse',
            hintText: 'https://www.chefkoch.de/rezepte/…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, url.text.trim()),
            child: const Text('Übernehmen'),
          ),
        ],
      ),
    );
    final uri = Uri.tryParse(address ?? '');
    if (uri == null || !uri.hasScheme || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await importRecipe(uri, id: _id);
      if (r == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Auf dieser Seite wurde kein Rezept gefunden.'),
          ),
        );
        return;
      }
      setState(() {
        _title.text = r.title;
        _servings.text = '${r.servings}';
        _minutes.text = r.minutes?.toString() ?? '';
        _ingredients.text = r.ingredients.join('\n');
        _steps.text = r.steps;
        _source.text = r.source;
      });
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Seite nicht erreichbar.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickPhoto() async {
    final picked = await pickFile(context, imagesOnly: true);
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final ref = await uploadPicked(context, picked);
      setState(() => _photo = ref);
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    if (_title.text.trim().isEmpty) return;
    AppScope.engineOf(context).saveRecipe(
      Recipe(
        id: _id,
        title: _title.text.trim(),
        servings: int.tryParse(_servings.text.trim())?.clamp(1, 50) ?? 4,
        minutes: int.tryParse(_minutes.text.trim()),
        ingredients: [
          for (final line in _ingredients.text.split('\n'))
            if (line.trim().isNotEmpty) Ingredient.parse(line),
        ],
        steps: _steps.text.trim(),
        source: _source.text.trim(),
        photo: _photo,
        tags: [
          for (final t in _tags.text.split(','))
            if (t.trim().isNotEmpty) t.trim(),
        ],
        favorite: widget.existing?.favorite ?? false,
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('„${widget.existing!.title}“ löschen?'),
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
    if (ok != true || !mounted) return;
    final engine = AppScope.engineOf(context);
    deleteWithUndo(
      context,
      what: widget.existing!.title,
      collections: const {Collections.recipes},
      delete: () => engine.deleteRecipe(widget.existing!.id),
    );
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final color = FamioColors.of(context).strong(FamioSection.meals);
    return SectionPage(
      section: FamioSection.meals,
      title: widget.existing == null ? 'Neues Rezept' : 'Rezept bearbeiten',
      actions: [
        ColorButton(
          label: 'Speichern',
          color: color,
          onPressed: _busy ? null : _save,
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(AppIcons.globe),
                label: const Text('Von Webseite übernehmen'),
                onPressed: _busy ? null : _import,
              ),
              OutlinedButton.icon(
                icon: const Icon(AppIcons.camera),
                label: Text(_photo == null ? 'Foto' : 'Foto ändern'),
                onPressed: _busy ? null : _pickPhoto,
              ),
              if (_busy)
                const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Titel'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _servings,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Portionen'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Minuten'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ingredients,
            minLines: 4,
            maxLines: 14,
            decoration: const InputDecoration(
              labelText: 'Zutaten – eine pro Zeile',
              hintText: '250 g Mehl\n500 ml Milch\n3 Eier',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _steps,
            minLines: 4,
            maxLines: 20,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Zubereitung – ein Schritt pro Zeile',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Stichworte (optional)',
              hintText: 'schnell, vegetarisch, Kinderliebling',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _source,
            decoration: const InputDecoration(
              labelText: 'Quelle (optional)',
              hintText: 'Webseite oder „Oma Inge“',
            ),
          ),
          if (widget.existing != null) ...[
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.trash, size: 18),
                label: const Text('Rezept löschen'),
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
