import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Typography tokens for the desktop client.
///
/// The display face [displayFont] (`AlimamaDongFangDaKai`, bundled in pubspec) is
/// used for hero titles, section headers, the song title on the player and the
/// lyrics view. Body / UI / metadata text uses the system default sans — never
/// the display face for lists or metadata (it is a heavy display face).
///
/// Desktop scale (logical px) runs slightly larger heads than mobile for the wide
/// canvas (DESKTOP_UI_PLAN §1.2): displayXL 34 / displayL 30 / displayM 26 /
/// titleL 22 / titleM 18 / body 15 / label 13 / caption 11.
class AppTypography {
  AppTypography._();

  /// Bundled display font family.
  static const String displayFont = 'AlimamaDongFangDaKai';

  // --- display / titles (display font) --------------------------------------

  static const TextStyle displayXL = TextStyle(
    fontFamily: displayFont,
    fontSize: 34,
    height: 1.15,
    color: AppColors.onSurface,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle displayL = TextStyle(
    fontFamily: displayFont,
    fontSize: 30,
    height: 1.2,
    color: AppColors.onSurface,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle displayM = TextStyle(
    fontFamily: displayFont,
    fontSize: 26,
    height: 1.2,
    color: AppColors.onSurface,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle titleL = TextStyle(
    fontFamily: displayFont,
    fontSize: 22,
    height: 1.3,
    color: AppColors.onSurface,
    fontWeight: FontWeight.w400,
  );

  // --- body / UI (system font) ----------------------------------------------

  static const TextStyle titleM = TextStyle(
    fontSize: 18,
    height: 1.4,
    color: AppColors.onSurface,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 1.45,
    color: AppColors.onSurface,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle label = TextStyle(
    fontSize: 13,
    height: 1.4,
    color: AppColors.onSurfaceMuted,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 11,
    height: 1.4,
    color: AppColors.onSurfaceFaint,
    fontWeight: FontWeight.w400,
  );

  /// Material [TextTheme] mapping for `ThemeData.textTheme`.
  static const TextTheme textTheme = TextTheme(
    displayLarge: displayXL,
    displayMedium: displayL,
    displaySmall: displayM,
    headlineMedium: displayM,
    titleLarge: titleL,
    titleMedium: titleM,
    bodyLarge: body,
    bodyMedium: body,
    labelLarge: label,
    labelMedium: label,
    bodySmall: caption,
    labelSmall: caption,
  );
}
