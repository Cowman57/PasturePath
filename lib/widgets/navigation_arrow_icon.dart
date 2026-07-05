import 'dart:math' as math;

import 'package:flutter/material.dart';

/// GPS / travel direction arrow — tip points up at 0° (geographic north).
///
/// Used inside flutter_map marker layers (which already rotate with the map).
/// Pass geographic [headingDeg] only — do not add map camera rotation.
class NavigationArrowIcon extends StatelessWidget {
  const NavigationArrowIcon({
    super.key,
    required this.size,
    this.headingDeg,
    this.color,
  });

  final double size;
  final double? headingDeg;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.blue.shade700;
    final rot = (headingDeg ?? 0) * math.pi / 180.0;
    return Transform.rotate(
      angle: rot,
      child: CustomPaint(
        size: Size.square(size),
        painter: _UpArrowPainter(c),
      ),
    );
  }
}

class _UpArrowPainter extends CustomPainter {
  _UpArrowPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.06)
      ..lineTo(w * 0.86, h * 0.76)
      ..lineTo(w * 0.60, h * 0.66)
      ..lineTo(w * 0.60, h * 0.94)
      ..lineTo(w * 0.40, h * 0.94)
      ..lineTo(w * 0.40, h * 0.66)
      ..lineTo(w * 0.14, h * 0.76)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _UpArrowPainter old) => old.color != color;
}
