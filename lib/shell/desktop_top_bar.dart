import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../pages/settings/settings_dialog.dart';
import '../router/routes.dart';
import '../state/search_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'fullscreen_controller.dart';
import 'nav_history.dart';
import 'window_buttons.dart';
import 'window_drag_region.dart';

/// Height of the persistent desktop top bar (roomier than the old 38px title bar
/// to seat the search pill).
const double kTopBarHeight = 48;

/// Runs the top-bar / Ctrl+F search: seeds [SearchProvider] with [kw] and switches
/// to the 搜索 branch so its results render.
void submitTopBarSearch(BuildContext context, String kw) {
  final String q = kw.trim();
  if (q.isEmpty) return;
  context.read<SearchProvider>().search(q);
  context.go(Routes.search);
}

/// The persistent top bar mounted above the content area in [AppShell]: ◀ ▶
/// browser-style history arrows, a global search pill, a draggable middle, and on
/// the right a 设置 (settings) button. Persists across every shell branch so
/// history + search + settings are always reachable. (Login / 账号 now live
/// inside the settings dialog, so the old avatar dropdown is gone.)
///
/// The window controls are NOT part of this bar anymore — [WindowButtons] is
/// hosted once by `DesktopWindowFrame` in an overlay pinned top-right above
/// every route (so pushed full-screen surfaces get them too). This bar only
/// reserves the overlay's exact footprint ([WindowButtons.totalWidth]) so the
/// settings button never slides under it; the spacer collapses in 沉浸全屏,
/// exactly like the overlay buttons themselves.
class DesktopTopBar extends StatelessWidget {
  final TextEditingController searchController;
  final FocusNode searchFocus;
  const DesktopTopBar({
    super.key,
    required this.searchController,
    required this.searchFocus,
  });

  @override
  Widget build(BuildContext context) {
    final NavHistory nav = context.watch<NavHistory>();
    return SizedBox(
      height: kTopBarHeight,
      child: Row(
        children: <Widget>[
          const SizedBox(width: AppDimens.space8),
          _NavArrow(
            icon: Icons.arrow_back_ios_new_rounded,
            tooltip: '后退',
            enabled: nav.canBack,
            onTap: nav.back,
          ),
          _NavArrow(
            icon: Icons.arrow_forward_ios_rounded,
            tooltip: '前进',
            enabled: nav.canForward,
            onTap: nav.forward,
          ),
          const SizedBox(width: AppDimens.space12),
          _TopSearchField(
            controller: searchController,
            focusNode: searchFocus,
          ),
          // Draggable middle — the shared [WindowDragRegion] disables itself
          // during 沉浸全屏 (no window to move; a startDragging on a fullscreen
          // window would pop it out of state).
          const Expanded(child: WindowDragRegion()),
          _NavArrow(
            icon: Icons.settings_rounded,
            tooltip: '设置',
            enabled: true,
            onTap: () => showSettingsDialog(context),
          ),
          const SizedBox(width: AppDimens.space8),
          // Footprint of the overlay-hosted WindowButtons (DesktopWindowFrame),
          // collapsing in fullscreen exactly as the overlay does.
          ValueListenableBuilder<bool>(
            valueListenable: FullscreenController.isFullscreen,
            builder: (BuildContext context, bool fullscreen, _) => SizedBox(
              width: fullscreen ? 0 : WindowButtons.totalWidth,
            ),
          ),
        ],
      ),
    );
  }
}

class _NavArrow extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;
  const _NavArrow({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_NavArrow> createState() => _NavArrowState();
}

class _NavArrowState extends State<_NavArrow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bool on = widget.enabled;
    final Color fg = on
        ? (_hover ? AppColors.onSurface : AppColors.onMuted)
        : AppColors.onFaint;
    final Widget btn = MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: on ? widget.onTap : null,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: (on && _hover) ? AppColors.hover : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(widget.icon, size: 15, color: fg),
        ),
      ),
    );
    return on ? Tooltip(message: widget.tooltip, child: btn) : btn;
  }
}

class _TopSearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  const _TopSearchField({required this.controller, required this.focusNode});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 34,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        style: AppTypography.body.copyWith(fontSize: 13),
        textInputAction: TextInputAction.search,
        onSubmitted: (String v) => submitTopBarSearch(context, v),
        cursorColor: AppColors.accentPlay,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索音乐 / 歌手 / 歌单',
          hintStyle: AppTypography.label.copyWith(fontSize: 13),
          prefixIcon: const Icon(Icons.search_rounded,
              size: 18, color: AppColors.onMuted),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 34),
          filled: true,
          fillColor: AppColors.glass,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            borderSide: const BorderSide(color: AppColors.glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            borderSide: const BorderSide(color: AppColors.accentPlay),
          ),
        ),
      ),
    );
  }
}
