import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Session-only immersive fullscreen state (沉浸全屏). NOT persisted — a window
/// always starts windowed.
///
/// Single source of truth: [isFullscreen] flips only after the
/// `window_manager` call succeeds, so UI gated on it (window buttons, drag
/// strips) can never desync from the real window state. Toggled globally by
/// F11 (and exited by Esc) via the key handler installed in `app.dart`, and by
/// the 沉浸全屏 row in the settings dialog.
class FullscreenController {
  FullscreenController._();

  /// Whether the window is currently fullscreen. Listen with a
  /// [ValueListenableBuilder] to hide window chrome while immersed.
  static final ValueNotifier<bool> isFullscreen = ValueNotifier<bool>(false);

  /// window_manager throws on non-desktop platforms — same guard style as
  /// `main.dart`'s window bootstrap.
  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Enters/leaves fullscreen. For a frameless window `setFullScreen(true)`
  /// covers the entire screen including the taskbar.
  static Future<void> setFullscreen(bool on) async {
    if (!_isDesktop || isFullscreen.value == on) return;
    await windowManager.setFullScreen(on);
    isFullscreen.value = on;
  }

  static Future<void> toggle() => setFullscreen(!isFullscreen.value);
}
