import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../models/playlist.dart';
import '../../../router/routes.dart';
import '../../../theme/app_dimens.dart';
import '../../../theme/app_typography.dart';
import '../../../widgets/artwork_image.dart';

/// A discovery card: square artwork + a two-line caption. Applies a subtle
/// press-scale (transform only — no layout shift) and pushes the playlist
/// detail route on tap.
class PlaylistCard extends StatefulWidget {
  const PlaylistCard({
    super.key,
    required this.playlist,
    this.width = 150,
  });

  final Playlist playlist;
  final double width;

  @override
  State<PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<PlaylistCard> {
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
    final Playlist playlist = widget.playlist;
    final String? caption = playlist.creatorName ?? playlist.description;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: () => context.push(Routes.playlistPath(playlist.id)),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: SizedBox(
          width: widget.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ArtworkImage(
                url: playlist.coverUrl,
                size: widget.width,
                radius: AppDimens.radiusMd,
                shadow: _coverShadow,
              ),
              const SizedBox(height: AppDimens.space8),
              Flexible(
                child: Text(
                  playlist.name,
                  maxLines: caption == null ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (caption != null)
                Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
