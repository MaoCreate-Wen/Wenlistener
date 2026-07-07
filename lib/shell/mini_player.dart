import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../router/routes.dart';
import '../state/player_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import '../widgets/artwork_image.dart';
import '../widgets/glass_container.dart';
import '../widgets/play_pause_button.dart';

/// Always-mounted (in [HomeShell]) compact player. Tapping it pushes the full
/// player route; the artwork carries the shared `album_art` hero.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // Field-level selects, NOT a whole-provider watch: the MiniPlayer is always
    // mounted, so a per-tick position notify (PlayerProvider._onSnapshot fires on
    // every position change) must not rebuild it and its live blur. It depends
    // only on the song / play-state / accent, all of which change far less often.
    final Song? song = context
        .select<PlayerProvider, Song?>((PlayerProvider p) => p.currentSong);
    if (song == null) return const SizedBox.shrink();
    final Color accent = context
        .select<PlayerProvider, Color>((PlayerProvider p) => p.dynamicAccent);
    final bool isPlaying =
        context.select<PlayerProvider, bool>((PlayerProvider p) => p.isPlaying);
    final bool isBuffering = context
        .select<PlayerProvider, bool>((PlayerProvider p) => p.isBuffering);
    final PlayerProvider player = context.read<PlayerProvider>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space12,
        0,
        AppDimens.space12,
        AppDimens.space4,
      ),
      child: GestureDetector(
        onTap: () => context.push(Routes.player),
        child: GlassContainer(
          blur: AppDimens.blurNav,
          radius: AppDimens.radiusLg,
          padding: const EdgeInsets.all(AppDimens.space8),
          child: SizedBox(
            height: AppDimens.miniPlayerHeight - 16,
            child: Row(
              children: <Widget>[
                ArtworkImage(
                  url: song.artworkUrl,
                  size: AppDimens.miniPlayerHeight - 28,
                  radius: AppDimens.radiusSm,
                  heroTag: 'album_art',
                ),
                const SizedBox(width: AppDimens.space12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        song.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        song.artistNames,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.label,
                      ),
                    ],
                  ),
                ),
                PlayPauseButton(
                  isPlaying: isPlaying,
                  isBuffering: isBuffering,
                  size: 40,
                  color: accent,
                  onPressed: player.togglePlay,
                ),
                IconButton(
                  onPressed: player.next,
                  icon: const Icon(
                    Icons.skip_next_rounded,
                    color: AppColors.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
