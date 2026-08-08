import 'dart:async';
import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../animation/neon_flow_background.dart';
import '../app.dart' show lightweightMode;
import '../services/audio_service.dart';
import '../services/settings_store.dart';
import '../state/settings_provider.dart';

/// System-tray icon + menu + close-behavior + 轻量模式 owner. Built once in
/// `main()` (after the service graph, before `runApp`) and alive for the whole
/// process — it deliberately lives OUTSIDE the widget tree so tray controls and
/// the close setting keep working while 轻量模式 has the UI tree disposed.
///
/// Responsibilities:
///  - always-on tray icon (the runner's own `app_icon.ico`, bundled under
///    `assets/` — tray_manager resolves asset keys against the exe-adjacent
///    `data/flutter_assets/`, so the same key works in debug AND release);
///  - left-click → show main window (also leaves 轻量模式);
///  - right-click → context menu: 显示主界面 / 播放暂停·上一首·下一首 (wired
///    straight to [AudioService]) / 轻量模式 checkbox / 退出;
///  - window ✕ → per [SettingsProvider.closeBehavior]: really exit, or hide to
///    tray (playback continues);
///  - 轻量模式: hide the window, flip [lightweightMode] so the whole UI tree is
///    disposed, then drop the decoded-image + mesh-texture caches.
class TrayController with TrayListener, WindowListener {
  TrayController({required this.audio, required this.settings});

  final AudioService audio;
  final SettingsProvider settings;

  /// Menu item keys.
  static const String _kShow = 'show';
  static const String _kTogglePlay = 'toggle_play';
  static const String _kPrev = 'prev';
  static const String _kNext = 'next';
  static const String _kLightweight = 'lightweight';
  static const String _kExit = 'exit';

  /// The runner icon, bundled as a Flutter asset (see pubspec `assets/`).
  /// tray_manager joins this onto `<exe dir>/data/flutter_assets/`, which
  /// exists next to both the Debug and the Release runner.
  static const String _iconAsset = 'assets/app_icon.ico';

  /// True once [_exit] starts — guards [onWindowClose] re-entry while the
  /// window is being destroyed for real.
  bool _quitting = false;

  Future<void> init() async {
    if (!Platform.isWindows) return;
    // ✕ no longer destroys the window directly; it lands in [onWindowClose].
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    trayManager.addListener(this);
    await trayManager.setIcon(_iconAsset);
    await trayManager.setToolTip('WenListener');
    await _refreshMenu();
  }

  /// (Re)builds the context menu — called at init and whenever the 轻量模式
  /// checkbox state changes so the menu stays truthful.
  Future<void> _refreshMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: <MenuItem>[
          MenuItem(key: _kShow, label: '显示主界面'),
          MenuItem.separator(),
          MenuItem(key: _kTogglePlay, label: '播放 / 暂停'),
          MenuItem(key: _kPrev, label: '上一首'),
          MenuItem(key: _kNext, label: '下一首'),
          MenuItem.separator(),
          MenuItem.checkbox(
            key: _kLightweight,
            label: '轻量模式',
            checked: lightweightMode.value,
          ),
          MenuItem.separator(),
          MenuItem(key: _kExit, label: '退出'),
        ],
      ),
    );
  }

  // --- tray events ----------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    unawaited(showMainWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    // `bringAppToFront: true` is LOAD-BEARING on Windows (despite the
    // deprecation): it makes the plugin call SetForegroundWindow before
    // TrackPopupMenu. Without it the menu paints but its modal loop never
    // receives input — items can't be clicked and the menu can't be dismissed
    // (the classic Shell_NotifyIcon+TrackPopupMenu foreground rule; verified
    // live: default-arg menus froze, with this flag they select/dismiss fine).
    // ignore: deprecated_member_use
    unawaited(trayManager.popUpContextMenu(bringAppToFront: true));
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _kShow:
        unawaited(showMainWindow());
      case _kTogglePlay:
        unawaited(audio.togglePlay());
      case _kPrev:
        unawaited(audio.previous());
      case _kNext:
        unawaited(audio.next());
      case _kLightweight:
        unawaited(setLightweight(!lightweightMode.value));
      case _kExit:
        unawaited(_exit());
    }
  }

  // --- window close ---------------------------------------------------------

  @override
  void onWindowClose() {
    if (_quitting) return;
    if (settings.closeBehavior == CloseBehavior.exit) {
      unawaited(_exit());
    } else {
      // 最小化到托盘: just hide — the tree stays mounted (this is NOT 轻量模式;
      // reopening is instant). Playback keeps running either way.
      unawaited(windowManager.hide());
    }
  }

  // --- actions ---------------------------------------------------------------

  /// Shows + focuses the main window; leaves 轻量模式 first if it is active
  /// (rebuilding the full UI tree BEFORE the window becomes visible, so the
  /// user never sees the placeholder).
  Future<void> showMainWindow() async {
    if (lightweightMode.value) {
      lightweightMode.value = false; // rebuild the full tree
      await _refreshMenu(); // un-tick the checkbox
    }
    await windowManager.show();
    await windowManager.focus();
  }

  /// Enables/disables 轻量模式 (see [lightweightMode] for the architecture).
  ///
  /// Enabling: swap the root to the placeholder FIRST and wait for that frame
  /// to complete — the old tree is unmounted/disposed by then — THEN drop the
  /// image + mesh caches (clearing under a live mesh field would dispose
  /// textures its shaders still sample) and hide the window last (a hidden
  /// window may stop pumping frames, so the swap must not depend on one).
  Future<void> setLightweight(bool on) async {
    if (lightweightMode.value == on) return;
    if (!on) {
      await showMainWindow();
      return;
    }
    lightweightMode.value = true;
    await _refreshMenu(); // tick the checkbox
    // Wait for the swap frame so every UI-tree object is truly disposed.
    // FORCED frame: if the window is already hidden (✕ → 最小化到托盘, then
    // 轻量模式 from the tray menu) the app lifecycle is `hidden`, frames are
    // disabled and a plain scheduleFrame() is a no-op — endOfFrame would park
    // this continuation forever (tree never unmounted, and the clears below
    // could later fire under a re-shown live tree). scheduleForcedFrame()
    // bypasses the lifecycle gate; the engine's vsync is not tied to window
    // visibility on Windows, so the swap frame still runs while hidden.
    SchedulerBinding.instance.scheduleForcedFrame();
    await SchedulerBinding.instance.endOfFrame;
    // Bail if 轻量模式 was already left (显示主界面 raced this await) — the
    // full tree is (re)mounted then, and clearing the mesh-texture cache under
    // a live mesh field would paint from disposed textures.
    if (!lightweightMode.value) return;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    NeonFlowBackground.clearTextureCache();
    await windowManager.hide();
  }

  /// Real exit. Ordering + hard-kill are load-bearing (see below).
  ///
  /// Previous approach (dispose audio → `windowManager.destroy()`) still hung:
  ///   1. `destroy()` is `PostQuitMessage(0)`, which races the engine/plugin COM
  ///      teardown — a live Media Foundation object released on a torn-down COM
  ///      apartment deadlocks;
  ///   2. worse, `just_audio_windows`'s own `dispose()` can itself block when a
  ///      track is loaded, so `await audio.dispose()` never returned and the ✕
  ///      just froze the window.
  ///
  /// Fix: hide first so ✕ feels instant, do a best-effort graceful teardown but
  /// under a hard timeout so nothing can wedge us, then `exit(0)` — deterministic
  /// process termination that sidesteps the whole `destroy()`/CoUninitialize race.
  /// The OS reclaims everything; persisted state (settings/playback) is already
  /// written on change, so an abrupt kill loses nothing meaningful.
  Future<void> _exit() async {
    if (_quitting) return;
    _quitting = true;
    // Window vanishes immediately — the user never sees a frozen frame.
    try {
      await windowManager.hide();
    } catch (_) {}
    // Remove the tray icon up front (fast, non-blocking) so no ghost lingers.
    try {
      await trayManager.destroy();
    } catch (e) {
      debugPrint('TrayController: tray destroy failed: $e');
    }
    // Best-effort MF release, but a hung dispose must NOT block exit.
    try {
      await audio.dispose().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('TrayController: audio dispose failed/timed out: $e');
    }
    exit(0);
  }
}
