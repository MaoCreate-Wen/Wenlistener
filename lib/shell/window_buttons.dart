import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_colors.dart';
import 'fullscreen_controller.dart';

/// The right-hand window controls — minimize / maximize-restore / close (close
/// hovers red). Extracted from the old `WindowTitleBar` so both the persistent
/// [DesktopTopBar] and the pushed full-screen surfaces (player / lyrics) can host
/// them. Each button is a fixed 46px cell whose height matches the top bar.
///
/// Hidden entirely during 沉浸全屏 (there is no window chrome to manage);
/// gating here covers every host in one place. Restored automatically on exit.
class WindowButtons extends StatelessWidget {
  final double height;
  const WindowButtons({super.key, this.height = 48});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: FullscreenController.isFullscreen,
      builder: (BuildContext context, bool fullscreen, _) {
        if (fullscreen) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _WindowButton(
                icon: Icons.remove,
                action: _WinAction.minimize,
                height: height),
            _WindowButton(
                icon: Icons.crop_square_outlined,
                action: _WinAction.maximize,
                height: height),
            _WindowButton(
                icon: Icons.close,
                action: _WinAction.close,
                danger: true,
                height: height),
          ],
        );
      },
    );
  }
}

enum _WinAction { minimize, maximize, close }

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final _WinAction action;
  final bool danger;
  final double height;
  const _WindowButton({
    required this.icon,
    required this.action,
    required this.height,
    this.danger = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  Future<void> _onTap() async {
    switch (widget.action) {
      case _WinAction.minimize:
        await windowManager.minimize();
      case _WinAction.maximize:
        final bool max = await windowManager.isMaximized();
        if (max) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      case _WinAction.close:
        await windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color hoverFill =
        widget.danger ? const Color(0xFFE81123) : AppColors.hover;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _onTap,
        child: Container(
          width: 46,
          height: widget.height,
          color: _hover ? hoverFill : Colors.transparent,
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 15, color: AppColors.onSurface),
        ),
      ),
    );
  }
}
