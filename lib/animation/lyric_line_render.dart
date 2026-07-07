import 'package:flutter/foundation.dart';

/// Immutable per-line transform snapshot emitted by [LyricPlayerController]
/// each frame. The lyrics view maps one of these onto every `Positioned` line.
///
/// See `AMLL_ANIMATION_SPEC.md` §3.7 / §4 for the field semantics.
@immutable
class LyricLineRender {
  /// Index into the controller's line list.
  final int index;

  /// Vertical offset in logical pixels (top of the line within the stack).
  final double y;

  /// Scale multiplier (1.0 == 100%). Derived from the scale spring's percent.
  final double scale;

  /// 0..1 line opacity.
  final double opacity;

  /// Gaussian blur sigma in pixels (0 == sharp). Capped at 12px — a deeper AMLL
  /// "fog" than the old 5px (AMLL itself caps at 32, `dom/lyric-line.ts:316`)
  /// while staying legible on mobile.
  final double blur;

  /// Alpha for the "sung / bright" text layer (active line → ~1.0).
  final double brightMaskAlpha;

  /// Alpha for the "unsung / dark" text layer (active line → ~0.4).
  final double darkMaskAlpha;

  /// Cascade stagger applied before this line adopted its target, in seconds
  /// (informational; the controller already consumes it internally).
  final double delaySeconds;

  const LyricLineRender({
    required this.index,
    required this.y,
    required this.scale,
    required this.opacity,
    required this.blur,
    required this.brightMaskAlpha,
    required this.darkMaskAlpha,
    required this.delaySeconds,
  });

  LyricLineRender copyWith({
    int? index,
    double? y,
    double? scale,
    double? opacity,
    double? blur,
    double? brightMaskAlpha,
    double? darkMaskAlpha,
    double? delaySeconds,
  }) =>
      LyricLineRender(
        index: index ?? this.index,
        y: y ?? this.y,
        scale: scale ?? this.scale,
        opacity: opacity ?? this.opacity,
        blur: blur ?? this.blur,
        brightMaskAlpha: brightMaskAlpha ?? this.brightMaskAlpha,
        darkMaskAlpha: darkMaskAlpha ?? this.darkMaskAlpha,
        delaySeconds: delaySeconds ?? this.delaySeconds,
      );

  @override
  bool operator ==(Object other) =>
      other is LyricLineRender &&
      other.index == index &&
      other.y == y &&
      other.scale == scale &&
      other.opacity == opacity &&
      other.blur == blur &&
      other.brightMaskAlpha == brightMaskAlpha &&
      other.darkMaskAlpha == darkMaskAlpha &&
      other.delaySeconds == delaySeconds;

  @override
  int get hashCode => Object.hash(
        index,
        y,
        scale,
        opacity,
        blur,
        brightMaskAlpha,
        darkMaskAlpha,
        delaySeconds,
      );
}
