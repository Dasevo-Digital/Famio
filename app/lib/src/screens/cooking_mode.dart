import 'dart:async';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_state.dart';
import '../reminders/reminder_service.dart';
import '../data/cooking.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// A recipe at the stove: first the ingredients to tick off, then one big
/// step per page. The screen stays on, times in a step ("10 Minuten")
/// start a kitchen timer with one tap. Swipe or use the arrow keys.
class CookingModeScreen extends StatefulWidget {
  const CookingModeScreen({
    super.key,
    required this.recipe,
    required this.servings,
  });

  final Recipe recipe;
  final int servings;

  @override
  State<CookingModeScreen> createState() => _CookingModeScreenState();
}

class _KitchenTimer {
  _KitchenTimer(this.slot, this.step, this.end);

  final int slot;

  /// The step (0-based) the timer belongs to.
  final int step;
  final DateTime end;
  bool rang = false;
}

class _CookingModeScreenState extends State<CookingModeScreen> {
  final _pages = PageController();
  var _page = 0;
  final _ticked = <int>{};
  final _timers = <_KitchenTimer>[];
  Timer? _tick;
  ReminderService? _reminders;

  late final List<String> _steps = [
    for (final s in widget.recipe.steps.split('\n'))
      if (s.trim().isNotEmpty) s.trim(),
  ];

  int get _count => _steps.length + 1;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable().catchError((Object _) {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reminders = AppScope.read(context).reminders;
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final t in _timers) {
      _reminders?.cancelTimer(t.slot);
    }
    WakelockPlus.disable().catchError((Object _) {});
    _pages.dispose();
    super.dispose();
  }

  void _go(int page) {
    if (page < 0 || page >= _count) return;
    _pages.animateToPage(
      page,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _start(int step, Duration duration) {
    final used = {for (final t in _timers) t.slot};
    final slot = List.generate(
      100,
      (i) => i,
    ).firstWhere((i) => !used.contains(i), orElse: () => 0);
    final timer = _KitchenTimer(slot, step, DateTime.now().add(duration));
    setState(() => _timers.add(timer));
    _reminders?.scheduleTimer(
      slot,
      timer.end,
      title: tr.cookTimerDone,
      body: tr.cookTimerDoneBody(widget.recipe.title, step + 1),
    );
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _stop(_KitchenTimer timer) {
    _reminders?.cancelTimer(timer.slot);
    setState(() => _timers.remove(timer));
    if (_timers.isEmpty) {
      _tick?.cancel();
      _tick = null;
    }
  }

  void _onTick() {
    if (!mounted) return;
    final now = DateTime.now();
    final due = [
      for (final t in _timers)
        if (!t.rang && !t.end.isAfter(now)) t,
    ];
    setState(() {
      for (final t in due) {
        t.rang = true;
      }
    });
    for (final t in due) {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(AppIcons.timer),
          title: Text(tr.cookTimerDone),
          content: Text(tr.cookTimerDoneBody(widget.recipe.title, t.step + 1)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr.commonOk),
            ),
          ],
        ),
      ).then((_) {
        if (mounted && _timers.contains(t)) _stop(t);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final color = c.strong(FamioSection.meals);
    final last = _page == _count - 1;
    return PopScope(
      canPop: _timers.every((t) => t.rang),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(tr.cookLeaveTitle),
            content: Text(tr.cookLeaveBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(tr.commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(tr.cookTimerStop),
              ),
            ],
          ),
        );
        if (leave == true && context.mounted) {
          for (final t in [..._timers]) {
            _stop(t);
          }
          Navigator.of(context).pop();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _go(_page + 1),
          const SingleActivator(LogicalKeyboardKey.space): () => _go(_page + 1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _go(_page - 1),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: c.tint(FamioSection.meals),
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              leading: IconButton(
                icon: const Icon(AppIcons.x),
                tooltip: tr.commonClose,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              title: Text(widget.recipe.title),
            ),
            body: SafeArea(
              child: Column(
                children: [
                  if (_timers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final t in _timers)
                            InputChip(
                              avatar: Icon(AppIcons.timer, color: color),
                              label: Text(
                                '${tr.cookStepOf(t.step + 1, _steps.length)}'
                                ' · ${_countdown(t)}',
                              ),
                              deleteButtonTooltipMessage: tr.cookTimerStop,
                              onPressed: () => _go(t.step + 1),
                              onDeleted: () => _stop(t),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: PageView.builder(
                      controller: _pages,
                      itemCount: _count,
                      onPageChanged: (p) => setState(() => _page = p),
                      itemBuilder: (context, page) => page == 0
                          ? _ingredients(context, color)
                          : _step(context, page - 1, color),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(AppIcons.caretLeft),
                          label: Text(tr.commonBack),
                          onPressed: _page == 0 ? null : () => _go(_page - 1),
                        ),
                        Expanded(
                          child: Text(
                            _page == 0
                                ? tr.mealsIngredients
                                : tr.cookStepOf(_page, _steps.length),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelLarge,
                          ),
                        ),
                        ColorButton(
                          label: last ? tr.commonDone : tr.commonNext,
                          icon: last ? AppIcons.check : AppIcons.caretRight,
                          color: color,
                          onPressed: last
                              ? () => Navigator.of(context).maybePop()
                              : () => _go(_page + 1),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ingredients(BuildContext context, Color color) {
    final theme = Theme.of(context);
    final factor = widget.servings / widget.recipe.servings;
    final ingredients = widget.recipe.ingredients;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        Text(
          '${tr.mealsIngredients} · ${tr.mealsServings} ${widget.servings}',
          style: theme.textTheme.titleLarge,
        ),
        Text(tr.cookTickOff, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        for (final (n, i) in ingredients.indexed)
          SoftCard(
            padding: EdgeInsets.zero,
            child: CheckboxListTile(
              value: _ticked.contains(n),
              activeColor: color,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => setState(
                () => v == true ? _ticked.add(n) : _ticked.remove(n),
              ),
              title: Text(
                [
                  i.quantity(factor),
                  i.name,
                ].where((s) => s.isNotEmpty).join(' '),
                style: theme.textTheme.titleLarge?.copyWith(
                  decoration: _ticked.contains(n)
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _step(BuildContext context, int index, Color color) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final step = _steps[index];
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr.cookStepOf(index + 1, _steps.length),
            style: theme.textTheme.titleMedium?.copyWith(
              color: FamioColors.of(context).text(color),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            step,
            style:
                (wide
                        ? theme.textTheme.headlineMedium
                        : theme.textTheme.headlineSmall)
                    ?.copyWith(height: 1.35),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final d in stepTimers(step))
                ColorButton(
                  label: tr.cookTimer(_duration(d)),
                  icon: AppIcons.timer,
                  color: color,
                  onPressed: () => _start(index, d),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// "1 Std. 30 Min.", "10 Min.", "45 Sek."
  static String _duration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return [
      if (h > 0) tr.cookHours('$h'),
      if (m > 0) tr.cookMinutes('$m'),
      if (s > 0) tr.cookSeconds('$s'),
    ].join(' ');
  }

  /// "07:32" or "1:05:00"; "0:00" once it rang.
  static String _countdown(_KitchenTimer t) {
    var left = t.end.difference(DateTime.now());
    if (left.isNegative) left = Duration.zero;
    final h = left.inHours;
    final mm = (left.inMinutes % 60).toString().padLeft(2, '0');
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
