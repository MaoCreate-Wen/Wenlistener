import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'hover_scale.dart';

/// A display-font section title with an optional "更多 ›" affordance and/or
/// trailing actions. Used by home carousels and page sections.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onMore;
  final String moreLabel;
  final List<Widget> actions;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onMore,
    this.moreLabel = '更多 ›',
    this.actions = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, AppDimens.space16, 2, AppDimens.space12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title,
                    style: AppTypography.titleM.copyWith(
                        fontFamily: AppTypography.displayFont,
                        fontWeight: FontWeight.w400,
                        fontSize: 18),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!,
                        style: AppTypography.caption, maxLines: 1),
                  ),
              ],
            ),
          ),
          const Spacer(),
          ...actions,
          if (onMore != null)
            HoverBuilder(
              builder: (BuildContext context, bool hovering) => GestureDetector(
                onTap: onMore,
                child: Text(
                  moreLabel,
                  style: AppTypography.caption.copyWith(
                    color: hovering
                        ? AppColors.onSurface
                        : AppColors.onSurfaceFaint,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
