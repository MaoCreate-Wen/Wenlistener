import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/player_provider.dart';

/// Static OLED-dark + glassmorphism color tokens for the **desktop** client.
///
/// The four members the reused logic layer imports ([bg], [seed], [seedDeep],
/// [accentPlay]) are load-bearing — `services/artwork_palette.dart`,
/// `state/player_provider.dart`, `animation/art_background.dart` and
/// `animation/neon_flow_background.dart` will not compile without them. The rest
/// are the desktop UI surface/text tokens (DESIGN_SYSTEM §2 + DESKTOP_UI_PLAN
/// §1.1). Reference these through [AppColors] / `Theme.of(context)` — never
/// hardcode `Color(0x...)` inside widgets. The *dynamic* accent (extracted from
/// album art) is surfaced separately by `PlayerProvider.dynamicAccent`; read it
/// via [accentOf].
class AppColors {
  AppColors._();

  // --- required by the reused logic layer (do NOT rename/remove) -----------

  /// App scaffold — true black for OLED.
  static const Color bg = Color(0xFF000000);

  /// Default play / active affordance (overridden at runtime by dynamic accent).
  static const Color accentPlay = Color(0xFF22C55E);

  /// Fallback brand gradient seed (no album art).
  static const Color seed = Color(0xFF4338CA);

  /// Fallback brand gradient deep stop.
  static const Color seedDeep = Color(0xFF1E1B4B);

  // --- desktop UI surfaces --------------------------------------------------

  /// Base card / sheet surface.
  static const Color surface = Color(0xFF0E0E14);

  /// Raised panel surface.
  static const Color surface2 = Color(0xFF0F0F23);

  /// Frosted glass fill (white @ ~8%) layered over a blur.
  static const Color glass = Color(0x14FFFFFF);

  /// Denser glass fill (white @ ~12%) — mini-player / title bar.
  static const Color glassStrong = Color(0x1FFFFFFF);

  /// 1px hairline on glass (white @ ~14%).
  static const Color glassBorder = Color(0x24FFFFFF);

  /// Alias kept for DESIGN_SYSTEM naming parity (== [glassStrong]).
  static const Color surfaceGlass = glassStrong;

  /// Alias kept for DESIGN_SYSTEM naming parity (== [glassBorder]).
  static const Color surfaceGlassBorder = glassBorder;

  // --- text -----------------------------------------------------------------

  /// Primary text.
  static const Color onSurface = Color(0xFFF8FAFC);

  /// Secondary text (white @ 60%).
  static const Color onSurfaceMuted = Color(0x99FFFFFF);

  /// Tertiary / disabled text (white @ 38%).
  static const Color onSurfaceFaint = Color(0x61FFFFFF);

  /// DESKTOP_UI_PLAN aliases.
  static const Color onMuted = onSurfaceMuted;
  static const Color onFaint = onSurfaceFaint;

  // --- interaction states ---------------------------------------------------

  /// Row / card hover fill (white @ 6%).
  static const Color hover = Color(0x0FFFFFFF);

  /// Pressed fill (white @ 10%).
  static const Color pressed = Color(0x1AFFFFFF);

  /// Selected / active track-row fill (white @ 9%).
  static const Color rowSelected = Color(0x17FFFFFF);

  // --- fallback gradient seeds (when there is no art) -----------------------

  /// Fallback gradient stop A.
  static const Color seedA = Color(0xFF4338CA);

  /// Fallback gradient stop B.
  static const Color seedB = Color(0xFF1E1B4B);

  /// The live album-art accent for the currently-playing track. Convenience over
  /// `context.select((PlayerProvider p) => p.dynamicAccent)`; drives progress
  /// fill, active nav pill, lyric highlight, like button and hero glow.
  static Color accentOf(BuildContext context) =>
      context.select((PlayerProvider p) => p.dynamicAccent);
}
