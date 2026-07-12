import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../models/image_url.dart';
import '../../../theme/app_colors.dart';

/// Self-contained album-art image for the player/lyrics surfaces (this agent owns
/// `pages/player` + `pages/lyrics`, so it carries its own artwork widget rather
/// than depending on a shared `widgets/` primitive that another agent builds).
///
/// Netease CDN covers are upgraded to HTTPS ([httpsImageUrl]) and fetched with a
/// browser UA + Referer ([kNeteaseImageHeaders]) — without both the CDN 403s /
/// silently falls back to a placeholder. Reserves its [size] so async loads never
/// jump the layout, and renders a muted surface tile for null/empty/failed art.
class PlayerArtwork extends StatelessWidget {
  final String? url;
  final double size;
  final double radius;
  final List<BoxShadow>? shadow;

  const PlayerArtwork({
    super.key,
    required this.url,
    required this.size,
    required this.radius,
    this.shadow,
  });

  @override
  Widget build(BuildContext context) {
    final String? resolved = httpsImageUrl(url);
    final BorderRadius br = BorderRadius.circular(radius);

    Widget image;
    if (resolved == null) {
      image = _placeholder();
    } else {
      image = CachedNetworkImage(
        imageUrl: resolved,
        httpHeaders: kNeteaseImageHeaders,
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 220),
        placeholder: (_, __) => _placeholder(),
        errorWidget: (_, __, ___) => _placeholder(),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: shadow,
      ),
      child: ClipRRect(borderRadius: br, child: image),
    );
  }

  Widget _placeholder() => Container(
        width: size,
        height: size,
        color: AppColors.surface2,
        alignment: Alignment.center,
        child: Icon(
          Icons.music_note_rounded,
          size: size * 0.28,
          color: AppColors.onSurfaceFaint,
        ),
      );
}
