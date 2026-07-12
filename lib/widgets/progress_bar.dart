import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_typography.dart';

/// AMLL `BouncingSlider` port: a thumbless scrubber whose track is white @15%
/// with a white fill (@40% idle, @90% while dragging), swelling 8→15px on press
/// with the emphasized overshoot curve. Draggable → [onSeek] on release,
/// [onChanged] continuously. Optional time labels (`0:27` / `-3:34`).
///
/// When [duration] is zero/unknown the bar is indeterminate: the elapsed label
/// still ticks, the right label reads `--:--`, and dragging is disabled
/// (matches the mobile player's fallback).
class WenProgressBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration>? onChanged;
  final ValueChanged<Duration>? onSeek;
  final bool showTimeLabels;
  final bool remainingOnRight;

  const WenProgressBar({
    super.key,
    required this.position,
    required this.duration,
    this.onChanged,
    this.onSeek,
    this.showTimeLabels = true,
    this.remainingOnRight = true,
  });

  @override
  State<WenProgressBar> createState() => _WenProgressBarState();
}

class _WenProgressBarState extends State<WenProgressBar> {
  double? _dragFraction;
  bool _dragging = false;

  bool get _known => widget.duration.inMilliseconds > 0;

  double get _fraction {
    if (_dragFraction != null) return _dragFraction!.clamp(0.0, 1.0);
    if (!_known) return 0;
    return (widget.position.inMilliseconds / widget.duration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  void _updateFromDx(double dx, double width) {
    if (!_known || width <= 0) return;
    setState(() => _dragFraction = (dx / width).clamp(0.0, 1.0));
    widget.onChanged?.call(_durationFor(_dragFraction!));
  }

  Duration _durationFor(double f) =>
      Duration(milliseconds: (f * widget.duration.inMilliseconds).round());

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double width = c.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (DragStartDetails d) {
                if (!_known) return;
                setState(() => _dragging = true);
                _updateFromDx(d.localPosition.dx, width);
              },
              onHorizontalDragUpdate: (DragUpdateDetails d) =>
                  _updateFromDx(d.localPosition.dx, width),
              onHorizontalDragEnd: (_) => _commit(),
              onHorizontalDragCancel: _commit,
              onTapDown: (TapDownDetails d) {
                if (!_known) return;
                _updateFromDx(d.localPosition.dx, width);
              },
              onTapUp: (_) => _commit(),
              child: SizedBox(
                height: 22,
                child: Center(
                  child: AnimatedContainer(
                    duration: AppMotion.fast,
                    curve: AppMotion.emphasized,
                    height: _dragging ? 15 : 8,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: _fraction,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white
                              .withValues(alpha: _dragging ? 0.9 : 0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (widget.showTimeLabels)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(_fmt(widget.position), style: AppTypography.caption),
                Text(_rightLabel(), style: AppTypography.caption),
              ],
            ),
          ),
      ],
    );
  }

  void _commit() {
    final double? f = _dragFraction;
    if (f != null && _known) widget.onSeek?.call(_durationFor(f));
    if (mounted) {
      setState(() {
        _dragFraction = null;
        _dragging = false;
      });
    }
  }

  String _rightLabel() {
    if (!_known) return '--:--';
    if (widget.remainingOnRight) {
      final Duration rem = widget.duration - widget.position;
      return '-${_fmt(rem.isNegative ? Duration.zero : rem)}';
    }
    return _fmt(widget.duration);
  }

  String _fmt(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
