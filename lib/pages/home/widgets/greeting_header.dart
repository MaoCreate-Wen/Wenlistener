import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_dimens.dart';
import '../../../theme/app_typography.dart';

/// Time-of-day greeting rendered in the display face. Sits at the top of the
/// discovery feed and scrolls away with the content.
class GreetingHeader extends StatelessWidget {
  const GreetingHeader({super.key, this.subtitle = '今天想听点什么？'});

  /// Secondary muted line under the greeting.
  final String subtitle;

  /// Maps an hour-of-day (0–23) to a localized greeting.
  static String greetingForHour(int hour) {
    if (hour >= 5 && hour < 11) return '早上好';
    if (hour >= 11 && hour < 13) return '中午好';
    if (hour >= 13 && hour < 18) return '下午好';
    if (hour >= 18 && hour < 23) return '晚上好';
    return '夜深了';
  }

  @override
  Widget build(BuildContext context) {
    final String greeting = greetingForHour(DateTime.now().hour);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.screenPadding,
        AppDimens.space8,
        AppDimens.screenPadding,
        AppDimens.space12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(greeting, style: AppTypography.displayM),
          const SizedBox(height: AppDimens.space4),
          Text(
            subtitle,
            style: AppTypography.label.copyWith(color: AppColors.onSurfaceMuted),
          ),
        ],
      ),
    );
  }
}
