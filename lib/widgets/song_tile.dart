import 'package:flutter/material.dart';

import '../models/song.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'artwork_image.dart';

/// The canonical list row: artwork + title + artist, with optional leading /
/// trailing slots. Highlights the title when [isActive].
class SongTile extends StatelessWidget {
  final String title;
  final String artist;
  final String? artworkUrl;
  final Widget? leading;
  final Widget? trailing;
  final bool isActive;
  final VoidCallback? onTap;
  final VoidCallback? onTrailingTap;

  const SongTile({
    super.key,
    required this.title,
    required this.artist,
    this.artworkUrl,
    this.leading,
    this.trailing,
    this.isActive = false,
    this.onTap,
    this.onTrailingTap,
  });

  factory SongTile.fromSong(
    Song song, {
    Widget? leading,
    Widget? trailing,
    bool isActive = false,
    VoidCallback? onTap,
    VoidCallback? onTrailingTap,
  }) {
    return SongTile(
      title: song.name,
      artist: song.artistNames,
      artworkUrl: song.artworkUrl,
      leading: leading,
      trailing: trailing,
      isActive: isActive,
      onTap: onTap,
      onTrailingTap: onTrailingTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color titleColor =
        isActive ? Theme.of(context).colorScheme.primary : AppColors.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: AppDimens.space8,
          horizontal: AppDimens.space8,
        ),
        child: Row(
          children: <Widget>[
            leading ??
                ArtworkImage(url: artworkUrl, size: AppDimens.tileArtwork),
            const SizedBox(width: AppDimens.space12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body.copyWith(
                      color: titleColor,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.label,
                  ),
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: AppDimens.space8),
              if (onTrailingTap != null)
                GestureDetector(onTap: onTrailingTap, child: trailing!)
              else
                trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
