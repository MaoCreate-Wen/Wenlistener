import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'fullscreen_controller.dart';

/// The ONE fullscreen-aware wrapper around `window_manager`'s [DragToMoveArea].
///
/// Every draggable window strip in the app (the shell top bar's middle, the
/// player/lyrics grabber strips, the detail pages' top bands) goes through this
/// widget so the behavior is defined once:
///
///  - drag moves the window, double-click toggles maximize/unmaximize (both
///    come from [DragToMoveArea] itself);
///  - during 沉浸全屏 the gestures are disabled — a `startDragging` on a
///    fullscreen window pops it out of state (same guard the top bar always
///    had), and there is no window to maximize.
///
/// [DragToMoveArea] hit-tests translucently, so hosting it UNDER interactive
/// controls in a `Stack` lets those controls win pointer events.
class WindowDragRegion extends StatelessWidget {
  final Widget child;
  const WindowDragRegion({super.key, this.child = const SizedBox.expand()});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: FullscreenController.isFullscreen,
      builder: (BuildContext context, bool fullscreen, _) =>
          fullscreen ? child : DragToMoveArea(child: child),
    );
  }
}
