import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// Row heading for home carousels / list sections, with an optional "More".
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onMore;

  const SectionHeader({super.key, required this.title, this.onMore});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(title, style: AppTypography.titleL)),
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.onSurfaceMuted,
                minimumSize: const Size(AppDimens.minTouch, AppDimens.minTouch),
              ),
              child: const Text('More'),
            ),
        ],
      ),
    );
  }
}
