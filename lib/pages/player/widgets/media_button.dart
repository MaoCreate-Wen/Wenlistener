import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A code-level port of AMLL's `MediaButton`
/// (`react-full/.../MediaButton/index.module.css`), tightened for touch with a
/// tactile press-down dip. A circular, transparent tap target that:
///
///  * fades its background `#fff0` → `#fff2` (white @ 13.3 %) over 300 ms while
///    held — AMLL's `transition: background-color 0.3s` + `:active` wash;
///  * **dips** its [child] toward `0.9×` the instant the pointer goes down
///    (quick, eased — the "push in" AMLL's CSS lacks on touch); then
///  * on release runs AMLL's signature press-bounce keyframe
///    `1 → 0.85 (20 %) → 1.1 (50 %) → 1 (100 %)` over 700 ms (the overshoot past
///    1.0 is the springy pop).
///
/// The dip and the bounce multiply, so one tap reads as a single fluid
/// push-in → spring-out. There is **no** Material ink/ripple: feedback is purely
/// the scale + wash, matching the app-wide "no white splash" rule
/// (see `AppTheme.dark`). The glyph colour comes from the caller's [child] —
/// AMLL's transport is monochrome white.
///
/// Two jank-proofing rules, learned the hard way (burst-screenshot diagnosis of
/// "transport buttons don't animate"):
///
///  1. The dip/wash are driven by a raw [Listener] (`onPointerDown`), NOT
///     `GestureDetector.onTapDown`. The player page wraps the transport in a
///     `SingleChildScrollView`, whose drag recognizer holds the gesture arena —
///     `onTapDown` therefore only fires at pointer-**up** for a quick click, so
///     the physical press showed no reaction at all. Raw pointer events are not
///     arena-gated: the dip now starts the same frame the button is pressed
///     (AMLL's `:active` is equally instant).
///  2. [onPressed] is deferred by one frame (post-frame callback). Transport
///     actions (next/prev/play) kick off heavy work — song load, artwork
///     palette, lyrics — that was measured to starve the UI thread to ~6 painted
///     frames over the bounce's 700 ms window, collapsing the animation into an
///     invisible flicker. One frame of deferral gets the wash + the bounce's
///     opening frames on screen before that flood starts, at ~8–16 ms of added
///     action latency.
class MediaButton extends StatefulWidget {
  /// The glyph (usually a white [Icon]) shown centred in the button.
  final Widget child;

  /// Invoked on tap, in sync with the press-bounce.
  final VoidCallback onPressed;

  /// Diameter of the circular hit target.
  final double size;

  const MediaButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.size = 56,
  });

  @override
  State<MediaButton> createState() => _MediaButtonState();
}

class _MediaButtonState extends State<MediaButton>
    with TickerProviderStateMixin {
  // Press-down dip: 1.0 (released) → 0.9 (held). Snaps down fast on touch, then
  // eases back over ~260 ms on release so it overlaps the bounce without a
  // visible snap. AMLL only washes the background on press; the dip is the
  // tactile addition for finger input.
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _pressScale = _press.drive(
    Tween<double>(begin: 1, end: 0.9)
        .chain(CurveTween(curve: Curves.easeOutCubic)),
  );

  // AMLL's release keyframe: 1 → 0.85 → 1.1 → 1 with segment weights 20 / 30 /
  // 50, each segment eased; fired once per tap. The overshoot past 1.0 is the
  // pop. Resting at value 1 keeps the idle scale exactly 1.0.
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    value: 1,
  );
  late final Animation<double> _bounceScale = _bounce.drive(
    TweenSequence<double>(<TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: 1, end: 0.85)
            .chain(CurveTween(curve: Curves.ease)),
        weight: 20,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: 0.85, end: 1.1)
            .chain(CurveTween(curve: Curves.ease)),
        weight: 30,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: 1.1, end: 1)
            .chain(CurveTween(curve: Curves.ease)),
        weight: 50,
      ),
    ]),
  );

  bool _pressed = false;

  @override
  void dispose() {
    _press.dispose();
    _bounce.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
    if (value) {
      _press.forward();
    } else {
      _press.reverse();
    }
  }

  void _handleTap() {
    // Release pop fires once per tap, independent of how long the finger was
    // down; a fast tap therefore still gets the full springy bounce.
    _bounce.forward(from: 0);
    // Defer the action one frame so the bounce's first frame (and the pressed
    // wash) actually reach the screen before any heavy side effects of the
    // action (song load / palette / lyrics) jank the UI thread — see the class
    // doc. The callback is captured so the action still runs even if this
    // button is rebuilt away in the meantime.
    final VoidCallback onPressed = widget.onPressed;
    SchedulerBinding.instance.addPostFrameCallback((_) => onPressed());
  }

  @override
  Widget build(BuildContext context) {
    // Raw pointer events drive the dip/wash so they fire the instant the button
    // is physically pressed, even while an ancestor scrollable is still holding
    // the gesture arena (see the class doc). The GestureDetector keeps tap
    // semantics (arena-safe: a drag that starts here still scrolls, and its
    // pointer-up is NOT a tap — the dip simply eases back).
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        // The per-tick Transform.scale repaint stays inside this button's own
        // 64-odd-px layer instead of dirtying the whole page.
        child: RepaintBoundary(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.ease,
            width: widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // #fff0 (fully transparent) → #fff2 (white @ 13.3 %) while
              // pressed.
              color:
                  _pressed ? const Color(0x22FFFFFF) : const Color(0x00FFFFFF),
            ),
            child: AnimatedBuilder(
              animation: Listenable.merge(<Listenable>[_press, _bounce]),
              builder: (BuildContext context, Widget? child) {
                return Transform.scale(
                  scale: _pressScale.value * _bounceScale.value,
                  child: child,
                );
              },
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
