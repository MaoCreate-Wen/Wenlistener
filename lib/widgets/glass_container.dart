import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

/// The frosted-glass surface primitive: blur + translucent fill + hairline +
/// optional soft shadow. Every desktop chrome surface (sidebar, mini-player,
/// title bar, cards) is built on this (DESKTOP_UI_PLAN §3).
class GlassContainer extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final bool border;
  final bool shadow;
  final double? radius;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final Color? fill;

  const GlassContainer({
    super.key,
    required this.child,
    this.blur = AppDimens.blurPanel,
    this.opacity = 0.10,
    this.border = true,
    this.shadow = false,
    this.radius,
    this.borderRadius,
    this.padding,
    this.fill,
  });

  @override
  Widget build(BuildContext context) {
    final BorderRadius br =
        borderRadius ?? BorderRadius.circular(radius ?? AppDimens.radiusLg);
    Widget content = ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: fill ?? Colors.white.withValues(alpha: opacity),
            borderRadius: br,
            border: border
                ? Border.all(color: AppColors.glassBorder, width: 1)
                : null,
          ),
          child: child,
        ),
      ),
    );
    if (shadow) {
      content = DecoratedBox(
        decoration:
            BoxDecoration(borderRadius: br, boxShadow: AppDimens.glassShadow),
        child: content,
      );
    }
    return content;
  }
}
