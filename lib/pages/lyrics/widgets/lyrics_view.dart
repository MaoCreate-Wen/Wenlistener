import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../animation/interlude_dots.dart';
import '../../../animation/lyric_line_render.dart';
import '../../../animation/lyric_player_controller.dart';
import '../../../models/lyric_line.dart';
import '../../../state/player_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_dimens.dart';
import '../../../theme/app_typography.dart';
import 'karaoke_text.dart';
import 'lyric_line_widget.dart';

/// The reusable AMLL lyric stack: a self-contained, absolutely-positioned
/// karaoke view driven by a private [LyricPlayerController] that it feeds from
/// [PlayerProvider] every frame. Ported unchanged from the mobile app (same AMLL
/// engine numbers) with one desktop addition — an [alignPosition] knob so the
/// bright active line can sit centred in a full-height right pane rather than the
/// mobile top-third default.
///
/// It renders **no** header / background / artwork — the host page supplies
/// those. Used both by the full-bleed `/lyrics` page and by the right-hand pane
/// of the two-pane `/player`.
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: AppDimens.space24),
    this.mainStyle,
    this.translationStyle,
    this.showInterludeDots = true,
    this.alignPosition = 0.42,
    this.onTapLine,
  });

  final EdgeInsets padding;
  final TextStyle? mainStyle;
  final TextStyle? translationStyle;
  final bool showInterludeDots;

  /// Fraction of the view height the active line is anchored at (AMLL
  /// `alignPosition`; 0.35 mobile top-third, ~0.42–0.5 to centre it on desktop).
  final double alignPosition;

  /// Tapping a line; null → seek playback (and the lyric layout) to its start.
  final ValueChanged<int>? onTapLine;

  // The app's calligraphic display face (阿里妈妈东方大楷). Single-weight (w400);
  // desktop bumps the size a touch over mobile (29 → 30) for the wide canvas.
  static const TextStyle defaultMainStyle = TextStyle(
    fontFamily: AppTypography.displayFont,
    fontSize: 30,
    height: 1.22,
    fontWeight: FontWeight.w400,
    color: AppColors.onSurface,
  );
  static const TextStyle defaultTranslationStyle = TextStyle(
    fontSize: 15,
    height: 1.32,
    letterSpacing: -0.1,
    color: AppColors.onSurfaceMuted,
    fontWeight: FontWeight.w500,
  );

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final LyricPlayerController _controller =
      LyricPlayerController(vsync: this);

  PlayerProvider? _provider;
  bool _subscribed = false;

  List<LyricLine> _lines = const <LyricLine>[];
  double _lastPosMs = 0;

  // Layout-sync memo (avoid re-measuring / re-pushing every frame).
  Size? _syncedSize;
  List<LyricLine>? _syncedLines;

  // --- static-line widget cache ---------------------------------------------
  // The controller notifies every vsync while playing, but only the SINGING
  // line's content actually depends on per-frame time. Every other line's
  // subtree is cached here and handed back REFERENCE-IDENTICAL frame after
  // frame, so Flutter short-circuits its rebuild (`child.widget == newWidget`)
  // and its RepaintBoundary layer is reused untouched — per-frame y motion and
  // the handoff/pause scale springs ride a Positioned + Transform SHELL that
  // lives outside the cached boundary. A line rebuilds only when its visual
  // key (folded alpha / blur bucket / passed flag) changes — i.e. during its
  // own 0.2–0.25s opacity/blur ease or the karaoke "passed" flip.
  List<Widget?> _staticContent = <Widget?>[];
  List<_StaticLineKey?> _staticKeys = <_StaticLineKey?>[];

  void _invalidateStaticLines() {
    _staticContent = List<Widget?>.filled(_lines.length, null);
    _staticKeys = List<_StaticLineKey?>.filled(_lines.length, null);
  }

  // Vertical padding above/below each line (half the inter-line gap). 22 gives
  // the roomier AMLL-like air between lines (was 14, which read cramped once the
  // per-word float rise was enlarged); [_measureHeights] adds `2 ×` this to every
  // measured line height, so the controller's Y accumulator stays exact.
  static const double _lineVPadding = 22;

  // B2 — the live, viewport-scaled main-line font size (AMLL `core/index.css:14`
  // `max(max(5vh,2.5vw),12px)`), recomputed every build from the window size so
  // the lyrics grow on a big/fullscreen window instead of sitting at a fixed
  // 30px. Null until the first build resolves it.
  double? _resolvedMainFontSize;

  /// AMLL responsive lyric font: narrow panes key off width (`8vw`), wider ones
  /// off the larger of `5vh` / `2.5vw`, both floored at 12px so a small window
  /// stays legible while a fullscreen one scales up to target.png proportions.
  double _lyricFontSize(Size window) {
    if (window.width < 768) {
      return math.max(0.08 * window.width, 12);
    }
    return math.max(math.max(0.05 * window.height, 0.025 * window.width), 12);
  }

  // The caller supplies the face (family / weight / colour); B2 overrides only
  // the size with the responsive value so both callers scale identically.
  TextStyle get _mainStyle {
    final TextStyle base = widget.mainStyle ?? LyricsView.defaultMainStyle;
    final double size = _resolvedMainFontSize ?? base.fontSize ?? 30;
    return base.copyWith(fontSize: size);
  }

  // Translation / sub line = 0.5em of the (scaled) main line (AMLL
  // `lyric-player.module.css:137`), so it tracks the main font up and down.
  TextStyle get _translationStyle {
    final TextStyle base =
        widget.translationStyle ?? LyricsView.defaultTranslationStyle;
    final double main = _resolvedMainFontSize ?? 30;
    return base.copyWith(fontSize: main * 0.5);
  }

  double get _padL => widget.padding.left;
  double get _padR => widget.padding.right;

  @override
  void initState() {
    super.initState();
    _controller.alignPosition = widget.alignPosition;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.alignPosition != widget.alignPosition) {
      _controller.alignPosition = widget.alignPosition;
    }
    if (oldWidget.mainStyle != widget.mainStyle ||
        oldWidget.translationStyle != widget.translationStyle) {
      _invalidateStaticLines();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_subscribed) {
      _provider = context.read<PlayerProvider>();
      _provider!.addListener(_onProvider);
      _subscribed = true;
      _onProvider();
      // Re-opening lyrics after an earlier transient failure: re-attempt the
      // fetch if we landed with no lines (no-op if lyrics are present/settled).
      if (_lines.isEmpty) _provider!.retryLyrics();
    }
  }

  void _onProvider() {
    final PlayerProvider p = _provider!;
    if (!identical(p.lyrics.lines, _lines)) {
      _lines = p.lyrics.lines;
      // The song id keys the controller clock: on a track switch the clock is
      // zeroed inside setLines so the fresh lines can never render against the
      // OLD track's large position (which briefly lit every "passed" word +
      // glow before the new ~0 position landed). The position push below (same
      // synchronous call, before any frame builds) then restores the live time.
      _controller.setLines(_lines, trackKey: p.currentSong?.id);
      _syncedLines = null; // force a re-measure
      _invalidateStaticLines();
    }
    _controller.setPlaying(p.isPlaying);

    final double posMs = p.position.inMilliseconds.toDouble();
    final double delta = posMs - _lastPosMs;
    // Large backward / forward jump → treat as a seek (snap, no cascade).
    if (delta < -200 || delta > 1500) {
      _controller.seekTo(p.position);
    } else {
      _controller.setCurrentTime(p.position);
    }
    _lastPosMs = posMs;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final PlayerProvider? p = _provider;
    if (state == AppLifecycleState.resumed && p != null) {
      _controller.seekTo(p.position);
      _lastPosMs = p.position.inMilliseconds.toDouble();
      if (_lines.isEmpty) p.retryLyrics();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _provider?.removeListener(_onProvider);
    _controller.dispose();
    super.dispose();
  }

  // --- layout sync ---------------------------------------------------------

  void _syncLayout(Size size) {
    final bool sizeChanged = _syncedSize != size;
    final bool linesChanged = !identical(_syncedLines, _lines);
    if (!sizeChanged && !linesChanged) return;
    _syncedSize = size;
    _syncedLines = _lines;

    final double textWidth = size.width - _padL - _padR;
    final List<double> heights = _measureHeights(textWidth);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.setLineHeights(heights);
      _controller.resize(size);
    });
  }

  List<double> _measureHeights(double maxWidth) {
    final List<double> out = <double>[];
    for (final LyricLine line in _lines) {
      double h = line.isWordByWord
          ? _measureWordLineHeight(line, maxWidth)
          : (TextPainter(
              text: TextSpan(
                text: line.text.isEmpty ? ' ' : line.text,
                style: _mainStyle,
              ),
              textDirection: TextDirection.ltr,
              maxLines: 4,
            )..layout(maxWidth: maxWidth))
              .height;
      if ((line.translation ?? '').isNotEmpty) {
        final TextPainter tt = TextPainter(
          text: TextSpan(text: line.translation, style: _translationStyle),
          textDirection: TextDirection.ltr,
          maxLines: 3,
        )..layout(maxWidth: maxWidth);
        h += tt.height + 4;
      }
      out.add(h + _lineVPadding * 2);
    }
    return out;
  }

  /// Height of a word-by-word line measured the way [_wordsWrap] lays it out.
  double _measureWordLineHeight(LyricLine line, double maxWidth) {
    final TextPainter tp = TextPainter(textDirection: TextDirection.ltr);
    tp.text = TextSpan(text: 'Ag', style: _mainStyle);
    tp.layout();
    final double lineHeight = tp.height;
    if (maxWidth <= 0 || line.words.isEmpty) return lineHeight;

    int runs = 0;
    double runWidth = 0;
    for (final LyricWord word in line.words) {
      if (word.text.isEmpty) continue;
      tp.text = TextSpan(text: word.text, style: _mainStyle);
      tp.layout();
      final double w = tp.width;
      if (runWidth > 0 && runWidth + w > maxWidth) {
        runs++;
        runWidth = 0;
      }
      runWidth += w;
    }
    if (runWidth > 0) runs++;
    return (runs < 1 ? 1 : runs) * lineHeight;
  }

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.of(context).disableAnimations;

    // B2 — resolve the viewport-scaled main font BEFORE any layout/measure below
    // (both `_measureHeights` and the line widgets read `_mainStyle`). When it
    // changes, drop the height memo so lines are re-measured at the new size.
    final double fs = _lyricFontSize(MediaQuery.sizeOf(context));
    if (_resolvedMainFontSize != fs) {
      _resolvedMainFontSize = fs;
      _syncedLines = null;
      _invalidateStaticLines(); // cached content bakes the resolved font size
    }

    // NARROW selects — the old `context.watch<PlayerProvider>()` here made the
    // ENTIRE view (LayoutBuilder + _syncLayout + Stack + the inner
    // ListenableBuilder) rebuild on every position tick, doubling the per-frame
    // widget work on top of the controller's own per-frame ListenableBuilder.
    // None of the fields build() actually reads change per tick, so we depend on
    // exactly those getters instead. The live position / isPlaying / lines feed
    // reaches the controller through [_onProvider] (a direct addListener in
    // didChangeDependencies), NOT through build — so the karaoke sweep is
    // untouched; the per-frame rebuild now comes solely from the controller's
    // isolated ListenableBuilder in [_animatedLyrics].

    // Spinner only on the first-ever load (no lines to show yet); on a
    // song-to-song switch the previous lines stay on screen until the new ones
    // swap in (AMLL never flashes a loading state between tracks).
    final bool lyricsLoading = context
        .select<PlayerProvider, bool>((PlayerProvider p) => p.lyricsLoading);
    if (lyricsLoading && _lines.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_lines.isEmpty) {
      final bool lyricsSettled = context
          .select<PlayerProvider, bool>((PlayerProvider p) => p.lyricsSettled);
      if (!lyricsSettled) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      return _empty();
    }
    if (reduceMotion) {
      // Only the reduced-motion static list needs the per-line active index; the
      // animated path never reads it (it highlights off the controller), so this
      // select is scoped to this branch and never re-runs build() otherwise.
      final int activeIndex = context.select<PlayerProvider, int>(
          (PlayerProvider p) => p.activeLyricIndex);
      return _StaticLyrics(
        lines: _lines,
        activeIndex: activeIndex,
        mainStyle: _mainStyle,
        translationStyle: _translationStyle,
        padding: widget.padding,
        onSeek: _seekToLine,
      );
    }
    // Interlude-dot colour — changes per song, not per tick. Passed down instead
    // of the whole provider so the animated subtree carries no live dependency.
    final Color accent = context
        .select<PlayerProvider, Color>((PlayerProvider p) => p.dynamicAccent);
    return _animatedLyrics(accent);
  }

  Widget _animatedLyrics(Color accent) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        _syncLayout(size);
        // Vertical drag browses the lyric column (the controller springs it back
        // to the sung line after ~5s); tap seeks to a line. On desktop a mouse
        // wheel / trackpad scroll also browses.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => _controller.beginUserScroll(),
          onVerticalDragUpdate: (DragUpdateDetails d) =>
              _controller.updateUserScroll(d.delta.dy),
          onVerticalDragEnd: (DragEndDetails d) =>
              _controller.endUserScroll(velocity: d.primaryVelocity ?? 0),
          onTapUp: (TapUpDetails details) {
            final int i = _lineAtY(details.localPosition.dy);
            if (i >= 0) _seekToLine(i);
          },
          child: Listener(
            onPointerSignal: (PointerSignalEvent e) {
              if (e is PointerScrollEvent) {
                _controller.beginUserScroll();
                _controller.updateUserScroll(-e.scrollDelta.dy);
                _controller.endUserScroll();
              }
            },
            // RepaintBoundary so the per-frame Stack repaint (the only thing
            // that legitimately changes every tick) is composited in its own
            // layer and never dirties the host page / background above it.
            child: ClipRect(
              child: RepaintBoundary(
                child: ListenableBuilder(
                  listenable: _controller,
                  builder: (BuildContext context, Widget? _) {
                    final List<LyricLineRender> renders =
                        _controller.renderLines;
                    final int active = _controller.activeIndex;
                    final int singing = _controller.singingIndex;
                    return Stack(
                      children: <Widget>[
                        ..._lineWidgets(renders, singing, size.height),
                        if (widget.showInterludeDots)
                          ..._interlude(active, accent),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _lineWidgets(
    List<LyricLineRender> renders,
    int singing,
    double viewportHeight,
  ) {
    const double margin = 320;
    final double timeMs = _controller.currentTimeMs;
    final int n =
        renders.length < _lines.length ? renders.length : _lines.length;
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < n; i++) {
      final double top = renders[i].y;
      final double bottom =
          (i + 1 < renders.length) ? renders[i + 1].y : top + 240;
      if (bottom < -margin || top > viewportHeight + margin) continue;
      final LyricLineRender render = renders[i];
      // The singing line carries per-frame content (the karaoke sweep / float /
      // emphasis) — it keeps the full mobile-verbatim path, rebuilt every
      // frame. A JUST-passed line stays on that live path a moment longer
      // (until [karaokeTailEndMs]) so its per-word float rises land at their
      // rest offset and any held word's emphasis/glow tail plays out, instead
      // of being frozen mid-flight by the static swap the instant the next
      // line starts (which visibly dropped every risen word back to the
      // baseline). Its sweep is already full, so only one MOVING sweep ever
      // exists. Every other line is a reference-cached subtree whose per-frame
      // motion (y + scale) rides this cheap shell instead, so its layer never
      // re-records. The ValueKey pins each line's element when the on-screen
      // window shifts, so cached instances short-circuit by identity rather
      // than being re-inflated at a new child slot.
      final LyricLine line = _lines[i];
      final bool floatTail = i != singing &&
          line.isWordByWord &&
          timeMs >= line.end.inMilliseconds &&
          timeMs < karaokeTailEndMs(line);
      final Widget child = i == singing || floatTail
          ? LyricLineWidget(
              line: line,
              render: render,
              currentTimeMs: timeMs,
              mainStyle: _mainStyle,
              translationStyle: _translationStyle,
              wordFadeWidth: _controller.wordFadeWidth,
              isActive: true,
            )
          // Scale about the left edge, matching LyricLineWidget's
          // transform-origin (AMLL), but OUTSIDE the cached RepaintBoundary.
          : Transform.scale(
              scale: render.scale,
              alignment: Alignment.centerLeft,
              child: _staticLine(i, render, timeMs),
            );
      out.add(
        Positioned(
          key: ValueKey<int>(i),
          top: top,
          left: _padL,
          right: _padR,
          child: child,
        ),
      );
    }
    return out;
  }

  /// The cached widget for non-singing line [i], rebuilt only when its visual
  /// key — folded alpha, blur bucket, karaoke "passed" flip — changes (its
  /// 0.2–0.25s opacity/blur eases), NOT on every controller tick. All alphas
  /// are quantized to 8-bit (what the rasterizer paints anyway) and the blur
  /// sigma to 0.25px buckets so a settled line's key is frame-stable.
  Widget _staticLine(int i, LyricLineRender render, double timeMs) {
    if (_staticContent.length != _lines.length) _invalidateStaticLines();
    final LyricLine line = _lines[i];
    final double opacity = render.opacity.clamp(0.0, 1.0);
    // The karaoke flat ink — the exact composite KaraokeText's non-singing
    // branch paints: once a line has passed, the (full-width) bright sweep sits
    // OVER the dark base, i.e. `1-(1-b)(1-d)`; while upcoming only the dark
    // base shows. Matching the live stack keeps the live→static swap at the
    // float-tail end pixel-continuous.
    final bool passed = timeMs >= line.end.inMilliseconds;
    final double flat = passed
        ? 1 -
            (1 - render.brightMaskAlpha.clamp(0.0, 1.0)) *
                (1 - render.darkMaskAlpha.clamp(0.0, 1.0))
        : render.darkMaskAlpha;
    // Fold the line-level opacity into the paint alphas (see StaticLyricLine).
    final double mainAlpha = (line.isWordByWord ? flat : 1.0) * opacity;
    final double translationAlpha =
        (_translationStyle.color ?? AppColors.onSurfaceMuted).a * opacity;
    // Passed word-by-word lines rest at the float's fill-forwards offset; the
    // white edge ring's fade tail (`s`, folded with opacity) rides along so the
    // handoff fade completes seamlessly on the cached path.
    final double floatDy = passed && line.isWordByWord
        ? karaokeRestDy(line, _mainStyle.fontSize ?? 30)
        : 0.0;
    final double s =
        ((render.brightMaskAlpha - 0.2) / 0.8).clamp(0.0, 1.0).toDouble();
    final double edgeAlpha = s * opacity;
    final _StaticLineKey key = (
      mainAlpha8: (mainAlpha * 255).round(),
      translationAlpha8: (translationAlpha * 255).round(),
      sigmaQ4: render.blur <= 0 ? 0 : (render.blur * 4).round(),
      floatDyQ4: (floatDy * 4).round(),
      edgeAlpha8: (edgeAlpha * 255).round(),
    );
    final Widget? cached = _staticContent[i];
    if (cached != null && _staticKeys[i] == key) return cached;
    final Widget built = StaticLyricLine(
      line: line,
      mainStyle: _mainStyle,
      translationStyle: _translationStyle,
      mainAlpha: key.mainAlpha8 / 255.0,
      translationAlpha: key.translationAlpha8 / 255.0,
      blurSigma: key.sigmaQ4 / 4.0,
      floatDy: key.floatDyQ4 / 4.0,
      edgeAlpha: key.edgeAlpha8 / 255.0,
    );
    _staticContent[i] = built;
    _staticKeys[i] = key;
    return built;
  }

  int _lineAtY(double dy) {
    final List<LyricLineRender> renders = _controller.renderLines;
    if (renders.isEmpty) return -1;
    for (int i = 0; i < renders.length; i++) {
      final double top = renders[i].y;
      final double bottom =
          i + 1 < renders.length ? renders[i + 1].y : double.infinity;
      if (dy >= top && dy < bottom) return i;
    }
    return dy < renders.first.y ? 0 : renders.length - 1;
  }

  List<Widget> _interlude(int active, Color accent) {
    final List<LyricLineRender> renders = _controller.renderLines;
    if (_lines.isEmpty || renders.isEmpty) return const <Widget>[];

    if (active < 0) {
      final LyricLine first = _lines.first;
      if (first.start < InterludeDots.minGap) return const <Widget>[];
      return _interludeDots(
        gap: first.start,
        accent: accent,
        yNext: renders.first.y,
        keyIndex: -1,
      );
    }

    if (active >= _lines.length - 1) return const <Widget>[];
    final LyricLine current = _lines[active];
    final LyricLine next = _lines[active + 1];
    final Duration gap = next.start - current.end;
    if (gap < InterludeDots.minGap) return const <Widget>[];

    final double sinceEnd =
        _controller.currentTimeMs - current.end.inMilliseconds;
    if (sinceEnd < 0) return const <Widget>[];
    if (active + 1 >= renders.length) return const <Widget>[];

    return _interludeDots(
      gap: gap,
      accent: accent,
      yNext: renders[active + 1].y,
      keyIndex: active,
    );
  }

  List<Widget> _interludeDots({
    required Duration gap,
    required Color accent,
    required double yNext,
    required int keyIndex,
  }) {
    const double gapHeight = _lineVPadding * 2;
    const double minMargin = 9;
    final double dotsHeight =
        (gapHeight - minMargin * 2).clamp(6.0, 12.0).toDouble();
    final double top = (yNext - gapHeight) + (gapHeight - dotsHeight) / 2;

    return <Widget>[
      Positioned(
        top: top,
        left: _padL,
        child: InterludeDots(
          key: ValueKey<int>(keyIndex),
          gapDuration: gap,
          color: accent,
          dotSize: dotsHeight,
        ),
      ),
    ];
  }

  Widget _empty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.lyrics_outlined,
                size: 56, color: AppColors.onSurfaceFaint),
            const SizedBox(height: AppDimens.space12),
            Text('暂无歌词', style: AppTypography.label),
          ],
        ),
      );

  void _seekToLine(int index) {
    if (index < 0 || index >= _lines.length) return;
    final Duration target = _lines[index].start;
    _controller.resetUserScroll();
    _controller.seekTo(target);
    final ValueChanged<int>? cb = widget.onTapLine;
    if (cb != null) {
      cb(index);
    } else {
      _provider?.seek(target);
    }
  }
}

/// Visual state of a cached non-singing line (see `_LyricsViewState._staticLine`):
/// 8-bit folded paint alphas, the 0.25px blur bucket (`sigma × 4`), the
/// quarter-px float rest offset and the 8-bit edge-ring alpha. Equal key ⇒
/// identical pixels ⇒ the cached widget instance is handed back.
typedef _StaticLineKey = ({
  int mainAlpha8,
  int translationAlpha8,
  int sigmaQ4,
  int floatDyQ4,
  int edgeAlpha8,
});

/// Reduced-motion fallback: a plain scrolling list that highlights the active
/// line (no springs, karaoke sweep or blur).
class _StaticLyrics extends StatefulWidget {
  final List<LyricLine> lines;
  final int activeIndex;
  final TextStyle mainStyle;
  final TextStyle translationStyle;
  final EdgeInsets padding;
  final void Function(int index) onSeek;

  const _StaticLyrics({
    required this.lines,
    required this.activeIndex,
    required this.mainStyle,
    required this.translationStyle,
    required this.padding,
    required this.onSeek,
  });

  @override
  State<_StaticLyrics> createState() => _StaticLyricsState();
}

class _StaticLyricsState extends State<_StaticLyrics> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(_StaticLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex) {
      _scrollToActive();
    }
  }

  void _scrollToActive() {
    if (!_scroll.hasClients || widget.activeIndex < 0) return;
    final double target = (widget.activeIndex * 72.0 - 200)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.symmetric(
        horizontal: widget.padding.left,
        vertical: AppDimens.space48,
      ),
      itemCount: widget.lines.length,
      itemBuilder: (BuildContext context, int index) {
        final bool active = index == widget.activeIndex;
        final LyricLine line = widget.lines[index];
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSeek(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  line.text,
                  style: widget.mainStyle.copyWith(
                    color: active
                        ? AppColors.onSurface
                        : AppColors.onSurface.withValues(alpha: 0.4),
                  ),
                ),
                if ((line.translation ?? '').isNotEmpty)
                  Text(line.translation!, style: widget.translationStyle),
              ],
            ),
          ),
        );
      },
    );
  }
}
