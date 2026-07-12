import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../state/player_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'fullscreen_controller.dart';
import 'sidebar_account_card.dart';
import 'sidebar_nav_item.dart';

/// Persistent left navigation rail (glass). Brand wordmark → the three
/// nav items (首页 / 搜索 / 音乐库) with an accent active-pill → spacer → account
/// card (设置 now lives in the top-bar account dropdown). Collapses to a 72px icon
/// rail when [collapsed] (narrow window).
///
/// Performance: like the mini-player, this rail used to sit on a
/// `GlassContainer` (BackdropFilter, sigma 18). It is a layout *sibling* of the
/// content — only the session-frozen wash gradient is painted behind it, and
/// blurring a smooth static gradient is a visual no-op. That filter re-ran a
/// full-height backdrop blur on every composited frame; the plain translucent
/// fill below is pixel-equivalent with zero per-frame raster cost.
class Sidebar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final bool collapsed;

  const Sidebar({
    super.key,
    required this.currentIndex,
    required this.onSelect,
    this.collapsed = false,
  });

  static const List<({IconData icon, IconData active, String label})> _items =
      <({IconData icon, IconData active, String label})>[
    (icon: Icons.home_outlined, active: Icons.home_rounded, label: '首页'),
    (icon: Icons.search_rounded, active: Icons.search_rounded, label: '搜索'),
    (
      icon: Icons.library_music_outlined,
      active: Icons.library_music_rounded,
      label: '音乐库'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final Color accent = context.select((PlayerProvider p) => p.dynamicAccent);
    final double width =
        collapsed ? AppDimens.sidebarRailWidth : AppDimens.sidebarWidth;

    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Same fill GlassContainer painted over its blur (white @ 0.08).
          color: Colors.white.withValues(alpha: 0.08),
          border: const Border(
            right: BorderSide(color: AppColors.glassBorder, width: 1),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space12,
            vertical: AppDimens.space16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _brand(),
              const SizedBox(height: AppDimens.space16),
              for (int i = 0; i < _items.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppDimens.space4),
                  child: SidebarNavItem(
                    icon: _items[i].icon,
                    activeIcon: _items[i].active,
                    label: _items[i].label,
                    active: currentIndex == i,
                    collapsed: collapsed,
                    accent: accent,
                    onTap: () => onSelect(i),
                  ),
                ),
              const Spacer(),
              SidebarAccountCard(collapsed: collapsed),
            ],
          ),
        ),
      ),
    );
  }

  Widget _brand() {
    // Wrapped in a DragToMoveArea so the top-left corner stays draggable now that
    // the window title bar no longer spans the top. The drag wrapper is dropped
    // during 沉浸全屏 (no window to move) — the wordmark itself stays visible.
    final Widget mark = collapsed
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Center(
              child: Text('W',
                  style: TextStyle(
                    fontFamily: AppTypography.displayFont,
                    fontSize: 24,
                    color: AppColors.accentPlay,
                  )),
            ),
          )
        : const Padding(
            padding: EdgeInsets.only(left: 8, top: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontFamily: AppTypography.displayFont,
                    fontSize: 22,
                    color: AppColors.onSurface,
                  ),
                  children: <InlineSpan>[
                    TextSpan(text: 'Wen'),
                    TextSpan(
                        text: 'Listener',
                        style: TextStyle(color: AppColors.accentPlay)),
                  ],
                ),
              ),
            ),
          );
    return ValueListenableBuilder<bool>(
      valueListenable: FullscreenController.isFullscreen,
      builder: (BuildContext context, bool fullscreen, _) =>
          fullscreen ? mark : DragToMoveArea(child: mark),
    );
  }
}
