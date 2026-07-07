import 'package:flutter/material.dart';

/// A code-level port of AMLL's `MediaButton`
/// (`react-full/.../MediaButton/index.module.css`), tightened for touch with a
/// tactile press-down dip. A circular, transparent tap target that:
///
///  * fades its background `#fff0` → `#fff2` (white @ 13.3 %) over 300 ms while
///    held — AMLL's `transition: background-color 0.3s` + `:active` wash;
///  * **dips** its [child] toward `0.9×` the instant a finger goes down (quick,
///    eased — the "push in" AMLL's CSS lacks on touch); then
///  * on release runs AMLL's signature press-bounce keyframe
///    `1 → 0.85 (20 %) → 1.1 (50 %) → 1 (100 %)` over 700 ms (the overshoot past
///    1.0 is the springy pop).
///
/// The dip and the bounce multiply, so one tap reads as a single fluid
/// push-in → spring-out. There is **no** Material ink/ripple: feedback is purely
/// the scale + wash, matching the app-wide "no white splash" rule
/// (see `AppTheme.dark`). The glyph colour comes from the caller's [child] —
/// AMLL's transport is monochrome white.
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
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
        width: widget.size,
        height: widget.size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // #fff0 (fully transparent) → #fff2 (white @ 13.3 %) while pressed.
          color: _pressed ? const Color(0x22FFFFFF) : const Color(0x00FFFFFF),
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
    );
  }
}
