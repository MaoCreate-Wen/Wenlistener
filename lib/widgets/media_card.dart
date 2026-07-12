import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_typography.dart';
import 'artwork_image.dart';
import 'hover_scale.dart';

/// A carousel / grid card: square cover + 2-line caption. On hover it lifts a
/// shadow and reveals a floating play button (fires [onPlay] without opening the
/// card). Tapping the body fires [onTap] (open detail). No layout-shifting hover.
class MediaCard extends StatelessWidget {
  final String? artworkUrl;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final double size;

  const MediaCard({
    super.key,
    required this.artworkUrl,
    required this.title,
    this.subtitle,
    this.onTap,
    this.onPlay,
    this.size = AppDimens.cardSize,
  });

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (BuildContext context, bool hovering) => HoverScale(
        onTap: onTap,
        child: SizedBox(
          width: size,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Stack(
                children: <Widget>[
                  ArtworkImage(
                    url: artworkUrl,
                    size: size,
                    radius: AppDimens.radiusMd,
                    shadow: hovering ? AppDimens.albumShadow : null,
                  ),
                  if (onPlay != null)
                    Positioned(
                      right: AppDimens.space8,
                      bottom: AppDimens.space8,
                      child: AnimatedOpacity(
                        opacity: hovering ? 1 : 0,
                        duration: const Duration(milliseconds: 140),
                        child: _PlayFab(onTap: onPlay!),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppDimens.space8),
              Text(
                title,
                style: AppTypography.body.copyWith(fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: AppTypography.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayFab extends StatelessWidget {
  final VoidCallback onTap;
  const _PlayFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return HoverScale(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.accentPlay,
          boxShadow: AppDimens.glassShadow,
        ),
        child: const Icon(Icons.play_arrow_rounded, color: Colors.black, size: 24),
      ),
    );
  }
}
