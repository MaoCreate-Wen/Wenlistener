import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_colors.dart';
import '../widgets/glass_motion.dart';
import 'bottom_nav_bar.dart';
import 'desktop/desktop_layout.dart';
import 'desktop/desktop_shell.dart';
import 'mini_player.dart';

/// Persistent app shell: the active branch fills the body, with the mini-player
/// and glass bottom-nav pinned beneath it.
class HomeShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const HomeShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Desktop (wide window on a desktop OS): sidebar + docked mini-player.
          // On Android this guard is always false → the mobile shell below is
          // rendered verbatim, untouched.
          if (DesktopLayout.active(constraints.maxWidth)) {
            return DesktopShell(navigationShell: navigationShell);
          }
          // --- existing mobile shell, unchanged ---
          return Column(
            children: <Widget>[
              // Flag "in motion" while the body scrolls so the pinned glass bars
              // below drop their live BackdropFilter (raster tax) during the
              // scroll and restore the blur when it settles.
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (ScrollNotification n) {
                    if (n is ScrollStartNotification ||
                        n is ScrollUpdateNotification) {
                      GlassMotion.scrollTick();
                    }
                    return false;
                  },
                  child: navigationShell,
                ),
              ),
              const MiniPlayer(),
              AppBottomNav(
                currentIndex: navigationShell.currentIndex,
                onTap: (int index) => navigationShell.goBranch(
                  index,
                  initialLocation: index == navigationShell.currentIndex,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
