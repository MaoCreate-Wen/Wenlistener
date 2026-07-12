import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../animation/lyric_line_render.dart';
import '../../../models/lyric_line.dart';
import '../../../theme/app_colors.dart';
import 'karaoke_text.dart';

/// The one line being sung *right now*. Applies the controller's per-line
/// transform verbatim (line-level [Opacity] + gaussian [ImageFiltered] +
/// [Transform.scale]) and renders the live karaoke (word) or plain content.
///
/// Rebuilt every frame — but the lyrics view builds it for the SINGLE
/// `singingIndex` line only; every other line goes through the reference-cached
/// [StaticLyricLine], which carries no per-frame saveLayer passes. Keeping the
/// mobile-verbatim compositing here (real `Opacity` over the layered dim-base +
/// bright-sweep stack) means the frozen karaoke look is untouched.
class LyricLineWidget extends StatelessWidget {
  final LyricLine line;
  final LyricLineRender render;
  final double currentTimeMs;
  final TextStyle mainStyle;
  final TextStyle translationStyle;
  final double wordFadeWidth;
  final bool isActive;

  const LyricLineWidget({
    super.key,
    required this.line,
    required this.render,
    required this.currentTimeMs,
    required this.mainStyle,
    required this.translationStyle,
    this.wordFadeWidth = 0.5,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    const Color textColor = AppColors.onSurface;

    // Live brightness differentiator `s` (the controller's bright-mask ramp
    // inverted) — drives the white edge ring's fade-in/out so the ring glides
    // with the handoff instead of popping.
    final double s =
        ((render.brightMaskAlpha - 0.2) / 0.8).clamp(0.0, 1.0).toDouble();

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
        // ramp that wraps the content below. B3: the active line additionally
        // carries the white edge ring (faded by `s`) so it separates from the
        // dimmed neighbours without popping at the handoff.
        : Text(
            line.text,
            style: mainStyle.copyWith(
              color: textColor,
              shadows: isActive && s > 0.004
                  ? activeEdgeShadows(mainStyle.fontSize ?? 24, intensity: s)
                  : null,
            ),
          );

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
    // drifting horizontally (matches AMLL's transform-origin).
    Widget content = Transform.scale(
      scale: render.scale,
      alignment: Alignment.centerLeft,
      child: column,
    );

    if (render.blur > 0.3) {
      content = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: render.blur,
          sigmaY: render.blur,
          tileMode: TileMode.decal,
        ),
        child: content,
      );
    }

    return RepaintBoundary(
      child: Opacity(
        opacity: render.opacity.clamp(0.0, 1.0),
        child: content,
      ),
    );
  }
}

/// A NON-singing lyric line, built once per visual state and then reused **by
/// reference** across frames (`_LyricsViewState._staticLine` caches the widget
/// instance), so the controller's per-frame notification costs zero rebuild,
/// zero re-layout and zero repaint for it.
///
/// Renders the same pixels as the live [LyricLineWidget] did for non-singing
/// lines, minus the two per-frame offscreen (saveLayer) passes:
///
///  • The line-level `Opacity` widget is FOLDED into the text paint colors —
///    [mainAlpha] / [translationAlpha] already carry `render.opacity`. A
///    non-singing line's content is flat single-layer text (the karaoke flat
///    Wrap or a plain [Text] plus a translation below), so alpha-in-the-color
///    composites identically to a group opacity, without the offscreen pass.
///  • The gaussian blur stays (same `ImageFilter`, same `TileMode.decal`), but
///    the caller quantizes [blurSigma] to 0.25px buckets, so the 0.2s blur
///    transitions re-record a line a handful of times instead of every frame
///    (≤0.125px sigma deviation — invisible on the ≥0.8px "fog" sigmas), and a
///    settled line's blurred layer is left untouched frame after frame.
///  • `render.scale` is applied by the caller OUTSIDE this widget's
///    [RepaintBoundary] (a pure compositor transform), so the y springs, the
///    handoff scale spring and the pause/resume 97↔100 re-flow never
///    re-rasterize the line. Blur therefore runs in pre-scale space; at the
///    0.97 inactive scale that is a ≤3% sigma difference — sub-pixel at the
///    12px cap.
class StaticLyricLine extends StatelessWidget {
  final LyricLine line;
  final TextStyle mainStyle;
  final TextStyle translationStyle;

  /// Final paint alpha for the main text: the karaoke flat ink
  /// (`passed ? brightMaskAlpha : darkMaskAlpha`, or 1.0 for plain lines)
  /// multiplied by the line-level `render.opacity`.
  final double mainAlpha;

  /// Final paint alpha for the translation: its style alpha × `render.opacity`.
  final double translationAlpha;

  /// Quantized gaussian sigma (0 == sharp, skips the filter entirely).
  final double blurSigma;

  /// Constant vertical offset (logical px, ≤ 0) the main line rests at — the
  /// per-word float's fill-forwards end position for a PASSED word-by-word
  /// line ([karaokeRestDy]); 0 for upcoming/plain lines. Applied to the main
  /// Wrap only (the translation below never floats), exactly like the live
  /// per-word transforms it replaces.
  final double floatDy;

  /// White edge-ring alpha (0..1, already folded with the line opacity). The
  /// live path fades the ring with the handoff differentiator `s`; carrying the
  /// tail of that fade here keeps the live→static swap seamless (0 for settled
  /// distant lines, so their cached subtree is unchanged).
  final double edgeAlpha;

  const StaticLyricLine({
    super.key,
    required this.line,
    required this.mainStyle,
    required this.translationStyle,
    required this.mainAlpha,
    required this.translationAlpha,
    required this.blurSigma,
    this.floatDy = 0,
    this.edgeAlpha = 0,
  });

  @override
  Widget build(BuildContext context) {
    final Color mainColor = AppColors.onSurface.withValues(alpha: mainAlpha);
    final TextStyle mainLineStyle = mainStyle.copyWith(
      color: mainColor,
      shadows: edgeAlpha > 0.004
          ? activeEdgeShadows(mainStyle.fontSize ?? 24, intensity: edgeAlpha)
          : null,
    );

    // Mirrors KaraokeText's non-singing flat branch: keep the per-word Wrap so
    // the layout never jumps on the singing handoff.
    Widget mainLine = line.isWordByWord
        ? Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            children: <Widget>[
              for (final LyricWord word in line.words)
                Text(word.text, style: mainLineStyle),
            ],
          )
        : Text(line.text, style: mainLineStyle);
    if (floatDy != 0) {
      mainLine = Transform.translate(
        offset: Offset(0, floatDy),
        child: mainLine,
      );
    }

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        mainLine,
        if ((line.translation ?? '').isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            line.translation!,
            style: translationStyle.copyWith(
              color: (translationStyle.color ?? AppColors.onSurfaceMuted)
                  .withValues(alpha: translationAlpha),
            ),
          ),
        ],
      ],
    );

    if (blurSigma > 0.3) {
      content = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.decal,
        ),
        child: content,
      );
    }

    return RepaintBoundary(child: content);
  }
}
