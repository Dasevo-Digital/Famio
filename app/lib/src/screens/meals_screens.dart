import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/family_extras.dart';
import '../data/pantry_match.dart';
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
import '../l10n.dart';
import 'nutrition_screens.dart';

const _collections = {
  Collections.recipes,
  Collections.mealPlan,
  Collections.pantryItems,
  Collections.shoppingLists,
  Collections.shoppingItems,
};

DateTime _monday(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return DateTime(day.year, day.month, day.day - (day.weekday - 1));
}

enum _Tab {
  week,
  recipes;

  String get label => switch (this) {
    week => tr.mealsWeekPlan,
    recipes => tr.mealsRecipes,
  };
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
      title: tr.sectionMeals,
      subtitle: tr.mealsWeekPlanFamilyRecipes,
      actions: const [SyncStatusIcon()],
      floating: AddButton(
        color: color,
        tooltip: _tab == _Tab.week ? tr.mealsPlanMeal : tr.mealsAddRecipe,
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
              tooltip: tr.mealsPreviousWeek,
              onPressed: () =>
                  onWeek(DateTime(week.year, week.month, week.day - 7)),
            ),
            Expanded(
              child: Text(
                '${DateFormat.MMMd(appLanguage).format(week)} – '
                '${DateFormat.MMMd(appLanguage).format(end.subtract(const Duration(days: 1)))}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(AppIcons.caretRight),
              tooltip: tr.mealsNextWeek,
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
              label: Text(tr.mealsPutWeekSIngredients),
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
                            DateFormat.MMMMEEEEd(appLanguage).format(day),
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(AppIcons.plus),
                          tooltip: tr.mealsPlanMeal,
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
                                tooltip: tr.commonChange,
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
    list = ShoppingList(id: newId(), name: tr.sectionShopping);
    engine.saveShoppingList(list);
  } else {
    list = await showModalBottomSheet<ShoppingList>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(tr.commonWhichList)),
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
        tr.mealsCountIngredientsListAdded(
          items.length,
          list.name,
          added < items.length ? tr.mealsCountAdded(items.length - added) : '',
        ),
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
        final pantry = engine.pantryItems;
        final stock = {
          for (final r in engine.recipes) r.id: engine.stockOf(r, pantry),
        };
        final recipes = engine.recipes
            .where(
              (r) =>
                  q.isEmpty ||
                  r.title.toLowerCase().contains(q) ||
                  r.tags.any((t) => t.toLowerCase().contains(q)) ||
                  r.ingredients.any((i) => i.name.toLowerCase().contains(q)),
            )
            .toList();
        // With a stocked pantry: what can be cooked with it comes first.
        if (pantry.isNotEmpty && q.isEmpty) {
          recipes.sort(
            (a, b) => stock[b.id]!.share.compareTo(stock[a.id]!.share),
          );
        }
        if (engine.recipes.isEmpty) {
          return EmptyHint(
            icon: AppIcons.cookingPot,
            color: color,
            text: tr.mealsCollectFavoriteRecipesWritten,
            action: ColorButton(
              label: tr.mealsAddRecipe,
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
              decoration: InputDecoration(
                prefixIcon: Icon(AppIcons.magnifyingGlass),
                hintText: tr.mealsSearchRecipeIngredient,
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
                                if (pantry.isNotEmpty && stock[r.id]!.total > 0)
                                  stock[r.id]!.missing.isEmpty
                                      ? tr.mealsEverythingPantry
                                      : tr.mealsHaveTotalPantry(
                                          stock[r.id]!.have.length,
                                          stock[r.id]!.total,
                                        )
                                else
                                  tr.mealsCountIngredients(
                                    r.ingredients.length,
                                  ),
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
          return SectionPage(
            section: FamioSection.meals,
            title: tr.commonRecipe,
            body: SizedBox.shrink(),
          );
        }
        final servings = _servings ?? widget.servings ?? r.servings;
        final factor = servings / r.servings;
        final pantry = engine.pantryItems;
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
              tooltip: r.favorite ? tr.mealsNoLongerFavorite : tr.mealsFavorite,
              onPressed: () =>
                  engine.saveRecipe(r.copyWith(favorite: !r.favorite)),
            ),
            const SizedBox(width: 8),
            BubbleButton(
              icon: AppIcons.pencilSimple,
              tooltip: tr.commonEdit,
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
                  Text(tr.mealsServings, style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton.filledTonal(
                    icon: const Text('−', style: TextStyle(fontSize: 20)),
                    tooltip: tr.mealsFewer,
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
                    tooltip: tr.navMore,
                    onPressed: () => setState(() => _servings = servings + 1),
                  ),
                ],
              ),
              ListHeading(tr.mealsIngredients),
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
                            if (pantry.isNotEmpty && inPantry(i, pantry))
                              Tooltip(
                                message: tr.mealsPantry,
                                child: Icon(
                                  AppIcons.check,
                                  size: 18,
                                  color: color,
                                ),
                              ),
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
                  if (pantry.isNotEmpty &&
                      engine.stockOf(r, pantry).have.isNotEmpty &&
                      engine.stockOf(r, pantry).missing.isNotEmpty)
                    ColorButton(
                      label: tr.mealsMissingItemsShoppingList,
                      icon: AppIcons.basket,
                      color: color,
                      onPressed: () => _toShopping(context, engine, [
                        for (final i in _scaled(r, servings))
                          if (!inPantry(i, pantry)) i,
                      ]),
                    ),
                  ColorButton(
                    label: pantry.isEmpty
                        ? tr.mealsShoppingList
                        : tr.mealsEverythingShoppingList,
                    icon: AppIcons.basket,
                    color: color,
                    onPressed: () =>
                        _toShopping(context, engine, _scaled(r, servings)),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(AppIcons.calendarBlank),
                    label: Text(tr.mealsSchedule),
                    onPressed: () => showMealEditor(
                      context,
                      day: DateUtils.dateOnly(DateTime.now()),
                      recipe: r,
                      servings: servings,
                    ),
                  ),
                ],
              ),
              RecipeNutrition(recipe: r),
              if (steps.isNotEmpty) ...[
                ListHeading(tr.mealsPreparation),
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
                              color: FamioColors.of(context).text(color),
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
            Text(tr.mealsPlanMeal, style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                InputChip(
                  avatar: const Icon(AppIcons.calendarBlank, size: 18),
                  label: Text(DateFormat.MMMMEEEEd(appLanguage).format(_day)),
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
              decoration: InputDecoration(labelText: tr.commonRecipe),
              items: [
                DropdownMenuItem(
                  value: null,
                  child: Text(tr.mealsNoRecipeJustText),
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
                decoration: InputDecoration(
                  labelText: tr.mealsWhatSDinner,
                  hintText: tr.mealsEGLeftoversOrder,
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(tr.mealsServings),
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
                    label: Text(tr.commonRemove),
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
                ColorButton(
                  label: tr.commonSave,
                  color: color,
                  onPressed: _save,
                ),
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
        title: Text(tr.mealsRecipeWebsite),
        content: TextField(
          controller: url,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: tr.commonAddress,
            hintText: 'https://www.chefkoch.de/rezepte/…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, url.text.trim()),
            child: Text(tr.commonApply),
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
          SnackBar(content: Text(tr.mealsNoRecipeWasFound)),
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
      messenger.showSnackBar(SnackBar(content: Text(tr.mealsPageNotReachable)));
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

  /// An ingredient keeps its product (nutrients) while its name stays.
  Ingredient _keepLink(Ingredient i) {
    final name = i.name.trim().toLowerCase();
    final before = widget.existing?.ingredients
        .where(
          (o) => o.nutrition != null && o.name.trim().toLowerCase() == name,
        )
        .firstOrNull;
    return before == null ? i : i.withNutrition(before.nutrition);
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
            if (line.trim().isNotEmpty) _keepLink(Ingredient.parse(line)),
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
        title: Text(tr.commonDeleteName(widget.existing!.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr.commonDelete),
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
      title: widget.existing == null ? tr.mealsNewRecipe : tr.mealsEditRecipe,
      actions: [
        ColorButton(
          label: tr.commonSave,
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
                label: Text(tr.mealsTakeWebsite),
                onPressed: _busy ? null : _import,
              ),
              OutlinedButton.icon(
                icon: const Icon(AppIcons.camera),
                label: Text(
                  _photo == null ? tr.commonPhoto : tr.mealsChangePhoto,
                ),
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
            decoration: InputDecoration(labelText: tr.commonTitle),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _servings,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: tr.mealsServings),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: tr.mealsMinutes),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ingredients,
            minLines: 4,
            maxLines: 14,
            decoration: InputDecoration(
              labelText: tr.mealsIngredientsOnePerLine,
              hintText: tr.meals250GFlour500,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _steps,
            minLines: 4,
            maxLines: 20,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: tr.mealsPreparationOneStepPer,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: InputDecoration(
              labelText: tr.mealsTagsOptional,
              hintText: tr.mealsQuickVegetarianKidsFavorite,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _source,
            decoration: InputDecoration(
              labelText: tr.mealsSourceOptional,
              hintText: tr.mealsWebsiteGrandmaInge,
            ),
          ),
          if (widget.existing != null) ...[
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.trash, size: 18),
                label: Text(tr.mealsDeleteRecipe),
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
