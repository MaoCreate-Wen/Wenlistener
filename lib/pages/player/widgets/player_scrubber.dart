import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import 'bouncing_track.dart';

/// A code-level port of AMLL's `BouncingSlider` + `PrebuiltProgressBar`: the
/// knob-less [BouncingTrack] (swell 8→15, brightening left-anchored fill,
/// rubber-band overscroll) with elapsed / remaining time labels beneath.
/// Deliberately not the Material [Slider].
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

class _PlayerScrubberState extends State<PlayerScrubber> {
  // The fraction the finger is currently at while dragging (null = not dragging).
  double? _dragFraction;

  // AMLL toggles the right-hand label between the total duration and the
  // remaining time on tap (`showRemainingTimeAtom`). We default to remaining.
  bool _showTotal = false;

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
    final Duration shown =
        _dragFraction != null ? _durationFor(fraction) : widget.position;
    final Duration remaining = widget.duration - shown;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        BouncingTrack(
          value: played,
          onChanged: (double f) {
            setState(() => _dragFraction = f);
            widget.onChanged?.call(_durationFor(f));
          },
          onChangeEnd: (double f) {
            widget.onSeek?.call(_durationFor(f));
            if (_dragFraction != null) setState(() => _dragFraction = null);
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(left, style: _style),
        if (onToggle != null)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: rightLabel,
            ),
          )
        else
          rightLabel,
      ],
    );
  }
}
