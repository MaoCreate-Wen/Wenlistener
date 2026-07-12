import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';

/// Centered placeholder for empty / unauthenticated / error views. Optional
/// [action] (e.g. a login CTA) sits below the copy.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.space32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: AppColors.onSurfaceFaint),
            const SizedBox(height: AppDimens.space16),
            Text(title,
                style: AppTypography.titleM, textAlign: TextAlign.center),
            if (message != null) ...<Widget>[
              const SizedBox(height: AppDimens.space8),
              Text(message!,
                  style: AppTypography.label, textAlign: TextAlign.center),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: AppDimens.space20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
