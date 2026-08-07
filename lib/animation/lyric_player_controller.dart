import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../models/lyric_line.dart';
import 'lyric_line_render.dart';
import 'spring.dart';

/// Per-line animation state (one spring for Y, one for scale, lerped opacity +
/// blur). Mirrors a single absolutely-positioned line element in AMLL's
/// `lyric-player/base.ts`.
class _Line {
  _Line({
    required this.index,
    required this.line,
    required double seedY,
  })  : isBackground = line.isBackground,
        isWordByWord = line.isWordByWord,
        posY = Spring(initial: seedY, params: SpringParams.posY),
        scale = Spring(
          initial: line.isBackground ? 75 : 100,
          params: line.isBackground ? SpringParams.bgScale : SpringParams.scale,
        );

  final int index;
  final LyricLine line;
  final bool isBackground;
  final bool isWordByWord;

  final Spring posY;
  final Spring scale; // stored in percent (100 == 1.0×)

  double opacity = 0;
  double blur = 0;
  double targetOpacity = 0;
  double targetBlur = 0;

  // Fixed-duration eased opacity/blur transitions (CSS parity). `*From` is the
  // value captured when the target last changed; `*T` is elapsed seconds since.
  double opacityFrom = 0;
  double opacityT = 0;
  double blurFrom = 0;
  double blurT = 0;

  // Pending targets + cascade delay (the spring only retargets once the delay
  // has elapsed, replicating CSS `transition-delay`).
  double pendingY = 0;
  double pendingScale = 100;
  double appliedY = double.nan;
  double appliedScale = double.nan;
  double delayTimer = 0;
  double delaySeconds = 0;

  double height = 0;
}

/// The lyrics animation engine (AMLL `LyricPlayer` reimplementation).
///
/// NOT a scroll view: every line is an absolutely-positioned element whose
/// vertical position / scale / opacity / blur is driven independently. One
/// [Ticker] advances all springs ([update]); playback time is pushed in
/// separately ([setCurrentTime]). Listen to this ([ChangeNotifier]) to rebuild
/// the line stack each frame and read [renderLines].
class LyricPlayerController extends ChangeNotifier {
  LyricPlayerController({required TickerProvider vsync}) {
    _ticker = vsync.createTicker(_onTick)..start();
  }

  /// Suppress the per-frame [notifyListeners] rebuild while LyricsView is fully
  /// hidden (player mode, morph≈0) WITHOUT ever stopping the [Ticker]. Stopping
  /// the ticker breaks the frame delta (`Ticker.start()` restarts `elapsed` from
  /// ~0, so the first resumed tick computes a huge negative `dt` that blows the
  /// springs off-screen → the settled lyrics rendered blank). Instead the ticker
  /// keeps advancing the springs/time every vsync (cheap UI-thread math, the
  /// original proven behaviour) but we skip the rebuild of the invisible lyric
  /// stack: no `_emit()` while hidden, so the ListenableBuilder doesn't reflow a
  /// stack that paints nothing (fadeAlpha 0). Becoming visible emits at once so
  /// the springs' current (already-correct) positions show immediately.
  void setHidden(bool hidden) {
    if (hidden == _hidden) return;
    _hidden = hidden;
    if (!hidden) _emit();
  }

  // --- tunables (mirror AMLL setters) --------------------------------------
  double alignPosition = 0.35;
  double wordFadeWidth = 0.5;
  bool enableScale = true;
  bool enableBlur = true;
  bool enableSpring = true;
  bool hidePassedLines = false;

  /// How early (ms) a line begins lifting before it is actually sung. Mirrors
  /// AMLL, which shifts every line's start time up to **1000ms** earlier — with a
  /// prev-line-end clamp so closely-spaced lines never cross (`base.ts:481-494`)
  /// — so the next line rises / brightens / centres *anticipatorily*. 800ms is a
  /// safe middle: it gives a clear anticipatory lift even on fast lines while the
  /// prev-end clamp ([_computeEffectiveStarts]) keeps it from leaping a whole line
  /// ahead. CRITICAL — only the LIFT / BRIGHTEN / ANCHOR is pulled early:
  /// [activeIndex] reads these shifted starts, but the karaoke ink is gated on the
  /// **un-shifted** [singingIndex] (raw [LyricLine.start]) so words never ink
  /// before they are actually sung. Keep that separation when changing this — the
  /// shift must not feed the karaoke fill (see [singingIndex] /
  /// `KaraokeText.isSinging`), or lines would highlight a word ahead.
  static const double earlyStartMs = 800;

  /// CSS-parity opacity/blur transition durations (AMLL
  /// `transition: opacity .25s; filter .2s`, default ease). The eased fade and
  /// blur COMPLETE at these times rather than only reaching ~63% (which a
  /// time-constant approach would).
  static const double _opacityDuration = 0.25;
  static const double _blurDuration = 0.2;

  /// How far (ms) interpolated playback time may lead the last authoritative
  /// push before the ticker stops advancing it. just_audio's `positionStream`
  /// emits roughly every 200ms (its default `maxPeriod`), so ≈ one push interval
  /// is the sweet spot: large enough for the karaoke fill to advance smoothly
  /// right up to the next push, small enough that an audio micro-stall can't let
  /// the fill race far ahead and then snap backward when the lagging push lands.
  static const double _maxLeadMs = 200;

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  bool _hidden = false;

  final List<_Line> _lines = <_Line>[];
  List<LyricLine> _source = const <LyricLine>[];
  List<double> _effStartMs = const <double>[]; // pre-shifted start times

  Size _size = const Size(400, 800);
  double _timeMs = 0;
  // The last *authoritative* audio time pushed in (via [setCurrentTime] /
  // [seekTo]). The ticker interpolates [_timeMs] forward between these sparse
  // pushes; clamping the interpolation to `_lastAuthoritativeMs + _maxLeadMs`
  // (≈ one position-push interval) lets the karaoke sweep advance smoothly to
  // meet the next push without ever racing far ahead of the audio and then
  // snapping back when the lagging push lands.
  double _lastAuthoritativeMs = 0;
  bool _playing = false;

  int _activeIndex = -1;
  int _singingIndex = -1;
  bool _layoutDirty = false;
  bool _seekPending = false;
  bool _forceEmit = false; // push at least one frame after a layout change

  // Manual user-scroll (drag to browse lyrics, then spring back after ~5s).
  // Mirrors AMLL `scrollOffset` / `scrollBoundary` / the 5s `scrolledHandler`.
  double _userScrollOffset = 0;
  bool _userScrolling = false;
  double _scrollMin = 0;
  double _scrollMax = 0;
  Timer? _followResetTimer;
  // True during the 5s "hold" between releasing a browse-drag and the auto
  // snap-back glide. While set, an advancing active line does NOT re-flow the
  // column (no staggered cascade) — the lines stay frozen exactly where the user
  // left them; the snap-back then glides smoothly to the now-current line. The
  // earlier behaviour (cascade at the offset position on every active change)
  // read as the whole list refreshing. Cleared by the snap-back, a fresh grab,
  // an authoritative seek, or new lyrics.
  bool _followResetPending = false;

  // Auto snap-back glide: when the 5s follow-reset fires (or a tapped seek
  // returns the column home), the shared [_userScrollOffset] is eased to 0 over
  // [_snapBackDuration] *as one block* — the cascade is suppressed (see
  // [_recomputeLayout]'s `seeking`) and every line's posY/scale snaps to the
  // eased-offset target each frame — so the column slides smoothly to the
  // active line instead of re-staggering the whole list (which read as a
  // top-to-bottom refresh). Driven from [_onTick]; cancelled by a new drag or a
  // seek.
  bool _snappingBack = false;
  double _snapBackFrom = 0;
  double _snapBackElapsed = 0;
  static const double _snapBackDuration = 0.4;

  List<LyricLineRender> _renderLines = const <LyricLineRender>[];

  // --- public API ----------------------------------------------------------

  List<LyricLineRender> get renderLines => _renderLines;
  int get activeIndex => _activeIndex;

  /// The line genuinely being sung *right now*: the last line whose **raw**
  /// [LyricLine.start] (no early shift) ≤ current time. Unlike [activeIndex] —
  /// which is pulled ~[earlyStartMs] early so the next line can lift/brighten
  /// anticipatorily — this never runs ahead of the audio. The lyrics view gates
  /// the karaoke fill + per-word emphasis on this so exactly one line ever
  /// sweeps at a time (the early-active next line lifts but does not ink yet).
  int get singingIndex => _singingIndex;

  double get currentTimeMs => _timeMs;
  List<LyricLine> get lines => _source;

  double get _fallbackLineHeight => _size.height / 5;

  /// Replace the lyric lines. New lines are seeded offscreen-below so they fly
  /// up into view on first layout.
  void setLines(List<LyricLine> lines) {
    if (identical(lines, _source)) return;
    // Content-equal re-supply (lyrics re-fetched as a fresh list, or a resume
    // that re-emits them) must not re-seed — that would replay the fly-up
    // cascade from the offscreen seed.
    if (_sameLineContent(lines, _source)) return;
    // Genuinely new lyrics: drop any in-flight snap-back glide / browse-hold and
    // re-anchor.
    _snappingBack = false;
    _followResetPending = false;
    _followResetTimer?.cancel();
    _userScrollOffset = 0;
    _source = lines;
    _lines.clear();
    final double seedY = _size.height * 2;
    for (int i = 0; i < lines.length; i++) {
      _lines.add(_Line(index: i, line: lines[i], seedY: seedY));
    }
    _computeEffectiveStarts();
    _activeIndex = _activeFor(_timeMs);
    _singingIndex = _singingFor(_timeMs);
    _layoutDirty = true;
    _seekPending = true; // first placement is instant
    _recomputeLayout();
    _emit();
  }

  /// Whether two line lists are content-equal for layout: same length and
  /// identical per-line [LyricLine.start]/[LyricLine.end]. Suppresses a needless
  /// re-seed (and its cascade) when the same lyrics arrive as a new list object.
  static bool _sameLineContent(List<LyricLine> a, List<LyricLine> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].start != b[i].start || a[i].end != b[i].end) return false;
    }
    return true;
  }

  /// Provide measured per-line heights (logical px). Triggers a re-layout when
  /// any height meaningfully changed.
  void setLineHeights(List<double> heights) {
    bool changed = false;
    for (int i = 0; i < _lines.length && i < heights.length; i++) {
      final double h = heights[i];
      if ((h - _lines[i].height).abs() > 0.5) {
        _lines[i].height = h;
        changed = true;
      }
    }
    if (changed) {
      _layoutDirty = true;
      _recomputeLayout();
    }
  }

  /// Update the available canvas size. Snaps (no slide) so entering the page or
  /// rotating doesn't animate a re-flow.
  void resize(Size size) {
    if (size == _size || size.isEmpty) return;
    _size = size;
    _layoutDirty = true;
    _seekPending = true;
    _recomputeLayout();
    _emit();
  }

  /// Whether playback is advancing (used to interpolate time between the
  /// discrete position updates pushed via [setCurrentTime]). A *change* re-flows
  /// the layout because pausing/resuming changes the inactive-line scale targets
  /// (paused → every line returns to full scale; see [_scaleTargetFor]) — AMLL's
  /// `pause()` / `resume()` likewise call `calcLayout()` (`base.ts:871-887`).
  void setPlaying(bool playing) {
    if (playing == _playing) return;
    _playing = playing;
    _layoutDirty = true;
    _recomputeLayout();
    _emit();
  }

  /// Push the authoritative playback time. Recomputes the active line and, if
  /// it changed, re-flows the layout with the staggered cascade.
  void setCurrentTime(Duration position) {
    _timeMs = position.inMilliseconds.toDouble();
    _lastAuthoritativeMs = _timeMs;
    final int singing = _singingFor(_timeMs);
    if (singing != _singingIndex) {
      _singingIndex = singing;
      // The karaoke gating moved even if the (early-shifted) active line did
      // not — force one emit so the view re-reads [singingIndex] while paused.
      _forceEmit = true;
    }
    final int active = _activeFor(_timeMs);
    if (active != _activeIndex) {
      _activeIndex = active;
      // During the 5s browse-hold keep the column frozen where the user left it
      // instead of re-flowing to the new active line (the staggered cascade at
      // the offset position read as the whole list refreshing). The snap-back
      // glide ([resetUserScroll]) re-centres on the now-current line afterwards.
      if (_followResetPending) {
        _forceEmit = true; // still rebuild so karaoke gating stays live
      } else {
        _layoutDirty = true;
        _recomputeLayout();
      }
    }
  }

  /// Jump to [position] instantly (no cascade, springs snap). Use on user seek.
  void seekTo(Duration position) {
    _userScrollOffset = 0;
    _userScrolling = false;
    _snappingBack = false; // an authoritative jump overrides the snap-back glide
    _followResetPending = false; // ...and any pending browse-hold
    _followResetTimer?.cancel();
    _timeMs = position.inMilliseconds.toDouble();
    _lastAuthoritativeMs = _timeMs;
    _activeIndex = _activeFor(_timeMs);
    _singingIndex = _singingFor(_timeMs);
    _layoutDirty = true;
    _seekPending = true;
    _recomputeLayout();
    _emit();
  }

  // --- user scroll (drag to browse; springs back to the active line ~5s) ---

  /// Begin a manual drag: stop following the active line and cancel any pending
  /// spring-back so the user stays in control. The de-blur (all lines → blur 0)
  /// kicks in on the first [updateUserScroll] — i.e. on real finger movement, not
  /// a tap that merely opens then closes a drag gesture — so taps never flicker.
  void beginUserScroll() {
    _userScrolling = true;
    _snappingBack = false; // a fresh grab cancels any in-flight snap-back glide
    _followResetPending = false; // ...and any pending browse-hold
    _followResetTimer?.cancel();
  }

  /// Drag the lyric column by [dyDelta] logical px. A finger moving DOWN
  /// (positive dy) reveals EARLIER lines. Re-lays out and emits immediately
  /// because ticks suppress emits while paused.
  void updateUserScroll(double dyDelta) {
    _userScrollOffset =
        (_userScrollOffset - dyDelta).clamp(_scrollMin, _scrollMax);
    _layoutDirty = true;
    _recomputeLayout();
    _emit();
  }

  /// End a manual drag: restore the distance-blur targets (they ease back in via
  /// the ticker's 0.2s blur transition) and schedule a spring-back to the active
  /// line after 5s. The 5s offset snap-back is unaffected.
  void endUserScroll({double velocity = 0}) {
    _userScrolling = false;
    // Enter the browse-hold *before* re-laying out so this release recompute —
    // and every active-line change until the snap-back — is a seek-snap (no
    // cascade) that leaves the lines exactly where the user released them; only
    // the distance-blur eases back in. See [_followResetPending].
    _followResetPending = true;
    _layoutDirty = true;
    _recomputeLayout();
    _emit();
    _followResetTimer = Timer(const Duration(seconds: 5), resetUserScroll);
  }

  /// Cancel any manual scroll and **glide** the column back to the active line.
  /// Rather than zeroing the offset and re-running the staggered cascade (which
  /// read as a full top-to-bottom list refresh), this eases the shared offset to
  /// 0 over [_snapBackDuration] from [_onTick] with the cascade suppressed, so the
  /// whole column slides as one block. Normal auto-follow resumes once it lands.
  void resetUserScroll() {
    _followResetTimer?.cancel();
    _userScrolling = false;
    _followResetPending = false;
    // The browse-hold kept the column frozen at the release layout while
    // [_activeIndex] advanced (active-line changes skipped re-layout). Re-anchor
    // the shared offset so a fresh recompute *reproduces* that frozen layout
    // under the now-current anchor: pick the offset that leaves the current
    // active line's anchor target at its present on-screen centre. Because every
    // line's position is the anchor centre plus a fixed height-based offset,
    // matching the active line matches them all — so the glide starts with NO
    // jump and NO re-stagger. Easing this offset to 0 then slides the whole
    // column as one block until the playing line lands at the anchor.
    final int n = _lines.length;
    if (n > 0) {
      final int a = _activeIndex < 0 ? 0 : math.min(_activeIndex, n - 1);
      final double activeCentre = _lines[a].posY.position + _heightOf(a) / 2;
      _userScrollOffset = _size.height * alignPosition - activeCentre;
    }
    // Already home (the playing line is already at the anchor) → nothing to glide.
    if (_userScrollOffset.abs() < 0.5) {
      _userScrollOffset = 0;
      _snappingBack = false;
      return;
    }
    _snapBackFrom = _userScrollOffset;
    _snapBackElapsed = 0;
    _snappingBack = true; // the ticker eases the offset to 0 with no cascade
  }

  // --- pre-shift / active selection ----------------------------------------

  void _computeEffectiveStarts() {
    final List<double> eff = List<double>.filled(_source.length, 0);
    for (int i = 0; i < _source.length; i++) {
      final double start = _source[i].start.inMilliseconds.toDouble();
      double shifted = start - earlyStartMs;
      if (i > 0) {
        final double prevEnd = _source[i - 1].end.inMilliseconds.toDouble();
        if (shifted < prevEnd) shifted = prevEnd;
      }
      if (shifted < 0) shifted = 0;
      eff[i] = shifted;
    }
    _effStartMs = eff;
  }

  int _activeFor(double timeMs) {
    int idx = -1;
    for (int i = 0; i < _effStartMs.length; i++) {
      if (_effStartMs[i] <= timeMs) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  /// Last line whose **raw** [LyricLine.start] ≤ [timeMs] — no early shift and
  /// no prev-end clamp. Mirrors [_activeFor] on the unshifted start times so it
  /// tracks the line actually being sung. [_source] is sorted by start, so the
  /// first future line ends the scan.
  int _singingFor(double timeMs) {
    int idx = -1;
    for (int i = 0; i < _source.length; i++) {
      if (_source[i].start.inMilliseconds <= timeMs) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  // --- layout (Y accumulator + cascade + styling) --------------------------

  void _recomputeLayout() {
    if (!_layoutDirty) return;
    _layoutDirty = false;
    final int n = _lines.length;
    if (n == 0) return;

    // Manual scrolling snaps Y/scale to the finger like a seek (no cascade). The
    // posY spring is left at its constant underdamped default (`SpringParams.posY`
    // 0.9/15/90) — AMLL never retunes it per line — so line-to-line motion stays
    // lively. [seekSnap] is the *true* seek (captured before `_seekPending` is
    // cleared): only it snaps blur. A manual drag instead lets blur EASE to 0
    // (see `_blurTargetFor`) so lines de-blur while dragged and re-blur on release.
    final bool seekSnap = _seekPending;
    // The auto snap-back glide also suppresses the cascade and snaps Y/scale to
    // the (eased) shared offset each frame so the column travels as one rigid
    // block — but it is NOT a [seekSnap], so blur keeps easing rather than
    // hard-cutting.
    final bool seeking = _seekPending ||
        _userScrolling ||
        _snappingBack ||
        _followResetPending;
    _seekPending = false;

    final int anchor = _activeIndex < 0 ? 0 : math.min(_activeIndex, n - 1);

    // Y accumulator: active line anchored at `alignPosition` of the height,
    // shifted by any manual user-scroll offset.
    double curPos = _size.height * alignPosition - _userScrollOffset;
    double sumAbove = 0;
    for (int i = 0; i < anchor; i++) {
      final double h = _heightOf(i);
      curPos -= h;
      sumAbove += h;
    }
    // Anchor the active line's CENTER (not its top) at `alignPosition` — AMLL
    // `base.ts:710,716-725` (`curPos += height*alignPosition; curPos -=
    // lineHeight/2`, default alignAnchor "center"). Without this the active line
    // sits ~½ a line too low.
    curPos -= _heightOf(anchor) / 2;

    // Cascade stagger ("flow").
    double delay = 0;
    double baseDelay = seeking ? 0 : 0.05;

    for (int i = 0; i < n; i++) {
      final _Line ln = _lines[i];
      final double targetY = curPos;

      ln.pendingY = targetY;
      ln.pendingScale = _scaleTargetFor(i);

      // Opacity / blur are fixed-duration eased transitions; reset the easing
      // (from the current value) whenever the target changes so they arrive on
      // time instead of forever approaching.
      final double nextOpacity = _opacityTargetFor(i);
      if (nextOpacity != ln.targetOpacity) {
        ln.opacityFrom = ln.opacity;
        ln.opacityT = 0;
        ln.targetOpacity = nextOpacity;
      }
      final double nextBlur = _blurTargetFor(i, n);
      if (nextBlur != ln.targetBlur) {
        ln.blurFrom = ln.blur;
        ln.blurT = 0;
        ln.targetBlur = nextBlur;
      }

      ln.delaySeconds = seeking ? 0 : delay;
      ln.delayTimer = seeking ? 0 : delay;

      if (seeking) {
        // Instant: snap Y/scale (and opacity) to the finger, no spring/cascade.
        ln.posY.snapTo(targetY);
        ln.scale.snapTo(ln.pendingScale);
        ln.appliedY = targetY;
        ln.appliedScale = ln.pendingScale;
        ln.opacity = ln.targetOpacity;
        ln.opacityFrom = ln.targetOpacity;
        ln.opacityT = _opacityDuration;
        // Blur snaps ONLY on a true seek. During a manual drag it instead eases
        // (the blurFrom/blurT reset above + the ticker's 0.2s transition) so
        // lines de-blur as the drag starts and re-blur on release — AMLL removes
        // only the filter while interacting (`&:hover .lyricLine{filter:unset}`).
        if (seekSnap) {
          ln.blur = ln.targetBlur;
          ln.blurFrom = ln.targetBlur;
          ln.blurT = _blurDuration;
        }
      } else if (targetY >= 0) {
        if (!ln.isBackground) delay += baseDelay;
        if (i >= anchor) baseDelay /= 1.05;
      }

      curPos += _heightOf(i);
    }

    // Scroll bounds: pull earlier lines into view (min = -heights above the
    // anchor) or later lines up (max = a little past the last line). Generous —
    // exact values don't matter, this just keeps drags from running off-screen.
    _scrollMin = -sumAbove;
    _scrollMax = math.max(0.0, curPos + _userScrollOffset - _size.height / 2);

    _forceEmit = true;
  }

  double _heightOf(int i) {
    final double h = _lines[i].height;
    return h > 0 ? h : _fallbackLineHeight;
  }

  double _scaleTargetFor(int i) {
    if (i == _activeIndex) return 100;
    // The inactive-line shrink (75 for background, 97 for normal) applies ONLY
    // while playing; paused, every line returns to full scale — AMLL
    // `base.ts:789-797` (`let targetScale = 100; if (!isActive && this.isPlaying)
    // { … }`).
    if (!_playing) return 100;
    if (_lines[i].isBackground) return 75;
    return enableScale ? 97 : 100;
  }

  double _opacityTargetFor(int i) {
    if (hidePassedLines && i < _activeIndex) return 0.00001;
    if (i == _activeIndex) return 0.85;
    return _lines[i].isWordByWord ? 1.0 : 0.2;
  }

  double _blurTargetFor(int i, int n) {
    if (!enableBlur) return 0;
    // While the user is dragging the lyric column every line targets blur 0 —
    // AMLL removes ONLY the `filter` while interacting (`lyric-player.module.css`
    // `&:hover .lyricLine{ filter: unset !important; }`); dimming/opacity stay.
    if (_userScrolling) return 0;
    if (i == _activeIndex) return 0;
    final int latest = _activeIndex < 0 ? 0 : _activeIndex;
    double blur = 1;
    if (i < latest) {
      blur += (latest - i) + 1; // above the active line
    } else {
      blur += (i - latest); // below (latest buffered == active here)
    }
    if (_size.width <= 1024) blur *= 0.8; // AMLL isCompact (narrow screens)
    // AMLL caps the on-screen blur at 32px (`dom/lyric-line.ts:316,876`
    // `Math.min(32, this.blur)`). We clamp lower — 12px — for a deeper AMLL
    // "fog" on distant lines while staying legible on mobile (the +1px/distance
    // ramp and the narrow-screen ×0.8 above are kept).
    return blur.clamp(0.0, 12.0);
  }

  // --- frame tick ----------------------------------------------------------

  void _onTick(Duration elapsed) {
    final double dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (_lines.isEmpty) return;

    // Clamp the frame delta up front (≤100ms). A long stall — e.g. the app
    // backgrounded — must not let interpolated playback time leap many lines at
    // once (which would replay the fly-up cascade on resume); the authoritative
    // position re-syncs via [seekTo] when the view sees the large jump.
    final double clamped = dt > 0.1 ? 0.1 : dt;

    // Auto snap-back glide: ease the shared column offset to 0 (eased), then
    // re-lay out with the cascade suppressed (the `_snappingBack` arm of
    // `seeking` snaps every line's posY/scale to the shifted target) so the whole
    // column slides as one rigid block to the active line — no per-line restagger.
    // Cleared only after the final (offset-0) recompute so the landing frame is
    // still cascade-free; the next normal layout change re-enables auto-follow.
    if (_snappingBack) {
      _snapBackElapsed += clamped;
      final double p = (_snapBackElapsed / _snapBackDuration).clamp(0.0, 1.0);
      _userScrollOffset =
          lerpDouble(_snapBackFrom, 0, Curves.easeOutCubic.transform(p))!;
      _layoutDirty = true;
      _recomputeLayout();
      _forceEmit = true;
      if (p >= 1.0) {
        _userScrollOffset = 0;
        _snappingBack = false;
      }
    }

    // Interpolate playback time between the discrete position pushes, but never
    // lead the last authoritative audio time by more than [_maxLeadMs] (≈ one
    // push interval) — otherwise the sweep races ahead during a sparse-push gap
    // and visibly snaps back when the next push lands. (Paused: `_playing` is
    // false so time is held verbatim.)
    if (_playing) {
      _timeMs =
          math.min(_timeMs + clamped * 1000, _lastAuthoritativeMs + _maxLeadMs);
      _singingIndex = _singingFor(_timeMs); // emits every frame while playing
      final int active = _activeFor(_timeMs);
      if (active != _activeIndex) {
        _activeIndex = active;
        // Browse-hold: keep the column frozen where the user left it (the
        // snap-back glide re-centres later). Otherwise re-flow to the new line.
        if (!_followResetPending) {
          _layoutDirty = true;
          _recomputeLayout();
        }
      }
    }

    bool stillAnimating = false;

    for (final _Line ln in _lines) {
      if (ln.delayTimer > 0) {
        ln.delayTimer = math.max(0, ln.delayTimer - clamped);
        stillAnimating = true;
      }
      if (ln.delayTimer <= 0) {
        if (ln.pendingY != ln.appliedY) {
          ln.posY.setTarget(ln.pendingY);
          ln.appliedY = ln.pendingY;
        }
      }
      // Scale retargets IMMEDIATELY — it is NOT held by the cascade delay. AMLL
      // staggers only posY (the CSS `transition-delay` rides translateY), while
      // scale springs toward its target at once: `dom/lyric-line.ts:899-900`
      // (`posY.setTargetPosition(top, delay)` vs `scale.setTargetPosition(scale)`
      // with no delay). Gating scale on the timer made the brighten/shrink lag
      // the lift.
      if (ln.pendingScale != ln.appliedScale) {
        ln.scale.setTarget(ln.pendingScale);
        ln.appliedScale = ln.pendingScale;
      }

      if (enableSpring) {
        ln.posY.update(clamped);
        ln.scale.update(clamped);
      } else {
        if (ln.delayTimer <= 0) {
          ln.posY.setPosition(ln.pendingY);
          ln.scale.setPosition(ln.pendingScale);
        }
      }

      // Opacity / blur: fixed-duration eased transitions that COMPLETE at the
      // nominal time (CSS `transition: opacity .25s; filter .2s`, default ease).
      if (ln.opacityT < _opacityDuration) {
        ln.opacityT += clamped;
        final double p = (ln.opacityT / _opacityDuration).clamp(0.0, 1.0);
        ln.opacity = lerpDouble(
            ln.opacityFrom, ln.targetOpacity, Curves.ease.transform(p))!;
      }
      if (ln.blurT < _blurDuration) {
        ln.blurT += clamped;
        final double p = (ln.blurT / _blurDuration).clamp(0.0, 1.0);
        ln.blur =
            lerpDouble(ln.blurFrom, ln.targetBlur, Curves.ease.transform(p))!;
      }

      if (!ln.posY.arrived ||
          !ln.scale.arrived ||
          (ln.opacity - ln.targetOpacity).abs() > 1e-3 ||
          (ln.blur - ln.targetBlur).abs() > 1e-2) {
        stillAnimating = true;
      }
    }

    // Avoid rebuilding the line stack every frame once everything has settled
    // and playback is paused. While playing we always emit so the karaoke
    // sweep + emphasis stay live. While the view is fully hidden (player mode)
    // skip the rebuild entirely — the springs still advance above, but the
    // invisible stack isn't reflowed; becoming visible ([setHidden] false)
    // emits the current state at once.
    if (!_hidden && (_playing || stillAnimating || _forceEmit)) {
      _forceEmit = false;
      _emit();
    }
  }

  void _emit() {
    final List<LyricLineRender> out =
        List<LyricLineRender>.filled(_lines.length, _empty, growable: false);
    for (int i = 0; i < _lines.length; i++) {
      final _Line ln = _lines[i];
      final double scalePercent = ln.scale.position;
      // Brightness differentiator for the karaoke bright/dark mask. While PLAYING
      // it eases off the scale spring (active line 100 → 1, inactive 97 → 0) so it
      // glides on hand-off. But PAUSED, AMLL returns EVERY line to scale 100
      // ([_scaleTargetFor]) — which would drive this to 1 for all lines and light
      // up every already-sung line (the "暂停后进歌词页整段亮起" bug). So when paused
      // derive it from active-ness directly; the settled play values match
      // (active≈1 / inactive≈0), so play↔pause is seamless.
      final double s = _playing
          ? ((scalePercent / 100 - 0.97) / 0.03).clamp(0.0, 1.0)
          : (i == _activeIndex ? 1.0 : 0.0);
      out[i] = LyricLineRender(
        index: i,
        y: ln.posY.position,
        scale: scalePercent / 100,
        opacity: ln.opacity.clamp(0.0, 1.0),
        blur: ln.blur < 0 ? 0 : ln.blur,
        brightMaskAlpha: s * 0.8 + 0.2,
        darkMaskAlpha: s * 0.2 + 0.2,
        delaySeconds: ln.delaySeconds,
      );
    }
    _renderLines = out;
    notifyListeners();
  }

  static const LyricLineRender _empty = LyricLineRender(
    index: 0,
    y: 0,
    scale: 1,
    opacity: 0,
    blur: 0,
    brightMaskAlpha: 0.2,
    darkMaskAlpha: 0.2,
    delaySeconds: 0,
  );

  @override
  void dispose() {
    _followResetTimer?.cancel();
    _ticker.dispose();
    super.dispose();
  }
}
