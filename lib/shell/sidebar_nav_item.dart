import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_motion.dart';
import '../theme/app_typography.dart';

/// A left-rail navigation row: icon + label with a hover fill and an active pill
/// tinted by the dynamic [accent] (`color-mix(accent 22%)`). Collapses to an
/// icon-only tile in the narrow rail ([collapsed]).
class SidebarNavItem extends StatefulWidget {
  final IconData icon;
  final IconData? activeIcon;
  final String label;
  final bool active;
  final bool collapsed;
  final Color accent;
  final VoidCallback onTap;

  const SidebarNavItem({
    super.key,
    required this.icon,
    this.activeIcon,
    required this.label,
    required this.active,
    required this.collapsed,
    required this.accent,
    required this.onTap,
  });

  @override
  State<SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<SidebarNavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Color fg = widget.active ? AppColors.onSurface : AppColors.onSurfaceMuted;
    final Color fill = widget.active
        ? Color.alphaBlend(
            widget.accent.withValues(alpha: 0.22), Colors.transparent)
        : _hover
            ? AppColors.hover
            : Colors.transparent;

    final Widget content = widget.collapsed
        ? Center(child: Icon(widget.active ? (widget.activeIcon ?? widget.icon) : widget.icon, size: 22, color: fg))
        : Row(
            children: <Widget>[
              Icon(widget.active ? (widget.activeIcon ?? widget.icon) : widget.icon,
                  size: 20, color: fg),
              const SizedBox(width: AppDimens.space12),
              Text(
                widget.label,
                style: AppTypography.body.copyWith(
                  fontSize: 14,
                  color: fg,
                  fontWeight:
                      widget.active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          );

    final Widget tile = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: EdgeInsets.symmetric(
            horizontal: widget.collapsed ? 0 : AppDimens.space12,
            vertical: 11,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
          ),
          child: content,
        ),
      ),
    );

    return widget.collapsed
        ? Tooltip(message: widget.label, child: tile)
        : tile;
  }
}
