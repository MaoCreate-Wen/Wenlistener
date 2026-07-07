import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../../theme/app_colors.dart';

/// A code-level port of AMLL's `BouncingSlider`: a rounded white track that
/// swells while touched, with a left-anchored white fill that brightens during
/// a drag (no knob/handle), and elapsed / remaining time labels beneath.
/// Deliberately not the Material [Slider].
///
/// Visuals mirror `BouncingSlider/index.module.css`:
///  * track (`.inner`): white @ 15 % background, height **8 px rest → 15 px
///    active**, animated with `Cubic(0.38, 1.625, 0.62, 0.995)` (the 1.625
///    control point overshoots, giving the springy swell);
///  * fill (`.thumb`): solid white, opacity **0.4 rest → 0.9 active**, animated
///    over 200 ms with `Cubic(0.2, 0.2, 0, 1)`;
///  * rubber-band overscroll (`bounceSpring` in `BouncingSlider/index.tsx`):
///    dragging past either end nudges the whole track a few px that way and
///    springs it back on release — the same tactile press feel as [MediaButton].
///
/// When the track length is unknown (`duration <= 0` — common for Migu 302→CDN
/// mp3 streams that report no decoder duration) it degrades to an
/// **indeterminate** bar: the elapsed time still counts up from t=0, the right
/// label shows `--:--`, and seeking is disabled until a real duration arrives.
class PlayerScrubber extends StatefulWidget {
  final Duration position;
  final Duration duration;

  /// Fires once, on release / tap, with the committed position.
  final ValueChanged<Duration>? onSeek;

  /// Fires continuously while dragging.
  final ValueChanged<Duration>? onChanged;

  /// Unplayed-track colour (kept for API compatibility; AMLL's track is white).
  final Color color;

  /// Played-fill colour (kept for API compatibility; AMLL's fill is white).
  final Color activeColor;

  const PlayerScrubber({
    super.key,
    required this.position,
    required this.duration,
    this.onSeek,
    this.onChanged,
    this.color = AppColors.onSurface,
    this.activeColor = AppColors.onSurface,
  });

  @override
  State<PlayerScrubber> createState() => _PlayerScrubberState();
}

class _PlayerScrubberState extends State<PlayerScrubber>
    with TickerProviderStateMixin {
  double? _dragFraction;
  bool _dragging = false;
  bool _pressed = false;

  // AMLL toggles the right-hand label between the total duration and the
  // remaining time on tap (`showRemainingTimeAtom`). We default to remaining.
  bool _showTotal = false;

  bool get _active => _dragging || _pressed;

  // Track height swell: 8 → 15 px. Forward while a pointer is down/dragging,
  // reverse on release; the overshooting cubic gives the spring.
  late final AnimationController _swell = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<double> _height = _swell.drive(
    Tween<double>(begin: 8, end: 15)
        .chain(CurveTween(curve: const Cubic(0.38, 1.625, 0.62, 0.995))),
  );

  // Rubber-band overscroll offset, in px (AMLL's `bounceSpring`). Unbounded so
  // it can carry past 0; pinned directly to the finger while dragging past an
  // end, then sprung back to 0 on release.
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

  // AMLL: `o = (rel - 1) * 900` past the right end, `rel * 900` past the left,
  // applied as `o / 100` px — i.e. ~9 px per full-width of overscroll, capped so
  // a wild drag can't fling the bar off. Zero while the pointer is on-track.
  double _overscrollPx(double rel) {
    if (rel > 1) return ((rel - 1) * 9).clamp(0.0, 28.0);
    if (rel < 0) return (rel * 9).clamp(-28.0, 0.0);
    return 0;
  }

  // While dragging AMLL pins the spring straight to the overscroll px (no lag).
  void _setOverscroll(double px) {
    _overscroll.stop();
    _overscroll.value = px;
  }

  // On release the spring eases the bar back to rest with a small settle.
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

  void _syncSwell() {
    if (_active) {
      _swell.forward();
    } else {
      _swell.reverse();
    }
  }

  Duration _durationFor(double f) =>
      Duration(milliseconds: (f * widget.duration.inMilliseconds).round());

  @override
  Widget build(BuildContext context) {
    final double total = widget.duration.inMilliseconds.toDouble();
    final bool determinate = total > 0;

    return determinate ? _buildDeterminate(total) : _buildIndeterminate();
  }

  // --- known duration: proportional fill + draggable seek ------------------

  Widget _buildDeterminate(double total) {
    final double played =
        (widget.position.inMilliseconds / total).clamp(0.0, 1.0);
    final double fraction = (_dragFraction ?? played).clamp(0.0, 1.0);
    final Duration shown = _dragging ? _durationFor(fraction) : widget.position;
    final Duration remaining = widget.duration - shown;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double w = c.maxWidth;
            void update(double dx) {
              final double rel = dx / w;
              setState(() => _dragFraction = rel.clamp(0.0, 1.0));
              widget.onChanged?.call(_durationFor(_dragFraction!));
              _setOverscroll(_overscrollPx(rel));
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (TapDownDetails d) {
                _setPressed(true);
                widget.onSeek?.call(
                    _durationFor((d.localPosition.dx / w).clamp(0.0, 1.0)));
              },
              onTapUp: (_) {
                _setPressed(false);
                _springOverscrollBack();
              },
              onTapCancel: () {
                _setPressed(false);
                _springOverscrollBack();
              },
              onHorizontalDragStart: (DragStartDetails d) {
                _setDragging(true);
                update(d.localPosition.dx);
              },
              onHorizontalDragUpdate: (DragUpdateDetails d) =>
                  update(d.localPosition.dx),
              onHorizontalDragEnd: (_) {
                if (_dragFraction != null) {
                  widget.onSeek?.call(_durationFor(_dragFraction!));
                }
                setState(() => _dragFraction = null);
                _setDragging(false);
                _springOverscrollBack();
              },
              // ≥24 px transparent hit area around the (thinner) visual track.
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
                                    duration:
                                        const Duration(milliseconds: 200),
                                    curve: const Cubic(0.2, 0.2, 0, 1),
                                    color: Colors.white.withValues(
                                        alpha: _active ? 0.9 : 0.4),
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
            );
          },
        ),
        const SizedBox(height: 2),
        _Labels(
          left: _fmt(shown),
          right: _showTotal
              ? _fmt(widget.duration)
              : '-${_fmt(remaining.isNegative ? Duration.zero : remaining)}',
          onToggle: () => setState(() => _showTotal = !_showTotal),
        ),
      ],
    );
  }

  // --- unknown duration: indeterminate bar, elapsed still counts up --------

  Widget _buildIndeterminate() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: 24,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(100),
              child: const SizedBox(
                height: 8,
                width: double.infinity,
                child: LinearProgressIndicator(
                  backgroundColor: Color(0x26FFFFFF),
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xE6FFFFFF)),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        _Labels(left: _fmt(widget.position), right: '--:--'),
      ],
    );
  }

  String _fmt(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// Elapsed (left) and remaining/total (right, tap-toggle) labels: white @ 50 %,
/// weight 500, tabular figures so the digits don't jitter.
class _Labels extends StatelessWidget {
  final String left;
  final String right;
  final VoidCallback? onToggle;

  const _Labels({required this.left, required this.right, this.onToggle});

  static const TextStyle _style = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: Color(0x80FFFFFF),
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    final Widget rightLabel = Text(right, style: _style);
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(left, style: _style),
          if (onToggle != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: rightLabel,
            )
          else
            rightLabel,
        ],
      ),
    );
  }
}
