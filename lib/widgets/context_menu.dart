import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// One entry in a right-click / ⋯ context menu.
class WenMenuAction {
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool danger;

  const WenMenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.danger = false,
  });
}

/// Pops a themed context menu at [position] (global coords) and invokes the
/// chosen action. Used by track rows (right-click) and their ⋯ button. Anchors
/// to the overlay so it works over full-screen routes too.
Future<void> showWenContextMenu(
  BuildContext context,
  Offset position,
  List<WenMenuAction> actions,
) async {
  final RenderBox overlay =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  final WenMenuAction? picked = await showMenu<WenMenuAction>(
    context: context,
    color: AppColors.surface2,
    elevation: 12,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      side: const BorderSide(color: AppColors.glassBorder, width: 1),
    ),
    position: RelativeRect.fromRect(
      Rect.fromPoints(position, position),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<WenMenuAction>>[
      for (final WenMenuAction a in actions)
        PopupMenuItem<WenMenuAction>(
          value: a,
          height: 40,
          child: Row(
            children: <Widget>[
              Icon(a.icon,
                  size: 18,
                  color: a.danger
                      ? const Color(0xFFEF4444)
                      : AppColors.onSurfaceMuted),
              const SizedBox(width: AppDimens.space12),
              Text(
                a.label,
                style: AppTypography.label.copyWith(
                  color: a.danger
                      ? const Color(0xFFEF4444)
                      : AppColors.onSurface,
                ),
              ),
            ],
          ),
        ),
    ],
  );
  picked?.onSelected();
}
