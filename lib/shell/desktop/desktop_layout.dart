import 'package:flutter/foundation.dart';

/// Single source of truth for the desktop-vs-mobile shell decision.
///
/// On Android [isDesktopPlatform] is compile-reachable-but-always-false at
/// runtime, so [active] short-circuits and the existing mobile shell renders
/// untouched. Uses [defaultTargetPlatform] (+ [kIsWeb]) so it needs no
/// `dart:io` import and is safe on web.
class DesktopLayout {
  DesktopLayout._();

  /// Width below which even a desktop window falls back to the mobile shell
  /// (e.g. a very narrow / snapped window). Matches the DESIGN_SPEC min width.
  static const double breakpoint = 900;

  /// True on a desktop OS only (never web, never Android/iOS).
  static bool get isDesktopPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Render the desktop shell? Desktop OS AND wide enough. Always false on
  /// Android → the existing mobile shell path is never perturbed.
  static bool active(double width) => isDesktopPlatform && width >= breakpoint;
}
