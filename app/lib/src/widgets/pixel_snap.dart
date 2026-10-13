import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paints [child] on whole device pixels. Shapes and text whose position
/// comes out at x.5 (a layout that divides the window height) look soft,
/// above all on displays with a pixel ratio of 1: external monitors and
/// remote desktops. The child moves by less than a pixel; the layout stays
/// as it is. Not for children of scrolling lists, which move without
/// painting again.
class PixelSnap extends SingleChildRenderObjectWidget {
  const PixelSnap({super.key, super.child});

  @override
  RenderPixelSnap createRenderObject(BuildContext context) =>
      RenderPixelSnap(MediaQuery.devicePixelRatioOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderPixelSnap renderObject) =>
      renderObject.ratio = MediaQuery.devicePixelRatioOf(context);
}

class RenderPixelSnap extends RenderProxyBox {
  RenderPixelSnap(this._ratio);

  double _ratio;

  set ratio(double value) {
    if (value == _ratio) return;
    _ratio = value;
    markNeedsPaint();
  }

  /// How far the top left corner is from the nearest device pixel.
  Offset get _shift {
    final at = localToGlobal(Offset.zero);
    double snap(double v) => (v * _ratio).roundToDouble() / _ratio - v;
    return Offset(snap(at.dx), snap(at.dy));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child case final child?) context.paintChild(child, offset + _shift);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final shift = _shift;
    transform.translateByDouble(shift.dx, shift.dy, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _shift,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }
}
