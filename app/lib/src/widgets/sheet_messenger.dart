import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Shows the messages of what is inside a bottom sheet or a dialog
/// („Milch“ gelöscht · Rückgängig, an upload that failed) over it, at its
/// bottom. Without it they go to the page below, where the sheet and its
/// barrier cover them and "Rückgängig" cannot be reached (#364).
///
/// [child] keeps its size and its taps; only a message that is showing
/// takes the taps where it is drawn. Wrap the whole content the sheet's
/// builder returns (outside its keyboard padding), so a message stays
/// above the keyboard.
///
/// When the sheet closes, a message that still offers something to do
/// (e.g. "Rückgängig" after "Löschen" and closing) moves to the page; a
/// plain message (a hint about the form) ends with the sheet.
class SheetMessenger extends StatefulWidget {
  const SheetMessenger({super.key, required this.child});

  final Widget child;

  @override
  State<SheetMessenger> createState() => _SheetMessengerHostState();
}

class _SheetMessengerHostState extends State<SheetMessenger> {
  /// Whether the message showing offers something to tap ("Rückgängig").
  /// A plain hint takes no taps: it often lies over the sheet's buttons
  /// (KIN-085, "Bitte Medikament eingeben" over "Speichern").
  final _actionShowing = ValueNotifier(false);

  @override
  void dispose() {
    _actionShowing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SheetScaffoldMessenger(
    actionShowing: _actionShowing,
    child: Stack(
      // The content is laid out as without this widget.
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          child: _SnackBarsOnly(
            takesTaps: _actionShowing,
            child: const Scaffold(
              // No status bar area to tap and nothing painted.
              primary: false,
              backgroundColor: Colors.transparent,
            ),
          ),
        ),
      ],
    ),
  );
}

class _SheetScaffoldMessenger extends ScaffoldMessenger {
  const _SheetScaffoldMessenger({
    required this.actionShowing,
    required super.child,
  });

  final ValueNotifier<bool> actionShowing;

  @override
  ScaffoldMessengerState createState() => _SheetMessengerState();
}

class _SheetMessengerState extends ScaffoldMessengerState {
  /// Shown or waiting, oldest first.
  final _open = <SnackBar>[];
  ScaffoldMessengerState? _outer;
  ModalRoute<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The page's messenger (above this one).
    _outer = ScaffoldMessenger.maybeOf(context);
    final route = ModalRoute.of(context);
    if (route != null && route != _route) {
      _route = route;
      route.popped.then((_) => _moveOut(route));
    }
  }

  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    final controller = super.showSnackBar(
      snackBar,
      snackBarAnimationStyle: snackBarAnimationStyle,
    );
    _open.add(snackBar);
    _showing();
    controller.closed.whenComplete(() {
      _open.remove(snackBar);
      _showing();
    });
    return controller;
  }

  /// The oldest open message is the one on screen.
  void _showing() {
    final messenger = widget as _SheetScaffoldMessenger;
    if (!mounted) return;
    messenger.actionShowing.value =
        _open.isNotEmpty && _open.first.action != null;
  }

  @override
  void clearSnackBars() {
    // Only the current one stays, until it is hidden.
    if (_open.length > 1) _open.removeRange(1, _open.length);
    super.clearSnackBars();
  }

  /// The sheet closes: what can still be done goes to the page.
  void _moveOut(ModalRoute<Object?> route) {
    final outer = _outer;
    if (!mounted || route != _route || outer == null || !outer.mounted) {
      return;
    }
    final moving = [
      for (final s in _open)
        if (s.action != null) s,
    ];
    if (moving.isEmpty) return;
    _open.clear();
    clearSnackBars();
    removeCurrentSnackBar();
    outer.hideCurrentSnackBar();
    for (final s in moving) {
      outer.showSnackBar(s);
    }
  }
}

/// Lets taps through to what is below, except on a message: the empty
/// [Scaffold] that shows the messages would otherwise take every tap on
/// the sheet.
class _SnackBarsOnly extends SingleChildRenderObjectWidget {
  const _SnackBarsOnly({required this.takesTaps, required Widget super.child});

  final ValueListenable<bool> takesTaps;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSnackBarsOnly(takesTaps);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSnackBarsOnly renderObject,
  ) => renderObject.takesTaps = takesTaps;
}

class _RenderSnackBarsOnly extends RenderProxyBox {
  _RenderSnackBarsOnly(this.takesTaps);

  ValueListenable<bool> takesTaps;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // A plain hint lets every tap through to the sheet.
    if (!takesTaps.value) return false;
    final probe = BoxHitTestResult();
    if (!super.hitTest(probe, position: position)) return false;
    // The scaffold lays out its parts (here only a message) in a
    // CustomMultiChildLayout; it is in the path only when one of them was
    // hit. Its background alone does not count.
    final onMessage = probe.path.any(
      (e) => e.target is RenderCustomMultiChildLayoutBox,
    );
    return onMessage && super.hitTest(result, position: position);
  }
}
