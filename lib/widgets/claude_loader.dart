import 'dart:math' as math;

import 'package:flutter/material.dart';

/// An animated, Claude-style "thinking star" loader.
///
/// Built in isolation — it depends on nothing else in the app and can be
/// dropped anywhere a [Widget] is expected. Drives a single infinite
/// animation loop (~3s) that combines:
///   * a continuous, linear 360° rotation, and
///   * a soft `sin`-based "breathing" of scale (0.8 ↔ 1.1) and opacity.
///
/// The star itself is drawn with a [CustomPainter] (a clean multi-ray /
/// four-point sparkle) so it matches the hand-drawn reference without
/// leaning on a specific Material glyph. Set [useIcon] to `true` to fall
/// back to [Icons.brightness_high_rounded] instead.
class ClaudeLoader extends StatefulWidget {
  const ClaudeLoader({
    super.key,
    this.size = 64,
    this.color = const Color(0xFF0EA5E9),
    this.duration = const Duration(seconds: 3),
    this.useIcon = false,
  });

  /// Side length of the (square) loader in logical pixels.
  final double size;

  /// Coral/peach star color.
  final Color color;

  /// One full rotation + breathing cycle.
  final Duration duration;

  /// When true, render [Icons.brightness_high_rounded] instead of the
  /// custom-painted sparkle.
  final bool useIcon;

  @override
  State<ClaudeLoader> createState() => _ClaudeLoaderState();
}

class _ClaudeLoaderState extends State<ClaudeLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = _controller.value; // 0..1 over the full cycle.

          // Continuous slow rotation: a full turn each cycle.
          final angle = t * 2 * math.pi;

          // Soft breathing via sin. sin(2πt) → [-1, 1]; remap to [0, 1].
          final breath = (math.sin(t * 2 * math.pi) + 1) / 2;

          // Scale pulses 0.8 ↔ 1.1.
          final scale = 0.8 + breath * (1.1 - 0.8);

          // Opacity gently fades 0.65 ↔ 1.0 so the pulse reads softly.
          final opacity = 0.65 + breath * (1.0 - 0.65);

          return Opacity(
            opacity: opacity,
            child: Transform.rotate(
              angle: angle,
              child: Transform.scale(
                scale: scale,
                child: child,
              ),
            ),
          );
        },
        child: widget.useIcon
            ? Icon(
                Icons.brightness_high_rounded,
                size: widget.size,
                color: widget.color,
              )
            : CustomPaint(
                size: Size.square(widget.size),
                painter: _StarPainter(color: widget.color),
              ),
      ),
    );
  }
}

/// Paints a clean four-point sparkle/star with softly concave sides —
/// the silhouette of the Claude "thinking" mark.
class _StarPainter extends CustomPainter {
  const _StarPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = size.width / 2;

    // Distance of the "valleys" between rays from the center. Smaller =
    // sharper, more needle-like rays (the hand-drawn look).
    final inner = outer * 0.18;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    const points = 4; // four primary rays
    final path = Path();

    // Build alternating outer (ray tip) / inner (valley) vertices, then
    // join the valleys with quadratic curves so the rays look concave.
    final verts = <Offset>[];
    final isOuter = <bool>[];
    final steps = points * 2;
    for (var i = 0; i < steps; i++) {
      final outerVertex = i.isEven;
      final r = outerVertex ? outer : inner;
      // Start pointing straight up.
      final theta = (i / steps) * 2 * math.pi - math.pi / 2;
      verts.add(Offset(
        center.dx + r * math.cos(theta),
        center.dy + r * math.sin(theta),
      ));
      isOuter.add(outerVertex);
    }

    for (var i = 0; i < verts.length; i++) {
      final v = verts[i];
      if (i == 0) {
        path.moveTo(v.dx, v.dy);
      } else if (isOuter[i]) {
        // Curve into each ray tip through the preceding valley for a
        // soft, hand-drawn concavity.
        path.quadraticBezierTo(verts[i - 1].dx, verts[i - 1].dy, v.dx, v.dy);
      } else {
        path.lineTo(v.dx, v.dy);
      }
    }
    path.close();

    canvas.drawPath(path, paint);

    // A small center dot to anchor the rays, like the reference mark.
    canvas.drawCircle(center, outer * 0.10, paint);
  }

  @override
  bool shouldRepaint(_StarPainter oldDelegate) => oldDelegate.color != color;
}
