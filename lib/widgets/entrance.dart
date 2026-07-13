import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// Shared **「向下展开」entrance** animations for every list/collection in the app.
///
/// The one canonical motion: each item slides DOWN into place from a small
/// negative-Y offset (i.e. drops in from just above its resting spot) while
/// fading in — never a horizontal fly-in. Timing/curve are the app's existing
/// [AppMotion.standard] (240ms) + [AppMotion.enter] (easeOutCubic), so it reads
/// as part of the same system as the queue-panel slide and the route transition.
///
/// Three entry points:
///  * [DownwardReveal] — a whole static, non-virtualised group (settings
///    sections, account cards, source/method chips, grids, dialog option lists).
///    Lays its children out as a Column or Wrap and staggers them top-to-bottom.
///  * [DownwardRevealItem] — one row of a `ListView.builder`, staggered by its
///    `index` (wrap only the FIRST-screen rows; pass `enabled: false` past the
///    fold so scrolling never replays the reveal).
///  * [dkVerticalMenuTransition] — a `transitionBuilder` for dropdown/popup
///    menus: fade + vertical [SizeTransition] pulling open from the top edge,
///    replacing the old scale-from-corner pop.
///
/// All three play **once, on first mount**, and never on rebuild/scroll/hover.

/// Per-item stagger step. 45ms reads as a clear cascade without dragging.
const Duration _kStagger = Duration(milliseconds: 45);

/// Cap on how many items get their own stagger slot — beyond this every later
/// item shares the last slot's timing, so a long group never has an
/// uncomfortably long tail (total ≤ 240 + 45×8 ≈ 600ms).
const int _kMaxStaggered = 8;

/// Default drop distance as a fraction of each item's own height (negative Y →
/// starts above its rest position). 0.06 is a gentle "settle", not a page slide.
const double _kSlide = 0.06;

/// Builds the [Interval] for item [i] inside a controller whose total duration is
/// `base + stagger × min(count-1, maxStaggered)` — item i eases over [base] ms
/// starting at its staggered offset.
Interval _slotFor(int i, int count, Duration base, Duration stagger, int maxStg) {
  final int slot = i < maxStg ? i : maxStg;
  final int totalMs = base.inMilliseconds + stagger.inMilliseconds * (count - 1 > maxStg ? maxStg : (count - 1 < 0 ? 0 : count - 1));
  final int startMs = stagger.inMilliseconds * slot;
  final double begin = totalMs == 0 ? 0 : (startMs / totalMs).clamp(0.0, 1.0);
  final double end =
      totalMs == 0 ? 1 : ((startMs + base.inMilliseconds) / totalMs).clamp(0.0, 1.0);
  return Interval(begin, end, curve: AppMotion.enter);
}

/// A staggered "drop-in from above + fade" for a whole static group.
class DownwardReveal extends StatefulWidget {
  const DownwardReveal({
    super.key,
    required this.children,
    this.wrap = false,
    this.spacing = 0,
    this.runSpacing = 0,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    this.mainAxisSize = MainAxisSize.min,
    this.wrapAlignment = WrapAlignment.start,
    this.duration = AppMotion.standard,
    this.stagger = _kStagger,
    this.maxStaggered = _kMaxStaggered,
    this.slide = _kSlide,
    this.enabled = true,
  });

  final List<Widget> children;

  /// Lay children out with a [Wrap] (chips / card grids) instead of a [Column].
  final bool wrap;
  final double spacing;
  final double runSpacing;
  final CrossAxisAlignment crossAxisAlignment;
  final MainAxisSize mainAxisSize;
  final WrapAlignment wrapAlignment;
  final Duration duration;
  final Duration stagger;
  final int maxStaggered;
  final double slide;

  /// When false, lays the children out with NO animation (identical geometry) —
  /// for reduced-motion or to disable the effect at a call site.
  final bool enabled;

  @override
  State<DownwardReveal> createState() => _DownwardRevealState();
}

class _DownwardRevealState extends State<DownwardReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    final int extra = widget.children.length - 1;
    final int slots = extra < 0 ? 0 : (extra > widget.maxStaggered ? widget.maxStaggered : extra);
    _c = AnimationController(
      vsync: this,
      duration: widget.duration + widget.stagger * slots,
    );
    if (widget.enabled) {
      _c.forward();
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _wrapChild(int i, Widget child) {
    if (!widget.enabled) return child;
    final Animation<double> a = CurvedAnimation(
      parent: _c,
      curve: _slotFor(i, widget.children.length, widget.duration, widget.stagger,
          widget.maxStaggered),
    );
    return SlideTransition(
      position: Tween<Offset>(begin: Offset(0, -widget.slide), end: Offset.zero)
          .animate(a),
      child: FadeTransition(opacity: a, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> wrapped = <Widget>[
      for (int i = 0; i < widget.children.length; i++)
        _wrapChild(i, widget.children[i]),
    ];
    if (widget.wrap) {
      return Wrap(
        spacing: widget.spacing,
        runSpacing: widget.runSpacing,
        alignment: widget.wrapAlignment,
        children: wrapped,
      );
    }
    // Column: interleave the (un-animated) spacing boxes.
    final List<Widget> col = <Widget>[];
    for (int i = 0; i < wrapped.length; i++) {
      if (i > 0 && widget.spacing > 0) {
        col.add(SizedBox(height: widget.spacing));
      }
      col.add(wrapped[i]);
    }
    return Column(
      mainAxisSize: widget.mainAxisSize,
      crossAxisAlignment: widget.crossAxisAlignment,
      children: col,
    );
  }
}

/// A single `ListView.builder` row's drop-in, staggered by its [index]. Wrap only
/// the first-screen rows and pass `enabled: false` for rows past the fold so a
/// scroll never replays the reveal (a builder recycles elements as you scroll).
class DownwardRevealItem extends StatefulWidget {
  const DownwardRevealItem({
    super.key,
    required this.index,
    required this.child,
    this.maxStaggered = _kMaxStaggered,
    this.duration = AppMotion.standard,
    this.stagger = _kStagger,
    this.slide = _kSlide,
    this.enabled = true,
  });

  final int index;
  final Widget child;
  final int maxStaggered;
  final Duration duration;
  final Duration stagger;
  final double slide;
  final bool enabled;

  @override
  State<DownwardRevealItem> createState() => _DownwardRevealItemState();
}

class _DownwardRevealItemState extends State<DownwardRevealItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _a =
      CurvedAnimation(parent: _c, curve: AppMotion.enter);

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      _c.value = 1;
      return;
    }
    final int slot =
        widget.index < widget.maxStaggered ? widget.index : widget.maxStaggered;
    // Stagger the START by index; each row still eases over [duration].
    Future<void>.delayed(widget.stagger * slot, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return SlideTransition(
      position: Tween<Offset>(begin: Offset(0, -widget.slide), end: Offset.zero)
          .animate(_a),
      child: FadeTransition(opacity: _a, child: widget.child),
    );
  }
}

/// A `transitionBuilder` for dropdown / popup menus: fade + a vertical
/// [SizeTransition] that pulls the menu open DOWNWARD from its top edge (the
/// anchor sits just below the trigger), replacing a scale-from-corner pop. Use
/// it from `showGeneralDialog`'s `transitionBuilder`.
Widget dkVerticalMenuTransition(Animation<double> anim, Widget child) {
  final CurvedAnimation curved = CurvedAnimation(
    parent: anim,
    curve: AppMotion.enter,
    reverseCurve: AppMotion.exit,
  );
  return FadeTransition(
    opacity: curved,
    child: Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: SizeTransition(
        axis: Axis.vertical,
        axisAlignment: -1, // grow from the top edge downward
        sizeFactor: curved,
        child: child,
      ),
    ),
  );
}
