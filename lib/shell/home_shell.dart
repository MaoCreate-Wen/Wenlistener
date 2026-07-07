import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_colors.dart';
import 'bottom_nav_bar.dart';
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
      body: Column(
        children: <Widget>[
          Expanded(child: navigationShell),
          const MiniPlayer(),
          AppBottomNav(
            currentIndex: navigationShell.currentIndex,
            onTap: (int index) => navigationShell.goBranch(
              index,
              initialLocation: index == navigationShell.currentIndex,
            ),
          ),
        ],
      ),
    );
  }
}
