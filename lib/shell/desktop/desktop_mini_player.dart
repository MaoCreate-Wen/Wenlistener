import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../router/routes.dart';
import '../../state/player_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_typography.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/glass_container.dart';
import '../../widgets/play_pause_button.dart';

/// Docked, full-width glass mini-player for the desktop shell (mockup §① `.mini`,
/// 72px). Reuses the same per-tick-safe `context.select` field reads as the
/// mobile [MiniPlayer] — it never `watch`es the whole [PlayerProvider], so the
/// per-position notify doesn't rebuild the live blur. The progress hairline on
/// the top edge is isolated into its own selector so only the 2px bar repaints.
class DesktopMiniPlayer extends StatelessWidget {
  const DesktopMiniPlayer({super.key});

  /// Mockup docked mini-player height.
  static const double height = 72;

  @override
  Widget build(BuildContext context) {
    final Song? song =
        context.select<PlayerProvider, Song?>((PlayerProvider p) => p.currentSong);
    if (song == null) return const SizedBox.shrink();
    final Color accent =
        context.select<PlayerProvider, Color>((PlayerProvider p) => p.dynamicAccent);
    final bool isPlaying =
        context.select<PlayerProvider, bool>((PlayerProvider p) => p.isPlaying);
    final bool isBuffering =
        context.select<PlayerProvider, bool>((PlayerProvider p) => p.isBuffering);
    final bool isLiked =
        context.select<PlayerProvider, bool>((PlayerProvider p) => p.isLiked);
    final PlayerProvider player = context.read<PlayerProvider>();

    return SizedBox(
      height: height,
      child: GlassContainer(
        blur: AppDimens.blurNav,
        radius: 0,
        child: Stack(
          children: <Widget>[
            // Accent progress hairline on the TOP edge (mockup `.mini::before`).
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _ProgressHairline(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
              child: Row(
                children: <Widget>[
                  GestureDetector(
                    onTap: () => context.push(Routes.player),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: ArtworkImage(
                        url: song.artworkUrl,
                        size: 48,
                        radius: AppDimens.radiusSm,
                        heroTag: 'album_art',
                        // Shared hero endpoint: same bounded decode key as the
                        // player cover for a pixel-identical flight.
                        heroCover: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppDimens.space12),
                  SizedBox(
                    width: 190,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.body
                              .copyWith(fontWeight: FontWeight.w600),
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
                  const SizedBox(width: AppDimens.space16),
                  // Centered transport cluster.
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        _TransportButton(
                          icon: Icons.skip_previous_rounded,
                          tooltip: 'Previous',
                          onPressed: player.previous,
                        ),
                        const SizedBox(width: AppDimens.space16),
                        PlayPauseButton(
                          isPlaying: isPlaying,
                          isBuffering: isBuffering,
                          size: 40,
                          color: accent,
                          onPressed: player.togglePlay,
                        ),
                        const SizedBox(width: AppDimens.space16),
                        _TransportButton(
                          icon: Icons.skip_next_rounded,
                          tooltip: 'Next',
                          onPressed: player.next,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppDimens.space16),
                  // Right cluster: like + open lyrics/queue.
                  _TransportButton(
                    icon: isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    tooltip: 'Like',
                    color: isLiked ? accent : AppColors.onSurfaceMuted,
                    onPressed: player.toggleLike,
                  ),
                  const SizedBox(width: AppDimens.space8),
                  _TransportButton(
                    icon: Icons.lyrics_outlined,
                    tooltip: 'Lyrics',
                    color: AppColors.onSurfaceMuted,
                    onPressed: () => context.push(Routes.player),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Thin accent progress bar bound to a dedicated `context.select` of the play
/// fraction so only this 2px sliver repaints on each position tick.
class _ProgressHairline extends StatelessWidget {
  const _ProgressHairline();

  @override
  Widget build(BuildContext context) {
    final double progress =
        context.select<PlayerProvider, double>((PlayerProvider p) => p.progress);
    final Color accent =
        context.select<PlayerProvider, Color>((PlayerProvider p) => p.dynamicAccent);
    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        value: progress.clamp(0.0, 1.0),
        minHeight: 2,
        backgroundColor: Colors.transparent,
        valueColor: AlwaysStoppedAnimation<Color>(accent),
      ),
    );
  }
}

class _TransportButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  @override
  State<_TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<_TransportButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final Color base = widget.color ?? AppColors.onSurface;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Padding(
            padding: const EdgeInsets.all(AppDimens.space8),
            child: Icon(
              widget.icon,
              size: 22,
              color: _hovering ? AppColors.onSurface : base,
            ),
          ),
        ),
      ),
    );
  }
}
