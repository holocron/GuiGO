import 'package:flutter/material.dart';

/// A padlock with its shackle swung wide open — the "not encrypted" mark.
/// Material's lock_open leaves a gap too small to read at app-bar size, so
/// the open shackle is drawn lifted and turned off the body.
class OpenLockIcon extends StatelessWidget {
  const OpenLockIcon({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? Colors.white;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _OpenLockPainter(c)),
    );
  }
}

class _OpenLockPainter extends CustomPainter {
  _OpenLockPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * s
      ..strokeCap = StrokeCap.round;
    // the body
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(3 * s, 11 * s, 14 * s, 11 * s),
      Radius.circular(2 * s),
    );
    canvas.drawRRect(body, stroke);
    canvas.drawCircle(
      Offset(10 * s, 16.5 * s),
      1.5 * s,
      Paint()..color = color,
    );
    // the shackle: anchored in the body's right side, swung up and out to
    // the right, its free leg well clear of the body
    final shackle = Path()
      ..moveTo(14 * s, 11 * s)
      ..lineTo(14 * s, 7 * s)
      ..arcToPoint(
        Offset(22 * s, 7 * s),
        radius: Radius.circular(4 * s),
      )
      ..lineTo(22 * s, 9 * s);
    canvas.drawPath(shackle, stroke);
  }

  @override
  bool shouldRepaint(_OpenLockPainter old) => old.color != color;
}
