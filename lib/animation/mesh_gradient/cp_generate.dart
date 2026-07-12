import 'dart:math' as math;

import 'cp_presets.dart';

/// Tangent-scale range for generated interior control points (AMLL uses 0.8–1.2).
/// Tightened a touch so no single patch's Hermite tangents balloon it into a
/// screen-dominating region — keeps the organic warp while capping per-patch
/// coverage (part of the lyrics-bg "no one giant colour block" fix).
const double _kGenTangentMin = 0.85;
const double _kGenTangentMax = 1.15;

/// Tangent-rotation spread (± degrees) for generated interior control points (AMLL
/// uses ±60). Slightly narrowed for the same reason.
const double _kGenRotDeg = 50.0;

/// Experimental random control-point generator — a direct port of
/// `bg-render/mesh-renderer/cp-generate.ts`. Produces an organic [n]×[n] patch
/// (AMLL calls `generateControlPoints(6, 6)` ~20% of the time instead of a
/// fixed preset). Uses [rng] for all the `Math.random()` draws.
ControlPointPreset generateControlPoints(int width, int height, math.Random rng) {
  double randomRange(double min, double max) => rng.nextDouble() * (max - min) + min;

  final double variationFraction = randomRange(0.4, 0.6);
  final double normalOffset = randomRange(0.3, 0.6);
  const double blendFactor = 0.8;
  final int smoothIters = randomRange(3, 5).floor();
  final double smoothFactor = randomRange(0.2, 0.3);
  final double smoothModifier = randomRange(-0.1, -0.05);

  final int w = width;
  final int h = height;

  final List<ControlPointConf> conf = <ControlPointConf>[];
  final double dx = w == 1 ? 0 : 2 / (w - 1);
  final double dy = h == 1 ? 0 : 2 / (h - 1);

  for (int j = 0; j < h; j++) {
    for (int i = 0; i < w; i++) {
      final double baseX = (w == 1 ? 0.0 : i / (w - 1)) * 2 - 1;
      final double baseY = (h == 1 ? 0.0 : j / (h - 1)) * 2 - 1;

      final bool isBorder = i == 0 || i == w - 1 || j == 0 || j == h - 1;
      final double pertX =
          isBorder ? 0 : randomRange(-variationFraction * dx, variationFraction * dx);
      final double pertY =
          isBorder ? 0 : randomRange(-variationFraction * dy, variationFraction * dy);
      double x = baseX + pertX;
      double y = baseY + pertY;

      final double ur = isBorder ? 0 : randomRange(-_kGenRotDeg, _kGenRotDeg);
      final double vr = isBorder ? 0 : randomRange(-_kGenRotDeg, _kGenRotDeg);
      final double up =
          isBorder ? 1 : randomRange(_kGenTangentMin, _kGenTangentMax);
      final double vp =
          isBorder ? 1 : randomRange(_kGenTangentMin, _kGenTangentMax);

      if (!isBorder) {
        final double uNorm = (baseX + 1) / 2;
        final double vNorm = (baseY + 1) / 2;

        final List<double> grad = _computeNoiseGradient(uNorm, vNorm, 0.001);
        double offsetX = grad[0] * normalOffset;
        double offsetY = grad[1] * normalOffset;

        final double distToBorder =
            <double>[uNorm, 1 - uNorm, vNorm, 1 - vNorm].reduce(math.min);

        final double weight = _smoothstep(0, 1.0, distToBorder);
        offsetX *= weight;
        offsetY *= weight;

        x = x * (1 - blendFactor) + (x + offsetX) * blendFactor;
        y = y * (1 - blendFactor) + (y + offsetY) * blendFactor;
      }
      conf.add(p(i, j, x, y, ur, vr, up, vp));
    }
  }

  _smoothifyControlPoints(conf, w, h, smoothIters, smoothFactor, smoothModifier);

  return preset(w, h, conf);
}

double _clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);

double _smoothstep(double edge0, double edge1, double x) {
  final double t = _clamp01((x - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
}

double _fract(double x) => x - x.floorToDouble();

double _noise(double x, double y) =>
    _fract(math.sin(x * 12.9898 + y * 78.233) * 43758.5453);

double _smoothNoise(double x, double y) {
  final double x0 = x.floorToDouble();
  final double y0 = y.floorToDouble();
  final double x1 = x0 + 1;
  final double y1 = y0 + 1;

  final double xf = x - x0;
  final double yf = y - y0;

  final double u = xf * xf * (3 - 2 * xf);
  final double v = yf * yf * (3 - 2 * yf);

  final double n00 = _noise(x0, y0);
  final double n10 = _noise(x1, y0);
  final double n01 = _noise(x0, y1);
  final double n11 = _noise(x1, y1);

  final double nx0 = n00 * (1 - u) + n10 * u;
  final double nx1 = n01 * (1 - u) + n11 * u;

  return nx0 * (1 - v) + nx1 * v;
}

List<double> _computeNoiseGradient(double x, double y, double epsilon) {
  final double n1 = _smoothNoise(x + epsilon, y);
  final double n2 = _smoothNoise(x - epsilon, y);
  final double n3 = _smoothNoise(x, y + epsilon);
  final double n4 = _smoothNoise(x, y - epsilon);
  final double gx = (n1 - n2) / (2 * epsilon);
  final double gy = (n3 - n4) / (2 * epsilon);
  final double len = math.sqrt(gx * gx + gy * gy);
  final double l = len == 0 ? 1 : len;
  return <double>[gx / l, gy / l];
}

void _smoothifyControlPoints(
  List<ControlPointConf> conf,
  int w,
  int h,
  int iterations,
  double factor,
  double factorIterationModifier,
) {
  List<List<ControlPointConf>> grid =
      List<List<ControlPointConf>>.generate(h, (int j) => List<ControlPointConf>.generate(w, (int i) => conf[j * w + i]));
  double f = factor;

  const List<List<int>> kernel = <List<int>>[
    <int>[1, 2, 1],
    <int>[2, 4, 2],
    <int>[1, 2, 1],
  ];
  const int kernelSum = 16;

  for (int iter = 0; iter < iterations; iter++) {
    final List<List<ControlPointConf>> newGrid = List<List<ControlPointConf>>.generate(
        h, (_) => List<ControlPointConf>.filled(w, const ControlPointConf(0, 0, 0, 0)));
    for (int j = 0; j < h; j++) {
      for (int i = 0; i < w; i++) {
        if (i == 0 || i == w - 1 || j == 0 || j == h - 1) {
          newGrid[j][i] = grid[j][i];
          continue;
        }
        double sumX = 0, sumY = 0, sumUR = 0, sumVR = 0, sumUP = 0, sumVP = 0;
        for (int dj = -1; dj <= 1; dj++) {
          for (int di = -1; di <= 1; di++) {
            final int weight = kernel[dj + 1][di + 1];
            final ControlPointConf nb = grid[j + dj][i + di];
            sumX += nb.x * weight;
            sumY += nb.y * weight;
            sumUR += nb.ur * weight;
            sumVR += nb.vr * weight;
            sumUP += nb.up * weight;
            sumVP += nb.vp * weight;
          }
        }
        final double avgX = sumX / kernelSum;
        final double avgY = sumY / kernelSum;
        final double avgUR = sumUR / kernelSum;
        final double avgVR = sumVR / kernelSum;
        final double avgUP = sumUP / kernelSum;
        final double avgVP = sumVP / kernelSum;

        final ControlPointConf cur = grid[j][i];
        newGrid[j][i] = p(
          i,
          j,
          cur.x * (1 - f) + avgX * f,
          cur.y * (1 - f) + avgY * f,
          cur.ur * (1 - f) + avgUR * f,
          cur.vr * (1 - f) + avgVR * f,
          cur.up * (1 - f) + avgUP * f,
          cur.vp * (1 - f) + avgVP * f,
        );
      }
    }
    grid = newGrid;
    f = _clamp01(f + factorIterationModifier);
  }

  for (int j = 0; j < h; j++) {
    for (int i = 0; i < w; i++) {
      conf[j * w + i] = grid[j][i];
    }
  }
}
