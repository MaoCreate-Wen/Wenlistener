import 'package:flutter/material.dart';

/// Circular play / pause control that shows a spinner while buffering.
class PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onPressed;
  final bool isBuffering;
  final double size;
  final Color? color;

  const PlayPauseButton({
    super.key,
    required this.isPlaying,
    required this.onPressed,
    this.isBuffering = false,
    this.size = 56,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isBuffering ? null : onPressed,
          child: isBuffering
              ? Padding(
                  padding: EdgeInsets.all(size * 0.3),
                  child: CircularProgressIndicator(strokeWidth: 2, color: c),
                )
              : Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: c,
                  size: size * 0.6,
                ),
        ),
      ),
    );
  }
}
