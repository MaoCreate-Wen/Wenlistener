import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../models/image_url.dart';
import '../services/artwork_palette.dart' show kCoverAnalysisDecodeDim;
import '../services/resource_cache.dart' show DiskCachedImage;
import '../theme/app_colors.dart';
import 'mesh_gradient/album_texture.dart';
import 'mesh_gradient/bhp_mesh.dart';
import 'mesh_gradient/cp_generate.dart';
import 'mesh_gradient/cp_presets.dart';

/// Lyrics-page background: a **source-level port of AMLL's `MeshGradientRenderer`**
/// (`@applemusic-like-lyrics/core`), under a flat black mask.
///
/// Faithful pipeline (same maths as the original):
///  1. the cover is reduced to 32², colour-graded
///     (`contrast .4 → saturate 3 → contrast 1.7 → brightness .75`) and box-blurred
///     (radius 2 ×2, plus a gentle colour-depth pass for near-monochrome covers)
///     into a **mirrored-repeat texture** — see [buildAlbumTexture];
///  2. a control-point **preset** (or, ~30% of the time, a denser random
///     [generateControlPoints] grid) drives a **bicubic Hermite patch** mesh
///     ([BhpMesh]) — warped vertex positions carrying regular UVs;
///  3. each frame the texture coordinates are **rotated** about uv (0.2,0.2) by
///     `(u_time+0.1)·2` and **zoomed** by `max(.001, 1-vol·2)` about (0.5,0.5)
///     (`u_time = frameTime/10000`, `frameTime += dt·flowSpeed·speedEase·beatSurge`),
///     exactly like `mesh.frag.glsl`; the mesh is drawn with [Canvas.drawVertices]
///     + an [ui.ImageShader] (mirror) and [BlendMode.modulate] so the per-vertex
///     **vignette** (`0.6 + smoothstep(0.8,0.3,dist)·0.4`) multiplies the texture;
///  4. album changes **cross-fade** via `easeInOutSine` (new mesh fades in over
///     the old, which is dropped once the new one is fully in).
///
/// **Rhythm.** AMLL's `u_volume` is the live low-frequency audio level, which the
/// shader turns into a swirl/zoom/darken pulse. When [lowFreqVolume] supplies a real
/// FFT reading (from `FftService` over the native Visualizer) it IS `u_volume`:
/// rotation `(u_time+u_volume)·2`, zoom `max(.001,1-u_volume·2)`, and a slight
/// darken-on-loud `max(.5,1-u_volume·.5)` — all straight from `mesh.frag.glsl`. When
/// no real signal is available (null / sentinel `< 0` — no mic or unsupported, e.g.
/// emulator), we synthesise a tasteful beat instead: a shaped sine at [_kBeatHz]
/// (~0.5 Hz), eased in while [playing] and out when paused ([_pulseEase]), surging the
/// flow clock (`1+[_kFlowPulseAmp]×`) + zoom (`0.1+[_kPulseVolumeAmp]`); the synthetic
/// beat only ADDS to the monotonic clock and keeps the rotation's frozen `+0.1` phase,
/// so the swirl never reverses. Paused, the beat eases to zero and the flow drifts
/// (speedEase→0.15). Defaults: flowSpeed 2 (= AMLL 4 after the 30fps/60Hz halving),
/// ~30fps.
class NeonFlowBackground extends StatefulWidget {
  /// The album cover sampled into the mesh texture. When null/loading the
  /// [colors] palette wash shows underneath.
  final String? imageUrl;

  /// The album's extracted palette — the wash shown before the cover decodes.
  final List<Color> colors;

  /// Background flow speed. Default 2 = AMLL's `flowSpeed` 4 (`base.ts:69`) after
  /// the 30fps-vs-60Hz `frameDelta` halving, since we integrate real elapsed
  /// time. Overridable.
  final double flowSpeed;

  /// Whether playback is active. Drives both the flow-SPEED gate and the synthetic
  /// rhythm pulse: playing → AMLL swirl with the beat swell eased in (see the class
  /// doc); paused → the beat fades out and the flow eases to a slow drift.
  final bool playing;

  /// Real-time AMLL `u_volume` from `FftService` (≈0.1 rest … ~0.3 loud). While it
  /// is null, or its value is the sentinel `< 0` (no mic / Visualizer unsupported),
  /// the background drives itself with the synthetic pulse below. When a real reading
  /// is present it replaces the synthetic beat and perturbs the rotation exactly like
  /// AMLL's `mesh.frag.glsl` (`angle = (u_time + u_volume)·2`).
  final ValueListenable<double>? lowFreqVolume;

  /// Whether the background reacts to the music (律动). When false it still flows
  /// gently but never pulses with the beat — the lyrics-page 律动 settings toggle.
  final bool reactive;

  /// The player↔lyrics morph clock (0=player, 1=lyrics). While it is strictly
  /// between 0 and 1 the field HOLDS its last frame (skips the ≈40k-vertex
  /// drawVertices) so the 280ms transition stays at 60fps — the flow turns only
  /// once per ~31s, so a held frame is invisible. Read ONLY inside the Ticker, so
  /// a changing value never rebuilds this widget.
  final Animation<double>? morph;

  const NeonFlowBackground({
    super.key,
    this.imageUrl,
    required this.colors,
    required this.playing,
    this.flowSpeed = 2,
    this.lowFreqVolume,
    this.reactive = true,
    this.morph,
  });

  /// Warm-up hook: decodes + grades [url]'s cover into the shared mesh-texture
  /// cache BEFORE any player/lyrics page mounts (call it from an always-mounted
  /// spot whenever the current song changes — see `_MeshPrewarmer` in
  /// `app_router.dart`). A warmed URL makes the first open of the now-playing
  /// surface a cache hit, so the field renders at FULL alpha from its very
  /// first frame instead of cross-fading in from the palette wash mid-push —
  /// the wash flashing through the route transition was the desktop 闪屏 (the
  /// same class of bug the mobile app fixed with its "background always-mount"
  /// rule; here only the cheap 32² texture is kept warm, not a live field).
  ///
  /// Fire-and-forget and re-entrant: cache hits and in-flight builds no-op, and
  /// failures fall back to the normal load-on-mount path.
  static Future<void> prewarm(String? url, List<Color> depthColors) async {
    if (url == null || url.isEmpty) return;
    final Map<String, ui.Image> cache = _NeonFlowBackgroundState._texCache;
    if (cache.containsKey(url) ||
        !_NeonFlowBackgroundState._prewarming.add(url)) {
      return;
    }
    try {
      final ui.Image? tex = await _NeonFlowBackgroundState._buildTextureForUrl(
        url,
        depthColors,
      );
      if (tex == null) return;
      // Same bounded-cache discipline as `_maybeLoad` (FIFO eviction).
      if (!cache.containsKey(url) &&
          cache.length >= _NeonFlowBackgroundState._kTexCacheCap) {
        cache.remove(cache.keys.first);
      }
      cache[url] = tex;
    } finally {
      _NeonFlowBackgroundState._prewarming.remove(url);
    }
  }

  /// Drops (and disposes) every cached 32² mesh texture. 轻量模式 memory hook:
  /// call ONLY while no [NeonFlowBackground] is mounted — live [MeshLayer]s
  /// hold shaders built from these images, so clearing under a mounted field
  /// would paint from disposed textures. An in-flight [prewarm] simply re-adds
  /// its (single, ~4 KB) entry afterwards; the next mount re-decodes on demand.
  static void clearTextureCache() {
    for (final ui.Image tex in _NeonFlowBackgroundState._texCache.values) {
      tex.dispose();
    }
    _NeonFlowBackgroundState._texCache.clear();
  }

  @override
  State<NeonFlowBackground> createState() => _NeonFlowBackgroundState();
}

class _NeonFlowBackgroundState extends State<NeonFlowBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// Drives repaints; its value is the flow-scaled `frameTime` in ms.
  final ValueNotifier<double> _frameTime = ValueNotifier<double>(0);
  Duration _last = Duration.zero;
  double _frameTimeMs = 0;

  /// Wall-clock ms at the last repaint emit, for the FPS cap.
  double _lastEmitMs = -1000;

  /// Play/pause SPEED gate (part of the play/pause response): eases to 1.0 while
  /// playing (exact AMLL steady-state flow) and to 0.15 when paused (a slow drift)
  /// over ~400ms. Multiplies the flow clock advance (which the beat surge also rides).
  double _speedEase = 1;

  /// Phase of the synthetic beat, in cycles [0,1); advances by [_kBeatHz] each
  /// second, then sampled into a shaped swell that drives the rhythm pulse.
  double _beatPhase = 0;

  /// Eases the beat intensity in (→1) while [playing] and out (→0) when paused, so
  /// the pulse swells with the music and settles to calm when stopped.
  double _pulseEase = 1;

  /// True while a real FFT reading ([NeonFlowBackground.lowFreqVolume] ≥ 0) is
  /// driving the pulse; the painter then perturbs rotation by `u_volume` (AMLL).
  /// Flips rarely (FFT start/stop), so a [setState] on change is cheap.
  bool _realMode = false;

  /// The synthetic `u_volume` fed to the painter (merged with [_frameTime] for
  /// repaints): baseline [_kConstVolume] (≈ 0.1) plus the eased beat swell, up to
  /// `+[_kPulseVolumeAmp]`. Drives the shader's zoom-in pulse and the painter's
  /// brightness throb. Updated only at emit time so it stays on the 30fps cadence.
  final ValueNotifier<double> _pulseNotifier =
      ValueNotifier<double>(_kConstVolume);

  /// Render-rate glide of `u_volume` (the value the painter reads). The FFT
  /// events arrive at ~20Hz but the ticker runs every frame, so we ease this
  /// toward the latest target every tick — the zoom/rotation then flow
  /// continuously instead of stepping at the event rate (which reads as jitter).
  double _renderVol = _kConstVolume;

  /// Active mesh layers (oldest → newest); newest fades in over the rest.
  final List<MeshLayer> _layers = <MeshLayer>[];

  /// Max entries in [_texCache] before the oldest is evicted (each is a tiny 32²
  /// ui.Image; capped so a long listening session can't grow it unbounded).
  static const int _kTexCacheCap = 24;

  /// Texture cache keyed by URL — re-opening a track never re-decodes/grades.
  /// Bounded by [_kTexCacheCap] (FIFO eviction; see [_maybeLoad]).
  static final Map<String, ui.Image> _texCache = <String, ui.Image>{};

  /// URLs with a [NeonFlowBackground.prewarm] build in flight (dedupe guard).
  static final Set<String> _prewarming = <String>{};

  /// Process-wide cache of built [BhpMesh] geometry, keyed by control-point
  /// preset (identity). The ~40k-vertex mesh is **album-independent** — it is
  /// pure warped geometry (positions/uv/mask/indices); the album enters only via
  /// [MeshLayer.texture]. So a fresh `BhpMesh.fromPreset` on every player open /
  /// track change re-ran ~40k-vertex + 237k-index construction (~1.3MB typed
  /// arrays, several ms on the UI thread, right on the sheet-push's first frame)
  /// for geometry that's fully reusable. The 6 curated presets stay resident
  /// (hit forever); the rare (~15%) generated grid is bounded by [_kMeshGeoCap]
  /// FIFO so a long session can't accumulate. Immutable + read-only, so any
  /// number of layers/albums share one instance safely.
  static final Map<ControlPointPreset, BhpMesh> _meshGeoCache =
      <ControlPointPreset, BhpMesh>{};
  static const int _kMeshGeoCap = 12;

  BhpMesh _meshFor(ControlPointPreset preset, int subs) {
    final BhpMesh? cached = _meshGeoCache[preset];
    if (cached != null) return cached;
    final BhpMesh mesh = BhpMesh.fromPreset(preset, subs);
    if (_meshGeoCache.length >= _kMeshGeoCap) {
      _meshGeoCache.remove(_meshGeoCache.keys.first);
    }
    _meshGeoCache[preset] = mesh;
    return mesh;
  }

  /// Shared, content-independent dither tile (see paint()) — built once, reused
  /// by every instance. Tiled + added over the field it breaks 8-bit banding.
  static ui.ImageShader? _ditherShader;
  static bool _ditherLoading = false;

  /// The URL whose mesh is currently the newest layer (or loading).
  String? _currentUrl;
  final math.Random _rng = math.Random();

  @override
  void initState() {
    super.initState();
    _speedEase = widget.playing ? 1.0 : 0.15;
    _pulseEase = widget.playing ? 1.0 : 0.0;
    _ticker = createTicker(_onTick)..start();
    _ensureDither();
    // Pre-warm: when the texture is already cached (any repeat open of this
    // track's player/lyrics page) the FIRST layer is pushed synchronously at
    // FULL alpha, so the very first composited frame is the real mesh field —
    // the route's own push-fade blends the whole page in, so replaying the
    // wash→mesh cross-fade here would only flash the wash (闪屏) on every open.
    _maybeLoad(instantFirst: true);
  }

  /// Builds the shared dither tile the first time any background mounts, then
  /// repaints. A small RGBA tile of low-amplitude monochrome noise; tiled and
  /// added with [BlendMode.plus] it nudges each pixel by ~0..2/255 — a faithful
  /// stand-in for the `gradientNoise` dither at the end of AMLL's
  /// `mesh.frag.glsl` (`result.rgb += vec3(dither)`).
  void _ensureDither() {
    if (_ditherShader != null || _ditherLoading) return;
    _ditherLoading = true;
    _buildDitherImage().then((ui.Image img) {
      _ditherShader = ui.ImageShader(
        img,
        TileMode.repeated,
        TileMode.repeated,
        _kIdentity,
        filterQuality: FilterQuality.none,
      );
      _ditherLoading = false;
      if (mounted) setState(() {});
    });
  }

  static Future<ui.Image> _buildDitherImage() {
    const int s = 64;
    final Uint8List px = Uint8List(s * s * 4);
    final math.Random rng = math.Random(0x9E3779B9);
    for (int i = 0; i < s * s; i++) {
      final int v = rng.nextInt(3); // 0,1,2 → +0..2/255 via BlendMode.plus
      final int o = i * 4;
      px[o] = v;
      px[o + 1] = v;
      px[o + 2] = v;
      px[o + 3] = 255;
    }
    final Completer<ui.Image> c = Completer<ui.Image>();
    ui.decodeImageFromPixels(px, s, s, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  @override
  void didUpdateWidget(NeonFlowBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) _maybeLoad();
  }

  void _onTick(Duration elapsed) {
    final double nowMs = elapsed.inMicroseconds / 1000.0;
    final double dtMs =
        _last == Duration.zero ? 0 : (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;

    // FREEZE the field while the player↔lyrics morph is in flight (0 < t < 1):
    // hold the last emitted frame so the ≈40k-vertex drawVertices + ImageShader
    // is NOT re-run for the 280ms morph while the cover morphs and the neon
    // cross-fades in. The flow turns once per ~31s, so a held frame is invisible;
    // skipping the dt integration too means the flow clock doesn't jump when the
    // morph settles and animation resumes. `_last` is already updated above, so
    // resume computes dt from now (no accumulated backlog). Note: at t==0 the
    // neon paints under Opacity(0) (skipped) so the tick here is nearly free.
    final double? m = widget.morph?.value;
    if (m != null && m > 0.001 && m < 0.999) return;

    // Play/pause SPEED gate (a gate on the flow SPEED, not a fake volume): ease to
    // 1.0 playing / 0.15 paused over ~400ms.
    _speedEase += ((widget.playing ? 1.0 : 0.15) - _speedEase) *
        (dtMs / 400).clamp(0.0, 1.0);

    // Real FFT vs synthetic. A live low-freq reading ([lowFreqVolume] ≥ 0) IS
    // `u_volume` (AMLL); otherwise synthesise a beat. [_realMode] drives the
    // painter's rotation term.
    final double realVol =
        (widget.reactive ? widget.lowFreqVolume?.value : null) ?? -1.0;
    final bool useReal = realVol >= 0;
    if (useReal != _realMode) {
      setState(() => _realMode = useReal);
    }

    // Beat-intensity gate: ease the synthetic pulse in while playing, out when paused
    // (→ calm), over [_kPulseEaseMs].
    _pulseEase += ((widget.playing ? 1.0 : 0.0) - _pulseEase) *
        (dtMs / _kPulseEaseMs).clamp(0.0, 1.0);

    // Synthetic beat: a shaped sine at [_kBeatHz]. `beat` ∈ [0,1] is the eased swell
    // (flow surge + zoom + darken) standing in for AMLL's live `u_volume` envelope
    // when no FFT is available.
    _beatPhase = (_beatPhase + dtMs * _kBeatHz / 1000.0) % 1.0;
    final double beatRaw = 0.5 - 0.5 * math.cos(2 * math.pi * _beatPhase);
    // 律动 off (settings) → no synthetic beat either; the field flows calmly.
    final double beat = widget.reactive
        ? math.pow(beatRaw, _kBeatSharpness).toDouble() * _pulseEase
        : 0.0;

    // Glide `u_volume` toward its latest target EVERY tick (not just at emit) so it's
    // continuous between the ~20Hz FFT events. Kept SHORT so beats still punch through.
    final double targetVol = useReal
        ? realVol.clamp(0.0, 0.6)
        : _kConstVolume + beat * _kPulseVolumeAmp;
    _renderVol +=
        (targetVol - _renderVol) * (dtMs / _kVolGlideMs).clamp(0.0, 1.0);

    // Flow clock. BOTH modes surge the (monotonic) flow clock on a beat so the swirl
    // visibly speeds up — real mode from the live volume above baseline, synthetic
    // from the invented beat. Only ever ADDS, so the rotation never reverses.
    // flowSpeed-2 default == AMLL's 4 after its 30fps-vs-60Hz `frameDelta` halving.
    final double beatAmt = useReal
        ? ((_renderVol - _kConstVolume) / _kRealVolRange).clamp(0.0, 1.0)
        : beat;
    final double surge = 1.0 + beatAmt * _kFlowPulseAmp;
    _frameTimeMs += dtMs * widget.flowSpeed * _speedEase * surge;

    // Cross-fade: the newest layer eases in (≈500ms); once full, drop the rest.
    bool fading = false;
    if (_layers.isNotEmpty) {
      final MeshLayer newest = _layers.last;
      if (newest.alpha < 1.0) {
        fading = true;
        newest.alpha = math.min(1.0, newest.alpha + dtMs / 500.0);
        if (newest.alpha >= 1.0 && _layers.length > 1) {
          for (int i = 0; i < _layers.length - 1; i++) {
            _layers[i].dispose();
          }
          _layers.removeRange(0, _layers.length - 1);
        }
      }
    }

    // FPS cap: the field rotates once per ~31s, so 30fps is visually identical
    // to 60 while halving GPU cost — important on the emulator's slow GLES. Never
    // throttle below a cross-fade so song changes stay buttery.
    if (fading || nowMs - _lastEmitMs >= _kMinFrameIntervalMs) {
      _lastEmitMs = nowMs;
      _frameTime.value = _frameTimeMs;
      // The render-glided `u_volume` — real FFT reading (smoothed) when present,
      // else the synthetic beat swell. Drives the shader's zoom + rotation (and the
      // gentle brightness darken). Sampled here with the 30fps cap.
      _pulseNotifier.value = _renderVol;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frameTime.dispose();
    _pulseNotifier.dispose();
    for (final MeshLayer l in _layers) {
      l.dispose();
    }
    _layers.clear();
    super.dispose();
  }

  /// Loads + preprocesses the current cover into a new mesh layer (cross-faded
  /// in). Cached textures resolve synchronously; a track change mid-decode is
  /// ignored. [instantFirst] (initState only) makes a cache-hit first layer
  /// appear at FULL alpha instead of fading — the page itself is being pushed
  /// under a route fade, so the field should be its settled self from frame 0
  /// (fading it in from the wash reads as a background flash on every open).
  void _maybeLoad({bool instantFirst = false}) {
    final String? url = widget.imageUrl;
    if (url == null || url.isEmpty) {
      _currentUrl = null;
      return;
    }
    if (url == _currentUrl) return;
    _currentUrl = url;

    final ui.Image? cached = _texCache[url];
    if (cached != null) {
      _pushLayer(cached, url, instant: instantFirst && _layers.isEmpty);
      return;
    }

    // Pass the album's palette so [buildAlbumTexture] can give near-monochrome
    // covers synthetic colour depth (it self-synthesises if the palette is empty).
    _buildTextureForUrl(url, widget.colors).then((ui.Image? tex) {
      if (!mounted || tex == null) return;
      if (widget.imageUrl != url) return; // track changed while decoding
      // Bound the cache so a long session can't accumulate ui.Images unbounded.
      // Evict the OLDEST url (never the just-added one). Dropping the map ref is
      // safe even if a live layer still holds that image — the layer's own
      // reference keeps it valid, so this can never use-after-dispose, and GC
      // reclaims the rest.
      if (!_texCache.containsKey(url) && _texCache.length >= _kTexCacheCap) {
        _texCache.remove(_texCache.keys.first);
      }
      _texCache[url] = tex;
      _pushLayer(tex, url);
    });
  }

  /// Picks a control-point preset (or, ~30% of the time, a denser generated grid),
  /// builds the bicubic mesh and pushes a new fading-in layer ([instant] skips
  /// the fade — used for a cache-hit FIRST layer at mount, see [_maybeLoad]).
  void _pushLayer(ui.Image texture, String url, {bool instant = false}) {
    final ControlPointPreset preset = _rng.nextDouble() < _kGenerateProbability
        ? generateControlPoints(_kGenerateGrid, _kGenerateGrid, _rng)
        : kControlPointPresets[_rng.nextInt(kControlPointPresets.length)];
    // Clamp tessellation so (n-1)·subdiv vertices/side stays under the 65 536 Uint16
    // index ceiling for denser grids; the 4×4/5×5 presets keep the full
    // [_kSubdivisions] (255÷4 = 63 ≥ 50); a 6×6 generated grid keeps the full 50
    // (255÷5 = 51), so generated grids no longer facet.
    final int subs = math.min(_kSubdivisions, 255 ~/ (preset.width - 1));
    final BhpMesh mesh = _meshFor(preset, subs);
    setState(() {
      _layers.add(
        MeshLayer(texture: texture, mesh: mesh)..alpha = instant ? 1.0 : 0.0,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Palette wash beneath — never a black flash before the cover decodes.
          _PaletteWash(colors: widget.colors),
          // The faithful AMLL mesh-gradient, repainting on the Ticker. Its own
          // RepaintBoundary keeps the per-frame mesh repaint from re-recording
          // the static [_PaletteWash] beneath it, and isolates the field's raster
          // layer from everything above (the lyrics).
          RepaintBoundary(
            child: CustomPaint(
              size: Size.infinite,
              painter: _MeshGradientPainter(
                layers: _layers,
                frameTime: _frameTime,
                pulse: _pulseNotifier,
                ditherShader: _ditherShader,
                realMode: _realMode,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Loads [url] (with the Netease CDN headers) and preprocesses it into the
  /// 32² mesh texture. [depthColors] is the album palette, forwarded to
  /// [buildAlbumTexture] for the near-monochrome colour-depth pass.
  static Future<ui.Image?> _buildTextureForUrl(
    String url,
    List<Color> depthColors,
  ) async {
    try {
      // Decode at the shared 128² analysis size ([kCoverAnalysisDecodeDim]) —
      // this builder immediately reduces the cover to a 32² texture, so a
      // native-resolution decode (25-36 MB RGBA per Netease cover, measured)
      // bought nothing; the ResizeImage construction is IDENTICAL to
      // ArtworkPalette's, so palette + mesh resolve one ~64 KB cache entry.
      final ImageProvider provider = ResizeImage.resizeIfNeeded(
        kCoverAnalysisDecodeDim,
        kCoverAnalysisDecodeDim,
        DiskCachedImage(url, headers: kNeteaseImageHeaders),
      );
      final Completer<ui.Image> completer = Completer<ui.Image>();
      final ImageStream stream = provider.resolve(const ImageConfiguration());
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (ImageInfo info, bool _) {
          if (!completer.isCompleted) completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (Object e, StackTrace? s) {
          if (!completer.isCompleted) completer.completeError(e);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      final ui.Image cover = await completer.future;
      return await buildAlbumTexture(cover, depthColors: depthColors);
    } catch (e) {
      debugPrint('NeonFlowBackground texture build failed: $e');
      return null;
    }
  }
}

/// Subdivision level of the bicubic patch — **50, exactly AMLL's
/// `resetSubdivition(50)`**. Tessellation controls how finely the warp curve is
/// approximated; at 50 the flowing colour bands have smooth, AMLL-faithful edges
/// (a 5×5 preset → 200×200 vertices). Denser generated grids ([_kGenerateGrid], 7×7)
/// would overflow the 65 536 Uint16 index ceiling at 50, so [_pushLayer] clamps their
/// subdivisions (7×7 → 42 → 252×252 = 63 504, still under the ceiling); the warp is
/// visually identical a few steps below 50. The mesh is built once per album and
/// cached, so per frame we only rotate texCoords + drawVertices — cheap at 30fps.
const int _kSubdivisions = 50;

/// Uniform outward scale on clip positions. **AMLL uses none (1.0)**: every preset
/// pins its border control points at exactly ±1 and the aspect logic
/// (`pos.y*=aspect` / `pos.x/=aspect`) only ever *expands* the constrained axis,
/// so the mesh always fills the frame with no gaps. Kept at 1.0 to match exactly.
const double _kClipOverscan = 1.0;

/// Min ms between mesh repaints (30fps cap). The background's rotation is slow
/// enough that 30 and 60 fps are indistinguishable here.
const double _kMinFrameIntervalMs = 1000.0 / 30.0;

/// Internal render downscale for the mesh field. On Windows Flutter renders
/// through Skia/ANGLE(D3D), which is fill-rate bound on this full-window mesh —
/// its per-frame cost scales with pixel area (the "bigger window = worse"
/// symptom). We render the whole field (the ≈40k-vertex `drawVertices`, the
/// `ImageShader` sample, the dither `plus` pass and the brightness `modulate`)
/// into an offscreen at `1/this` per axis, then upscale with a single cheap
/// bilinear blit. The field is inherently soft (a 32² box-blurred texture
/// magnified across the whole screen), so a moderate downscale is invisible.
///
/// **2.0, not the old 3.0.** At 3× the offscreen was so coarse that the bilinear
/// UPSCALE — not the mesh — became the artefact: reconstructing the low-res grid
/// puts a C¹ (derivative) discontinuity at every buffer-texel boundary, and along
/// a diagonal colour band those folds line up into a faint Mach-band staircase
/// that reads as "锯齿" once stretched 3–6× (worst at 1440p/4K). 2.0 maps each grid
/// cell to ~2 output px so the fold period drops below the visible threshold. The
/// mesh itself never aliased (it fills the frame with no silhouette edge — MSAA
/// would buy nothing); this is purely a source-resolution fix. Desktop GPUs have
/// the fill-rate to spare (the ≈4× offscreen pixels are still a rounding error).
const double _kFieldDownsample = 2.0;

/// Absolute ceiling on the offscreen field buffer's HEIGHT, so the per-frame
/// mesh fill-rate stops scaling with the window/monitor at all: on a large or
/// 4K-maximised window the effective downsample grows past [_kFieldDownsample]
/// to keep the buffer ≤ this many rows. Raised 360 → 720 alongside the
/// [_kFieldDownsample] drop: 360 pinned the buffer at ~640×360 on ANY ≥1080p
/// window (1080p→3×, 4K→6×), so the upscale staircase above was always present
/// on desktop. At 720 the buffer is ~960×540 (1080p) / 1280×720 (1440p & 4K,
/// capped), grid cells map to 2–3 output px, and the staircase disappears. The
/// full-resolution cost that remains is still the single bilinear blit (one cheap
/// textured quad, independent of the buffer size), and the cap keeps the offscreen
/// fill CONSTANT above 1440p instead of growing with the monitor.
const double _kFieldMaxHeight = 720.0;

/// Time constant (ms) for the render-rate `u_volume` glide ([_renderVol]) — eases
/// the reactive volume toward each new FFT target so the zoom/rotation glide
/// between the ~20Hz FFT events instead of stepping. Kept SHORT so beats still
/// punch through (over-gliding averages the pulse away → motion reads as subtle).
const double _kVolGlideMs = 90.0;

/// Normalising range for the real-mode flow surge: how far `u_volume` rises above
/// [_kConstVolume] on a strong beat. `(vol-baseline)/this` → a [0,1] beat amount
/// that (× [_kFlowPulseAmp]) speeds up the swirl, so a bass hit visibly accelerates
/// the flow (real mode; the synthetic beat drives the same surge).
const double _kRealVolRange = 0.3;

/// Baseline `u_volume` ≈ 0.1 — AMLL's steady-state level (React default
/// `setLowFreqVolume(1.0)` ÷ 10, `mesh-renderer/index.ts:928,1113`). The synthetic
/// beat (see [_kBeatHz]) swells the live volume ABOVE this baseline; at rest (paused
/// or between beats) the volume sits here and the swirl/zoom hold their AMLL values.
const double _kConstVolume = 0.1;

/// Zoom-in reactivity: `zoom = max(_kZoomFloor, 1 - u_volume·_kZoomAmp)`. AMLL uses
/// amp 2 / floor ~0, but with our punchier `u_volume` that magnifies so hard on a
/// beat that a single colour patch fills the screen. Amp 1.2 + a 0.4 floor keep the
/// zoom pulse gentle (≤~2.5× at the peak) so more of the cover's colours stay on
/// screen; the flow-speed surge + rotation carry the reactivity. Lower amp / higher
/// floor = calmer zoom.
const double _kZoomAmp = 1.2;
const double _kZoomFloor = 0.4;

/// Synthetic-beat frequency in Hz — the rhythm pulse's tempo. ~0.5 Hz is one swell
/// every two seconds: clearly visible yet calm/musical. Real audio FFT isn't wired
/// up, so this stands in for AMLL's live `u_volume` envelope. Tunable.
const double _kBeatHz = 0.5;

/// Shapes the beat's `0.5-0.5cos` swell: >1 makes it peakier (quick rise, more time
/// spent near calm between beats) for a clearer "beat", still C¹-smooth.
const double _kBeatSharpness = 1.6;

/// Peak fraction the synthetic beat adds to `u_volume` above [_kConstVolume] (the
/// no-FFT fallback). Drives the zoom-IN pulse (`zoom = max(.001, 1-vol·2)`): peak
/// 0.1+0.14 = 0.24 → zoom ~0.52 — an obvious breathing swell when no real FFT is
/// available (real FFT uses the wider `_span` in fft_service instead).
const double _kPulseVolumeAmp = 0.14;

/// Peak extra flow-SPEED on a beat: the clock advances up to `1+this×` faster at the
/// swell's peak, so the swirl visibly surges (both real + synthetic modes). Only ever
/// adds, so the clock stays monotonic → no rotation reversal/jank.
const double _kFlowPulseAmp = 1.2;

/// Ease time (ms) for the beat intensity to fade in on play / out on pause, so the
/// rhythm swells with the music and settles to calm when stopped.
const double _kPulseEaseMs = 450.0;

/// Probability a new album uses a freshly **generated** (denser, more-numerous-patch)
/// control-point grid instead of a curated preset. AMLL uses ~20%; we keep it low so
/// the warped regions stay large with SMOOTH, rounded dividing curves — a denser grid
/// (more control points at fewer subdivisions) makes the patch boundaries read as
/// angular/faceted ("有棱有角"), which we don't want. The curated 4×4/5×5 presets at
/// 50 subdivisions give the soft rounded flow, so this is kept LOW (0.15) — most
/// covers use a smooth preset; only the occasional one gets the generated grid.
const double _kGenerateProbability = 0.15;

/// Side length of the generated control-point grid — **AMLL's 6**, restored from 7.
/// A 6×6 grid = 25 patches (vs a 7×7's 36), so fewer, larger patches → softer
/// dividing curves; and its tessellation is the FULL [_kSubdivisions] (255÷5 = 51 ≥
/// 50) rather than a 7×7's 42, so the warp curves stay smooth (less "有棱有角").
const int _kGenerateGrid = 6;

/// One album's mesh + texture, with its cross-fade alpha and reusable per-frame
/// buffers (positions cached by size, colours by alpha, texCoords every frame).
class MeshLayer {
  MeshLayer({required this.texture, required this.mesh})
      : _texCoords = Float32List(mesh.vertexCount * 2),
        _colors = Int32List(mesh.vertexCount);

  final ui.Image texture;
  final BhpMesh mesh;
  double alpha = 0;

  final Float32List _texCoords;
  final Int32List _colors;
  Size? _posSize;
  Float32List? _posScreen;
  double _colorsForAlpha = -1;

  /// The mirrored-repeat texture shader — built once per layer, not per frame.
  late final ui.ImageShader shader = ui.ImageShader(
    texture,
    TileMode.mirror,
    TileMode.mirror,
    _kIdentity,
    filterQuality: FilterQuality.low,
  );

  /// The layer's drawVertices Paint — built once per layer, not per frame.
  late final Paint paint = Paint()..shader = shader;

  /// Maps the clip-space mesh positions to screen pixels for [size], applying the
  /// AMLL aspect overscan (`aspect>1 → y*=aspect; else x/=aspect`) + a small
  /// uniform overscan. Cached until the size changes.
  Float32List positionsFor(Size size) {
    if (_posScreen != null && _posSize == size) return _posScreen!;
    final double w = size.width, h = size.height;
    final double aspect = h == 0 ? 1 : w / h;
    final Float32List src = mesh.positions;
    final Float32List out = Float32List(src.length);
    for (int i = 0; i < mesh.vertexCount; i++) {
      double px = src[i * 2] * _kClipOverscan;
      double py = src[i * 2 + 1] * _kClipOverscan;
      if (aspect > 1) {
        py *= aspect;
      } else {
        px /= aspect;
      }
      out[i * 2] = (px * 0.5 + 0.5) * w;
      out[i * 2 + 1] = (py * 0.5 + 0.5) * h;
    }
    _posScreen = out;
    _posSize = size;
    return out;
  }

  /// Per-vertex colours = vignette mask, with alpha = `easeInOutSine(alpha)` so
  /// `BlendMode.modulate` multiplies the texture by the mask and fades the layer.
  Int32List colors() {
    final double a = _easeInOutSine(alpha.clamp(0.0, 1.0));
    if (_colorsForAlpha == a) return _colors;
    final int ai = (a * 255).round().clamp(0, 255);
    final Float32List mask = mesh.mask;
    for (int i = 0; i < mesh.vertexCount; i++) {
      final int m = (mask[i] * 255).round().clamp(0, 255);
      _colors[i] = (ai << 24) | (m << 16) | (m << 8) | m;
    }
    _colorsForAlpha = a;
    return _colors;
  }

  /// Rotates the regular UVs about (0.2,0.2) by [angle], scales by [zoom] about
  /// (0.5,0.5), then to texture pixels — `rot(v_uv-0.2, angle)·zoom + 0.5` from
  /// `mesh.frag.glsl` ([zoom] softened from AMLL's `1-u_volume·2`, see [_kZoomAmp];
  /// constant here).
  Float32List texCoords(double angle, double zoom) {
    final double c = math.cos(angle), s = math.sin(angle);
    final Float32List uv = mesh.uv;
    final double texSize = kAlbumTexSize.toDouble();
    for (int i = 0; i < mesh.vertexCount; i++) {
      final double du = uv[i * 2] - 0.2;
      final double dv = uv[i * 2 + 1] - 0.2;
      final double ru = c * du - s * dv;
      final double rv = s * du + c * dv;
      _texCoords[i * 2] = (ru * zoom + 0.5) * texSize;
      _texCoords[i * 2 + 1] = (rv * zoom + 0.5) * texSize;
    }
    return _texCoords;
  }

  /// Drops this layer. The [texture] is **owned by the URL cache**, not the
  /// layer, so nothing is disposed here (a re-opened track reuses the texture).
  void dispose() {}
}

double _easeInOutSine(double x) => -(math.cos(math.pi * x) - 1) / 2;

final Float64List _kIdentity = Float64List.fromList(<double>[
  1, 0, 0, 0, //
  0, 1, 0, 0, //
  0, 0, 1, 0, //
  0, 0, 0, 1, //
]);

class _MeshGradientPainter extends CustomPainter {
  _MeshGradientPainter({
    required this.layers,
    required this.frameTime,
    required this.pulse,
    required this.ditherShader,
    required this.realMode,
  }) : super(repaint: Listenable.merge(<Listenable>[frameTime, pulse]));

  final List<MeshLayer> layers;
  final ValueNotifier<double> frameTime;

  /// Whether a real FFT signal is driving [pulse]; selects AMLL's
  /// `angle = (u_time + u_volume)·2` rotation (real) vs the frozen baseline phase
  /// (synthetic, so the invented beat can't reverse the swirl).
  final bool realMode;

  /// The synthetic `u_volume` — baseline [_kConstVolume] (≈ 0.1) plus the beat swell.
  /// Drives the pulsing zoom (`max(.001, 1-vol·2)`) and the brightness throb; the
  /// rotation uses the constant baseline phase instead. Merged with [frameTime] for
  /// repaints.
  final ValueNotifier<double> pulse;
  final ui.ImageShader? ditherShader;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || layers.isEmpty) return;

    // Render the mesh into a REDUCED-resolution offscreen, then upscale with one
    // cheap bilinear blit. Everything in [_paintField] then runs at
    // 1/scale² the pixels — the fill-rate the Skia/ANGLE(D3D)
    // Windows backend is bound on (offscreen layers, ImageShader, per-pixel blend
    // passes). `toImageSync` keeps the rasterisation on the GPU. Because the field
    // is inherently soft the upscale is invisible, and — with the
    // [_kFieldMaxHeight] cap — the mesh's per-frame fill-rate is now CONSTANT
    // regardless of window size (the old "bigger window = worse" culprit); only
    // the single bilinear blit still touches full-window pixels.
    final double scale = math.max(
      _kFieldDownsample,
      size.height / _kFieldMaxHeight,
    );
    final int lowW = math.max(1, (size.width / scale).round());
    final int lowH = math.max(1, (size.height / scale).round());
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas lowCanvas = Canvas(recorder);
    _paintField(lowCanvas, Size(lowW.toDouble(), lowH.toDouble()));
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(lowW, lowH);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, lowW.toDouble(), lowH.toDouble()),
      Offset.zero & size,
      _blitPaint,
    );
    image.dispose();
    picture.dispose();
    // Release the native buffers of this frame's transient Vertices objects NOW
    // (the rasterised image no longer needs them) instead of waiting on the GC —
    // at 30 emits/s the untracked native allocations otherwise pile up between
    // collections and show as memory/GC jitter.
    for (final ui.Vertices v in _frameVertices) {
      v.dispose();
    }
    _frameVertices.clear();
  }

  /// Reusable Paint objects — the painter allocates NO Paints per frame.
  /// Safe as statics: painting is single-threaded (UI thread) and each field is
  /// fully (re)configured before every use.
  static final Paint _blitPaint = Paint()..filterQuality = FilterQuality.low;
  static final Paint _ditherPaint = Paint()..blendMode = BlendMode.plus;
  static final Paint _dimPaint = Paint()..blendMode = BlendMode.modulate;

  /// This frame's transient [ui.Vertices], disposed right after the offscreen
  /// is rasterised (see [paint]). Static scratch list — never grows past the
  /// live layer count (1, or 2 during a cross-fade).
  static final List<ui.Vertices> _frameVertices = <ui.Vertices>[];

  /// Paints one frame of the mesh field at [size] (the reduced offscreen size).
  /// All coordinates derive from [size], so the geometry is identical at any
  /// resolution — only the pixel count changes. Kept a pure paint routine so
  /// [paint] can drive it into a downscaled buffer.
  void _paintField(Canvas canvas, Size size) {
    if (size.isEmpty || layers.isEmpty) return;

    // u_time = frameTime/10000; vol = the synthetic `u_volume` (baseline 0.1 + beat).
    // angle keeps AMLL's `(u_time + 0.1)·2` form but with the CONSTANT baseline phase
    // — the beat rides the (monotonic) flow clock inside u_time, so the rotation can
    // surge but never reverse. zoom = max(.001, 1 - vol·2) pulses straight from
    // `mesh.frag.glsl`: as the beat swells vol, the field zooms in.
    final double uTime = frameTime.value / 10000.0;
    final double vol = pulse.value;
    // AMLL `mesh.frag.glsl:36` rotates by `(u_time + u_volume)·2`. With a real
    // (heavily-smoothed) signal we use vol directly so the bass perturbs rotation;
    // synthetic mode keeps the constant baseline phase so the invented 0.5 Hz beat
    // can't reverse the swirl.
    final double angle = (uTime + (realMode ? vol : _kConstVolume)) * 2.0;
    // Zoom-in pulse. AMLL is `max(.001, 1-vol·2)`, but our punchy `u_volume`
    // over-magnifies on a beat (one colour patch fills the screen); softened to
    // `1-vol·[_kZoomAmp]` with a [_kZoomFloor] floor so a beat gently zooms (≤~2.5×)
    // rather than slamming in.
    final double zoom = math.max(_kZoomFloor, 1.0 - vol * _kZoomAmp);
    // AMLL loudness darken (`mesh.frag.glsl:41`): `max(0.5, 1 - u_volume·0.5)` — a
    // gentle per-pixel dim, 0.95 at rest (vol 0.1) … ~0.85 on a beat, floor 0.5.
    // Applied as a modulate below, NOT the old up-to-45% black flash (a strobe).
    final double brightness = math.max(0.5, 1.0 - vol * 0.5);

    final Rect rect = Offset.zero & size;

    // No per-frame blur — exactly like AMLL, which has none either. The softness
    // is inherent: the 32² texture (radius-2 ×3 box blur, see buildAlbumTexture)
    // sampled across the whole screen with bilinear magnification IS the smooth
    // gradient; the light blur keeps the cover's colour regions, so the warp shows
    // them as flowing bands. Each frame is just the cheap textured mesh + the
    // dither below — no full-screen Gaussian blur to pay for every frame.
    for (final MeshLayer layer in layers) {
      final Float32List positions = layer.positionsFor(size);
      final Float32List texCoords = layer.texCoords(angle, zoom);
      final Int32List colors = layer.colors();

      final ui.Vertices vertices = ui.Vertices.raw(
        VertexMode.triangles,
        positions,
        textureCoordinates: texCoords,
        colors: colors,
        indices: layer.mesh.indices,
      );
      // Disposed after the offscreen rasterises (see [paint]) — the Vertices
      // wrapper itself is the one unavoidable per-frame allocation (the engine
      // API offers no mutable variant); its Float32List inputs are all reused.
      _frameVertices.add(vertices);

      // modulate → texel.rgb · maskColor.rgb, texel.a(1) · maskColor.a(fade).
      // [MeshLayer.paint] is the layer's cached shader Paint — no per-frame Paint.
      canvas.drawVertices(vertices, BlendMode.modulate, layer.paint);
    }

    // The field's current coverage: the strongest layer's eased fade alpha.
    // Scales the loudness dim below so it ramps in WITH a cross-fade instead of
    // snapping on the frame the fade completes (the old `alpha >= 0.99` hard
    // gate popped the whole background 5–12% darker in a single frame at the
    // end of every player open — a visible blink).
    double fieldAlpha = 0;
    for (final MeshLayer l in layers) {
      final double a = _easeInOutSine(l.alpha.clamp(0.0, 1.0));
      if (a > fieldAlpha) fieldAlpha = a;
    }

    // Dithering — a faithful port of the final step of AMLL's `mesh.frag.glsl`
    // (`result.rgb += vec3(dither)`). Adding ~1/255 of static, screen-space
    // noise breaks the 8-bit contour banding that a smooth gradient (all the
    // more so after the blur above) would otherwise show as faint "boundary"
    // rings. Drawn last, in screen space, over the composited field.
    //
    // BlendMode.plus also sums alpha, so we apply it only once the field is
    // opaque — i.e. not during a layer's fade-in, when the canvas is still
    // partly transparent and the palette wash below must show through (banding
    // is imperceptible during that ½s, and the ±2/255 step when this flips is
    // itself invisible — unlike the dim below, which must ramp).
    final ui.ImageShader? dither = ditherShader;
    if (dither != null && fieldAlpha >= 0.99) {
      canvas.drawRect(rect, _ditherPaint..shader = dither);
    }

    // Loud → gently DARKER, matching AMLL (`mesh.frag.glsl:41-43`): a smooth
    // per-pixel multiply (`BlendMode.modulate`) by [brightness], NOT a flat black
    // over-paint. This replaces the old up-to-45% black Rect that flashed on every
    // bass hit (a luminance strobe that read as flicker and hid the motion). At the
    // peak vol (~0.35) brightness ≈ 0.83 → ~17% dim; at rest (0.1) ≈ 0.95 → ~5%.
    // modulate·transparent stays transparent so the palette wash below is
    // untouched, and modulate on a premultiplied semi-transparent field dims it
    // proportionally — so the dim is scaled by [fieldAlpha] (fades in with the
    // layer) rather than hard-gated on an opaque field, which used to land the
    // full dim in one frame when the cross-fade finished.
    final double dimmed = 1.0 - (1.0 - brightness) * fieldAlpha;
    if (dimmed < 0.999) {
      final int c = (dimmed * 255).round().clamp(0, 255);
      canvas.drawRect(rect, _dimPaint..color = Color.fromARGB(255, c, c, c));
    }
  }

  @override
  bool shouldRepaint(_MeshGradientPainter old) =>
      !identical(old.layers, layers) ||
      old.frameTime != frameTime ||
      old.pulse != pulse ||
      old.realMode != realMode ||
      old.ditherShader != ditherShader;
}

/// The palette wash shown beneath the mesh until the cover decodes (and as the
/// backdrop the first layer fades in over).
class _PaletteWash extends StatelessWidget {
  const _PaletteWash({required this.colors});

  final List<Color> colors;

  /// Compresses a raw palette swatch into the mesh field's tonal range. The
  /// field is inherently DARK — the album texture is graded `brightness .75`
  /// (after the contrast/saturate passes), multiplied by the 0.6–1.0 vignette
  /// and the AMLL loudness dim — while raw palette swatches keep the cover's
  /// native lightness. For a bright cover (beige/white art) the un-toned wash
  /// was a near-white blast the player's push-fade dragged across the dark
  /// home shell for a few frames (闪屏) before the mesh covered it. Halving
  /// the lightness and capping it at 0.30 keeps the wash hue-true to the album
  /// but guarantees it can never be brighter than the field that replaces it.
  static Color _fieldTone(Color c) {
    final HSLColor h = HSLColor.fromColor(c);
    return h
        .withLightness((h.lightness * 0.5).clamp(0.05, 0.30))
        .toColor();
  }

  @override
  Widget build(BuildContext context) {
    // A soft, tonally-coherent vertical ramp derived from the dominant swatch,
    // not two unrelated colours meeting in the middle — so the wash shown for
    // the ~½s before the mesh fades in already reads like the smooth field that
    // replaces it (same hue, same DARK tonal range — see [_fieldTone]).
    final Color base =
        _fieldTone(colors.isNotEmpty ? colors[0] : AppColors.seed);
    final Color second = colors.length > 1
        ? _fieldTone(colors[1])
        : shiftLightness(base, -0.16);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            shiftLightness(base, 0.06),
            base,
            second,
            shiftLightness(second, -0.22),
          ],
          stops: const <double>[0.0, 0.4, 0.72, 1.0],
        ),
      ),
      child: const ColoredBox(color: Color(0x1A000000)),
    );
  }
}

/// Lightens (positive) or darkens (negative) [c] by [amount] in HSL lightness —
/// used to derive tonally-related gradient stops from a single dominant colour.
Color shiftLightness(Color c, double amount) {
  final HSLColor h = HSLColor.fromColor(c);
  return h.withLightness((h.lightness + amount).clamp(0.0, 1.0)).toColor();
}
