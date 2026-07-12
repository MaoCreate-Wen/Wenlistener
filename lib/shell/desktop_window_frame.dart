import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'desktop_top_bar.dart';
import 'window_buttons.dart';

/// Frameless desktop window frame. Pinned by `MaterialApp.router`'s `builder:`
/// above every route, so it is the ONE host for the window controls: an OLED
/// backdrop behind the router's pages, with [WindowButtons] pinned top-right
/// ABOVE them. Full-screen routes pushed over the shell (player / lyrics /
/// playlist details) therefore keep minimize / maximize / close without hosting
/// anything themselves; [DesktopTopBar] just reserves the overlay's footprint.
///
/// The overlay is strictly the buttons' own 138×48 top-right box — never a
/// full-width blanket — so it steals no clicks from page content. During
/// 沉浸全屏 [WindowButtons] renders nothing (it watches
/// `FullscreenController.isFullscreen`, a static notifier reachable from this
/// layer), so no dead chrome floats over an immersive surface.
class DesktopWindowFrame extends StatelessWidget {
  final Widget child;
  const DesktopWindowFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bg,
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: child),
          const Positioned(
            top: 0,
            right: 0,
            child: WindowButtons(height: kTopBarHeight),
          ),
        ],
      ),
    );
  }
}
