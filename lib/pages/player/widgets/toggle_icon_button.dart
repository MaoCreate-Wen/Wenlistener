import 'package:flutter/material.dart';

/// Shared AMLL press-feedback primitive — the same tactile feel as the transport
/// [MediaButton] (`media_button.dart`), factored out so every interactive
/// control in the desktop shell (toggles, hover-icons, the playlist CTAs, the
/// settings selectors) reacts identically. There is **no** Material ink / ripple:
/// feedback is purely
///
///  * a fast press-down **dip** `1 → 0.9` (120 ms ease-out) the instant a pointer
///    goes down, easing back over ~260 ms on release; and
///  * AMLL's signature release **bounce** keyframe `1 → 0.85 (20 %) → 1.1 (50 %) →
///    1 (100 %)` over 700 ms (the overshoot past 1.0 is the springy pop), fired
///    once per tap; plus
///  * (circular variant only) a fixed background **wash** `#fff0 → #fff2`
///    (white @ 12.5 %) on hover / press — AMLL's `background-color 0.3s` +
///    `:active` wash.
///
/// The dip and bounce multiply, so one tap reads as a single fluid
/// push-in → spring-out. Two shapes:
///
///  * default ctor — a bare wrapper that scales its [child] as a whole (no wash);
///    use it around pill CTAs that already paint their own background.
///  * [AmllBounce.circle] — a fixed-[diameter] circular hit target that paints the
///    hover/press wash behind the child and scales only the inner glyph
///    (MediaButton behaviour).
class AmllBounce extends StatefulWidget {
  /// The visual to animate. For [AmllBounce.circle] this is the centred glyph;
  /// for the default ctor it is the whole button.
  final Widget child;

  /// Fired on tap (after the bounce is kicked off). Ignored when [onTapAt] is set.
  final VoidCallback? onTap;

  /// Fired on tap with the pointer's global position — used to anchor context
  /// menus. Takes precedence over [onTap] when both are supplied.
  final void Function(Offset globalPosition)? onTapAt;

  /// Hover tooltip.
  final String? tooltip;

  /// Circular hit target diameter (circle variant only).
  final double diameter;

  final bool _circle;

  const AmllBounce({
    super.key,
    required this.child,
    this.onTap,
    this.onTapAt,
    this.tooltip,
  })  : _circle = false,
        diameter = 0;

  const AmllBounce.circle({
    super.key,
    required this.child,
    required this.diameter,
    this.onTap,
    this.onTapAt,
    this.tooltip,
  }) : _circle = true;

  @override
  State<AmllBounce> createState() => _AmllBounceState();
}

class _AmllBounceState extends State<AmllBounce> with TickerProviderStateMixin {
  // Press-down dip: 1.0 (released) → 0.9 (held). Snaps down fast, eases back so
  // it overlaps the release bounce without a visible snap.
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _pressScale = _press.drive(
    Tween<double>(begin: 1, end: 0.9)
        .chain(CurveTween(curve: Curves.easeOutCubic)),
  );

  // AMLL release keyframe: 1 → 0.85 → 1.1 → 1, segment weights 20 / 30 / 50.
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
  bool _hover = false;
  Offset _tapPos = Offset.zero;

  bool get _interactive => widget.onTap != null || widget.onTapAt != null;

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
    _bounce.forward(from: 0);
    if (widget.onTapAt != null) {
      widget.onTapAt!(_tapPos);
    } else {
      widget.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget scaled = AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_press, _bounce]),
      builder: (BuildContext context, Widget? child) {
        return Transform.scale(
          scale: _pressScale.value * _bounceScale.value,
          child: child,
        );
      },
      child: widget.child,
    );

    Widget core;
    if (widget._circle) {
      // #fff0 (transparent) → #fff2 (white @ 12.5 %) on hover / press.
      core = AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
        width: widget.diameter,
        height: widget.diameter,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (_pressed || _hover)
              ? const Color(0x20FFFFFF)
              : const Color(0x00FFFFFF),
        ),
        child: scaled,
      );
    } else {
      core = scaled;
    }

    Widget result = MouseRegion(
      cursor: _interactive
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (TapDownDetails d) {
          _tapPos = d.globalPosition;
          _setPressed(true);
        },
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: _interactive ? _handleTap : null,
        child: core,
      ),
    );

    if (widget.tooltip != null) {
      result = Tooltip(message: widget.tooltip!, child: result);
    }
    return result;
  }
}

/// A code-level port of AMLL's `ToggleIconButton`
/// (`react-full/.../ToggleIconButton`): a transparent, circular hit target whose
/// glyph rests at **opacity 0.5 unchecked → 0.9 checked**, cross-fading over
/// 200 ms. Press feedback is AMLL's shared [AmllBounce] (press dip + release
/// bounce + white hover/press wash) — no Material ink / ripple, matching the
/// transport [MediaButton] and the app-wide "no white splash" rule.
///
/// Used by the player page's bottom control row (airplay / lyrics / playlist).
///
/// The glyph is either a Material [icon] or an arbitrary [child] widget — the
/// AMLL bottom controls pass their vector glyphs from `widgets/amll_icons.dart`
/// as [child] (white, [iconSize]-square), which the [AnimatedOpacity] then
/// modulates identically to a Material [Icon].
///
/// Checked state is glyph opacity only: 0.5 unchecked → 0.9 checked, on a
/// fully transparent circular background — no ring, no fill, no shadow.
class ToggleIconButton extends StatelessWidget {
  /// Material glyph shown centred in the button. Ignored when [child] is set.
  final IconData? icon;

  /// Custom glyph widget (e.g. an AMLL vector icon), overriding [icon]. Must be
  /// white so the checked/unchecked opacity shift reads correctly.
  final Widget? child;

  /// Whether the toggle reads as "on" (brighter glyph). Single-state buttons
  /// (e.g. airplay) can leave this false.
  final bool checked;

  final VoidCallback onTap;

  /// Hover tooltip.
  final String? tooltip;

  /// Glyph size; the tap target is [target]² regardless.
  final double iconSize;
  final double target;

  const ToggleIconButton({
    super.key,
    this.icon,
    this.child,
    required this.onTap,
    this.checked = false,
    this.tooltip,
    this.iconSize = 24,
    this.target = 40,
  }) : assert(icon != null || child != null, 'provide an icon or a child');

  @override
  Widget build(BuildContext context) {
    final Widget glyph =
        child ?? Icon(icon, size: iconSize, color: Colors.white);
    return AmllBounce.circle(
      diameter: target,
      onTap: onTap,
      tooltip: tooltip,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
        opacity: checked ? 0.9 : 0.5,
        child: glyph,
      ),
    );
  }
}
