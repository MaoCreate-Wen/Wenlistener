import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'desktop_layout.dart';
import 'window_title_bar.dart';

/// App-level wrapper installed via `MaterialApp.router.builder`. On a desktop OS
/// it pins the custom [WindowTitleBar] above **every** route (shell AND
/// full-screen pushed routes like `/player` / `/settings`) so the window
/// controls stay reachable. On mobile / web it is a pure pass-through — the
/// Android widget tree is byte-for-byte what it was before.
class DesktopWindowFrame extends StatelessWidget {
  final Widget child;

  const DesktopWindowFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!DesktopLayout.isDesktopPlatform) return child;
    return ColoredBox(
      color: AppColors.bg,
      child: Column(
        children: <Widget>[
          // The title bar sits above the route Navigator, so it has no Overlay
          // ancestor of its own — its window-control tooltips would throw
          // ("Tooltip widgets require an Overlay"). Give it a bounded Overlay.
          SizedBox(
            height: WindowTitleBar.height,
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(builder: (BuildContext _) => const WindowTitleBar()),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
