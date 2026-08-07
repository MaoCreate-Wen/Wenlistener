import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../animation/lyric_line_render.dart';
import '../../../models/lyric_line.dart';
import '../../../theme/app_colors.dart';
import 'karaoke_text.dart';

/// One absolutely-positioned lyric line. Applies the controller's per-line
/// transform (scale / opacity / blur) and renders either the karaoke (word) or
/// a plain line, plus an optional translation.
class LyricLineWidget extends StatelessWidget {
  final LyricLine line;
  final LyricLineRender render;
  final double currentTimeMs;
  final TextStyle mainStyle;
  final TextStyle translationStyle;
  final double wordFadeWidth;
  final bool isActive;

  /// When true (during the player↔lyrics morph) the line renders the CHEAP path:
  /// the animated per-line [render.scale] is dropped to a FIXED 1.0 (the animated
  /// scale re-rasterized text at fractional sizes every frame → `CreateGlyphAtlas`
  /// thrash), and the per-line Gaussian blur (`ImageFilter.blur`, a full offscreen
  /// per blurred line — ~6-10 live mid-cascade) is skipped. Combined with
  /// `isActive:false` (no additive-glow saveLayer / per-word ShaderMask) this cut
  /// the transition's per-frame raster from ~40-58ms toward budget.
  final bool morphing;

  /// Whole-view fade multiplier (the player↔lyrics morph's lyrics-alpha), applied
  /// PER LINE so the crossfade needs no full-screen group-Opacity offscreen. 1.0
  /// when settled.
  final double fadeAlpha;

  const LyricLineWidget({
    super.key,
    required this.line,
    required this.render,
    required this.currentTimeMs,
    required this.mainStyle,
    required this.translationStyle,
    this.wordFadeWidth = 0.5,
    required this.isActive,
    this.morphing = false,
    this.fadeAlpha = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    const Color textColor = AppColors.onSurface;

    final Widget mainLine = line.isWordByWord
        ? KaraokeText(
            line: line,
            currentTimeMs: currentTimeMs,
            style: mainStyle,
            textColor: textColor,
            brightAlpha: render.brightMaskAlpha,
            darkAlpha: render.darkMaskAlpha,
            wordFadeWidth: wordFadeWidth,
            // Only the line being sung gets the moving fill/emphasis; others
            // render flat so two lines never sweep at once. ([isActive] here is
            // already the controller's [singingIndex], not the early-shifted
            // [activeIndex] used for the lift/scale.)
            isSinging: isActive,
          )
        // No word-level timing → no fake per-character sweep. The whole line
        // lights up as one uniform-brightness sentence; its active-vs-inactive
        // brightness comes entirely from the line-level Opacity(render.opacity)
        // ramp that wraps the content below.
        : Text(line.text, style: mainStyle.copyWith(color: textColor));

    Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        mainLine,
        if ((line.translation ?? '').isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(line.translation!, style: translationStyle),
        ],
      ],
    );

    // Scale about the left edge so lines grow toward the reader without
    // drifting horizontally (matches AMLL's transform-origin). During the morph
    // the scale is pinned to 1.0: an animated fractional scale re-rasterizes the
    // text into the glyph atlas every frame (the measured CreateGlyphAtlas
    // thrash), so hold it steady until the morph settles.
    Widget content = morphing
        ? column
        : Transform.scale(
            scale: render.scale,
            alignment: Alignment.centerLeft,
            child: column,
          );

    if (!morphing && render.blur > 0.3) {
      content = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: render.blur,
          sigmaY: render.blur,
          tileMode: TileMode.decal,
        ),
        child: content,
      );
    }

    // Opacity is OUTSIDE the RepaintBoundary: the line rasterizes into its own
    // layer once, and the fade (its own cascade opacity × the whole-view morph
    // [fadeAlpha]) is a cheap compositor alpha-modulation of that cached layer —
    // NOT a re-raster, and NOT the full-screen group-Opacity offscreen the host
    // used to wrap the whole LyricsView in (a ~8.6ms saveLayer on Impeller).
    return Opacity(
      opacity: (render.opacity * fadeAlpha).clamp(0.0, 1.0),
      child: RepaintBoundary(child: content),
    );
  }
}
