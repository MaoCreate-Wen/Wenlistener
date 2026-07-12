import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../state/player_provider.dart';
import '../theme/app_colors.dart';
import 'buttons.dart';

/// Heart toggle wired to [PlayerProvider]. Without a [song] it tracks the
/// now-playing track ([PlayerProvider.isLiked] / [PlayerProvider.toggleLike]);
/// with a [song] it targets that specific row ([isLikedSong] / [setLiked]) so a
/// track row's heart is correct regardless of what's playing. Selects only the
/// liked flag so a position tick doesn't rebuild it.
class LikeButton extends StatelessWidget {
  final Song? song;
  final double size;

  const LikeButton({super.key, this.song, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final Song? target = song;
    final bool liked = context.select<PlayerProvider, bool>((PlayerProvider p) =>
        target == null ? p.isLiked : p.isLikedSong(target));
    final Color accent =
        context.select((PlayerProvider p) => p.dynamicAccent);
    return IconHoverButton(
      icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      size: size,
      iconSize: size * 0.55,
      active: liked,
      activeColor: accent == AppColors.accentPlay ? AppColors.accentPlay : accent,
      tooltip: liked ? '取消喜欢' : '喜欢',
      onTap: () {
        final PlayerProvider p = context.read<PlayerProvider>();
        if (target == null) {
          p.toggleLike();
        } else {
          p.setLiked(target, !p.isLikedSong(target));
        }
      },
    );
  }
}
