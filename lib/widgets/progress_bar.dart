import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// Accent-colored, draggable playback scrubber with optional time labels.
///
/// [onChanged] fires continuously while dragging; [onSeek] fires once on
/// release (commit the seek there).
class ProgressBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration>? onChanged;
  final ValueChanged<Duration>? onSeek;
  final Color? accent;
  final bool showTimeLabels;

  const ProgressBar({
    super.key,
    required this.position,
    required this.duration,
    this.onChanged,
    this.onSeek,
    this.accent,
    this.showTimeLabels = true,
  });

  @override
  State<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<ProgressBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final Color accent = widget.accent ?? Theme.of(context).colorScheme.primary;
    final double total = widget.duration.inMilliseconds.toDouble();
    final double fraction = total <= 0
        ? 0.0
        : (widget.position.inMilliseconds / total).clamp(0.0, 1.0);
    final double value = (_dragValue ?? fraction).clamp(0.0, 1.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: accent,
            inactiveTrackColor: AppColors.surfaceGlassBorder,
            thumbColor: accent,
            overlayColor: accent.withValues(alpha: 0.18),
          ),
          child: Slider(
            value: value,
            onChanged: total <= 0
                ? null
                : (double v) {
                    setState(() => _dragValue = v);
                    widget.onChanged?.call(_durationFor(v));
                  },
            onChangeEnd: total <= 0
                ? null
                : (double v) {
                    widget.onSeek?.call(_durationFor(v));
                    setState(() => _dragValue = null);
                  },
          ),
        ),
        if (widget.showTimeLabels)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(_fmt(widget.position), style: AppTypography.caption),
                Text(_fmt(widget.duration), style: AppTypography.caption),
              ],
            ),
          ),
      ],
    );
  }

  Duration _durationFor(double v) =>
      Duration(milliseconds: (v * widget.duration.inMilliseconds).round());

  String _fmt(Duration d) {
    final int minutes = d.inMinutes;
    final int seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
