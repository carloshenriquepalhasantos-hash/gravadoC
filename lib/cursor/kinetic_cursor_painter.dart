import 'dart:ui';

import 'package:flutter/material.dart';

import 'kinetic_cursor_controller.dart';
import 'kinetic_cursor_options.dart';

class KineticCursorPainter extends CustomPainter {
  const KineticCursorPainter({
    required this.controller,
    required this.options,
    required this.timeMs,
  });

  final KineticCursorController controller;
  final KineticCursorOptions options;
  final int timeMs;

  @override
  void paint(Canvas canvas, Size size) {
    if (!options.enabled) return;

    final x = controller.renderedX * size.width;
    final y = controller.renderedY * size.height;
    final scale = options.scale;

    if (options.motionBlur) {
      final intensity = options.motionBlurIntensity / 100;
      for (var i = 4; i >= 1; i--) {
        final offset = i * 3.5 * intensity;
        final paint = Paint()
          ..color = options.highlightColor.withValues(alpha: 0.30 - i * 0.055)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
        canvas.drawCircle(Offset(x - offset, y - offset), 9 * scale, paint);
      }
    }

    final halo = Paint()
      ..color = options.highlightColor.withValues(alpha: 0.22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(Offset(x, y), 18 * scale, halo);

    if (options.clickAnimation) {
      final elapsed = timeMs - controller.lastClickMs;
      if (elapsed >= 0 && elapsed < 250) {
        final phase = elapsed / 250;
        final radius = lerpDouble(10, 34, phase)!.toDouble();
        final alpha = lerpDouble(0.65, 0, phase)!.toDouble();
        canvas.drawCircle(
          Offset(x, y),
          radius * scale,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = options.highlightColor.withValues(alpha: alpha),
        );
      }
    }

    final cursorPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = const Color(0xFF111111)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    Path path;
    if (options.style == CursorStyle.hand) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x, y),
            width: 24 * scale,
            height: 32 * scale,
          ),
          Radius.circular(12 * scale),
        ),
        cursorPaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x, y),
            width: 24 * scale,
            height: 32 * scale,
          ),
          Radius.circular(12 * scale),
        ),
        outline,
      );
      return;
    }

    path = Path()
      ..moveTo(x, y)
      ..lineTo(x + 7 * scale, y + 20 * scale)
      ..lineTo(x + 13 * scale, y + 13 * scale)
      ..lineTo(x + 20 * scale, y + 19 * scale)
      ..lineTo(x + 24 * scale, y + 15 * scale)
      ..lineTo(x + 17 * scale, y + 10 * scale)
      ..lineTo(x + 26 * scale, y + 8 * scale)
      ..close();
    canvas.drawPath(path, cursorPaint);
    canvas.drawPath(path, outline);
  }

  @override
  bool shouldRepaint(covariant KineticCursorPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.options != options ||
      oldDelegate.timeMs != timeMs;
}
