import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'hover_scale.dart';

/// Filled call-to-action in the dynamic [accent] (e.g. Play-all). Hover deepens
/// the fill; press scales in without reflow.
class AccentButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color accent;
  final bool dense;

  const AccentButton({
    super.key,
    required this.label,
    required this.accent,
    this.icon,
    this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return HoverScale(
      onTap: onTap,
      child: HoverBuilder(
        builder: (BuildContext context, bool hovering) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.symmetric(
            horizontal: dense ? AppDimens.space16 : AppDimens.space20,
            vertical: dense ? AppDimens.space8 : AppDimens.space12,
          ),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: hovering ? 1 : 0.9),
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            boxShadow: hovering
                ? <BoxShadow>[
                    BoxShadow(
                      color: accent.withValues(alpha: 0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18, color: Colors.black),
                const SizedBox(width: AppDimens.space8),
              ],
              Text(
                label,
                style: AppTypography.label.copyWith(
                  color: Colors.black,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Translucent glass pill button (secondary actions: 收藏 / 导入 / logout).
class GhostButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool dense;
  final Color? tint;

  const GhostButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.dense = false,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final Color fg = tint ?? AppColors.onSurface;
    return HoverScale(
      onTap: onTap,
      child: HoverBuilder(
        builder: (BuildContext context, bool hovering) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.symmetric(
            horizontal: dense ? AppDimens.space16 : AppDimens.space20,
            vertical: dense ? AppDimens.space8 : AppDimens.space12,
          ),
          decoration: BoxDecoration(
            color: hovering ? AppColors.pressed : AppColors.glass,
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            border: Border.all(color: AppColors.glassBorder, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: AppDimens.space8),
              ],
              Text(label,
                  style: AppTypography.label.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A bare hover-tinted icon button (row actions, secondary transport). Circular
/// hover fill, click cursor, optional tooltip.
class IconHoverButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? activeColor;
  final bool active;
  final String? tooltip;

  const IconHoverButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 36,
    this.iconSize = 20,
    this.color,
    this.activeColor,
    this.active = false,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final Color base = active
        ? (activeColor ?? AppColors.accentPlay)
        : (color ?? AppColors.onSurfaceMuted);
    Widget button = HoverBuilder(
      builder: (BuildContext context, bool hovering) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hovering ? AppColors.hover : Colors.transparent,
          ),
          child: Icon(
            icon,
            size: iconSize,
            color: hovering && !active ? AppColors.onSurface : base,
          ),
        ),
      ),
    );
    if (tooltip != null) button = Tooltip(message: tooltip!, child: button);
    return button;
  }
}
