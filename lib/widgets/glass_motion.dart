import 'dart:async';

import 'package:flutter/widgets.dart';

/// Process-wide "the UI is in motion" flag. [GlassContainer] watches it and, while
/// true, drops its live `BackdropFilter` for a cheap opaque scrim.
///
/// WHY: a `BackdropFilter` re-samples + Gaussian-blurs the pixels BEHIND it every
/// frame the backdrop changes. Two are permanently on screen (MiniPlayer +
/// BottomNav), so the instant ANY animation runs — a list scroll, a route push —
/// both blurs re-run a full read-back+blur ON TOP of the animation's own paint,
/// overflowing the raster budget → dropped frames for the animation's duration,
/// then it recovers once motion stops. Swapping to a flat scrim while moving
/// removes that per-frame raster tax exactly on the frames that can't afford it;
/// the frosted blur returns the moment the backdrop is static again (the eye
/// can't resolve an 18px blur on fast-moving content anyway).
///
/// Sources OR together (scroll + route transition) so overlapping motions don't
/// clear the flag early; the scroll source self-clears via a short debounce so a
/// missed `ScrollEndNotification` can never strand the glass in scrim mode.
class GlassMotion {
  GlassMotion._();

  static final ValueNotifier<bool> moving = ValueNotifier<bool>(false);

  static bool _scroll = false;
  static bool _route = false;
  static Timer? _scrollOff;

  static void _recompute() {
    final bool v = _scroll || _route;
    if (moving.value != v) moving.value = v;
  }

  /// Called on every scroll start/update. Keeps the flag true and (re)arms a
  /// debounce that clears it shortly after scrolling stops — robust even if a
  /// [ScrollEndNotification] is dropped.
  static void scrollTick() {
    _scroll = true;
    _recompute();
    _scrollOff?.cancel();
    _scrollOff = Timer(const Duration(milliseconds: 120), () {
      _scroll = false;
      _recompute();
    });
  }

  /// Called by the route observer around push/pop transitions.
  static void setRoute(bool v) {
    _route = v;
    _recompute();
  }
}

/// Flags [GlassMotion] while a route push/pop transition is animating, so the
/// shell's glass bars (composited behind a sliding full-screen route) stop
/// re-blurring for the ~340ms transition. Attach to the [GoRouter] `observers`.
class GlassMotionRouteObserver extends NavigatorObserver {
  final Set<Animation<double>> _watched = <Animation<double>>{};

  void _watch(Route<dynamic>? route) {
    if (route is! ModalRoute) return;
    final Animation<double> anim = route.animation ?? kAlwaysCompleteAnimation;
    if (_watched.contains(anim)) return;
    // By the time the observer is notified of a PUSH, TransitionRoute.didPush()
    // has ALREADY called _controller.forward() (status is already `forward`), so
    // addStatusListener won't fire on registration and the listener would only
    // ever see the trailing `completed` → the push would never gate the shell
    // glass. Seed the flag from the CURRENT status; the listener still catches
    // the edge in the rarer case forward() hasn't fired yet. (didPop seeds true.)
    final AnimationStatus current = anim.status;
    if (current == AnimationStatus.completed) return; // settled / no transition
    _watched.add(anim);
    if (current == AnimationStatus.forward ||
        current == AnimationStatus.reverse) {
      GlassMotion.setRoute(true);
    }
    void listener(AnimationStatus status) {
      final bool animating = status == AnimationStatus.forward ||
          status == AnimationStatus.reverse;
      GlassMotion.setRoute(animating);
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        anim.removeStatusListener(listener);
        _watched.remove(anim);
      }
    }

    anim.addStatusListener(listener);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _watch(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // The revealed route's reverse transition drives the motion on pop.
    GlassMotion.setRoute(true);
    _watch(route);
    _watch(previousRoute);
  }
}
