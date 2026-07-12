import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Side length the album cover is reduced to before colour-grading + blurring.
/// AMLL uses a 32×32 `reduceImageSizeCanvas`; we keep that exactly.
const int kAlbumTexSize = 32;

/// Box-blur radius over the 32² texture — AMLL's `2`, kept exactly (radius 1 would
/// pixellate this tiny texture once it is magnified across the whole screen).
const int _kBlurRadius = 2;

/// Box-blur passes over the 32² texture. **AMLL ships 4** (`blurImage(…, 2, 4)`);
/// we run **2** on purpose. PROJECT MEMORY: the pass-count is the vibrant-vs-flat
/// knob — *fewer passes = sharper colour regions = more visible flow* (12 collapsed
/// every cover to a flat wash; 4 = AMLL; 3 was intermediate; 2 keeps the cover's
/// colour regions crisper so the warped mesh reads as clearly *flowing* bands on the
/// lyrics page). Radius stays 2 (see [_kBlurRadius]); the screen-filling softness
/// still comes for free from bilinear magnification of this 32² texture — so even at
/// 2 passes the field is smooth, just with more defined bands. Don't drop below ~2 or
/// the 32² region seams start to read as blocky after magnification.
const int _kBlurPasses = 2;

/// Per-channel mean-absolute-deviation (0..255, measured on the colour-graded 32²
/// texture) at/above which a cover counts as "varied enough" to need no synthetic
/// colour depth — those covers stay byte-for-byte AMLL-faithful. Below it the blend
/// ramps up so near-monochrome covers gain a gentle hue field to flow. Widened from
/// 24 so "somewhat-monochrome" covers (the ones prone to one warped patch filling
/// the screen) also get a little depth to break up.
const double _kDepthVarFull = 28.0;

/// Max blend fraction of the synthetic hue field into a fully-monochrome cover.
/// Luma-preserving on purpose: the cover keeps its brightness/identity, it just
/// gains depth (not a repaint). Lifted a little (0.40 → 0.46) so a one-colour cover
/// fills the field with more hue variety (fewer screen-filling single-colour blocks).
const double _kDepthMaxStrength = 0.46;

/// Spatial frequency (full cycles across the 32² texture) of the synthetic hue
/// field. The original field was ~1 diagonal cycle → one big colour region that,
/// once warped, could fill most of the lyrics screen for a near-monochrome cover.
/// Raising it to a few cycles breaks the field into smaller, more numerous regions
/// so no single hue dominates; kept low enough (~2.4) that the radius-2 ×2 blur and
/// bilinear magnification still read it as smooth flowing bands, not noise.
const double _kDepthFieldCycles = 2.4;

/// How strongly the cross-direction accent anchor (anchors[2]) mixes in — pushes the
/// field from parallel bands toward a 2D *cellular* look (smaller, more regions).
const double _kDepthAccentMix = 0.5;

/// A finer third ramp folded on top, interleaving the analogous pair so even the
/// remaining larger areas get subdivided — keeps regions small and numerous.
const double _kDepthFineMix = 0.3;

/// Builds the AMLL mesh-gradient source texture from an album cover — a faithful
/// port of `MeshGradientRenderer.setAlbum` (preprocessing half) + `img.ts`.
///
/// Pipeline (identical maths to the source):
///  1. downscale the cover to [kAlbumTexSize]² (low quality, like AMLL),
///  2. per-pixel colour grade **in this exact order**, keeping the channels as
///     unclamped doubles until the final store (matching the JS, where only the
///     final `Uint8ClampedArray` write clamps):
///       - contrast 0.4  →  `(c-128)*0.4 + 128`
///       - saturate 3.0  →  `gray*-2 + c*3`        (gray = .3r+.59g+.11b)
///       - contrast 1.7  →  `(c-128)*1.7 + 128`
///       - brightness .75 →  `c * 0.75`            (clamped on store)
///  2b. **colour depth** for near-monochrome covers ([_injectColorDepth]): a
///     gentle, luma-preserving synthetic hue field is mixed in so the warp has
///     more than one hue to flow between — a self-gating no-op for covers that
///     already vary, which stay byte-for-byte AMLL-faithful,
///  3. box-blur radius [_kBlurRadius] (2), **[_kBlurPasses] (2) passes** — two below
///     AMLL's `blurImage(imageData, 2, 4)` so the cover's colour regions stay
///     sharper (the field's smoothness comes mostly from sampling this 32² texture
///     across the whole screen with bilinear magnification, not heavy blur),
///  4. decode the RGBA bytes back into a [ui.Image] used as a **mirrored-repeat**
///     texture by the mesh shader.
///
/// [depthColors] is the album's extracted palette (`ArtworkPalette` already appends
/// synthesised analogous/complementary hues for low-variance covers); it biases the
/// depth field toward the cover's own palette when it offers distinct hues, else
/// the field is synthesised from the texture's mean colour.
Future<ui.Image> buildAlbumTexture(
  ui.Image source, {
  List<Color> depthColors = const <Color>[],
}) async {
  const int n = kAlbumTexSize;

  // 1. Downscale to n×n.
  final double nd = n.toDouble();
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    source,
    ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, nd, nd),
    ui.Paint()..filterQuality = ui.FilterQuality.low,
  );
  final ui.Image small = await recorder.endRecording().toImage(n, n);
  final ByteData? bd =
      await small.toByteData(format: ui.ImageByteFormat.rawRgba);
  small.dispose();
  if (bd == null) {
    throw StateError('buildAlbumTexture: toByteData returned null');
  }
  final Uint8List pixels = bd.buffer.asUint8List();

  // 2. Colour grade (contrast .4 → saturate 3 → contrast 1.7 → brightness .75).
  for (int i = 0; i < pixels.length; i += 4) {
    double r = pixels[i].toDouble();
    double g = pixels[i + 1].toDouble();
    double b = pixels[i + 2].toDouble();

    // contrast 0.4
    r = (r - 128) * 0.4 + 128;
    g = (g - 128) * 0.4 + 128;
    b = (b - 128) * 0.4 + 128;

    // saturate 3.0
    final double gray = r * 0.3 + g * 0.59 + b * 0.11;
    r = gray * -2.0 + r * 3.0;
    g = gray * -2.0 + g * 3.0;
    b = gray * -2.0 + b * 3.0;

    // contrast 1.7
    r = (r - 128) * 1.7 + 128;
    g = (g - 128) * 1.7 + 128;
    b = (b - 128) * 1.7 + 128;

    // brightness 0.75 (clamp on store)
    pixels[i] = (r * 0.75).clamp(0.0, 255.0).toInt();
    pixels[i + 1] = (g * 0.75).clamp(0.0, 255.0).toInt();
    pixels[i + 2] = (b * 0.75).clamp(0.0, 255.0).toInt();
    pixels[i + 3] = 255;
  }

  // 2b. Colour depth for near-monochrome covers (gentle synthetic hue field; a
  //     self-gating no-op for covers that already vary). Done before the blur so the
  //     injected field is softened into the cover with no visible seams.
  _injectColorDepth(pixels, n, depthColors);

  // 3. Box blur — radius [_kBlurRadius] (2), [_kBlurPasses] (2) passes. AMLL ships
  //    `blurImage(imageData, 2, 4)`; we run two fewer passes on purpose (see
  //    [_kBlurPasses]). The blur stays light by design: the cover's distinct colour
  //    regions must survive here so the warped mesh shows them as the flowing bands
  //    you see on the real player (the "明显分割线") — fewer passes = crisper bands =
  //    more visible flow. The screen-filling softness comes later, for free, from
  //    bilinear magnification of this 32² texture — NOT from heavy blur. (Running 12
  //    passes collapses every cover into one flat wash — the regression that made the
  //    field a featureless blur instead of the gradient.)
  _blurImage(pixels, n, n, _kBlurRadius, _kBlurPasses);

  // 4. Decode back to a ui.Image.
  return _imageFromRgba(pixels, n, n);
}

/// Separable box blur — direct port of `img.ts#blurImage` (a "stack-ish" moving
/// average run [quality] times over RGBA bytes). Operates in place on [pixels].
void _blurImage(
  Uint8List pixels,
  int width,
  int height,
  int radius,
  int quality,
) {
  final int wm = width - 1;
  final int hm = height - 1;
  final int rad1x = radius + 1;
  final int divx = radius + rad1x;
  final int rad1y = radius + 1;
  final int divy = radius + rad1y;
  final double div2 = 1.0 / (divx * divy);

  final Int32List r = Int32List(width * height);
  final Int32List g = Int32List(width * height);
  final Int32List b = Int32List(width * height);
  final Int32List a = Int32List(width * height);
  final Int32List vmin = Int32List(width > height ? width : height);
  final Int32List vmax = Int32List(width > height ? width : height);

  int rsum, gsum, bsum, asum, x, y, i, p, p1, p2, yp, yi, yw;

  while (quality-- > 0) {
    yw = yi = 0;

    for (y = 0; y < height; y++) {
      rsum = pixels[yw] * rad1x;
      gsum = pixels[yw + 1] * rad1x;
      bsum = pixels[yw + 2] * rad1x;
      asum = pixels[yw + 3] * rad1x;

      for (i = 1; i <= radius; i++) {
        p = yw + ((i > wm ? wm : i) << 2);
        rsum += pixels[p];
        gsum += pixels[p + 1];
        bsum += pixels[p + 2];
        asum += pixels[p + 3];
      }

      for (x = 0; x < width; x++) {
        r[yi] = rsum;
        g[yi] = gsum;
        b[yi] = bsum;
        a[yi] = asum;

        if (y == 0) {
          vmin[x] = (x + rad1x < wm ? x + rad1x : wm) << 2;
          vmax[x] = (x - radius > 0 ? x - radius : 0) << 2;
        }

        p1 = yw + vmin[x];
        p2 = yw + vmax[x];

        rsum += pixels[p1] - pixels[p2];
        gsum += pixels[p1 + 1] - pixels[p2 + 1];
        bsum += pixels[p1 + 2] - pixels[p2 + 2];
        asum += pixels[p1 + 3] - pixels[p2 + 3];

        yi++;
      }
      yw += width << 2;
    }

    for (x = 0; x < width; x++) {
      yp = x;
      rsum = r[yp] * rad1y;
      gsum = g[yp] * rad1y;
      bsum = b[yp] * rad1y;
      asum = a[yp] * rad1y;

      for (i = 1; i <= radius; i++) {
        yp += i > hm ? 0 : width;
        rsum += r[yp];
        gsum += g[yp];
        bsum += b[yp];
        asum += a[yp];
      }

      yi = x << 2;
      for (y = 0; y < height; y++) {
        pixels[yi] = (rsum * div2 + 0.5).toInt();
        pixels[yi + 1] = (gsum * div2 + 0.5).toInt();
        pixels[yi + 2] = (bsum * div2 + 0.5).toInt();
        pixels[yi + 3] = (asum * div2 + 0.5).toInt();

        if (x == 0) {
          vmin[y] = (y + rad1y < hm ? y + rad1y : hm) * width;
          vmax[y] = (y - radius > 0 ? y - radius : 0) * width;
        }

        p1 = x + vmin[y];
        p2 = x + vmax[y];

        rsum += r[p1] - r[p2];
        gsum += g[p1] - g[p2];
        bsum += b[p1] - b[p2];
        asum += a[p1] - a[p2];

        yi += width << 2;
      }
    }
  }
}

Future<ui.Image> _imageFromRgba(Uint8List rgba, int width, int height) {
  final Completer<ui.Image> completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Mixes a gentle, **luma-preserving** synthetic hue field into a near-monochrome
/// [n]×[n] texture (RGBA bytes, in place) so the mesh warp has more than one hue to
/// flow between — a cover that is essentially one colour otherwise warps a flat
/// field into a monotonous background. This is the only intentional colour
/// deviation from AMLL and it is **self-gating**: the blend strength scales with how
/// monochrome the cover is, so covers that already vary measurably are left
/// byte-for-byte faithful.
///
/// Steps:
///  1. measure the colour-graded texture's per-channel mean-absolute-deviation;
///  2. `strength = (1 - clamp(dev/[_kDepthVarFull])) · [_kDepthMaxStrength]` — high
///     for a one-colour cover, ~0 for a varied one (early-out below ~0.02);
///  3. derive three field anchors ([_depthAnchors]) — an analogous pair + a soft
///     split-complementary accent, preferring [depthColors] when they offer
///     genuinely different hues, else synthesised off the cover's own mean hue;
///  4. per texel, blend toward a higher-frequency *cellular* mix of those anchors
///     (small, numerous regions — see [_kDepthFieldCycles]), first rescaling the
///     field to the texel's own luma so only *hue* shifts — the cover keeps its
///     brightness/identity, it just gains depth.
void _injectColorDepth(Uint8List pixels, int n, List<Color> depthColors) {
  final int count = n * n;
  if (count == 0) return;

  // 1. Mean colour + mean absolute deviation (on the graded texture — the ground
  //    truth for "is this cover essentially one colour").
  double sumR = 0, sumG = 0, sumB = 0;
  for (int i = 0; i < count; i++) {
    final int o = i * 4;
    sumR += pixels[o];
    sumG += pixels[o + 1];
    sumB += pixels[o + 2];
  }
  final double meanR = sumR / count;
  final double meanG = sumG / count;
  final double meanB = sumB / count;

  double dev = 0;
  for (int i = 0; i < count; i++) {
    final int o = i * 4;
    dev += (pixels[o] - meanR).abs() +
        (pixels[o + 1] - meanG).abs() +
        (pixels[o + 2] - meanB).abs();
  }
  dev /= count * 3; // per-channel mean abs deviation, 0..255

  // 2. Self-gating strength: varied covers (high deviation) get ~nothing.
  final double varNorm = (dev / _kDepthVarFull).clamp(0.0, 1.0);
  final double strength = (1.0 - varNorm) * _kDepthMaxStrength;
  if (strength < 0.02) return;

  // 3. Three field anchors as 0..255 doubles.
  final Color mean = Color.fromARGB(
    255,
    meanR.round().clamp(0, 255).toInt(),
    meanG.round().clamp(0, 255).toInt(),
    meanB.round().clamp(0, 255).toInt(),
  );
  final List<Color> anchors = _depthAnchors(mean, depthColors);
  final Color cL = anchors[0], cR = anchors[1], cC = anchors[2];
  final double aLr = cL.r * 255.0, aLg = cL.g * 255.0, aLb = cL.b * 255.0;
  final double aRr = cR.r * 255.0, aRg = cR.g * 255.0, aRb = cR.b * 255.0;
  final double aCr = cC.r * 255.0, aCg = cC.g * 255.0, aCb = cC.b * 255.0;

  // 4. Higher-frequency cellular hue field, luma-preserving blend.
  final double inv = n > 1 ? 1.0 / (n - 1) : 0.0;
  final double f = _kDepthFieldCycles;
  for (int y = 0; y < n; y++) {
    final double v = y * inv;
    for (int x = 0; x < n; x++) {
      final double u = x * inv;
      // Three ramps at [_kDepthFieldCycles] cycles in DIFFERENT directions → a 2D
      // patchwork of SMALL regions (not one big band), so a near-monochrome cover
      // never warps into a single screen-filling colour. The blur below softens the
      // cell seams into flowing bands.
      final double g1 = 0.5 + 0.5 * math.cos(math.pi * f * (u + v));
      final double g2 = 0.5 + 0.5 * math.cos(math.pi * f * (u - v) + 0.7);
      final double g3 = 0.5 + 0.5 * math.cos(math.pi * f * 1.7 * u + 1.9);

      double fr = aLr + (aRr - aLr) * g1;
      double fg = aLg + (aRg - aLg) * g1;
      double fb = aLb + (aRb - aLb) * g1;
      // Cross-direction accent → cells; finer ramp interleaves the analogous pair so
      // even the larger remaining areas get subdivided into more regions.
      final double k = g2 * _kDepthAccentMix;
      fr += (aCr - fr) * k;
      fg += (aCg - fg) * k;
      fb += (aCb - fb) * k;
      final double k2 = g3 * _kDepthFineMix;
      fr += (aRr - fr) * k2;
      fg += (aRg - fg) * k2;
      fb += (aRb - fb) * k2;

      final int o = (y * n + x) * 4;
      final double pr = pixels[o].toDouble();
      final double pg = pixels[o + 1].toDouble();
      final double pb = pixels[o + 2].toDouble();

      // Rescale the field to this texel's luma → only hue shifts, brightness stays.
      final double pl = pr * 0.3 + pg * 0.59 + pb * 0.11;
      final double fl = fr * 0.3 + fg * 0.59 + fb * 0.11;
      final double sc = fl > 1.0 ? pl / fl : 1.0;
      fr *= sc;
      fg *= sc;
      fb *= sc;

      pixels[o] = (pr + (fr - pr) * strength).clamp(0.0, 255.0).round();
      pixels[o + 1] = (pg + (fg - pg) * strength).clamp(0.0, 255.0).round();
      pixels[o + 2] = (pb + (fb - pb) * strength).clamp(0.0, 255.0).round();
    }
  }
}

/// Three colour-field anchors for [_injectColorDepth]: an analogous pair (±~30°)
/// plus a soft split-complementary accent (+150°), derived off [mean]'s hue. When
/// [depthColors] supplies genuinely different, saturated hues (ArtworkPalette's
/// synthesised depth colours) they are preferred for the accent/second anchor so
/// the mesh interpolates the palette's own colours; otherwise everything is
/// synthesised off [mean] — keeping this self-contained (no service dependency).
List<Color> _depthAnchors(Color mean, List<Color> depthColors) {
  final HSLColor base = HSLColor.fromColor(mean);
  final double s = base.saturation;
  final double l = base.lightness;
  Color shift(double dHue, double dSat, double dLight) => base
      .withHue((base.hue + dHue) % 360.0)
      .withSaturation((s + dSat).clamp(0.0, 1.0))
      .withLightness((l + dLight).clamp(0.0, 1.0))
      .toColor();

  final Color aL = shift(-30, 0.10, 0.04);
  Color aR = shift(30, 0.06, -0.04);
  Color aC = shift(150, -0.06, 0.0);

  // Prefer real, hue-distinct palette swatches when ArtworkPalette supplied them.
  final List<Color> distinct = <Color>[];
  for (final Color c in depthColors) {
    final HSLColor h = HSLColor.fromColor(c);
    if (h.saturation < 0.12) continue; // skip greys
    if (_hueDist(h.hue, base.hue) > 22.0) distinct.add(c);
  }
  if (distinct.isNotEmpty) {
    aC = distinct.first;
    if (distinct.length > 1) aR = distinct[1];
  }
  return <Color>[aL, aR, aC];
}

/// Shortest distance between two hues (degrees, 0..180).
double _hueDist(double a, double b) {
  final double d = (a - b).abs() % 360.0;
  return d > 180.0 ? 360.0 - d : d;
}
