import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../models/image_url.dart';
import '../theme/app_colors.dart';

/// The album-art background for the player page.
///
/// The recipe is deliberately simple and uncoloured:
///  1. the album cover is decoded DOWN to a small [_kBlockRes]² grid
///     ("缩略成比较小的块") so only its coarse colours remain, filled via
///     [BoxFit.cover] with a slight [_baseZoom] for drift headroom,
///  2. a Gaussian blur ([ui.ImageFilter.blur], sigma ≈ [_blurSigma]) melts those
///     blocks into a soft colour field, and
///  3. a vertical scrim holds it understated (darker at the status bar / controls).
///
/// There is **no** saturation/brightness colour-grading. A very subtle slow drift
/// (gentle pan + breathe) keeps it alive without drawing attention.
///
/// Performance: the expensive blur is rendered once into a cached
/// [RepaintBoundary]; only a cheap outer [Transform] animates each frame, so the
/// full-screen blur is never recomputed per frame.
///
/// When [imageUrl] is null/empty the widget falls back to a gradient built from
/// [paletteColors] (or the brand seed colours when no palette is available).
class ArtBackground extends StatefulWidget {
  final String? imageUrl;
  final List<Color> paletteColors;
  final double flowSpeed;

  const ArtBackground({
    super.key,
    required this.imageUrl,
    this.paletteColors = const <Color>[],
    this.flowSpeed = 4,
  });

  @override
  State<ArtBackground> createState() => _ArtBackgroundState();
}

class _ArtBackgroundState extends State<ArtBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _time = ValueNotifier<double>(0);
  Duration _last = Duration.zero;

  /// Base zoom into the downscaled cover — just enough headroom for the drift's
  /// pan/scale to never expose an edge (the low-res source is the whole colour
  /// field now, not a zoomed-in slice, so we don't need the old 2.0×).
  static const double _baseZoom = 1.2;

  /// Side length the cover is decoded down to first ("缩略成小块") — a low-res
  /// colour grid whose blocks the blur then softens into a smooth field.
  static const int _kBlockRes = 32;

  /// Gaussian blur radius applied AFTER the downscale, so the small blocks melt
  /// into a soft colour field (not so heavy it flattens to one colour).
  static const double _blurSigma = 40;

  @override
  void initState() {
    super.initState();
    // The ticker exists only to drive the drift of a blurred COVER. The
    // no-image fallback (_paletteWash) is a static gradient, so ticking there
    // would schedule a redundant frame every vsync forever. Run the ticker only
    // while a cover is shown (createTicker is also TickerMode-aware, so an
    // offstage route mutes it automatically).
    _ticker = createTicker(_onTick);
    _syncTicker();
  }

  @override
  void didUpdateWidget(ArtBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) _syncTicker();
  }

  void _syncTicker() {
    final bool needsDrift =
        widget.imageUrl != null && widget.imageUrl!.isNotEmpty;
    if (needsDrift && !_ticker.isActive) {
      _last = Duration.zero; // elapsed restarts at zero on start()
      _ticker.start();
    } else if (!needsDrift && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final double dt =
        _last == Duration.zero ? 0 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _time.value += dt;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 700),
        switchInCurve: Curves.easeInOut,
        switchOutCurve: Curves.easeInOut,
        layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
          fit: StackFit.expand,
          children: <Widget>[...previous, if (current != null) current],
        ),
        child: KeyedSubtree(
          key: ValueKey<String?>(widget.imageUrl),
          child: _content(),
        ),
      ),
    );
  }

  Widget _content() {
    final String? url = widget.imageUrl;
    if (url == null || url.isEmpty) return _paletteWash();
    // Netease CDN gates on a browser UA + Referer; without these headers it
    // returns 403 and the cover silently falls back to a placeholder.
    final ImageProvider image =
        CachedNetworkImageProvider(url, headers: kNeteaseImageHeaders);
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Neutral base so there is never a transparent flash before the
          // blurred cover paints. Pure black — no colour-grading.
          const ColoredBox(color: AppColors.bg),
          // 1 + 2. the cover at BoxFit.cover, zoomed 2.0× and heavily blurred,
          // with a very subtle slow drift.
          _flow(image),
          // 3. a vertical scrim instead of a flat mask: darker at the top (status
          //    bar) and bottom (transport controls), lighter through the middle
          //    where the artwork sits — the warm top-to-deep gradient of the
          //    reference player, and better legibility where the text/controls are.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0x66000000),
                  Color(0x26000000),
                  Color(0x33000000),
                  Color(0x80000000),
                ],
                stops: <double>[0.0, 0.32, 0.62, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The frosted cover. The zoomed, blurred image is built **once** (cached in a
  /// [RepaintBoundary]); the outer [Transform] applies only a cheap, subtle
  /// pan/breathe each frame so the full-screen blur is never recomputed.
  Widget _flow(ImageProvider image) {
    final Widget frosted = RepaintBoundary(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: _blurSigma,
          sigmaY: _blurSigma,
          tileMode: TileMode.clamp,
        ),
        child: Transform.scale(
          scale: _baseZoom,
          child: SizedBox.expand(
            child: Image(
              // Decode the cover down to a small [_kBlockRes]² grid first
              // ("缩略成小块"); the bilinear upscale + the blur below turn it into a
              // soft colour field instead of a recognisable zoomed cover slice.
              image: ResizeImage(image,
                  width: _kBlockRes, height: _kBlockRes, allowUpscaling: false),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
              errorBuilder: (BuildContext context, Object _, StackTrace? __) =>
                  _paletteWash(),
            ),
          ),
        ),
      ),
    );

    return ValueListenableBuilder<double>(
      valueListenable: _time,
      child: frosted,
      builder: (BuildContext context, double t, Widget? child) {
        // VERY subtle: a slow breathe (~±2%) plus a gentle pan (~±2.5% of the
        // viewport). The 2.0× base zoom absorbs this with edge headroom to spare.
        final double phase = t * 0.05 * widget.flowSpeed;
        final double scale = 1.0 + 0.04 * (0.5 + 0.5 * math.sin(phase * 0.7));
        final double dx = 0.025 * math.sin(phase);
        final double dy = 0.025 * math.cos(phase * 0.83);
        return Transform.scale(
          scale: scale,
          child: FractionalTranslation(
            translation: Offset(dx, dy),
            child: child,
          ),
        );
      },
    );
  }

  /// Fallback gradient from the extracted [paletteColors] (or the brand seed
  /// colours when empty). Used when there is no cover image, and as the
  /// error fallback if a cover fails to load.
  Widget _paletteWash() {
    final List<Color> p = widget.paletteColors;
    final Color base = p.isNotEmpty ? p[0] : AppColors.seed;
    final Color second = p.length > 1 ? p[1] : _shiftLightness(base, -0.16);
    // A soft, tonally-coherent vertical ramp (see ArtworkPalette) instead of two
    // unrelated swatches meeting on the diagonal — no hard seam before the cover
    // decodes.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            _shiftLightness(base, 0.06),
            base,
            second,
            _shiftLightness(second, -0.22),
          ],
          stops: const <double>[0.0, 0.4, 0.72, 1.0],
        ),
      ),
    );
  }
}

/// Lightens (positive) / darkens (negative) [c] by [amount] in HSL lightness.
Color _shiftLightness(Color c, double amount) {
  final HSLColor h = HSLColor.fromColor(c);
  return h.withLightness((h.lightness + amount).clamp(0.0, 1.0)).toColor();
}
