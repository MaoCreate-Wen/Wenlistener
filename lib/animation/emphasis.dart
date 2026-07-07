import 'dart:math' as math;

import 'package:flutter/animation.dart';

import '../models/lyric_line.dart';

/// Word-emphasis ("bouncing glowing chars") model, ported from AMLL
/// `dom/lyric-line.ts`. See `AMLL_ANIMATION_SPEC.md` §5c.
///
/// A long-held word is split into per-character spans that pulse — rising then
/// falling — with a staggered delay and a small scale + splay + lift ([charAt],
/// the MOTION). The glow is applied at the WHOLE-WORD level ([glowAt] → [WordGlow]):
/// ONE soft pure-white aura behind the entire word whose opacity/blur ride a single
/// rise-then-fall breath and grow with hold duration, so the whole word lights up
/// together. (AMLL stacks tight per-glyph halos that only merge into a word glow
/// over its bright, heavily-blurred cover art; a single wide word-wide aura reads
/// the same on any background — including our darker mesh — instead of isolated
/// per-glyph dots.) The caller composites it in one additive (`BlendMode.plus`)
/// pass. The final word of a line gets an exaggerated pop (amount/glow boost).

/// CJK (Han) range test — emphasis triggers for any held CJK glyph, but for
/// latin words only when the trimmed length is in [2, 7].
final RegExp _cjk = RegExp(
  r'[㐀-䶿一-鿿豈-﫿぀-ヿ가-힯]',
);

bool _hasCjk(String s) => _cjk.hasMatch(s);

/// Whether [word] qualifies for the bouncing-glow emphasis.
bool shouldEmphasize(LyricWord word) {
  final int durMs = word.duration.inMilliseconds;
  if (durMs < 1000) return false;
  final String t = word.text.trim();
  if (t.isEmpty) return false;
  if (_hasCjk(t)) return true;
  final int len = t.length;
  return len >= 2 && len <= 7;
}

/// AMLL's `makeEmpEasing` (`dom/lyric-line.ts`): a rise-then-fall pulse built
/// from two cubic-bezier halves split at the midpoint. The attack maps
/// `[0, mid] → [0, 1]` through [_bezIn]; the release maps `[mid, 1] → [1, 0]`
/// through `1 - bezOut(...)`. Continuous, equals 1 at the midpoint and 0 at both
/// edges (and anywhere outside the open interval `(0, 1)`).
double emphasisEase(double p) {
  if (p <= 0 || p >= 1) return 0;
  const double mid = 0.5;
  return p < mid
      ? _bezIn.transform(p / mid)
      : 1 - _bezOut.transform((p - mid) / (1 - mid));
}

// AMLL constants (verbatim): `bezIn = bezier(0.2, 0.4, 0.58, 1.0)` is the
// attack, `bezOut = bezier(0.3, 0.0, 0.58, 1.0)` the release, `EMP_EASING_MID
// = 0.5`.
const Cubic _bezIn = Cubic(0.2, 0.4, 0.58, 1.0);
const Cubic _bezOut = Cubic(0.3, 0.0, 0.58, 1.0);

// Extra per-char lift that scales with hold length (`glow`), stacked on the base
// emphasis lift — a hair more float the longer a char is held.
const double _glowFloatEm = 0.03;

/// Peak-opacity gain for the single soft word-wide emphasis aura (vs AMLL's many
/// stacked tight per-glyph halos, which only merge over its bright blurred art).
/// Tuning knob — raise for a brighter glow.
const double _glowGain = 1.8;

/// Whole-word emphasis glow sampled at a moment: ONE soft pure-white aura behind
/// the entire word — opacity [alpha], blur radius [blurEm] in **em** (× font size)
/// — instead of a tight halo per glyph. See [WordEmphasis.glowAt].
class WordGlow {
  final double alpha;
  final double blurEm;
  const WordGlow({required this.alpha, required this.blurEm});
  static const WordGlow none = WordGlow(alpha: 0, blurEm: 0);
  bool get hasGlow => alpha > 0.001 && blurEm > 0.0001;
}

/// Per-character emphasis MOTION sampled at a moment in time: scale + horizontal
/// splay + vertical lift (offsets in **em** — multiply by the font size before
/// applying as pixels). The glow is no longer per-character; the whole word's soft
/// aura is [WordEmphasis.glowAt] / [WordGlow].
class CharEmphasis {
  final double scale;
  final double offsetXEm;
  final double offsetYEm;

  const CharEmphasis({
    required this.scale,
    required this.offsetXEm,
    required this.offsetYEm,
  });

  static const CharEmphasis none = CharEmphasis(
    scale: 1,
    offsetXEm: 0,
    offsetYEm: 0,
  );

  bool get isActive =>
      (scale - 1).abs() > 0.001 ||
      offsetXEm.abs() > 0.001 ||
      offsetYEm.abs() > 0.001;
}

/// Pre-computed emphasis magnitudes for one word; sample per character with
/// [charAt].
class WordEmphasis {
  /// Number of (emphasised) characters in the word.
  final int charCount;

  /// Overall animation window in ms (already scaled for the last-word pop).
  final double durationMs;

  /// Scale/offset magnitude (≤ 1.2).
  final double amount;

  /// Bloom intensity (≤ 0.8), AMLL's `blur`: drives the soft-glow opacity and
  /// radius. Eases in with hold duration (`du/3000` cubed then `sqrt`, ×0.5) —
  /// faint on a ~1s syllable, strong past ~3s (see [charAt]).
  final double glow;

  const WordEmphasis._({
    required this.charCount,
    required this.durationMs,
    required this.amount,
    required this.glow,
  });

  /// Build the magnitudes for [word]. [isLastWord] applies the final-word boost
  /// (amount ×1.6, glow ×1.5, duration ×1.2).
  factory WordEmphasis.forWord(LyricWord word, {required bool isLastWord}) {
    final int rawDur = word.duration.inMilliseconds;
    final double du0 = math.max(1000, rawDur).toDouble();

    final double ampBase = du0 / 2000.0;
    double amount =
        (ampBase > 1 ? math.sqrt(ampBase) : ampBase * ampBase * ampBase) * 0.6;
    amount = math.min(amount, 1.2);

    // Bloom intensity = AMLL's `blur` (`dom/lyric-line.ts:571-574`), verbatim:
    // `b = du/3000`, cubed while ramping in (gentle onset) then `sqrt` once past
    // the divisor (plateau), ×0.5 (du≈1s → 0.02; du≈2s → 0.15; du≈3s → 0.5). The
    // last-word boost (×1.5) and the ≤0.8 cap are applied below.
    final double blurBase = du0 / 3000.0;
    double glow =
        (blurBase > 1 ? math.sqrt(blurBase) : blurBase * blurBase * blurBase) *
            0.5;

    double du = du0;
    if (isLastWord) {
      amount *= 1.6;
      glow *= 1.5;
      du *= 1.2;
    }
    glow = math.min(glow, 0.8);

    return WordEmphasis._(
      charCount: word.text.trim().runes.length,
      durationMs: du,
      amount: amount,
      glow: glow,
    );
  }

  /// Sample character [i] (of [charCount]) at [wordElapsedMs] — milliseconds
  /// since the word started being sung. MOTION only (scale/splay/lift); the glow
  /// is the whole-word [glowAt].
  CharEmphasis charAt(int i, double wordElapsedMs) {
    final int n = charCount <= 0 ? 1 : charCount;
    final double delay = (durationMs / 2.5 / n) * i;
    final double p = (wordElapsedMs - delay) / durationMs;
    if (p <= 0 || p >= 1) return CharEmphasis.none;

    final double e = emphasisEase(p);
    if (e <= 0) return CharEmphasis.none;

    final double splay = (n / 2.0) - i; // chars fan out from the centre
    // Held chars drift up a hair more (grows with hold via `glow`), stacked on the
    // base lift, so the motion swells the longer the char is held.
    final double floatEm = 0.025 * amount + _glowFloatEm * glow;

    return CharEmphasis(
      scale: 1 + e * 0.1 * amount,
      offsetXEm: -e * 0.03 * amount * splay,
      offsetYEm: -e * floatEm,
    );
  }

  /// WHOLE-word glow at [wordElapsedMs] (ms since the word started). Collapses
  /// AMLL's staggered per-char bloom pulses into ONE rise→fall breath so the entire
  /// word lights up together. The window is 1.35× the word duration (AMLL's last
  /// char tails out ~1.4×), and the blur is MUCH wider than AMLL's per-char
  /// `min(0.3, blur*0.3)` so a single blurred word copy reads as a soft word-wide
  /// aura, not isolated per-glyph dots. Zero outside the open window.
  WordGlow glowAt(double wordElapsedMs) {
    if (glow <= 0) return WordGlow.none;
    final double window = durationMs * 1.35;
    if (window <= 0) return WordGlow.none;
    final double p = wordElapsedMs / window;
    if (p <= 0 || p >= 1) return WordGlow.none;
    final double env = emphasisEase(p);
    if (env <= 0) return WordGlow.none;
    final double alpha = math.min(0.9, env * glow * _glowGain);
    // du≈1s → ~0.36em, du≈3s → ~0.6em (cap 0.75em) — a broad soft halo.
    final double blurEm = math.min(0.75, 0.35 + glow * 0.5);
    return WordGlow(alpha: alpha, blurEm: blurEm);
  }
}
