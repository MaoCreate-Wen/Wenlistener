import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Typography tokens.
///
/// The display face [displayFont] (`AlimamaDongFangDaKai`) is used for hero
/// titles, the song title on the player and the lyrics view. Body / UI text
/// uses the system default sans — never the display face for lists or metadata.
class AppTypography {
  AppTypography._();

  /// Bundled display font family.
  static const String displayFont = 'AlimamaDongFangDaKai';

  // Display / title (display font).
  static const TextStyle displayL = TextStyle(
    fontFamily: displayFont,
    fontSize: 32,
    height: 1.2,
    color: AppColors.onSurface,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle displayM = TextStyle(
    fontFamily: displayFont,
    fontSize: 28,
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

  // Body / UI (system font).
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
    displayLarge: displayL,
    displayMedium: displayM,
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
