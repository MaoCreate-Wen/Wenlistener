import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../animation/art_background.dart';
import '../../../state/player_provider.dart';

/// Full-bleed fluid album-art background for the player, driven by the current
/// song + extracted palette. Selectively rebuilds only when the artwork or the
/// palette changes (the [ArtBackground] animates itself).
class PlayerBackground extends StatelessWidget {
  const PlayerBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final String? artworkUrl = context.select<PlayerProvider, String?>(
      (PlayerProvider p) => p.currentSong?.artworkUrl,
    );
    final List<Color> palette = context.select<PlayerProvider, List<Color>>(
      (PlayerProvider p) => p.paletteColors,
    );
    return Positioned.fill(
      child: ArtBackground(
        imageUrl: artworkUrl,
        paletteColors: palette,
      ),
    );
  }
}
