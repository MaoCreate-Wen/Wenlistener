import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import '../models/image_url.dart';
import '../theme/app_colors.dart';
import 'resource_cache.dart';

/// Decode dimension for cover ANALYSIS consumers (palette quantization here,
/// the 32² mesh-gradient texture in `NeonFlowBackground`). Both sample colour
/// statistics, not pixels-for-display, so a 128² decode is lossless for their
/// purposes while replacing the native-resolution decode (25-36 MB RGBA for a
/// typical Netease cover) with a ~64 KB cache entry. Shared so both consumers
/// construct an IDENTICAL ResizeImage provider — equal key ⇒ one decode.
const int kCoverAnalysisDecodeDim = 128;

/// Result of extracting a dynamic palette from album art.
class PaletteResult {
  /// Dominant vibrant accent (drives progress bar, nav pill, glow, etc.).
  final Color accent;

  /// Mid-value swatches sorted by descending saturation.
  final List<Color> colors;

  /// Two-stop wash gradient derived from [colors].
  final Gradient gradient;

  const PaletteResult({
    required this.accent,
    required this.colors,
    required this.gradient,
  });

  /// Brand seed fallback (no art / extraction failed).
  static const PaletteResult fallback = PaletteResult(
    accent: AppColors.seed,
    colors: <Color>[AppColors.seed, AppColors.seedDeep],
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[AppColors.seed, AppColors.seedDeep],
    ),
  );
}

/// Extracts a [PaletteResult] from album art, reusing the legacy
/// `computeImageColors` filtering logic.
///
/// The expensive median-cut quantization is moved OFF the UI isolate via
/// [compute] (only the unavoidable `dart:ui` image *decode* has to stay on the
/// root isolate), and successful results are memoised in [_cache] keyed by URL.
/// Switching back to a previously-seen cover therefore returns instantly with
/// no recompute, and a first-time extraction no longer burns a synchronous
/// quantize on the main thread — the #1 cause of queue-switch jank.
class ArtworkPalette {
  const ArtworkPalette();

  /// URL-keyed memo of successfully extracted palettes. Static so it is shared
  /// across the (cheap, `const`) [ArtworkPalette] instances and survives queue
  /// churn. A plain [Map] keeps insertion order, so eviction can drop the
  /// oldest entry once [_maxCacheEntries] is exceeded.
  static final Map<String, PaletteResult> _cache = <String, PaletteResult>{};

  /// Upper bound on [_cache]; the oldest entry is evicted past this.
  static const int _maxCacheEntries = 64;

  Future<PaletteResult> extract(String? url) async {
    if (url == null || url.isEmpty) return PaletteResult.fallback;

    final PaletteResult? cached = _cache[url];
    if (cached != null) return cached;

    try {
      // The image *decode* must run on the root isolate (`dart:ui`), so resolve
      // and rasterize the cover here, then hand the raw RGBA bytes off-thread.
      //
      // Decode at a SMALL fixed target ([kCoverAnalysisDecodeDim]², via
      // ResizeImage) — median-cut palette quality is insensitive to resolution,
      // but the raw provider decoded the cover at its native size (Netease art
      // is routinely 2000-3000px ⇒ a 25-36 MB RGBA imageCache entry PER TRACK,
      // measured as the dominant driver of the 400-500 MB lyrics-page working
      // set). The 128² entry is ~64 KB and quantizes ~16k pixels instead of
      // ~6M on the background isolate. The construction matches the mesh
      // texture builder's exactly, so both resolve ONE shared cache entry.
      final ui.Image image = await _resolveCoverImage(
        ResizeImage.resizeIfNeeded(
          kCoverAnalysisDecodeDim,
          kCoverAnalysisDecodeDim,
          DiskCachedImage(url, headers: kNeteaseImageHeaders),
        ),
      );
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return PaletteResult.fallback;

      // Median-cut quantize on a background isolate. fromByteData is documented
      // isolate-safe (it never touches `dart:ui`), and PaletteGenerator/
      // PaletteColor/PaletteTarget all use value equality, so the result safely
      // copies back across the isolate boundary (vibrant/dominant lookups still
      // resolve after the round trip).
      final PaletteGenerator gen = await compute(
        _quantizePalette,
        EncodedImage(bytes, width: image.width, height: image.height),
      );

      // ---- map PaletteGenerator -> PaletteResult (derivation unchanged) ----
      List<Color> colors = await computeImageColors(gen);
      if (colors.isEmpty) {
        final Color? fb = gen.vibrantColor?.color ?? gen.dominantColor?.color;
        if (fb == null) return PaletteResult.fallback;
        colors = <Color>[fb, AppColors.seedDeep];
      }
      // Keep the true dominant as the accent, then (only for covers dominated by a
      // single hue) append synthetic depth colours so the mesh-gradient background
      // has more than one hue to flow between — see [_enrichForDepth]. Colourful
      // covers pass through unchanged, and the dominant stays at index 0.
      final Color accent = colors.first;
      final List<Color> enriched = _enrichForDepth(colors);
      final PaletteResult result = PaletteResult(
        accent: accent,
        colors: enriched,
        gradient: _gradientOf(enriched),
      );
      _store(url, result);
      return result;
    } catch (e) {
      // Any failure (decode error, timeout, empty bytes, isolate error) must
      // degrade gracefully — never throw, or it would crash the song switch.
      debugPrint('ArtworkPalette.extract failed: $e');
      return PaletteResult.fallback;
    }
  }

  /// Stores [result] for [url], evicting the oldest entry when the cache is
  /// full. Only successful extractions are cached — failures fall through to
  /// [PaletteResult.fallback] uncached, so a transient decode/network error can
  /// recover on the next switch instead of permanently poisoning the URL.
  static void _store(String url, PaletteResult result) {
    if (_cache.length >= _maxCacheEntries && !_cache.containsKey(url)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[url] = result;
  }
}

/// Quantizes an already-decoded RGBA frame into a [PaletteGenerator].
///
/// Top-level so it can be the entry point of a background isolate via [compute].
/// Mirrors the old `fromImageProvider` call (`maximumColorCount: 16`, default
/// filters/targets) so the produced palette — and therefore the derived
/// [PaletteResult] — is identical to before, just computed off the UI thread.
Future<PaletteGenerator> _quantizePalette(EncodedImage encoded) {
  return PaletteGenerator.fromByteData(encoded, maximumColorCount: 16);
}

/// Resolves [provider] to a decoded [ui.Image] on the current (root) isolate,
/// applying the same `Size(100, 100)` configuration the old
/// `PaletteGenerator.fromImageProvider` used. Rejects on decode error or after
/// [timeout] so a stuck or broken cover can never hang a song switch (callers
/// then fall back to [PaletteResult.fallback]).
Future<ui.Image> _resolveCoverImage(
  ImageProvider provider, {
  Duration timeout = const Duration(seconds: 15),
}) {
  final ImageStream stream = provider.resolve(
    const ImageConfiguration(size: Size(100, 100), devicePixelRatio: 1.0),
  );
  final Completer<ui.Image> completer = Completer<ui.Image>();
  Timer? timeoutTimer;
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      timeoutTimer?.cancel();
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete(info.image);
    },
    onError: (Object error, StackTrace? stackTrace) {
      timeoutTimer?.cancel();
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  );
  if (timeout != Duration.zero) {
    timeoutTimer = Timer(timeout, () {
      stream.removeListener(listener);
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Timeout loading cover for palette extraction'),
        );
      }
    });
  }
  stream.addListener(listener);
  return completer.future;
}

/// A soft vertical wash derived from the dominant swatch. Rather than butting
/// two unrelated swatches together (which shows a hard diagonal seam), we build
/// a tonally-coherent ramp — dominant, a related deep stop, and lightened /
/// darkened derivations — so the wash reads as one smooth field, like the
/// AMLL mesh that ultimately replaces it.
Gradient _gradientOf(List<Color> colors) {
  final Color base = colors.first;
  final Color second =
      colors.length > 1 ? colors[1] : _shiftLightness(base, -0.16);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      _shiftLightness(base, 0.06),
      base,
      second,
      _shiftLightness(second, -0.22),
    ],
    stops: const <double>[0.0, 0.4, 0.72, 1.0],
  );
}

/// Lightens (positive) / darkens (negative) [c] by [amount] in HSL lightness.
Color _shiftLightness(Color c, double amount) {
  final HSLColor h = HSLColor.fromColor(c);
  return h.withLightness((h.lightness + amount).clamp(0.0, 1.0)).toColor();
}

/// Synthesises tonally-related "depth" colours around a [dominant] swatch — an
/// analogous pair (±~28° hue) and a soft split-complementary accent (+150°), each
/// only gently nudged in saturation/lightness. Gives the mesh-gradient background
/// (and the wash) extra hues to interpolate when a cover is essentially one colour.
/// Subtle by design — depth, not neon.
List<Color> synthesizeDepthColors(Color dominant) {
  final HSLColor base = HSLColor.fromColor(dominant);
  final double s = base.saturation;
  final double l = base.lightness;
  Color shift(double dHue, double dSat, double dLight) => base
      .withHue((base.hue + dHue) % 360.0)
      .withSaturation((s + dSat).clamp(0.0, 1.0))
      .withLightness((l + dLight).clamp(0.0, 1.0))
      .toColor();
  return <Color>[
    shift(-28, 0.10, 0.05), // cooler analogous, a touch brighter
    shift(28, 0.06, -0.05), // warmer analogous, a touch deeper
    shift(150, -0.05, 0.0), // soft split-complementary accent
  ];
}

/// Appends [synthesizeDepthColors] to a palette dominated by a single hue (see
/// [_isLowVariancePalette]) so the mesh background has more colour to flow between;
/// returns [colors] untouched for palettes that already vary. The dominant stays at
/// index 0 (callers treat `colors.first` as the accent, and the wash uses the first
/// two stops — both preserved).
List<Color> _enrichForDepth(List<Color> colors) {
  if (colors.isEmpty || !_isLowVariancePalette(colors)) return colors;
  return <Color>[...colors, ...synthesizeDepthColors(colors.first)];
}

/// True when [colors] is dominated by a single hue — i.e. fewer than two distinct,
/// reasonably-saturated hues. These are the covers whose mesh background looks
/// flat/monotonous and benefit from synthetic depth colours.
bool _isLowVariancePalette(List<Color> colors) {
  if (colors.length < 2) return true;
  final double baseHue = HSLColor.fromColor(colors.first).hue;
  double maxHueDist = 0;
  for (final Color c in colors) {
    final HSLColor h = HSLColor.fromColor(c);
    if (h.saturation < 0.12) continue; // greys aren't a distinct hue
    final double d = _hueDistance(h.hue, baseHue);
    if (d > maxHueDist) maxHueDist = d;
  }
  return maxHueDist < 28.0;
}

/// Shortest distance between two hues (degrees, 0..180).
double _hueDistance(double a, double b) {
  final double d = (a - b).abs() % 360.0;
  return d > 180.0 ? 360.0 - d : d;
}

/// Ported from legacy `lib/lyrics.dart`: keep only mid-value swatches
/// (0.3 < HSV value < 0.7), then sort by descending saturation.
Future<List<Color>> computeImageColors(PaletteGenerator generator) async {
  final List<({int index, double saturation})> sortColors =
      <({int index, double saturation})>[];
  for (int index = 0; index < generator.paletteColors.length; index++) {
    final Color current = generator.paletteColors[index].color;
    final double value = HSVColor.fromColor(current).value;
    if (value < 0.3 || value > 0.7) continue;
    sortColors.add(
      (index: index, saturation: HSVColor.fromColor(current).saturation),
    );
  }
  sortColors.sort((a, b) => b.saturation.compareTo(a.saturation));
  return <Color>[
    for (final ({int index, double saturation}) e in sortColors)
      generator.paletteColors[e.index].color,
  ];
}
