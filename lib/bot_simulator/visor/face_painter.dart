// Draws one FacePose on the visor. Two passes per eye: a blurred glow
// underlay, then a crisp core — the neon-on-OLED look from the
// expression sheet. All geometry is relative to the eye radius so the
// visor scales with the widget.

import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import 'face_pose.dart';

class FacePainter extends CustomPainter {
  const FacePainter({required this.pose});

  final FacePose pose;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width * 0.135, size.height * 0.30);
    final y = size.height * 0.52;
    final leftCenter = Offset(size.width * 0.30, y);
    final rightCenter = Offset(size.width * 0.70, y);

    // Glow underlay, then core.
    _paintEye(canvas, pose.left, leftCenter, r, glow: true);
    _paintEye(canvas, pose.right, rightCenter, r, glow: true);
    _paintEye(canvas, pose.left, leftCenter, r, glow: false);
    _paintEye(canvas, pose.right, rightCenter, r, glow: false);

    if (pose.battery > 0.01) {
      _paintBattery(canvas, size, r);
    }
  }

  Paint _strokePaint(double width, double alpha, {required bool glow}) {
    final paint = Paint()
      ..color = pose.color.withValues(alpha: alpha * (glow ? 0.45 : 1.0))
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (glow) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.9);
    }
    return paint;
  }

  Paint _fillPaint(Color color, double alpha, double blurSigma,
      {required bool glow}) {
    final paint = Paint()
      ..color = color.withValues(alpha: alpha * (glow ? 0.45 : 1.0))
      ..style = PaintingStyle.fill;
    if (glow) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma);
    }
    return paint;
  }

  void _paintEye(Canvas canvas, EyePose eye, Offset center, double baseR,
      {required bool glow}) {
    final r = baseR * eye.radius;
    final strokeW = eye.stroke * baseR;

    canvas.save();
    canvas.translate(
      center.dx + eye.offset.dx * baseR,
      center.dy + eye.offset.dy * baseR,
    );
    canvas.rotate(eye.tilt);
    canvas.scale(1, eye.squash.clamp(0.04, 2.0));

    final arcAlpha = (1.0 - eye.heart - eye.chevron).clamp(0.0, 1.0);
    if (arcAlpha > 0.01) {
      final rect = Rect.fromCircle(center: Offset.zero, radius: r);
      if (eye.fill > 0.01) {
        canvas.drawCircle(
          Offset.zero,
          r,
          _fillPaint(pose.color, arcAlpha * eye.fill, strokeW, glow: glow),
        );
      }
      if (eye.sweep >= math.pi * 2 - 0.01) {
        canvas.drawCircle(Offset.zero, r,
            _strokePaint(strokeW, arcAlpha, glow: glow));
      } else {
        canvas.drawArc(
          rect,
          eye.centerAngle - eye.sweep / 2,
          eye.sweep,
          false,
          _strokePaint(strokeW, arcAlpha, glow: glow),
        );
      }
      if (!glow && eye.pupil > 0.01 && eye.fill > 0.01) {
        canvas.drawCircle(
          Offset(eye.pupilOffset.dx * r, eye.pupilOffset.dy * r),
          r * 0.40,
          Paint()
            ..color =
                const Color(0xFF000000).withValues(alpha: eye.pupil * arcAlpha),
        );
      }
    }

    if (eye.heart > 0.01) {
      canvas.drawPath(
        _heartPath(r * (0.85 + 0.15 * eye.heart)),
        _fillPaint(pose.color, eye.heart, strokeW, glow: glow),
      );
    }

    if (eye.chevron > 0.01) {
      final s = r * (0.85 + 0.15 * eye.chevron);
      final path = Path()
        ..moveTo(s * 0.6, -s * 0.62)
        ..lineTo(-s * 0.45, 0)
        ..lineTo(s * 0.6, s * 0.62);
      canvas.drawPath(path,
          _strokePaint(strokeW, eye.chevron, glow: glow));
    }

    canvas.restore();

    // Decorations sit outside the squash/tilt transform so a blink does
    // not crush the rays or the sparkle.
    final decoCenter =
        center + Offset(eye.offset.dx * baseR, eye.offset.dy * baseR);
    if (eye.rays > 0.01) {
      _paintRays(canvas, decoCenter, r, eye.rays, baseR, glow: glow);
    }
    if (!glow && eye.sparkle > 0.01) {
      _paintSparkle(
        canvas,
        decoCenter + eye.sparkleOffset * r,
        baseR * 0.32,
        eye.sparkle,
      );
    }
    if (eye.brow > 0.01) {
      canvas.drawLine(
        decoCenter + Offset(-r * 0.95, -r * 1.30),
        decoCenter + Offset(r * 0.70, -r * 1.48),
        _strokePaint(baseR * 0.20, eye.brow, glow: glow),
      );
    }
  }

  void _paintRays(Canvas canvas, Offset center, double r, double alpha,
      double baseR,
      {required bool glow}) {
    final paint = _strokePaint(baseR * 0.16, alpha, glow: glow);
    for (final degrees in const [-130.0, -90.0, -50.0]) {
      final a = degrees * math.pi / 180;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        center + dir * (r * 1.30),
        center + dir * (r * 1.62),
        paint,
      );
    }
  }

  void _paintSparkle(Canvas canvas, Offset center, double s, double alpha) {
    final path = Path()
      ..moveTo(center.dx, center.dy - s)
      ..lineTo(center.dx + s * 0.24, center.dy - s * 0.24)
      ..lineTo(center.dx + s, center.dy)
      ..lineTo(center.dx + s * 0.24, center.dy + s * 0.24)
      ..lineTo(center.dx, center.dy + s)
      ..lineTo(center.dx - s * 0.24, center.dy + s * 0.24)
      ..lineTo(center.dx - s, center.dy)
      ..lineTo(center.dx - s * 0.24, center.dy - s * 0.24)
      ..close();
    canvas.drawPath(
      path,
      Paint()..color = const Color(0xFFFFC94A).withValues(alpha: alpha),
    );
  }

  void _paintBattery(Canvas canvas, Size size, double baseR) {
    final w = baseR * 0.85;
    final h = w * 0.48;
    final origin = Offset(size.width - w - baseR * 0.55, baseR * 0.42);
    final alpha = pose.battery;
    final stroke = Paint()
      ..color = pose.color.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.10;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        origin & Size(w, h),
        Radius.circular(h * 0.22),
      ),
      stroke,
    );
    // Terminal nub.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset(origin.dx + w + w * 0.06, origin.dy + h * 0.28) &
            Size(w * 0.12, h * 0.44),
        Radius.circular(w * 0.04),
      ),
      Paint()..color = pose.color.withValues(alpha: alpha),
    );
    // One remaining bar.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset(origin.dx + w * 0.12, origin.dy + h * 0.20) &
            Size(w * 0.20, h * 0.60),
        Radius.circular(h * 0.10),
      ),
      Paint()..color = pose.color.withValues(alpha: alpha),
    );
  }

  Path _heartPath(double s) {
    return Path()
      ..moveTo(0, s * 0.90)
      ..cubicTo(-s * 1.10, s * 0.15, -s * 0.75, -s * 0.70, 0, -s * 0.25)
      ..cubicTo(s * 0.75, -s * 0.70, s * 1.10, s * 0.15, 0, s * 0.90);
  }

  @override
  bool shouldRepaint(covariant FacePainter oldDelegate) =>
      oldDelegate.pose != pose;
}
