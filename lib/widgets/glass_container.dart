import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

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

  @override
  Widget build(BuildContext context) {
    final BorderRadius br = BorderRadius.circular(radius ?? AppDimens.radiusLg);
    return ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: opacity),
            borderRadius: br,
            border: border
                ? Border.all(color: AppColors.surfaceGlassBorder, width: 1)
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}
