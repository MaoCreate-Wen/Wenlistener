import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/player_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import '../widgets/glass_container.dart';

/// One bottom-nav destination.
class AppNavTab {
  final String label;
  final IconData icon;
  final IconData activeIcon;

  const AppNavTab({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}

/// Glass bottom navigation with a pill indicator tinted by the dynamic accent.
class AppBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const AppBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  static const List<AppNavTab> tabs = <AppNavTab>[
    AppNavTab(
      label: 'Home',
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
    ),
    AppNavTab(
      label: 'Search',
      icon: Icons.search_outlined,
      activeIcon: Icons.search_rounded,
    ),
    AppNavTab(
      label: 'Library',
      icon: Icons.library_music_outlined,
      activeIcon: Icons.library_music_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final Color accent =
        context.select<PlayerProvider, Color>((PlayerProvider p) => p.dynamicAccent);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.space12,
          0,
          AppDimens.space12,
          AppDimens.space8,
        ),
        child: GlassContainer(
          blur: AppDimens.blurNav,
          radius: AppDimens.radiusPill,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space8,
            vertical: AppDimens.space4,
          ),
          child: SizedBox(
            height: AppDimens.navHeight - 16,
            child: GestureDetector(
              // Horizontal swipe/drag across the bar moves to the adjacent tab.
              behavior: HitTestBehavior.opaque,
              onHorizontalDragEnd: (DragEndDetails d) {
                final double v = d.primaryVelocity ?? 0;
                if (v < -120 && currentIndex < tabs.length - 1) {
                  onTap(currentIndex + 1);
                } else if (v > 120 && currentIndex > 0) {
                  onTap(currentIndex - 1);
                }
              },
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  final double itemWidth = c.maxWidth / tabs.length;
                  return Stack(
                    children: <Widget>[
                      // Shared sliding indicator — GLIDES to the selected tab (a
                      // drag-like motion) instead of each tab fading its own pill.
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutCubic,
                        left: currentIndex * itemWidth,
                        top: 0,
                        bottom: 0,
                        width: itemWidth,
                        child: Padding(
                          padding: const EdgeInsets.all(AppDimens.space4),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.18),
                              borderRadius:
                                  BorderRadius.circular(AppDimens.radiusPill),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: <Widget>[
                          for (int i = 0; i < tabs.length; i++)
                            Expanded(
                              child: _NavItem(
                                tab: tabs[i],
                                selected: i == currentIndex,
                                accent: accent,
                                onTap: () => onTap(i),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final AppNavTab tab;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _NavItem({
    required this.tab,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? accent : AppColors.onSurfaceMuted;
    // The selected pill is now the shared sliding indicator behind the Row; each
    // item just fades + gently scales its glyph as it becomes active.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          AnimatedScale(
            scale: selected ? 1.0 : 0.9,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: Icon(selected ? tab.activeIcon : tab.icon, size: 22, color: color),
          ),
          const SizedBox(height: 2),
          Text(tab.label, style: AppTypography.caption.copyWith(color: color)),
        ],
      ),
    );
  }
}
