import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../pages/player/player_page.dart';
import '../router/app_router.dart';
import '../router/routes.dart';
import '../theme/app_colors.dart';
import 'fullscreen_controller.dart';

/// The right-hand window controls — minimize / maximize-restore / close (close
/// hovers red). Hosted ONCE, by [DesktopWindowFrame] (the `MaterialApp.router`
/// `builder:` layer), pinned top-right ABOVE every route — shell branches AND
/// the pushed full-screen surfaces (player / lyrics / playlist details) — so no
/// page ever needs its own copy. Each button is a fixed 46px cell whose height
/// matches the top bar.
///
/// Hidden entirely during 沉浸全屏 (there is no window chrome to manage);
/// gating here covers the single host in one place. Restored automatically on
/// exit ([FullscreenController.isFullscreen] is a static [ValueNotifier], so it
/// is reachable from the frame layer without any provider).
///
/// On the LYRIC SURFACES (`/player` — the AMLL player — while its right
/// synced-lyric pane is VISIBLE, and the maximized `/lyrics` route) the
/// buttons auto-fade: after ~3s without the pointer over their 138×48 corner
/// they animate to fully transparent so no chrome floats over the lyrics. The
/// corner stays hover-responsive while invisible — moving the mouse onto it
/// snaps the buttons back, and they hold while hovered; leaving restarts the
/// countdown. Any navigation off the lyric surfaces (or collapsing the lyric
/// pane) restores permanent full opacity. The surface signal is primarily
/// [PlayerPage.lyricSurfaceActive] — the fused player page's own "mounted
/// with the lyric pane on screen" notifier (a static, reachable from this
/// layer ABOVE the Router where `GoRouter.of(context)` cannot see anything;
/// see [_WindowButtonsState.initState] for why go_router path compares can
/// never detect the imperatively-pushed player sheet) — plus the reported
/// location for the `go`-style routes. Fullscreen still takes precedence:
/// while immersed nothing renders at all.
class WindowButtons extends StatefulWidget {
  /// Total width of the three 46px cells — [DesktopTopBar] reserves exactly
  /// this much trailing space so its content never slides under the overlay.
  static const double totalWidth = 3 * 46;

  final double height;
  const WindowButtons({super.key, this.height = 48});

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> {
  /// Pointer-idle time on a lyric surface before the fade-out starts.
  static const Duration _idleDelay = Duration(seconds: 3);

  /// Fade-out to transparent (slow, unobtrusive).
  static const Duration _fadeOut = Duration(milliseconds: 500);

  /// Fade-in on hover (quick — the user is reaching for the buttons).
  static const Duration _fadeIn = Duration(milliseconds: 150);

  bool _lyricsSurface = false;
  bool _hovered = false;
  bool _visible = true;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    // Primary signal: [PlayerPage.lyricSurfaceActive]. `/player` is pushed
    // IMPERATIVELY (`context.push`), and go_router keeps the reported
    // location at the UNDERLYING route for imperative pushes — measured on
    // this app: `routerDelegate.currentConfiguration.uri.path` stays `/`
    // for the whole life of the sheet, and `routeInformationProvider` says
    // `/player` for exactly one notification before reverting to `/`. NO
    // path compare can therefore ever see the player sheet (that was the
    // bug that kept this fade from ever firing). The fused player page
    // instead OWNS the signal: it publishes `true` while mounted with its
    // lyric pane visible and resets on dispose (pop), which also folds in
    // the pane-collapse toggle and the no-song case for free.
    PlayerPage.lyricSurfaceActive.addListener(_onRouteChanged);
    // Secondary: real location changes (`go`-style navigations, e.g. the
    // standalone maximized `/lyrics` surface) still re-evaluate the flag.
    AppRouter.router.routeInformationProvider.addListener(_onRouteChanged);
    _lyricsSurface = _isLyricsSurface();
    _armIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    AppRouter.router.routeInformationProvider.removeListener(_onRouteChanged);
    PlayerPage.lyricSurfaceActive.removeListener(_onRouteChanged);
    super.dispose();
  }

  /// Whether the user is "在歌词页": on the fused player sheet with its lyric
  /// pane actually visible ([PlayerPage.lyricSurfaceActive] — the page's own
  /// mounted+pane-visible signal, see [initState] for why a route-path check
  /// cannot work), or on the standalone maximized `/lyrics` route (which is
  /// all lyrics by definition).
  static bool _isLyricsSurface() {
    if (PlayerPage.lyricSurfaceActive.value) return true;
    return AppRouter.router.routeInformationProvider.value.uri.path ==
        Routes.lyrics;
  }

  void _onRouteChanged() {
    final bool active = _isLyricsSurface();
    if (active == _lyricsSurface) return;
    setState(() {
      _lyricsSurface = active;
      // Entering a lyric surface starts from full opacity (the timer below
      // takes it from there); leaving one restores permanent full opacity.
      _visible = true;
    });
    _armIdleTimer();
  }

  /// (Re)starts the fade countdown. Only ever armed on a lyric surface while
  /// the pointer is off the buttons — everywhere else the buttons are solid.
  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!_lyricsSurface || _hovered) return;
    _idleTimer = Timer(_idleDelay, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _onEnter() {
    _idleTimer?.cancel();
    _idleTimer = null;
    setState(() {
      _hovered = true;
      _visible = true;
    });
  }

  void _onExit() {
    setState(() => _hovered = false);
    _armIdleTimer();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: FullscreenController.isFullscreen,
      builder: (BuildContext context, bool fullscreen, _) {
        // Fullscreen wins over everything: no chrome at all, no hover target.
        if (fullscreen) return const SizedBox.shrink();
        // MouseRegion spans the full 138×48 corner (opaque hit test), so the
        // buttons stay hover-discoverable even at opacity 0 — Opacity does not
        // disable hit testing, and at exactly 0 it paints nothing, so faded
        // buttons never ghost in screenshots.
        return MouseRegion(
          onEnter: (_) => _onEnter(),
          onExit: (_) => _onExit(),
          child: AnimatedOpacity(
            opacity: _visible ? 1.0 : 0.0,
            duration: _visible ? _fadeIn : _fadeOut,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _WindowButton(
                    icon: Icons.remove,
                    action: _WinAction.minimize,
                    height: widget.height),
                _WindowButton(
                    icon: Icons.crop_square_outlined,
                    action: _WinAction.maximize,
                    height: widget.height),
                _WindowButton(
                    icon: Icons.close,
                    action: _WinAction.close,
                    danger: true,
                    height: widget.height),
              ],
            ),
          ),
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
