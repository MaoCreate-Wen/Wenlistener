import 'package:flutter/material.dart';

/// Spacing, radius, blur, elevation and shell-metric tokens (4-pt scale) for the
/// desktop client (DESKTOP_UI_PLAN §1.3 / mockup.html geometry).
class AppDimens {
  AppDimens._();

  // --- spacing (4-pt) -------------------------------------------------------
  static const double space4 = 4;
  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space32 = 32;
  static const double space48 = 48;

  /// Default desktop screen padding.
  static const double screenPadding = 24;

  /// Gap between feed sections.
  static const double sectionGap = 20;

  // --- corner radii ---------------------------------------------------------
  static const double radiusSm = 10;
  static const double radiusMd = 16;
  static const double radiusLg = 22;
  static const double radiusXl = 28;
  static const double radiusPill = 999;

  /// Album-art corner radius scales with the art size (matches legacy `size/20`).
  static double albumRadius(double size) => size / 20;

  // --- glass blur sigmas ----------------------------------------------------
  static const double blurPanel = 24;
  static const double blurPlayerBg = 30;

  /// Sidebar / mini-player / title-bar chrome blur.
  static const double blurChrome = 18;

  // --- shell metrics (mockup.html) ------------------------------------------
  static const double titleBarHeight = 38;
  static const double sidebarWidth = 230;
  static const double sidebarRailWidth = 72;
  static const double miniPlayerHeight = 72;
  static const double cardSize = 150;
  static const double playerCoverSize = 330;
  static const double minTouch = 44;

  /// Below this window width the sidebar collapses to the icon rail.
  static const double sidebarCollapseWidth = 1080;

  /// Below this content width dense track tables hide the album column.
  static const double tableAlbumHideWidth = 900;

  // --- z-index scale --------------------------------------------------------
  static const double zBase = 0;
  static const double zNav = 10;
  static const double zMiniPlayer = 20;
  static const double zOverlay = 30;
  static const double zPlayer = 40;
  static const double zToast = 50;

  /// Soft shadow under glass surfaces (black @ 40%, blur 16, y 8).
  static const List<BoxShadow> glassShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x66000000),
      blurRadius: 16,
      offset: Offset(0, 8),
    ),
  ];

  /// Depth shadow under album covers (black @ 35%, blur 18, y 8, spread -2).
  static const List<BoxShadow> albumShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x59000000),
      blurRadius: 18,
      offset: Offset(0, 8),
      spreadRadius: -2,
    ),
  ];
}
