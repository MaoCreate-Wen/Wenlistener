import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';

/// A drag-to-dismiss full-screen sheet, shared by the `/player` and `/lyrics`
/// routes so both get identical dismiss behaviour.
///
/// The drag follows the finger; past a threshold (or a downward fling) it
/// dismisses. There are TWO exit behaviours:
///  • **drag-down / grabber tap** (下拉返回) → SUPPRESS the shared `album_art` Hero
///    and pop: a plain slide-down (the cover slides down WITH the page, no flight).
///  • **system back button** → keeps the Hero: the route's reverse slide flies the
///    cover back to its destination.
/// The distinction is the `heroSuppressed` flag the [builder] receives (true only
/// for the drag/grabber path).
///
/// [dragAnywhere] chooses WHERE the drag lives:
///  • **true** (default — the player page): a vertical drag ANYWHERE on the sheet
///    dismisses it (there is nothing else to scroll).
///  • **false** (the lyrics page): the body is left free so the lyrics can be
///    browse-scrolled, and ONLY the [SheetGrabber] (顶部小横条) drags the sheet —
///    a downward swipe over the lyrics browses them instead of returning.
/// Either way the grabber drives the SAME drag (it finds the sheet through an
/// inherited [_SheetScope]), so it works even when [dragAnywhere] is off.
///
/// Perf: the drag offset is a [ValueNotifier], NOT setState — a drag updates it
/// ~60×/s and rebuilding the whole page subtree that often is what makes the drag
/// jank ("卡手"). Only the inner [Transform] listens; the content is built ONCE per
/// build() and reused, so a drag frame just re-offsets it.
///
/// The host route must be non-opaque with a non-zero `reverseTransitionDuration`
/// + a reverse slide transition (so the back-button pop animates and flies the
/// Hero); see the `/player` and `/lyrics` routes in `app_router.dart`. That route
/// also owns the pop curve (an ease-IN reverseCurve so the dismiss leaves promptly
/// instead of dwelling near the middle).
class DismissibleSheet extends StatefulWidget {
  /// Builds the sheet content. `dismiss` runs the drag/grabber exit (suppress the
  /// Hero, then pop); `heroSuppressed` is a listenable the caller watches ON ITS
  /// COVER ONLY (via a `ValueListenableBuilder`) to drop the `album_art` Hero tag
  /// — so committing a dismiss rebuilds just the cover, never the whole page.
  final Widget Function(
    BuildContext context,
    VoidCallback dismiss,
    ValueListenable<bool> heroSuppressed,
  ) builder;

  /// The actual pop (e.g. `if (context.canPop()) context.pop()`).
  final VoidCallback onDismiss;

  /// Whether a vertical drag anywhere on the sheet dismisses it. See the class
  /// doc — true for the player, false for the lyrics page (grabber-only).
  final bool dragAnywhere;

  const DismissibleSheet({
    super.key,
    required this.builder,
    required this.onDismiss,
    this.dragAnywhere = true,
  });

  @override
  State<DismissibleSheet> createState() => _DismissibleSheetState();
}

class _DismissibleSheetState extends State<DismissibleSheet>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _dy = ValueNotifier<double>(0);
  double _from = 0;

  /// Flipped true (once) when a drag/grabber dismiss commits. A ValueNotifier so
  /// ONLY the cover — which watches it — rebuilds to drop its Hero; the rest of the
  /// page is untouched (no full-content rebuild hitch as the slide starts).
  final ValueNotifier<bool> _suppressHero = ValueNotifier<bool>(false);
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    // Eases _dy back to 0 on a sub-threshold release. A committed drag/grabber
    // dismiss instead suppresses the Hero and pops (see [_dismiss]); the route's
    // reverse slide then carries the page down. The system back button leaves
    // _suppressHero false → the Hero flies.
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        _dy.value = _from * (1 - Curves.easeOut.transform(_anim.value));
      });
  }

  void _settleBack() {
    _from = _dy.value;
    _anim
      ..reset()
      ..forward();
  }

  void _dismiss() {
    if (_suppressHero.value) return;
    _suppressHero.value = true; // rebuilds only the cover (drops its Hero)
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDismiss());
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_anim.isAnimating) _anim.stop();
    _dy.value = math.max(0, _dy.value + d.delta.dy);
  }

  void _onEnd(DragEndDetails d) {
    final double v = d.primaryVelocity ?? 0;
    if (_dy.value > 120 || v > 700) {
      _dismiss();
    } else {
      _settleBack();
    }
  }

  // Entry points the [SheetGrabber] uses (via [_SheetScope]) to drag the sheet —
  // the ONLY drag source when [DismissibleSheet.dragAnywhere] is off (lyrics page).
  void grabberDragUpdate(DragUpdateDetails d) => _onUpdate(d);
  void grabberDragEnd(DragEndDetails d) => _onEnd(d);

  @override
  void dispose() {
    _anim.dispose();
    _dy.dispose();
    _suppressHero.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Content is built ONCE and cached in a RepaintBoundary: build() never re-runs
    // for a drag (that only moves _dy) NOR for a dismiss (the Hero flag is a
    // ValueNotifier the cover watches). So the drag / settle / route-slide Transform
    // just re-offsets a CACHED layer — it never re-paints the page's blurred
    // background / mesh / lyrics per frame, which was the slide-down jank ("卡顿").
    final Widget content = RepaintBoundary(
      child: widget.builder(context, _dismiss, _suppressHero),
    );
    final Widget movable = ValueListenableBuilder<double>(
      valueListenable: _dy,
      child: content,
      builder: (BuildContext context, double dy, Widget? child) =>
          Transform.translate(offset: Offset(0, dy), child: child),
    );
    // Whole-page drag only when [dragAnywhere]; otherwise the body is free (so the
    // lyrics can browse-scroll) and the grabber alone drags, via [_SheetScope].
    final Widget body = widget.dragAnywhere
        ? GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onVerticalDragUpdate: _onUpdate,
            onVerticalDragEnd: _onEnd,
            child: movable,
          )
        : movable;
    return _SheetScope(state: this, child: body);
  }
}

/// Exposes the enclosing [_DismissibleSheetState] to a descendant [SheetGrabber]
/// so the grabber can drive the sheet's drag/dismiss even when whole-page drag is
/// off. The reference is stable for the sheet's lifetime → never notifies.
class _SheetScope extends InheritedWidget {
  final _DismissibleSheetState state;

  const _SheetScope({required this.state, required super.child});

  static _DismissibleSheetState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SheetScope>()?.state;

  @override
  bool updateShouldNotify(_SheetScope oldWidget) => false;
}

/// The centred grabber pill at the top of a [DismissibleSheet]. Tap it — or drag
/// it down — to dismiss. The drag is forwarded to the sheet via [_SheetScope], so
/// it returns to the previous page even on a sheet whose body doesn't itself
/// dismiss (the lyrics page: "按住顶部小横条下拉返回").
class SheetGrabber extends StatelessWidget {
  final VoidCallback onTap;

  const SheetGrabber({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final _DismissibleSheetState? sheet = _SheetScope.maybeOf(context);
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onVerticalDragUpdate: sheet?.grabberDragUpdate,
        onVerticalDragEnd: sheet?.grabberDragEnd,
        // A wide, tall invisible hit area around the little pill so it's an easy
        // grab target to pull the whole page down — without covering the header.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 80),
          child: Container(
            width: 40,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.30),
              borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            ),
          ),
        ),
      ),
    );
  }
}
