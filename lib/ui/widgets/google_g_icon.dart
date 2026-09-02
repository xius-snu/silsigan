import 'package:flutter/material.dart';

/// Four-color Google "G" mark for the sign-in button.
class GoogleGIcon extends StatelessWidget {
  const GoogleGIcon({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Google',
      child: CustomPaint(
        size: Size.square(size),
        painter: const _GoogleGPainter(),
      ),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();

  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.save();
    canvas.scale(s / 24, s / 24);

    const c = Offset(12, 12);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.6
      ..strokeCap = StrokeCap.butt;

    final r = Rect.fromCircle(center: c, radius: 8.2);

    canvas.drawArc(r, -3.05, 1.85, false, ring..color = _red);
    canvas.drawArc(r, 2.05, 1.15, false, ring..color = _yellow);
    canvas.drawArc(r, 0.55, 1.55, false, ring..color = _green);
    canvas.drawArc(r, -0.55, 0.85, false, ring..color = _blue);

    // Horizontal bar of the G (blue).
    canvas.drawRRect(
      RRect.fromLTRBR(11.4, 9.7, 20.6, 14.3, const Radius.circular(0.4)),
      Paint()..color = _blue,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
