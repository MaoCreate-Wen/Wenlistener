import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../pages/player/widgets/queue_panel.dart';
import '../router/routes.dart';
import '../state/player_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import '../widgets/artwork_image.dart';
import '../widgets/buttons.dart';
import '../widgets/like_button.dart';
import '../widgets/transport_controls.dart';
import '../widgets/volume_control.dart';

/// Docked bottom mini-player (72px glass). A top accent progress line,
/// then art + title/artist (→ `/player`) · centered transport · right cluster
/// (like · volume · open lyrics). Every piece reads [PlayerProvider] via
/// `context.select` so a position tick only rebuilds the thin progress line, not
/// the whole bar (the mobile per-tick-rebuild lesson).
///
/// Performance: this bar used to sit on a `GlassContainer` (BackdropFilter,
/// sigma 18). In [AppShell]'s layout the mini-player is a layout *sibling* of
/// the content — the only thing painted behind it is the session-frozen wash
/// gradient, and a Gaussian blur of a smooth static gradient is visually the
/// gradient itself. The filter therefore re-ran a full-width sigma-18 backdrop
/// blur on every composited frame (each position tick, every scroll frame) for
/// zero visible effect. It is replaced by the same translucent fill without the
/// filter — identical look, no per-frame blur on the raster thread.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final bool hasSong = context.select((PlayerProvider p) => p.hasSong);

    return SizedBox(
      height: AppDimens.miniPlayerHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Same fill GlassContainer painted over its blur (white @ 0.12).
          color: Colors.white.withValues(alpha: 0.12),
          border: const Border(
            top: BorderSide(color: AppColors.glassBorder, width: 1),
          ),
        ),
        child: Stack(
          children: <Widget>[
            // RepaintBoundary: the line repaints ~5×/s while playing; without
            // the boundary each tick dirtied (and re-rasterised) the whole bar.
            const Align(
              alignment: Alignment.topCenter,
              child: RepaintBoundary(child: _ProgressLine()),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppDimens.space16),
              child: hasSong
                  ? const _MiniBody()
                  : const _IdleBody(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Thin accent progress line on the top edge — the only piece that watches
/// `progress`, so a position tick rebuilds just these 2 pixels. The select is
/// quantised to 1/512 of the width (~2–3 px on a typical window): position
/// emissions that wouldn't visibly move the line no longer rebuild anything.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine();

  @override
  Widget build(BuildContext context) {
    final double progress = context.select(
        (PlayerProvider p) => (p.progress * 512).roundToDouble() / 512);
    final Color accent = context.select((PlayerProvider p) => p.dynamicAccent);
    return SizedBox(
      height: 2,
      width: double.infinity,
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: progress.clamp(0.0, 1.0),
        child: ColoredBox(color: accent),
      ),
    );
  }
}

class _IdleBody extends StatelessWidget {
  const _IdleBody();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppDimens.radiusSm),
          ),
          child: const Icon(Icons.music_note_rounded,
              color: AppColors.onSurfaceFaint, size: 22),
        ),
        const SizedBox(width: AppDimens.space12),
        Text('未在播放', style: AppTypography.label),
      ],
    );
  }
}

class _MiniBody extends StatelessWidget {
  const _MiniBody();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        Expanded(child: _NowPlaying()),
        TransportControls(full: false, playSize: 40, gap: 14),
        Expanded(child: _RightCluster()),
      ],
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying();

  @override
  Widget build(BuildContext context) {
    final Song? song = context.select((PlayerProvider p) => p.currentSong);
    if (song == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => context.push(Routes.player),
            child: ArtworkImage(
              url: song.artworkUrl,
              size: 48,
              radius: AppDimens.radiusSm,
              heroTag: 'album_art',
            ),
          ),
        ),
        const SizedBox(width: AppDimens.space12),
        Flexible(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => context.push(Routes.player),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body.copyWith(
                      fontFamily: AppTypography.displayFont,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    song.artistNames,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption
                        .copyWith(color: AppColors.onSurfaceMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RightCluster extends StatelessWidget {
  const _RightCluster();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const LikeButton(size: 34),
        const SizedBox(width: AppDimens.space4),
        const VolumeControl(width: 84),
        const SizedBox(width: AppDimens.space8),
        IconHoverButton(
          icon: Icons.queue_music_rounded,
          size: 34,
          iconSize: 20,
          tooltip: '播放列表',
          onTap: () => showQueuePanel(context),
        ),
        IconHoverButton(
          icon: Icons.open_in_full_rounded,
          size: 34,
          iconSize: 18,
          tooltip: '打开播放器',
          onTap: () => context.push(Routes.player),
        ),
      ],
    );
  }
}
