import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../animation/emphasis.dart';
import '../../../models/lyric_line.dart';

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
    final double floatEm = line.isBackground ? 0.10 : 0.05;
    final int lastIndex = line.words.length - 1;

    // Not the singing line → one flat layer, no sweep / float / emphasis: fully
    // inked once the line has passed (sung color), un-inked while upcoming (base
    // color). Keeps the per-word `Wrap` so the layout doesn't jump on handoff,
    // and makes a simultaneous second karaoke physically impossible (§5b).
    if (!isSinging) {
      final bool passed = currentTimeMs >= line.end.inMilliseconds;
      final Color flat =
          textColor.withValues(alpha: passed ? brightAlpha : darkAlpha);
      return Wrap(
        alignment: _wrapAlignment,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: <Widget>[
          for (final LyricWord word in line.words)
            Text(word.text, style: style.copyWith(color: flat)),
        ],
      );
    }

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
          child: _wordsWrap(_WordPass.glow, fontSize, floatEm, lastIndex),
        ),
        _wordsWrap(_WordPass.text, fontSize, floatEm, lastIndex),
      ],
    );
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

    // (a) Float: rise 0 → -floatEm em over max(1000ms, wordDur), easeOut.
    final double floatDur = math.max(1000.0, dur);
    final double floatP =
        Curves.easeOut.transform((elapsed / floatDur).clamp(0.0, 1.0));
    final double floatY = -floatEm * fontSize * floatP;

    final Widget content =
        pass == _WordPass.glow ? _glowContent() : _textContent(sung);

    return Transform.translate(
      offset: Offset(0, floatY),
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
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Dim base (unsung) layer.
        _wordLayer(textColor.withValues(alpha: darkAlpha)),
        // Bright layer, inked in left→right by the karaoke sweep.
        ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect bounds) => _maskShader(bounds, sung),
          child: _wordLayer(textColor.withValues(alpha: brightAlpha)),
        ),
      ],
    );
  }

  /// One painted copy of the word in [color] — plain [Text] or, for held words, a
  /// row of independently animated (scale/splay/lift) characters (the MOTION). The
  /// glow no longer lives here — it's the single word-wide aura in [_glowContent].
  Widget _wordLayer(Color color) {
    if (!shouldEmphasize(word)) {
      return Text(word.text, style: style.copyWith(color: color));
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
  }) {
    final Widget text = Text(ch, style: style.copyWith(color: color));

    // The sine bounce can lift a char a hair before its emphasis pulse begins, so
    // apply the transform when EITHER the emphasis is active OR the bounce is.
    if (!e.isActive && sinBounceY == 0) return text;

    return Transform.translate(
      offset:
          Offset(e.offsetXEm * fontSize, e.offsetYEm * fontSize + sinBounceY),
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
/// per-character pure-white glow halos are drawn into a single unclipped layer
/// here and added together — letting adjacent glyphs' halos overlap and MERGE
/// into a continuous word/phrase halo instead of reading as isolated per-glyph
/// blobs.
class _AdditiveLayer extends SingleChildRenderObjectWidget {
  const _AdditiveLayer({required Widget child}) : super(child: child);

  @override
  _RenderAdditiveLayer createRenderObject(BuildContext context) =>
      _RenderAdditiveLayer();
}

class _RenderAdditiveLayer extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    // bounds = null so the layer is never clipped — the bloom must extend well
    // past each glyph box (up to ~0.3em blur) to bridge and merge across glyphs.
    context.canvas.saveLayer(null, Paint()..blendMode = BlendMode.plus);
    super.paint(context, offset);
    context.canvas.restore();
  }
}
