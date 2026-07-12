import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Frameless desktop window frame. Pinned by `MaterialApp.router`'s `builder:`
/// above every route. The custom title bar now lives *inside* the shell as the
/// persistent [DesktopTopBar] (so it can host ◀ ▶ history + search + account),
/// and the pushed full-screen surfaces (player / lyrics) carry their own
/// [WindowButtons]. This frame is therefore a plain OLED backdrop — it only
/// paints the scaffold background behind every route.
class DesktopWindowFrame extends StatelessWidget {
  final Widget child;
  const DesktopWindowFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: AppColors.bg, child: child);
  }
}
