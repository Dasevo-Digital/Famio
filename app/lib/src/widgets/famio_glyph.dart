import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The house with a heart from the app icon, drawn as vectors so it stays
/// sharp at every size and pixel density (a scaled bitmap looked soft on a
/// large Mac window). Same shapes as `glyph(size, 0.8)` in
/// tool/make_icons.py, on a transparent square of [size].
class FamioGlyph extends StatelessWidget {
  const FamioGlyph({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const CustomPaint(painter: _GlyphPainter()),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter();

  static const _heart = Color(0xFFEC5A86);

  @override
  void paint(Canvas canvas, Size size) {
    // Glyph units: 100 wide, 80 % of the square.
    final u = size.shortestSide * 0.8 / 100;
    final cx = size.width / 2;
    final top = size.height / 2 - 48 * u;
    final white = Paint()..color = Colors.white;
    final apex = Offset(cx, top + 4 * u);
    // Roof: a thick line with round caps and joint.
    canvas.drawPath(
      Path()
        ..moveTo(cx - 44 * u, top + 38 * u)
        ..lineTo(apex.dx, apex.dy)
        ..lineTo(cx + 44 * u, top + 38 * u),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 13 * u
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    // Body below the roof.
    canvas.drawRRect(
      RRect.fromLTRBR(
        cx - 32 * u,
        top + 30 * u,
        cx + 32 * u,
        top + 92 * u,
        Radius.circular(9 * u),
      ),
      white,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - 32 * u, top + 30 * u)
        ..lineTo(apex.dx, apex.dy)
        ..lineTo(cx + 32 * u, top + 30 * u)
        ..close(),
      white,
    );
    // Classic parametric heart in the middle of the house.
    final w = 34 * u;
    final heartY = top + 62 * u;
    final heart = Path();
    for (var i = 0; i < 200; i++) {
      final t = 2 * math.pi * i / 200;
      final s = math.sin(t);
      final x = 16 * s * s * s;
      final y =
          13 * math.cos(t) -
          5 * math.cos(2 * t) -
          2 * math.cos(3 * t) -
          math.cos(4 * t);
      final p = Offset(cx + x * w / 32, heartY - y * w / 32 - w * 0.03);
      i == 0 ? heart.moveTo(p.dx, p.dy) : heart.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(heart..close(), Paint()..color = _heart);
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) => false;
}
