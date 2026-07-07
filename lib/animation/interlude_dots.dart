import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The breathing "interlude" dots shown during an instrumental gap, ported from
/// AMLL `dom/interlude-dots.ts`. See `AMLL_ANIMATION_SPEC.md` §6.
///
/// Only renders when [gapDuration] is at least 4000ms. Three dots breathe
/// (±0.05 scale) while a fill lights dot 0 → 1 → 2 as a progress indicator,
/// growing in over the first 2s and shrinking out over the final 750ms.
class InterludeDots extends StatefulWidget {
  /// Length of the instrumental gap.
  final Duration gapDuration;

  /// Dot tint; defaults to the theme primary (dynamic accent on the player).
  final Color? color;

  /// Diameter of a single dot.
  final double dotSize;

  const InterludeDots({
    super.key,
    required this.gapDuration,
    this.color,
    this.dotSize = 12,
  });

  /// The threshold below which interludes are not surfaced.
  static const Duration minGap = Duration(milliseconds: 4000);

  @override
  State<InterludeDots> createState() => _InterludeDotsState();
}

class _InterludeDotsState extends State<InterludeDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.gapDuration,
  )..forward();

  @override
  void didUpdateWidget(InterludeDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gapDuration != widget.gapDuration) {
      _controller
        ..stop()
        ..duration = widget.gapDuration
        ..forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.gapDuration < InterludeDots.minGap) {
      return const SizedBox.shrink();
    }
    final Color color = widget.color ?? Theme.of(context).colorScheme.primary;
    final double dur = widget.gapDuration.inMilliseconds.toDouble();

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? _) {
          final double t = (_controller.value * dur).clamp(0.0, dur);
          return CustomPaint(
            size: Size(widget.dotSize * 5, widget.dotSize),
            painter: _DotsPainter(
              t: t,
              dur: dur,
              color: color,
              dotSize: widget.dotSize,
            ),
          );
        },
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter({
    required this.t,
    required this.dur,
    required this.color,
    required this.dotSize,
  });

  final double t;
  final double dur;
  final Color color;
  final double dotSize;

  @override
  void paint(Canvas canvas, Size size) {
    // Overall breathing scale (§6).
    final double breathe = dur / (dur / 1500).ceil();
    double scale = math.sin(1.5 * math.pi - 2 * t / breathe) / 20 + 1;

    if (t < 2000) {
      scale *= _easeOutExpo((t / 2000).clamp(0.0, 1.0));
    }

    final double shrinkStart = dur - 750;
    if (t > shrinkStart) {
      // Shrink the group to ×0.5 (not all the way to 0) over the final 750ms:
      // AMLL halves the easeInOutBack arg — `(750-(dur-t))/750/2`, which reaches
      // 0.5 at the very end, and easeInOutBack(0.5)=0.5 → scale ×(1-0.5)
      // (interlude-dots.ts:100-106). Without the `/2` it shrank fully to 0.
      scale *= 1 - _easeInOutBack(((t - shrinkStart) / 750 / 2).clamp(0.0, 1.0));
    }

    scale = math.max(0, scale) * 0.7;

    // Group opacity: fade-in 500–1000ms, fade-out in the final 375ms.
    double opacity = 1;
    if (t < 500) {
      opacity = 0;
    } else if (t < 1000) {
      opacity = (t - 500) / 500;
    }
    final double fadeOutStart = dur - 375;
    if (t > fadeOutStart) {
      opacity *= ((dur - t) / 375).clamp(0.0, 1.0);
    }
    if (opacity <= 0 || scale <= 0) return;

    final double r = (dotSize / 2) * scale;
    final double gap = dotSize * 1.6;
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final List<double> xs = <double>[cx - gap, cx, cx + gap];

    // Per-dot OPACITY (progress lights dot0 → 1 → 2): each dot ramps 0.25 → 1 as
    // `(elapsed*3/dotsDuration)*0.75` (clamped), staggered by `dotsDuration/3`,
    // then multiplied by the group opacity — AMLL `interlude-dots.ts:115-152`.
    // `dotsDuration = max(0, dur-750)` (the breathing window minus the shrink).
    final double dotsDuration = math.max(0.0, dur - 750);
    final double dotStep = dotsDuration / 3;
    for (int i = 0; i < 3; i++) {
      final double elapsed = t - dotStep * i;
      final double dotOpacity = dotsDuration <= 0
          ? 1.0
          : ((elapsed * 3 / dotsDuration) * 0.75).clamp(0.25, 1.0);
      final double a = (opacity * dotOpacity).clamp(0.0, 1.0);
      final Paint paint = Paint()
        ..color = color.withValues(alpha: a)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(xs[i], cy), r, paint);
    }
  }

  static double _easeOutExpo(double x) =>
      x >= 1 ? 1 : 1 - math.pow(2, -10 * x).toDouble();

  static double _easeInOutBack(double x) {
    const double c1 = 1.70158;
    const double c2 = c1 * 1.525;
    if (x < 0.5) {
      final double v = 2 * x;
      return (v * v * ((c2 + 1) * v - c2)) / 2;
    }
    final double v = 2 * x - 2;
    return (v * v * ((c2 + 1) * v + c2) + 2) / 2;
  }

  @override
  bool shouldRepaint(_DotsPainter old) =>
      old.t != t || old.color != color || old.dur != dur;
}
