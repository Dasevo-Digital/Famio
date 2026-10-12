import 'dart:math' as math;

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';

/// The real buttons the tour points at. The navigation and the start page
/// mark them with these keys; a step whose button is not on screen is left
/// out.
abstract final class TourTargets {
  static final sections = {
    for (final s in FamioSection.values)
      s: GlobalKey(debugLabel: 'tour.${s.name}'),
  };

  /// "Mehr" in the phone bar, where the other sections live.
  static final more = GlobalKey(debugLabel: 'tour.more');
  static final sos = GlobalKey(debugLabel: 'tour.sos');
}

class TourStep {
  const TourStep({
    required this.target,
    required this.title,
    required this.text,
  });

  final GlobalKey target;
  final String title;
  final String text;
}

/// The steps for [me], who sees [sections]: about a minute, by role –
/// parents get the children, children their duties and points.
List<TourStep> tourSteps({
  required FamilyMember me,
  required List<FamioSection> sections,
}) {
  final steps = <TourStep>[];
  void add(FamioSection section, String title, String text) {
    if (!sections.contains(section)) return;
    final own = TourTargets.sections[section]!;
    if (own.currentContext != null) {
      steps.add(TourStep(target: own, title: title, text: text));
    } else if (TourTargets.more.currentContext != null) {
      // On a phone most sections sit behind "Mehr".
      steps.add(
        TourStep(
          target: TourTargets.more,
          title: title,
          text: '$text ${tr.tourUnderMore}',
        ),
      );
    }
  }

  add(FamioSection.home, tr.tourHomeTitle, tr.tourHomeText);
  add(FamioSection.calendar, tr.tourCalendarTitle, tr.tourCalendarText);
  if (me.isChild && sections.contains(FamioSection.chores)) {
    add(FamioSection.chores, tr.tourChoresTitle, tr.tourChoresText);
  } else {
    add(FamioSection.tasks, tr.tourTasksTitle, tr.tourTasksText);
  }
  add(FamioSection.shopping, tr.tourShoppingTitle, tr.tourShoppingText);
  if (!me.isChild && !me.isGuest) {
    add(FamioSection.kids, tr.tourKidsTitle, tr.tourKidsText);
  }
  if (TourTargets.sos.currentContext != null) {
    steps.add(
      TourStep(
        target: TourTargets.sos,
        title: tr.tourSosTitle,
        text: tr.tourSosText,
      ),
    );
  }
  final admin = me.isAdmin ? ' ${tr.tourAdminText}' : '';
  if (TourTargets.sections[FamioSection.settings]!.currentContext != null) {
    steps.add(
      TourStep(
        target: TourTargets.sections[FamioSection.settings]!,
        title: tr.tourSettingsTitle,
        text: '${tr.tourSettingsText}$admin',
      ),
    );
  } else if (TourTargets.more.currentContext != null) {
    steps.add(
      TourStep(
        target: TourTargets.more,
        title: tr.tourMoreTitle,
        text: '${tr.tourMoreText}$admin',
      ),
    );
  }
  return steps;
}

const _doneKey = 'tour.offered';

/// Remembers that the tour was taken or declined; the start page card
/// reads it again.
Future<void> _markOffered() async {
  try {
    await (await SharedPreferences.getInstance()).setBool(_doneKey, true);
  } catch (_) {
    // Without storage it is offered again next time; no harm.
  }
  TourBanner._changed.value++;
}

/// Starts the tour on the start page. [go] switches to a section (see
/// `FamioNav`), [sections] are the ones [me] sees.
Future<void> startFamioTour(
  BuildContext context, {
  required FamilyMember me,
  required List<FamioSection> sections,
  required ValueChanged<FamioSection> go,
}) async {
  await _markOffered();
  go(FamioSection.home);
  // The start page with its buttons is laid out in the next frame.
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return;
  final steps = tourSteps(me: me, sections: sections);
  if (steps.isEmpty) return;
  await Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, _, _) => _TourOverlay(steps: steps),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _TourOverlay extends StatefulWidget {
  const _TourOverlay({required this.steps});

  final List<TourStep> steps;

  @override
  State<_TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<_TourOverlay> {
  var _index = 0;

  TourStep get _step => widget.steps[_index];
  bool get _last => _index == widget.steps.length - 1;

  void _next() => _last ? Navigator.pop(context) : setState(() => _index++);

  void _back() {
    if (_index > 0) setState(() => _index--);
  }

  /// Where [key]'s button is on screen, a little larger.
  Rect? _hole(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return (box.localToGlobal(Offset.zero) & box.size).inflate(6);
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final still = MediaQuery.of(context).disableAnimations;
    final duration = still ? Duration.zero : const Duration(milliseconds: 280);
    final hole = _hole(_step.target);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
        const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
        const SingleActivator(LogicalKeyboardKey.enter): _next,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _back,
      },
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              return Stack(
                children: [
                  // Taps beside the card do nothing: the tour is no menu.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      child: TweenAnimationBuilder<Rect?>(
                        tween: RectTween(end: hole),
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        builder: (context, rect, _) => CustomPaint(
                          size: size,
                          painter: _ScrimPainter(
                            hole: rect,
                            scrim: Colors.black.withValues(alpha: 0.62),
                            ring: c.strong(FamioSection.home),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _placed(
                    size,
                    hole,
                    AnimatedSwitcher(
                      duration: duration,
                      child: _Card(
                        key: ValueKey(_index),
                        step: _step,
                        number: _index + 1,
                        total: widget.steps.length,
                        last: _last,
                        onNext: _next,
                        onBack: _index > 0 ? _back : null,
                        onSkip: () => Navigator.pop(context),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Next to the button: beside the side rail, else above or below it.
  Widget _placed(Size size, Rect? hole, Widget card) {
    final width = math.min(380.0, size.width - 32);
    if (hole == null) {
      return Center(
        child: SizedBox(width: width, child: card),
      );
    }
    if (hole.right < size.width * 0.3 && size.width - hole.right > width + 32) {
      return Positioned(
        left: hole.right + 20,
        top: (hole.center.dy - 120).clamp(16, math.max(16, size.height - 300)),
        width: width,
        child: card,
      );
    }
    final left = (hole.center.dx - width / 2).clamp(
      16.0,
      size.width - width - 16,
    );
    // Below or above the button, wherever the card fits; with a very large
    // button (a child's emergency card) at the bottom edge, over it.
    const room = 260.0;
    final inset = MediaQuery.paddingOf(context);
    final below = size.height - inset.bottom - hole.bottom - 16;
    final above = hole.top - inset.top - 16;
    if (below >= room && below >= above) {
      return Positioned(
        left: left,
        top: hole.bottom + 16,
        width: width,
        child: card,
      );
    }
    return Positioned(
      left: left,
      bottom: above >= room ? size.height - hole.top + 16 : inset.bottom + 16,
      width: width,
      child: card,
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.step,
    required this.number,
    required this.total,
    required this.last,
    required this.onNext,
    required this.onSkip,
    this.onBack,
  });

  final TourStep step;
  final int number;
  final int total;
  final bool last;
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr.tourStep(number, total),
              style: theme.textTheme.labelMedium?.copyWith(color: c.inkSoft),
            ),
            const SizedBox(height: 4),
            Text(step.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(step.text, style: theme.textTheme.bodyMedium),
            ),
            const SizedBox(height: 8),
            // Wraps on narrow phones and with large text.
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                if (!last)
                  TextButton(onPressed: onSkip, child: Text(tr.tourSkip)),
                if (onBack != null)
                  TextButton(onPressed: onBack, child: Text(tr.commonBack)),
                FilledButton(
                  onPressed: onNext,
                  child: Text(last ? tr.commonDone : tr.commonNext),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScrimPainter extends CustomPainter {
  const _ScrimPainter({
    required this.hole,
    required this.scrim,
    required this.ring,
  });

  final Rect? hole;
  final Color scrim;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    final cutout = hole == null
        ? null
        : RRect.fromRectAndRadius(hole!, const Radius.circular(20));
    if (cutout != null) path.addRRect(cutout);
    canvas.drawPath(path, Paint()..color = scrim);
    if (cutout != null) {
      canvas.drawRRect(
        cutout,
        Paint()
          ..color = ring
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(_ScrimPainter old) =>
      old.hole != hole || old.scrim != scrim || old.ring != ring;
}

/// Start page, once per device: "Neu bei Famio? Eine Minute Rundgang".
class TourBanner extends StatefulWidget {
  const TourBanner({super.key, required this.onStart});

  final VoidCallback onStart;

  /// Bumped when the tour was taken or the card hidden.
  static final _changed = ValueNotifier(0);

  @override
  State<TourBanner> createState() => _TourBannerState();
}

class _TourBannerState extends State<TourBanner> {
  Future<bool>? _offered;
  var _seen = -1;

  Future<bool> _load() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_doneKey) ?? false;
    } catch (_) {
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: TourBanner._changed,
      builder: (context, changed, _) {
        if (changed != _seen) {
          _seen = changed;
          _offered = _load();
        }
        return FutureBuilder<bool>(
          future: _offered,
          builder: (context, snapshot) {
            if (snapshot.data != false) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: SoftCard(
                color: c.tint(FamioSection.home),
                onTap: widget.onStart,
                child: Row(
                  children: [
                    Icon(AppIcons.sparkle, color: c.strong(FamioSection.home)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr.tourBannerTitle,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            tr.tourBannerText,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: tr.commonHide,
                      icon: const Icon(AppIcons.x),
                      onPressed: _markOffered,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Starts the tour from anywhere inside the app shell.
void startTourFromShell(BuildContext context) {
  final engine = AppScope.read(context).engine;
  final me = engine?.me;
  final nav = FamioTourScope.maybeOf(context);
  if (me == null || nav == null) return;
  startFamioTour(context, me: me, sections: nav.sections, go: nav.go);
}

/// What the tour needs from the app shell: the visible sections and how to
/// switch to one.
class FamioTourScope extends InheritedWidget {
  const FamioTourScope({
    super.key,
    required this.sections,
    required this.go,
    required super.child,
  });

  final List<FamioSection> sections;
  final ValueChanged<FamioSection> go;

  static FamioTourScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FamioTourScope>();

  @override
  bool updateShouldNotify(FamioTourScope old) => old.sections != sections;
}
