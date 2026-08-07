import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme/app_colors.dart';
import 'desktop_mini_player.dart';
import 'desktop_sidebar.dart';

/// Wide-layout body: a left [DesktopSidebar], the routed branch page in the
/// content area, and a full-width docked [DesktopMiniPlayer] beneath. Takes the
/// same [StatefulNavigationShell] instance [HomeShell] feeds the mobile layout,
/// so branch/IndexedStack state, the shared `album_art` Hero and mini-player
/// persistence all keep working identically.
class DesktopShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const DesktopShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bg,
      child: Column(
        children: <Widget>[
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                DesktopSidebar(navigationShell: navigationShell),
                Expanded(child: navigationShell),
              ],
            ),
          ),
          const DesktopMiniPlayer(),
        ],
      ),
    );
  }
}
