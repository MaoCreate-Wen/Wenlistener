import 'package:flutter/material.dart';

import '../../../models/search_result.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_dimens.dart';
import '../../../theme/app_typography.dart';

/// Horizontal selector across the four primary [SearchType]s. Re-querying is the
/// host's job: [onSelected] forwards to `SearchProvider.setType`, which re-runs
/// the active search.
class SearchTabChips extends StatelessWidget {
  final SearchType selected;
  final ValueChanged<SearchType> onSelected;

  const SearchTabChips({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  static const List<SearchType> _types = <SearchType>[
    SearchType.song,
    SearchType.album,
    SearchType.artist,
    SearchType.playlist,
  ];

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: AppDimens.minTouch,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: _types.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: AppDimens.space8),
        itemBuilder: (BuildContext context, int index) {
          final SearchType type = _types[index];
          return _TabChip(
            label: type.label,
            selected: type == selected,
            accent: accent,
            onTap: () => onSelected(type),
          );
        },
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _TabChip({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
        decoration: BoxDecoration(
          color:
              selected ? accent.withValues(alpha: 0.18) : AppColors.surfaceGlass,
          borderRadius: BorderRadius.circular(AppDimens.radiusPill),
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.55)
                : AppColors.surfaceGlassBorder,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: AppTypography.label.copyWith(
            color: selected ? accent : AppColors.onSurfaceMuted,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
