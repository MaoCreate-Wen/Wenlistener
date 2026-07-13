import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../animation/emphasis.dart';
import '../../../models/lyric_line.dart';

/// B3 — the active line's "白边强调": a subtle pure-white outer glow ring baked
/// onto the sung line's glyphs (AMLL `dom/lyric-line.ts:600-616` per-character
/// `text-shadow`). A tight bright ring plus a soft outer halo lift the active
/// line off the milky, dimmed neighbours by more than brightness alone. Applied
/// ONLY to the active/singing line; scaled to the (responsive) font so the ring
/// stays proportional at every viewport size.
/// [intensity] (0..1) scales the ring's alpha so it can FADE with the line's
/// live brightness differentiator `s` (the controller's bright-mask ramp)
/// instead of popping on/off at the singing handoff.
List<Shadow> activeEdgeShadows(double fontSize, {double intensity = 1}) =>
    <Shadow>[
      Shadow(
        color: Colors.white.withValues(alpha: 0.55 * intensity),
        blurRadius: fontSize * 0.12,
      ),
      Shadow(
        color: Colors.white.withValues(alpha: 0.25 * intensity),
        blurRadius: fontSize * 0.30,
      ),
    ];

// --- per-word float ("浮升") tunables -----------------------------------------
// Rise distance in em of the main font: 1.8× the original 0.05/0.10 — the rise
// was barely perceptible at desktop sizes; ~0.09em (≈4px at a 42px font) reads
// as a clear lift without turning cartoonish.
const double _floatEmMain = 0.09;
const double _floatEmBg = 0.18;

double _floatEmFor(LyricLine line) => line.isBackground ? _floatEmBg : _floatEmMain;

/// Duration (ms) of one word's float rise: 1.5 × max(1000, word duration). The
/// 1.5× stretch (was exactly max(1000, dur)) makes the enlarged rise a languid
/// drift instead of a quick pop.
double _floatDurMs(double wordDurMs) => 1.5 * math.max(1000.0, wordDurMs);

/// Resting offset (logical px, negative = up) every fully-floated word of a
/// PASSED word-by-word line sits at. The flat non-singing renderings
/// ([KaraokeText]'s flat branch and `StaticLyricLine`) apply this so a finished
/// line KEEPS its risen position — AMLL's float fills forwards — instead of the
/// whole line dropping back to the baseline the instant the next line starts.
double karaokeRestDy(LyricLine line, double fontSize) =>
    -_floatEmFor(line) * fontSize;

/// When (ms on the lyric clock) the LAST per-word animation of [line] — float
/// rise, per-char emphasis motion (delay + 1× window, ≤ start + 1.4× the
/// emphasis duration), whole-word glow breath (1.35×) and the additive sine
/// bounce (< 1.4×) — has fully settled. The lyrics view keeps a passed line on
/// the LIVE karaoke path until this moment so those tails play out (and the
/// words land at [karaokeRestDy]) rather than being frozen mid-flight by the
/// static swap at the singing handoff.
double karaokeTailEndMs(LyricLine line) {
  double end = line.end.inMilliseconds.toDouble();
  final int last = line.words.length - 1;
  for (int i = 0; i <= last; i++) {
    final LyricWord w = line.words[i];
    final double start = w.start.inMilliseconds.toDouble();
    final double dur = math.max(1, w.duration.inMilliseconds).toDouble();
    final double floatEnd = start + _floatDurMs(dur);
    if (floatEnd > end) end = floatEnd;
    if (shouldEmphasize(w)) {
      // Mirrors WordEmphasis.forWord/charAt/glowAt windows: emphasis duration
      // (last word ×1.2), per-char delays < duration/2.5, glow window ×1.35 —
      // all bounded by 1.4× the emphasis duration past the word start.
      final double empDur = math.max(1000.0, dur) * (i == last ? 1.2 : 1.0);
      final double empEnd = start + empDur * 1.4;
      if (empEnd > end) end = empEnd;
    }
  }
  return end;
}

/// Word-by-word lyric line: each word "inks in" left→right as it is sung
/// (karaoke), lifts slightly (float), and—when held long enough—its characters
/// pulse and glow (emphasis). See `AMLL_ANIMATION_SPEC.md` §5.
class KaraokeText extends StatelessWidget {
  final LyricLine line;
  final double currentTimeMs;
  final TextStyle style;

  /// Base text color (the dynamic accent reads better than pure white on art).
  final Color textColor;

  /// Sung ("bright") and unsung ("dark") alphas from the controller (§4).
  final double brightAlpha;
  final double darkAlpha;

  /// iPad-style soft karaoke edge (0.5). 1.0 = hard Android edge.
  final double wordFadeWidth;

  /// Whether this is the line genuinely being sung *right now* (the controller's
  /// `singingIndex`, not the early-shifted `activeIndex`). Only the singing line
  /// gets the moving per-word fill + emphasis; every other word-by-word line
  /// renders as one flat layer, so two lines can never sweep at once.
  final bool isSinging;

  final TextAlign textAlign;

  const KaraokeText({
    super.key,
    required this.line,
    required this.currentTimeMs,
    required this.style,
    required this.textColor,
    required this.brightAlpha,
    required this.darkAlpha,
    required this.isSinging,
    this.wordFadeWidth = 0.5,
    this.textAlign = TextAlign.start,
  });

  @override
  Widget build(BuildContext context) {
    final double fontSize = style.fontSize ?? 24;
    final double floatEm = _floatEmFor(line);
    final int lastIndex = line.words.length - 1;

    // Not the singing line → one flat layer, no sweep / float / emphasis: fully
    // inked once the line has passed (sung color), un-inked while upcoming (base
    // color). Keeps the per-word `Wrap` so the layout doesn't jump on handoff,
    // and (with the lyrics view's live float tail) at most one line ever runs a
    // MOVING sweep at a time (§5b). A passed line's flat ink composites the
    // bright layer OVER the dark base — `1-(1-b)(1-d)` — exactly what the live
    // two-layer stack settles to, and it keeps the words at their float REST
    // offset, so the live→flat swap is pixel-continuous.
    if (!isSinging) {
      final bool passed = currentTimeMs >= line.end.inMilliseconds;
      final Color flat = textColor.withValues(
          alpha: passed
              ? 1 - (1 - brightAlpha) * (1 - darkAlpha)
              : darkAlpha);
      final Widget wrap = Wrap(
        alignment: _wrapAlignment,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: <Widget>[
          for (final LyricWord word in line.words)
            Text(word.text, style: style.copyWith(color: flat)),
        ],
      );
      if (!passed) return wrap;
      return Transform.translate(
        offset: Offset(0, karaokeRestDy(line, fontSize)),
        child: wrap,
      );
    }

    // TEXT pass: dim base + bright karaoke sweep, no glow. Always built.
    final Widget textPass =
        _wordsWrap(_WordPass.text, fontSize, floatEm, lastIndex);

    // The GLOW pass exists ONLY to composite emphasised words' pure-white auras
    // additively — a line-sized, isolated `saveLayer(BlendMode.plus)` pair
    // (`_AdditiveLayer`). That offscreen buffer is the single most expensive op
    // per karaoke frame, so we only pay for it on frames where some word ACTUALLY
    // has a live aura right now. Most singing frames have none (short syllables
    // never emphasise; long ones glow only inside their held window), so the
    // saveLayer is skipped outright then — the text pass alone is pixel-identical
    // to the Stack when the glow layer contributes nothing.
    if (!_anyWordGlowing(lastIndex)) return textPass;

    // Two registered passes over the SAME words. Both `Wrap`s break lines
    // identically because text `Shadow`s and `Transform`s never change metrics:
    //   • GLOW pass UNDERNEATH, wrapped once in `_AdditiveLayer` so every glyph's
    //     pure-white bloom is composited with `BlendMode.plus` in ONE line-wide
    //     layer — adjacent glyphs' halos overlap and MERGE into a continuous
    //     word/phrase halo (Flutter text shadows have no `plus-lighter`).
    //   • TEXT pass ON TOP: dim base + bright karaoke sweep, no glow.
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        _AdditiveLayer(
          fontSize: fontSize,
          child: _wordsWrap(_WordPass.glow, fontSize, floatEm, lastIndex),
        ),
        textPass,
      ],
    );
  }

  /// Whether ANY word in the (singing) line currently has a live emphasis aura
  /// at [currentTimeMs]. Pure arithmetic (no widget build), so it is far cheaper
  /// than the glow-pass `saveLayer` it gates away on the common no-glow frames.
  /// Uses the EXACT same test `_glowContent` applies (mobile's untouched
  /// [WordEmphasis.glowAt] breath — no extra gating), so skipping the pass only
  /// ever drops a fully-transparent layer: zero visual change, pure perf.
  bool _anyWordGlowing(int lastIndex) {
    for (int i = 0; i < line.words.length; i++) {
      final LyricWord word = line.words[i];
      if (!shouldEmphasize(word)) continue;
      final double elapsed = currentTimeMs - word.start.inMilliseconds;
      final WordGlow g = WordEmphasis.forWord(word, isLastWord: i == lastIndex)
          .glowAt(elapsed);
      if (g.hasGlow) return true;
    }
    return false;
  }

  /// One [Wrap] of the line's words for the given [pass]. Both passes share this
  /// builder so the glow and text Wraps stay pixel-registered.
  Widget _wordsWrap(
    _WordPass pass,
    double fontSize,
    double floatEm,
    int lastIndex,
  ) {
    return Wrap(
      alignment: _wrapAlignment,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: <Widget>[
        for (int i = 0; i < line.words.length; i++)
          _KaraokeWord(
            word: line.words[i],
            currentTimeMs: currentTimeMs,
            style: style,
            textColor: textColor,
            brightAlpha: brightAlpha,
            darkAlpha: darkAlpha,
            fontSize: fontSize,
            wordFadeWidth: wordFadeWidth,
            floatEm: floatEm,
            isLastWord: i == lastIndex,
            pass: pass,
          ),
      ],
    );
  }

  WrapAlignment get _wrapAlignment {
    switch (textAlign) {
      case TextAlign.center:
        return WrapAlignment.center;
      case TextAlign.end:
      case TextAlign.right:
        return WrapAlignment.end;
      default:
        return WrapAlignment.start;
    }
  }
}

class _KaraokeWord extends StatelessWidget {
  final LyricWord word;
  final double currentTimeMs;
  final TextStyle style;
  final Color textColor;
  final double brightAlpha;
  final double darkAlpha;
  final double fontSize;
  final double wordFadeWidth;
  final double floatEm;
  final bool isLastWord;

  /// Which registered pass this copy renders (the bright/dim text, or the
  /// transparent glyphs carrying only the white bloom).
  final _WordPass pass;

  const _KaraokeWord({
    required this.word,
    required this.currentTimeMs,
    required this.style,
    required this.textColor,
    required this.brightAlpha,
    required this.darkAlpha,
    required this.fontSize,
    required this.wordFadeWidth,
    required this.floatEm,
    required this.isLastWord,
    required this.pass,
  });

  @override
  Widget build(BuildContext context) {
    final double dur = math.max(1, word.duration.inMilliseconds).toDouble();
    final double elapsed = currentTimeMs - word.start.inMilliseconds;
    final double sung = (elapsed / dur).clamp(0.0, 1.0);

    // (a) Float: rise 0 → -floatEm em over [_floatDurMs] (1.5 × max(1000ms,
    // wordDur)), easeOut.
    final double floatDur = _floatDurMs(dur);
    final double floatP =
        Curves.easeOut.transform((elapsed / floatDur).clamp(0.0, 1.0));
    final double floatY = -floatEm * fontSize * floatP;

    final Widget content =
        pass == _WordPass.glow ? _glowContent() : _textContent(sung);

    // filterQuality — CRITICAL for a smooth rise. A plain (vector) translate
    // re-paints the glyphs, and the text raster SNAPS glyph origins to whole
    // device pixels: the ~4px rise then renders as four 1px pops with the word
    // frozen for many frames in between (measured: identical rasters across
    // 3-4 frames, then a 1px jump). A non-null filterQuality applies the
    // transform as a bitmap op (ImageFilter.matrix) — the word's raster is
    // sampled bilinearly at the true fractional offset, so the rise glides
    // sub-pixel-smooth. Glow-pass copies stay vector: their only visible output
    // is a ≥0.35em blurred aura, where sub-pixel registration is invisible, and
    // skipping the filter avoids a second stack of offscreen layers.
    return Transform.translate(
      offset: Offset(0, floatY),
      filterQuality:
          pass == _WordPass.text && floatY != 0 ? FilterQuality.low : null,
      child: content,
    );
  }

  /// GLOW pass: for an emphasised held word, ONE soft pure-white aura behind the
  /// WHOLE word (a single blurred white copy of the word text) whose opacity/blur
  /// follow the word-level [WordEmphasis.glowAt] breath — so the entire word lights
  /// up together instead of N tight per-glyph dots sweeping left→right. Composited
  /// once, additively, line-wide by [_AdditiveLayer]. Every copy here is a
  /// transparent-filled placeholder so this Wrap lays out identically to the text
  /// Wrap (Transforms/Shadows never change metrics).
  Widget _glowContent() {
    const Color clear = Color(0x00000000);
    if (!shouldEmphasize(word)) {
      return Text(
        word.text,
        style: style.copyWith(color: clear, shadows: const <Shadow>[]),
      );
    }
    // Transparent per-char ghost = the SAME Row the text pass builds, so this Wrap
    // breaks lines identically.
    final Widget ghost = _wordLayer(clear);

    final WordEmphasis emphasis =
        WordEmphasis.forWord(word, isLastWord: isLastWord);
    final double elapsed = currentTimeMs - word.start.inMilliseconds;
    final WordGlow g = emphasis.glowAt(elapsed);
    if (!g.hasGlow) return ghost;

    // ONE soft word-wide halo behind the ghost: a single blurred WHITE copy of the
    // whole word. The wide blur overflows the (unclipped) additive layer and adds
    // (BlendMode.plus) into a continuous aura hugging the whole word.
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        ghost,
        Positioned.fill(
          child: Center(
            child: Text(
              word.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: style.copyWith(
                color: clear,
                shadows: <Shadow>[
                  Shadow(
                    color: const Color(0xFFFFFFFF).withValues(alpha: g.alpha),
                    blurRadius: g.blurEm * fontSize,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// TEXT pass: the dim (unsung) base with the bright (sung) layer inked in
  /// left→right by the karaoke sweep. No glow (the aura lives in the additive glow
  /// pass beneath) and no drop-shadow. `Clip.none` so the (shadowless) layers are
  /// never cropped to the glyph box.
  Widget _textContent(double sung) {
    // B3 — every word reaching `_textContent` belongs to the singing (active)
    // line (the flat non-singing branch returns before any `_KaraokeWord` is
    // built), so the white edge is applied here and nowhere else. It rides on
    // the dim BASE layer only: the base is drawn once per word and follows the
    // real per-word float / emphasis layout, so the ring rises with the word and
    // never doubles. The bright sweep layer stacks on top with NO shadows, so the
    // karaoke fill stays crisp and the ring reads as an outline hugging the
    // glyph. This is a static styling ADDITION only — the layer structure below
    // (dim base + always-masked bright sweep) is the mobile app's, verbatim, so
    // the fill motion and its soft trailing edge match Android exactly.
    //
    // The ring's alpha rides the line's live brightness differentiator `s`
    // (recovered from the controller's bright-mask ramp `s·0.8+0.2`): it fades
    // IN as a line takes the anchor and OUT after the handoff — so the passed
    // line's float/glow tail (still on this live path) converges pixel-exactly
    // on the ring-less flat rendering instead of the ring popping off.
    final double s = ((brightAlpha - 0.2) / 0.8).clamp(0.0, 1.0);
    final List<Shadow>? edge =
        s > 0.004 ? activeEdgeShadows(fontSize, intensity: s) : null;

    final Widget dimBase = _wordLayer(textColor.withValues(alpha: darkAlpha),
        shadows: edge, smooth: true);

    // Fully-unsung word (the sweep hasn't reached it): [_maskShader] returns an
    // all-transparent mask (right<=0 branch), so the dstIn bright layer would
    // contribute ZERO pixels. Skip building the ShaderMask + its per-word
    // saveLayer offscreen entirely and paint only the dim base — pixel-identical.
    // Every upcoming word on the singing line takes this path, so the singing
    // line's per-frame offscreen count collapses to just the word(s) under the
    // moving edge plus the already-sung words behind it (which still need the
    // real mask for their trailing fade). This is the #1 driver of the working-set
    // ramp 2-3s after /lyrics opens.
    if (sung <= 0) return dimBase;

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Dim base (unsung) layer + the active white edge ring.
        dimBase,
        // Bright layer, inked in left→right by the karaoke sweep.
        ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect bounds) => _maskShader(bounds, sung),
          child:
              _wordLayer(textColor.withValues(alpha: brightAlpha), smooth: true),
        ),
      ],
    );
  }

  /// One painted copy of the word in [color] — plain [Text] or, for held words, a
  /// row of independently animated (scale/splay/lift) characters (the MOTION). The
  /// glow no longer lives here — it's the single word-wide aura in [_glowContent].
  /// [smooth] = sample the per-char emphasis transforms sub-pixel (text pass);
  /// the glow-pass ghosts stay vector (their aura blur hides raster snapping).
  Widget _wordLayer(Color color, {List<Shadow>? shadows, bool smooth = false}) {
    if (!shouldEmphasize(word)) {
      return Text(word.text,
          style: style.copyWith(color: color, shadows: shadows));
    }

    final List<String> chars = word.text.runes
        .map((int r) => String.fromCharCode(r))
        .toList(growable: false);
    final WordEmphasis emphasis =
        WordEmphasis.forWord(word, isLastWord: isLastWord);
    final double elapsed = currentTimeMs - word.start.inMilliseconds;
    final int n = chars.length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        for (int i = 0; i < chars.length; i++)
          _emphasisChar(
            chars[i],
            emphasis.charAt(i, elapsed),
            color,
            sinBounceY: _sinBounceY(emphasis, i, n, elapsed),
            shadows: shadows,
            smooth: smooth,
          ),
      ],
    );
  }

  /// AMLL's separate per-char "emphasize-word-float" sine bounce
  /// (`dom/lyric-line.ts:633-660`): an ADDITIVE float `sin(progress·π)·-floatEm`
  /// over a window of `1.4×` the emphasis duration, begun 400ms before the char's
  /// own emphasis delay. Returned in **px** and STACKED on the word-level float
  /// and the per-char emphasis lift (`e.offsetYEm`) rather than replacing them.
  /// `floatEm` already carries the background-line ×2 (0.05 → 0.10). Zero outside
  /// the open window (sin is 0 at both ends anyway).
  double _sinBounceY(WordEmphasis emphasis, int i, int n, double elapsed) {
    final double window = emphasis.durationMs * 1.4;
    if (window <= 0) return 0;
    final double perCharDelay =
        (emphasis.durationMs / 2.5 / (n <= 0 ? 1 : n)) * i;
    final double charElapsed = elapsed - (perCharDelay - 400);
    final double p = charElapsed / window;
    if (p <= 0 || p >= 1) return 0;
    return -math.sin(p * math.pi) * floatEm * fontSize;
  }

  /// One emphasised character with its MOTION transform (scale + splay + lift + the
  /// additive per-char sine bounce [sinBounceY]). No per-char glow — the aura is
  /// the single word-wide layer in [_glowContent].
  Widget _emphasisChar(
    String ch,
    CharEmphasis e,
    Color color, {
    required double sinBounceY,
    List<Shadow>? shadows,
    bool smooth = false,
  }) {
    final Widget text =
        Text(ch, style: style.copyWith(color: color, shadows: shadows));

    // The sine bounce can lift a char a hair before its emphasis pulse begins, so
    // apply the transform when EITHER the emphasis is active OR the bounce is.
    if (!e.isActive && sinBounceY == 0) return text;

    // Same sub-pixel treatment as the word float: the ~px-scale per-char lift /
    // splay / bounce steps pixel-to-pixel under a vector translate (glyph
    // origins snap to device pixels), so the text pass samples the char's
    // raster at the true fractional offset instead.
    return Transform.translate(
      offset:
          Offset(e.offsetXEm * fontSize, e.offsetYEm * fontSize + sinBounceY),
      filterQuality: smooth ? FilterQuality.low : null,
      child: Transform.scale(scale: e.scale, child: text),
    );
  }

  Shader _maskShader(Rect bounds, double sung) {
    final double w = bounds.width;
    final double fadeNorm = w <= 0 ? 0 : (fontSize * wordFadeWidth) / w;
    double right = sung.clamp(0.0, 1.0);
    double left = (right - fadeNorm).clamp(0.0, 1.0);
    if (left > right) left = right;

    if (right <= 0) {
      return const LinearGradient(
        colors: <Color>[Colors.transparent, Colors.transparent],
      ).createShader(bounds);
    }
    if (left >= 1) {
      return const LinearGradient(
        colors: <Color>[Colors.white, Colors.white],
      ).createShader(bounds);
    }
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: const <Color>[Colors.white, Colors.white, Colors.transparent],
      stops: <double>[0.0, left, right],
    ).createShader(bounds);
  }
}

/// Which of the two registered passes a [_KaraokeWord] renders: the bright/dim
/// [text] glyphs, or the transparent-fill [glow] glyphs carrying only the
/// pure-white bloom shadows (composited additively, line-wide, by
/// [_AdditiveLayer]).
enum _WordPass { text, glow }

/// Composites its [child] as ONE additive (`BlendMode.plus`) layer. Flutter text
/// `Shadow`s have no per-glyph blend mode (AMLL gets its merged word halo from
/// `mix-blend-mode: plus-lighter` on the lyric container), so the whole line's
/// per-character pure-white glow halos are drawn into a single layer here and
/// added together — letting adjacent glyphs' halos overlap and MERGE into a
/// continuous word/phrase halo instead of reading as isolated per-glyph blobs.
///
/// [fontSize] sizes the layers: they are BOUNDED to the line box inflated by
/// 1.5em — the widest bloom is a 0.75em blur radius (σ ≈ 0.43em, tail gone
/// well before 1.5em), so nothing visible is clipped, while the old `null`
/// bounds made Skia allocate the offscreen at the CLIP size (the whole lyric
/// view) on every glow frame.
///
/// The plus layer sits inside an extra plain (srcOver) isolation layer so the
/// additive merge always happens against TRANSPARENT and the result is then
/// alpha-composited over whatever is beneath. That is exactly what the old
/// page-level edge-fade `ShaderMask` offscreen provided implicitly; with that
/// full-window layer gone, an un-isolated `plus` would add straight onto the
/// live mesh background (`mesh + glow` instead of `glow + mesh·(1-α)`) and
/// visibly brighten every halo over bright art. Costs one extra line-sized
/// saveLayer, ONLY on frames where a word actually glows.
class _AdditiveLayer extends SingleChildRenderObjectWidget {
  const _AdditiveLayer({required this.fontSize, required Widget child})
      : super(child: child);

  /// The line's main font size in px — the em basis for the layer bounds.
  final double fontSize;

  @override
  _RenderAdditiveLayer createRenderObject(BuildContext context) =>
      _RenderAdditiveLayer(fontSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAdditiveLayer renderObject,
  ) {
    renderObject.fontSize = fontSize;
  }
}

class _RenderAdditiveLayer extends RenderProxyBox {
  _RenderAdditiveLayer(this._fontSize);

  double _fontSize;
  set fontSize(double value) {
    if (value == _fontSize) return;
    _fontSize = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final Rect bounds = (offset & size).inflate(_fontSize * 1.5);
    final Canvas canvas = context.canvas;
    // Isolation first (srcOver), then the additive merge inside it — see the
    // widget doc: `plus` must resolve against transparent, then composite
    // normally, to render the same pixels the page-offscreen era did.
    canvas.saveLayer(bounds, Paint());
    canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.plus);
    super.paint(context, offset);
    canvas.restore();
    canvas.restore();
  }
}
