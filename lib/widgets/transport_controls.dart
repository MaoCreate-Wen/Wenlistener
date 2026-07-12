import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/audio_service.dart' show RepeatMode;
import '../state/player_provider.dart';
import '../theme/app_colors.dart';

/// Transparent, monochrome-white transport icon with an AMLL-style press bounce
/// (scale-in + a soft `#fff2` fill flash, ~220ms settle). No accent tint — the
/// AMLL MediaButton is always white (DESIGN_SYSTEM player spec).
class MediaButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color color;
  final bool active;
  final Color? activeColor;
  final String? tooltip;

  const MediaButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 44,
    this.iconSize = 24,
    this.color = AppColors.onSurface,
    this.active = false,
    this.activeColor,
    this.tooltip,
  });

  @override
  State<MediaButton> createState() => _MediaButtonState();
}

class _MediaButtonState extends State<MediaButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final Color fg = widget.active
        ? (widget.activeColor ?? AppColors.accentPlay)
        : widget.color;
    Widget button = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.86 : 1.0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: Container(
            width: widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _pressed
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.transparent,
            ),
            child: Icon(widget.icon, size: widget.iconSize, color: fg),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}

/// The central play/pause control. [light] = a solid white disc with a black
/// glyph (player page / mini-player); otherwise a transparent white glyph.
/// Shows a small spinner while buffering.
class PlayPauseButton extends StatelessWidget {
  final bool isPlaying;
  final bool isBuffering;
  final VoidCallback? onTap;
  final double size;
  final bool light;

  const PlayPauseButton({
    super.key,
    required this.isPlaying,
    this.isBuffering = false,
    this.onTap,
    this.size = 44,
    this.light = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!light) {
      return MediaButton(
        icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        iconSize: size * 0.6,
        size: size,
        onTap: onTap,
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.onSurface,
          ),
          alignment: Alignment.center,
          child: isBuffering
              ? SizedBox(
                  width: size * 0.4,
                  height: size * 0.4,
                  child: const CircularProgressIndicator(
                    strokeWidth: 2.4,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                  ),
                )
              : Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.black,
                  size: size * 0.56,
                ),
        ),
      ),
    );
  }
}

/// The full transport cluster — consumes [PlayerProvider] and centers
/// (shuffle ·) prev · play/pause · next (· repeat). [full] adds the shuffle and
/// repeat toggles (player page); the mini-player passes `full: false`. Selects
/// each field so a position tick doesn't rebuild the whole row.
class TransportControls extends StatelessWidget {
  final bool full;
  final double playSize;
  final double gap;

  const TransportControls({
    super.key,
    this.full = true,
    this.playSize = 64,
    this.gap = 24,
  });

  @override
  Widget build(BuildContext context) {
    final bool isPlaying =
        context.select((PlayerProvider p) => p.isPlaying);
    final bool isBuffering =
        context.select((PlayerProvider p) => p.isBuffering);
    final PlayerProvider actions = context.read<PlayerProvider>();

    final List<Widget> row = <Widget>[];
    if (full) {
      final bool shuffle =
          context.select((PlayerProvider p) => p.shuffleEnabled);
      row.add(MediaButton(
        icon: Icons.shuffle_rounded,
        iconSize: 22,
        active: shuffle,
        onTap: actions.toggleShuffle,
        tooltip: '随机播放',
      ));
      row.add(SizedBox(width: gap));
    }
    row.add(MediaButton(
      icon: Icons.skip_previous_rounded,
      iconSize: playSize * 0.42,
      onTap: actions.previous,
      tooltip: '上一首',
    ));
    row.add(SizedBox(width: gap));
    row.add(PlayPauseButton(
      isPlaying: isPlaying,
      isBuffering: isBuffering,
      size: playSize,
      onTap: actions.togglePlay,
    ));
    row.add(SizedBox(width: gap));
    row.add(MediaButton(
      icon: Icons.skip_next_rounded,
      iconSize: playSize * 0.42,
      onTap: actions.next,
      tooltip: '下一首',
    ));
    if (full) {
      final RepeatMode repeat =
          context.select((PlayerProvider p) => p.repeatMode);
      row.add(SizedBox(width: gap));
      row.add(MediaButton(
        icon: repeat == RepeatMode.one
            ? Icons.repeat_one_rounded
            : Icons.repeat_rounded,
        iconSize: 22,
        active: repeat != RepeatMode.off,
        onTap: actions.cycleRepeat,
        tooltip: switch (repeat) {
          RepeatMode.off => '顺序播放',
          RepeatMode.all => '列表循环',
          RepeatMode.one => '单曲循环',
        },
      ));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: row);
  }
}
