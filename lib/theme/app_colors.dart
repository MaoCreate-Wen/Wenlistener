import 'package:flutter/material.dart';

/// Static OLED-dark + glassmorphism color tokens.
///
/// Reference these through [AppColors] / `Theme.of(context)` — never hardcode
/// `Color(0x...)` inside widgets. The dynamic accent (extracted from album art)
/// is surfaced separately by `PlayerProvider.dynamicAccent`.
class AppColors {
  AppColors._();

  /// App scaffold — true black for OLED.
  static const Color bg = Color(0xFF000000);

  /// Base card / sheet surface.
  static const Color surface = Color(0xFF0E0E14);

  /// Frosted glass fill (white @ ~12%) layered over a blur.
  static const Color surfaceGlass = Color(0x1FFFFFFF);

  /// 1px hairline on glass (white @ ~16%).
  static const Color surfaceGlassBorder = Color(0x29FFFFFF);

  /// Primary text.
  static const Color onSurface = Color(0xFFF8FAFC);

  /// Secondary text (white @ 60%).
  static const Color onSurfaceMuted = Color(0x99FFFFFF);

  /// Tertiary / disabled text (white @ 38%).
  static const Color onSurfaceFaint = Color(0x61FFFFFF);

  /// Default play / active affordance (overridden at runtime by dynamic accent).
  static const Color accentPlay = Color(0xFF22C55E);

  /// Fallback brand gradient seed (no album art).
  static const Color seed = Color(0xFF4338CA);

  /// Fallback brand gradient deep stop.
  static const Color seedDeep = Color(0xFF1E1B4B);
}
