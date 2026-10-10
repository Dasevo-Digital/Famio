import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/family_data.dart';
import '../data/open_food_facts.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../l10n.dart';
import 'pantry_screens.dart';

/// Recipe → nutrients of one serving from the linked ingredients, and the
/// way to link them.
class RecipeNutrition extends StatelessWidget {
  const RecipeNutrition({super.key, required this.recipe, this.off});

  final Recipe recipe;

  /// Tests pass their own.
  final OpenFoodFacts? off;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = recipe.nutritionPerServing;
    final whole = NumberFormat.decimalPattern(appLanguage)
      ..maximumFractionDigits = 0;
    final one = NumberFormat.decimalPattern(appLanguage)
      ..maximumFractionDigits = 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListHeading(tr.mealsNutrition),
        if (n != null) ...[
          SoftCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 20,
                  runSpacing: 8,
                  children: [
                    for (final (value, label) in [
                      (whole.format(n.kcal), 'kcal'),
                      ('${one.format(n.protein)} g', tr.mealsProtein),
                      ('${one.format(n.fat)} g', tr.mealsFat),
                      ('${one.format(n.carbs)} g', tr.mealsCarbs),
                    ])
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(value, style: theme.textTheme.titleMedium),
                          Text(label, style: theme.textTheme.bodySmall),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${tr.mealsNutritionPerServing} · '
                  '${tr.mealsNutritionFromCount(n.counted, n.total)}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(tr.mealsNutritionSource, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
          icon: const Icon(AppIcons.link),
          label: Text(
            n == null ? tr.mealsNutritionStart : tr.mealsNutritionLink,
          ),
          onPressed: () => openNutritionLinks(context, recipe.id, off: off),
        ),
      ],
    );
  }
}

/// Asks once per device whether Open Food Facts may be asked, then opens
/// the ingredients to link.
Future<void> openNutritionLinks(
  BuildContext context,
  String recipeId, {
  OpenFoodFacts? off,
}) async {
  if (!await OpenFoodFacts.allowed()) {
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.nutritionConsentTitle),
        content: Text(tr.nutritionConsentText),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.nutritionConsentAllow),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await OpenFoodFacts.allow(true);
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => NutritionLinkScreen(recipeId: recipeId, off: off),
    ),
  );
}

/// Each ingredient of a recipe with its Open Food Facts product.
class NutritionLinkScreen extends StatelessWidget {
  const NutritionLinkScreen({super.key, required this.recipeId, this.off});

  final String recipeId;
  final OpenFoodFacts? off;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final whole = NumberFormat.decimalPattern(appLanguage)
      ..maximumFractionDigits = 0;
    return DataBuilder(
      collections: const {Collections.recipes},
      builder: (context, engine) {
        final r = engine.recipe(recipeId);
        return SectionPage(
          section: FamioSection.meals,
          title: tr.nutritionLinkTitle,
          subtitle: r?.title,
          body: r == null
              ? const SizedBox.shrink()
              : ListView(
                  children: [
                    for (final (index, i) in r.ingredients.indexed)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        title: Text(i.toString()),
                        subtitle: Text(switch (i.nutrition) {
                          null => tr.nutritionNotLinked,
                          final n => [
                            n.product,
                            tr.nutritionPer100(whole.format(n.kcal)),
                            if (i.amount != null && i.grams == null)
                              tr.nutritionNoGrams,
                          ].join(' · '),
                        }),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(AppIcons.magnifyingGlass),
                              tooltip: tr.commonSearch,
                              onPressed: () =>
                                  _search(context, engine, r, index),
                            ),
                            if (scannerAvailable)
                              IconButton(
                                icon: const Icon(AppIcons.scanBarcode),
                                tooltip: tr.nutritionScan,
                                onPressed: () =>
                                    _scan(context, engine, r, index),
                              ),
                            if (i.nutrition != null)
                              IconButton(
                                icon: const Icon(AppIcons.unlink),
                                tooltip: tr.nutritionUnlink,
                                onPressed: () =>
                                    _link(engine, r.id, index, null),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      tr.mealsNutritionSource,
                      style: theme.textTheme.bodySmall,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () async {
                          await OpenFoodFacts.allow(false);
                          if (context.mounted) Navigator.pop(context);
                        },
                        child: Text(tr.nutritionStop),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  OpenFoodFacts get _off => off ?? OpenFoodFacts();

  Future<void> _search(
    BuildContext context,
    SyncEngine engine,
    Recipe r,
    int index,
  ) async {
    final found = await showDialog<Nutrition>(
      context: context,
      builder: (_) =>
          _SearchDialog(off: _off, query: r.ingredients[index].name),
    );
    if (found != null && context.mounted) {
      await _choose(context, engine, r.id, index, found);
    }
  }

  Future<void> _scan(
    BuildContext context,
    SyncEngine engine,
    Recipe r,
    int index,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const BarcodeScanScreen()),
    );
    if (code == null) return;
    try {
      final found = await _off.product(code);
      if (found == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr.nutritionUnknownProduct)),
        );
      } else if (context.mounted) {
        await _choose(context, engine, r.id, index, found);
      }
    } on Object {
      messenger.showSnackBar(SnackBar(content: Text(tr.nutritionOffline)));
    }
  }

  /// Links [found]; pieces or packages the product does not weigh are
  /// asked for once.
  Future<void> _choose(
    BuildContext context,
    SyncEngine engine,
    String recipeId,
    int index,
    Nutrition found,
  ) async {
    final r = engine.recipe(recipeId);
    if (r == null || index >= r.ingredients.length) return;
    final i = r.ingredients[index];
    var chosen = found;
    if (i.amount != null && i.withNutrition(found).grams == null) {
      final grams = await _askWeight(context, i);
      if (grams != null) {
        chosen = i.byPackage
            ? found.copyWith(packageGrams: grams)
            : found.copyWith(pieceGrams: grams);
      }
    }
    _link(engine, recipeId, index, chosen);
  }

  static void _link(
    SyncEngine engine,
    String recipeId,
    int index,
    Nutrition? nutrition,
  ) {
    final r = engine.recipe(recipeId);
    if (r == null || index >= r.ingredients.length) return;
    final ingredients = [...r.ingredients];
    ingredients[index] = ingredients[index].withNutrition(nutrition);
    engine.saveRecipe(r.copyWith(ingredients: ingredients));
  }

  static Future<double?> _askWeight(BuildContext context, Ingredient i) async {
    final input = TextEditingController();
    final what = [if (i.unit.isNotEmpty) i.unit, i.name].join(' ');
    final grams = await showDialog<double>(
      context: context,
      builder: (context) {
        void done() => Navigator.pop(
          context,
          double.tryParse(input.text.trim().replaceAll(',', '.')),
        );
        return AlertDialog(
          title: Text(tr.nutritionWeightTitle),
          content: TextField(
            controller: input,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: tr.nutritionWeightOf(what),
              suffixText: 'g',
            ),
            onSubmitted: (_) => done(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.commonCancel),
            ),
            FilledButton(onPressed: done, child: Text(tr.commonOk)),
          ],
        );
      },
    );
    input.dispose();
    return grams != null && grams > 0 ? grams : null;
  }
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.off, required this.query});

  final OpenFoodFacts off;
  final String query;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  late final _input = TextEditingController(text: widget.query);
  List<Nutrition>? _results;
  var _busy = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_input.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final results = await widget.off.search(_input.text);
      if (mounted) setState(() => _results = results);
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final whole = NumberFormat.decimalPattern(appLanguage)
      ..maximumFractionDigits = 0;
    final results = _results;
    return AlertDialog(
      title: TextField(
        controller: _input,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: tr.commonSearch,
          suffixIcon: IconButton(
            icon: const Icon(AppIcons.magnifyingGlass),
            tooltip: tr.commonSearch,
            onPressed: _search,
          ),
        ),
        onSubmitted: (_) => _search(),
      ),
      content: SizedBox(
        width: 440,
        height: 360,
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _failed
            ? Center(child: Text(tr.nutritionOffline))
            : results == null
            ? const SizedBox.shrink()
            : results.isEmpty
            ? Center(child: Text(tr.nutritionNoResults))
            : ListView(
                children: [
                  for (final n in results)
                    ListTile(
                      title: Text(n.product),
                      subtitle: Text(tr.nutritionPer100(whole.format(n.kcal))),
                      onTap: () => Navigator.pop(context, n),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.commonCancel),
        ),
      ],
    );
  }
}
