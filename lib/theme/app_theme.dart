import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_dimens.dart';
import 'app_typography.dart';

/// Material 3 OLED-dark theme built from [AppColors.seed], with surfaces
/// overridden to the desktop dark tokens. Consumed by `MaterialApp.router`.
class AppTheme {
  AppTheme._();

  static ThemeData dark() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.seed,
      brightness: Brightness.dark,
    ).copyWith(
      surface: AppColors.surface,
      onSurface: AppColors.onSurface,
      primary: AppColors.accentPlay,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      canvasColor: AppColors.bg,
      textTheme: AppTypography.textTheme,
      // The desktop UI draws its own hover/press feedback (MouseRegion tints,
      // AMLL MediaButton swell, PlayerScrubber). Kill the global Material
      // splash/highlight so no white ripple flashes on click.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(
          overlayColor: WidgetStatePropertyAll<Color>(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
        ),
      ),
      textButtonTheme: const TextButtonThemeData(
        style: ButtonStyle(
          overlayColor: WidgetStatePropertyAll<Color>(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      iconTheme: const IconThemeData(color: AppColors.onSurface),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll<Color>(AppColors.glassBorder),
        thickness: const WidgetStatePropertyAll<double>(6),
        radius: const Radius.circular(AppDimens.radiusPill),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.onSurface),
        titleTextStyle: AppTypography.titleM,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.glassBorder,
        thickness: 1,
        space: AppDimens.space16,
      ),
    );
  }
}
