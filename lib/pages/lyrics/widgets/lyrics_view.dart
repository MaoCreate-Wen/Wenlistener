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
import 'lyric_line_widget.dart';

/// The reusable AMLL lyric stack: a self-contained, absolutely-positioned
/// karaoke view driven by a private [LyricPlayerController] that it feeds from
/// [PlayerProvider] every frame.
///
/// It renders **no** header / background / artwork — the host page supplies
/// those, which keeps the shared `album_art` Hero unique per route. Used both by
/// the full-screen `/lyrics` page and by the right-hand pane of the wide,
/// two-pane `/player` (where AMLL shows the player chrome and the lyrics on one
/// page).
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: AppDimens.space24),
    this.mainStyle,
    this.translationStyle,
    this.showInterludeDots = true,
    this.onTapLine,
  });

  final EdgeInsets padding;
  final TextStyle? mainStyle;
  final TextStyle? translationStyle;
  final bool showInterludeDots;

  /// Tapping a line; null → seek playback (and the lyric layout) to its start.
  final ValueChanged<int>? onTapLine;

  // The app's calligraphic display face (阿里妈妈东方大楷), registered in pubspec.
  // It is single-weight (w400) — asking for w700 only triggers a faux-bold smear
  // — and the wide kai glyphs crowd under negative tracking, so no letterSpacing.
  // The taller face gets a slightly looser `height` (1.16 → 1.22) for headroom;
  // `_measureHeights` measures with this same style, so the line bands track it.
  static const TextStyle defaultMainStyle = TextStyle(
    fontFamily: AppTypography.displayFont,
    fontSize: 29,
    height: 1.22,
    fontWeight: FontWeight.w400,
    color: AppColors.onSurface,
    // No drop-shadow — AMLL's lyrics carry none either (its only text-shadow is the
    // white emphasis bloom). The word-by-word text stays flat white.
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

  static const double _lineVPadding = 14;

  TextStyle get _mainStyle => widget.mainStyle ?? LyricsView.defaultMainStyle;
  TextStyle get _translationStyle =>
      widget.translationStyle ?? LyricsView.defaultTranslationStyle;
  double get _padL => widget.padding.left;
  double get _padR => widget.padding.right;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_subscribed) {
      _provider = context.read<PlayerProvider>();
      _provider!.addListener(_onProvider);
      _subscribed = true;
      _onProvider();
      // Re-opening /lyrics after an earlier transient failure: re-attempt the
      // fetch if we landed with no lines (no-op if lyrics are present/settled).
      if (_lines.isEmpty) _provider!.retryLyrics();
    }
  }

  void _onProvider() {
    final PlayerProvider p = _provider!;
    if (!identical(p.lyrics.lines, _lines)) {
      _lines = p.lyrics.lines;
      _controller.setLines(_lines);
      _syncedLines = null; // force a re-measure
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
    // Returning from background: snap to the authoritative position (mirrors
    // AMLL `onPageShow → setCurrentTime(t, isSeek:true)`) so we don't replay the
    // fly-up cascade from a stale offscreen seed.
    final PlayerProvider? p = _provider;
    if (state == AppLifecycleState.resumed && p != null) {
      _controller.seekTo(p.position);
      _lastPosMs = p.position.inMilliseconds.toDouble();
      // Returning from the background with no lyrics → re-attempt a failed fetch.
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
      // Word-by-word lines render as a `Wrap` of per-word boxes (KaraokeText),
      // which can only break *between* words. A single `TextPainter` over the
      // concatenated `line.text` may break *inside* a word the Wrap can't (e.g.
      // a multi-glyph CJK word), under-counting lines → the absolutely-
      // positioned lines would overlap. So measure word lines the way they wrap.
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

  /// Height of a word-by-word line measured the way [KaraokeText] lays it out: a
  /// `Wrap` (spacing 0) of per-word boxes. We greedily pack each word's intrinsic
  /// width into runs exactly like `Wrap` — breaking *before* a word that would
  /// overflow — then multiply the run count by one line's height. This matches
  /// the rendered height even where words can't break internally (CJK), where a
  /// single `TextPainter` over `line.text` would under-count lines → overlap.
  double _measureWordLineHeight(LyricLine line, double maxWidth) {
    final TextPainter tp = TextPainter(textDirection: TextDirection.ltr);
    // One run's height: the line box for the main style (fixed by its `height`
    // multiplier, so any sample glyph gives the same value the words render at).
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
    final PlayerProvider player = context.watch<PlayerProvider>();
    final bool reduceMotion = MediaQuery.of(context).disableAnimations;

    // Spinner only on the first-ever load (no lines to show yet); on a
    // song-to-song switch the previous lines stay on screen until the new ones
    // swap in (AMLL never flashes a loading state between tracks).
    if (player.lyricsLoading && _lines.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_lines.isEmpty) {
      // Not settled → a transient fetch failure is being retried; keep the
      // spinner rather than flash "No lyrics" for a track that may have them.
      if (!player.lyricsSettled) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      return _empty();
    }
    if (reduceMotion) {
      return _StaticLyrics(
        lines: _lines,
        activeIndex: player.activeLyricIndex,
        mainStyle: _mainStyle,
        translationStyle: _translationStyle,
        padding: widget.padding,
        onSeek: _seekToLine,
      );
    }
    return _animatedLyrics(player);
  }

  Widget _animatedLyrics(PlayerProvider player) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        _syncLayout(size);
        // Vertical drag browses the lyric column (the controller springs it back
        // to the sung line after ~5s); tap seeks to a line. Crucially the drag
        // here does NOT return to the player: the lyrics page's [DismissibleSheet]
        // is grabber-only (`dragAnywhere: false`), so a downward swipe over the
        // lyrics scrolls them instead of dismissing — only the 顶部小横条 returns.
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
          child: ClipRect(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (BuildContext context, Widget? _) {
                final List<LyricLineRender> renders = _controller.renderLines;
                // [activeIndex] is pulled a touch (~60ms) early for the
                // anticipatory lift; the karaoke fill must follow the line
                // *actually* being sung, so gate it on [singingIndex] while the
                // Y-anchor / interlude dots keep using [activeIndex] (at 60ms the
                // two effectively coincide, so the bright line == the inked line).
                final int active = _controller.activeIndex;
                final int singing = _controller.singingIndex;
                return Stack(
                  children: <Widget>[
                    ..._lineWidgets(renders, singing, size.height),
                    if (widget.showInterludeDots)
                      ..._interlude(active, player.dynamicAccent),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// Builds only the lyric lines whose band intersects the viewport (plus a
  /// margin so the cascade still animates in/out at the edges).
  List<Widget> _lineWidgets(
    List<LyricLineRender> renders,
    int singing,
    double viewportHeight,
  ) {
    const double margin = 320;
    final int n =
        renders.length < _lines.length ? renders.length : _lines.length;
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < n; i++) {
      final double top = renders[i].y;
      final double bottom =
          (i + 1 < renders.length) ? renders[i + 1].y : top + 240;
      if (bottom < -margin || top > viewportHeight + margin) continue;
      out.add(
        Positioned(
          top: top,
          left: _padL,
          right: _padR,
          child: LyricLineWidget(
            line: _lines[i],
            render: renders[i],
            currentTimeMs: _controller.currentTimeMs,
            mainStyle: _mainStyle,
            translationStyle: _translationStyle,
            wordFadeWidth: _controller.wordFadeWidth,
            isActive: i == singing,
          ),
        ),
      );
    }
    return out;
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

  /// Breathing dots floated in the empty strip before a line, shown only for
  /// genuinely long instrumental gaps (≥ [InterludeDots.minGap]) — both the
  /// lead-in before line 0 and the interludes between lines. They must never
  /// touch the previous line's descenders or the next line's glyphs.
  List<Widget> _interlude(int active, Color accent) {
    final List<LyricLineRender> renders = _controller.renderLines;
    if (_lines.isEmpty || renders.isEmpty) return const <Widget>[];

    // Lead-in: before the first line becomes active, float the dots above line 0
    // when the intro gap (song start → line 0) is long enough — AMLL's lead-in
    // interlude (`base.ts:398-419`: scrollToIndex 0 + line 0 not yet started →
    // interlude index -2, dots placed before line 0). They clear as line 0 lifts
    // in (active flips to 0).
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

  /// Positions the breathing dots in the empty strip directly above the line at
  /// [yNext] (the next line, or line 0 for the lead-in) and builds the widget.
  ///
  /// Every measured band bakes `2 * _lineVPadding` of phantom spacing *below* its
  /// (top-aligned) text, so the strip between one line's glyph bottom and the next
  /// line's glyph top is exactly that tall, sitting directly above `yNext`:
  ///     strip = [yNext - 2*_lineVPadding, yNext]   (height == 2*_lineVPadding).
  /// InterludeDots paints a box exactly `dotSize` tall (`Size(dotSize*5, dotSize)`,
  /// circles centred). Size it to leave a comfortable margin top *and* bottom in
  /// the strip, then centre it — so the dots float clearly and can't reach either
  /// neighbouring line's glyphs. Driving the widget's `dotSize` from the same
  /// value keeps placement and paint in lock-step.
  List<Widget> _interludeDots({
    required Duration gap,
    required Color accent,
    required double yNext,
    required int keyIndex,
  }) {
    const double gapHeight = _lineVPadding * 2;
    const double minMargin = 9; // ≥ this many px of clearance on each side
    final double dotsHeight =
        (gapHeight - minMargin * 2).clamp(6.0, 12.0).toDouble();
    final double top = (yNext - gapHeight) + (gapHeight - dotsHeight) / 2;

    return <Widget>[
      Positioned(
        top: top,
        // Left-aligned to the text inset so the (left-aligned) dots share the
        // lyric column's padding and never spill outside it.
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
            Text('No lyrics for this track', style: AppTypography.label),
          ],
        ),
      );

  /// Snap the lyric layout to a tapped line, then either delegate to [onTapLine]
  /// or seek playback to its start.
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
