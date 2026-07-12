import 'dart:math' as math;
import 'dart:typed_data';

import 'cp_presets.dart';

/// A built Bicubic-Hermite-Patch mesh — the geometry the AMLL mesh-gradient
/// draws. Port of `BHPMesh` (`mesh-renderer/index.ts`). Holds, per vertex:
///  - [positions]: warped clip-space position (x,y ∈ roughly [-1,1]),
///  - [uv]: the **regular** (un-warped) texture coordinate ∈ [0,1],
///  - [mask]: the AMLL vignette `0.6 + smoothstep(0.8,0.3,dist)·0.4` (1 at
///    centre → 0.6 at the edge), computed from [uv] like the fragment shader.
///
/// Vertex colours in the source are always white — the album enters only via the
/// texture sampled at [uv] — so we don't store a colour, just the vignette mask.
class BhpMesh {
  BhpMesh({
    required this.positions,
    required this.uv,
    required this.mask,
    required this.indices,
    required this.vertexSide,
  });

  final Float32List positions; // 2 per vertex (clip space)
  final Float32List uv; // 2 per vertex (regular [0,1])
  final Float32List mask; // 1 per vertex (vignette 0.6..1.0)
  final Uint16List indices;
  final int vertexSide; // vertices per side (VN)

  int get vertexCount => vertexSide * vertexSide;

  /// Builds the mesh from a control-point [p] preset at the given [subdivisions]
  /// (AMLL uses 50; lower stays visually identical since the warp field and the
  /// 32² blurred texture are both smooth). The preset must be square (N×N) — all
  /// built-in presets and `generateControlPoints` are.
  factory BhpMesh.fromPreset(ControlPointPreset p, int subdivisions) {
    final int n = p.width;
    assert(p.height == n, 'mesh presets are square');

    // Base tangent spacing, exactly as setAlbum computes uPower/vPower.
    final double uPower = 2 / (n - 1);
    final double vPower = 2 / (n - 1);

    // Build control points (location + tangents from rot/scale), indexed (cx,cy).
    final List<_CP> cps = List<_CP>.generate(n * n, (_) => _CP());
    for (final ControlPointConf c in p.conf) {
      final _CP cp = cps[c.cx + c.cy * n];
      cp.locX = c.x;
      cp.locY = c.y;
      cp.setU(c.ur * math.pi / 180, uPower * c.up);
      cp.setV(c.vr * math.pi / 180, vPower * c.vp);
    }

    final int subDivM1 = subdivisions - 1;
    final int vn = (n - 1) * subdivisions; // vertices per side
    final double invSubDivM1 = 1 / subDivM1;
    final double t = subDivM1 * (n - 1).toDouble();
    final double invT = 1 / t; // invTH == invTW (square)

    final Float32List positions = Float32List(vn * vn * 2);
    final Float32List uv = Float32List(vn * vn * 2);
    final Float32List mask = Float32List(vn * vn);

    // Precomputed [norm³, norm², norm, 1] for each subdivision step.
    final Float64List normPowers = Float64List(subdivisions * 4);
    for (int i = 0; i < subdivisions; i++) {
      final double norm = i * invSubDivM1;
      final int idx = i * 4;
      normPowers[idx] = norm * norm * norm;
      normPowers[idx + 1] = norm * norm;
      normPowers[idx + 2] = norm;
      normPowers[idx + 3] = 1;
    }

    final Float64List mX = Float64List(16);
    final Float64List mY = Float64List(16);
    final Float64List accX = Float64List(16);
    final Float64List accY = Float64List(16);
    final Float64List ux = Float64List(4);
    final Float64List uy = Float64List(4);

    for (int x = 0; x < n - 1; x++) {
      for (int y = 0; y < n - 1; y++) {
        final _CP p00 = cps[x + y * n];
        final _CP p01 = cps[x + (y + 1) * n];
        final _CP p10 = cps[(x + 1) + y * n];
        final _CP p11 = cps[(x + 1) + (y + 1) * n];

        _meshCoefficients(p00, p01, p10, p11, 0, mX); // axis x
        _meshCoefficients(p00, p01, p10, p11, 1, mY); // axis y
        _precompute(mX, accX);
        _precompute(mY, accY);

        final double sX = x / (n - 1);
        final double sY = y / (n - 1);
        final int baseVx = y * subdivisions;
        final int baseVy = x * subdivisions;

        for (int u = 0; u < subdivisions; u++) {
          final int vxOffset = baseVx + u;
          final int uIdx = u * 4;

          ux[0] = normPowers[uIdx];
          ux[1] = normPowers[uIdx + 1];
          ux[2] = normPowers[uIdx + 2];
          ux[3] = normPowers[uIdx + 3];
          _transformMat4(ux, accX);

          uy[0] = normPowers[uIdx];
          uy[1] = normPowers[uIdx + 1];
          uy[2] = normPowers[uIdx + 2];
          uy[3] = normPowers[uIdx + 3];
          _transformMat4(uy, accY);

          final double uvY = 1 - sY - u * invT;

          for (int v = 0; v < subdivisions; v++) {
            final int vy = baseVy + v;
            final int vIdx = v * 4;
            final double v0 = normPowers[vIdx];
            final double v1 = normPowers[vIdx + 1];
            final double v2 = normPowers[vIdx + 2];
            final double v3 = normPowers[vIdx + 3];

            final double px = v0 * ux[0] + v1 * ux[1] + v2 * ux[2] + v3 * ux[3];
            final double py = v0 * uy[0] + v1 * uy[1] + v2 * uy[2] + v3 * uy[3];
            final double uvX = sX + v * invT;

            final int flat = vxOffset + vy * vn;
            positions[flat * 2] = px;
            positions[flat * 2 + 1] = py;
            uv[flat * 2] = uvX;
            uv[flat * 2 + 1] = uvY;

            // AMLL vignette, evaluated from the regular uv exactly like the frag.
            final double dx = uvX - 0.5;
            final double dy = uvY - 0.5;
            final double dist = math.sqrt(dx * dx + dy * dy);
            final double vig = _smoothstep(0.8, 0.3, dist);
            mask[flat] = 0.6 + vig * 0.4;
          }
        }
      }
    }

    // Standard grid triangulation over the vn×vn vertices.
    final Uint16List indices = Uint16List((vn - 1) * (vn - 1) * 6);
    int ii = 0;
    for (int yv = 0; yv < vn - 1; yv++) {
      for (int xv = 0; xv < vn - 1; xv++) {
        final int i0 = yv * vn + xv;
        final int i1 = i0 + 1;
        final int i2 = i0 + vn;
        final int i3 = i2 + 1;
        indices[ii++] = i0;
        indices[ii++] = i1;
        indices[ii++] = i2;
        indices[ii++] = i1;
        indices[ii++] = i3;
        indices[ii++] = i2;
      }
    }

    return BhpMesh(
      positions: positions,
      uv: uv,
      mask: mask,
      indices: indices,
      vertexSide: vn,
    );
  }
}

double _smoothstep(double edge0, double edge1, double x) {
  double t = (x - edge0) / (edge1 - edge0);
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  return t * t * (3 - 2 * t);
}

class _CP {
  double locX = 0, locY = 0;
  double uTanX = 0, uTanY = 0;
  double vTanX = 0, vTanY = 0;
  void setU(double rot, double scale) {
    uTanX = math.cos(rot) * scale;
    uTanY = math.sin(rot) * scale;
  }

  void setV(double rot, double scale) {
    vTanX = -math.sin(rot) * scale;
    vTanY = math.cos(rot) * scale;
  }

  double loc(int axis) => axis == 0 ? locX : locY;
  double uTan(int axis) => axis == 0 ? uTanX : uTanY;
  double vTan(int axis) => axis == 0 ? vTanX : vTanY;
}

// --- gl-matrix Mat4 (column-major flat 16) helpers, exact ports ---

/// H = Mat4.fromValues(2,-2,1,1, -3,3,-2,-1, 0,0,1,0, 1,0,0,0)
final Float64List _h = Float64List.fromList(<double>[
  2, -2, 1, 1, //
  -3, 3, -2, -1, //
  0, 0, 1, 0, //
  1, 0, 0, 0, //
]);
final Float64List _hT = _transpose(_h);

Float64List _transpose(Float64List a) {
  final Float64List o = Float64List(16);
  o[0] = a[0];
  o[1] = a[4];
  o[2] = a[8];
  o[3] = a[12];
  o[4] = a[1];
  o[5] = a[5];
  o[6] = a[9];
  o[7] = a[13];
  o[8] = a[2];
  o[9] = a[6];
  o[10] = a[10];
  o[11] = a[14];
  o[12] = a[3];
  o[13] = a[7];
  o[14] = a[11];
  o[15] = a[15];
  return o;
}

void _mul(Float64List out, Float64List a, Float64List b) {
  final double a00 = a[0], a01 = a[1], a02 = a[2], a03 = a[3];
  final double a10 = a[4], a11 = a[5], a12 = a[6], a13 = a[7];
  final double a20 = a[8], a21 = a[9], a22 = a[10], a23 = a[11];
  final double a30 = a[12], a31 = a[13], a32 = a[14], a33 = a[15];
  for (int c = 0; c < 4; c++) {
    final double b0 = b[c * 4], b1 = b[c * 4 + 1], b2 = b[c * 4 + 2], b3 = b[c * 4 + 3];
    out[c * 4] = b0 * a00 + b1 * a10 + b2 * a20 + b3 * a30;
    out[c * 4 + 1] = b0 * a01 + b1 * a11 + b2 * a21 + b3 * a31;
    out[c * 4 + 2] = b0 * a02 + b1 * a12 + b2 * a22 + b3 * a32;
    out[c * 4 + 3] = b0 * a03 + b1 * a13 + b2 * a23 + b3 * a33;
  }
}

/// out = vec4 transformed by m (column-major): out = m · a, in place on [a].
void _transformMat4(Float64List a, Float64List m) {
  final double x = a[0], y = a[1], z = a[2], w = a[3];
  a[0] = m[0] * x + m[4] * y + m[8] * z + m[12] * w;
  a[1] = m[1] * x + m[5] * y + m[9] * z + m[13] * w;
  a[2] = m[2] * x + m[6] * y + m[10] * z + m[14] * w;
  a[3] = m[3] * x + m[7] * y + m[11] * z + m[15] * w;
}

final Float64List _tmpA = Float64List(16);

/// precomputeMatrix: output = H_T · (Mᵀ · H)
void _precompute(Float64List m, Float64List output) {
  // output = Mᵀ
  final Float64List mt = _transpose(m);
  // _tmpA = Mᵀ · H
  _mul(_tmpA, mt, _h);
  // output = H_T · _tmpA
  _mul(output, _hT, _tmpA);
}

/// meshCoefficients for one axis (0=x, 1=y), writing into [out] (flat 16).
void _meshCoefficients(_CP p00, _CP p01, _CP p10, _CP p11, int axis, Float64List out) {
  out[0] = p00.loc(axis);
  out[1] = p01.loc(axis);
  out[2] = p00.vTan(axis);
  out[3] = p01.vTan(axis);
  out[4] = p10.loc(axis);
  out[5] = p11.loc(axis);
  out[6] = p10.vTan(axis);
  out[7] = p11.vTan(axis);
  out[8] = p00.uTan(axis);
  out[9] = p01.uTan(axis);
  out[10] = 0;
  out[11] = 0;
  out[12] = p10.uTan(axis);
  out[13] = p11.uTan(axis);
  out[14] = 0;
  out[15] = 0;
}
