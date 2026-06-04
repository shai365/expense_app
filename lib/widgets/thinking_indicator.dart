import 'dart:math' as math;
import 'package:flutter/material.dart';

class ThinkingIndicator extends StatefulWidget {
  final double size;
  final double strokeWidth;
  final Color? color;
  final Duration duration;

  const ThinkingIndicator({
    super.key,
    this.size = 48,
    this.strokeWidth = 4,
    this.color,
    this.duration = const Duration(milliseconds: 1600),
  });

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

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
    final color = widget.color ?? const Color(0xFF0EA5E9); // Cyber Blue default

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _ThinkingPainter(
              progress: _controller.value,
              color: color,
              strokeWidth: widget.strokeWidth,
            ),
          );
        },
      ),
    );
  }
}

class _ThinkingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  static const double _arcSweep = 100 * math.pi / 180;
  static const double _trailSweep = 50 * math.pi / 180;

  _ThinkingPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color.withValues(alpha: 0.12)
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, trackPaint);

    final easedProgress = _easeInOut(progress);
    final startAngle = -math.pi / 2 + (easedProgress * 2 * math.pi);

    final trailOpacity = 0.25 + 0.3 * math.sin(progress * 2 * math.pi);
    final trailPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color.withValues(alpha: trailOpacity)
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      rect,
      startAngle - _trailSweep - 0.05,
      _trailSweep,
      false,
      trailPaint,
    );

    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, startAngle, _arcSweep, false, arcPaint);
  }

  double _easeInOut(double t) {
    return t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2) / 2;
  }

  @override
  bool shouldRepaint(_ThinkingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}

// ---------------------------------------------------------------------------
// ThinkingBrush — the organic, hand-drawn Claude "brush star" loader.
//
// A burst of ~14 rays radiating from a center point, each with a fixed
// (deterministically-seeded) jitter in angle, length, and stroke width so
// the shape reads as sketched rather than mechanical. Rays "breathe":
// they pulse outward/inward and fade their opacity with a soft sine, each
// offset by a small per-ray phase so the whole mark shimmers as if it's
// thinking. Pure presentation — no app state, no data flow.
// ---------------------------------------------------------------------------

class ThinkingBrush extends StatefulWidget {
  final double size;
  final double strokeWidth;
  final Color? color;
  final Duration duration;
  final int rayCount;

  const ThinkingBrush({
    super.key,
    this.size = 64,
    this.strokeWidth = 3.5,
    this.color,
    this.duration = const Duration(milliseconds: 2400),
    this.rayCount = 14,
  });

  @override
  State<ThinkingBrush> createState() => _ThinkingBrushState();
}

class _ThinkingBrushState extends State<ThinkingBrush>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<_Ray> _rays;

  @override
  void initState() {
    super.initState();
    _rays = _buildRays(widget.rayCount, widget.strokeWidth);
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..repeat();
  }

  // Build the ray geometry ONCE with a fixed seed, so the silhouette is
  // stable across rebuilds — only the breathing animates, not the shape.
  List<_Ray> _buildRays(int count, double baseWidth) {
    final rnd = math.Random(7);
    final rays = <_Ray>[];
    for (var i = 0; i < count; i++) {
      final baseAngle = (i / count) * 2 * math.pi;
      final angle = baseAngle + (rnd.nextDouble() - 0.5) * 0.20; // ±~0.1 rad
      final length = 0.74 + rnd.nextDouble() * 0.26; // 0.74..1.0 of radius
      final phase = rnd.nextDouble() * 0.22; // mostly-synced breathing
      final width = baseWidth * (0.8 + rnd.nextDouble() * 0.55);
      rays.add(_Ray(angle: angle, length: length, phase: phase, width: width));
    }
    return rays;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? const Color(0xFF0EA5E9); // Cyber Blue

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _BrushPainter(
              progress: _controller.value,
              color: color,
              rays: _rays,
            ),
          );
        },
      ),
    );
  }
}

class _Ray {
  final double angle;
  final double length; // fraction of max radius (0..1)
  final double phase; // breathing offset (0..1)
  final double width; // stroke width for this ray

  const _Ray({
    required this.angle,
    required this.length,
    required this.phase,
    required this.width,
  });
}

class _BrushPainter extends CustomPainter {
  final double progress;
  final Color color;
  final List<_Ray> rays;

  _BrushPainter({
    required this.progress,
    required this.color,
    required this.rays,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;
    // Small gap so rays emerge from around a center point, not the exact
    // pixel — reads more like a brush burst.
    final innerGap = maxRadius * 0.12;

    for (final ray in rays) {
      // Per-ray breathing: a soft sine, offset by the ray's phase so the
      // burst shimmers instead of pulsing in lockstep.
      final t = (progress + ray.phase) % 1.0;
      final pulse = (math.sin(t * 2 * math.pi) + 1) / 2; // 0..1

      // Length pulses outward/inward (0.55 ↔ 1.0 of the ray's own length).
      final reach = maxRadius * ray.length * (0.55 + 0.45 * pulse);
      // Opacity breathes up and down.
      final opacity = 0.30 + 0.70 * pulse;

      final dir = Offset(math.cos(ray.angle), math.sin(ray.angle));
      final start = center + dir * innerGap;
      final end = center + dir * reach;

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ray.width
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: opacity.clamp(0.0, 1.0));

      canvas.drawLine(start, end, paint);
    }

    // A soft center anchor that breathes with the overall cycle.
    final centerPulse = (math.sin(progress * 2 * math.pi) + 1) / 2;
    final centerPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.45 + 0.45 * centerPulse);
    canvas.drawCircle(center, maxRadius * 0.07, centerPaint);
  }

  @override
  bool shouldRepaint(_BrushPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.rays != rays;
}
