import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import 'glass_motion.dart';

/// The frosted-glass surface primitive: blur + translucent fill + hairline.
class GlassContainer extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final bool border;
  final double? radius;
  final EdgeInsetsGeometry? padding;

  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 24,
    this.opacity = 0.10,
    this.border = true,
    this.radius,
    this.padding,
  });

  /// Opaque frosted stand-in used WHILE the backdrop is animating (see
  /// [GlassMotion]). Dark enough to hide fast-moving content, so a live
  /// `BackdropFilter` read-back/blur isn't paid on every animation frame.
  static const Color _motionScrim = Color(0xE60B0B10);

  @override
  Widget build(BuildContext context) {
    final BorderRadius br = BorderRadius.circular(radius ?? AppDimens.radiusLg);
    // The tinted fill + hairline is IDENTICAL in both states and prebuilt once, so
    // flipping motion state swaps only the glass LAYER, never rebuilds the child.
    final Widget fill = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: opacity),
        borderRadius: br,
        border: border
            ? Border.all(color: AppColors.surfaceGlassBorder, width: 1)
            : null,
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: br,
      child: ValueListenableBuilder<bool>(
        valueListenable: GlassMotion.moving,
        child: fill,
        builder: (BuildContext context, bool moving, Widget? built) {
          if (moving) {
            // Motion: flat scrim, no back-buffer sampling → ~free on the raster
            // thread. Restores the real blur the instant motion stops.
            return DecoratedBox(
              decoration: BoxDecoration(color: _motionScrim, borderRadius: br),
              child: built,
            );
          }
          return BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: built,
          );
        },
      ),
    );
  }
}
