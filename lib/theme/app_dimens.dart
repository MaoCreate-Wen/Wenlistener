import 'package:flutter/material.dart';

/// Spacing, radius, blur and elevation tokens (4-pt scale).
class AppDimens {
  AppDimens._();

  // Spacing scale (4-pt).
  static const double space4 = 4;
  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space32 = 32;
  static const double space48 = 48;

  /// Default horizontal screen padding.
  static const double screenPadding = 16;

  // Corner radii.
  static const double radiusSm = 10;
  static const double radiusMd = 16;
  static const double radiusLg = 22;
  static const double radiusXl = 28;
  static const double radiusPill = 999;

  /// Album-art corner radius scales with the art size (matches legacy `size/20`).
  static double albumRadius(double size) => size / 20;

  // Glass blur sigmas.
  static const double blurPanel = 24;
  static const double blurPlayerBg = 30;
  // Kept moderate: blur cost scales super-linearly with sigma, and the nav/mini
  // bars drop to a flat scrim while anything animates (see GlassMotion), so this
  // only pays out on static frames.
  static const double blurNav = 12;

  // Component heights / sizes.
  static const double miniPlayerHeight = 64;
  static const double navHeight = 64;
  static const double tileArtwork = 56;
  static const double minTouch = 44;

  /// Soft shadow under glass surfaces (black @ 40%, blur 16, y 8).
  static const List<BoxShadow> glassShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x66000000),
      blurRadius: 16,
      offset: Offset(0, 8),
    ),
  ];

  /// Depth shadow under home-feed album covers (black @ 35%, blur 18, y 8,
  /// pulled in -2 so it reads as a tight drop, not a halo).
  static const List<BoxShadow> albumShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x59000000),
      blurRadius: 18,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
  ];
}
