import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Per-line replacement for the old PAGE-level edge-fade `ShaderMask`.
///
/// The `/lyrics` page used to wrap the ENTIRE lyric column in one
/// `ShaderMask(dstIn)` — a full-window `saveLayer` re-composited every frame
/// (the single biggest constant raster cost of the page). The fade itself only
/// touches two thin bands (top/bottom ~14% of the view), and only the LINES
/// whose pixels reach into those bands actually need masking, so this widget
/// applies the *same* view-anchored vertical gradient per line instead:
///
///  • Lines fully inside the opaque middle (the overwhelming majority) paint
///    straight through — **no layer at all** (`_inBand == false` short-circuits
///    to a plain `paintChild`), and the cached `StaticLyricLine` boundaries
///    behind them stay reference-identical, exactly as before.
///  • A line whose painted extent (layout box inflated by [overflowMargin] for
///    glow/blur/float overflow) intersects a fade band gets a [ShaderMaskLayer]
///    whose `maskRect` is just that inflated LINE rect — the engine's
///    `saveLayer` is then line-sized, not window-sized.
///
/// Pixel parity: `dstIn` multiplies each destination pixel's alpha by the
/// gradient sampled at that pixel's VIEW-space y. Whether that multiply happens
/// inside one whole-view layer or inside per-line layers, the factor at every
/// pixel is identical (lines don't overlap; their sub-percent blur-fringe
/// overlaps differ only in second-order alpha terms far below one 8-bit step).
/// The gradient here is expressed in the line's local frame but spans exactly
/// [viewHeight] with the same 4 stops the page mask used, so the sampled values
/// match the old full-view `LinearGradient` bit-for-bit.
///
/// The widget is rebuilt every frame by the lyric view's per-frame shell (like
/// the `Positioned`/`Transform.scale` wrappers around cached lines); when its
/// geometry is unchanged (settled lines) [RenderLineEdgeFade.update] no-ops, so
/// an idle frame stays idle.
class LineEdgeFade extends SingleChildRenderObjectWidget {
  const LineEdgeFade({
    super.key,
    required this.lineTop,
    required this.viewHeight,
    required this.topFadePx,
    required this.bottomFadePx,
    required this.overflowMargin,
    required Widget super.child,
  });

  /// This line's top edge in lyric-view coordinates (its `Positioned.top`, the
  /// controller's `render.y`). Anchors the view-space gradient in local space.
  final double lineTop;

  /// Height of the lyric viewport the fade stops are fractions of.
  final double viewHeight;

  /// Height in px of the top / bottom fade bands (0 disables that band).
  final double topFadePx;
  final double bottomFadePx;

  /// How far outside the line's layout box its painting can reach (glow halos,
  /// gaussian blur tails, float rise, edge-ring shadows). Used both for the
  /// "does this line touch a band" test and to inflate the mask rect so every
  /// overflowing pixel is still multiplied by the gradient, exactly as the
  /// whole-view mask did.
  final double overflowMargin;

  @override
  RenderLineEdgeFade createRenderObject(BuildContext context) =>
      RenderLineEdgeFade(
        lineTop: lineTop,
        viewHeight: viewHeight,
        topFadePx: topFadePx,
        bottomFadePx: bottomFadePx,
        overflowMargin: overflowMargin,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLineEdgeFade renderObject,
  ) {
    renderObject.update(
      lineTop: lineTop,
      viewHeight: viewHeight,
      topFadePx: topFadePx,
      bottomFadePx: bottomFadePx,
      overflowMargin: overflowMargin,
    );
  }
}

class RenderLineEdgeFade extends RenderProxyBox {
  RenderLineEdgeFade({
    required double lineTop,
    required double viewHeight,
    required double topFadePx,
    required double bottomFadePx,
    required double overflowMargin,
  })  : _lineTop = lineTop,
        _viewHeight = viewHeight,
        _topFadePx = topFadePx,
        _bottomFadePx = bottomFadePx,
        _overflowMargin = overflowMargin;

  double _lineTop;
  double _viewHeight;
  double _topFadePx;
  double _bottomFadePx;
  double _overflowMargin;

  /// Whether the line's (inflated) painted extent currently reaches a fade
  /// band — i.e. whether painting needs the mask layer at all.
  bool _inBand = false;

  @override
  bool get alwaysNeedsCompositing => _inBand;

  /// Batch setter from [LineEdgeFade.updateRenderObject]: no-ops when nothing
  /// changed (settled lines rebuild the shell every frame with identical
  /// values), otherwise re-derives [_inBand] and invalidates only what the
  /// change actually affects.
  void update({
    required double lineTop,
    required double viewHeight,
    required double topFadePx,
    required double bottomFadePx,
    required double overflowMargin,
  }) {
    if (lineTop == _lineTop &&
        viewHeight == _viewHeight &&
        topFadePx == _topFadePx &&
        bottomFadePx == _bottomFadePx &&
        overflowMargin == _overflowMargin) {
      return;
    }
    _lineTop = lineTop;
    _viewHeight = viewHeight;
    _topFadePx = topFadePx;
    _bottomFadePx = bottomFadePx;
    _overflowMargin = overflowMargin;
    _refreshBandState();
  }

  bool _computeInBand() {
    if (!hasSize) return false;
    if (_topFadePx <= 0 && _bottomFadePx <= 0) return false;
    final double top = _lineTop - _overflowMargin;
    final double bottom = _lineTop + size.height + _overflowMargin;
    return top < _topFadePx || bottom > _viewHeight - _bottomFadePx;
  }

  void _refreshBandState() {
    final bool inBand = _computeInBand();
    if (inBand != _inBand) {
      _inBand = inBand;
      // The layer structure changes (mask layer added/dropped).
      markNeedsCompositingBitsUpdate();
      markNeedsPaint();
    } else if (inBand) {
      // Still masked but the geometry moved → the gradient anchoring (and the
      // mask rect) changed, so the layer must be refreshed.
      markNeedsPaint();
    }
    // Out-of-band geometry motion needs no repaint from us: painting is a plain
    // pass-through whose output doesn't depend on these fields.
  }

  @override
  void performLayout() {
    super.performLayout();
    // The band test needs `size`, which may have just changed.
    _refreshBandState();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (!_inBand) {
      layer = null;
      super.paint(context, offset);
      return;
    }

    // saveLayer bounds = this LINE (inflated for paint overflow), not the view.
    final Rect mask = Rect.fromLTRB(
      offset.dx - _overflowMargin,
      offset.dy - _overflowMargin,
      offset.dx + size.width + _overflowMargin,
      offset.dy + size.height + _overflowMargin,
    );

    // The engine evaluates the mask shader relative to maskRect's top-left, so
    // express the view-spanning gradient there: view y = 0 sits at local
    // -lineTop, i.e. at overflowMargin - lineTop below the mask origin.
    final double viewTopY = _overflowMargin - _lineTop;
    final double h = _viewHeight <= 0 ? 1 : _viewHeight;
    final double topStop = (_topFadePx / h).clamp(0.0, 1.0);
    final double bottomStop =
        (1.0 - _bottomFadePx / h).clamp(topStop, 1.0);
    // Identical colors/stops to the old page-level LinearGradient — only the
    // coordinate frame differs.
    final ui.Shader shader = ui.Gradient.linear(
      Offset(mask.width / 2, viewTopY),
      Offset(mask.width / 2, viewTopY + h),
      const <Color>[
        Color(0x00000000), // Colors.transparent
        Color(0xFFFFFFFF), // Colors.white
        Color(0xFFFFFFFF),
        Color(0x00000000),
      ],
      <double>[0.0, topStop, bottomStop, 1.0],
    );

    final ShaderMaskLayer maskLayer =
        (layer as ShaderMaskLayer?) ?? ShaderMaskLayer();
    maskLayer
      ..shader = shader
      ..maskRect = mask
      ..blendMode = BlendMode.dstIn;
    layer = maskLayer;
    context.pushLayer(maskLayer, super.paint, offset);
  }
}
