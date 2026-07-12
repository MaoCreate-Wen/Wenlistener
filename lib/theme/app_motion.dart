import 'package:flutter/animation.dart';

/// Motion tokens for the desktop UI *chrome* (sidebar collapse, mini→full player,
/// player→lyrics, hover/press). The lyric/player springs are consumed unchanged
/// from `lib/animation` (AMLL) — never re-tuned here (DESKTOP_UI_PLAN §1.4).
class AppMotion {
  AppMotion._();

  /// Micro-interactions (hover tint, press).
  static const Duration fast = Duration(milliseconds: 160);

  /// Standard enter/exit for panels and page chrome.
  static const Duration standard = Duration(milliseconds: 240);

  /// Sheet push/pop (player, lyrics).
  static const Duration sheet = Duration(milliseconds: 320);

  /// Wash cross-fade on song change.
  static const Duration wash = Duration(milliseconds: 600);

  /// Ease-out enter.
  static const Curve enter = Curves.easeOutCubic;

  /// Ease-in exit.
  static const Curve exit = Curves.easeInCubic;

  /// Slight overshoot for slider swell / press bounce (AMLL BouncingSlider feel).
  static const Curve emphasized = Cubic(0.38, 1.625, 0.62, 0.995);
}
