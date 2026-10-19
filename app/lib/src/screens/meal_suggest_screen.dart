import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../data/meal_suggestions.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// "Woche vorschlagen": fills the free days of [monday]'s week from the
/// family's recipes; each day can be swapped or left out before it is
/// planned. Returns the planned recipes (for the shopping list).
Future<List<MealCandidate>?> showMealSuggestions(
  BuildContext context,
  DateTime monday,
) => Navigator.of(context).push(
  MaterialPageRoute<List<MealCandidate>>(
    builder: (_) => MealSuggestScreen(monday: monday),
  ),
);

class MealSuggestScreen extends StatefulWidget {
  const MealSuggestScreen({super.key, required this.monday, this.today});

  final DateTime monday;

  /// For tests; the current day otherwise.
  final DateTime? today;

  @override
  State<MealSuggestScreen> createState() => _MealSuggestScreenState();
}

class _MealSuggestScreenState extends State<MealSuggestScreen> {
  late final SyncEngine _engine = AppScope.engineOf(context);
  late final List<PlannedMeal> _planned = _engine.plannedMeals(
    DateTime(widget.monday.year, widget.monday.month, widget.monday.day - 28),
    DateTime(widget.monday.year, widget.monday.month, widget.monday.day + 7),
  );
  late MealSlot _slot = usualSlot(_planned);
  var _seed = 0;
  late MealSuggestion _suggestion;

  /// Per free day the index into the candidates, null when left out.
  late List<int?> _chosen;

  var _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_ready) _suggest();
  }

  void _suggest() {
    final now = widget.today ?? DateTime.now();
    _suggestion = suggestMeals(
      monday: widget.monday,
      slot: _slot,
      recipes: _engine.recipes,
      planned: _planned,
      pantry: _engine.pantryItems,
      from: DateTime(now.year, now.month, now.day),
      seed: _seed,
    );
    final count = _suggestion.candidates.length;
    _chosen = [
      for (var i = 0; i < _suggestion.days.length; i++) i < count ? i : null,
    ];
    _ready = true;
  }

  /// The next recipe not planned on another day, after the current one.
  void _swap(int day) {
    final count = _suggestion.candidates.length;
    final used = {..._chosen.nonNulls};
    final current = _chosen[day];
    for (var step = 1; step <= count; step++) {
      final next = ((current ?? -1) + step) % count;
      if (!used.contains(next)) {
        setState(() => _chosen[day] = next);
        return;
      }
    }
  }

  void _apply() {
    final planned = <MealCandidate>[];
    for (var i = 0; i < _suggestion.days.length; i++) {
      final index = _chosen[i];
      if (index == null) continue;
      final candidate = _suggestion.candidates[index];
      _engine.saveMeal(
        PlannedMeal(
          id: newId(),
          date: _suggestion.days[i],
          slot: _slot,
          recipeId: candidate.recipe.id,
        ),
      );
      planned.add(candidate);
    }
    Navigator.pop(context, planned);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.meals);
    final days = _suggestion.days;
    final candidates = _suggestion.candidates;
    final count = _chosen.nonNulls.length;
    final day = DateFormat.MMMEd(appLanguage);
    return SectionPage(
      section: FamioSection.meals,
      title: tr.mealsSuggestTitle,
      actions: [
        ColorButton(
          label: tr.mealsSuggestApply(count),
          color: color,
          onPressed: count == 0 ? null : _apply,
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(top: 4, bottom: listBottomPadding(context)),
        children: [
          Text(tr.mealsSuggestHint, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final slot in [MealSlot.lunch, MealSlot.dinner])
                ChoiceChip(
                  label: Text(slot.label),
                  selected: _slot == slot,
                  onSelected: (_) => setState(() {
                    _slot = slot;
                    _suggest();
                  }),
                ),
              if (candidates.length > 1)
                TextButton.icon(
                  icon: const Icon(AppIcons.shuffle, size: 18),
                  label: Text(tr.mealsSuggestOther),
                  onPressed: () => setState(() {
                    _seed++;
                    _suggest();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (days.isEmpty)
            EmptyHint(
              icon: AppIcons.calendarCheck,
              color: color,
              text: tr.mealsSuggestAllPlanned,
            )
          else if (candidates.isEmpty)
            EmptyHint(
              icon: AppIcons.chefHat,
              color: color,
              text: tr.mealsSuggestNoRecipes,
            )
          else
            for (var i = 0; i < days.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _SuggestionCard(
                  day: day.format(days[i]),
                  candidate: _chosen[i] == null
                      ? null
                      : candidates[_chosen[i]!],
                  // Only while a recipe is left that is on no other day.
                  onSwap: candidates.length > count ? () => _swap(i) : null,
                  onRemove: _chosen[i] == null
                      ? null
                      : () => setState(() => _chosen[i] = null),
                ),
              ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.day,
    required this.candidate,
    required this.onSwap,
    required this.onRemove,
  });

  final String day;
  final MealCandidate? candidate;
  final VoidCallback? onSwap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final candidate = this.candidate;
    final stock = candidate?.stock;
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              day,
              style: theme.textTheme.labelMedium?.copyWith(color: c.inkSoft),
            ),
          ),
          Expanded(
            child: candidate == null
                ? Text(
                    tr.mealsSuggestLeftOut,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: c.inkSoft,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          candidate.recipe.title,
                          if (candidate.recipe.favorite) '★',
                        ].join(' '),
                        style: theme.textTheme.bodyLarge,
                      ),
                      if (stock != null && stock.total > 0)
                        Text(
                          [
                            tr.mealsSuggestStock(
                              stock.have.length,
                              stock.total,
                            ),
                            if (candidate.usesExpiring) tr.mealsSuggestExpiring,
                          ].join(' · '),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
          ),
          IconButton(
            icon: Icon(candidate == null ? AppIcons.plus : AppIcons.shuffle),
            tooltip: candidate == null
                ? tr.mealsSuggestAdd
                : tr.mealsSuggestSwap,
            onPressed: onSwap,
          ),
          if (onRemove != null)
            IconButton(
              icon: const Icon(AppIcons.x),
              tooltip: tr.mealsSuggestLeaveOut,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
