import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// A code-level port of the *track* of AMLL's `BouncingSlider`
/// (`BouncingSlider/index.module.css` + `index.tsx`): a knob-less rounded white
/// rail that **swells** while touched, with a left-anchored white fill that
/// **brightens** during a drag, and a rubber-band **overscroll** spring when a
/// drag is carried past either end.
///
/// Extracted so the progress scrubber and the volume rail share the exact same
/// tactile feel (plan §2.5). It owns nothing about time or labels — it reports a
/// normalised fraction `0..1` through [onChanged] (continuous, during a drag)
/// and [onChangeEnd] (committed, on release / tap). The resting fill follows the
/// [value] prop; while dragging it follows the finger.
///
/// Visual numbers (from the CSS):
///  * track (`.inner`): white @ 15 % background, height **8 px rest → 15 px
///    active**, animated with `Cubic(0.38, 1.625, 0.62, 0.995)` (the 1.625
///    control point overshoots → the springy swell);
///  * fill (`.thumb`): solid white, opacity **0.4 rest → 0.9 active**, animated
///    over 200 ms with `Cubic(0.2, 0.2, 0, 1)`;
///  * overscroll (`bounceSpring`): ~9 px per full-width past an end, clamped to
///    ±28 px, sprung back on release with `SpringDescription(1, 150, 18)`.
class BouncingTrack extends StatefulWidget {
  /// Resting fill fraction, `0..1`.
  final double value;

  /// Fires continuously while dragging, with the clamped fraction `0..1`.
  final ValueChanged<double>? onChanged;

  /// Fires once on release / tap, with the committed fraction `0..1`.
  final ValueChanged<double>? onChangeEnd;

  /// When false the track renders but ignores pointers (e.g. unknown duration).
  final bool enabled;

  const BouncingTrack({
    super.key,
    required this.value,
    this.onChanged,
    this.onChangeEnd,
    this.enabled = true,
  });

  @override
  State<BouncingTrack> createState() => _BouncingTrackState();
}

class _BouncingTrackState extends State<BouncingTrack>
    with TickerProviderStateMixin {
  double? _dragFraction;
  bool _dragging = false;
  bool _pressed = false;
  bool _hovered = false;

  // AMLL's `.inner` swells on `:hover` too, not just while touched — the rail
  // fattens and the fill brightens the moment the cursor lands on it, and stays
  // swelled through a press/drag that follows. Any of the three keeps it up; it
  // only springs back once the cursor has left *and* the pointer is released.
  bool get _active => _dragging || _pressed || _hovered;

  late final AnimationController _swell = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<double> _height = _swell.drive(
    Tween<double>(begin: 8, end: 15)
        .chain(CurveTween(curve: const Cubic(0.38, 1.625, 0.62, 0.995))),
  );

  late final AnimationController _overscroll =
      AnimationController.unbounded(vsync: this);
  static const SpringDescription _overscrollSpring =
      SpringDescription(mass: 1, stiffness: 150, damping: 18);

  @override
  void dispose() {
    _swell.dispose();
    _overscroll.dispose();
    super.dispose();
  }

  double _overscrollPx(double rel) {
    if (rel > 1) return ((rel - 1) * 9).clamp(0.0, 28.0);
    if (rel < 0) return (rel * 9).clamp(-28.0, 0.0);
    return 0;
  }

  void _setOverscroll(double px) {
    _overscroll.stop();
    _overscroll.value = px;
  }

  void _springOverscrollBack() {
    if (_overscroll.value == 0) return;
    _overscroll.animateWith(
      SpringSimulation(
          _overscrollSpring, _overscroll.value, 0, _overscroll.velocity),
    );
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
    _syncSwell();
  }

  void _setDragging(bool value) {
    if (_dragging == value) return;
    setState(() => _dragging = value);
    _syncSwell();
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    _syncSwell();
  }

  void _syncSwell() => _active ? _swell.forward() : _swell.reverse();

  @override
  Widget build(BuildContext context) {
    final double fraction = (_dragFraction ?? widget.value).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        void update(double dx) {
          final double rel = dx / w;
          setState(() => _dragFraction = rel.clamp(0.0, 1.0));
          widget.onChanged?.call(_dragFraction!);
          _setOverscroll(_overscrollPx(rel));
        }

        return MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : MouseCursor.defer,
          onEnter: widget.enabled ? (_) => _setHovered(true) : null,
          onExit: widget.enabled
              ? (_) {
                  _setHovered(false);
                  // If the cursor leaves mid-press/drag the pointer state still
                  // holds the swell up; `_syncSwell` only reverses once nothing
                  // is active, so a genuine drag never gets yanked back down.
                }
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: widget.enabled
                ? (TapDownDetails d) {
                    _setPressed(true);
                    widget.onChangeEnd
                        ?.call((d.localPosition.dx / w).clamp(0.0, 1.0));
                  }
                : null,
            onTapUp: widget.enabled
                ? (_) {
                    _setPressed(false);
                    _springOverscrollBack();
                  }
                : null,
            onTapCancel: widget.enabled
                ? () {
                    _setPressed(false);
                    _springOverscrollBack();
                  }
                : null,
            onHorizontalDragStart: widget.enabled
                ? (DragStartDetails d) {
                    _setDragging(true);
                    update(d.localPosition.dx);
                  }
                : null,
            onHorizontalDragUpdate: widget.enabled
                ? (DragUpdateDetails d) => update(d.localPosition.dx)
                : null,
            onHorizontalDragEnd: widget.enabled
                ? (_) {
                    if (_dragFraction != null) {
                      widget.onChangeEnd?.call(_dragFraction!);
                    }
                    setState(() => _dragFraction = null);
                    _setDragging(false);
                    _springOverscrollBack();
                  }
                : null,
            child: SizedBox(
              height: 24,
              child: Center(
                child: AnimatedBuilder(
                  animation:
                      Listenable.merge(<Listenable>[_swell, _overscroll]),
                  builder: (BuildContext context, Widget? _) {
                    return Transform.translate(
                      offset: Offset(_overscroll.value, 0),
                      child: SizedBox(
                        height: _height.value,
                        width: double.infinity,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(100),
                          child: Stack(
                            fit: StackFit.expand,
                            children: <Widget>[
                              const ColoredBox(color: Color(0x26FFFFFF)),
                              FractionallySizedBox(
                                widthFactor: fraction,
                                alignment: Alignment.centerLeft,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  curve: const Cubic(0.2, 0.2, 0, 1),
                                  color: Colors.white
                                      .withValues(alpha: _active ? 0.9 : 0.4),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
