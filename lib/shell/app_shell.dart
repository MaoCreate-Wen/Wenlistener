import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../state/player_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_motion.dart';
import 'desktop_top_bar.dart';
import 'mini_player.dart';
import 'sidebar.dart';

/// The desktop shell: a persistent left [Sidebar] beside the branch content, a
/// persistent [DesktopTopBar] above the content (◀ ▶ history, search, account
/// dropdown + window controls) and a docked [MiniPlayer] at the bottom, over the
/// album-art wash. The [StatefulShellRoute] branches (首页 / 搜索 / 音乐库) live in
/// [navigationShell], so switching tabs keeps the chrome mounted. The wash freezes
/// on the session's first song (owned by [PlayerProvider]) and is read via
/// `context.select` so only it repaints on a song change — not on every tick.
class AppShell extends StatefulWidget {
  final StatefulNavigationShell navigationShell;
  const AppShell({super.key, required this.navigationShell});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _goBranch(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Gradient wash =
        context.select((PlayerProvider p) => p.washGradient);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
              _searchFocus.requestFocus(),
        },
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: AppMotion.wash,
                child: DecoratedBox(
                  key: ValueKey<Gradient>(wash),
                  decoration: BoxDecoration(gradient: wash),
                ),
              ),
            ),
            Column(
              children: <Widget>[
                Expanded(
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints c) {
                      final bool collapsed =
                          c.maxWidth < AppDimens.sidebarCollapseWidth;
                      return Row(
                        children: <Widget>[
                          // RepaintBoundary: keeps content scrolls/animations
                          // from re-rasterising the static rail and vice versa.
                          RepaintBoundary(
                            child: Sidebar(
                              currentIndex:
                                  widget.navigationShell.currentIndex,
                              onSelect: _goBranch,
                              collapsed: collapsed,
                            ),
                          ),
                          Expanded(
                            child: Column(
                              children: <Widget>[
                                DesktopTopBar(
                                  searchController: _searchCtrl,
                                  searchFocus: _searchFocus,
                                ),
                                Expanded(child: widget.navigationShell),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                // RepaintBoundary: the bar's own repaints (song change; the
                // progress line has a further boundary inside) stay out of the
                // content layer, and content scrolls stay out of the bar.
                const RepaintBoundary(child: MiniPlayer()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
