/// AMLL control-icon library — faithful Flutter ports of the exact SVG glyphs
/// that Apple-Music-like-Lyrics (AMLL) uses for its horizontal player controls.
///
/// Every glyph below is the *real* path data lifted verbatim from AMLL source:
///   - transport (play/pause/rewind/forward/shuffle/repeat):
///       applemusic-like-lyrics-full-refractor/packages/react-full/src/components/PrebuiltLyricPlayer/*.svg
///   - bottom controls (lyrics-toggle / playlist / airplay):
///       .../react-full/src/components/ToggleIconButton/*.svg and IconButton/airplay.svg
///   - overflow (···): .../react-full/src/components/MenuButton/icon_more.svg
///   - volume: .../react-full/src/components/VolumeControlSlider/icon_speaker*.svg
///
/// The paths are drawn by a tiny self-contained SVG path parser + [CustomPainter]
/// so this file needs **no** asset wiring and no `flutter_svg` import — it only
/// depends on `dart:ui` + Flutter. Import it and drop the widgets straight into a
/// control row; each is const-constructible and takes `size` + `color`.
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

// ---------------------------------------------------------------------------
// Public icon widgets
// ---------------------------------------------------------------------------

/// Shuffle glyph (crossing arrows). viewBox 56×56 — `PrebuiltLyricPlayer/shuffle.svg`.
class AmllShuffleIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllShuffleIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(56, 56),
    paths: const [_kShufflePath],
  );
}

/// Previous / rewind — the twin left-pointing arrows. viewBox 134×134
/// (`PrebuiltLyricPlayer/icon_rewind.svg`, the two visible arrows, standby
/// duplicate omitted).
class AmllPreviousIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllPreviousIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(134, 134),
    paths: const [_kRewindRightArrow, _kRewindLeftArrow],
  );
}

/// Play triangle. viewBox 38×38 — `PrebuiltLyricPlayer/icon_play.svg`.
class AmllPlayIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllPlayIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(38, 38),
    paths: const [_kPlayPath],
  );
}

/// Pause (two rounded bars). viewBox 38×38 — `PrebuiltLyricPlayer/icon_pause.svg`.
class AmllPauseIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllPauseIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(38, 38),
    paths: const [_kPausePath],
  );
}

/// Next / forward — the twin right-pointing arrows. viewBox 134×134
/// (`PrebuiltLyricPlayer/icon_forward.svg`, the two visible arrows).
class AmllNextIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllNextIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(134, 134),
    paths: const [_kForwardLeftArrow, _kForwardRightArrow],
  );
}

/// Repeat (loop) glyph. viewBox 56×56 — `PrebuiltLyricPlayer/repeat.svg`.
class AmllRepeatIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllRepeatIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(56, 56),
    paths: const [_kRepeatPath],
  );
}

/// Repeat-one — the loop with a small `1` centred inside, matching AMLL's
/// `repeat_on_one.svg` composition (loop glyph + numeral) minus the filled
/// squircle background so it reads as a plain monochrome control.
class AmllRepeatOneIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllRepeatOneIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _RepeatOnePainter(color),
      isComplex: true,
    ),
  );
}

/// Lyrics show/hide glyph — AMLL's bottom-right lyrics toggle, viewBox 64×64.
///
/// Faithful two-state port of `ToggleIconButton/lyrics_on.svg` +
/// `lyrics_off.svg`:
///  - [filled] = `true` (checked / lyrics shown, AMLL's on state): the whole
///    64×64 rounded-square plate is FILLED with [color]; the speech bubble is
///    knocked out of it (even-odd hole) so it shows the background through,
///    and the two quote marks are filled with [color] again inside the hole.
///  - [filled] = `false` (unchecked, AMLL's off state): the outlined speech
///    bubble (outer + inner contour forming a stroke-like ring, tail at the
///    bottom-left) with the quote marks filled.
class AmllLyricsToggleIcon extends StatelessWidget {
  final double size;
  final Color color;
  final bool filled;
  const AmllLyricsToggleIcon({
    super.key,
    this.size = 24,
    this.color = _kWhite,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(64, 64),
    paths: filled
        ? const [_kLyricsOnPlatePath, _kLyricsQuotesPath]
        : const [_kLyricsPath],
  );
}

/// Playlist / play-queue glyph (three lines with leading dots) — AMLL's
/// bottom-right queue toggle. viewBox 64×64 — `ToggleIconButton/playlist_off.svg`.
class AmllPlaylistIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllPlaylistIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(64, 64),
    paths: const [_kPlaylistPath],
  );
}

/// Queue glyph as used by the compact bottom play-bar (`IconButton/list_bullet.svg`,
/// bulleted list). A slimmer alternative to [AmllPlaylistIcon]. viewBox 36×36.
class AmllQueueIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllQueueIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(36, 36),
    paths: const [_kListBulletPath],
  );
}

/// AirPlay (concentric arcs over an upward triangle) — AMLL's bottom-left glyph.
/// viewBox 64×64 — `IconButton/airplay.svg`.
class AmllAirplayIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllAirplayIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(64, 64),
    paths: const [_kAirplayPath],
  );
}

/// Overflow / more (···). viewBox 24×24 — `MenuButton/icon_more.svg`.
class AmllMoreIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllMoreIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(24, 24),
    paths: const [_kMorePath],
  );
}

/// Volume-low speaker (body only). viewBox 32×40 —
/// `VolumeControlSlider/icon_speaker.svg`.
class AmllVolumeLowIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllVolumeLowIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(32, 40),
    paths: const [_kSpeakerBody],
  );
}

/// Volume-high speaker (body + three sound waves). viewBox 43×40 —
/// `VolumeControlSlider/icon_speaker_3.svg`.
class AmllVolumeHighIcon extends StatelessWidget {
  final double size;
  final Color color;
  const AmllVolumeHighIcon({super.key, this.size = 24, this.color = _kWhite});

  @override
  Widget build(BuildContext context) => _AmllGlyph(
    size: size,
    color: color,
    viewBox: const Size(43, 40),
    paths: const [
      _kSpeaker3Body,
      _kSpeaker3Wave1,
      _kSpeaker3Wave2,
      _kSpeaker3Wave3,
    ],
  );
}

// ---------------------------------------------------------------------------
// Rendering plumbing
// ---------------------------------------------------------------------------

const Color _kWhite = Color(0xFFFFFFFF);

/// Shared glyph widget: sizes a square (or aspect-fit) box and fills the parsed
/// paths with [color] via [_GlyphPainter].
class _AmllGlyph extends StatelessWidget {
  final double size;
  final Color color;
  final Size viewBox;
  final List<String> paths;

  const _AmllGlyph({
    required this.size,
    required this.color,
    required this.viewBox,
    required this.paths,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _GlyphPainter(paths: paths, viewBox: viewBox, color: color),
      isComplex: true,
    ),
  );
}

/// Fills a set of SVG sub-paths (all sharing one viewBox) into the paint box,
/// aspect-fit and centred. Even-odd fill matches SVG `fill-rule` for the glyphs
/// whose source declares it (the two-tone toggles); it is harmless for the rest.
class _GlyphPainter extends CustomPainter {
  final List<String> paths;
  final Size viewBox;
  final Color color;

  _GlyphPainter({
    required this.paths,
    required this.viewBox,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final ui.Path path = ui.Path()..fillType = PathFillType.evenOdd;
    for (final String d in paths) {
      path.addPath(_parseSvgPath(d), Offset.zero);
    }

    final double scale = _fitScale(viewBox, size);
    final double dx = (size.width - viewBox.width * scale) / 2;
    final double dy = (size.height - viewBox.height * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);
    canvas.drawPath(path, Paint()..color = color..isAntiAlias = true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlyphPainter old) =>
      old.color != color || old.viewBox != viewBox || old.paths != paths;
}

/// Draws the repeat loop plus a centred `1` numeral.
class _RepeatOnePainter extends CustomPainter {
  final Color color;
  static const Size _vb = Size(56, 56);

  _RepeatOnePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = _fitScale(_vb, size);
    final double dx = (size.width - _vb.width * scale) / 2;
    final double dy = (size.height - _vb.height * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);
    canvas.drawPath(
      _parseSvgPath(_kRepeatPath),
      Paint()..color = color..isAntiAlias = true,
    );
    canvas.restore();

    // The "1" — a thin rounded bar with a short diagonal flag, echoing the
    // numeral in AMLL's repeat_on_one glyph, centred over the loop.
    final double s = size.shortestSide;
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final double barW = s * 0.055;
    final double barH = s * 0.30;
    final Paint p = Paint()
      ..color = color
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final ui.Path one = ui.Path()
      ..moveTo(cx - barW * 1.6, cy - barH * 0.28)
      ..lineTo(cx + barW * 0.5, cy - barH * 0.5)
      ..lineTo(cx + barW * 0.5, cy + barH * 0.5)
      ..lineTo(cx + barW * 1.5, cy + barH * 0.5)
      ..lineTo(cx + barW * 1.5, cy + barH * 0.5 + barW)
      ..lineTo(cx - barW * 1.5, cy + barH * 0.5 + barW)
      ..lineTo(cx - barW * 1.5, cy + barH * 0.5)
      ..lineTo(cx - barW * 0.5, cy + barH * 0.5)
      ..lineTo(cx - barW * 0.5, cy - barH * 0.18)
      ..lineTo(cx - barW * 1.6, cy - barH * 0.05)
      ..close();
    canvas.drawPath(one, p);
  }

  @override
  bool shouldRepaint(covariant _RepeatOnePainter old) => old.color != color;
}

/// Aspect-fit scale that keeps the whole viewBox inside [dst].
double _fitScale(Size viewBox, Size dst) {
  final double sx = dst.width / viewBox.width;
  final double sy = dst.height / viewBox.height;
  return sx < sy ? sx : sy;
}

// ---------------------------------------------------------------------------
// Minimal SVG path-data parser
//
// Supports M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z with implicit command
// repetition — the full set of commands appearing in AMLL's icon SVGs (plus
// robustness spares). Absolute + relative are both handled.
// ---------------------------------------------------------------------------

final RegExp _kTokenRe = RegExp(
  r'([MmLlHhVvCcSsQqTtAaZz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)',
);

ui.Path _parseSvgPath(String d) {
  final path = ui.Path();
  final List<_Tok> toks = <_Tok>[];
  for (final Match m in _kTokenRe.allMatches(d)) {
    if (m.group(1) != null) {
      toks.add(_Tok.cmd(m.group(1)!));
    } else {
      toks.add(_Tok.num(double.parse(m.group(2)!)));
    }
  }

  int i = 0;
  double cx = 0, cy = 0; // current point
  double sx = 0, sy = 0; // sub-path start
  double px = 0, py = 0; // previous control point (for S/T reflection)
  String prevCmd = '';
  String cmd = '';

  double num() => toks[i++].value;

  while (i < toks.length) {
    if (toks[i].isCmd) {
      cmd = toks[i++].cmdChar;
    } else {
      // Implicit repeat: an M/m becomes L/l on repetition, others repeat as-is.
      if (cmd == 'M') {
        cmd = 'L';
      } else if (cmd == 'm') {
        cmd = 'l';
      }
    }
    final bool rel = cmd == cmd.toLowerCase();

    switch (cmd.toUpperCase()) {
      case 'M':
        double x = num(), y = num();
        if (rel) {
          x += cx;
          y += cy;
        }
        cx = x;
        cy = y;
        sx = x;
        sy = y;
        path.moveTo(cx, cy);
        break;
      case 'L':
        double x = num(), y = num();
        if (rel) {
          x += cx;
          y += cy;
        }
        cx = x;
        cy = y;
        path.lineTo(cx, cy);
        break;
      case 'H':
        double x = num();
        if (rel) x += cx;
        cx = x;
        path.lineTo(cx, cy);
        break;
      case 'V':
        double y = num();
        if (rel) y += cy;
        cy = y;
        path.lineTo(cx, cy);
        break;
      case 'C':
        double x1 = num(), y1 = num(), x2 = num(), y2 = num(), x = num(), y = num();
        if (rel) {
          x1 += cx;
          y1 += cy;
          x2 += cx;
          y2 += cy;
          x += cx;
          y += cy;
        }
        path.cubicTo(x1, y1, x2, y2, x, y);
        px = x2;
        py = y2;
        cx = x;
        cy = y;
        break;
      case 'S':
        double x2 = num(), y2 = num(), x = num(), y = num();
        if (rel) {
          x2 += cx;
          y2 += cy;
          x += cx;
          y += cy;
        }
        final bool sm = prevCmd.toUpperCase() == 'C' || prevCmd.toUpperCase() == 'S';
        final double x1 = sm ? 2 * cx - px : cx;
        final double y1 = sm ? 2 * cy - py : cy;
        path.cubicTo(x1, y1, x2, y2, x, y);
        px = x2;
        py = y2;
        cx = x;
        cy = y;
        break;
      case 'Q':
        double x1 = num(), y1 = num(), x = num(), y = num();
        if (rel) {
          x1 += cx;
          y1 += cy;
          x += cx;
          y += cy;
        }
        path.quadraticBezierTo(x1, y1, x, y);
        px = x1;
        py = y1;
        cx = x;
        cy = y;
        break;
      case 'T':
        double x = num(), y = num();
        if (rel) {
          x += cx;
          y += cy;
        }
        final bool sm = prevCmd.toUpperCase() == 'Q' || prevCmd.toUpperCase() == 'T';
        final double x1 = sm ? 2 * cx - px : cx;
        final double y1 = sm ? 2 * cy - py : cy;
        path.quadraticBezierTo(x1, y1, x, y);
        px = x1;
        py = y1;
        cx = x;
        cy = y;
        break;
      case 'A':
        // Elliptical arc — unused by AMLL's icons; consume 7 params and fall
        // back to a straight line to the endpoint so the parser stays total.
        num();
        num();
        num();
        num();
        num();
        double x = num(), y = num();
        if (rel) {
          x += cx;
          y += cy;
        }
        cx = x;
        cy = y;
        path.lineTo(cx, cy);
        break;
      case 'Z':
        path.close();
        cx = sx;
        cy = sy;
        break;
    }
    prevCmd = cmd;
  }
  return path;
}

class _Tok {
  final bool isCmd;
  final String cmdChar;
  final double value;
  const _Tok.cmd(this.cmdChar) : isCmd = true, value = 0;
  const _Tok.num(this.value) : isCmd = false, cmdChar = '';
}

// ---------------------------------------------------------------------------
// Raw path data (verbatim from AMLL SVGs)
// ---------------------------------------------------------------------------

const String _kPlayPath =
    'M5.80762 32.4896V5.4925C5.80762 4.305 6.12305 3.41438 6.75391 2.82063C7.38477 2.22688 8.13932 1.93 9.01758 1.93C9.78451 1.93 10.5391 2.14029 11.2812 2.56086L33.7324 15.6605C34.5859 16.1553 35.223 16.6562 35.6436 17.1634C36.0641 17.6582 36.2744 18.2705 36.2744 19.0003C36.2744 19.7054 36.0641 20.3177 35.6436 20.8372C35.223 21.3444 34.5859 21.8392 33.7324 22.3216L11.2812 35.4212C10.5391 35.8542 9.78451 36.0706 9.01758 36.0706C8.13932 36.0706 7.38477 35.7676 6.75391 35.1614C6.12305 34.5677 5.80762 33.6771 5.80762 32.4896Z';

const String _kPausePath =
    'M8.46953 37C7.37801 37 6.56603 36.7271 6.03359 36.1814C5.51445 35.6489 5.25488 34.8502 5.25488 33.7854V4.21464C5.25488 3.14975 5.52111 2.35108 6.05355 1.81864C6.59931 1.27288 7.40463 1 8.46953 1H13.3813C14.4329 1 15.2249 1.27288 15.7574 1.81864C16.3031 2.35108 16.576 3.14975 16.576 4.21464V33.7854C16.576 34.8502 16.3031 35.6489 15.7574 36.1814C15.2249 36.7271 14.4329 37 13.3813 37H8.46953ZM24.6426 37C23.5644 37 22.759 36.7271 22.2266 36.1814C21.6942 35.6489 21.4279 34.8502 21.4279 33.7854V4.21464C21.4279 3.14975 21.6942 2.35108 22.2266 1.81864C22.7724 1.27288 23.5777 1 24.6426 1H29.5544C30.6193 1 31.4179 1.27288 31.9504 1.81864C32.4828 2.35108 32.7491 3.14975 32.7491 4.21464V33.7854C32.7491 34.8502 32.4828 35.6489 31.9504 36.1814C31.4179 36.7271 30.6193 37 29.5544 37H24.6426Z';

const String _kForwardLeftArrow =
    'M62 60.0717C65.938 62.3453 67.9069 63.4821 68.5677 64.9662C69.1441 66.2608 69.1441 67.7391 68.5677 69.0336C67.9069 70.5177 65.938 71.6545 62 73.9281L41 86.0525C37.062 88.326 35.0931 89.4628 33.4774 89.293C32.0681 89.1449 30.7878 88.4057 29.9549 87.2593C29 85.945 29 83.6714 29 79.1243V54.8755C29 50.3284 29 48.0548 29.9549 46.7405C30.7878 45.5941 32.0681 44.8549 33.4774 44.7068C35.0931 44.537 37.062 45.6738 41 47.9473L62 60.0717Z';

const String _kForwardRightArrow =
    'M102 60.0717C105.938 62.3453 107.907 63.4821 108.568 64.9662C109.144 66.2608 109.144 67.7391 108.568 69.0336C107.907 70.5177 105.938 71.6545 102 73.9281L81 86.0525C77.062 88.326 75.0931 89.4628 73.4774 89.293C72.0681 89.1449 70.7878 88.4057 69.9549 87.2593C69 85.945 69 83.6714 69 79.1243V54.8755C69 50.3284 69 48.0548 69.9549 46.7405C70.7878 45.5941 72.0681 44.8549 73.4774 44.7068C75.0931 44.537 77.062 45.6738 81 47.9473L102 60.0717Z';

const String _kRewindRightArrow =
    'M72 60.0717C68.062 62.3453 66.0931 63.4821 65.4323 64.9662C64.8559 66.2608 64.8559 67.7391 65.4323 69.0336C66.0931 70.5177 68.062 71.6545 72 73.9281L93 86.0525C96.938 88.326 98.9069 89.4628 100.523 89.293C101.932 89.1449 103.212 88.4057 104.045 87.2593C105 85.945 105 83.6714 105 79.1243V54.8755C105 50.3284 105 48.0548 104.045 46.7405C103.212 45.5941 101.932 44.8549 100.523 44.7068C98.9069 44.537 96.938 45.6738 93 47.9473L72 60.0717Z';

const String _kRewindLeftArrow =
    'M32 60.0717C28.062 62.3453 26.0931 63.4821 25.4323 64.9662C24.8559 66.2608 24.8559 67.7391 25.4323 69.0336C26.0931 70.5177 28.062 71.6545 32 73.9281L53 86.0525C56.938 88.326 58.9069 89.4628 60.5226 89.293C61.9319 89.1449 63.2122 88.4057 64.0451 87.2593C65 85.945 65 83.6714 65 79.1243V54.8755C65 50.3284 65 48.0548 64.0451 46.7405C63.2122 45.5941 61.9319 44.8549 60.5226 44.7068C58.9069 44.537 56.938 45.6738 53 47.9473L32 60.0717Z';

const String _kShufflePath =
    'M10.624 36.3125C10.624 35.75 10.8218 35.2754 11.2173 34.8887C11.6216 34.4932 12.1094 34.2954 12.6807 34.2954H15.4756C16.3896 34.2954 17.1455 34.1372 17.7432 33.8208C18.3496 33.5044 18.9341 32.9946 19.4966 32.2915L27.3936 22.3379C28.3955 21.0811 29.4282 20.2285 30.4917 19.7803C31.5552 19.332 32.79 19.1079 34.1963 19.1079H36.4243V16.1548C36.4243 15.6714 36.5605 15.2935 36.833 15.021C37.1055 14.7397 37.479 14.5991 37.9536 14.5991C38.1821 14.5991 38.3843 14.6343 38.5601 14.7046C38.7446 14.7749 38.9072 14.8672 39.0479 14.9814L44.8223 19.8857C45.1826 20.1846 45.3628 20.5493 45.3628 20.98C45.3628 21.4106 45.1826 21.7754 44.8223 22.0742L39.0479 26.9917C38.9072 27.106 38.7446 27.2026 38.5601 27.2817C38.3843 27.3521 38.1821 27.3872 37.9536 27.3872C37.479 27.3872 37.1055 27.2466 36.833 26.9653C36.5605 26.6841 36.4243 26.3018 36.4243 25.8184V23.1421H33.9194C33.3218 23.1421 32.8076 23.2036 32.377 23.3267C31.9551 23.4497 31.564 23.6562 31.2036 23.9463C30.8521 24.2275 30.4829 24.6143 30.0962 25.1064L21.606 35.7061C20.8853 36.6113 20.0986 37.2749 19.2461 37.6968C18.3936 38.1099 17.3389 38.3164 16.082 38.3164H12.6807C12.1094 38.3164 11.6216 38.123 11.2173 37.7363C10.8218 37.3496 10.624 36.875 10.624 36.3125ZM10.624 21.125C10.624 20.5625 10.8218 20.0879 11.2173 19.7012C11.6216 19.3057 12.1094 19.1079 12.6807 19.1079H15.7261C16.9829 19.1079 18.0947 19.3188 19.0615 19.7407C20.0371 20.1538 20.8853 20.8174 21.606 21.7314L30.0435 32.2783C30.5972 32.9727 31.1992 33.4824 31.8496 33.8076C32.5 34.1328 33.291 34.2954 34.2227 34.2954H36.4243V31.5664C36.4243 31.083 36.5605 30.7007 36.833 30.4194C37.1055 30.1382 37.479 29.9976 37.9536 29.9976C38.1821 29.9976 38.3843 30.0371 38.5601 30.1162C38.7446 30.1865 38.9072 30.2832 39.0479 30.4062L44.8223 35.2974C45.1826 35.5962 45.3628 35.9609 45.3628 36.3916C45.3628 36.8223 45.1826 37.187 44.8223 37.4858L39.0479 42.3901C38.9072 42.5132 38.7446 42.6099 38.5601 42.6802C38.3843 42.7593 38.1821 42.7988 37.9536 42.7988C37.479 42.7988 37.1055 42.6582 36.833 42.377C36.5605 42.0957 36.4243 41.7134 36.4243 41.23V38.3164H34.1699C32.9043 38.3164 31.7222 38.1011 30.6235 37.6704C29.5249 37.231 28.5625 36.4927 27.7363 35.4556L19.4966 25.146C18.9341 24.4429 18.2925 23.9331 17.5718 23.6167C16.8599 23.3003 16.0381 23.1421 15.1064 23.1421H12.6807C12.1094 23.1421 11.6216 22.9443 11.2173 22.5488C10.8218 22.1533 10.624 21.6787 10.624 21.125Z';

const String _kRepeatPath =
    'M14.2495 28.9956C13.6519 28.9956 13.1465 28.7891 12.7334 28.376C12.3203 27.9541 12.1138 27.4531 12.1138 26.873V25.3438C12.1138 23.832 12.4565 22.5312 13.1421 21.4414C13.8276 20.3516 14.8076 19.5166 16.082 18.9365C17.3564 18.3477 18.877 18.0532 20.6436 18.0532H30.3599V15.4033C30.3599 14.9111 30.4961 14.5288 30.7686 14.2563C31.041 13.9751 31.4146 13.8345 31.8892 13.8345C32.1177 13.8345 32.3198 13.874 32.4956 13.9531C32.6714 14.0234 32.8296 14.1113 32.9702 14.2168L38.7578 19.1343C39.1182 19.4331 39.2939 19.7979 39.2852 20.2285C39.2852 20.6504 39.1094 21.0107 38.7578 21.3096L32.9702 26.2271C32.8296 26.3501 32.6714 26.4468 32.4956 26.5171C32.3198 26.5874 32.1177 26.6226 31.8892 26.6226C31.4146 26.6226 31.041 26.4819 30.7686 26.2007C30.4961 25.9194 30.3599 25.5415 30.3599 25.0669V22.1929H20.459C19.1846 22.1929 18.1826 22.5269 17.4531 23.1948C16.7236 23.8628 16.3589 24.7812 16.3589 25.9502V26.873C16.3589 27.4531 16.1523 27.9541 15.7393 28.376C15.3262 28.7891 14.8296 28.9956 14.2495 28.9956ZM41.7505 26.7017C42.3306 26.7017 42.8271 26.9082 43.2402 27.3213C43.6621 27.7344 43.873 28.2354 43.873 28.8242V30.3535C43.873 31.8652 43.5303 33.166 42.8447 34.2559C42.1592 35.3457 41.1792 36.1851 39.9048 36.7739C38.6304 37.354 37.1055 37.644 35.3301 37.644H25.627V40.2676C25.627 40.751 25.4907 41.1333 25.2183 41.4146C24.9458 41.6958 24.5723 41.8364 24.0977 41.8364C23.8691 41.8364 23.6626 41.7969 23.478 41.7178C23.3022 41.6475 23.1484 41.5552 23.0166 41.4409L17.2158 36.5366C16.873 36.2466 16.6973 35.8862 16.6885 35.4556C16.6885 35.0249 16.8643 34.6558 17.2158 34.3481L23.0166 29.4307C23.1484 29.3164 23.3022 29.2241 23.478 29.1538C23.6626 29.0835 23.8691 29.0483 24.0977 29.0483C24.5723 29.0483 24.9458 29.189 25.2183 29.4702C25.4907 29.7427 25.627 30.125 25.627 30.6172V33.4912H35.5278C36.8022 33.4912 37.8042 33.1616 38.5337 32.5024C39.2632 31.8345 39.6279 30.916 39.6279 29.7471V28.8242C39.6279 28.2354 39.8301 27.7344 40.2344 27.3213C40.6475 26.9082 41.1528 26.7017 41.7505 26.7017Z';

const String _kLyricsPath =
    'M22.8594 53.9102C22 53.9102 21.3229 53.6302 20.8281 53.0703C20.3464 52.5104 20.1055 51.7617 20.1055 50.8242V46.1953H18.9727C17.1237 46.1953 15.5156 45.8242 14.1484 45.082C12.7812 44.3398 11.7201 43.2721 10.9648 41.8789C10.2227 40.4857 9.85156 38.8125 9.85156 36.8594V21.5664C9.85156 19.6133 10.2161 17.9401 10.9453 16.5469C11.6875 15.1536 12.7552 14.0859 14.1484 13.3438C15.5417 12.5885 17.2214 12.2109 19.1875 12.2109H44.793C46.7721 12.2109 48.4518 12.5885 49.832 13.3438C51.2253 14.0859 52.2865 15.1536 53.0156 16.5469C53.7578 17.9401 54.1289 19.6133 54.1289 21.5664V36.8594C54.1289 38.8125 53.7578 40.4857 53.0156 41.8789C52.2865 43.2721 51.2253 44.3398 49.832 45.082C48.4518 45.8242 46.7721 46.1953 44.793 46.1953H33.0742L26.4336 52.0547C25.7044 52.6927 25.0729 53.1615 24.5391 53.4609C24.0182 53.7604 23.4583 53.9102 22.8594 53.9102ZM23.9141 49.0469L30.0859 42.9727C30.5156 42.5299 30.9193 42.237 31.2969 42.0938C31.6745 41.9375 32.1758 41.8594 32.8008 41.8594H44.5977C46.3424 41.8594 47.6445 41.4232 48.5039 40.5508C49.3633 39.6784 49.793 38.3828 49.793 36.6641V21.7422C49.793 20.0365 49.3633 18.7474 48.5039 17.875C47.6445 17.0026 46.3424 16.5664 44.5977 16.5664H19.3828C17.625 16.5664 16.3164 17.0026 15.457 17.875C14.6107 18.7474 14.1875 20.0365 14.1875 21.7422V36.6641C14.1875 38.3828 14.6107 39.6784 15.457 40.5508C16.3164 41.4232 17.625 41.8594 19.3828 41.8594H22.2344C22.8073 41.8594 23.2305 41.9896 23.5039 42.25C23.7773 42.4974 23.9141 42.9271 23.9141 43.5391V49.0469ZM22.4492 27.1914C22.4492 25.9935 22.8529 25.0104 23.6602 24.2422C24.4674 23.474 25.4701 23.0898 26.668 23.0898C28.0221 23.0898 29.1029 23.5716 29.9102 24.5352C30.7305 25.4857 31.1406 26.6576 31.1406 28.0508C31.1406 29.2096 30.9323 30.2383 30.5156 31.1367C30.112 32.0221 29.5911 32.7708 28.9531 33.3828C28.3281 33.9948 27.6771 34.457 27 34.7695C26.3229 35.082 25.7174 35.2383 25.1836 35.2383C24.8841 35.2383 24.6367 35.1536 24.4414 34.9844C24.2461 34.8151 24.1484 34.5938 24.1484 34.3203C24.1484 34.0859 24.2135 33.8906 24.3438 33.7344C24.487 33.5651 24.7214 33.4414 25.0469 33.3633C25.5677 33.2331 26.0625 33.0312 26.5312 32.7578C27.013 32.4714 27.4362 32.1328 27.8008 31.7422C28.1654 31.3385 28.4453 30.8828 28.6406 30.375H28.3867C28.1263 30.7005 27.7943 30.9284 27.3906 31.0586C26.987 31.1758 26.5573 31.2344 26.1016 31.2344C25.0078 31.2344 24.1224 30.8503 23.4453 30.082C22.7812 29.3008 22.4492 28.3372 22.4492 27.1914ZM33.0742 27.1914C33.0742 25.9935 33.4714 25.0104 34.2656 24.2422C35.0729 23.474 36.082 23.0898 37.293 23.0898C38.6471 23.0898 39.7279 23.5716 40.5352 24.5352C41.3555 25.4857 41.7656 26.6576 41.7656 28.0508C41.7656 29.2096 41.5573 30.2383 41.1406 31.1367C40.737 32.0221 40.2161 32.7708 39.5781 33.3828C38.9531 33.9948 38.2956 34.457 37.6055 34.7695C36.9284 35.082 36.3294 35.2383 35.8086 35.2383C35.5091 35.2383 35.2617 35.1536 35.0664 34.9844C34.8711 34.8151 34.7734 34.5938 34.7734 34.3203C34.7734 34.0859 34.8385 33.8906 34.9688 33.7344C35.112 33.5651 35.3529 33.4414 35.6914 33.3633C36.1992 33.2331 36.6875 33.0312 37.1562 32.7578C37.638 32.4714 38.0612 32.1328 38.4258 31.7422C38.7904 31.3385 39.0703 30.8828 39.2656 30.375H39.0117C38.7513 30.7005 38.4193 30.9284 38.0156 31.0586C37.612 31.1758 37.1823 31.2344 36.7266 31.2344C35.6328 31.2344 34.7474 30.8503 34.0703 30.082C33.4062 29.3008 33.0742 28.3372 33.0742 27.1914Z';

/// `ToggleIconButton/lyrics_on.svg`, first path (fill-rule="evenodd"):
/// the filled 64×64 rounded-square plate with the speech-bubble contour as an
/// even-odd hole punched out of it. Verbatim from AMLL.
const String _kLyricsOnPlatePath =
    'M1.91256 7.67068C0 11.0858 0 15.6405 0 24.75V39.25C0 48.3595 0 52.9142 1.91256 56.3293C3.26425 58.7429 5.25707 60.7357 7.67068 62.0874C11.0858 64 15.6405 64 24.75 64H39.25C48.3595 64 52.9142 64 56.3293 62.0874C58.7429 60.7357 60.7357 58.7429 62.0874 56.3293C64 52.9142 64 48.3595 64 39.25V24.75C64 15.6405 64 11.0858 62.0874 7.67068C60.7357 5.25707 58.7429 3.26425 56.3293 1.91256C52.9142 0 48.3595 0 39.25 0H24.75C15.6405 0 11.0858 0 7.67068 1.91256C5.25707 3.26425 3.26425 5.25707 1.91256 7.67068ZM20.8281 53.0703C21.3229 53.6302 22 53.9102 22.8594 53.9102C23.4583 53.9102 24.0182 53.7604 24.5391 53.4609C25.0729 53.1615 25.7044 52.6927 26.4336 52.0547L33.0742 46.1953H44.793C46.7721 46.1953 48.4518 45.8242 49.832 45.082C51.2253 44.3398 52.2865 43.2721 53.0156 41.8789C53.7578 40.4857 54.1289 38.8125 54.1289 36.8594V21.5664C54.1289 19.6133 53.7578 17.9401 53.0156 16.5469C52.2865 15.1536 51.2253 14.0859 49.832 13.3438C48.4518 12.5885 46.7721 12.2109 44.793 12.2109H19.1875C17.2214 12.2109 15.5417 12.5885 14.1484 13.3438C12.7552 14.0859 11.6875 15.1536 10.9453 16.5469C10.2161 17.9401 9.85156 19.6133 9.85156 21.5664V36.8594C9.85156 38.8125 10.2227 40.4857 10.9648 41.8789C11.7201 43.2721 12.7812 44.3398 14.1484 45.082C15.5156 45.8242 17.1237 46.1953 18.9727 46.1953H20.1055V50.8242C20.1055 51.7617 20.3464 52.5104 20.8281 53.0703Z';

/// `ToggleIconButton/lyrics_on.svg`, second path: the two quote marks that sit
/// inside the knocked-out bubble. Verbatim from AMLL.
const String _kLyricsQuotesPath =
    'M22.4492 27.1914C22.4492 25.9935 22.8529 25.0104 23.6602 24.2422C24.4674 23.474 25.4701 23.0898 26.668 23.0898C28.0221 23.0898 29.1029 23.5716 29.9102 24.5352C30.7305 25.4857 31.1406 26.6576 31.1406 28.0508C31.1406 29.2096 30.9323 30.2383 30.5156 31.1367C30.112 32.0221 29.5911 32.7708 28.9531 33.3828C28.3281 33.9948 27.6771 34.457 27 34.7695C26.3229 35.082 25.7174 35.2383 25.1836 35.2383C24.8841 35.2383 24.6367 35.1536 24.4414 34.9844C24.2461 34.8151 24.1484 34.5938 24.1484 34.3203C24.1484 34.0859 24.2135 33.8906 24.3438 33.7344C24.487 33.5651 24.7214 33.4414 25.0469 33.3633C25.5677 33.2331 26.0625 33.0312 26.5312 32.7578C27.013 32.4714 27.4362 32.1328 27.8008 31.7422C28.1654 31.3385 28.4453 30.8828 28.6406 30.375H28.3867C28.1263 30.7005 27.7943 30.9284 27.3906 31.0586C26.987 31.1758 26.5573 31.2344 26.1016 31.2344C25.0078 31.2344 24.1224 30.8503 23.4453 30.082C22.7812 29.3008 22.4492 28.3372 22.4492 27.1914ZM33.0742 27.1914C33.0742 25.9935 33.4714 25.0104 34.2656 24.2422C35.0729 23.474 36.082 23.0898 37.293 23.0898C38.6471 23.0898 39.7279 23.5716 40.5352 24.5352C41.3555 25.4857 41.7656 26.6576 41.7656 28.0508C41.7656 29.2096 41.5573 30.2383 41.1406 31.1367C40.737 32.0221 40.2161 32.7708 39.5781 33.3828C38.9531 33.9948 38.2956 34.457 37.6055 34.7695C36.9284 35.082 36.3294 35.2383 35.8086 35.2383C35.5091 35.2383 35.2617 35.1536 35.0664 34.9844C34.8711 34.8151 34.7734 34.5938 34.7734 34.3203C34.7734 34.0859 34.8385 33.8906 34.9688 33.7344C35.112 33.5651 35.3529 33.4414 35.6914 33.3633C36.1992 33.2331 36.6875 33.0312 37.1562 32.7578C37.638 32.4714 38.0612 32.1328 38.4258 31.7422C38.7904 31.3385 39.0703 30.8828 39.2656 30.375H39.0117C38.7513 30.7005 38.4193 30.9284 38.0156 31.0586C37.612 31.1758 37.1823 31.2344 36.7266 31.2344C35.6328 31.2344 34.7474 30.8503 34.0703 30.082C33.4062 29.3008 33.0742 28.3372 33.0742 27.1914Z';

const String _kPlaylistPath =
    'M23.9922 21.8594C23.4062 21.8594 22.9115 21.6641 22.5078 21.2734C22.1172 20.8698 21.9219 20.375 21.9219 19.7891C21.9219 19.2161 22.1172 18.7279 22.5078 18.3242C22.9115 17.9206 23.4062 17.7188 23.9922 17.7188H50.418C50.9909 17.7188 51.4792 17.9206 51.8828 18.3242C52.2865 18.7279 52.4883 19.2161 52.4883 19.7891C52.4883 20.375 52.2865 20.8698 51.8828 21.2734C51.4792 21.6641 50.9909 21.8594 50.418 21.8594H23.9922ZM23.9922 33.9883C23.4062 33.9883 22.9115 33.7865 22.5078 33.3828C22.1172 32.9792 21.9219 32.4909 21.9219 31.918C21.9219 31.3451 22.1172 30.8633 22.5078 30.4727C22.9115 30.069 23.4062 29.8672 23.9922 29.8672H50.418C50.9909 29.8672 51.4792 30.069 51.8828 30.4727C52.2865 30.8633 52.4883 31.3451 52.4883 31.918C52.4883 32.5039 52.2865 32.9987 51.8828 33.4023C51.4792 33.793 50.9909 33.9883 50.418 33.9883H23.9922ZM23.9922 46.1172C23.4062 46.1172 22.9115 45.9219 22.5078 45.5312C22.1172 45.1276 21.9219 44.6328 21.9219 44.0469C21.9219 43.474 22.1172 42.9857 22.5078 42.582C22.9115 42.1784 23.4062 41.9766 23.9922 41.9766H50.418C50.9909 41.9766 51.4792 42.1784 51.8828 42.582C52.2865 42.9857 52.4883 43.474 52.4883 44.0469C52.4883 44.6328 52.2865 45.1276 51.8828 45.5312C51.4792 45.9219 50.9909 46.1172 50.418 46.1172H23.9922ZM14.4805 22.7383C13.6602 22.7383 12.957 22.4518 12.3711 21.8789C11.7982 21.306 11.5117 20.6094 11.5117 19.7891C11.5117 18.9688 11.7982 18.2721 12.3711 17.6992C12.957 17.1263 13.6602 16.8398 14.4805 16.8398C15.2878 16.8398 15.9844 17.1263 16.5703 17.6992C17.1562 18.2721 17.4492 18.9688 17.4492 19.7891C17.4492 20.6094 17.1562 21.306 16.5703 21.8789C15.9844 22.4518 15.2878 22.7383 14.4805 22.7383ZM14.4805 34.8867C13.6602 34.8867 12.957 34.5938 12.3711 34.0078C11.7982 33.4219 11.5117 32.7253 11.5117 31.918C11.5117 31.1107 11.7982 30.4141 12.3711 29.8281C12.957 29.2422 13.6602 28.9492 14.4805 28.9492C15.2878 28.9492 15.9844 29.2422 16.5703 29.8281C17.1562 30.4141 17.4492 31.1107 17.4492 31.918C17.4492 32.7253 17.1562 33.4219 16.5703 34.0078C15.9844 34.5938 15.2878 34.8867 14.4805 34.8867ZM14.4805 47.0156C13.6602 47.0156 12.957 46.7227 12.3711 46.1367C11.7982 45.5638 11.5117 44.8672 11.5117 44.0469C11.5117 43.2266 11.7982 42.5299 12.3711 41.957C12.957 41.3841 13.6602 41.0977 14.4805 41.0977C15.2878 41.0977 15.9844 41.3841 16.5703 41.957C17.1562 42.5299 17.4492 43.2266 17.4492 44.0469C17.4492 44.8672 17.1562 45.5638 16.5703 46.1367C15.9844 46.7227 15.2878 47.0156 14.4805 47.0156Z';

const String _kListBulletPath =
    'M11.8037 10.397C11.4131 10.397 11.0811 10.2652 10.8076 10.0015C10.5439 9.72809 10.4121 9.39606 10.4121 9.00543C10.4121 8.61481 10.5439 8.28766 10.8076 8.02399C11.0811 7.75055 11.4131 7.61383 11.8037 7.61383H31.6963C32.0869 7.61383 32.4189 7.75055 32.6924 8.02399C32.9658 8.28766 33.1025 8.61481 33.1025 9.00543C33.1025 9.40582 32.9658 9.73785 32.6924 10.0015C32.4189 10.2652 32.0869 10.397 31.6963 10.397H11.8037ZM11.8037 19.3912C11.4131 19.3912 11.0811 19.2593 10.8076 18.9957C10.5439 18.7222 10.4121 18.3902 10.4121 17.9996C10.4121 17.6089 10.5439 17.2818 10.8076 17.0181C11.0811 16.7447 11.4131 16.608 11.8037 16.608H31.6963C32.0869 16.608 32.4189 16.7447 32.6924 17.0181C32.9658 17.2818 33.1025 17.6089 33.1025 17.9996C33.1025 18.3902 32.9658 18.7222 32.6924 18.9957C32.4189 19.2593 32.0869 19.3912 31.6963 19.3912H11.8037ZM11.8037 28.3853C11.4131 28.3853 11.0811 28.2535 10.8076 27.9898C10.5439 27.7261 10.4121 27.399 10.4121 27.0084C10.4121 26.608 10.5439 26.2759 10.8076 26.0123C11.0811 25.7388 11.4131 25.6021 11.8037 25.6021H31.6963C32.0869 25.6021 32.4189 25.7388 32.6924 26.0123C32.9658 26.2857 33.1025 26.6177 33.1025 27.0084C33.1025 27.399 32.9658 27.7261 32.6924 27.9898C32.4189 28.2535 32.0869 28.3853 31.6963 28.3853H11.8037ZM4.94824 11.0709C4.38184 11.0709 3.89355 10.8707 3.4834 10.4703C3.08301 10.0699 2.88281 9.5816 2.88281 9.00543C2.88281 8.42926 3.08301 7.94098 3.4834 7.54059C3.89355 7.1402 4.38184 6.94 4.94824 6.94C5.51465 6.94 5.99805 7.1402 6.39844 7.54059C6.80859 7.94098 7.01367 8.42926 7.01367 9.00543C7.01367 9.5816 6.80859 10.0699 6.39844 10.4703C5.99805 10.8707 5.51465 11.0709 4.94824 11.0709ZM4.94824 20.065C4.38184 20.065 3.89355 19.8648 3.4834 19.4644C3.08301 19.0543 2.88281 18.566 2.88281 17.9996C2.88281 17.4332 3.08301 16.9498 3.4834 16.5494C3.89355 16.1392 4.38184 15.9341 4.94824 15.9341C5.51465 15.9341 5.99805 16.1392 6.39844 16.5494C6.80859 16.9498 7.01367 17.4332 7.01367 17.9996C7.01367 18.566 6.80859 19.0543 6.39844 19.4644C5.99805 19.8648 5.51465 20.065 4.94824 20.065ZM4.94824 29.0591C4.38184 29.0591 3.89355 28.8589 3.4834 28.4586C3.08301 28.0582 2.88281 27.5748 2.88281 27.0084C2.88281 26.4322 3.08301 25.9439 3.4834 25.5435C3.89355 25.1431 4.38184 24.9429 4.94824 24.9429C5.51465 24.9429 5.99805 25.1431 6.39844 25.5435C6.80859 25.9439 7.01367 26.4322 7.01367 27.0084C7.01367 27.5748 6.80859 28.0582 6.39844 28.4586C5.99805 28.8589 5.51465 29.0591 4.94824 29.0591Z';

const String _kAirplayPath =
    'M11.8633 31.8984C11.8633 29.138 12.3841 26.5469 13.4258 24.125C14.4674 21.6901 15.9128 19.5482 17.7617 17.6992C19.6107 15.8372 21.7526 14.3854 24.1875 13.3438C26.6224 12.2891 29.2266 11.7617 32 11.7617C34.7734 11.7617 37.3776 12.2891 39.8125 13.3438C42.2474 14.3854 44.3893 15.8372 46.2383 17.6992C48.0872 19.5482 49.5326 21.6901 50.5742 24.125C51.6159 26.5469 52.1367 29.138 52.1367 31.8984C52.1367 34.6719 51.6029 37.2826 50.5352 39.7305C49.4674 42.1784 48.0156 44.3073 46.1797 46.1172C46.0365 46.2604 45.8802 46.332 45.7109 46.332C45.5547 46.332 45.4049 46.2539 45.2617 46.0977L44.3438 45.0625C44.0964 44.763 44.1094 44.4635 44.3828 44.1641C45.9453 42.6016 47.1823 40.7656 48.0938 38.6562C49.0182 36.5339 49.4805 34.2812 49.4805 31.8984C49.4805 29.5026 49.0247 27.2565 48.1133 25.1602C47.2018 23.0508 45.9388 21.1953 44.3242 19.5938C42.7227 17.9792 40.8672 16.7161 38.7578 15.8047C36.6484 14.8932 34.3958 14.4375 32 14.4375C29.6042 14.4375 27.3516 14.8932 25.2422 15.8047C23.1328 16.7161 21.2708 17.9792 19.6562 19.5938C18.0547 21.1953 16.7982 23.0508 15.8867 25.1602C14.9753 27.2565 14.5195 29.5026 14.5195 31.8984C14.5195 34.2812 14.9753 36.5273 15.8867 38.6367C16.7982 40.7461 18.0417 42.5885 19.6172 44.1641C19.8776 44.4635 19.8841 44.7565 19.6367 45.043L18.7188 46.0781C18.5885 46.2344 18.4323 46.3125 18.25 46.3125C18.0807 46.3125 17.9245 46.2409 17.7812 46.0977C15.9583 44.2878 14.513 42.1654 13.4453 39.7305C12.3906 37.2826 11.8633 34.6719 11.8633 31.8984ZM17.5469 31.8984C17.5469 29.9193 17.918 28.0573 18.6602 26.3125C19.4154 24.5677 20.457 23.0312 21.7852 21.7031C23.1133 20.375 24.6497 19.3333 26.3945 18.5781C28.1393 17.8229 30.0078 17.4453 32 17.4453C33.9792 17.4453 35.8411 17.8229 37.5859 18.5781C39.3438 19.3333 40.8867 20.375 42.2148 21.7031C43.543 23.0312 44.5781 24.5677 45.3203 26.3125C46.0755 28.0573 46.4531 29.9193 46.4531 31.8984C46.4531 33.8255 46.0885 35.6419 45.3594 37.3477C44.6432 39.0404 43.6667 40.5312 42.4297 41.8203C42.2865 41.9766 42.1237 42.0547 41.9414 42.0547C41.7721 42.0547 41.6224 41.9766 41.4922 41.8203L40.5547 40.7852C40.3073 40.5117 40.3073 40.2122 40.5547 39.8867C41.5573 38.8581 42.3451 37.6602 42.918 36.293C43.4909 34.9128 43.7773 33.4479 43.7773 31.8984C43.7773 30.2839 43.4714 28.7669 42.8594 27.3477C42.2474 25.9284 41.3945 24.6784 40.3008 23.5977C39.2201 22.5169 37.9701 21.6706 36.5508 21.0586C35.1315 20.4336 33.6146 20.1211 32 20.1211C30.3724 20.1211 28.849 20.4336 27.4297 21.0586C26.0104 21.6706 24.7604 22.5169 23.6797 23.5977C22.599 24.6784 21.7526 25.9284 21.1406 27.3477C20.5286 28.7669 20.2227 30.2839 20.2227 31.8984C20.2227 33.4349 20.5026 34.8932 21.0625 36.2734C21.6354 37.6536 22.4232 38.8581 23.4258 39.8867C23.6732 40.2122 23.6732 40.5117 23.4258 40.7852L22.5078 41.8008C22.3776 41.957 22.2214 42.0417 22.0391 42.0547C21.8568 42.0547 21.694 41.9701 21.5508 41.8008C20.3138 40.5117 19.3372 39.0208 18.6211 37.3281C17.9049 35.6224 17.5469 33.8125 17.5469 31.8984ZM23.2305 31.8984C23.2305 30.2969 23.6276 28.832 24.4219 27.5039C25.2161 26.1758 26.2708 25.1146 27.5859 24.3203C28.9141 23.526 30.3854 23.1289 32 23.1289C33.6146 23.1289 35.0794 23.526 36.3945 24.3203C37.7227 25.1146 38.7839 26.1758 39.5781 27.5039C40.3724 28.832 40.7695 30.2969 40.7695 31.8984C40.7695 32.9661 40.5807 33.9753 40.2031 34.9258C39.8255 35.8633 39.3047 36.7031 38.6406 37.4453C38.5104 37.6276 38.3542 37.7188 38.1719 37.7188C38.0026 37.7188 37.8398 37.6406 37.6836 37.4844L36.7266 36.4688C36.4792 36.2214 36.4596 35.9414 36.668 35.6289C37.1237 35.1341 37.4753 34.5677 37.7227 33.9297C37.9701 33.2917 38.0938 32.6146 38.0938 31.8984C38.0938 30.7917 37.8138 29.776 37.2539 28.8516C36.707 27.9271 35.9714 27.1914 35.0469 26.6445C34.1224 26.0846 33.1068 25.8047 32 25.8047C30.8932 25.8047 29.8776 26.0846 28.9531 26.6445C28.0286 27.1914 27.2865 27.9271 26.7266 28.8516C26.1797 29.776 25.9062 30.7917 25.9062 31.8984C25.9062 32.6016 26.0299 33.2721 26.2773 33.9102C26.5247 34.5482 26.8698 35.1146 27.3125 35.6094C27.5078 35.9219 27.4883 36.2018 27.2539 36.4492L26.2969 37.4648C26.1406 37.6211 25.9714 37.6992 25.7891 37.6992C25.6198 37.6992 25.4701 37.6146 25.3398 37.4453C24.6758 36.7031 24.1549 35.8568 23.7773 34.9062C23.4128 33.9557 23.2305 32.9531 23.2305 31.8984ZM19.8906 51.3711C19.4089 51.3711 19.0898 51.1758 18.9336 50.7852C18.7773 50.3945 18.8555 50.0299 19.168 49.6914L31.1016 36.1758C31.3359 35.9023 31.6289 35.7656 31.9805 35.7656C32.332 35.7656 32.625 35.9023 32.8594 36.1758L44.8125 49.6914C45.112 50.0299 45.1836 50.3945 45.0273 50.7852C44.8711 51.1758 44.5586 51.3711 44.0898 51.3711H19.8906Z';

const String _kMorePath =
    'M5.5161,14.1665C5.8687,14.1665 6.1856,14.083 6.467,13.916C6.7485,13.749 6.9742,13.5264 7.1443,13.248C7.3144,12.9697 7.3994,12.6574 7.3994,12.311C7.3994,11.7977 7.217,11.3601 6.8521,10.9983C6.4871,10.6365 6.0418,10.4556 5.5161,10.4556C5.1759,10.4556 4.8652,10.5391 4.5837,10.7061C4.3023,10.873 4.0781,11.0972 3.9111,11.3787C3.7441,11.6601 3.6606,11.9709 3.6606,12.311C3.6606,12.6574 3.7441,12.9697 3.9111,13.248C4.0781,13.5264 4.3023,13.749 4.5837,13.916C4.8652,14.083 5.1759,14.1665 5.5161,14.1665ZM12.4092,14.1665C12.7555,14.1665 13.0679,14.083 13.3462,13.916C13.6245,13.749 13.8472,13.5264 14.0142,13.248C14.1812,12.9697 14.2646,12.6574 14.2646,12.311C14.2646,11.7977 14.0837,11.3601 13.7219,10.9983C13.3601,10.6365 12.9225,10.4556 12.4092,10.4556C12.069,10.4556 11.7582,10.5391 11.4768,10.7061C11.1954,10.873 10.9727,11.0972 10.8088,11.3787C10.6449,11.6601 10.563,11.9709 10.563,12.311C10.563,12.6574 10.6449,12.9697 10.8088,13.248C10.9727,13.5264 11.1954,13.749 11.4768,13.916C11.7582,14.083 12.069,14.1665 12.4092,14.1665ZM19.3022,14.1665C19.6424,14.1665 19.9532,14.083 20.2346,13.916C20.516,13.749 20.7402,13.5264 20.9072,13.248C21.0742,12.9697 21.1577,12.6574 21.1577,12.311C21.1577,11.7977 20.9768,11.3601 20.615,10.9983C20.2532,10.6365 19.8156,10.4556 19.3022,10.4556C18.9559,10.4556 18.6405,10.5391 18.356,10.7061C18.0715,10.873 17.8457,11.0972 17.6787,11.3787C17.5117,11.6601 17.4282,11.9709 17.4282,12.311C17.4282,12.6574 17.5117,12.9697 17.6787,13.248C17.8457,13.5264 18.0715,13.749 18.356,13.916C18.6405,14.083 18.9559,14.1665 19.3022,14.1665Z';

const String _kSpeakerBody =
    'M14.9042 27.1802C14.4202 27.1802 14.0473 26.9897 13.595 26.5612L10.3815 23.5461C10.3339 23.5065 10.2863 23.4906 10.2228 23.4906H8.01703C6.70778 23.4906 5.99365 22.7527 5.99365 21.38V18.4442C5.99365 17.0715 6.70778 16.3257 8.01703 16.3257H10.2307C10.2863 16.3257 10.3418 16.3019 10.3815 16.2622L13.595 13.2709C14.079 12.8107 14.4361 12.6282 14.8883 12.6282C15.6104 12.6282 16.142 13.1915 16.142 13.8977V25.9344C16.142 26.6406 15.6104 27.1802 14.9042 27.1802Z';

const String _kSpeaker3Body =
    'M24.0403 27.1802C23.5642 27.1802 23.1913 26.9897 22.739 26.5612L19.5176 23.5461C19.4779 23.5065 19.4224 23.4906 19.3668 23.4906H17.161C15.8518 23.4906 15.1377 22.7527 15.1377 21.38V18.4442C15.1377 17.0715 15.8518 16.3257 17.161 16.3257H19.3668C19.4303 16.3257 19.4779 16.3019 19.5255 16.2622L22.739 13.2709C23.223 12.8107 23.5721 12.6282 24.0324 12.6282C24.7544 12.6282 25.286 13.1915 25.286 13.8977V25.9344C25.286 26.6406 24.7544 27.1802 24.0403 27.1802Z';

const String _kSpeaker3Wave1 =
    'M28.0948 23.6653C27.6028 23.3559 27.4996 22.7687 27.8964 22.1101C28.2931 21.4991 28.5232 20.7136 28.5232 19.8964C28.5232 19.0712 28.301 18.2856 27.8964 17.6826C27.4917 17.032 27.6028 16.4369 28.0948 16.1274C28.547 15.8418 29.1104 15.9529 29.404 16.3576C30.0863 17.3097 30.491 18.5713 30.491 19.8964C30.491 21.2214 30.0863 22.4831 29.404 23.4273C29.1104 23.8399 28.547 23.943 28.0948 23.6653Z';

const String _kSpeaker3Wave2 =
    'M31.6733 25.8711C31.1576 25.5696 31.0942 24.9428 31.4432 24.3794C32.2526 23.1257 32.7207 21.5468 32.7207 19.8964C32.7207 18.2459 32.2605 16.6591 31.4432 15.4133C31.0942 14.8499 31.1576 14.2231 31.6733 13.9137C32.1415 13.6439 32.7128 13.755 33.0143 14.2152C34.0855 15.7783 34.6885 17.8016 34.6885 19.8964C34.6885 21.9911 34.0775 23.9985 33.0143 25.5775C32.7128 26.0377 32.1415 26.1488 31.6733 25.8711Z';

const String _kSpeaker3Wave3 =
    'M35.2362 28.1007C34.7363 27.7992 34.6569 27.1803 34.9981 26.6249C36.1883 24.7286 36.9104 22.4196 36.9104 19.9122C36.9104 17.397 36.1883 15.0881 34.9981 13.1917C34.6569 12.6362 34.7363 12.0174 35.2362 11.7159C35.7123 11.4302 36.3073 11.5651 36.6088 12.0571C38.0133 14.2866 38.8702 16.9765 38.8702 19.9122C38.8702 22.8401 38.0291 25.5379 36.6088 27.7675C36.3073 28.2515 35.7123 28.3864 35.2362 28.1007Z';
