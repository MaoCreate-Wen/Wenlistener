import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/home_section.dart';
import '../../../models/song.dart';
import '../../../state/player_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_dimens.dart';
import '../../../theme/app_typography.dart';
import '../../../widgets/artwork_image.dart';
import '../../../widgets/section_header.dart';
import 'playlist_card.dart';

/// A two-column "recommended" grid under a [SectionHeader]. Renders the
/// section's songs (tap → [PlayerProvider.playQueue]) or, when it carries no
/// songs, falls back to its playlists ([PlaylistCard]). Also drives the
/// daily-songs feed: an optional [HomeSection.subtitle] under the title and a
/// per-song [Song.reason] caption when present.
class RecommendedGrid extends StatelessWidget {
  const RecommendedGrid({super.key, required this.section});

  final HomeSection section;

  /// Caption block height for a title + artist (2 lines).
  static const double _captionHeight = 46;

  /// Caption block height when a third [Song.reason] line is shown (3 lines).
  static const double _captionHeightWithReason = 62;
  static const int _columns = 2;

  @override
  Widget build(BuildContext context) {
    final List<Song> songs = section.songs;
    final bool useSongs = songs.isNotEmpty;
    final int count =
        useSongs ? songs.length : section.playlists.length;
    if (count == 0) return const SizedBox.shrink();

    final bool showReasons = useSongs &&
        songs.any((Song s) => (s.reason ?? '').trim().isNotEmpty);
    final double captionHeight =
        showReasons ? _captionHeightWithReason : _captionHeight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: AppDimens.screenPadding),
          child: SectionHeader(title: section.title),
        ),
        if (section.subtitle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.screenPadding,
              0,
              AppDimens.screenPadding,
              AppDimens.space8,
            ),
            child: Text(
              section.subtitle!,
              style:
                  AppTypography.label.copyWith(color: AppColors.onSurfaceMuted),
            ),
          ),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double content =
                constraints.maxWidth - AppDimens.screenPadding * 2;
            final double cell =
                (content - AppDimens.space12 * (_columns - 1)) / _columns;
            final double tileHeight =
                cell + AppDimens.space8 + captionHeight;
            return GridView.builder(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.screenPadding,
              ),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: count,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                crossAxisSpacing: AppDimens.space12,
                mainAxisSpacing: AppDimens.space16,
                mainAxisExtent: tileHeight,
              ),
              itemBuilder: (BuildContext context, int index) {
                if (useSongs) {
                  return _SongCard(
                    song: songs[index],
                    artSize: cell,
                    showReason: showReasons,
                    onTap: () => context
                        .read<PlayerProvider>()
                        .playQueue(songs, index: index),
                  );
                }
                return PlaylistCard(
                  playlist: section.playlists[index],
                  width: cell,
                );
              },
            );
          },
        ),
      ],
    );
  }
}

/// A grid cell for a single recommended song (artwork + title + artist) with a
/// subtle press-scale.
class _SongCard extends StatefulWidget {
  const _SongCard({
    required this.song,
    required this.artSize,
    required this.onTap,
    this.showReason = false,
  });

  final Song song;
  final double artSize;
  final VoidCallback onTap;

  /// When true, surface [Song.reason] (推荐理由) as a third caption line if the
  /// song carries one.
  final bool showReason;

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard> {
  /// Soft, low-alpha drop so the cover floats off the feed — matches the
  /// player page _Artwork resting drop (wide blur, pulled-in negative spread;
  /// reads as depth, not a dark halo). Cover art only, never the caption.
  static const List<BoxShadow> _coverShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x33000000),
      blurRadius: 20,
      offset: Offset(0, 10),
      spreadRadius: -6,
    ),
  ];

  bool _pressed = false;

  void _setPressed(bool value) {
    if (mounted && _pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final Song song = widget.song;
    final String? reason = widget.showReason ? song.reason : null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ArtworkImage(
              url: song.artworkUrl,
              size: widget.artSize,
              radius: AppDimens.radiusMd,
              shadow: _coverShadow,
            ),
            const SizedBox(height: AppDimens.space8),
            Flexible(
              child: Text(
                song.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              song.artistNames,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption,
            ),
            if (reason != null && reason.trim().isNotEmpty)
              Text(
                reason,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption
                    .copyWith(color: AppColors.accentPlay),
              ),
          ],
        ),
      ),
    );
  }
}
