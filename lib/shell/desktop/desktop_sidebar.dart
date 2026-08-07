import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../router/routes.dart';
import '../../services/netease_api.dart';
import '../../state/auth_provider.dart';
import '../../state/player_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/glass_container.dart';
import '../bottom_nav_bar.dart';

/// Left glass rail for the desktop shell. Reuses [AppBottomNav.tabs] (Home /
/// Search / Library) driving `navigationShell.goBranch`, adds a Settings item
/// (pushes the existing `/settings` route) and a bottom account card
/// (pushes `/accounts`). The active nav item is a pill tinted by the dynamic
/// accent — the same `context.select` the bottom nav uses.
class DesktopSidebar extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const DesktopSidebar({super.key, required this.navigationShell});

  /// Fixed rail width (mockup §① side = 230).
  static const double width = 230;

  @override
  Widget build(BuildContext context) {
    final Color accent =
        context.select<PlayerProvider, Color>((PlayerProvider p) => p.dynamicAccent);
    final int currentIndex = navigationShell.currentIndex;

    return SizedBox(
      width: width,
      child: GlassContainer(
        blur: AppDimens.blurNav,
        radius: 0,
        padding: const EdgeInsets.fromLTRB(
          AppDimens.space12,
          AppDimens.space16,
          AppDimens.space12,
          AppDimens.space16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _SidebarLogo(),
            const SizedBox(height: AppDimens.space8),
            for (int i = 0; i < AppBottomNav.tabs.length; i++)
              _SidebarItem(
                icon: AppBottomNav.tabs[i].icon,
                activeIcon: AppBottomNav.tabs[i].activeIcon,
                label: AppBottomNav.tabs[i].label,
                selected: i == currentIndex,
                accent: accent,
                onTap: () => navigationShell.goBranch(
                  i,
                  initialLocation: i == currentIndex,
                ),
              ),
            _SidebarItem(
              icon: Icons.settings_outlined,
              activeIcon: Icons.settings_rounded,
              label: 'Settings',
              selected: false,
              accent: accent,
              onTap: () => context.push(Routes.settings),
            ),
            const Spacer(),
            const _AccountCard(),
          ],
        ),
      ),
    );
  }
}

class _SidebarLogo extends StatelessWidget {
  const _SidebarLogo();

  @override
  Widget build(BuildContext context) {
    final Color accent =
        context.select<PlayerProvider, Color>((PlayerProvider p) => p.dynamicAccent);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space8,
        AppDimens.space8,
        AppDimens.space8,
        AppDimens.space12,
      ),
      child: Text.rich(
        TextSpan(
          style: AppTypography.titleL.copyWith(fontSize: 20),
          children: <TextSpan>[
            const TextSpan(text: 'Wen'),
            TextSpan(text: 'Listener', style: TextStyle(color: accent)),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final Color color =
        widget.selected ? AppColors.onSurface : AppColors.onSurfaceMuted;
    final Color fill = widget.selected
        ? widget.accent.withValues(alpha: 0.22)
        : (_hovering ? AppColors.surfaceGlass : Colors.transparent);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space12,
              vertical: AppDimens.space12,
            ),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(AppDimens.radiusSm),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  widget.selected ? widget.activeIcon : widget.icon,
                  size: 20,
                  color: color,
                ),
                const SizedBox(width: AppDimens.space12),
                Text(widget.label, style: AppTypography.body.copyWith(color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom account card. Shows the signed-in Netease account (avatar seed + name
/// + VIP tier) when logged in, otherwise a "sign in" prompt. Tapping opens the
/// existing multi-account manager route.
class _AccountCard extends StatelessWidget {
  const _AccountCard();

  @override
  Widget build(BuildContext context) {
    final bool loggedIn =
        context.select<AuthProvider, bool>((AuthProvider a) => a.isLoggedIn);
    final NeteaseAccount? account =
        context.select<AuthProvider, NeteaseAccount?>((AuthProvider a) => a.account);
    final Color accent =
        context.select<PlayerProvider, Color>((PlayerProvider p) => p.dynamicAccent);

    final String primary = loggedIn
        ? (account?.nickname ?? '已登录')
        : '未登录';
    final String secondary = loggedIn
        ? ((account?.vipType ?? 0) > 0 ? '黑胶 VIP' : '网易云音乐')
        : '点击登录 / 管理账号';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.push(Routes.accounts),
        child: Container(
          padding: const EdgeInsets.all(AppDimens.space8),
          decoration: BoxDecoration(
            color: AppColors.surfaceGlass,
            borderRadius: BorderRadius.circular(AppDimens.radiusMd),
            border: Border.all(color: AppColors.surfaceGlassBorder, width: 1),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[AppColors.seed, accent],
                  ),
                ),
                child: loggedIn
                    ? null
                    : const Icon(Icons.person_outline,
                        size: 18, color: AppColors.onSurface),
              ),
              const SizedBox(width: AppDimens.space8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      primary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.label.copyWith(color: AppColors.onSurface),
                    ),
                    Text(
                      secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
