import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// Neutral placeholder shown by the bootstrap router until real pages
/// (Streams 2–5) replace it.
class PlaceholderPage extends StatelessWidget {
  final String title;

  const PlaceholderPage({super.key, this.title = 'Coming soon'});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.music_note_rounded,
              color: AppColors.onSurfaceFaint,
              size: 48,
            ),
            const SizedBox(height: AppDimens.space12),
            Text(title, style: AppTypography.titleL),
          ],
        ),
      ),
    );
  }
}
